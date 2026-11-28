pub use crate::android_engine::{UiAndroidAudioCmd, UiAndroidAudioEvent};
use crate::frb_generated::StreamSink;
#[cfg(not(target_os = "android"))]
use neomodern_core::audio::mpv::{MpvEngine, MpvOptions};
use neomodern_core::audio::{AudioEngine, Equalizer, NetGuardedEngine, ReplayGain};
use neomodern_core::backup::{self, BackupState, auto as backup_auto, swap as backup_swap};
use neomodern_core::library::{
    AlbumDetail, AlbumRow, ArtistProfile, ArtistRow, ArtistTopTrack, BucketStat, DynamicMix,
    FolderInfo, GenreRow, HomeFeed, HomeMixDetail, Hooks, Library, ListeningStats, MAX_PROFILES,
    NewListenEvent, PROFILE_COLORS, PlaylistInfo, Profile, ProfileId, RecentListen, RecentTrack,
    SortSpec, TopAlbumStat, TopArtistStat, TopGenreStat, TopTrackStat, TrackRow, cover_color, m3u,
    scan, tags,
};
use neomodern_core::lyrics::save::{self as lyrics_save, SaveMode};
use neomodern_core::lyrics::{
    BulkSaveOutcome, Coverage, LyricsOptions, LyricsResult, LyricsService, LyricsSource,
    ShareBlock, ShareOutcome, ShareStatus, attach_local_lrc,
};
#[cfg(not(target_os = "android"))]
use neomodern_core::media_keys::{self, Extra as MediaKeysExtra, MediaKeys};
use neomodern_core::metadata::{ApplyOutcome, MetadataService, Proposal, TrackCandidate};
use neomodern_core::net::Feature;
#[cfg(not(target_os = "android"))]
use neomodern_core::online::tools::Tool;
use neomodern_core::online::{
    ArtistScanProgress, DownloadJob, DownloadKind, DownloadRequest, DownloadState, OnlineAlbum,
    OnlineAlbumDetail, OnlineService, OnlineStatus, OnlineTrack, SearchResults,
};
use neomodern_core::player::{Player, PlayerEvent, PlayerSnapshot, Status, TrackInfo};
use neomodern_core::queue::{RepeatMode, Track};
use neomodern_core::session::{BackupInterval, PinnedKind, PinnedRef, SessionStore, is_stream_url};
use neomodern_core::source_provider::{
    ExternalTrack, ProviderConfig, ProviderRegistry, build_provider, load_provider_configs,
    parse_provider_kind, save_provider_configs,
};
use neomodern_core::sync::jam::host::JamStatus;
use neomodern_core::sync::pair_link::PairQr;
use neomodern_core::sync::service::{PairingOpen, SyncStatus};
use neomodern_core::sync::{
    EventSink, RemoteFeed, SyncConfig, SyncService, default_device_name, link,
};
use neomodern_core::update;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::broadcast;

struct CoreEventSink {
    event_tx: broadcast::Sender<UiEvent>,
}

impl EventSink for CoreEventSink {
    fn emit(&self, event: &str, _payload: serde_json::Value) {
        if event == "sync://status" || event == "jam://status" {
            let _ = self.event_tx.send(UiEvent::SyncChanged);
        }
    }
}

struct CoreState {
    data_dir: PathBuf,
    player: Arc<Player>,
    library: Arc<Library>,
    session: Arc<SessionStore>,
    backup: Arc<BackupState>,
    lyrics: Arc<LyricsService>,
    metadata: Arc<MetadataService>,
    online: Arc<OnlineService>,
    sync: SyncService,
    profile_lock: AtomicBool,
    source_config_path: PathBuf,
    source_configs: Mutex<Vec<ProviderConfig>>,
    source_registry: Arc<ProviderRegistry>,
    cover_colors: Mutex<HashMap<String, Option<u32>>>,
    metadata_proposals: Mutex<HashMap<(i64, String), Proposal>>,
    track_metadata_proposals: Mutex<HashMap<(i64, String), Proposal>>,
    ui_prefs_path: PathBuf,
    ui_prefs: Mutex<UiPrefs>,
    #[cfg(not(target_os = "android"))]
    media_keys: Option<MediaKeys>,
    #[cfg(target_os = "android")]
    android_engine_tx: std::sync::mpsc::Sender<neomodern_core::audio::EngineEvent>,
    #[cfg(target_os = "android")]
    android_slots: crate::android_engine::SharedSlots,
    event_tx: broadcast::Sender<UiEvent>,
}

static CORE: OnceLock<Arc<CoreState>> = OnceLock::new();
static INIT_LOCK: Mutex<()> = Mutex::new(());

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

#[derive(Debug, Clone)]
pub struct UiTrackInfo {
    pub id: u64,
    pub path: String,
    pub title: String,
    pub artist: String,
    pub queued: bool,
}

impl From<TrackInfo> for UiTrackInfo {
    fn from(t: TrackInfo) -> Self {
        Self {
            id: t.id.value(),
            path: t.path,
            title: t.title,
            artist: t.artist,
            queued: t.queued,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiPlayerSnapshot {
    pub status: String,
    pub current_index: Option<u32>,
    pub current: Option<UiTrackInfo>,
    pub queue_length: u32,
    pub queue_version: u64,
    pub position_seconds: f64,
    pub duration_seconds: Option<f64>,
    pub volume: f64,
    pub shuffle: bool,
    pub repeat: String,
    pub replaygain: String,
    pub gapless: bool,
    pub wasapi_exclusive: bool,
    pub eq_enabled: bool,
    pub eq_preamp_db: f64,
    pub eq_gains_db: Vec<f64>,
    pub crossfade_seconds: f64,
    pub sleep_ends_at: Option<i64>,
    pub sleep_end_of_track: bool,
    pub previous_track: Option<UiTrackInfo>,
    pub next_track: Option<UiTrackInfo>,
    pub context: Option<String>,
}

impl From<PlayerSnapshot> for UiPlayerSnapshot {
    fn from(s: PlayerSnapshot) -> Self {
        let status = match s.status {
            Status::Playing => "playing",
            Status::Paused => "paused",
            Status::Stopped => "stopped",
        }
        .to_string();
        let repeat = match s.repeat {
            RepeatMode::Off => "off",
            RepeatMode::All => "all",
            RepeatMode::One => "one",
        }
        .to_string();
        let replaygain = match s.replaygain {
            ReplayGain::Off => "off",
            ReplayGain::Track => "track",
            ReplayGain::Album => "album",
        }
        .to_string();
        Self {
            status,
            current_index: s.current_index.and_then(|i| u32::try_from(i).ok()),
            current: s.current.map(Into::into),
            queue_length: u32::try_from(s.queue_length).unwrap_or(u32::MAX),
            queue_version: s.queue_version,
            position_seconds: s.position_seconds,
            duration_seconds: s.duration_seconds,
            volume: s.volume,
            shuffle: s.shuffle,
            repeat,
            replaygain,
            gapless: s.gapless,
            wasapi_exclusive: s.wasapi_exclusive,
            eq_enabled: s.equalizer.enabled,
            eq_preamp_db: s.equalizer.preamp_db,
            eq_gains_db: s.equalizer.gains_db.to_vec(),
            crossfade_seconds: s.crossfade_seconds,
            sleep_ends_at: s.sleep_ends_at,
            sleep_end_of_track: s.sleep_end_of_track,
            previous_track: s.previous_track.map(Into::into),
            next_track: s.next_track.map(Into::into),
            context: s.context,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiTrackRow {
    pub id: i64,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_id: Option<i64>,
    pub track_no: Option<u32>,
    pub disc_no: Option<u32>,
    pub year: Option<i32>,
    pub duration_ms: Option<u64>,
    pub path: String,
    pub cover: Option<String>,
    pub plays: u32,
}

impl From<TrackRow> for UiTrackRow {
    fn from(r: TrackRow) -> Self {
        Self {
            id: r.id,
            title: r.title,
            artist: r.artist,
            album: r.album,
            album_id: r.album_id,
            track_no: r.track_no,
            disc_no: r.disc_no,
            year: r.year,
            duration_ms: r.duration_ms,
            path: r.path,
            cover: r.cover,
            plays: r.plays,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiAlbumRow {
    pub id: i64,
    pub title: String,
    pub album_artist: String,
    pub year: Option<i32>,
    pub track_count: u32,
    pub cover: Option<String>,
    pub cover_color: Option<u32>,
}

impl From<AlbumRow> for UiAlbumRow {
    fn from(a: AlbumRow) -> Self {
        let cover_color = cached_cover_color_only(a.cover.as_deref());
        Self {
            id: a.id,
            title: a.title,
            album_artist: a.album_artist,
            year: a.year,
            track_count: a.track_count,
            cover: a.cover,
            cover_color,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiAlbumDetail {
    pub album: UiAlbumRow,
    pub tracks: Vec<UiTrackRow>,
}

impl From<AlbumDetail> for UiAlbumDetail {
    fn from(d: AlbumDetail) -> Self {
        Self {
            album: d.album.into(),
            tracks: d.tracks.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiFolderInfo {
    pub id: i64,
    pub path: String,
}

impl From<FolderInfo> for UiFolderInfo {
    fn from(f: FolderInfo) -> Self {
        Self {
            id: f.id,
            path: f.path,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiDynamicMix {
    pub id: String,
    pub title: String,
    pub subtitle: String,
    pub track_count: u32,
    pub cover_paths: Vec<String>,
}

impl From<DynamicMix> for UiDynamicMix {
    fn from(m: DynamicMix) -> Self {
        let title = if m.title_key.contains("{name}") {
            m.title_key
                .replace("{name}", m.subject.as_deref().unwrap_or("Daily"))
        } else {
            m.title_key
        };
        Self {
            id: m.id,
            title,
            subtitle: m.subtitle_key,
            track_count: m.track_count,
            cover_paths: m.album_covers,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiRecentTrack {
    pub track: UiTrackRow,
    pub started_at: i64,
}

impl From<RecentTrack> for UiRecentTrack {
    fn from(r: RecentTrack) -> Self {
        Self {
            track: r.track.into(),
            started_at: r.started_at,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiHomeFeed {
    pub recently_played_albums: Vec<UiAlbumRow>,
    pub recently_played_tracks: Vec<UiRecentTrack>,
    pub recently_added_albums: Vec<UiAlbumRow>,
    pub favorite_count: u64,
    pub mixes: Vec<UiDynamicMix>,
    pub has_history: bool,
}

impl From<HomeFeed> for UiHomeFeed {
    fn from(f: HomeFeed) -> Self {
        Self {
            recently_played_albums: f
                .recently_played_albums
                .into_iter()
                .map(Into::into)
                .collect(),
            recently_played_tracks: f
                .recently_played_tracks
                .into_iter()
                .map(Into::into)
                .collect(),
            recently_added_albums: f
                .recently_added_albums
                .into_iter()
                .map(Into::into)
                .collect(),
            favorite_count: f.favorite_count,
            mixes: f.mixes.into_iter().map(Into::into).collect(),
            has_history: f.has_history,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiHomeMixDetail {
    pub mix: UiDynamicMix,
    pub tracks: Vec<UiTrackRow>,
}

impl From<HomeMixDetail> for UiHomeMixDetail {
    fn from(d: HomeMixDetail) -> Self {
        Self {
            mix: d.mix.into(),
            tracks: d.tracks.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiPlaylistInfo {
    pub id: i64,
    pub name: String,
    pub track_count: u32,
    pub cover: Option<String>,
    pub album_covers: Vec<String>,
    pub cover_mode: String,
    pub cover_value: Option<String>,
}

impl From<PlaylistInfo> for UiPlaylistInfo {
    fn from(p: PlaylistInfo) -> Self {
        let (cover_mode, cover_value) = playlist_cover_mode_and_value(p.cover.as_deref());
        Self {
            id: p.id,
            name: p.name,
            track_count: p.track_count,
            cover: p.cover,
            album_covers: p.album_covers,
            cover_mode,
            cover_value,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiArtistRow {
    pub name: String,
    pub track_count: u32,
    pub album_count: u32,
    pub cover: Option<String>,
    pub play_count: u64,
    pub listened_ms: u64,
}

impl From<ArtistRow> for UiArtistRow {
    fn from(a: ArtistRow) -> Self {
        Self {
            name: a.name,
            track_count: a.track_count,
            album_count: a.album_count,
            cover: a.cover,
            play_count: a.play_count,
            listened_ms: a.listened_ms,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiArtistTopTrack {
    pub track: UiTrackRow,
    pub play_count: u64,
    pub listened_ms: u64,
}

impl From<ArtistTopTrack> for UiArtistTopTrack {
    fn from(t: ArtistTopTrack) -> Self {
        Self {
            track: t.track.into(),
            play_count: t.play_count,
            listened_ms: t.listened_ms,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiArtistDetail {
    pub name: String,
    pub track_count: u32,
    pub album_count: u32,
    pub total_duration_ms: u64,
    pub genres: Vec<String>,
    pub play_count: u64,
    pub listened_ms: u64,
    pub image: Option<String>,
    pub cover: Option<String>,
    pub bio: Option<String>,
    pub fetched_at: Option<i64>,
    pub fallback_cover: Option<String>,
    pub popular_tracks: Vec<UiArtistTopTrack>,
    pub albums: Vec<UiAlbumRow>,
    pub tracks: Vec<UiTrackRow>,
    pub online_albums: Vec<UiOnlineAlbum>,
}

impl From<ArtistProfile> for UiArtistDetail {
    fn from(a: ArtistProfile) -> Self {
        let cover = a.image.clone().or_else(|| a.fallback_cover.clone());
        Self {
            name: a.name,
            track_count: a.track_count,
            album_count: a.album_count,
            total_duration_ms: a.total_duration_ms,
            genres: a.genres,
            play_count: a.play_count,
            listened_ms: a.listened_ms,
            image: a.image,
            cover,
            bio: a.bio,
            fetched_at: a.fetched_at,
            fallback_cover: a.fallback_cover,
            popular_tracks: a.popular_tracks.into_iter().map(Into::into).collect(),
            albums: a.albums.into_iter().map(Into::into).collect(),
            tracks: a.tracks.into_iter().map(Into::into).collect(),
            online_albums: Vec::new(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiSyncedLine {
    pub time_ms: i64,
    pub text: String,
}

#[derive(Debug, Clone)]
pub struct UiLyrics {
    pub found: bool,
    pub is_instrumental: bool,
    pub synced_lines: Vec<UiSyncedLine>,
    pub plain_text: Option<String>,
    pub source: Option<String>,
}

#[derive(Debug, Clone)]
pub struct UiGenreInfo {
    pub name: String,
    pub track_count: u32,
    pub album_count: u32,
    pub cover_path: Option<String>,
}

#[derive(Debug, Clone)]
pub struct UiGenreDetail {
    pub name: String,
    pub track_count: u32,
    pub album_count: u32,
    pub total_duration_ms: u64,
    pub cover_path: Option<String>,
    pub albums: Vec<UiAlbumRow>,
}

#[derive(Debug, Clone)]
pub struct UiTopTrackStat {
    pub track_id: Option<i64>,
    pub path: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub cover: Option<String>,
    pub play_count: u64,
    pub listened_ms: u64,
    pub skip_count: u64,
}

impl From<TopTrackStat> for UiTopTrackStat {
    fn from(t: TopTrackStat) -> Self {
        Self {
            track_id: t.track_id,
            path: t.path,
            title: t.title,
            artist: t.artist,
            album: t.album,
            cover: t.cover,
            play_count: t.play_count,
            listened_ms: t.listened_ms,
            skip_count: t.skip_count,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiTopArtistStat {
    pub artist: String,
    pub cover: Option<String>,
    pub play_count: u64,
    pub listened_ms: u64,
    pub unique_tracks: u64,
    pub skip_count: u64,
}

impl From<TopArtistStat> for UiTopArtistStat {
    fn from(a: TopArtistStat) -> Self {
        Self {
            artist: a.artist,
            cover: a.cover,
            play_count: a.play_count,
            listened_ms: a.listened_ms,
            unique_tracks: a.unique_tracks,
            skip_count: a.skip_count,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiTopAlbumStat {
    pub album: String,
    pub artist: String,
    pub album_id: Option<i64>,
    pub cover: Option<String>,
    pub play_count: u64,
    pub listened_ms: u64,
}

impl From<TopAlbumStat> for UiTopAlbumStat {
    fn from(a: TopAlbumStat) -> Self {
        Self {
            album: a.album,
            artist: a.artist,
            album_id: a.album_id,
            cover: a.cover,
            play_count: a.play_count,
            listened_ms: a.listened_ms,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiMonthlyStat {
    pub label: String,
    pub listened_ms: i64,
    pub plays: i64,
}

impl From<BucketStat> for UiMonthlyStat {
    fn from(b: BucketStat) -> Self {
        Self {
            label: b.label,
            listened_ms: i64::try_from(b.listened_ms).unwrap_or(i64::MAX),
            plays: i64::try_from(b.play_count).unwrap_or(i64::MAX),
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiGenreStat {
    pub genre: String,
    pub listened_ms: i64,
    pub plays: i64,
}

impl From<TopGenreStat> for UiGenreStat {
    fn from(g: TopGenreStat) -> Self {
        Self {
            genre: g.genre,
            listened_ms: i64::try_from(g.listened_ms).unwrap_or(i64::MAX),
            plays: i64::try_from(g.play_count).unwrap_or(i64::MAX),
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiRecentListenEvent {
    pub id: i64,
    pub track_id: Option<i64>,
    pub path: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub cover: Option<String>,
    pub started_at: i64,
    pub listened_ms: i64,
    pub completed: bool,
    pub skipped: bool,
    pub source: String,
}

impl From<RecentListen> for UiRecentListenEvent {
    fn from(r: RecentListen) -> Self {
        Self {
            id: r.id,
            track_id: r.track_id,
            path: r.path,
            title: r.title,
            artist: r.artist,
            album: r.album,
            cover: r.cover,
            started_at: r.started_at,
            listened_ms: i64::try_from(r.listened_ms).unwrap_or(i64::MAX),
            completed: r.completed,
            skipped: r.skipped,
            source: r.source,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiStatsSummary {
    pub total_listened_ms: u64,
    pub play_count: u64,
    pub raw_event_count: u64,
    pub skip_count: u64,
    pub completed_count: u64,
    pub unique_tracks: u64,
    pub unique_artists: u64,
    pub unique_albums: u64,
    pub active_days: u64,
    pub longest_streak_days: u64,
    pub current_streak_days: u64,
    /// Completion ratio in `[0.0, 1.0]` (`completed_count / raw_event_count`).
    pub completion_rate: f64,
    pub peak_hour: Option<u32>,
    /// Monday = 0 .. Sunday = 6, matching `neomodern-core`.
    pub favorite_weekday: Option<u32>,
    pub first_listen_at: Option<i64>,
    /// 24 local-hour buckets (0..23) of listening duration in milliseconds.
    pub hourly_ms: Vec<i64>,
    /// 7 weekday buckets (Monday = 0 .. Sunday = 6) of listening duration in milliseconds.
    pub weekday_ms: Vec<i64>,
    pub monthly: Vec<UiMonthlyStat>,
    pub top_genres: Vec<UiGenreStat>,
    pub top_tracks: Vec<UiTopTrackStat>,
    pub top_artists: Vec<UiTopArtistStat>,
    pub top_albums: Vec<UiTopAlbumStat>,
    pub recent_events: Vec<UiRecentListenEvent>,
    pub available_years: Vec<i32>,
}

fn stats_to_ui(s: ListeningStats, sort_by_plays: bool) -> UiStatsSummary {
    let completion_rate = if s.summary.raw_event_count > 0 {
        s.summary.completed_count as f64 / s.summary.raw_event_count as f64
    } else {
        0.0
    };
    let top_tracks_src = if sort_by_plays {
        s.top_tracks_by_plays
    } else {
        s.top_tracks_by_time
    };
    UiStatsSummary {
        total_listened_ms: s.summary.total_listened_ms,
        play_count: s.summary.play_count,
        raw_event_count: s.summary.raw_event_count,
        skip_count: s.summary.skip_count,
        completed_count: s.summary.completed_count,
        unique_tracks: s.summary.unique_tracks,
        unique_artists: s.summary.unique_artists,
        unique_albums: s.summary.unique_albums,
        active_days: s.summary.active_days,
        longest_streak_days: s.summary.longest_streak_days,
        current_streak_days: s.summary.current_streak_days,
        completion_rate,
        peak_hour: s.summary.top_hour,
        favorite_weekday: s.summary.top_weekday,
        first_listen_at: s.summary.first_listen_at,
        hourly_ms: s
            .by_hour
            .into_iter()
            .map(|b| i64::try_from(b.listened_ms).unwrap_or(i64::MAX))
            .collect(),
        weekday_ms: s
            .by_weekday
            .into_iter()
            .map(|b| i64::try_from(b.listened_ms).unwrap_or(i64::MAX))
            .collect(),
        monthly: s.by_month.into_iter().map(Into::into).collect(),
        top_genres: s.top_genres.into_iter().map(Into::into).collect(),
        top_tracks: top_tracks_src.into_iter().map(Into::into).collect(),
        top_artists: s.top_artists_by_time.into_iter().map(Into::into).collect(),
        top_albums: s.top_albums_by_time.into_iter().map(Into::into).collect(),
        recent_events: s.recent.into_iter().map(Into::into).collect(),
        available_years: s.available_years,
    }
}

impl From<ListeningStats> for UiStatsSummary {
    fn from(s: ListeningStats) -> Self {
        stats_to_ui(s, false)
    }
}

#[derive(Debug, Clone)]
pub struct UiProfile {
    pub id: i64,
    pub name: String,
    pub color: String,
    pub created_at: i64,
    pub has_pin: bool,
}

impl From<Profile> for UiProfile {
    fn from(p: Profile) -> Self {
        Self {
            id: p.id.0,
            name: p.name,
            color: p.color,
            created_at: p.created_at,
            has_pin: p.has_pin,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiProfilesState {
    pub active: i64,
    pub profiles: Vec<UiProfile>,
    pub colors: Vec<String>,
    pub max_profiles: u32,
    pub locked: bool,
}

#[derive(Debug, Clone)]
pub struct UiPeerStatus {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub address: Option<String>,
    pub connected: bool,
    pub syncing: bool,
    pub last_sync_at: Option<i64>,
    pub profile_name: String,
    pub profile_id: i64,
    pub last_error: Option<String>,
    pub rounds: u64,
}

#[derive(Debug, Clone)]
pub struct UiSyncStatus {
    pub role: String,
    pub device_id: String,
    pub device_name: String,
    pub active_profile: i64,
    pub allow_phone_connections: bool,
    pub listening_port: Option<u16>,
    pub listening_addresses: Vec<String>,
    pub pairing_state: String,
    pub pairing_code: Option<String>,
    pub pairing_remaining_secs: Option<u64>,
    pub pairing_profile_name: Option<String>,
    pub peers: Vec<UiPeerStatus>,
}

impl From<SyncStatus> for UiSyncStatus {
    fn from(s: SyncStatus) -> Self {
        Self {
            role: s.role.to_owned(),
            device_id: s.device_id,
            device_name: s.device_name,
            active_profile: s.active_profile,
            allow_phone_connections: s.allow_phone_connections,
            listening_port: s.listening.as_ref().map(|l| l.port),
            listening_addresses: s.listening.map(|l| l.addresses).unwrap_or_default(),
            pairing_state: s.pairing.state.to_owned(),
            pairing_code: s.pairing.code,
            pairing_remaining_secs: s.pairing.remaining_secs,
            pairing_profile_name: s.pairing.profile_name,
            peers: s
                .peers
                .into_iter()
                .map(|p| UiPeerStatus {
                    id: p.id,
                    name: p.name,
                    kind: p.kind.to_owned(),
                    address: p.address,
                    connected: p.connected,
                    syncing: p.syncing,
                    last_sync_at: p.last_sync_at,
                    profile_name: p.profile_name,
                    profile_id: p.profile_id,
                    last_error: p.last_error,
                    rounds: p.rounds,
                })
                .collect(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiPairingOpen {
    pub code: String,
    pub addresses: Vec<String>,
    pub port: u16,
    pub remaining_secs: u64,
    pub profile_name: String,
    pub pairing_uri: String,
    pub qr_matrix: Vec<bool>,
    pub qr_size: u32,
}

fn qr_parts(qr: Option<PairQr>) -> (String, Vec<bool>, u32) {
    match qr {
        Some(q) => {
            let size = u32::try_from(q.size).unwrap_or(0);
            let matrix = q.modules.bytes().map(|b| b == b'1').collect();
            (q.link, matrix, size)
        }
        None => (String::new(), Vec::new(), 0),
    }
}

impl From<PairingOpen> for UiPairingOpen {
    fn from(p: PairingOpen) -> Self {
        let (pairing_uri, qr_matrix, qr_size) = qr_parts(p.qr);
        Self {
            code: p.code,
            addresses: p.addresses,
            port: p.port,
            remaining_secs: p.remaining_secs,
            profile_name: p.profile_name,
            pairing_uri,
            qr_matrix,
            qr_size,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiPartyGuestInfo {
    pub id: String,
    pub name: String,
    pub added: u32,
    pub connected: bool,
}

#[derive(Debug, Clone)]
pub struct UiPartyRecent {
    pub title: String,
    pub artist: String,
    pub added_by: String,
}

#[derive(Debug, Clone)]
pub struct UiPartyStatus {
    pub enabled: bool,
    pub running: bool,
    pub code: Option<String>,
    pub join_uri: Option<String>,
    pub qr_matrix: Vec<bool>,
    pub qr_size: u32,
    pub addresses: Vec<String>,
    pub guests: Vec<UiPartyGuestInfo>,
    pub recent: Vec<UiPartyRecent>,
}

impl From<JamStatus> for UiPartyStatus {
    fn from(s: JamStatus) -> Self {
        let (qr_link, qr_matrix, qr_size) = qr_parts(s.qr);
        let join_uri = s.link.or_else(|| (!qr_link.is_empty()).then_some(qr_link));
        Self {
            enabled: s.enabled,
            running: s.running,
            code: s.code,
            join_uri,
            qr_matrix,
            qr_size,
            addresses: s.addresses,
            guests: s
                .guests
                .into_iter()
                .map(|g| UiPartyGuestInfo {
                    id: g.id,
                    name: g.name,
                    added: g.added,
                    connected: g.connected,
                })
                .collect(),
            recent: s
                .recent
                .into_iter()
                .map(|r| UiPartyRecent {
                    title: r.title,
                    artist: r.artist,
                    added_by: r.added_by,
                })
                .collect(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiSourceProvider {
    pub id: String,
    pub name: String,
    pub base_url: String,
    pub enabled: bool,
}

#[derive(Debug, Clone)]
pub struct UiExternalTrack {
    pub provider_id: String,
    pub external_id: String,
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub duration_ms: Option<u64>,
    pub cover_url: Option<String>,
}

#[derive(Debug, Clone)]
pub struct UiTrackTags {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_number: Option<u32>,
    pub disc_number: Option<u32>,
    pub year: Option<i32>,
    pub genre: Option<String>,
}

impl From<tags::EditableTags> for UiTrackTags {
    fn from(t: tags::EditableTags) -> Self {
        Self {
            title: t.title,
            artist: t.artist,
            album: t.album,
            album_artist: t.album_artist,
            track_number: t.track_no,
            disc_number: t.disc_no,
            year: t.year,
            genre: t.genre,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiMetadataFieldDiff {
    pub field: String,
    pub old_value: Option<String>,
    pub new_value: Option<String>,
}

#[derive(Debug, Clone)]
pub struct UiMetadataTrackDiff {
    pub track_id: i64,
    pub path: String,
    pub title: String,
    pub matched: bool,
    pub fields: Vec<UiMetadataFieldDiff>,
}

#[derive(Debug, Clone)]
pub struct UiAlbumMatchCandidate {
    pub release_mbid: String,
    pub release_group_mbid: String,
    pub title: String,
    pub artist: String,
    pub year: Option<i32>,
    pub country: Option<String>,
    pub format: Option<String>,
    pub status: Option<String>,
    pub track_count: u32,
    pub score: u8,
    pub label: String,
    pub cover_preview: Option<String>,
    pub album_fields: Vec<UiMetadataFieldDiff>,
    pub tracks: Vec<UiMetadataTrackDiff>,
}

#[derive(Debug, Clone)]
pub struct UiMetadataApplyResult {
    pub batch_id: i64,
    pub updated: u32,
    pub failed: Vec<String>,
    pub cover: Option<String>,
}

#[derive(Debug, Clone)]
pub struct UiPinnedItem {
    pub kind: String,
    pub target_id: i64,
    pub title: String,
    pub subtitle: String,
    pub cover_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct UiPrefs {
    pub language: String,
    pub welcome_dismissed: bool,
    pub sidebar_width: f64,
    pub right_panel_width: f64,
}

impl Default for UiPrefs {
    fn default() -> Self {
        Self {
            language: "system".to_string(),
            welcome_dismissed: false,
            sidebar_width: 228.0,
            right_panel_width: 328.0,
        }
    }
}

impl From<ExternalTrack> for UiExternalTrack {
    fn from(t: ExternalTrack) -> Self {
        Self {
            provider_id: t.provider_id,
            external_id: t.external_id,
            title: t.title,
            artist: t.artist,
            album: t.album,
            duration_ms: t.duration_ms,
            cover_url: t.cover_url,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiTrackMatchCandidate {
    pub candidate_id: String,
    pub recording_id: String,
    pub release_id: String,
    pub release_group_id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub year: Option<i32>,
    pub country: Option<String>,
    pub format: Option<String>,
    pub status: Option<String>,
    pub score: u8,
    pub label: String,
    pub cover_preview: Option<String>,
    pub track: UiMetadataTrackDiff,
}

#[derive(Debug, Clone)]
pub struct UiOnlineStatus {
    pub ytdlp_available: bool,
    pub ytdlp_version: Option<String>,
    pub ffmpeg_available: bool,
    pub download_dir: String,
    pub ytdlp_path: Option<String>,
    pub can_install_tools: bool,
    pub managed_ytdlp: bool,
    pub managed_ffmpeg: bool,
}

impl From<OnlineStatus> for UiOnlineStatus {
    fn from(s: OnlineStatus) -> Self {
        Self {
            ytdlp_available: s.ytdlp_available,
            ytdlp_version: s.ytdlp_version,
            ffmpeg_available: s.ffmpeg_available,
            download_dir: s.download_dir,
            ytdlp_path: s.ytdlp_path,
            can_install_tools: s.can_install_tools,
            managed_ytdlp: s.managed_ytdlp,
            managed_ffmpeg: s.managed_ffmpeg,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiOnlineAlbum {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub year: Option<i32>,
    pub track_count: u32,
    pub cover: Option<String>,
    pub cover_url: Option<String>,
    pub source_url: Option<String>,
}

impl From<OnlineAlbum> for UiOnlineAlbum {
    fn from(a: OnlineAlbum) -> Self {
        Self {
            id: a.id,
            title: a.title,
            artist: a.artist,
            year: a.year,
            track_count: a.track_count,
            cover: a.cover,
            cover_url: a.cover_url,
            source_url: a.source_url,
        }
    }
}

impl From<UiOnlineAlbum> for OnlineAlbum {
    fn from(a: UiOnlineAlbum) -> Self {
        Self {
            id: a.id,
            title: a.title,
            artist: a.artist,
            year: a.year,
            track_count: a.track_count,
            cover: a.cover,
            cover_url: a.cover_url,
            source_url: a.source_url,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiOnlineTrack {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: String,
    pub track_no: Option<u32>,
    pub disc_no: Option<u32>,
    pub year: Option<i32>,
    pub duration_seconds: Option<f64>,
    pub source_url: Option<String>,
    pub cover: Option<String>,
    pub cover_url: Option<String>,
}

impl From<OnlineTrack> for UiOnlineTrack {
    fn from(t: OnlineTrack) -> Self {
        Self {
            id: t.id,
            title: t.title,
            artist: t.artist,
            album: t.album,
            album_artist: t.album_artist,
            track_no: t.track_no,
            disc_no: t.disc_no,
            year: t.year,
            duration_seconds: t.duration_seconds,
            source_url: t.source_url,
            cover: t.cover,
            cover_url: t.cover_url,
        }
    }
}

impl From<UiOnlineTrack> for OnlineTrack {
    fn from(t: UiOnlineTrack) -> Self {
        Self {
            id: t.id,
            title: t.title,
            artist: t.artist,
            album: t.album,
            album_artist: t.album_artist,
            track_no: t.track_no,
            disc_no: t.disc_no,
            year: t.year,
            duration_seconds: t.duration_seconds,
            source_url: t.source_url,
            cover: t.cover,
            cover_url: t.cover_url,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiOnlineSearchResult {
    pub albums: Vec<UiOnlineAlbum>,
    pub tracks: Vec<UiOnlineTrack>,
}

impl From<SearchResults> for UiOnlineSearchResult {
    fn from(r: SearchResults) -> Self {
        Self {
            albums: r.albums.into_iter().map(Into::into).collect(),
            tracks: r.tracks.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiOnlineAlbumDetail {
    pub album: UiOnlineAlbum,
    pub tracks: Vec<UiOnlineTrack>,
}

impl From<OnlineAlbumDetail> for UiOnlineAlbumDetail {
    fn from(d: OnlineAlbumDetail) -> Self {
        Self {
            album: d.album.into(),
            tracks: d.tracks.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiDownloadJob {
    pub id: u64,
    pub kind: String,
    pub title: String,
    pub artist: String,
    pub cover: Option<String>,
    pub state: String,
    pub done_tracks: u32,
    pub total_tracks: u32,
    pub current_track: Option<String>,
    pub error: Option<String>,
    pub output_dir: Option<String>,
}

impl From<DownloadJob> for UiDownloadJob {
    fn from(j: DownloadJob) -> Self {
        let kind = match j.kind {
            DownloadKind::Track => "track",
            DownloadKind::Album => "album",
        }
        .to_string();
        let state = match j.state {
            DownloadState::Queued => "queued",
            DownloadState::Downloading => "downloading",
            DownloadState::Done => "done",
            DownloadState::Failed => "failed",
            DownloadState::Cancelled => "cancelled",
        }
        .to_string();
        Self {
            id: j.id,
            kind,
            title: j.title,
            artist: j.artist,
            cover: j.cover,
            state,
            done_tracks: u32::try_from(j.done_tracks).unwrap_or(u32::MAX),
            total_tracks: u32::try_from(j.total_tracks).unwrap_or(u32::MAX),
            current_track: j.current_track,
            error: j.error,
            output_dir: j.output_dir,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiArtistScanProgress {
    pub running: bool,
    pub done: u32,
    pub total: u32,
    pub updated: u32,
    pub current: Option<String>,
    pub cancelled: bool,
    pub error: Option<String>,
}

impl From<ArtistScanProgress> for UiArtistScanProgress {
    fn from(p: ArtistScanProgress) -> Self {
        Self {
            running: p.scanning,
            done: p.done,
            total: p.total,
            updated: p.updated,
            current: p.current_artist,
            cancelled: p.cancelled,
            error: p.error,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiNetSettings {
    pub offline_mode: bool,
    pub online: bool,
    pub lyrics: bool,
    pub artist_info: bool,
    pub metadata: bool,
    pub updates: bool,
    pub allow_online: bool,
    pub allow_lyrics: bool,
    pub allow_artist_info: bool,
    pub allow_metadata: bool,
    pub allow_updates: bool,
    pub lyrics_save: String,
    pub lyrics_netease: bool,
}

#[derive(Debug, Clone)]
pub struct UiLyricsCoverage {
    pub with_lyrics: u64,
    pub without_lyrics: u64,
    pub unchecked: u64,
}

impl From<Coverage> for UiLyricsCoverage {
    fn from(c: Coverage) -> Self {
        Self {
            with_lyrics: c.with_lyrics,
            without_lyrics: c.without_lyrics,
            unchecked: c.unchecked,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiBulkSaveOutcome {
    pub saved: u64,
    pub skipped: u64,
}

impl From<BulkSaveOutcome> for UiBulkSaveOutcome {
    fn from(o: BulkSaveOutcome) -> Self {
        Self {
            saved: o.saved,
            skipped: o.skipped,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiLyricsShareStatus {
    pub available: bool,
    pub reason: Option<String>,
    pub outcome: Option<String>,
}

#[derive(Debug, Clone)]
pub struct UiUpdateInfo {
    pub current_version: String,
    pub update_available: bool,
    pub version: Option<String>,
    pub url: Option<String>,
    pub installable: bool,
}

#[derive(Debug, Clone)]
#[allow(clippy::large_enum_variant)]
pub enum UiEvent {
    State(UiPlayerSnapshot),
    Position {
        seconds: f64,
        duration: Option<f64>,
    },
    LibraryChanged,
    ScanProgress {
        scanned: u64,
        total: u64,
        done: bool,
    },
    SyncChanged,
    DownloadsChanged,
    ArtistScanProgress {
        running: bool,
        total: u32,
        done: u32,
        current: Option<String>,
        error: Option<String>,
    },
    ToolInstallProgress {
        tool: String,
        stage: String,
        received: u64,
        total: Option<u64>,
    },
    Error(String),
}

fn core() -> Result<&'static Arc<CoreState>, String> {
    CORE.get()
        .ok_or_else(|| "neomodern core is not initialized".to_string())
}

fn build_tracks(library: &Library, paths: Vec<String>) -> Vec<Track> {
    paths
        .into_iter()
        .map(|path| match library.track_meta(&path).ok().flatten() {
            Some(meta) => Track {
                path: PathBuf::from(&path),
                title: Some(meta.title),
                artist: Some(meta.artist),
            },
            None => Track::from(PathBuf::from(path)),
        })
        .collect()
}

fn source_label(source: LyricsSource) -> String {
    match source {
        LyricsSource::LocalLrc => "Local .lrc".to_string(),
        LyricsSource::Embedded => "Embedded Tag".to_string(),
        LyricsSource::Lrclib => "LRCLIB".to_string(),
        LyricsSource::Netease => "NetEase".to_string(),
    }
}

fn rgb_to_argb([r, g, b]: [u8; 3]) -> u32 {
    0xFF00_0000 | (u32::from(r) << 16) | (u32::from(g) << 8) | u32::from(b)
}

fn cached_cover_color_only(cover: Option<&str>) -> Option<u32> {
    let cover = cover?.trim();
    if cover.is_empty() {
        return None;
    }
    let state = CORE.get()?;
    let cache = state.cover_colors.lock().unwrap_or_else(|e| e.into_inner());
    cache.get(cover).copied().flatten()
}

fn compute_and_cache_cover_color(state: &CoreState, path: &str) -> Option<u32> {
    let key = path.trim();
    if key.is_empty() {
        return None;
    }
    {
        let cache = state.cover_colors.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(&cached) = cache.get(key) {
            return cached;
        }
    }
    let color = cover_color::cover_color(Path::new(key))
        .ok()
        .map(rgb_to_argb);
    let mut cache = state.cover_colors.lock().unwrap_or_else(|e| e.into_inner());
    if cache.len() >= 1024 {
        cache.clear();
    }
    cache.insert(key.to_owned(), color);
    color
}

fn playlist_cover_mode_and_value(cover: Option<&str>) -> (String, Option<String>) {
    match cover.map(str::trim).filter(|s| !s.is_empty()) {
        None => ("auto".to_string(), None),
        Some(s) if s.starts_with("preset:") => ("gradient".to_string(), Some(s.to_owned())),
        Some(s) => ("image".to_string(), Some(s.to_owned())),
    }
}

fn normalize_language(lang: &str) -> Option<&'static str> {
    match lang.trim() {
        "system" => Some("system"),
        "en" => Some("en"),
        "tr" => Some("tr"),
        _ => None,
    }
}

fn sanitize_width(value: f64, default: f64, min: f64, max: f64) -> f64 {
    if value.is_finite() && value > 0.0 {
        value.clamp(min, max)
    } else {
        default
    }
}

fn validate_and_normalize_ui_prefs(prefs: UiPrefs) -> Result<UiPrefs, String> {
    let language = normalize_language(&prefs.language)
        .ok_or_else(|| format!("invalid ui language: {}", prefs.language))?
        .to_string();
    let defaults = UiPrefs::default();
    Ok(UiPrefs {
        language,
        welcome_dismissed: prefs.welcome_dismissed,
        sidebar_width: sanitize_width(prefs.sidebar_width, defaults.sidebar_width, 120.0, 600.0),
        right_panel_width: sanitize_width(
            prefs.right_panel_width,
            defaults.right_panel_width,
            180.0,
            720.0,
        ),
    })
}

fn load_ui_prefs(path: &Path) -> UiPrefs {
    let defaults = UiPrefs::default();
    let Ok(bytes) = std::fs::read(path) else {
        return defaults;
    };
    let Ok(val) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        return defaults;
    };
    let language = val
        .get("language")
        .and_then(|v| v.as_str())
        .and_then(normalize_language)
        .unwrap_or("system")
        .to_string();
    let welcome_dismissed = val
        .get("welcomeDismissed")
        .and_then(|v| v.as_bool())
        .unwrap_or(defaults.welcome_dismissed);
    let sidebar_width = val
        .get("sidebarWidth")
        .and_then(|v| v.as_f64())
        .map(|w| sanitize_width(w, defaults.sidebar_width, 120.0, 600.0))
        .unwrap_or(defaults.sidebar_width);
    let right_panel_width = val
        .get("rightPanelWidth")
        .and_then(|v| v.as_f64())
        .map(|w| sanitize_width(w, defaults.right_panel_width, 180.0, 720.0))
        .unwrap_or(defaults.right_panel_width);
    UiPrefs {
        language,
        welcome_dismissed,
        sidebar_width,
        right_panel_width,
    }
}

fn save_ui_prefs(path: &Path, prefs: &UiPrefs) -> Result<(), String> {
    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let json = serde_json::to_vec_pretty(&serde_json::json!({
        "language": prefs.language,
        "welcomeDismissed": prefs.welcome_dismissed,
        "sidebarWidth": prefs.sidebar_width,
        "rightPanelWidth": prefs.right_panel_width,
    }))
    .map_err(|e| e.to_string())?;
    scan::write_atomic(path, &json).map_err(|e| e.to_string())
}

fn refresh_player_meta(library: &Library, player: &Player, paths: &[String]) {
    for path in paths {
        match library.track_meta(path) {
            Ok(Some(meta)) => {
                player.update_track_meta(path, &meta.title, &meta.artist);
            }
            Ok(None) => {}
            Err(e) => log::warn!("could not read back {path}: {e}"),
        }
    }
}

fn find_track_id_for_path(library: &Library, path: &str) -> Result<Option<i64>, String> {
    if let Some(id) = library.track_id_by_path(path).map_err(|e| e.to_string())? {
        return Ok(Some(id));
    }
    let display = scan::display_path(Path::new(path));
    if display != path
        && let Some(id) = library
            .track_id_by_path(&display)
            .map_err(|e| e.to_string())?
    {
        return Ok(Some(id));
    }
    if let Ok(canon) = std::fs::canonicalize(Path::new(path)) {
        let canon_display = scan::display_path(&canon);
        if let Some(id) = library
            .track_id_by_path(&canon_display)
            .map_err(|e| e.to_string())?
        {
            return Ok(Some(id));
        }
    }
    Ok(None)
}

pub async fn init_core(data_dir: String, cache_dir: String) -> Result<UiPlayerSnapshot, String> {
    let startup = {
        let _guard = INIT_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(existing) = CORE.get() {
            return Ok(existing.player.snapshot().into());
        }

        let data_path = PathBuf::from(&data_dir);
        let cache_path = PathBuf::from(&cache_dir);

        // Apply any staged backup import before opening library.sqlite3 or
        // loading session.json.
        let import_outcome = backup_swap::apply_pending_import(&data_path);
        if let Some(outcome) = &import_outcome {
            if outcome.applied {
                log::info!("applied staged backup import on startup");
            } else if let Some(err) = &outcome.error {
                log::warn!("staged backup import failed on startup: {err}");
            }
        }

        let session = Arc::new(SessionStore::new(data_path.join("session.json")));
        let (event_tx, _) = broadcast::channel::<UiEvent>(256);
        let remote_feed = RemoteFeed::new();

        let (engine_tx, engine_rx) = std::sync::mpsc::channel();
        #[cfg(not(target_os = "android"))]
        let engine: Box<dyn AudioEngine> = Box::new(
            MpvEngine::new(MpvOptions::default(), engine_tx)
                .map_err(|e| format!("failed to start audio engine: {e}"))?,
        );
        #[cfg(target_os = "android")]
        let (engine, android_slots, android_engine_tx) = {
            let eng = crate::android_engine::AndroidBridgeEngine::new()
                .map_err(|e| format!("failed to start android audio bridge: {e}"))?;
            let slots = eng.slots_handle();
            (Box::new(eng) as Box<dyn AudioEngine>, slots, engine_tx)
        };

        let observer_session = Arc::clone(&session);
        let observer_feed = remote_feed.clone();
        let observer_tx = event_tx.clone();
        let player = Arc::new(Player::new(
            Box::new(NetGuardedEngine::new(engine, session.net_policy())),
            Box::new(move |event| {
                observer_feed.on_player_event(&event);
                match event {
                    PlayerEvent::State(snap) => {
                        if let Some(state) = CORE.get() {
                            observer_session
                                .on_player_state(&snap, || state.player.export_session());
                            #[cfg(not(target_os = "android"))]
                            if let Some(keys) = state.media_keys.as_ref() {
                                keys.publish(&snap, |path| MediaKeysExtra {
                                    album: state
                                        .library
                                        .track_meta(path)
                                        .ok()
                                        .flatten()
                                        .map(|m| m.album),
                                    cover: state
                                        .library
                                        .track_cover(path)
                                        .ok()
                                        .flatten()
                                        .or_else(|| state.online.stream_cover(path)),
                                });
                            }
                        }
                        let _ = observer_tx.send(UiEvent::State(snap.into()));
                    }
                    PlayerEvent::Position { seconds, duration } => {
                        if let Some(state) = CORE.get() {
                            let (qv, idx, pos) = state.player.progress_state();
                            observer_session.maybe_save_progress(qv, idx, pos, || {
                                state.player.export_session()
                            });
                        }
                        let _ = observer_tx.send(UiEvent::Position { seconds, duration });
                    }
                    PlayerEvent::Listen(rec) => {
                        if let Some(state) = CORE.get()
                            && let Err(e) = state.library.record_listen_event(NewListenEvent {
                                path: rec.path,
                                title: rec.title,
                                artist: rec.artist,
                                duration_ms: rec.duration_ms,
                                started_at: rec.started_at,
                                ended_at: rec.ended_at,
                                listened_ms: rec.listened_ms,
                                completed: rec.completed,
                                skipped: rec.skipped,
                            })
                        {
                            log::warn!("failed to record listen event: {e}");
                        }
                    }
                    PlayerEvent::Error(message) => {
                        let _ = observer_tx.send(UiEvent::Error(message));
                    }
                }
            }),
        ));

        player.restore_session(session.load());

        #[cfg(not(target_os = "android"))]
        let media_keys = {
            #[cfg(target_os = "windows")]
            let hwnd = find_process_hwnd();
            #[cfg(not(target_os = "windows"))]
            let hwnd = None;
            media_keys::create(hwnd, &player)
        };

        let progress_tx = event_tx.clone();
        let changed_tx = event_tx.clone();
        let library = Arc::new(
            Library::open(
                &data_path.join("library.sqlite3"),
                &cache_path.join("covers"),
                Hooks {
                    on_progress: Box::new(move |p| {
                        let _ = progress_tx.send(UiEvent::ScanProgress {
                            scanned: p.scanned,
                            total: 0,
                            done: p.done,
                        });
                    }),
                    on_changed: Box::new(move |_version| {
                        if let Some(state) = CORE.get() {
                            state.sync.library_changed();
                        }
                        let _ = changed_tx.send(UiEvent::LibraryChanged);
                    }),
                },
            )
            .map_err(|e| format!("failed to open library: {e}"))?
            .with_user_images_dir(data_path.join("images")),
        );

        let wanted_profile = ProfileId(session.active_profile());
        if let Err(e) = library.set_active_profile(wanted_profile) {
            log::warn!(
                "profile {} not found ({e}); using the first one",
                wanted_profile.0
            );
            session.adopt_active_profile(library.active_profile().0);
        }

        let profile_lock = AtomicBool::new(
            library
                .profile_has_pin(library.active_profile())
                .unwrap_or(false),
        );

        if import_outcome.as_ref().is_some_and(|o| o.applied) {
            match library.folder_status() {
                Ok(folders) => {
                    library.keep_missing_on_next_scan(folders.iter().map(|f| f.id));
                    library.start_scan(
                        folders
                            .into_iter()
                            .filter(|f| f.reachable)
                            .map(|f| FolderInfo {
                                id: f.id,
                                path: f.path,
                            })
                            .collect(),
                    );
                }
                Err(e) => log::warn!("could not list folders after backup import: {e}"),
            }
        }

        let backup = Arc::new(BackupState::new(data_path.clone(), import_outcome));

        match library.repair_missing_covers() {
            Ok(folders) if !folders.is_empty() => library.start_scan(folders),
            Ok(_) => {}
            Err(e) => log::warn!("could not check album covers: {e}"),
        }

        let lyrics = Arc::new(
            LyricsService::new(&cache_path.join("lyrics"))
                .map_err(|e| format!("failed to open lyrics cache: {e}"))?
                .with_net_policy(session.net_policy()),
        );

        let metadata = Arc::new(
            MetadataService::new()
                .map_err(|e| format!("failed to create metadata service: {e}"))?
                .with_net_policy(session.net_policy()),
        );

        let default_download_dir = default_music_dir()
            .map(PathBuf::from)
            .unwrap_or_else(|| data_path.join("Downloads"))
            .join("NeoModern");
        let downloads_tx = event_tx.clone();
        let online = OnlineService::new(
            cache_path.join("online-covers"),
            default_download_dir,
            Arc::new(move |_jobs| {
                let _ = downloads_tx.send(UiEvent::DownloadsChanged);
            }),
            session.net_policy(),
        )
        .with_artist_images_dir(library.artist_images_dir());
        #[cfg(not(target_os = "android"))]
        let online = online.with_tools_dir(data_path.join("tools"));
        let online = Arc::new(online);

        let sync = SyncService::new(
            Arc::clone(&library),
            Some(Arc::clone(&player)),
            remote_feed,
            Arc::new(CoreEventSink {
                event_tx: event_tx.clone(),
            }),
            SyncConfig {
                port: link::DEFAULT_PORT,
                server: cfg!(not(target_os = "android")),
                default_name: default_device_name(),
                backup_dir: data_path.join("sync-backups"),
            },
        );

        let source_config_path = data_path.join("source_providers.json");
        let configs = load_provider_configs(&source_config_path);
        let source_registry = Arc::new(ProviderRegistry::new());
        for cfg in &configs {
            if cfg.enabled {
                match build_provider(cfg, session.net_policy()) {
                    Ok(p) => {
                        source_registry.register(p);
                    }
                    Err(e) => {
                        log::warn!("skipping invalid source provider {}: {e}", cfg.id);
                    }
                }
            }
        }

        let ui_prefs_path = data_path.join("ui_prefs.json");
        let loaded_ui_prefs = load_ui_prefs(&ui_prefs_path);

        let allow_phones = session.allow_phone_connections();
        let party_enabled = session.jam_enabled();
        let sync_clone = sync.clone();
        #[cfg(not(target_os = "android"))]
        let auto_backup_args = (
            Arc::clone(&backup),
            Arc::clone(&session),
            Arc::clone(&library),
            Arc::clone(&player),
        );

        let state = Arc::new(CoreState {
            data_dir: data_path,
            player: Arc::clone(&player),
            library,
            session,
            backup,
            lyrics,
            metadata,
            online,
            sync,
            profile_lock,
            source_config_path,
            source_configs: Mutex::new(configs),
            source_registry,
            cover_colors: Mutex::new(HashMap::new()),
            metadata_proposals: Mutex::new(HashMap::new()),
            track_metadata_proposals: Mutex::new(HashMap::new()),
            ui_prefs_path,
            ui_prefs: Mutex::new(loaded_ui_prefs),
            #[cfg(not(target_os = "android"))]
            media_keys,
            #[cfg(target_os = "android")]
            android_engine_tx,
            #[cfg(target_os = "android")]
            android_slots,
            event_tx,
        });
        let _ = CORE.set(state);

        let worker = Arc::clone(&player);
        std::thread::Builder::new()
            .name("engine-events".into())
            .spawn(move || {
                while let Ok(ev) = engine_rx.recv() {
                    worker.handle_engine_event(ev);
                }
            })
            .map_err(|e| format!("failed to start engine-events thread: {e}"))?;

        (
            player,
            sync_clone,
            allow_phones,
            party_enabled,
            #[cfg(not(target_os = "android"))]
            auto_backup_args,
        )
    };

    #[cfg(not(target_os = "android"))]
    let (player, sync, allow_phones, party_enabled, auto_backup_args) = startup;
    #[cfg(target_os = "android")]
    let (player, sync, allow_phones, party_enabled) = startup;

    #[cfg(not(target_os = "android"))]
    {
        let (backup_state, auto_session, auto_library, auto_player) = auto_backup_args;
        let save_session_cb = Arc::clone(&auto_session);
        backup_auto::spawn_auto_backup(
            backup_state,
            auto_session,
            auto_library,
            Arc::new(move || {
                save_session_cb.save_now(&auto_player.export_session());
            }),
        );
    }

    tokio::spawn(async move {
        sync.start(allow_phones).await;
        if party_enabled && let Err(e) = sync.jam_set_enabled(true).await {
            log::info!("party queue: {e}");
        }
    });

    Ok(player.snapshot().into())
}

pub async fn subscribe_events(sink: StreamSink<UiEvent>) -> Result<(), String> {
    let state = core()?;
    let mut rx = state.event_tx.subscribe();
    loop {
        match rx.recv().await {
            Ok(ev) => {
                if sink.add(ev).is_err() {
                    break;
                }
            }
            Err(broadcast::error::RecvError::Lagged(skipped)) => {
                log::debug!("ui event stream lagged by {skipped} events");
                let snap = state.player.snapshot().into();
                if sink.add(UiEvent::State(snap)).is_err() {
                    break;
                }
            }
            Err(broadcast::error::RecvError::Closed) => break,
        }
    }
    Ok(())
}

pub async fn subscribe_android_audio_cmds(
    sink: StreamSink<UiAndroidAudioCmd>,
) -> Result<(), String> {
    let (sub_id, mut rx) = crate::android_engine::subscribe_cmds();
    while let Some(cmd) = rx.recv().await {
        if sink.add(cmd).is_err() {
            break;
        }
    }
    crate::android_engine::unsubscribe_cmds(sub_id);
    Ok(())
}

pub fn android_audio_report_event(event: UiAndroidAudioEvent) -> Result<(), String> {
    #[cfg(target_os = "android")]
    {
        let state = core()?;
        match &event {
            UiAndroidAudioEvent::TrackStarted {
                path,
                auto_advanced,
            } if *auto_advanced => {
                if let Ok(mut slots) = state.android_slots.lock() {
                    slots.0 = Some(PathBuf::from(path));
                }
            }
            UiAndroidAudioEvent::Idle => {
                if let Ok(mut slots) = state.android_slots.lock() {
                    *slots = (None, None);
                }
            }
            _ => {}
        }
        match crate::android_engine::translate_event(event) {
            crate::android_engine::BridgeAction::Engine(events) => {
                for ev in events {
                    state
                        .android_engine_tx
                        .send(ev)
                        .map_err(|_| "audio engine event loop stopped".to_string())?;
                }
            }
            crate::android_engine::BridgeAction::MediaPlay => {
                state.player.play().map_err(|e| e.to_string())?;
            }
            crate::android_engine::BridgeAction::MediaPause => {
                state.player.pause().map_err(|e| e.to_string())?;
            }
            crate::android_engine::BridgeAction::MediaToggle => {
                state.player.toggle_pause().map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = event;
        Ok(())
    }
}

pub fn player_snapshot() -> Result<UiPlayerSnapshot, String> {
    Ok(core()?.player.snapshot().into())
}

pub fn player_play_tracks(
    paths: Vec<String>,
    start_index: u32,
    context: Option<String>,
) -> Result<UiPlayerSnapshot, String> {
    let state = core()?;
    let tracks = build_tracks(&state.library, paths);
    state
        .player
        .replace_queue_from(tracks, start_index as usize, context)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn player_play_index(index: u32) -> Result<UiPlayerSnapshot, String> {
    core()?
        .player
        .play_index(index as usize)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn player_toggle_pause() -> Result<UiPlayerSnapshot, String> {
    core()?
        .player
        .toggle_pause()
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn player_next() -> Result<UiPlayerSnapshot, String> {
    core()?
        .player
        .next()
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn player_previous() -> Result<UiPlayerSnapshot, String> {
    core()?
        .player
        .previous()
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn player_seek(seconds: f64) -> Result<UiPlayerSnapshot, String> {
    core()?
        .player
        .seek(seconds)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn player_set_volume(percent: f64) -> Result<UiPlayerSnapshot, String> {
    core()?
        .player
        .set_volume(percent)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn player_set_shuffle(enabled: bool) -> Result<UiPlayerSnapshot, String> {
    core()?
        .player
        .set_shuffle(enabled)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn player_set_repeat(mode: String) -> Result<UiPlayerSnapshot, String> {
    let repeat = match mode.as_str() {
        "off" => RepeatMode::Off,
        "all" => RepeatMode::All,
        "one" => RepeatMode::One,
        other => return Err(format!("invalid repeat mode: {other}")),
    };
    core()?
        .player
        .set_repeat(repeat)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn player_set_replaygain(mode: String) -> Result<UiPlayerSnapshot, String> {
    let rg = match mode.as_str() {
        "off" => ReplayGain::Off,
        "track" => ReplayGain::Track,
        "album" => ReplayGain::Album,
        other => return Err(format!("invalid replaygain mode: {other}")),
    };
    core()?
        .player
        .set_replaygain(rg)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn player_set_gapless(enabled: bool) -> Result<UiPlayerSnapshot, String> {
    core()?
        .player
        .set_gapless(enabled)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn player_set_wasapi_exclusive(enabled: bool) -> Result<UiPlayerSnapshot, String> {
    core()?
        .player
        .set_wasapi_exclusive(enabled)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn player_set_equalizer(
    enabled: bool,
    preamp_db: f64,
    gains_db: Vec<f64>,
) -> Result<UiPlayerSnapshot, String> {
    let mut gains = [0.0f64; 10];
    for (dst, src) in gains.iter_mut().zip(gains_db) {
        *dst = src;
    }
    let eq = Equalizer {
        enabled,
        preamp_db,
        gains_db: gains,
    };
    core()?
        .player
        .set_equalizer(eq)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn player_set_crossfade(seconds: f64) -> Result<UiPlayerSnapshot, String> {
    core()?
        .player
        .set_crossfade(seconds)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn player_set_sleep_timer(
    minutes: Option<f64>,
    end_of_track: bool,
) -> Result<UiPlayerSnapshot, String> {
    core()?
        .player
        .set_sleep_timer(minutes, end_of_track)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn settings_get_offline() -> Result<bool, String> {
    Ok(core()?.session.offline_mode())
}

pub fn settings_set_offline(offline: bool) -> Result<(), String> {
    let state = core()?;
    state.session.set_offline_mode(offline);
    state.session.save_now(&state.player.export_session());
    Ok(())
}

pub fn queue_page(offset: u32, limit: u32) -> Result<Vec<UiTrackInfo>, String> {
    Ok(core()?
        .player
        .queue_page(offset as usize, limit as usize)
        .into_iter()
        .map(Into::into)
        .collect())
}

pub fn queue_enqueue(paths: Vec<String>) -> Result<UiPlayerSnapshot, String> {
    let state = core()?;
    let tracks = build_tracks(&state.library, paths);
    state
        .player
        .enqueue(tracks)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn queue_enqueue_many(paths: Vec<String>) -> Result<UiPlayerSnapshot, String> {
    queue_enqueue(paths)
}

pub fn queue_insert_next(paths: Vec<String>) -> Result<UiPlayerSnapshot, String> {
    let state = core()?;
    let tracks = build_tracks(&state.library, paths);
    state
        .player
        .insert_next_many(tracks)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn queue_remove(index: u32) -> Result<UiPlayerSnapshot, String> {
    core()?
        .player
        .remove(index as usize)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn queue_move(from: u32, to: u32) -> Result<UiPlayerSnapshot, String> {
    core()?
        .player
        .move_entry(from as usize, to as usize)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn queue_clear_queued() -> Result<UiPlayerSnapshot, String> {
    core()?
        .player
        .clear_queued()
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn library_folders() -> Result<Vec<UiFolderInfo>, String> {
    core()?
        .library
        .folders()
        .map(|v| v.into_iter().map(Into::into).collect())
        .map_err(|e| e.to_string())
}

pub fn library_add_folder(path: String) -> Result<Vec<UiFolderInfo>, String> {
    let lib = &core()?.library;
    let id = lib.add_folder(&path).map_err(|e| e.to_string())?;
    let folders = lib.folders().map_err(|e| e.to_string())?;
    let to_scan: Vec<FolderInfo> = folders.iter().filter(|f| f.id == id).cloned().collect();
    if !to_scan.is_empty() {
        lib.start_scan(to_scan);
    }
    Ok(folders.into_iter().map(Into::into).collect())
}

pub fn library_remove_folder(id: i64) -> Result<Vec<UiFolderInfo>, String> {
    let lib = &core()?.library;
    lib.remove_folder(id).map_err(|e| e.to_string())?;
    lib.folders()
        .map(|v| v.into_iter().map(Into::into).collect())
        .map_err(|e| e.to_string())
}

pub fn library_scan() -> Result<(), String> {
    let lib = &core()?.library;
    let folders = lib.folders().map_err(|e| e.to_string())?;
    lib.start_scan(folders);
    Ok(())
}

pub fn library_is_scanning() -> Result<bool, String> {
    Ok(core()?.library.is_scanning())
}

pub fn library_tracks_page(
    offset: u32,
    limit: u32,
    search: Option<String>,
) -> Result<Vec<UiTrackRow>, String> {
    let lib = &core()?.library;
    let page = lib
        .search_tracks_page(
            u64::from(offset),
            u64::from(limit),
            SortSpec::parse("artist", None),
            search.as_deref().unwrap_or(""),
        )
        .map_err(|e| e.to_string())?;
    Ok(page.items.into_iter().map(Into::into).collect())
}

pub fn library_albums_page(
    offset: u32,
    limit: u32,
    search: Option<String>,
) -> Result<Vec<UiAlbumRow>, String> {
    let lib = &core()?.library;
    let page = lib
        .search_albums_page(
            u64::from(offset),
            u64::from(limit),
            search.as_deref().unwrap_or(""),
        )
        .map_err(|e| e.to_string())?;
    Ok(page.items.into_iter().map(Into::into).collect())
}

pub fn library_album_count(search: Option<String>) -> Result<u32, String> {
    let lib = &core()?.library;
    let page = lib
        .search_albums_page(0, 1, search.as_deref().unwrap_or(""))
        .map_err(|e| e.to_string())?;
    Ok(u32::try_from(page.total).unwrap_or(u32::MAX))
}

pub fn library_album_detail(album_id: i64) -> Result<Option<UiAlbumDetail>, String> {
    let state = core()?;
    let lib = &state.library;
    if lib
        .album_info(album_id)
        .map_err(|e| e.to_string())?
        .is_none()
    {
        return Ok(None);
    }
    let detail = lib.album(album_id).map_err(|e| e.to_string())?;
    let mut ui_detail: UiAlbumDetail = detail.into();
    if ui_detail.album.cover_color.is_none()
        && let Some(cover) = ui_detail.album.cover.as_deref()
    {
        ui_detail.album.cover_color = compute_and_cache_cover_color(state, cover);
    }
    Ok(Some(ui_detail))
}

pub fn cover_color_for_path(path: String) -> Result<Option<u32>, String> {
    let state = core()?;
    Ok(compute_and_cache_cover_color(state, &path))
}

pub fn library_track_count(search: Option<String>) -> Result<u32, String> {
    let lib = &core()?.library;
    let page = lib
        .search_tracks_page(
            0,
            1,
            SortSpec::parse("artist", None),
            search.as_deref().unwrap_or(""),
        )
        .map_err(|e| e.to_string())?;
    Ok(u32::try_from(page.total).unwrap_or(u32::MAX))
}

pub fn library_track_cover(path: String) -> Result<Option<String>, String> {
    let state = core()?;
    let local = state
        .library
        .track_cover(&path)
        .map_err(|e| e.to_string())?;
    if local.is_some() {
        return Ok(local);
    }
    Ok(state.online.stream_cover(&path))
}

pub fn library_play_all(
    start_index: u32,
    search: Option<String>,
) -> Result<UiPlayerSnapshot, String> {
    let state = core()?;
    let tracks = state
        .library
        .matching_tracks(
            SortSpec::parse("artist", None),
            search.as_deref().unwrap_or(""),
        )
        .map_err(|e| e.to_string())?;
    state
        .player
        .replace_queue(tracks, start_index as usize)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn library_play_album(
    album_id: i64,
    start_index: u32,
    shuffle: bool,
) -> Result<UiPlayerSnapshot, String> {
    let state = core()?;
    let tracks = state
        .library
        .album_tracks(album_id)
        .map_err(|e| e.to_string())?;
    if shuffle {
        let _ = state.player.set_shuffle(true);
    }
    state
        .player
        .replace_queue_from(
            tracks,
            start_index as usize,
            Some(format!("album:{album_id}")),
        )
        .map(Into::into)
        .map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------
// Home & Dynamic Mixes
// ---------------------------------------------------------------------

pub fn library_home() -> Result<UiHomeFeed, String> {
    core()?
        .library
        .home_feed()
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn library_home_mix_detail(mix_id: String) -> Result<Option<UiHomeMixDetail>, String> {
    core()?
        .library
        .home_mix_detail(&mix_id)
        .map(|opt| opt.map(Into::into))
        .map_err(|e| e.to_string())
}

pub fn library_play_home_mix(mix_id: String) -> Result<UiPlayerSnapshot, String> {
    library_play_home_mix_from(mix_id, None)
}

pub fn library_play_home_mix_from(
    mix_id: String,
    start_path: Option<String>,
) -> Result<UiPlayerSnapshot, String> {
    let state = core()?;
    let tracks = state
        .library
        .home_mix_queue_tracks(&mix_id)
        .map_err(|e| e.to_string())?;
    let start = neomodern_core::library::db::resolve_mix_start(&tracks, start_path.as_deref())?;
    state
        .player
        .replace_queue_from(tracks, start, Some(format!("mix:{mix_id}")))
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn library_save_home_mix(mix_id: String, name: String) -> Result<UiPlaylistInfo, String> {
    core()?
        .library
        .save_mix_as_playlist(&mix_id, &name)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------
// Favorites (Star)
// ---------------------------------------------------------------------

pub fn favorites_list() -> Result<Vec<i64>, String> {
    core()?
        .library
        .favorites()
        .map(|v| v.into_iter().map(|f| f.track_id).collect())
        .map_err(|e| e.to_string())
}

pub fn favorites_tracks() -> Result<Vec<UiTrackRow>, String> {
    let lib = &core()?.library;
    let mut out = Vec::new();
    let mut offset = 0u64;
    let page_size = 500u64;
    loop {
        let page = lib
            .favorites_page(offset, page_size)
            .map_err(|e| e.to_string())?;
        let fetched = page.items.len() as u64;
        out.extend(page.items.into_iter().map(Into::into));
        offset += fetched;
        if fetched == 0 || offset >= page.total {
            break;
        }
    }
    Ok(out)
}

pub fn favorites_toggle(track_id: i64) -> Result<bool, String> {
    core()?
        .library
        .toggle_favorite(track_id)
        .map_err(|e| e.to_string())
}

pub fn favorites_toggle_by_path(path: String) -> Result<bool, String> {
    core()?
        .library
        .toggle_favorite_by_path(&path)
        .map_err(|e| e.to_string())
}

pub fn favorites_set_many(track_ids: Vec<i64>, favorite: bool) -> Result<(), String> {
    core()?
        .library
        .set_favorites(&track_ids, favorite)
        .map(|_| ())
        .map_err(|e| e.to_string())
}

pub fn favorites_play(start_index: u32) -> Result<UiPlayerSnapshot, String> {
    let state = core()?;
    let tracks = state
        .library
        .favorites_queue_tracks()
        .map_err(|e| e.to_string())?;
    state
        .player
        .replace_queue_from(tracks, start_index as usize, Some("favorites".into()))
        .map(Into::into)
        .map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------
// Playlists
// ---------------------------------------------------------------------

pub fn playlists_list() -> Result<Vec<UiPlaylistInfo>, String> {
    core()?
        .library
        .playlists()
        .map(|v| v.into_iter().map(Into::into).collect())
        .map_err(|e| e.to_string())
}

pub fn playlists_create(name: String) -> Result<UiPlaylistInfo, String> {
    core()?
        .library
        .create_playlist(&name, &[])
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn playlists_rename(id: i64, name: String) -> Result<(), String> {
    core()?
        .library
        .rename_playlist(id, &name)
        .map_err(|e| e.to_string())
}

pub fn playlists_delete(id: i64) -> Result<(), String> {
    core()?
        .library
        .delete_playlist(id)
        .map_err(|e| e.to_string())
}

pub fn playlists_tracks(id: i64) -> Result<Vec<UiTrackRow>, String> {
    let lib = &core()?.library;
    let mut out = Vec::new();
    let mut offset = 0u64;
    let limit = 1000u64;
    loop {
        let batch = lib
            .playlist_tracks(id, offset, limit)
            .map_err(|e| e.to_string())?;
        let count = batch.len() as u64;
        out.extend(batch.into_iter().map(Into::into));
        if count < limit {
            break;
        }
        offset += count;
    }
    Ok(out)
}

pub fn playlists_add_tracks(id: i64, track_ids: Vec<i64>) -> Result<(), String> {
    core()?
        .library
        .playlist_add_tracks(id, &track_ids)
        .map(|_| ())
        .map_err(|e| e.to_string())
}

pub fn playlists_remove_track(id: i64, position: u32) -> Result<(), String> {
    core()?
        .library
        .playlist_remove(id, &[position as usize])
        .map_err(|e| e.to_string())
}

pub fn playlists_move_track(playlist_id: i64, from: u32, to: u32) -> Result<(), String> {
    core()?
        .library
        .playlist_move(playlist_id, from as usize, to as usize)
        .map_err(|e| e.to_string())
}

pub fn playlists_set_cover(
    playlist_id: i64,
    mode: String,
    value: Option<String>,
) -> Result<(), String> {
    let lib = &core()?.library;
    match mode.trim() {
        "auto" => lib
            .clear_playlist_cover(playlist_id)
            .map_err(|e| e.to_string()),
        "gradient" => {
            let raw = value
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| "gradient preset value is required".to_string())?;
            let preset = if raw.starts_with("preset:") {
                raw.to_owned()
            } else {
                format!("preset:{raw}")
            };
            lib.set_playlist_cover_preset(playlist_id, &preset)
                .map_err(|e| e.to_string())
        }
        "image" => {
            let path = value
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| "image path is required".to_string())?;
            lib.set_playlist_cover_file(playlist_id, Path::new(path))
                .map_err(|e| e.to_string())
        }
        other => Err(format!("invalid playlist cover mode: {other}")),
    }
}

pub fn playlists_export_m3u(playlist_id: i64, dest_path: String) -> Result<u32, String> {
    let dest = dest_path.trim();
    if dest.is_empty() {
        return Err("destination path must not be empty".to_string());
    }
    let lib = &core()?.library;
    let rows = lib
        .playlist_tracks(playlist_id, 0, u32::MAX as u64)
        .map_err(|e| e.to_string())?;
    let count = u32::try_from(rows.len()).unwrap_or(u32::MAX);
    let rendered = m3u::render(&rows);
    let out_path = Path::new(dest);
    if let Some(parent) = out_path.parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    std::fs::write(out_path, rendered).map_err(|e| format!("could not write {dest}: {e}"))?;
    Ok(count)
}

pub fn playlists_import_m3u(src_path: String, name: String) -> Result<UiPlaylistInfo, String> {
    let src = src_path.trim();
    if src.is_empty() {
        return Err("source path must not be empty".to_string());
    }
    let path = Path::new(src);
    let bytes = std::fs::read(path).map_err(|e| format!("could not read {src}: {e}"))?;
    let text = String::from_utf8_lossy(&bytes);
    let playlist_name = if name.trim().is_empty() {
        path.file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| "Imported".to_string())
    } else {
        name.trim().to_string()
    };
    let imported = core()?
        .library
        .import_m3u(&playlist_name, &text, path.parent())
        .map_err(|e| e.to_string())?;
    Ok(imported.playlist.into())
}

pub fn playlists_play(id: i64, start_index: u32) -> Result<UiPlayerSnapshot, String> {
    let state = core()?;
    let tracks = state
        .library
        .playlist_queue_tracks(id)
        .map_err(|e| e.to_string())?;
    state
        .player
        .replace_queue_from(tracks, start_index as usize, Some(format!("playlist:{id}")))
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn playlists_play_shuffled(id: i64) -> Result<UiPlayerSnapshot, String> {
    let state = core()?;
    let tracks = state
        .library
        .playlist_queue_tracks(id)
        .map_err(|e| e.to_string())?;
    let _ = state.player.set_shuffle(true);
    state
        .player
        .replace_queue_from(tracks, 0, Some(format!("playlist:{id}")))
        .map(Into::into)
        .map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------
// Artists
// ---------------------------------------------------------------------

pub fn library_artist_count(search: Option<String>) -> Result<u32, String> {
    let lib = &core()?.library;
    let page = lib
        .search_artists_page(0, 1, search.as_deref().unwrap_or(""))
        .map_err(|e| e.to_string())?;
    Ok(u32::try_from(page.total).unwrap_or(u32::MAX))
}

pub fn library_artists_page(
    offset: u32,
    limit: u32,
    search: Option<String>,
) -> Result<Vec<UiArtistRow>, String> {
    let lib = &core()?.library;
    let page = lib
        .search_artists_page(
            u64::from(offset),
            u64::from(limit),
            search.as_deref().unwrap_or(""),
        )
        .map_err(|e| e.to_string())?;
    Ok(page.items.into_iter().map(Into::into).collect())
}

pub fn library_artist_detail(name: String) -> Result<Option<UiArtistDetail>, String> {
    let lib = &core()?.library;
    let profile = lib.artist_profile(&name).map_err(|e| e.to_string())?;
    if profile.track_count == 0 && profile.album_count == 0 {
        return Ok(None);
    }
    Ok(Some(profile.into()))
}

pub fn library_play_artist(name: String, shuffle: bool) -> Result<UiPlayerSnapshot, String> {
    library_play_artist_from(name, 0, shuffle)
}

pub fn library_play_artist_from(
    name: String,
    start_index: u32,
    shuffle: bool,
) -> Result<UiPlayerSnapshot, String> {
    let state = core()?;
    let tracks = state
        .library
        .artist_tracks(&name)
        .map_err(|e| e.to_string())?;
    if shuffle {
        let _ = state.player.set_shuffle(true);
    }
    let context = Some(format!("artist:{}", name.to_lowercase()));
    state
        .player
        .replace_queue_from(tracks, start_index as usize, context)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

fn prefer_turkish_bio(state: &CoreState) -> bool {
    state
        .ui_prefs
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .language
        == "tr"
}

pub async fn artist_enrich(name: String) -> Result<Option<UiArtistDetail>, String> {
    let state = core()?;
    let prefer_tr = prefer_turkish_bio(state);
    let info = state
        .online
        .artist_info(&state.library, &name, prefer_tr)
        .await?;
    let profile = state
        .library
        .artist_profile(&name)
        .map_err(|e| e.to_string())?;
    if profile.track_count == 0
        && profile.album_count == 0
        && info.image.is_none()
        && info.bio.is_none()
        && info.albums.is_empty()
    {
        return Ok(None);
    }
    let mut detail: UiArtistDetail = profile.into();
    if detail.image.is_none() {
        detail.image = info.image;
    }
    if detail.bio.is_none() {
        detail.bio = info.bio;
    }
    detail.cover = detail
        .image
        .clone()
        .or_else(|| detail.fallback_cover.clone());
    detail.online_albums = info.albums.into_iter().map(Into::into).collect();
    Ok(Some(detail))
}

pub async fn artist_enrich_all() -> Result<UiArtistScanProgress, String> {
    let state = core()?;
    let lib = Arc::clone(&state.library);
    let online = Arc::clone(&state.online);
    let prefer_tr = prefer_turkish_bio(state);
    let lib_tx = state.event_tx.clone();
    let on_library_changed: Arc<dyn Fn(u64) + Send + Sync> = Arc::new(move |_version| {
        if let Some(s) = CORE.get() {
            s.sync.library_changed();
        }
        let _ = lib_tx.send(UiEvent::LibraryChanged);
    });
    let scan_tx = state.event_tx.clone();
    let on_artist_scan: Arc<dyn Fn(ArtistScanProgress) + Send + Sync> = Arc::new(move |progress| {
        let _ = scan_tx.send(UiEvent::ArtistScanProgress {
            running: progress.scanning,
            total: progress.total,
            done: progress.done,
            current: progress.current_artist,
            error: progress.error,
        });
    });
    let progress = tokio::task::spawn_blocking(move || {
        online.start_artist_scan(lib, false, prefer_tr, on_library_changed, on_artist_scan)
    })
    .await
    .map_err(|e| e.to_string())??;
    Ok(progress.into())
}

pub fn artist_enrich_status() -> Result<UiArtistScanProgress, String> {
    Ok(core()?.online.artist_scan_status().into())
}

pub fn artist_enrich_cancel() -> Result<(), String> {
    core()?.online.cancel_artist_scan();
    Ok(())
}

// ---------------------------------------------------------------------
// Genres
// ---------------------------------------------------------------------

fn genre_row_to_ui(lib: &Library, row: GenreRow) -> UiGenreInfo {
    let album_count = lib
        .genre_detail(&row.name)
        .ok()
        .and_then(|d| u32::try_from(d.albums.len()).ok())
        .unwrap_or(0);
    UiGenreInfo {
        name: row.name,
        track_count: row.track_count,
        album_count,
        cover_path: row.cover,
    }
}

pub fn library_genres() -> Result<Vec<UiGenreInfo>, String> {
    let lib = &core()?.library;
    let rows = lib.genres().map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|row| genre_row_to_ui(lib, row))
        .collect())
}

pub fn library_genre_detail(genre: String) -> Result<UiGenreDetail, String> {
    let lib = &core()?.library;
    let detail = lib.genre_detail(&genre).map_err(|e| e.to_string())?;
    let cover_path = detail.albums.iter().find_map(|a| a.cover.clone());
    let album_count = u32::try_from(detail.albums.len()).unwrap_or(u32::MAX);
    Ok(UiGenreDetail {
        name: detail.name,
        track_count: detail.track_count,
        album_count,
        total_duration_ms: detail.duration_ms,
        cover_path,
        albums: detail.albums.into_iter().map(Into::into).collect(),
    })
}

pub fn library_genre_tracks_page(
    genre: String,
    offset: u32,
    limit: u32,
) -> Result<Vec<UiTrackRow>, String> {
    let lib = &core()?.library;
    let page = lib
        .genre_tracks_page(&genre, u64::from(offset), u64::from(limit).min(1000))
        .map_err(|e| e.to_string())?;
    Ok(page.items.into_iter().map(Into::into).collect())
}

pub fn library_play_genre(
    genre: String,
    shuffle: bool,
    start_index: u32,
) -> Result<UiPlayerSnapshot, String> {
    let state = core()?;
    let tracks = state
        .library
        .genre_tracks(&genre)
        .map_err(|e| e.to_string())?;
    if shuffle {
        let _ = state.player.set_shuffle(true);
    }
    let context = Some(format!("genre:{}", genre.to_lowercase()));
    state
        .player
        .replace_queue_from(tracks, start_index as usize, context)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------
// Lyrics
// ---------------------------------------------------------------------

fn map_lyrics_result(result: LyricsResult) -> UiLyrics {
    match result {
        LyricsResult::Synced { source, lines } => UiLyrics {
            found: true,
            is_instrumental: false,
            synced_lines: lines
                .into_iter()
                .map(|l| UiSyncedLine {
                    time_ms: (l.time_seconds * 1000.0).round() as i64,
                    text: l.text,
                })
                .collect(),
            plain_text: None,
            source: Some(source_label(source)),
        },
        LyricsResult::Plain { source, lines } => UiLyrics {
            found: true,
            is_instrumental: false,
            synced_lines: Vec::new(),
            plain_text: Some(lines.join("\n")),
            source: Some(source_label(source)),
        },
        LyricsResult::Instrumental { source } => UiLyrics {
            found: true,
            is_instrumental: true,
            synced_lines: Vec::new(),
            plain_text: None,
            source: Some(source_label(source)),
        },
        LyricsResult::NotFound => UiLyrics {
            found: false,
            is_instrumental: false,
            synced_lines: Vec::new(),
            plain_text: None,
            source: None,
        },
    }
}

async fn lyrics_for_track_inner(
    path: String,
    title: String,
    artist: String,
    duration_secs: Option<f64>,
    force: bool,
) -> Result<UiLyrics, String> {
    let state = core()?;
    let lib = Arc::clone(&state.library);
    let lyrics = Arc::clone(&state.lyrics);
    let opts = LyricsOptions::new(
        state.session.lyrics_save(),
        state.session.lyrics_netease() && state.session.net_allowed(Feature::Lyrics),
        state.player.current_path(),
    )
    .with_queue_meta(Some((title, artist)));

    let result = lyrics
        .for_track_with(lib, path, duration_secs, force, &opts)
        .await
        .map_err(|e| e.to_string())?;

    Ok(map_lyrics_result(result))
}

pub async fn lyrics_for_track(
    path: String,
    title: String,
    artist: String,
    _album: String,
    duration_secs: Option<f64>,
) -> Result<UiLyrics, String> {
    lyrics_for_track_inner(path, title, artist, duration_secs, false).await
}

pub async fn lyrics_for_track_refresh(
    path: String,
    title: String,
    artist: String,
    _album: String,
    duration_secs: Option<f64>,
) -> Result<UiLyrics, String> {
    lyrics_for_track_inner(path, title, artist, duration_secs, true).await
}

pub fn lyrics_save_lrc(track_path: String, content: String) -> Result<String, String> {
    if content.trim().is_empty() {
        return Err("lyrics content must not be empty".to_string());
    }
    let audio = Path::new(track_path.trim());
    if track_path.trim().is_empty() || is_stream_url(audio) {
        return Err("cannot save .lrc for this track path".to_string());
    }
    let _wrote = lyrics_save::save(SaveMode::Sidecar, audio, &content)?;
    let lower = audio.with_extension("lrc");
    let upper = audio.with_extension("LRC");
    let dest = if lower.exists() || !upper.exists() {
        lower
    } else {
        upper
    };
    Ok(scan::display_path(&dest))
}

pub async fn lyrics_save_cached() -> Result<UiBulkSaveOutcome, String> {
    let state = core()?;
    let lib = Arc::clone(&state.library);
    let lyrics = Arc::clone(&state.lyrics);
    let mode = state.session.lyrics_save();
    let current = state.player.current_path();
    let outcome = tokio::task::spawn_blocking(move || {
        lyrics.save_cached_blocking(&lib, mode, current.as_deref())
    })
    .await
    .map_err(|e| e.to_string())?;
    Ok(outcome.into())
}

pub async fn lyrics_attach_file(audio_path: String, lrc_path: String) -> Result<UiLyrics, String> {
    let state = core()?;
    let lib = Arc::clone(&state.library);
    let result = tokio::task::spawn_blocking(move || {
        if find_track_id_for_path(&lib, &audio_path)?.is_none() {
            return Err("track is not in library".to_string());
        }
        attach_local_lrc(Path::new(&audio_path), Path::new(&lrc_path)).map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())??;
    Ok(map_lyrics_result(result))
}

pub async fn lyrics_coverage() -> Result<UiLyricsCoverage, String> {
    let state = core()?;
    let lib = Arc::clone(&state.library);
    let lyrics = Arc::clone(&state.lyrics);
    let coverage = tokio::task::spawn_blocking(move || lyrics.coverage_blocking(&lib))
        .await
        .map_err(|e| e.to_string())?;
    Ok(coverage.into())
}

fn share_block_label(reason: ShareBlock) -> String {
    match reason {
        ShareBlock::NoLocalLyrics => "noLocalLyrics",
        ShareBlock::NeedsMetadata => "needsMetadata",
        ShareBlock::OnLrclib => "onLrclib",
        ShareBlock::OtherSource => "otherSource",
        ShareBlock::Offline => "offline",
        ShareBlock::Busy => "busy",
    }
    .to_string()
}

fn map_share_status(status: ShareStatus) -> UiLyricsShareStatus {
    UiLyricsShareStatus {
        available: status.available,
        reason: status.reason.map(share_block_label),
        outcome: None,
    }
}

pub async fn lyrics_share_status_for(
    path: String,
    duration_seconds: Option<f64>,
) -> Result<UiLyricsShareStatus, String> {
    let state = core()?;
    let lib = Arc::clone(&state.library);
    let lyrics = Arc::clone(&state.lyrics);
    let status = lyrics
        .share_status(lib, path, duration_seconds)
        .await
        .map_err(|e| e.to_string())?;
    Ok(map_share_status(status))
}

pub async fn lyrics_share_status() -> Result<UiLyricsShareStatus, String> {
    let state = core()?;
    let snap = state.player.snapshot();
    let Some(current) = snap.current else {
        return Ok(UiLyricsShareStatus {
            available: false,
            reason: Some("noTrack".to_string()),
            outcome: None,
        });
    };
    lyrics_share_status_for(current.path, snap.duration_seconds).await
}

pub async fn lyrics_share_for(
    path: String,
    duration_seconds: Option<f64>,
) -> Result<UiLyricsShareStatus, String> {
    let state = core()?;
    let lib = Arc::clone(&state.library);
    let lyrics = Arc::clone(&state.lyrics);
    let outcome = lyrics
        .share(lib, path, duration_seconds)
        .await
        .map_err(|e| e.to_string())?;
    Ok(match outcome {
        ShareOutcome::Published => UiLyricsShareStatus {
            available: false,
            reason: Some("onLrclib".to_string()),
            outcome: Some("published".to_string()),
        },
        ShareOutcome::Cancelled => UiLyricsShareStatus {
            available: true,
            reason: None,
            outcome: Some("cancelled".to_string()),
        },
    })
}

pub async fn lyrics_share() -> Result<UiLyricsShareStatus, String> {
    let state = core()?;
    let snap = state.player.snapshot();
    let current = snap
        .current
        .ok_or_else(|| "no track is currently playing".to_string())?;
    lyrics_share_for(current.path, snap.duration_seconds).await
}

pub fn lyrics_share_cancel() -> Result<(), String> {
    core()?.lyrics.cancel_share();
    Ok(())
}

// ---------------------------------------------------------------------
// Listening Stats (Recap)
// ---------------------------------------------------------------------

pub fn listening_stats(days: Option<u32>) -> Result<UiStatsSummary, String> {
    let lib = &core()?.library;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
        .unwrap_or(0);
    let from = days.map(|d| now.saturating_sub(i64::from(d) * 86_400));
    lib.listening_stats(from, None)
        .map(|s| stats_to_ui(s, false))
        .map_err(|e| e.to_string())
}

/// Aggregated listening statistics for the `[from_ms, to_ms)` Unix-millisecond range.
pub fn listening_stats_range(
    from_ms: Option<i64>,
    to_ms: Option<i64>,
    sort_by_plays: bool,
) -> Result<UiStatsSummary, String> {
    let lib = &core()?.library;
    let from_secs = from_ms.map(|ms| ms.div_euclid(1000));
    let to_secs = to_ms.map(|ms| ms.div_euclid(1000));
    lib.listening_stats(from_secs, to_secs)
        .map(|s| stats_to_ui(s, sort_by_plays))
        .map_err(|e| e.to_string())
}

pub fn listening_history_clear() -> Result<(), String> {
    let state = core()?;
    state
        .library
        .clear_listen_history()
        .map_err(|e| e.to_string())?;
    let _ = state.event_tx.send(UiEvent::LibraryChanged);
    Ok(())
}

// ---------------------------------------------------------------------
// Profiles & PIN (K24 / K25)
// ---------------------------------------------------------------------

fn build_profiles_state(state: &CoreState) -> Result<UiProfilesState, String> {
    let profiles = state
        .library
        .profiles()
        .map_err(|e| e.to_string())?
        .into_iter()
        .map(Into::into)
        .collect();
    Ok(UiProfilesState {
        active: state.library.active_profile().0,
        profiles,
        colors: PROFILE_COLORS.iter().map(|c| (*c).to_owned()).collect(),
        max_profiles: u32::try_from(MAX_PROFILES).unwrap_or(8),
        locked: state.profile_lock.load(Ordering::SeqCst),
    })
}

pub fn profiles_list() -> Result<UiProfilesState, String> {
    build_profiles_state(core()?)
}

pub fn profile_create(name: String) -> Result<UiProfilesState, String> {
    let state = core()?;
    if state.profile_lock.load(Ordering::SeqCst) {
        return Err("unlock the profile first".into());
    }
    state
        .library
        .create_profile(&name)
        .map_err(|e| e.to_string())?;
    build_profiles_state(state)
}

pub fn profile_rename(id: i64, name: String) -> Result<UiProfilesState, String> {
    let state = core()?;
    if state.profile_lock.load(Ordering::SeqCst) {
        return Err("unlock the profile first".into());
    }
    state
        .library
        .rename_profile(ProfileId(id), &name)
        .map_err(|e| e.to_string())?;
    build_profiles_state(state)
}

pub async fn profile_delete(id: i64) -> Result<UiProfilesState, String> {
    let state = core()?;
    if state.profile_lock.load(Ordering::SeqCst) {
        return Err("unlock the profile first".into());
    }
    state
        .library
        .delete_profile(ProfileId(id))
        .map_err(|e| e.to_string())?;
    state.sync.profile_deleted(ProfileId(id)).await?;
    state.session.forget_profile(id);
    state.session.save_now(&state.player.export_session());
    build_profiles_state(state)
}

pub async fn profile_switch(id: i64, pin: Option<String>) -> Result<UiPlayerSnapshot, String> {
    let state = core()?;
    let target = ProfileId(id);
    if state.library.active_profile() != target {
        state
            .library
            .check_profile_pin(target, pin.as_deref())
            .map_err(|e| e.to_string())?;
        if !state
            .library
            .profiles()
            .map_err(|e| e.to_string())?
            .iter()
            .any(|p| p.id == target)
        {
            return Err("no such profile".into());
        }
        let leaving = state.player.take_for_profile_switch();
        let next = state.session.switch_profile(leaving, id);
        state
            .library
            .set_active_profile(target)
            .map_err(|e| e.to_string())?;
        let snap = state.player.load_profile_state(next);
        state.profile_lock.store(false, Ordering::SeqCst);
        if let Err(e) = state.sync.profile_switched().await {
            log::warn!("sync: could not follow profile switch: {e}");
        }
        let _ = state.event_tx.send(UiEvent::State(snap.clone().into()));
        let _ = state.event_tx.send(UiEvent::SyncChanged);
        return Ok(snap.into());
    }
    if state.profile_lock.load(Ordering::SeqCst) {
        state
            .library
            .check_profile_pin(target, pin.as_deref())
            .map_err(|e| e.to_string())?;
        state.profile_lock.store(false, Ordering::SeqCst);
    }
    Ok(state.player.snapshot().into())
}

pub fn profile_set_pin(id: i64, pin: Option<String>) -> Result<UiProfilesState, String> {
    let state = core()?;
    if state.profile_lock.load(Ordering::SeqCst) {
        return Err("unlock the profile first".into());
    }
    state
        .library
        .set_profile_pin(ProfileId(id), pin.as_deref())
        .map_err(|e| e.to_string())?;
    build_profiles_state(state)
}

pub fn profile_unlock(pin: String) -> Result<UiProfilesState, String> {
    let state = core()?;
    state
        .library
        .check_profile_pin(state.library.active_profile(), Some(&pin))
        .map_err(|e| e.to_string())?;
    state.profile_lock.store(false, Ordering::SeqCst);
    build_profiles_state(state)
}

// ---------------------------------------------------------------------
// Local Network Sync & Party Queue (K21 / K23 / K27 / K29)
// ---------------------------------------------------------------------

pub async fn sync_status() -> Result<UiSyncStatus, String> {
    core()?.sync.status().await.map(Into::into)
}

pub async fn sync_set_allow_phone_connections(allow: bool) -> Result<UiSyncStatus, String> {
    let state = core()?;
    let status = state.sync.set_allow_phone_connections(allow).await?;
    state.session.set_allow_phone_connections(allow);
    state.session.save_now(&state.player.export_session());
    Ok(status.into())
}

pub async fn sync_set_device_name(name: String) -> Result<UiSyncStatus, String> {
    core()?.sync.set_device_name(&name).await.map(Into::into)
}

pub async fn sync_pair_open() -> Result<UiPairingOpen, String> {
    core()?.sync.pair_open().await.map(Into::into)
}

pub async fn sync_pair_close() -> Result<UiSyncStatus, String> {
    let state = core()?;
    state.sync.pair_close();
    state.sync.status().await.map(Into::into)
}

pub async fn sync_remove_peer(peer_id: String) -> Result<UiSyncStatus, String> {
    core()?.sync.remove_peer(&peer_id).await.map(Into::into)
}

pub async fn sync_now() -> Result<UiSyncStatus, String> {
    core()?.sync.sync_now().await.map(Into::into)
}

pub async fn party_status() -> Result<UiPartyStatus, String> {
    core()?.sync.jam_status().await.map(Into::into)
}

pub async fn party_set_enabled(enabled: bool) -> Result<UiPartyStatus, String> {
    let state = core()?;
    let status = state.sync.jam_set_enabled(enabled).await?;
    state.session.set_jam_enabled(enabled);
    state.session.save_now(&state.player.export_session());
    Ok(status.into())
}

pub async fn party_start() -> Result<UiPartyStatus, String> {
    core()?.sync.jam_start().await.map(Into::into)
}

pub async fn party_end() -> Result<UiPartyStatus, String> {
    core()?.sync.jam_end().await.map(Into::into)
}

pub async fn party_new_code() -> Result<UiPartyStatus, String> {
    core()?.sync.jam_new_code().await.map(Into::into)
}

pub async fn party_remove_guest(id: String) -> Result<UiPartyStatus, String> {
    core()?.sync.jam_remove_guest(&id).await.map(Into::into)
}

// ---------------------------------------------------------------------
// External Sources (K29 neutral SourceProvider)
// ---------------------------------------------------------------------

fn map_source_configs(configs: &[ProviderConfig]) -> Vec<UiSourceProvider> {
    configs
        .iter()
        .map(|cfg| UiSourceProvider {
            id: cfg.id.clone(),
            name: cfg.name.clone(),
            base_url: cfg.kind.display_endpoint(),
            enabled: cfg.enabled,
        })
        .collect()
}

fn generate_provider_id(name: &str, existing: &[ProviderConfig]) -> String {
    let mut slug = String::new();
    let mut prev_dash = false;
    for ch in name.chars() {
        if ch.is_ascii_alphanumeric() {
            slug.push(ch.to_ascii_lowercase());
            prev_dash = false;
        } else if !prev_dash && !slug.is_empty() {
            slug.push('-');
            prev_dash = true;
        }
    }
    let base = slug.trim_matches('-');
    let base = if base.is_empty() { "source" } else { base };
    if !existing.iter().any(|c| c.id == base) {
        return base.to_owned();
    }
    let mut n = 2usize;
    loop {
        let candidate = format!("{base}-{n}");
        if !existing.iter().any(|c| c.id == candidate) {
            return candidate;
        }
        n += 1;
    }
}

pub fn source_providers_list() -> Result<Vec<UiSourceProvider>, String> {
    let state = core()?;
    let configs = state
        .source_configs
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    Ok(map_source_configs(&configs))
}

pub fn source_provider_add(
    name: String,
    base_url: String,
) -> Result<Vec<UiSourceProvider>, String> {
    let state = core()?;
    let clean_name = name.trim().to_owned();
    if clean_name.is_empty() {
        return Err("source name must not be empty".into());
    }
    let kind = parse_provider_kind(&base_url).map_err(|e| e.to_string())?;
    let mut configs = state
        .source_configs
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let id = generate_provider_id(&clean_name, &configs);
    let new_cfg = ProviderConfig {
        id,
        name: clean_name,
        kind,
        enabled: true,
    };
    let provider = build_provider(&new_cfg, state.session.net_policy())
        .map_err(|e| e.to_string())?;
    let mut updated = configs.clone();
    updated.push(new_cfg);
    save_provider_configs(&state.source_config_path, &updated).map_err(|e| e.to_string())?;
    state.source_registry.register(provider);
    *configs = updated;
    Ok(map_source_configs(&configs))
}

pub fn source_provider_remove(id: String) -> Result<Vec<UiSourceProvider>, String> {
    let state = core()?;
    let mut configs = state
        .source_configs
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let mut updated = configs.clone();
    let before = updated.len();
    updated.retain(|c| c.id != id);
    if updated.len() == before {
        return Err("source provider not found".into());
    }
    save_provider_configs(&state.source_config_path, &updated).map_err(|e| e.to_string())?;
    state.source_registry.remove(&id);
    *configs = updated;
    Ok(map_source_configs(&configs))
}

pub fn source_provider_toggle(id: String, enabled: bool) -> Result<Vec<UiSourceProvider>, String> {
    let state = core()?;
    let mut configs = state
        .source_configs
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let mut updated = configs.clone();
    let Some(entry) = updated.iter_mut().find(|c| c.id == id) else {
        return Err("source provider not found".into());
    };
    entry.enabled = enabled;
    if enabled {
        let provider = build_provider(entry, state.session.net_policy())
            .map_err(|e| e.to_string())?;
        save_provider_configs(&state.source_config_path, &updated).map_err(|e| e.to_string())?;
        state.source_registry.register(provider);
    } else {
        save_provider_configs(&state.source_config_path, &updated).map_err(|e| e.to_string())?;
        state.source_registry.remove(&id);
    }
    *configs = updated;
    Ok(map_source_configs(&configs))
}

pub async fn source_provider_search(
    provider_id: String,
    query: String,
    limit: u32,
) -> Result<Vec<UiExternalTrack>, String> {
    let state = core()?;
    let provider = state
        .source_registry
        .get(&provider_id)
        .ok_or_else(|| "source provider is disabled or not found".to_string())?;
    let tracks = provider
        .search(&query, limit.clamp(1, 100) as usize)
        .await
        .map_err(|e| e.to_string())?;
    Ok(tracks.into_iter().map(Into::into).collect())
}

pub async fn source_provider_play(
    provider_id: String,
    external_id: String,
    title: String,
    artist: String,
) -> Result<UiPlayerSnapshot, String> {
    let state = core()?;
    let provider = state
        .source_registry
        .get(&provider_id)
        .ok_or_else(|| "source provider is disabled or not found".to_string())?;
    let stream = provider
        .resolve_stream(&external_id)
        .await
        .map_err(|e| e.to_string())?;
    let track = Track {
        path: PathBuf::from(stream.url),
        title: (!title.trim().is_empty()).then_some(title),
        artist: (!artist.trim().is_empty()).then_some(artist),
    };
    state
        .player
        .replace_queue_from(vec![track], 0, Some(format!("source:{provider_id}")))
        .map(Into::into)
        .map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------
// Tag Editor
// ---------------------------------------------------------------------

pub fn track_tags_read(path: String) -> Result<UiTrackTags, String> {
    tags::read_tags(Path::new(&path))
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn track_tags_write(path: String, new_tags: UiTrackTags) -> Result<(), String> {
    let state = core()?;
    let current = state.player.current_path();
    if tags::is_playing_path(&path, current.as_deref()) {
        return Err(tags::PLAYING_ERROR.to_string());
    }
    let changes = tags::TagChanges {
        title: Some(new_tags.title),
        artist: Some(new_tags.artist),
        album: Some(new_tags.album),
        album_artist: Some(new_tags.album_artist),
        track_no: Some(new_tags.track_number),
        disc_no: Some(new_tags.disc_number),
        year: Some(new_tags.year),
        genre: Some(new_tags.genre),
        ..tags::TagChanges::default()
    };
    if let Some(track_id) = find_track_id_for_path(&state.library, &path)? {
        let outcome =
            tags::write_for_tracks(&state.library, &[track_id], &changes, current.as_deref())
                .map_err(|e| e.to_string())?;
        if !outcome.failed.is_empty() {
            let msg = outcome
                .failed
                .into_iter()
                .map(|f| f.error)
                .collect::<Vec<_>>()
                .join("; ");
            return Err(msg);
        }
        refresh_player_meta(&state.library, &state.player, &outcome.updated);
    } else {
        tags::write_tags(Path::new(&path), &changes).map_err(|e| e.to_string())?;
        if let Ok(updated) = tags::read_tags(Path::new(&path)) {
            let title = updated.title.unwrap_or_default();
            let artist = updated.artist.unwrap_or_default();
            state.player.update_track_meta(&path, &title, &artist);
        }
        let _ = state.event_tx.send(UiEvent::LibraryChanged);
    }
    Ok(())
}

// ---------------------------------------------------------------------
// MusicBrainz Metadata Matching
// ---------------------------------------------------------------------

fn map_field_diff(d: neomodern_core::metadata::FieldDiff) -> UiMetadataFieldDiff {
    UiMetadataFieldDiff {
        field: d.field.to_string(),
        old_value: d.old,
        new_value: d.new,
    }
}

fn cache_album_proposals(
    state: &CoreState,
    album_id: i64,
    candidates: &[neomodern_core::metadata::AlbumCandidate],
) {
    let mut cache = state
        .metadata_proposals
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if cache.len() > 128 {
        cache.clear();
    }
    for cand in candidates {
        cache.insert((album_id, cand.release_id.clone()), cand.proposal.clone());
    }
}

pub async fn metadata_match_album(album_id: i64) -> Result<Vec<UiAlbumMatchCandidate>, String> {
    let state = core()?;
    let candidates = state
        .metadata
        .match_album(&state.library, album_id)
        .await
        .map_err(|e| e.to_string())?;
    cache_album_proposals(state, album_id, &candidates);
    Ok(candidates
        .into_iter()
        .map(|c| UiAlbumMatchCandidate {
            release_mbid: c.release_id,
            release_group_mbid: c.release_group_id,
            title: c.title,
            artist: c.artist,
            year: c.year,
            country: c.country,
            format: c.format,
            status: c.status,
            track_count: u32::try_from(c.track_count).unwrap_or(u32::MAX),
            score: c.score,
            label: c.label.to_string(),
            cover_preview: c.cover_preview,
            album_fields: c.album_fields.into_iter().map(map_field_diff).collect(),
            tracks: c
                .tracks
                .into_iter()
                .map(|t| UiMetadataTrackDiff {
                    track_id: t.track_id,
                    path: t.path,
                    title: t.title,
                    matched: t.matched,
                    fields: t.fields.into_iter().map(map_field_diff).collect(),
                })
                .collect(),
        })
        .collect())
}

fn map_apply_outcome(outcome: ApplyOutcome) -> UiMetadataApplyResult {
    UiMetadataApplyResult {
        batch_id: outcome.batch_id,
        updated: u32::try_from(outcome.updated).unwrap_or(u32::MAX),
        failed: outcome
            .failed
            .into_iter()
            .map(|(path, err)| format!("{path}: {err}"))
            .collect(),
        cover: outcome.cover,
    }
}

pub async fn metadata_apply_album(
    album_id: i64,
    release_mbid: String,
    download_cover: bool,
) -> Result<UiMetadataApplyResult, String> {
    let state = core()?;
    let cached = {
        let cache = state
            .metadata_proposals
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        cache.get(&(album_id, release_mbid.clone())).cloned()
    };
    let mut proposal = match cached {
        Some(p) => p,
        None => {
            let candidates = state
                .metadata
                .match_album(&state.library, album_id)
                .await
                .map_err(|e| e.to_string())?;
            cache_album_proposals(state, album_id, &candidates);
            candidates
                .into_iter()
                .find(|c| c.release_id == release_mbid)
                .map(|c| c.proposal)
                .ok_or_else(|| {
                    format!("matching release {release_mbid} not found for album {album_id}")
                })?
        }
    };
    proposal.cover = download_cover;
    let outcome = state
        .metadata
        .apply(&state.library, proposal, state.player.current_path())
        .await
        .map_err(|e| e.to_string())?;
    refresh_player_meta(&state.library, &state.player, &outcome.updated_paths);
    if outcome.cover.is_some() {
        state
            .cover_colors
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
    }
    Ok(map_apply_outcome(outcome))
}

pub async fn metadata_undo_last() -> Result<u32, String> {
    let state = core()?;
    let latest = state
        .library
        .next_tag_batch_id()
        .map_err(|e| e.to_string())?
        - 1;
    if latest <= 0 {
        return Err("nothing to undo for this change".to_string());
    }
    let outcome = state
        .metadata
        .undo(&state.library, latest, state.player.current_path())
        .await
        .map_err(|e| e.to_string())?;
    refresh_player_meta(&state.library, &state.player, &outcome.updated_paths);
    state
        .cover_colors
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear();
    if outcome.updated == 0 && !outcome.failed.is_empty() {
        let msg = outcome
            .failed
            .into_iter()
            .map(|(p, e)| format!("{p}: {e}"))
            .collect::<Vec<_>>()
            .join("; ");
        return Err(msg);
    }
    Ok(u32::try_from(outcome.updated).unwrap_or(u32::MAX))
}

pub fn metadata_can_undo() -> Result<bool, String> {
    let state = core()?;
    let latest = state
        .library
        .next_tag_batch_id()
        .map_err(|e| e.to_string())?
        - 1;
    if latest <= 0 {
        return Ok(false);
    }
    let rows = state
        .library
        .tag_history_batch(latest)
        .map_err(|e| e.to_string())?;
    Ok(!rows.is_empty())
}

fn track_candidate_id(recording_id: &str, release_id: &str) -> String {
    format!("{recording_id}:{release_id}")
}

fn cache_track_proposals(state: &CoreState, track_id: i64, candidates: &[TrackCandidate]) {
    let mut cache = state
        .track_metadata_proposals
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if cache.len() > 128 {
        cache.clear();
    }
    for cand in candidates {
        let id = track_candidate_id(&cand.recording_id, &cand.release_id);
        cache.insert((track_id, id), cand.proposal.clone());
    }
}

pub async fn metadata_match_track(track_id: i64) -> Result<Vec<UiTrackMatchCandidate>, String> {
    let state = core()?;
    let candidates = state
        .metadata
        .match_track(&state.library, track_id)
        .await
        .map_err(|e| e.to_string())?;
    cache_track_proposals(state, track_id, &candidates);
    Ok(candidates
        .into_iter()
        .map(|c| UiTrackMatchCandidate {
            candidate_id: track_candidate_id(&c.recording_id, &c.release_id),
            recording_id: c.recording_id,
            release_id: c.release_id,
            release_group_id: c.release_group_id,
            title: c.title,
            artist: c.artist,
            album: c.album,
            year: c.year,
            country: c.country,
            format: c.format,
            status: c.status,
            score: c.score,
            label: c.label.to_string(),
            cover_preview: c.cover_preview,
            track: UiMetadataTrackDiff {
                track_id: c.track.track_id,
                path: c.track.path,
                title: c.track.title,
                matched: c.track.matched,
                fields: c.track.fields.into_iter().map(map_field_diff).collect(),
            },
        })
        .collect())
}

pub async fn metadata_apply_track(track_id: i64, candidate_id: String) -> Result<u32, String> {
    let state = core()?;
    let cached = {
        let cache = state
            .track_metadata_proposals
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        cache
            .get(&(track_id, candidate_id.clone()))
            .cloned()
            .or_else(|| {
                cache
                    .iter()
                    .find(|((tid, key), _)| {
                        *tid == track_id
                            && key.split_once(':').is_some_and(|(rec, rel)| {
                                rec == candidate_id || rel == candidate_id
                            })
                    })
                    .map(|(_, p)| p.clone())
            })
    };
    let proposal = match cached {
        Some(p) => p,
        None => {
            let candidates = state
                .metadata
                .match_track(&state.library, track_id)
                .await
                .map_err(|e| e.to_string())?;
            cache_track_proposals(state, track_id, &candidates);
            candidates
                .into_iter()
                .find(|c| {
                    track_candidate_id(&c.recording_id, &c.release_id) == candidate_id
                        || c.recording_id == candidate_id
                        || c.release_id == candidate_id
                })
                .map(|c| c.proposal)
                .ok_or_else(|| {
                    format!("matching candidate {candidate_id} not found for track {track_id}")
                })?
        }
    };
    let outcome = state
        .metadata
        .apply(&state.library, proposal, state.player.current_path())
        .await
        .map_err(|e| e.to_string())?;
    refresh_player_meta(&state.library, &state.player, &outcome.updated_paths);
    if outcome.cover.is_some() {
        state
            .cover_colors
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
    }
    if outcome.updated == 0 && !outcome.failed.is_empty() {
        let msg = outcome
            .failed
            .into_iter()
            .map(|(p, e)| format!("{p}: {e}"))
            .collect::<Vec<_>>()
            .join("; ");
        return Err(msg);
    }
    Ok(u32::try_from(outcome.updated).unwrap_or(u32::MAX))
}

// ---------------------------------------------------------------------
// Online Search, Playback, Downloads & Tools
// ---------------------------------------------------------------------

async fn current_online_status(state: &CoreState) -> Result<UiOnlineStatus, String> {
    let store = Arc::clone(&state.session);
    let lib = Arc::clone(&state.library);
    let online = Arc::clone(&state.online);
    let status = tokio::task::spawn_blocking(move || online.status(&store, &lib))
        .await
        .map_err(|e| e.to_string())?;
    Ok(status.into())
}

pub async fn online_status() -> Result<UiOnlineStatus, String> {
    current_online_status(core()?).await
}

pub async fn online_set_download_dir(dir: String) -> Result<UiOnlineStatus, String> {
    let state = core()?;
    let trimmed = dir.trim();
    let next = (!trimmed.is_empty()).then(|| PathBuf::from(trimmed));
    state.session.set_download_dir(next);
    state.session.save_now(&state.player.export_session());
    current_online_status(state).await
}

pub async fn online_set_ytdlp_path(path: Option<String>) -> Result<UiOnlineStatus, String> {
    let state = core()?;
    let trimmed = path.as_deref().map(str::trim).filter(|s| !s.is_empty());
    if let Some(p) = trimmed
        && !neomodern_core::online::is_valid_ytdlp_binary_path(Path::new(p))
    {
        return Err("invalid yt-dlp executable".into());
    }
    state.session.set_ytdlp_path(trimmed.map(PathBuf::from));
    state.session.save_now(&state.player.export_session());
    current_online_status(state).await
}

pub async fn online_install_tool(tool: String) -> Result<UiOnlineStatus, String> {
    #[cfg(target_os = "android")]
    {
        let _ = tool;
        Err("not available on Android".into())
    }
    #[cfg(not(target_os = "android"))]
    {
        let state = core()?;
        let which = Tool::parse(&tool).ok_or_else(|| format!("unknown tool: {tool}"))?;
        let tx = state.event_tx.clone();
        let emit = move |p: neomodern_core::online::tools::InstallProgress| {
            let tool_name = match p.tool {
                Tool::Ytdlp => "ytdlp",
                Tool::Ffmpeg => "ffmpeg",
            }
            .to_string();
            let _ = tx.send(UiEvent::ToolInstallProgress {
                tool: tool_name,
                stage: p.stage.to_string(),
                received: p.received,
                total: p.total,
            });
        };
        state
            .online
            .install_tool(which, &emit)
            .await
            .map_err(|e| e.to_string())?;
        current_online_status(state).await
    }
}

pub async fn online_search(query: String) -> Result<UiOnlineSearchResult, String> {
    let state = core()?;
    let bin = state.online.resolve_ytdlp_bin(&state.session);
    state
        .online
        .search(&query, &bin)
        .await
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub async fn online_album_detail(album: UiOnlineAlbum) -> Result<UiOnlineAlbumDetail, String> {
    let state = core()?;
    let bin = state.online.resolve_ytdlp_bin(&state.session);
    let core_album: OnlineAlbum = album.into();
    state
        .online
        .album_detail(&core_album, &bin)
        .await
        .map(Into::into)
        .map_err(|e| e.to_string())
}

fn online_queue_entry(track: OnlineTrack, stream_url: String) -> Track {
    Track {
        path: PathBuf::from(stream_url),
        title: (!track.title.is_empty()).then_some(track.title),
        artist: (!track.artist.is_empty()).then_some(track.artist),
    }
}

pub async fn online_play_tracks(
    tracks: Vec<UiOnlineTrack>,
    start_index: u32,
) -> Result<UiPlayerSnapshot, String> {
    let state = core()?;
    let mut rest = tracks
        .into_iter()
        .map(OnlineTrack::from)
        .skip(start_index as usize);
    let first = rest.next().ok_or("no track to play")?;
    let bin = state.online.resolve_ytdlp_bin(&state.session);
    let (stream_url, _) = state
        .online
        .resolve_stream(&first, &bin)
        .await
        .map_err(|e| e.to_string())?;
    let snap = state
        .player
        .replace_queue(vec![online_queue_entry(first, stream_url)], 0)
        .map_err(|e| e.to_string())?;
    let Some(mut anchor) = snap.current.as_ref().map(|c| c.id) else {
        return Ok(snap.into());
    };
    let rest: Vec<OnlineTrack> = rest.collect();
    if !rest.is_empty() {
        let online = Arc::clone(&state.online);
        let player = Arc::clone(&state.player);
        tokio::spawn(async move {
            for track in rest {
                let title = track.title.clone();
                let stream_url = match online.resolve_stream(&track, &bin).await {
                    Ok((url, _)) => url,
                    Err(e) => {
                        log::warn!("skipping '{title}': {e}");
                        continue;
                    }
                };
                match player.insert_after(anchor, online_queue_entry(track, stream_url)) {
                    Ok(Some(id)) => anchor = id,
                    Ok(None) => break,
                    Err(e) => {
                        log::warn!("could not queue '{title}': {e}");
                        break;
                    }
                }
            }
        });
    }
    Ok(snap.into())
}

pub fn online_download_track(track: UiOnlineTrack) -> Result<UiDownloadJob, String> {
    let state = core()?;
    let core_track: OnlineTrack = track.into();
    let title = core_track.title.clone();
    let artist = core_track.artist.clone();
    let cover = core_track
        .cover
        .clone()
        .or_else(|| core_track.cover_url.clone());
    let req = DownloadRequest {
        kind: DownloadKind::Track,
        title,
        artist,
        cover,
        tracks: vec![core_track],
    };
    state
        .online
        .enqueue_download(req, &state.session, &state.library)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn online_download_album(
    album: UiOnlineAlbum,
    tracks: Vec<UiOnlineTrack>,
) -> Result<UiDownloadJob, String> {
    let state = core()?;
    let cover = album.cover.or(album.cover_url);
    let req = DownloadRequest {
        kind: DownloadKind::Album,
        title: album.title,
        artist: album.artist,
        cover,
        tracks: tracks.into_iter().map(Into::into).collect(),
    };
    state
        .online
        .enqueue_download(req, &state.session, &state.library)
        .map(Into::into)
        .map_err(|e| e.to_string())
}

pub fn online_downloads() -> Result<Vec<UiDownloadJob>, String> {
    Ok(core()?
        .online
        .downloads()
        .into_iter()
        .map(Into::into)
        .collect())
}

pub fn online_cancel_download(id: u64) -> Result<Vec<UiDownloadJob>, String> {
    let online = &core()?.online;
    Ok(online
        .cancel_download(id)
        .unwrap_or_else(|| online.downloads())
        .into_iter()
        .map(Into::into)
        .collect())
}

pub fn online_clear_finished() -> Result<Vec<UiDownloadJob>, String> {
    Ok(core()?
        .online
        .clear_finished()
        .into_iter()
        .map(Into::into)
        .collect())
}

// ---------------------------------------------------------------------
// Network, Privacy & Update Check
// ---------------------------------------------------------------------

fn build_net_settings(session: &SessionStore) -> UiNetSettings {
    let lyrics_save = match session.lyrics_save() {
        SaveMode::Sidecar => "sidecar",
        SaveMode::Embed => "embed",
        SaveMode::Off => "off",
    }
    .to_string();
    UiNetSettings {
        offline_mode: session.offline_mode(),
        online: session.net_feature(Feature::Online),
        lyrics: session.net_feature(Feature::Lyrics),
        artist_info: session.net_feature(Feature::ArtistInfo),
        metadata: session.net_feature(Feature::Metadata),
        updates: session.net_feature(Feature::Updates),
        allow_online: session.net_allowed(Feature::Online),
        allow_lyrics: session.net_allowed(Feature::Lyrics),
        allow_artist_info: session.net_allowed(Feature::ArtistInfo),
        allow_metadata: session.net_allowed(Feature::Metadata),
        allow_updates: session.net_allowed(Feature::Updates),
        lyrics_save,
        lyrics_netease: session.lyrics_netease(),
    }
}

pub fn app_get_net_settings() -> Result<UiNetSettings, String> {
    Ok(build_net_settings(&core()?.session))
}

pub fn app_set_net_feature(feature: String, enabled: bool) -> Result<UiNetSettings, String> {
    let state = core()?;
    let feat = match feature.trim() {
        "lyrics" => Feature::Lyrics,
        "online" => Feature::Online,
        "artistInfo" | "artist_info" => Feature::ArtistInfo,
        "metadata" => Feature::Metadata,
        "updates" => Feature::Updates,
        other => return Err(format!("unknown network feature: {other}")),
    };
    state.session.set_net_feature(feat, enabled);
    state.session.save_now(&state.player.export_session());
    Ok(build_net_settings(&state.session))
}

pub fn app_set_offline_mode(enabled: bool) -> Result<UiNetSettings, String> {
    let state = core()?;
    state.session.set_offline_mode(enabled);
    state.session.save_now(&state.player.export_session());
    Ok(build_net_settings(&state.session))
}

pub fn app_set_lyrics_save(mode: String) -> Result<UiNetSettings, String> {
    let state = core()?;
    let save_mode = match mode.trim() {
        "sidecar" => SaveMode::Sidecar,
        "embed" => SaveMode::Embed,
        "off" => SaveMode::Off,
        other => return Err(format!("invalid lyrics save mode: {other}")),
    };
    state.session.set_lyrics_save(save_mode);
    state.session.save_now(&state.player.export_session());
    Ok(build_net_settings(&state.session))
}

pub fn app_set_lyrics_netease(enabled: bool) -> Result<UiNetSettings, String> {
    let state = core()?;
    state.session.set_lyrics_netease(enabled);
    state.session.save_now(&state.player.export_session());
    Ok(build_net_settings(&state.session))
}

pub async fn app_check_update() -> Result<UiUpdateInfo, String> {
    let state = core()?;
    let current = neomodern_core::VERSION.to_string();
    let policy = state.session.net_policy();
    let found = update::check(&current, &policy).await?;
    Ok(match found {
        Some(info) => UiUpdateInfo {
            current_version: current,
            update_available: true,
            version: Some(info.version),
            url: Some(info.url),
            installable: info.installable,
        },
        None => UiUpdateInfo {
            current_version: current,
            update_available: false,
            version: None,
            url: None,
            installable: false,
        },
    })
}

// ---------------------------------------------------------------------
// Pinned Items
// ---------------------------------------------------------------------

fn parse_pinned_kind(kind: &str) -> Result<PinnedKind, String> {
    match kind.trim() {
        "album" => Ok(PinnedKind::Album),
        "playlist" => Ok(PinnedKind::Playlist),
        other => Err(format!("invalid pinned kind: {other}")),
    }
}

pub fn pinned_list() -> Result<Vec<UiPinnedItem>, String> {
    let state = core()?;
    let refs = state.session.pinned();
    let mut playlists_cache: Option<Vec<PlaylistInfo>> = None;
    let mut out = Vec::with_capacity(refs.len());
    for item in refs {
        match item.kind {
            PinnedKind::Album => {
                if let Ok(Some(album)) = state.library.album_info(item.id) {
                    out.push(UiPinnedItem {
                        kind: "album".to_string(),
                        target_id: album.id,
                        title: album.title,
                        subtitle: album.album_artist,
                        cover_path: album.cover,
                    });
                }
            }
            PinnedKind::Playlist => {
                let list = match &playlists_cache {
                    Some(v) => v,
                    None => playlists_cache
                        .insert(state.library.playlists().map_err(|e| e.to_string())?),
                };
                if let Some(p) = list.iter().find(|p| p.id == item.id) {
                    let cover_path = p
                        .cover
                        .as_deref()
                        .filter(|c| !c.starts_with("preset:"))
                        .map(str::to_owned)
                        .or_else(|| p.album_covers.first().cloned());
                    out.push(UiPinnedItem {
                        kind: "playlist".to_string(),
                        target_id: p.id,
                        title: p.name.clone(),
                        subtitle: String::new(),
                        cover_path,
                    });
                }
            }
        }
    }
    Ok(out)
}

pub fn pinned_toggle(kind: String, target_id: i64) -> Result<bool, String> {
    let state = core()?;
    let kind = parse_pinned_kind(&kind)?;
    let pinned = state.session.toggle_pin(PinnedRef {
        kind,
        id: target_id,
    });
    state.session.save_now(&state.player.export_session());
    Ok(pinned)
}

// ---------------------------------------------------------------------
// UI Preferences & Default Music Directory
// ---------------------------------------------------------------------

pub fn ui_prefs_get() -> Result<UiPrefs, String> {
    let state = core()?;
    Ok(state
        .ui_prefs
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone())
}

pub fn ui_prefs_save(prefs: UiPrefs) -> Result<(), String> {
    let state = core()?;
    let normalized = validate_and_normalize_ui_prefs(prefs)?;
    save_ui_prefs(&state.ui_prefs_path, &normalized)?;
    *state.ui_prefs.lock().unwrap_or_else(|e| e.into_inner()) = normalized;
    Ok(())
}

pub fn default_music_dir() -> Option<String> {
    let candidate: Option<PathBuf> = {
        #[cfg(target_os = "windows")]
        {
            std::env::var_os("USERPROFILE")
                .map(|home| PathBuf::from(home).join("Music"))
                .or_else(|| {
                    let drive = std::env::var_os("HOMEDRIVE")?;
                    let path = std::env::var_os("HOMEPATH")?;
                    let mut home = PathBuf::from(drive);
                    home.push(path);
                    Some(home.join("Music"))
                })
        }
        #[cfg(target_os = "android")]
        {
            Some(PathBuf::from("/storage/emulated/0/Music"))
        }
        #[cfg(all(not(target_os = "windows"), not(target_os = "android")))]
        {
            std::env::var_os("XDG_MUSIC_DIR")
                .map(PathBuf::from)
                .filter(|p| p.is_dir())
                .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join("Music")))
        }
    };
    candidate
        .filter(|p| p.is_dir())
        .map(|p| scan::display_path(&p))
}

// ---------------------------------------------------------------------
// Backup, Restore & Relocate Music Folder
// ---------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct UiBackupExportResult {
    pub path: String,
    pub size_bytes: u64,
    pub entry_count: u64,
}

#[derive(Debug, Clone)]
pub struct UiBackupPreview {
    pub app_version: String,
    pub created_at: i64,
    pub source_platform: String,
    pub profiles_count: u32,
    pub tracks_count: u64,
    pub playlists_count: u64,
    pub listens_count: u64,
    pub size_bytes: u64,
    pub entry_count: u64,
}

impl From<backup::archive::BackupSummary> for UiBackupPreview {
    fn from(s: backup::archive::BackupSummary) -> Self {
        Self {
            app_version: s.app_version,
            created_at: s.created_at,
            source_platform: s.platform,
            profiles_count: u32::try_from(s.profiles.len()).unwrap_or(u32::MAX),
            tracks_count: s.tracks,
            playlists_count: s.playlists,
            listens_count: s.listens,
            size_bytes: s.size,
            entry_count: s.entries,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiBackupImportResult {
    pub safety_backup_dir: String,
    pub restart_required: bool,
}

#[derive(Debug, Clone)]
pub struct UiAutoBackupStatus {
    pub enabled: bool,
    pub folder: Option<String>,
    pub cadence: String,
    pub keep: u32,
    pub last_backup_at: Option<i64>,
    pub last_backup_size: Option<u64>,
    pub last_error: Option<String>,
}

fn cadence_to_string(interval: BackupInterval) -> String {
    match interval {
        BackupInterval::Day => "daily".to_string(),
        BackupInterval::Week => "weekly".to_string(),
    }
}

fn parse_cadence(cadence: &str) -> Result<BackupInterval, String> {
    match cadence.trim().to_ascii_lowercase().as_str() {
        "daily" | "day" => Ok(BackupInterval::Day),
        "weekly" | "week" => Ok(BackupInterval::Week),
        other => Err(format!("invalid backup cadence: {other}")),
    }
}

fn auto_backup_to_ui(store: &SessionStore) -> UiAutoBackupStatus {
    let a = store.auto_backup();
    UiAutoBackupStatus {
        enabled: a.enabled,
        folder: a.folder.map(|p| scan::display_path(&p)),
        cadence: cadence_to_string(a.interval),
        keep: a.keep,
        last_backup_at: a.last_at,
        last_backup_size: a.last_size,
        last_error: a.last_error,
    }
}

#[derive(Debug, Clone)]
pub struct UiRelocatePreview {
    pub old_path: String,
    pub new_path: String,
    pub total_tracks: u64,
    pub found_tracks: u64,
    pub missing_tracks: u64,
}

#[derive(Debug, Clone)]
pub struct UiRelocateResult {
    pub rewritten_tracks: u64,
}

pub async fn backup_export(dest_path: String) -> Result<UiBackupExportResult, String> {
    let dest = dest_path.trim().to_string();
    if dest.is_empty() {
        return Err("destination path cannot be empty".to_string());
    }
    let state = core()?;
    let backup = Arc::clone(&state.backup);
    let data_dir = state.data_dir.clone();
    let session = Arc::clone(&state.session);
    let player = Arc::clone(&state.player);
    tokio::task::spawn_blocking(move || {
        let _job = backup.begin().map_err(|e| e.to_string())?;
        session.save_now(&player.export_session());
        let info = backup::archive::export(&data_dir, Path::new(&dest), backup::now_ms())
            .map_err(|e| e.to_string())?;
        Ok(UiBackupExportResult {
            path: info.path,
            size_bytes: info.size,
            entry_count: info.entry_count,
        })
    })
    .await
    .map_err(|e| e.to_string())?
}

pub async fn backup_inspect(src_path: String) -> Result<UiBackupPreview, String> {
    let src = src_path.trim().to_string();
    if src.is_empty() {
        return Err("backup path cannot be empty".to_string());
    }
    let state = core()?;
    let data_dir = state.data_dir.clone();
    tokio::task::spawn_blocking(move || {
        backup::archive::inspect(Path::new(&src), &data_dir)
            .map(Into::into)
            .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

pub async fn backup_stage_import(src_path: String) -> Result<UiBackupImportResult, String> {
    let src = src_path.trim().to_string();
    if src.is_empty() {
        return Err("backup path cannot be empty".to_string());
    }
    let state = core()?;
    let backup = Arc::clone(&state.backup);
    let data_dir = state.data_dir.clone();
    let session = Arc::clone(&state.session);
    let player = Arc::clone(&state.player);
    tokio::task::spawn_blocking(move || {
        let job = backup.begin().map_err(|e| e.to_string())?;
        session.save_now(&player.export_session());
        let staged = backup_swap::stage_import(Path::new(&src), &data_dir, backup::now_ms())
            .map_err(|e| e.to_string())?;
        backup.set_import_pending();
        drop(job);
        Ok(UiBackupImportResult {
            safety_backup_dir: staged.before_import,
            restart_required: staged.restart_required,
        })
    })
    .await
    .map_err(|e| e.to_string())?
}

pub fn backup_auto_status() -> Result<UiAutoBackupStatus, String> {
    let state = core()?;
    Ok(auto_backup_to_ui(&state.session))
}

pub fn backup_set_auto(
    enabled: bool,
    folder: Option<String>,
    cadence: String,
    keep: u32,
) -> Result<UiAutoBackupStatus, String> {
    if cfg!(target_os = "android") {
        return Err("automatic backup is not available on Android".to_string());
    }
    let state = core()?;
    let interval = parse_cadence(&cadence)?;
    let folder = folder
        .map(|f| f.trim().to_string())
        .filter(|f| !f.is_empty())
        .map(PathBuf::from);
    if enabled && !folder.as_ref().is_some_and(|f| f.is_dir()) {
        return Err("choose an existing folder for the backups".to_string());
    }
    if !neomodern_core::session::BACKUP_KEEP_CHOICES.contains(&keep) {
        return Err(format!(
            "keep must be one of {:?}",
            neomodern_core::session::BACKUP_KEEP_CHOICES
        ));
    }
    state.session.update_auto_backup(|a| {
        if a.folder != folder {
            a.last_error = None;
        }
        a.enabled = enabled;
        a.folder = folder;
        a.interval = interval;
        a.keep = keep;
    });
    state.session.save_now(&state.player.export_session());
    state.backup.notify_auto();
    Ok(auto_backup_to_ui(&state.session))
}

pub async fn backup_run_auto_now() -> Result<UiAutoBackupStatus, String> {
    let state = core()?;
    let session = Arc::clone(&state.session);
    let player = Arc::clone(&state.player);
    backup_auto::run_auto_once(
        &state.backup,
        &state.session,
        &state.library,
        Arc::new(move || {
            session.save_now(&player.export_session());
        }),
    )
    .await?;
    Ok(auto_backup_to_ui(&state.session))
}

pub async fn folder_relocate_preview(
    folder_id: i64,
    new_path: String,
) -> Result<UiRelocatePreview, String> {
    let state = core()?;
    let library = Arc::clone(&state.library);
    tokio::task::spawn_blocking(move || {
        let old_path = library
            .folders()
            .map_err(|e| e.to_string())?
            .into_iter()
            .find(|f| f.id == folder_id)
            .map(|f| f.path)
            .ok_or_else(|| format!("folder {folder_id} not found"))?;
        let check = library
            .folder_check_move(folder_id, &new_path)
            .map_err(|e| e.to_string())?;
        let missing_tracks = if !check.exists || check.checked == 0 {
            check.total
        } else if check.checked == check.total {
            check.total.saturating_sub(check.found)
        } else {
            check.checked.saturating_sub(check.found)
        };
        let resolved_new = Path::new(&new_path)
            .canonicalize()
            .map(|p| scan::display_path(&p))
            .unwrap_or_else(|_| new_path.trim().to_string());
        Ok(UiRelocatePreview {
            old_path,
            new_path: resolved_new,
            total_tracks: check.total,
            found_tracks: check.found,
            missing_tracks,
        })
    })
    .await
    .map_err(|e| e.to_string())?
}

pub async fn folder_relocate_apply(
    folder_id: i64,
    new_path: String,
) -> Result<UiRelocateResult, String> {
    let state = core()?;
    let library = Arc::clone(&state.library);
    let player = Arc::clone(&state.player);
    let session = Arc::clone(&state.session);
    tokio::task::spawn_blocking(move || {
        let moved = library
            .move_folder_detailed(folder_id, &new_path)
            .map_err(|e| e.to_string())?;
        if moved.old_path != moved.folder.path {
            player.rebase_paths(&moved.old_path, &moved.folder.path);
            session.rebase_paths(&moved.old_path, &moved.folder.path);
            session.save_now(&player.export_session());
        }
        library.start_scan(vec![moved.folder]);
        Ok(UiRelocateResult {
            rewritten_tracks: moved.rewritten_tracks,
        })
    })
    .await
    .map_err(|e| e.to_string())?
}

pub fn library_missing_folders() -> Result<Vec<UiFolderInfo>, String> {
    let statuses = core()?.library.folder_status().map_err(|e| e.to_string())?;
    Ok(statuses
        .into_iter()
        .filter(|f| !f.reachable)
        .map(|f| UiFolderInfo {
            id: f.id,
            path: f.path,
        })
        .collect())
}

#[cfg(target_os = "windows")]
fn find_process_hwnd() -> Option<*mut std::ffi::c_void> {
    use std::ffi::c_void;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetCurrentProcessId() -> u32;
    }

    #[link(name = "user32")]
    unsafe extern "system" {
        fn EnumWindows(
            lp_enum_func: unsafe extern "system" fn(*mut c_void, isize) -> i32,
            l_param: isize,
        ) -> i32;
        fn GetWindowThreadProcessId(hwnd: *mut c_void, lpdw_process_id: *mut u32) -> u32;
        fn IsWindowVisible(hwnd: *mut c_void) -> i32;
    }

    struct Search {
        pid: u32,
        found: *mut c_void,
    }

    unsafe extern "system" fn callback(hwnd: *mut c_void, l_param: isize) -> i32 {
        let search = unsafe { &mut *(l_param as *mut Search) };
        let mut win_pid = 0u32;
        unsafe {
            GetWindowThreadProcessId(hwnd, &mut win_pid);
            if win_pid == search.pid && IsWindowVisible(hwnd) != 0 {
                search.found = hwnd;
                return 0;
            }
        }
        1
    }

    let mut search = Search {
        pid: unsafe { GetCurrentProcessId() },
        found: std::ptr::null_mut(),
    };
    unsafe {
        EnumWindows(callback, (&mut search as *mut Search) as isize);
    }
    (!search.found.is_null()).then_some(search.found)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rgb_to_argb_packs_opaque_alpha() {
        assert_eq!(rgb_to_argb([0x12, 0x34, 0x56]), 0xFF12_3456);
        assert_eq!(rgb_to_argb([0, 0, 0]), 0xFF00_0000);
        assert_eq!(rgb_to_argb([255, 255, 255]), 0xFFFF_FFFF);
    }

    #[test]
    fn playlist_cover_mode_parses_auto_gradient_and_image() {
        assert_eq!(
            playlist_cover_mode_and_value(None),
            ("auto".to_string(), None)
        );
        assert_eq!(
            playlist_cover_mode_and_value(Some("  ")),
            ("auto".to_string(), None)
        );
        assert_eq!(
            playlist_cover_mode_and_value(Some("preset:teal:star")),
            ("gradient".to_string(), Some("preset:teal:star".to_string()))
        );
        assert_eq!(
            playlist_cover_mode_and_value(Some("C:/covers/pl.jpg")),
            ("image".to_string(), Some("C:/covers/pl.jpg".to_string()))
        );
    }

    #[test]
    fn ui_prefs_validation_and_persistence_roundtrip() {
        let valid = validate_and_normalize_ui_prefs(UiPrefs {
            language: "tr".to_string(),
            welcome_dismissed: true,
            sidebar_width: 260.0,
            right_panel_width: 340.0,
        })
        .unwrap();
        assert_eq!(valid.language, "tr");
        assert!(valid.welcome_dismissed);
        assert_eq!(valid.sidebar_width, 260.0);
        assert_eq!(valid.right_panel_width, 340.0);

        assert!(
            validate_and_normalize_ui_prefs(UiPrefs {
                language: "fr".to_string(),
                ..UiPrefs::default()
            })
            .is_err()
        );

        let dir = std::env::temp_dir().join(format!(
            "neomodern_ui_prefs_test_{}_{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let prefs_path = dir.join("ui_prefs.json");
        assert_eq!(load_ui_prefs(&prefs_path), UiPrefs::default());
        save_ui_prefs(&prefs_path, &valid).unwrap();
        assert_eq!(load_ui_prefs(&prefs_path), valid);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn parse_pinned_kind_validates_variants() {
        assert_eq!(parse_pinned_kind("album").unwrap(), PinnedKind::Album);
        assert_eq!(parse_pinned_kind("playlist").unwrap(), PinnedKind::Playlist);
        assert!(parse_pinned_kind("artist").is_err());
    }

    #[test]
    fn stats_to_ui_maps_full_summary_and_sort_order() {
        use neomodern_core::library::StatsSummary;

        let by_hour = (0u32..24)
            .map(|h| BucketStat {
                label: format!("{h:02}"),
                listened_ms: if h == 21 { 50_000 } else { u64::from(h) * 100 },
                play_count: if h == 21 { 2 } else { 0 },
            })
            .collect();
        let by_weekday = (0..7)
            .map(|w| BucketStat {
                label: w.to_string(),
                listened_ms: if w == 4 { 80_000 } else { 1_000 },
                play_count: if w == 4 { 3 } else { 0 },
            })
            .collect();
        let stats = ListeningStats {
            summary: StatsSummary {
                total_listened_ms: 120_000,
                play_count: 4,
                raw_event_count: 5,
                skip_count: 1,
                completed_count: 3,
                unique_tracks: 2,
                unique_artists: 2,
                unique_albums: 1,
                active_days: 3,
                longest_streak_days: 2,
                current_streak_days: 1,
                top_hour: Some(21),
                top_weekday: Some(4),
                first_listen_at: Some(1_700_000_000),
            },
            top_tracks_by_plays: vec![TopTrackStat {
                track_id: Some(10),
                path: "/music/plays.mp3".to_string(),
                title: "Most Played".to_string(),
                artist: "Artist A".to_string(),
                album: "Album A".to_string(),
                cover: Some("/covers/a.jpg".to_string()),
                play_count: 10,
                listened_ms: 30_000,
                skip_count: 0,
            }],
            top_tracks_by_time: vec![TopTrackStat {
                track_id: Some(20),
                path: "/music/time.mp3".to_string(),
                title: "Longest Time".to_string(),
                artist: "Artist B".to_string(),
                album: "Album B".to_string(),
                cover: None,
                play_count: 2,
                listened_ms: 90_000,
                skip_count: 1,
            }],
            top_artists_by_time: vec![TopArtistStat {
                artist: "Artist B".to_string(),
                cover: None,
                play_count: 2,
                listened_ms: 90_000,
                unique_tracks: 1,
                skip_count: 1,
            }],
            top_albums_by_time: vec![TopAlbumStat {
                album: "Album B".to_string(),
                artist: "Artist B".to_string(),
                album_id: Some(7),
                cover: None,
                play_count: 2,
                listened_ms: 90_000,
            }],
            top_genres: vec![TopGenreStat {
                genre: "Ambient".to_string(),
                play_count: 3,
                listened_ms: 100_000,
            }],
            by_hour,
            by_weekday,
            by_month: vec![BucketStat {
                label: "2026-11".to_string(),
                listened_ms: 120_000,
                play_count: 4,
            }],
            recent: vec![RecentListen {
                id: 99,
                track_id: Some(20),
                path: "/music/time.mp3".to_string(),
                title: "Longest Time".to_string(),
                artist: "Artist B".to_string(),
                album: "Album B".to_string(),
                cover: None,
                started_at: 1_700_001_000,
                listened_ms: 45_000,
                completed: true,
                skipped: false,
                source: "local".to_string(),
            }],
            available_years: vec![2026],
        };

        let by_time = stats_to_ui(stats.clone(), false);
        assert_eq!(by_time.top_tracks[0].title, "Longest Time");
        assert_eq!(by_time.raw_event_count, 5);
        assert_eq!(by_time.skip_count, 1);
        assert_eq!(by_time.completed_count, 3);
        assert!((by_time.completion_rate - 0.6).abs() < 1e-9);
        assert_eq!(by_time.peak_hour, Some(21));
        assert_eq!(by_time.favorite_weekday, Some(4));
        assert_eq!(by_time.hourly_ms.len(), 24);
        assert_eq!(by_time.hourly_ms[21], 50_000);
        assert_eq!(by_time.weekday_ms.len(), 7);
        assert_eq!(by_time.weekday_ms[4], 80_000);
        assert_eq!(by_time.monthly.len(), 1);
        assert_eq!(by_time.monthly[0].label, "2026-11");
        assert_eq!(by_time.monthly[0].plays, 4);
        assert_eq!(by_time.top_genres.len(), 1);
        assert_eq!(by_time.top_genres[0].genre, "Ambient");
        assert_eq!(by_time.recent_events.len(), 1);
        assert!(by_time.recent_events[0].completed);
        assert_eq!(by_time.available_years, vec![2026]);

        let by_plays = stats_to_ui(stats, true);
        assert_eq!(by_plays.top_tracks[0].title, "Most Played");
        assert_eq!(by_plays.top_tracks[0].play_count, 10);
    }

    #[test]
    fn genre_row_to_ui_reports_zero_albums_for_empty_library() {
        let dir = std::env::temp_dir().join(format!(
            "neomodern_genre_test_{}_{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let lib = Library::open(
            &dir.join("library.sqlite3"),
            &dir.join("covers"),
            Hooks::none(),
        )
        .unwrap();
        let ui = genre_row_to_ui(
            &lib,
            GenreRow {
                name: "Jazz".to_string(),
                track_count: 4,
                cover: Some("/covers/jazz.jpg".to_string()),
            },
        );
        assert_eq!(ui.name, "Jazz");
        assert_eq!(ui.track_count, 4);
        assert_eq!(ui.album_count, 0);
        assert_eq!(ui.cover_path.as_deref(), Some("/covers/jazz.jpg"));
        drop(lib);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn backup_cadence_parses_and_formats_cleanly() {
        assert_eq!(parse_cadence("daily").unwrap(), BackupInterval::Day);
        assert_eq!(parse_cadence("day").unwrap(), BackupInterval::Day);
        assert_eq!(parse_cadence("Weekly").unwrap(), BackupInterval::Week);
        assert_eq!(parse_cadence("week").unwrap(), BackupInterval::Week);
        assert!(parse_cadence("hourly").is_err());
        assert_eq!(cadence_to_string(BackupInterval::Day), "daily");
        assert_eq!(cadence_to_string(BackupInterval::Week), "weekly");
    }
}

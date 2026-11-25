pub use crate::android_engine::{UiAndroidAudioCmd, UiAndroidAudioEvent};
use crate::frb_generated::StreamSink;
#[cfg(not(target_os = "android"))]
use neomodern_core::audio::mpv::{MpvEngine, MpvOptions};
use neomodern_core::audio::{AudioEngine, Equalizer, NetGuardedEngine, ReplayGain};
use neomodern_core::library::{
    AlbumDetail, AlbumRow, ArtistProfile, ArtistRow, ArtistTopTrack, DynamicMix, FolderInfo,
    HomeFeed, HomeMixDetail, Hooks, Library, ListeningStats, MAX_PROFILES, NewListenEvent,
    PROFILE_COLORS, PlaylistInfo, Profile, ProfileId, RecentTrack, SortSpec, TopAlbumStat,
    TopArtistStat, TopTrackStat, TrackRow, cover_color, m3u, scan, tags,
};
use neomodern_core::lyrics::save::{self as lyrics_save, SaveMode};
use neomodern_core::lyrics::{LyricsOptions, LyricsResult, LyricsService, LyricsSource};
#[cfg(not(target_os = "android"))]
use neomodern_core::media_keys::{self, Extra as MediaKeysExtra, MediaKeys};
use neomodern_core::metadata::{ApplyOutcome, MetadataService, Proposal};
use neomodern_core::net::Feature;
use neomodern_core::player::{Player, PlayerEvent, PlayerSnapshot, Status, TrackInfo};
use neomodern_core::queue::{RepeatMode, Track};
use neomodern_core::session::{PinnedKind, PinnedRef, SessionStore, is_stream_url};
use neomodern_core::source_provider::{
    ExternalTrack, HttpJsonProvider, ProviderConfig, ProviderKind, ProviderRegistry,
    load_provider_configs, save_provider_configs, validate_base_url,
};
use neomodern_core::sync::jam::host::JamStatus;
use neomodern_core::sync::pair_link::PairQr;
use neomodern_core::sync::service::{PairingOpen, SyncStatus};
use neomodern_core::sync::{
    EventSink, RemoteFeed, SyncConfig, SyncService, default_device_name, link,
};
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
    player: Arc<Player>,
    library: Arc<Library>,
    session: Arc<SessionStore>,
    lyrics: Arc<LyricsService>,
    metadata: Arc<MetadataService>,
    sync: SyncService,
    profile_lock: AtomicBool,
    source_config_path: PathBuf,
    source_configs: Mutex<Vec<ProviderConfig>>,
    source_registry: Arc<ProviderRegistry>,
    cover_colors: Mutex<HashMap<String, Option<u32>>>,
    metadata_proposals: Mutex<HashMap<(i64, String), Proposal>>,
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
    pub bio: Option<String>,
    pub fallback_cover: Option<String>,
    pub popular_tracks: Vec<UiArtistTopTrack>,
    pub albums: Vec<UiAlbumRow>,
    pub tracks: Vec<UiTrackRow>,
}

impl From<ArtistProfile> for UiArtistDetail {
    fn from(a: ArtistProfile) -> Self {
        Self {
            name: a.name,
            track_count: a.track_count,
            album_count: a.album_count,
            total_duration_ms: a.total_duration_ms,
            genres: a.genres,
            play_count: a.play_count,
            listened_ms: a.listened_ms,
            image: a.image,
            bio: a.bio,
            fallback_cover: a.fallback_cover,
            popular_tracks: a.popular_tracks.into_iter().map(Into::into).collect(),
            albums: a.albums.into_iter().map(Into::into).collect(),
            tracks: a.tracks.into_iter().map(Into::into).collect(),
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
pub struct UiTopTrackStat {
    pub track_id: Option<i64>,
    pub path: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub cover: Option<String>,
    pub play_count: u64,
    pub listened_ms: u64,
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
}

impl From<TopArtistStat> for UiTopArtistStat {
    fn from(a: TopArtistStat) -> Self {
        Self {
            artist: a.artist,
            cover: a.cover,
            play_count: a.play_count,
            listened_ms: a.listened_ms,
            unique_tracks: a.unique_tracks,
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
pub struct UiStatsSummary {
    pub total_listened_ms: u64,
    pub play_count: u64,
    pub unique_tracks: u64,
    pub unique_artists: u64,
    pub unique_albums: u64,
    pub active_days: u64,
    pub longest_streak_days: u64,
    pub current_streak_days: u64,
    pub top_tracks: Vec<UiTopTrackStat>,
    pub top_artists: Vec<UiTopArtistStat>,
    pub top_albums: Vec<UiTopAlbumStat>,
}

impl From<ListeningStats> for UiStatsSummary {
    fn from(s: ListeningStats) -> Self {
        Self {
            total_listened_ms: s.summary.total_listened_ms,
            play_count: s.summary.play_count,
            unique_tracks: s.summary.unique_tracks,
            unique_artists: s.summary.unique_artists,
            unique_albums: s.summary.unique_albums,
            active_days: s.summary.active_days,
            longest_streak_days: s.summary.longest_streak_days,
            current_streak_days: s.summary.current_streak_days,
            top_tracks: s.top_tracks_by_time.into_iter().map(Into::into).collect(),
            top_artists: s.top_artists_by_time.into_iter().map(Into::into).collect(),
            top_albums: s.top_albums_by_time.into_iter().map(Into::into).collect(),
        }
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
                                    cover: state.library.track_cover(path).ok().flatten(),
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
                match HttpJsonProvider::from_config(cfg, session.net_policy()) {
                    Ok(p) => {
                        source_registry.register(Arc::new(p));
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

        let state = Arc::new(CoreState {
            player: Arc::clone(&player),
            library,
            session,
            lyrics,
            metadata,
            sync,
            profile_lock,
            source_config_path,
            source_configs: Mutex::new(configs),
            source_registry,
            cover_colors: Mutex::new(HashMap::new()),
            metadata_proposals: Mutex::new(HashMap::new()),
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

        (player, sync_clone, allow_phones, party_enabled)
    };

    let (player, sync, allow_phones, party_enabled) = startup;
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
    core()?
        .library
        .track_cover(&path)
        .map_err(|e| e.to_string())
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

// ---------------------------------------------------------------------
// Lyrics
// ---------------------------------------------------------------------

pub async fn lyrics_for_track(
    path: String,
    title: String,
    artist: String,
    _album: String,
    duration_secs: Option<f64>,
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
        .for_track_with(lib, path, duration_secs, false, &opts)
        .await
        .map_err(|e| e.to_string())?;

    Ok(match result {
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
    })
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
        .map(Into::into)
        .map_err(|e| e.to_string())
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
        .filter_map(|cfg| match &cfg.kind {
            ProviderKind::HttpJson { base_url } => Some(UiSourceProvider {
                id: cfg.id.clone(),
                name: cfg.name.clone(),
                base_url: base_url.clone(),
                enabled: cfg.enabled,
            }),
            #[cfg(not(target_os = "android"))]
            ProviderKind::Cli { .. } => None,
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
    let normalized_url = validate_base_url(&base_url).map_err(|e| e.to_string())?;
    let mut configs = state
        .source_configs
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let id = generate_provider_id(&clean_name, &configs);
    let provider = HttpJsonProvider::new(id.clone(), &normalized_url, state.session.net_policy())
        .map_err(|e| e.to_string())?;
    let mut updated = configs.clone();
    updated.push(ProviderConfig {
        id,
        name: clean_name,
        kind: ProviderKind::HttpJson {
            base_url: normalized_url,
        },
        enabled: true,
    });
    save_provider_configs(&state.source_config_path, &updated).map_err(|e| e.to_string())?;
    state.source_registry.register(Arc::new(provider));
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
        let provider = HttpJsonProvider::from_config(entry, state.session.net_policy())
            .map_err(|e| e.to_string())?;
        save_provider_configs(&state.source_config_path, &updated).map_err(|e| e.to_string())?;
        state.source_registry.register(Arc::new(provider));
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
}

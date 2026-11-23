use crate::frb_generated::StreamSink;
#[cfg(not(target_os = "android"))]
use neomodern_core::audio::mpv::{MpvEngine, MpvOptions};
use neomodern_core::audio::{Equalizer, NetGuardedEngine, ReplayGain};
use neomodern_core::library::{
    AlbumDetail, AlbumRow, ArtistProfile, ArtistRow, ArtistTopTrack, DynamicMix, FolderInfo,
    HomeFeed, HomeMixDetail, Hooks, Library, ListeningStats, NewListenEvent, PlaylistInfo,
    ProfileId, RecentTrack, SortSpec, TopAlbumStat, TopArtistStat, TopTrackStat, TrackRow,
};
use neomodern_core::lyrics::{LyricsOptions, LyricsResult, LyricsService, LyricsSource};
use neomodern_core::net::Feature;
use neomodern_core::player::{Player, PlayerEvent, PlayerSnapshot, Status, TrackInfo};
use neomodern_core::queue::{RepeatMode, Track};
use neomodern_core::session::SessionStore;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::broadcast;

struct CoreState {
    player: Arc<Player>,
    library: Arc<Library>,
    session: Arc<SessionStore>,
    lyrics: Arc<LyricsService>,
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
}

impl From<AlbumRow> for UiAlbumRow {
    fn from(a: AlbumRow) -> Self {
        Self {
            id: a.id,
            title: a.title,
            album_artist: a.album_artist,
            year: a.year,
            track_count: a.track_count,
            cover: a.cover,
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
}

impl From<PlaylistInfo> for UiPlaylistInfo {
    fn from(p: PlaylistInfo) -> Self {
        Self {
            id: p.id,
            name: p.name,
            track_count: p.track_count,
            cover: p.cover,
            album_covers: p.album_covers,
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

pub fn init_core(data_dir: String, cache_dir: String) -> Result<UiPlayerSnapshot, String> {
    let _guard = INIT_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(existing) = CORE.get() {
        return Ok(existing.player.snapshot().into());
    }

    let data_path = PathBuf::from(&data_dir);
    let cache_path = PathBuf::from(&cache_dir);

    let session = Arc::new(SessionStore::new(data_path.join("session.json")));
    let (event_tx, _) = broadcast::channel::<UiEvent>(256);

    let (engine_tx, engine_rx) = std::sync::mpsc::channel();
    #[cfg(not(target_os = "android"))]
    let engine = MpvEngine::new(MpvOptions::default(), engine_tx)
        .map_err(|e| format!("failed to start audio engine: {e}"))?;
    #[cfg(target_os = "android")]
    return Err("Android audio engine is not yet wired in neomodern_bridge".to_string());

    let observer_session = Arc::clone(&session);
    let observer_tx = event_tx.clone();
    let player = Arc::new(Player::new(
        Box::new(NetGuardedEngine::new(
            Box::new(engine),
            session.net_policy(),
        )),
        Box::new(move |event| match event {
            PlayerEvent::State(snap) => {
                if let Some(state) = CORE.get() {
                    observer_session.on_player_state(&snap, || state.player.export_session());
                }
                let _ = observer_tx.send(UiEvent::State(snap.into()));
            }
            PlayerEvent::Position { seconds, duration } => {
                if let Some(state) = CORE.get() {
                    let (qv, idx, pos) = state.player.progress_state();
                    observer_session
                        .maybe_save_progress(qv, idx, pos, || state.player.export_session());
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
        }),
    ));

    player.restore_session(session.load());

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

    let state = Arc::new(CoreState {
        player: Arc::clone(&player),
        library,
        session,
        lyrics,
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
    let lib = &core()?.library;
    if lib.album_info(album_id).map_err(|e| e.to_string())?.is_none() {
        return Ok(None);
    }
    let detail = lib.album(album_id).map_err(|e| e.to_string())?;
    Ok(Some(detail.into()))
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

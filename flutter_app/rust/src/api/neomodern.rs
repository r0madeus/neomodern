use crate::frb_generated::StreamSink;
#[cfg(not(target_os = "android"))]
use neomodern_core::audio::mpv::{MpvEngine, MpvOptions};
use neomodern_core::audio::NetGuardedEngine;
use neomodern_core::library::{
    AlbumDetail, AlbumRow, FolderInfo, Hooks, Library, NewListenEvent, ProfileId, SortSpec,
    TrackRow,
};
use neomodern_core::player::{Player, PlayerEvent, PlayerSnapshot, Status, TrackInfo};
use neomodern_core::queue::{RepeatMode, Track};
use neomodern_core::session::SessionStore;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use tokio::sync::broadcast;

struct CoreState {
    player: Arc<Player>,
    library: Arc<Library>,
    #[allow(dead_code)]
    session: Arc<SessionStore>,
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

    let state = Arc::new(CoreState {
        player: Arc::clone(&player),
        library,
        session,
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

pub fn queue_page(offset: u32, limit: u32) -> Result<Vec<UiTrackInfo>, String> {
    Ok(core()?
        .player
        .queue_page(offset as usize, limit as usize)
        .into_iter()
        .map(Into::into)
        .collect())
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

//! Persistent playback settings and session queue/position state.

use crate::audio::ReplayGain;
use crate::library::scan::write_atomic;
use crate::lyrics::SaveMode;
use crate::net::{Feature, NetPolicy};
use crate::player::PlayerSnapshot;
use crate::queue::RepeatMode;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const POSITION_SAVE_INTERVAL: Duration = Duration::from_secs(5);
const VOLUME_SAVE_INTERVAL: Duration = Duration::from_secs(1);

fn default_volume() -> f64 {
    100.0
}

fn default_close_to_tray() -> bool {
    true
}

fn default_autoplay() -> bool {
    true
}

fn default_lyrics_netease() -> bool {
    true
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PinnedKind {
    Album,
    Playlist,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PinnedRef {
    pub kind: PinnedKind,
    pub id: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedTrack {
    pub path: PathBuf,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub artist: Option<String>,
}

/// Profiles (K24): the player state of a profile that is not active, kept
/// until it is switched to again. The active profile's state lives in the
/// top-level fields of [`SessionState`], so older versions still read it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ProfileSession {
    pub queue: Vec<SavedTrack>,
    pub current_index: Option<usize>,
    pub position_seconds: f64,
    pub shuffle: bool,
    pub repeat: RepeatMode,
    pub pinned: Vec<PinnedRef>,
    pub autoplay: bool,
}

impl Default for ProfileSession {
    fn default() -> Self {
        Self {
            queue: Vec::new(),
            current_index: None,
            position_seconds: 0.0,
            shuffle: false,
            repeat: RepeatMode::Off,
            pinned: Vec::new(),
            autoplay: default_autoplay(),
        }
    }
}

impl ProfileSession {
    /// The per-profile part of `state`.
    pub fn from_state(state: &SessionState) -> Self {
        Self {
            queue: state.queue.clone(),
            current_index: state.current_index,
            position_seconds: state.position_seconds,
            shuffle: state.shuffle,
            repeat: state.repeat,
            pinned: state.pinned.clone(),
            autoplay: state.autoplay,
        }
    }

    /// `device` with this profile's part put in.
    pub fn into_state(self, device: &SessionState) -> SessionState {
        SessionState {
            queue: self.queue,
            current_index: self.current_index,
            position_seconds: self.position_seconds,
            shuffle: self.shuffle,
            repeat: self.repeat,
            pinned: self.pinned,
            autoplay: self.autoplay,
            ..device.clone()
        }
        .normalized()
    }
}

fn default_active_profile() -> i64 {
    1
}

/// How often the automatic backup runs (docs/BACKUP.md, section 3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BackupInterval {
    #[default]
    Day,
    Week,
}

/// Choices for how many automatic backups are kept.
pub const BACKUP_KEEP_CHOICES: [u32; 3] = [3, 5, 10];

fn default_backup_keep() -> u32 {
    5
}

/// Automatic backup to a folder (K28, desktop only). Off by default; the
/// `last_*` fields describe the latest run. A device setting: an import
/// keeps this device's value.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AutoBackup {
    pub enabled: bool,
    pub folder: Option<PathBuf>,
    pub interval: BackupInterval,
    #[serde(default = "default_backup_keep")]
    pub keep: u32,
    /// Unix ms of the last successful backup.
    pub last_at: Option<i64>,
    /// Size in bytes of the last successful backup.
    pub last_size: Option<u64>,
    /// Error of the last attempt; `None` after a success.
    pub last_error: Option<String>,
}

impl Default for AutoBackup {
    fn default() -> Self {
        Self {
            enabled: false,
            folder: None,
            interval: BackupInterval::Day,
            keep: default_backup_keep(),
            last_at: None,
            last_size: None,
            last_error: None,
        }
    }
}

impl AutoBackup {
    /// Clamp hand-edited values: `keep` is one of the offered choices.
    pub fn normalized(mut self) -> Self {
        if !BACKUP_KEEP_CHOICES.contains(&self.keep) {
            self.keep = default_backup_keep();
        }
        self.folder = clean_opt_path(self.folder);
        self
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SessionState {
    #[serde(default = "default_volume")]
    pub volume: f64,
    pub shuffle: bool,
    pub repeat: RepeatMode,
    pub queue: Vec<SavedTrack>,
    pub current_index: Option<usize>,
    pub position_seconds: f64,
    pub replaygain: ReplayGain,
    #[serde(default = "default_true")]
    pub gapless: bool,
    #[serde(default)]
    pub wasapi_exclusive: bool,
    /// Closing the window hides it to the tray instead of quitting. Owned by
    /// [`SessionStore`], which fills it in on every save.
    #[serde(default = "default_close_to_tray")]
    pub close_to_tray: bool,
    /// Folder where downloaded tracks/albums are saved. `None` = first library
    /// folder or the OS Music folder.
    #[serde(default)]
    pub download_dir: Option<PathBuf>,
    /// Optional custom path to the `yt-dlp` executable (`None` = search PATH).
    #[serde(default)]
    pub ytdlp_path: Option<PathBuf>,
    /// Albums and playlists pinned by the user to the desktop sidebar.
    #[serde(default)]
    pub pinned: Vec<PinnedRef>,
    /// Where lyrics found online are saved besides the cache. Owned by
    /// [`SessionStore`].
    #[serde(default)]
    pub lyrics_save: SaveMode,
    /// Also search NetEase Cloud Music when LRCLIB has nothing. Owned by
    /// [`SessionStore`].
    #[serde(default = "default_lyrics_netease")]
    pub lyrics_netease: bool,
    /// Autoplay (K18): fitting songs follow when the queue runs out.
    /// Owned by [`SessionStore`].
    #[serde(default = "default_autoplay")]
    pub autoplay: bool,
    /// Master switch: nothing in the app contacts the internet. Owned by
    /// [`SessionStore`].
    #[serde(default)]
    pub offline_mode: bool,
    /// Per-feature internet switches (effective while `offline_mode` is
    /// off). Owned by [`SessionStore`].
    #[serde(default = "default_true")]
    pub net_lyrics: bool,
    #[serde(default = "default_true")]
    pub net_online: bool,
    #[serde(default = "default_true")]
    pub net_artist_info: bool,
    #[serde(default = "default_true")]
    pub net_metadata: bool,
    #[serde(default = "default_true")]
    pub net_updates: bool,
    /// The first-run welcome was finished or skipped. Owned by
    /// [`SessionStore`].
    #[serde(default)]
    pub welcome_done: bool,
    #[serde(default)]
    pub equalizer: crate::audio::Equalizer,
    /// Crossfade length in seconds; 0 = off.
    #[serde(default)]
    pub crossfade_seconds: f64,
    /// PC <-> phone sync (docs/SYNC.md): the desktop listens for paired
    /// phones only while this is on. Off by default. Owned by
    /// [`SessionStore`].
    #[serde(default)]
    pub allow_phone_connections: bool,
    /// Local Jam (K27, docs/JAM.md), experimental: this computer may host
    /// a Jam. Off by default. Owned by [`SessionStore`].
    #[serde(default)]
    pub jam_enabled: bool,
    /// Local Jam: this phone may join a Jam. Off by default. Owned by
    /// [`SessionStore`].
    #[serde(default)]
    pub jam_guest_enabled: bool,
    /// Profiles (K24): the profile the top-level player fields belong to.
    #[serde(default = "default_active_profile")]
    pub active_profile: i64,
    /// Profiles (K24): parked player state of the other profiles.
    #[serde(default)]
    pub profiles: std::collections::BTreeMap<i64, ProfileSession>,
    /// Automatic backup (K28). Owned by [`SessionStore`].
    #[serde(default)]
    pub auto_backup: AutoBackup,
}

impl Default for SessionState {
    fn default() -> Self {
        Self {
            volume: default_volume(),
            shuffle: false,
            repeat: RepeatMode::Off,
            queue: Vec::new(),
            current_index: None,
            position_seconds: 0.0,
            replaygain: ReplayGain::default(),
            gapless: true,
            wasapi_exclusive: false,
            close_to_tray: default_close_to_tray(),
            download_dir: None,
            ytdlp_path: None,
            pinned: Vec::new(),
            lyrics_save: SaveMode::default(),
            lyrics_netease: default_lyrics_netease(),
            autoplay: default_autoplay(),
            offline_mode: false,
            net_lyrics: true,
            net_online: true,
            net_artist_info: true,
            net_metadata: true,
            welcome_done: false,
            equalizer: crate::audio::Equalizer::default(),
            crossfade_seconds: 0.0,
            net_updates: true,
            allow_phone_connections: false,
            jam_enabled: false,
            jam_guest_enabled: false,
            active_profile: default_active_profile(),
            profiles: std::collections::BTreeMap::new(),
            auto_backup: AutoBackup::default(),
        }
    }
}

impl SessionState {
    /// Clamp out-of-range values so corrupted or hand-edited files stay safe.
    pub fn normalized(mut self) -> Self {
        self.volume = if self.volume.is_finite() {
            self.volume.clamp(0.0, 100.0)
        } else {
            default_volume()
        };
        // Online streams (`http(s)://`) are resolved URLs that expire within
        // hours; a restored one would never play. Drop them, keeping the
        // current entry pointed at the same track when it survives.
        let current_path = self
            .current_index
            .and_then(|i| self.queue.get(i))
            .map(|t| t.path.clone());
        self.queue.retain(|t| !is_stream_url(&t.path));
        self.current_index = current_path.and_then(|p| self.queue.iter().position(|t| t.path == p));
        self.position_seconds = if self.current_index.is_some() && self.position_seconds.is_finite()
        {
            self.position_seconds.max(0.0)
        } else {
            0.0
        };
        let mut seen = Vec::with_capacity(self.pinned.len());
        for item in self.pinned {
            if !seen.contains(&item) {
                seen.push(item);
            }
        }
        self.pinned = seen;
        self.auto_backup = self.auto_backup.normalized();
        self
    }
}

/// Whether a queue path is a resolved online stream or network URI/UNC path
/// rather than a local file.
pub fn is_stream_url(path: &Path) -> bool {
    let s = path.to_string_lossy();
    if s.starts_with("\\\\") || s.starts_with("//") {
        return true;
    }
    let lower = s.to_ascii_lowercase();
    const SCHEMES: &[&str] = &[
        "http://", "https://", "rtsp://", "rtmps://", "rtmp://", "mms://", "mmsh://", "ftp://",
        "sftp://", "smb://", "tcp://", "udp://", "hls://",
    ];
    SCHEMES.iter().any(|scheme| lower.starts_with(scheme))
}

pub fn load(path: &Path) -> SessionState {
    let Ok(bytes) = std::fs::read(path) else {
        return SessionState::default();
    };
    serde_json::from_slice::<SessionState>(&bytes)
        .map(SessionState::normalized)
        .unwrap_or_default()
}

pub fn save(path: &Path, state: &SessionState) -> std::io::Result<()> {
    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_vec(&state.clone().normalized())
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    write_atomic(path, &json)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct StructuralKey {
    queue_version: u64,
    current_index: Option<usize>,
    shuffle: bool,
    repeat: RepeatMode,
    replaygain: ReplayGain,
    gapless: bool,
    wasapi_exclusive: bool,
    /// Equalizer (enabled, preamp, ten gains) and crossfade as raw bits.
    sound: [u64; 13],
}

impl From<&PlayerSnapshot> for StructuralKey {
    fn from(s: &PlayerSnapshot) -> Self {
        Self {
            queue_version: s.queue_version,
            current_index: s.current_index,
            shuffle: s.shuffle,
            repeat: s.repeat,
            replaygain: s.replaygain,
            gapless: s.gapless,
            wasapi_exclusive: s.wasapi_exclusive,
            sound: {
                let eq = &s.equalizer;
                let mut bits = [0u64; 13];
                bits[0] = u64::from(eq.enabled);
                bits[1] = eq.preamp_db.to_bits();
                for (slot, g) in bits[2..12].iter_mut().zip(eq.gains_db) {
                    *slot = g.to_bits();
                }
                bits[12] = s.crossfade_seconds.to_bits();
                bits
            },
        }
    }
}

#[derive(Default)]
struct GuardState {
    last_written_at: Option<Instant>,
    last_structure: Option<StructuralKey>,
    last_queue_version: Option<u64>,
    last: SessionState,
}

fn clean_opt_path(path: Option<PathBuf>) -> Option<PathBuf> {
    path.filter(|p| !p.as_os_str().is_empty())
}

/// Serializes disk writes and throttles high-frequency position/volume saves.
pub struct SessionStore {
    path: PathBuf,
    guard: Mutex<GuardState>,
    close_to_tray: AtomicBool,
    download_dir: Mutex<Option<PathBuf>>,
    ytdlp_path: Mutex<Option<PathBuf>>,
    pinned: Mutex<Vec<PinnedRef>>,
    lyrics_save: Mutex<SaveMode>,
    lyrics_netease: AtomicBool,
    autoplay: AtomicBool,
    welcome_done: AtomicBool,
    allow_phone_connections: AtomicBool,
    jam_enabled: AtomicBool,
    jam_guest_enabled: AtomicBool,
    active_profile: std::sync::atomic::AtomicI64,
    parked: Mutex<std::collections::BTreeMap<i64, ProfileSession>>,
    auto_backup: Mutex<AutoBackup>,
    net: Arc<NetPolicy>,
}

impl SessionStore {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            guard: Mutex::new(GuardState::default()),
            close_to_tray: AtomicBool::new(default_close_to_tray()),
            download_dir: Mutex::new(None),
            ytdlp_path: Mutex::new(None),
            pinned: Mutex::new(Vec::new()),
            lyrics_save: Mutex::new(SaveMode::default()),
            lyrics_netease: AtomicBool::new(default_lyrics_netease()),
            autoplay: AtomicBool::new(default_autoplay()),
            welcome_done: AtomicBool::new(false),
            allow_phone_connections: AtomicBool::new(false),
            jam_enabled: AtomicBool::new(false),
            jam_guest_enabled: AtomicBool::new(false),
            active_profile: std::sync::atomic::AtomicI64::new(default_active_profile()),
            parked: Mutex::new(std::collections::BTreeMap::new()),
            auto_backup: Mutex::new(AutoBackup::default()),
            net: Arc::new(NetPolicy::default()),
        }
    }

    /// The shared internet policy; services hold a clone of it.
    pub fn net_policy(&self) -> Arc<NetPolicy> {
        Arc::clone(&self.net)
    }

    /// Whether `feature` may contact the internet now: false in offline
    /// mode or when its own switch is off.
    pub fn net_allowed(&self, feature: Feature) -> bool {
        self.net.allowed(feature)
    }

    /// Loads the saved state and adopts its window and download settings.
    pub fn load(&self) -> SessionState {
        let state = load(&self.path);
        self.close_to_tray
            .store(state.close_to_tray, Ordering::SeqCst);
        *self.download_dir.lock().unwrap_or_else(|e| e.into_inner()) =
            clean_opt_path(state.download_dir.clone());
        *self.ytdlp_path.lock().unwrap_or_else(|e| e.into_inner()) =
            clean_opt_path(state.ytdlp_path.clone());
        *self.pinned.lock().unwrap_or_else(|e| e.into_inner()) = state.pinned.clone();
        *self.lyrics_save.lock().unwrap_or_else(|e| e.into_inner()) = state.lyrics_save;
        self.lyrics_netease
            .store(state.lyrics_netease, Ordering::SeqCst);
        self.autoplay.store(state.autoplay, Ordering::SeqCst);
        self.welcome_done
            .store(state.welcome_done, Ordering::SeqCst);
        self.allow_phone_connections
            .store(state.allow_phone_connections, Ordering::SeqCst);
        self.jam_enabled.store(state.jam_enabled, Ordering::SeqCst);
        self.jam_guest_enabled
            .store(state.jam_guest_enabled, Ordering::SeqCst);
        self.active_profile
            .store(state.active_profile, Ordering::SeqCst);
        {
            let mut parked = self.parked.lock().unwrap_or_else(|e| e.into_inner());
            *parked = state.profiles.clone();
            // Never park the active profile's own state twice.
            parked.remove(&state.active_profile);
        }
        *self.auto_backup.lock().unwrap_or_else(|e| e.into_inner()) = state.auto_backup.clone();
        self.net.set_offline(state.offline_mode);
        self.net.set_feature(Feature::Lyrics, state.net_lyrics);
        self.net.set_feature(Feature::Online, state.net_online);
        self.net
            .set_feature(Feature::ArtistInfo, state.net_artist_info);
        self.net.set_feature(Feature::Metadata, state.net_metadata);
        self.net.set_feature(Feature::Updates, state.net_updates);
        state
    }

    pub fn lyrics_save(&self) -> SaveMode {
        *self.lyrics_save.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn set_lyrics_save(&self, mode: SaveMode) {
        *self.lyrics_save.lock().unwrap_or_else(|e| e.into_inner()) = mode;
    }

    pub fn autoplay(&self) -> bool {
        self.autoplay.load(Ordering::SeqCst)
    }

    pub fn set_autoplay(&self, enabled: bool) {
        self.autoplay.store(enabled, Ordering::SeqCst);
    }

    pub fn allow_phone_connections(&self) -> bool {
        self.allow_phone_connections.load(Ordering::SeqCst)
    }

    pub fn set_allow_phone_connections(&self, enabled: bool) {
        self.allow_phone_connections
            .store(enabled, Ordering::SeqCst);
    }

    pub fn jam_enabled(&self) -> bool {
        self.jam_enabled.load(Ordering::SeqCst)
    }

    pub fn set_jam_enabled(&self, enabled: bool) {
        self.jam_enabled.store(enabled, Ordering::SeqCst);
    }

    pub fn jam_guest_enabled(&self) -> bool {
        self.jam_guest_enabled.load(Ordering::SeqCst)
    }

    pub fn set_jam_guest_enabled(&self, enabled: bool) {
        self.jam_guest_enabled.store(enabled, Ordering::SeqCst);
    }

    pub fn auto_backup(&self) -> AutoBackup {
        self.auto_backup
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// Changes the automatic backup settings in memory; the caller saves.
    pub fn update_auto_backup(&self, f: impl FnOnce(&mut AutoBackup)) -> AutoBackup {
        let mut a = self.auto_backup.lock().unwrap_or_else(|e| e.into_inner());
        f(&mut a);
        *a = a.clone().normalized();
        a.clone()
    }

    pub fn lyrics_netease(&self) -> bool {
        self.lyrics_netease.load(Ordering::SeqCst)
    }

    pub fn set_lyrics_netease(&self, enabled: bool) {
        self.lyrics_netease.store(enabled, Ordering::SeqCst);
    }

    pub fn offline_mode(&self) -> bool {
        self.net.offline()
    }

    pub fn set_offline_mode(&self, enabled: bool) {
        self.net.set_offline(enabled);
    }

    /// The user's own switch for `feature` (ignores offline mode).
    pub fn net_feature(&self, feature: Feature) -> bool {
        self.net.feature_enabled(feature)
    }

    pub fn set_net_feature(&self, feature: Feature, enabled: bool) {
        self.net.set_feature(feature, enabled);
    }

    pub fn welcome_done(&self) -> bool {
        self.welcome_done.load(Ordering::SeqCst)
    }

    pub fn set_welcome_done(&self, done: bool) {
        self.welcome_done.store(done, Ordering::SeqCst);
    }

    pub fn close_to_tray(&self) -> bool {
        self.close_to_tray.load(Ordering::SeqCst)
    }

    pub fn set_close_to_tray(&self, enabled: bool) {
        self.close_to_tray.store(enabled, Ordering::SeqCst);
    }

    pub fn download_dir(&self) -> Option<PathBuf> {
        self.download_dir
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    pub fn set_download_dir(&self, dir: Option<PathBuf>) {
        *self.download_dir.lock().unwrap_or_else(|e| e.into_inner()) = clean_opt_path(dir);
    }

    pub fn ytdlp_path(&self) -> Option<PathBuf> {
        self.ytdlp_path
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    pub fn set_ytdlp_path(&self, path: Option<PathBuf>) {
        *self.ytdlp_path.lock().unwrap_or_else(|e| e.into_inner()) = clean_opt_path(path);
    }

    pub fn pinned(&self) -> Vec<PinnedRef> {
        self.pinned
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    pub fn toggle_pin(&self, item: PinnedRef) -> bool {
        let mut pinned = self.pinned.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(pos) = pinned.iter().position(|p| *p == item) {
            pinned.remove(pos);
            false
        } else {
            pinned.push(item);
            true
        }
    }

    /// Profiles (K24): the profile whose player state the top-level fields
    /// hold.
    pub fn active_profile(&self) -> i64 {
        self.active_profile.load(Ordering::SeqCst)
    }

    /// Profiles (K24): parks `leaving` (the active profile's full state, from
    /// `Player::take_for_profile_switch`) and returns the state to load for
    /// profile `to`: its parked queue, pins and autoplay with this device's
    /// settings. Saves at once.
    pub fn switch_profile(&self, leaving: SessionState, to: i64) -> SessionState {
        let from = self.active_profile();
        let mut leaving = leaving;
        self.apply_store_fields(&mut leaving);
        let next = {
            let mut parked = self.parked.lock().unwrap_or_else(|e| e.into_inner());
            parked.insert(from, ProfileSession::from_state(&leaving));
            parked.remove(&to).unwrap_or_default()
        };
        let state = next.into_state(&leaving);
        *self.pinned.lock().unwrap_or_else(|e| e.into_inner()) = state.pinned.clone();
        self.autoplay.store(state.autoplay, Ordering::SeqCst);
        self.active_profile.store(to, Ordering::SeqCst);
        self.save_now(&state);
        state
    }

    /// Profiles (K24): the saved active profile no longer exists; the
    /// top-level player state now belongs to `id`.
    pub fn adopt_active_profile(&self, id: i64) {
        self.active_profile.store(id, Ordering::SeqCst);
        self.parked
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&id);
    }

    /// Profiles (K24): forgets a deleted profile's parked state.
    pub fn forget_profile(&self, id: i64) {
        self.parked
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&id);
    }

    fn apply_store_fields(&self, state: &mut SessionState) {
        state.close_to_tray = self.close_to_tray();
        state.download_dir = self.download_dir();
        state.ytdlp_path = self.ytdlp_path();
        state.pinned = self.pinned();
        state.lyrics_save = self.lyrics_save();
        state.lyrics_netease = self.lyrics_netease();
        state.autoplay = self.autoplay();
        state.welcome_done = self.welcome_done();
        state.allow_phone_connections = self.allow_phone_connections();
        state.jam_enabled = self.jam_enabled();
        state.jam_guest_enabled = self.jam_guest_enabled();
        state.active_profile = self.active_profile();
        state.profiles = self
            .parked
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        state.auto_backup = self.auto_backup();
        state.offline_mode = self.net.offline();
        state.net_lyrics = self.net.feature_enabled(Feature::Lyrics);
        state.net_online = self.net.feature_enabled(Feature::Online);
        state.net_artist_info = self.net.feature_enabled(Feature::ArtistInfo);
        state.net_metadata = self.net.feature_enabled(Feature::Metadata);
        state.net_updates = self.net.feature_enabled(Feature::Updates);
    }

    fn write_locked(&self, g: &mut GuardState, mut state: SessionState, now: Instant) -> bool {
        self.apply_store_fields(&mut state);
        if let Err(e) = save(&self.path, &state) {
            log::warn!("failed to save session state: {e}");
            false
        } else {
            g.last_written_at = Some(now);
            g.last = state;
            true
        }
    }

    pub fn save_now(&self, state: &SessionState) {
        let mut g = self.guard.lock().unwrap_or_else(|e| e.into_inner());
        g.last_queue_version = None;
        self.write_locked(&mut g, state.clone(), Instant::now());
    }

    pub fn on_player_state(&self, snap: &PlayerSnapshot, build: impl FnOnce() -> SessionState) {
        let key = StructuralKey::from(snap);
        let now = Instant::now();
        let mut g = self.guard.lock().unwrap_or_else(|e| e.into_inner());
        let structure_changed = g.last_structure != Some(key);
        let due = g
            .last_written_at
            .is_none_or(|t| now.duration_since(t) >= VOLUME_SAVE_INTERVAL);
        if !structure_changed && !due {
            return;
        }
        if self.write_locked(&mut g, build(), now) {
            g.last_queue_version = Some(snap.queue_version);
        } else {
            g.last_queue_version = None;
        }
        g.last_structure = Some(key);
    }

    pub fn maybe_save_position(&self, build: impl FnOnce() -> SessionState) {
        let now = Instant::now();
        let mut g = self.guard.lock().unwrap_or_else(|e| e.into_inner());
        let due = g
            .last_written_at
            .is_none_or(|t| now.duration_since(t) >= POSITION_SAVE_INTERVAL);
        if !due {
            return;
        }
        g.last_queue_version = None;
        self.write_locked(&mut g, build(), now);
    }

    /// Saves playback progress at most once per `POSITION_SAVE_INTERVAL`,
    /// reusing the cached queue when `queue_version` has not changed so the
    /// caller avoids cloning `Vec<SavedTrack>` on the `Player` mutex.
    pub fn maybe_save_progress(
        &self,
        queue_version: u64,
        current_index: Option<usize>,
        position_seconds: f64,
        build: impl FnOnce() -> SessionState,
    ) {
        let now = Instant::now();
        let mut g = self.guard.lock().unwrap_or_else(|e| e.into_inner());
        let due = g
            .last_written_at
            .is_none_or(|t| now.duration_since(t) >= POSITION_SAVE_INTERVAL);
        if !due {
            return;
        }
        if g.last_queue_version == Some(queue_version)
            && current_index.is_none_or(|i| i < g.last.queue.len())
        {
            g.last.current_index = current_index;
            g.last.position_seconds = if position_seconds.is_finite() && position_seconds >= 0.0 {
                position_seconds
            } else {
                0.0
            };
            self.apply_store_fields(&mut g.last);
            if let Err(e) = save(&self.path, &g.last) {
                log::warn!("failed to save session state: {e}");
                g.last_queue_version = None;
            } else {
                g.last_written_at = Some(now);
            }
            return;
        }
        if self.write_locked(&mut g, build(), now) {
            g.last_queue_version = Some(queue_version);
        } else {
            g.last_queue_version = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn missing_or_corrupt_file_falls_back_to_default() {
        let dir = TempDir::new().unwrap();
        assert_eq!(
            load(&dir.path().join("missing.json")),
            SessionState::default()
        );

        let bad = dir.path().join("bad.json");
        std::fs::write(&bad, "{not valid json").unwrap();
        assert_eq!(load(&bad), SessionState::default());
    }

    #[test]
    fn roundtrip_and_normalization() {
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("nested/session.json");
        let state = SessionState {
            volume: 42.5,
            shuffle: true,
            repeat: RepeatMode::All,
            queue: vec![SavedTrack {
                path: PathBuf::from("/music/track.flac"),
                title: Some("Track".into()),
                artist: Some("Artist".into()),
            }],
            current_index: Some(0),
            position_seconds: 18.25,
            replaygain: ReplayGain::Track,
            gapless: false,
            wasapi_exclusive: true,
            close_to_tray: false,
            download_dir: Some(PathBuf::from("/music/downloads")),
            ytdlp_path: None,
            pinned: vec![
                PinnedRef {
                    kind: PinnedKind::Album,
                    id: 7,
                },
                PinnedRef {
                    kind: PinnedKind::Playlist,
                    id: 3,
                },
            ],
            lyrics_save: SaveMode::Embed,
            lyrics_netease: false,
            autoplay: false,
            offline_mode: true,
            net_lyrics: false,
            net_online: true,
            net_artist_info: false,
            net_metadata: true,
            net_updates: false,
            welcome_done: true,
            equalizer: crate::audio::Equalizer {
                enabled: true,
                preamp_db: -2.0,
                gains_db: [3.0, 2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 3.0],
            },
            crossfade_seconds: 6.0,
            allow_phone_connections: true,
            jam_enabled: true,
            jam_guest_enabled: true,
            active_profile: 2,
            profiles: [(1, ProfileSession::default())].into_iter().collect(),
            auto_backup: AutoBackup {
                enabled: true,
                folder: Some(PathBuf::from("/backups")),
                interval: BackupInterval::Week,
                keep: 10,
                last_at: Some(1_700_000_000_000),
                last_size: Some(1234),
                last_error: None,
            },
        };
        save(&file, &state).unwrap();
        assert_eq!(load(&file), state);

        let clamped = SessionState {
            volume: 150.0,
            shuffle: false,
            repeat: RepeatMode::One,
            queue: vec![],
            current_index: Some(3),
            position_seconds: 99.0,
            replaygain: ReplayGain::Off,
            ..SessionState::default()
        }
        .normalized();
        assert_eq!(clamped.volume, 100.0);
        assert_eq!(clamped.current_index, None);
        assert_eq!(clamped.position_seconds, 0.0);
    }

    #[test]
    fn old_session_files_without_replaygain_still_load() {
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("session.json");
        std::fs::write(&file, r#"{"volume":55.0,"shuffle":true}"#).unwrap();
        let s = load(&file);
        assert_eq!(s.volume, 55.0);
        assert!(s.shuffle);
        assert_eq!(s.replaygain, ReplayGain::Album);
        assert!(s.gapless);
        assert!(!s.wasapi_exclusive);

        let json = serde_json::to_value(SessionState {
            replaygain: ReplayGain::Off,
            gapless: false,
            wasapi_exclusive: true,
            ..SessionState::default()
        })
        .unwrap();
        assert_eq!(json["replaygain"], "off");
        assert_eq!(json["gapless"], false);
        assert_eq!(json["wasapiExclusive"], true);
    }

    #[test]
    fn close_to_tray_defaults_on_and_is_persisted_by_the_store() {
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("session.json");

        // Old files without the field, and missing files, default to on.
        std::fs::write(&file, r#"{"volume":55.0}"#).unwrap();
        assert!(load(&file).close_to_tray);
        assert!(SessionState::default().close_to_tray);
        assert!(SessionStore::new(file.clone()).close_to_tray());
        assert!(SessionStore::new(file.clone()).load().close_to_tray);

        // The store writes its own value, whatever the state it is given says.
        let store = SessionStore::new(file.clone());
        store.set_close_to_tray(false);
        store.save_now(&SessionState::default());
        assert!(!load(&file).close_to_tray);
        let json: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(json["closeToTray"], false);

        // ...and a new store picks it up on load.
        let again = SessionStore::new(file.clone());
        assert!(again.close_to_tray());
        assert!(!again.load().close_to_tray);
        assert!(!again.close_to_tray());

        // Later saves driven by player events keep the value.
        again.maybe_save_position(SessionState::default);
        assert!(!load(&file).close_to_tray);
    }

    fn track(name: &str) -> SavedTrack {
        SavedTrack {
            path: PathBuf::from(name),
            title: None,
            artist: None,
        }
    }

    #[test]
    fn each_profile_keeps_its_own_queue_pins_and_autoplay() {
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("session.json");
        // A file from before profiles: everything is profile 1's.
        std::fs::write(
            &file,
            r#"{"volume":40.0,"queue":[{"path":"a.flac"}],"currentIndex":0,"positionSeconds":12.5,"shuffle":true,"pinned":[{"kind":"album","id":3}]}"#,
        )
        .unwrap();
        let store = SessionStore::new(file.clone());
        let loaded = store.load();
        assert_eq!(store.active_profile(), 1);
        assert_eq!(loaded.queue, vec![track("a.flac")]);

        // Switch to a new profile 2: an empty queue, device settings kept.
        let for_two = store.switch_profile(loaded.clone(), 2);
        assert_eq!(store.active_profile(), 2);
        assert!(for_two.queue.is_empty());
        assert!(!for_two.shuffle);
        assert!(store.pinned().is_empty());
        assert_eq!(for_two.volume, 40.0);

        // Profile 2 builds its own state; it survives a restart.
        let mut two = for_two;
        two.queue = vec![track("b.flac")];
        two.current_index = Some(0);
        store.set_autoplay(false);
        store.save_now(&two);
        let again = SessionStore::new(file.clone());
        let reloaded = again.load();
        assert_eq!(again.active_profile(), 2);
        assert_eq!(reloaded.queue, vec![track("b.flac")]);
        assert!(!again.autoplay());

        // Back to profile 1: its queue, position, shuffle and pins return.
        let one = again.switch_profile(reloaded, 1);
        assert_eq!(one.queue, vec![track("a.flac")]);
        assert_eq!(one.current_index, Some(0));
        assert_eq!(one.position_seconds, 12.5);
        assert!(one.shuffle);
        assert!(again.autoplay());
        assert_eq!(
            again.pinned(),
            vec![PinnedRef {
                kind: PinnedKind::Album,
                id: 3
            }]
        );
        // ...and profile 2's is parked for later.
        let on_disk = load(&file);
        assert_eq!(on_disk.active_profile, 1);
        assert_eq!(on_disk.profiles[&2].queue, vec![track("b.flac")]);
        assert!(!on_disk.profiles.contains_key(&1));

        again.forget_profile(2);
        again.save_now(&one);
        assert!(load(&file).profiles.is_empty());
    }

    #[test]
    fn autoplay_is_on_by_default_and_persists() {
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("session.json");
        std::fs::write(&file, r#"{"volume":55.0}"#).unwrap();
        assert!(load(&file).autoplay, "old files: on, like Spotify");
        let store = SessionStore::new(file.clone());
        store.load();
        assert!(store.autoplay());
        store.set_autoplay(false);
        store.save_now(&SessionState::default());
        let again = SessionStore::new(file);
        again.load();
        assert!(!again.autoplay());
    }

    #[test]
    fn phone_connections_are_off_by_default_and_persist() {
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("session.json");
        std::fs::write(&file, r#"{"volume":55.0}"#).unwrap();
        assert!(!load(&file).allow_phone_connections);
        let store = SessionStore::new(file.clone());
        store.load();
        assert!(!store.allow_phone_connections());
        store.set_allow_phone_connections(true);
        store.save_now(&SessionState::default());
        let again = SessionStore::new(file);
        again.load();
        assert!(again.allow_phone_connections());
    }

    #[test]
    fn jam_switches_are_off_by_default_and_persist() {
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("session.json");
        std::fs::write(&file, r#"{"volume":55.0}"#).unwrap();
        let old = load(&file);
        assert!(!old.jam_enabled && !old.jam_guest_enabled);
        let store = SessionStore::new(file.clone());
        store.load();
        assert!(!store.jam_enabled() && !store.jam_guest_enabled());
        store.set_jam_enabled(true);
        store.set_jam_guest_enabled(true);
        store.save_now(&SessionState::default());
        let again = SessionStore::new(file);
        again.load();
        assert!(again.jam_enabled() && again.jam_guest_enabled());
    }

    #[test]
    fn lyrics_settings_default_and_persist_through_the_store() {
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("session.json");

        // Old files and missing files: sidecar saving, NetEase on.
        std::fs::write(&file, r#"{"volume":55.0}"#).unwrap();
        let state = load(&file);
        assert_eq!(state.lyrics_save, SaveMode::Sidecar);
        assert!(state.lyrics_netease);

        let store = SessionStore::new(file.clone());
        assert_eq!(store.lyrics_save(), SaveMode::Sidecar);
        assert!(store.lyrics_netease());
        store.set_lyrics_save(SaveMode::Off);
        store.set_lyrics_netease(false);
        store.save_now(&SessionState::default());
        let json: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(json["lyricsSave"], "off");
        assert_eq!(json["lyricsNetease"], false);

        let again = SessionStore::new(file);
        let state = again.load();
        assert_eq!(state.lyrics_save, SaveMode::Off);
        assert_eq!(again.lyrics_save(), SaveMode::Off);
        assert!(!again.lyrics_netease());
    }

    #[test]
    fn net_switches_default_on_and_persist_through_the_store() {
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("session.json");

        // An old file without the fields: online, every feature allowed.
        std::fs::write(&file, r#"{"volume":55.0}"#).unwrap();
        let state = load(&file);
        assert!(!state.offline_mode);
        assert!(state.net_lyrics && state.net_online && state.net_artist_info);
        assert!(state.net_metadata && state.net_updates);
        let store = SessionStore::new(file.clone());
        store.load();
        for f in Feature::ALL {
            assert!(store.net_allowed(f), "{f:?}");
        }

        // A feature switch only affects its own feature.
        store.set_net_feature(Feature::Metadata, false);
        assert!(!store.net_allowed(Feature::Metadata));
        assert!(store.net_allowed(Feature::Lyrics));

        // Offline mode wins over every switch but keeps them as they are.
        store.set_offline_mode(true);
        for f in Feature::ALL {
            assert!(!store.net_allowed(f), "{f:?}");
        }
        assert!(store.net_feature(Feature::Lyrics));
        store.save_now(&SessionState::default());

        let json: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(json["offlineMode"], true);
        assert_eq!(json["netMetadata"], false);
        assert_eq!(json["netLyrics"], true);

        let again = SessionStore::new(file);
        again.load();
        assert!(again.offline_mode());
        assert!(!again.net_feature(Feature::Metadata));
        assert!(again.net_feature(Feature::Updates));
        assert!(!again.net_allowed(Feature::Updates));
        again.set_offline_mode(false);
        assert!(again.net_allowed(Feature::Updates));
        assert!(!again.net_allowed(Feature::Metadata));
    }

    #[test]
    fn pinned_items_dedup_toggle_and_persist() {
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("session.json");
        let album = PinnedRef {
            kind: PinnedKind::Album,
            id: 42,
        };
        let playlist = PinnedRef {
            kind: PinnedKind::Playlist,
            id: 9,
        };

        let store = SessionStore::new(file.clone());
        assert!(store.toggle_pin(album));
        assert!(store.toggle_pin(playlist));
        assert_eq!(store.pinned(), vec![album, playlist]);
        store.save_now(&SessionState::default());

        let reloaded = SessionStore::new(file.clone());
        let state = reloaded.load();
        assert_eq!(state.pinned, vec![album, playlist]);
        assert!(!reloaded.toggle_pin(album));
        assert_eq!(reloaded.pinned(), vec![playlist]);
    }

    #[test]
    fn is_stream_url_detects_streams_and_unc_paths() {
        assert!(is_stream_url(Path::new("http://example.com/stream.mp3")));
        assert!(is_stream_url(Path::new("https://example.com/stream.mp3")));
        assert!(is_stream_url(Path::new("HTTPS://example.com/stream.mp3")));
        assert!(is_stream_url(Path::new("rtsp://example.com/a")));
        assert!(is_stream_url(Path::new("RTSP://example.com/a")));
        assert!(is_stream_url(Path::new("rtmps://example.com/a")));
        assert!(is_stream_url(Path::new("rtmp://example.com/a")));
        assert!(is_stream_url(Path::new("mms://example.com/a")));
        assert!(is_stream_url(Path::new("mmsh://example.com/a")));
        assert!(is_stream_url(Path::new("ftp://example.com/a")));
        assert!(is_stream_url(Path::new("sftp://example.com/a")));
        assert!(is_stream_url(Path::new("smb://server/share/song.mp3")));
        assert!(is_stream_url(Path::new("tcp://127.0.0.1:9000")));
        assert!(is_stream_url(Path::new("udp://127.0.0.1:9000")));
        assert!(is_stream_url(Path::new("hls://example.com/master.m3u8")));
        assert!(is_stream_url(Path::new(r"\\server\share\song.mp3")));
        assert!(is_stream_url(Path::new("//server/share/song.mp3")));

        assert!(!is_stream_url(Path::new(r"C:\Music\song.mp3")));
        assert!(!is_stream_url(Path::new("/music/song.mp3")));
        assert!(!is_stream_url(Path::new(
            "content://media/external/audio/1"
        )));
    }

    #[test]
    fn maybe_save_progress_reuses_cached_queue_across_same_version_ticks() {
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("session.json");
        let store = SessionStore::new(file.clone());
        let track = SavedTrack {
            path: PathBuf::from("/music/song.flac"),
            title: Some("Song".into()),
            artist: Some("Artist".into()),
        };

        let mut build_calls = 0usize;
        store.maybe_save_progress(7, Some(0), 12.5, || {
            build_calls += 1;
            SessionState {
                queue: vec![track.clone()],
                current_index: Some(0),
                position_seconds: 12.5,
                ..SessionState::default()
            }
        });
        assert_eq!(build_calls, 1);
        assert_eq!(load(&file).position_seconds, 12.5);
        assert_eq!(load(&file).queue, vec![track.clone()]);

        // Throttled within 5 seconds: neither builds nor writes.
        store.maybe_save_progress(7, Some(0), 15.0, || {
            build_calls += 1;
            SessionState::default()
        });
        assert_eq!(build_calls, 1);
        assert_eq!(load(&file).position_seconds, 12.5);

        // Simulate elapsed save interval; same queue_version must skip build().
        store
            .guard
            .lock()
            .unwrap()
            .last_written_at
            .replace(Instant::now() - POSITION_SAVE_INTERVAL - Duration::from_secs(1));
        store.maybe_save_progress(7, Some(0), 27.5, || {
            build_calls += 1;
            panic!("build should not be called when queue_version is unchanged");
        });
        assert_eq!(build_calls, 1);
        let saved = load(&file);
        assert_eq!(saved.position_seconds, 27.5);
        assert_eq!(saved.current_index, Some(0));
        assert_eq!(saved.queue, vec![track.clone()]);

        // Changing queue_version after the interval rebuilds once and caches again.
        store
            .guard
            .lock()
            .unwrap()
            .last_written_at
            .replace(Instant::now() - POSITION_SAVE_INTERVAL - Duration::from_secs(1));
        let track2 = SavedTrack {
            path: PathBuf::from("/music/second.flac"),
            title: Some("Second".into()),
            artist: Some("Artist".into()),
        };
        store.maybe_save_progress(8, Some(1), 3.0, || {
            build_calls += 1;
            SessionState {
                queue: vec![track.clone(), track2.clone()],
                current_index: Some(1),
                position_seconds: 3.0,
                ..SessionState::default()
            }
        });
        assert_eq!(build_calls, 2);
        let saved = load(&file);
        assert_eq!(saved.queue.len(), 2);
        assert_eq!(saved.current_index, Some(1));
        assert_eq!(saved.position_seconds, 3.0);

        // Explicit save_now resets cached queue_version so the next progress tick resyncs once.
        store.save_now(&SessionState {
            queue: vec![track.clone()],
            current_index: Some(0),
            position_seconds: 1.0,
            ..SessionState::default()
        });
        store
            .guard
            .lock()
            .unwrap()
            .last_written_at
            .replace(Instant::now() - POSITION_SAVE_INTERVAL - Duration::from_secs(1));
        store.maybe_save_progress(8, Some(0), 9.0, || {
            build_calls += 1;
            SessionState {
                queue: vec![track.clone()],
                current_index: Some(0),
                position_seconds: 9.0,
                ..SessionState::default()
            }
        });
        assert_eq!(build_calls, 3);
        assert_eq!(load(&file).position_seconds, 9.0);
    }
}

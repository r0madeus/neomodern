//! Music library: folder scanning (`walkdir`), tags and embedded covers
//! (`lofty`), SQLite storage (`rusqlite`). Covers are written to a cache
//! folder and shown through the asset protocol, never sent over IPC as
//! base64 (architecture rule 4). Song lists are paged over IPC (rule 4).
//!
//! * [`db`] – schema (versioned with `PRAGMA user_version`) and queries.
//! * [`scan`] – incremental folder scan: walk, read tags, extract covers.
//! * [`Library`] – thread-safe facade: one SQLite connection behind a
//!   mutex, a change `version` counter and a `scanning` flag.
//!
//! Scans run on a background thread, one at a time. Folders requested while
//! a scan is running are queued and processed by the same worker thread.
//! The database lock is only held while a batch (~500 files) is written, so
//! queries stay responsive during a scan.

pub mod alpha;
pub mod autoplay;
pub mod cover_color;
pub mod db;
pub mod m3u;
pub mod profiles;
pub mod scan;
pub mod tags;

use crate::queue::Track;
use rusqlite::Connection;
use serde::Serialize;
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

pub use db::{SortDir, SortOrder, SortSpec};
pub use profiles::{
    DEFAULT_FIRST_PROFILE_NAME, MAX_PROFILES, PROFILE_COLORS, Profile, ProfileId, ProfileSummary,
};
pub use scan::ScanStats;

#[derive(Debug, thiserror::Error)]
pub enum LibraryError {
    #[error("database error: {0}")]
    Db(#[from] rusqlite::Error),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("{0} not found")]
    NotFound(String),
    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, LibraryError>;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct FolderInfo {
    pub id: i64,
    pub path: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryStats {
    pub tracks: u64,
    pub albums: u64,
    pub version: u64,
    pub scanning: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrackMeta {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TrackRow {
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
    /// Absolute path of the album's cached cover, if any.
    pub cover: Option<String>,
    /// How many times it was played (0 where a list does not count).
    pub plays: u32,
    /// When it was added to the playlist (unix seconds); only in playlist
    /// listings.
    pub added_to_playlist: Option<i64>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AlbumRow {
    pub id: i64,
    pub title: String,
    pub album_artist: String,
    pub year: Option<i32>,
    pub track_count: u32,
    /// Absolute path of the cover file in the cache folder, if any.
    pub cover: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PlaylistInfo {
    pub id: i64,
    pub name: String,
    pub track_count: u32,
    pub cover: Option<String>,
    pub album_covers: Vec<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct FavoriteRef {
    pub track_id: i64,
    pub path: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewListenEvent {
    pub path: String,
    pub title: String,
    pub artist: String,
    pub duration_ms: Option<u64>,
    pub started_at: i64,
    pub ended_at: i64,
    pub listened_ms: u64,
    pub completed: bool,
    pub skipped: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct StatsSummary {
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
    pub top_hour: Option<u32>,
    pub top_weekday: Option<u32>,
    pub first_listen_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TopTrackStat {
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

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TopArtistStat {
    pub artist: String,
    pub cover: Option<String>,
    pub play_count: u64,
    pub listened_ms: u64,
    pub unique_tracks: u64,
    pub skip_count: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TopAlbumStat {
    pub album: String,
    pub artist: String,
    pub album_id: Option<i64>,
    pub cover: Option<String>,
    pub play_count: u64,
    pub listened_ms: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TopGenreStat {
    pub genre: String,
    pub play_count: u64,
    pub listened_ms: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct BucketStat {
    pub label: String,
    pub listened_ms: u64,
    pub play_count: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RecentListen {
    pub id: i64,
    pub track_id: Option<i64>,
    pub path: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub cover: Option<String>,
    pub started_at: i64,
    pub listened_ms: u64,
    pub completed: bool,
    pub skipped: bool,
    pub source: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ListeningStats {
    pub summary: StatsSummary,
    pub top_tracks_by_plays: Vec<TopTrackStat>,
    pub top_tracks_by_time: Vec<TopTrackStat>,
    pub top_artists_by_time: Vec<TopArtistStat>,
    pub top_albums_by_time: Vec<TopAlbumStat>,
    pub top_genres: Vec<TopGenreStat>,
    pub by_hour: Vec<BucketStat>,
    pub by_weekday: Vec<BucketStat>,
    pub by_month: Vec<BucketStat>,
    pub recent: Vec<RecentListen>,
    pub available_years: Vec<i32>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DynamicMix {
    pub id: String,
    pub kind: String,
    pub title_key: String,
    pub subject: Option<String>,
    pub subtitle_key: String,
    pub track_count: u32,
    pub album_covers: Vec<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RecentTrack {
    pub track: TrackRow,
    pub started_at: i64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct HomeFeed {
    pub recently_played_albums: Vec<AlbumRow>,
    pub recently_played_tracks: Vec<RecentTrack>,
    pub recently_added_albums: Vec<AlbumRow>,
    pub favorite_tracks: Vec<TrackRow>,
    pub favorite_count: u64,
    pub mixes: Vec<DynamicMix>,
    pub has_history: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct HomeMixDetail {
    pub mix: DynamicMix,
    pub tracks: Vec<TrackRow>,
}

/// Result of importing an M3U playlist.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ImportedPlaylist {
    pub playlist: PlaylistInfo,
    pub matched: usize,
    /// Entries with no matching song in this library.
    pub missing: usize,
}

/// Result of saving the queue as a playlist.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SavedPlaylist {
    pub playlist: PlaylistInfo,
    /// Queue entries that are not in the library and were left out.
    pub skipped: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AlbumDetail {
    pub album: AlbumRow,
    pub tracks: Vec<TrackRow>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ArtistRow {
    pub name: String,
    pub track_count: u32,
    pub album_count: u32,
    pub cover: Option<String>,
    pub play_count: u64,
    pub listened_ms: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ArtistMeta {
    pub name: String,
    pub image: Option<String>,
    pub bio: Option<String>,
    pub fetched_at: i64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ArtistTopTrack {
    pub track: TrackRow,
    pub play_count: u64,
    pub listened_ms: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ArtistProfile {
    pub name: String,
    pub track_count: u32,
    pub album_count: u32,
    pub total_duration_ms: u64,
    pub genres: Vec<String>,
    pub play_count: u64,
    pub listened_ms: u64,
    pub image: Option<String>,
    pub bio: Option<String>,
    pub fetched_at: Option<i64>,
    pub fallback_cover: Option<String>,
    pub popular_tracks: Vec<ArtistTopTrack>,
    pub albums: Vec<AlbumRow>,
    pub tracks: Vec<TrackRow>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct GenreRow {
    pub name: String,
    pub track_count: u32,
    pub cover: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct GenreDetail {
    pub name: String,
    pub albums: Vec<AlbumRow>,
    /// Tracks are fetched in pages with `genre_tracks_page`.
    pub track_count: u32,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Page<T> {
    pub total: u64,
    pub items: Vec<T>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanProgress {
    pub folder: String,
    pub scanned: u64,
    pub done: bool,
}

/// Callbacks into the host application (Tauri events in the app, no-ops in
/// tests).
pub struct Hooks {
    pub on_progress: Box<dyn Fn(ScanProgress) + Send + Sync>,
    /// Called with the new version after every change.
    pub on_changed: Box<dyn Fn(u64) + Send + Sync>,
}

impl Hooks {
    pub fn none() -> Self {
        Self {
            on_progress: Box::new(|_| {}),
            on_changed: Box::new(|_| {}),
        }
    }
}

pub struct Library {
    conn: Mutex<Connection>,
    /// Cache: album covers and other files that can be made again.
    covers_dir: PathBuf,
    /// User data: images the user chose (playlist covers). Never in the
    /// cache, so clearing the cache does not lose them.
    user_images_dir: PathBuf,
    version: AtomicU64,
    scanning: AtomicBool,
    queue: Mutex<VecDeque<(i64, PathBuf)>>,
    cover_colors: Mutex<HashMap<String, Option<[u8; 3]>>>,
    hooks: Hooks,
    /// The profile whose data the profile-less methods use (K24).
    active: AtomicI64,
    /// Wrong PIN guesses per profile: (count, last try) (K25).
    pin_tries: Mutex<HashMap<i64, (u32, std::time::Instant)>>,
}

/// Name of the pre-profiles database copy, next to the database.
pub const BEFORE_PROFILES_BACKUP: &str = "library-before-profiles.sqlite3";

impl Library {
    /// Opens the library; a database without profiles gets one named after
    /// the OS user (see [`Library::open_with_first_profile_name`]).
    pub fn open(db_path: &Path, covers_dir: &Path, hooks: Hooks) -> Result<Self> {
        Self::open_with_first_profile_name(
            db_path,
            covers_dir,
            hooks,
            &profiles::default_first_profile_name(),
        )
    }

    /// Like [`Library::open`]; `first_profile_name` names profile 1 when the
    /// schema v14 migration creates it. Before that migration rewrites
    /// tables, the database is copied to `library-before-profiles.sqlite3`
    /// next to it (kept if it already exists).
    pub fn open_with_first_profile_name(
        db_path: &Path,
        covers_dir: &Path,
        hooks: Hooks,
        first_profile_name: &str,
    ) -> Result<Self> {
        if let Some(dir) = db_path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        std::fs::create_dir_all(covers_dir)?;
        let conn = Connection::open(db_path)?;
        backup_before_profiles(&conn, db_path)?;
        db::init_with_first_profile(&conn, first_profile_name)?;
        Ok(Self::with_connection(conn, covers_dir, hooks))
    }

    fn with_connection(conn: Connection, covers_dir: &Path, hooks: Hooks) -> Self {
        Self {
            conn: Mutex::new(conn),
            covers_dir: covers_dir.to_path_buf(),
            user_images_dir: covers_dir.to_path_buf(),
            version: AtomicU64::new(1),
            scanning: AtomicBool::new(false),
            queue: Mutex::new(VecDeque::new()),
            cover_colors: Mutex::new(HashMap::new()),
            hooks,
            active: AtomicI64::new(ProfileId::FIRST.0),
            pin_tries: Mutex::new(HashMap::new()),
        }
    }

    pub(crate) fn conn(&self) -> MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|p| p.into_inner())
    }

    pub fn covers_dir(&self) -> &Path {
        &self.covers_dir
    }

    /// Keeps user-chosen images (playlist covers) in `dir`, a data folder,
    /// and moves the ones an older version saved in the cache folder.
    pub fn with_user_images_dir(mut self, dir: PathBuf) -> Self {
        self.user_images_dir = dir;
        if let Err(e) = self.move_playlist_covers_out_of_cache() {
            log::warn!("could not move playlist covers out of the cache: {e}");
        }
        if let Err(e) = self.move_downloaded_images_out_of_cache() {
            log::warn!("could not move downloaded covers out of the cache: {e}");
        }
        self
    }

    /// Album covers downloaded with "Find info". User data, not cache: they
    /// were fetched once on purpose and cannot be made again from the files.
    pub fn downloaded_album_covers_dir(&self) -> PathBuf {
        self.user_images_dir.join("albums")
    }

    /// Artist pictures from the artist profiles; kept so they are not
    /// downloaded again after a cache clean-up.
    pub fn artist_images_dir(&self) -> PathBuf {
        self.user_images_dir.join("artists")
    }

    /// Moves downloaded album covers (known from their undo record) and
    /// artist pictures that an older version kept in the cache folder.
    fn move_downloaded_images_out_of_cache(&self) -> Result<()> {
        if self.user_images_dir == self.covers_dir {
            return Ok(());
        }
        let conn = self.conn();
        let added: Vec<(i64, String)> = {
            let mut st = conn.prepare(
                "SELECT id, path FROM tag_history WHERE track_id IS NULL AND old_json = ?1",
            )?;
            st.query_map([ADDED_COVER_MARK], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<std::result::Result<_, _>>()?
        };
        let albums_dir = self.downloaded_album_covers_dir();
        for (row_id, old) in added {
            if let Some(new) = move_into(&self.covers_dir, &albums_dir, &old)? {
                conn.execute(
                    "UPDATE albums SET cover = ?1 WHERE cover = ?2",
                    [&new, &old],
                )?;
                conn.execute(
                    "UPDATE tag_history SET path = ?1 WHERE id = ?2",
                    rusqlite::params![new, row_id],
                )?;
            }
        }
        let artists: Vec<(String, String)> = {
            let mut st =
                conn.prepare("SELECT name_key, image FROM artists_meta WHERE image IS NOT NULL")?;
            st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<std::result::Result<_, _>>()?
        };
        let artists_dir = self.artist_images_dir();
        for (key, old) in artists {
            if let Some(new) = move_into(&self.covers_dir, &artists_dir, &old)? {
                conn.execute(
                    "UPDATE artists_meta SET image = ?1 WHERE name_key = ?2",
                    [&new, &key],
                )?;
            }
        }
        Ok(())
    }

    /// Root of the images the user keeps (playlist covers, downloaded album
    /// covers, artist pictures).
    pub fn user_images_dir(&self) -> &Path {
        &self.user_images_dir
    }

    fn playlist_covers_dir(&self) -> PathBuf {
        self.user_images_dir.join("playlists")
    }

    fn legacy_playlist_covers_dir(&self) -> PathBuf {
        self.covers_dir.join("playlists")
    }

    fn move_playlist_covers_out_of_cache(&self) -> Result<()> {
        let legacy = self.legacy_playlist_covers_dir();
        let target = self.playlist_covers_dir();
        if legacy == target {
            return Ok(());
        }
        let covers = db::playlist_cover_paths(&self.conn())?;
        for (profile, id, cover) in covers {
            let old = PathBuf::from(&cover);
            if !old.starts_with(&legacy) {
                continue;
            }
            let new_path = match old.file_name() {
                Some(name) if old.is_file() => {
                    std::fs::create_dir_all(&target)?;
                    let new_path = target.join(name);
                    if std::fs::rename(&old, &new_path).is_err() {
                        std::fs::copy(&old, &new_path)?;
                        let _ = std::fs::remove_file(&old);
                    }
                    Some(scan::display_path(&new_path))
                }
                // The cache was already cleared: fall back to the collage.
                _ => None,
            };
            db::set_playlist_cover(&self.conn(), profile, id, new_path.as_deref())?;
        }
        Ok(())
    }

    /// Albums whose cover file is gone (cache cleared, data folder moved to
    /// another computer): their cover is cleared and their tracks are marked
    /// changed, so the next scan writes the cover again. Returns the folders
    /// to scan.
    pub fn repair_missing_covers(&self) -> Result<Vec<FolderInfo>> {
        let conn = self.conn();
        let missing: Vec<i64> = {
            let mut st = conn.prepare("SELECT id, cover FROM albums WHERE cover IS NOT NULL")?;
            st.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?
                .filter_map(std::result::Result::ok)
                .filter(|(_, cover)| !Path::new(cover).is_file())
                .map(|(id, _)| id)
                .collect()
        };
        if missing.is_empty() {
            return Ok(Vec::new());
        }
        let mut folder_ids = std::collections::BTreeSet::new();
        {
            let tx = conn.unchecked_transaction()?;
            for id in &missing {
                tx.execute("UPDATE albums SET cover = NULL WHERE id = ?1", [id])?;
                // mtime -1 never matches a file, so the scan parses these again.
                tx.execute("UPDATE tracks SET mtime = -1 WHERE album_id = ?1", [id])?;
                let mut st =
                    tx.prepare("SELECT DISTINCT folder_id FROM tracks WHERE album_id = ?1")?;
                for f in st.query_map([id], |r| r.get::<_, i64>(0))? {
                    folder_ids.insert(f?);
                }
            }
            tx.commit()?;
        }
        log::info!(
            "{} album covers are missing; rescanning to restore them",
            missing.len()
        );
        drop(conn);
        Ok(self
            .folders()?
            .into_iter()
            .filter(|f| folder_ids.contains(&f.id))
            .collect())
    }

    pub fn version(&self) -> u64 {
        self.version.load(Ordering::SeqCst)
    }

    pub fn is_scanning(&self) -> bool {
        self.scanning.load(Ordering::SeqCst)
    }

    /// Bumps the version and notifies the host.
    pub(crate) fn bump(&self) -> u64 {
        let v = self.version.fetch_add(1, Ordering::SeqCst) + 1;
        (self.hooks.on_changed)(v);
        v
    }

    pub(crate) fn progress(&self, p: ScanProgress) {
        (self.hooks.on_progress)(p);
    }

    pub fn folders(&self) -> Result<Vec<FolderInfo>> {
        db::folders(&self.conn())
    }

    /// Registers a folder (idempotent) and returns its id. Does not scan.
    pub fn add_folder(&self, path: &str) -> Result<i64> {
        let p = Path::new(path);
        if !p.is_dir() {
            return Err(LibraryError::Other(format!("not a folder: {path}")));
        }
        let canonical = std::fs::canonicalize(p)?;
        let canonical = scan::display_path(&canonical);
        let id = db::add_folder(&self.conn(), &canonical)?;
        self.bump();
        Ok(id)
    }

    pub fn remove_folder(&self, id: i64) -> Result<()> {
        self.queue
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .retain(|(fid, _)| *fid != id);
        let covers = {
            let mut conn = self.conn();
            db::remove_folder(&mut conn, id)?
        };
        scan::remove_cover_files(&covers);
        self.bump();
        Ok(())
    }

    pub fn stats(&self) -> Result<LibraryStats> {
        let (tracks, albums) = db::counts(&self.conn())?;
        Ok(LibraryStats {
            tracks,
            albums,
            version: self.version(),
            scanning: self.is_scanning(),
        })
    }

    pub fn tracks_page(
        &self,
        offset: u64,
        limit: u64,
        sort: impl Into<SortSpec>,
    ) -> Result<Vec<TrackRow>> {
        db::tracks_page(
            &self.conn(),
            self.active_profile(),
            offset,
            limit.min(1000),
            sort,
        )
    }

    pub fn search_tracks_page(
        &self,
        offset: u64,
        limit: u64,
        sort: impl Into<SortSpec>,
        query: &str,
    ) -> Result<Page<TrackRow>> {
        db::search_tracks_page(
            &self.conn(),
            self.active_profile(),
            offset,
            limit.min(1000),
            sort,
            query,
        )
    }

    pub fn track_meta(&self, path: &str) -> Result<Option<TrackMeta>> {
        let key = scan::display_path(Path::new(path));
        db::track_meta_by_path(&self.conn(), &key)
    }

    /// Absolute cover path of the album containing the track at `path`.
    pub fn track_cover(&self, path: &str) -> Result<Option<String>> {
        let key = scan::display_path(Path::new(path));
        db::track_cover_by_path(&self.conn(), &key)
    }

    pub fn albums_page(&self, offset: u64, limit: u64) -> Result<Vec<AlbumRow>> {
        db::albums_page(&self.conn(), offset, limit.min(1000))
    }

    pub fn search_albums_page(
        &self,
        offset: u64,
        limit: u64,
        query: &str,
    ) -> Result<Page<AlbumRow>> {
        db::search_albums_page(&self.conn(), offset, limit.min(1000), query)
    }

    pub fn album_info(&self, album_id: i64) -> Result<Option<AlbumRow>> {
        db::album_info(&self.conn(), album_id)
    }

    pub fn cached_cover_color(&self, cover: &str) -> Result<Option<[u8; 3]>> {
        {
            let cache = self.cover_colors.lock().unwrap_or_else(|p| p.into_inner());
            if let Some(&color) = cache.get(cover) {
                return Ok(color);
            }
        }
        let path = Path::new(cover);
        let inside = std::fs::canonicalize(path).is_ok_and(|p| {
            [
                self.covers_dir(),
                self.user_images_dir(),
                &self.playlist_covers_dir(),
            ]
            .iter()
            .any(|dir| std::fs::canonicalize(dir).is_ok_and(|d| p.starts_with(d)))
        });
        if !inside {
            return Ok(None);
        }
        let color = cover_color::cover_color(path).ok();
        let mut cache = self.cover_colors.lock().unwrap_or_else(|p| p.into_inner());
        if cache.len() >= 512 {
            cache.clear();
        }
        cache.insert(cover.to_string(), color);
        Ok(color)
    }

    pub fn album(&self, album_id: i64) -> Result<AlbumDetail> {
        db::album_detail(&self.conn(), self.active_profile(), album_id)
    }

    /// Tracks of an album in play order, ready for the queue.
    pub fn album_tracks(&self, album_id: i64) -> Result<Vec<Track>> {
        db::album_tracks(&self.conn(), album_id)
    }

    /// The whole library in `sort` order, ready for the queue.
    pub fn all_tracks(&self, sort: impl Into<SortSpec>) -> Result<Vec<Track>> {
        db::all_tracks(&self.conn(), sort)
    }

    pub fn all_tracks_lyrics_meta(&self) -> Result<Vec<db::TrackLyricsMeta>> {
        db::all_tracks_lyrics_meta(&self.conn())
    }

    /// Tracks matching `query` in `sort` order, ready for the queue.
    pub fn matching_tracks(&self, sort: impl Into<SortSpec>, query: &str) -> Result<Vec<Track>> {
        db::matching_tracks(&self.conn(), sort, query)
    }

    pub fn playlists(&self) -> Result<Vec<PlaylistInfo>> {
        db::playlists(&self.conn(), self.active_profile())
    }

    pub fn create_playlist(&self, name: &str, track_ids: &[i64]) -> Result<PlaylistInfo> {
        db::create_playlist(
            &mut self.conn(),
            self.active_profile(),
            name,
            track_ids,
            unix_now(),
        )
    }

    pub fn rename_playlist(&self, id: i64, name: &str) -> Result<()> {
        db::rename_playlist(&self.conn(), self.active_profile(), id, name)
    }

    pub fn delete_playlist(&self, id: i64) -> Result<()> {
        let old = db::delete_playlist(&self.conn(), self.active_profile(), id)?;
        self.remove_playlist_cover_if_cached(old);
        Ok(())
    }

    pub fn set_playlist_cover_file(&self, id: i64, image_path: &Path) -> Result<()> {
        let buf = encode_cover_jpeg(image_path)?;

        let dir = self.playlist_covers_dir();
        std::fs::create_dir_all(&dir)?;
        let hash = scan::fnv1a(&buf);
        let dest = dir.join(format!("{id}_{hash:016x}.jpg"));
        scan::write_atomic(&dest, &buf)?;
        let dest_str = scan::display_path(&dest);

        match db::set_playlist_cover(&self.conn(), self.active_profile(), id, Some(&dest_str)) {
            Ok(old) => {
                if old.as_deref() != Some(dest_str.as_str()) {
                    self.remove_playlist_cover_if_cached(old);
                }
                Ok(())
            }
            Err(e) => {
                let _ = std::fs::remove_file(&dest);
                Err(e)
            }
        }
    }

    pub fn set_playlist_cover_preset(&self, id: i64, preset: &str) -> Result<()> {
        if !preset.starts_with("preset:") || preset.len() > 64 {
            return Err(LibraryError::Other("invalid cover preset".into()));
        }
        let old = db::set_playlist_cover(&self.conn(), self.active_profile(), id, Some(preset))?;
        self.remove_playlist_cover_if_cached(old);
        Ok(())
    }

    pub fn clear_playlist_cover(&self, id: i64) -> Result<()> {
        let old = db::set_playlist_cover(&self.conn(), self.active_profile(), id, None)?;
        self.remove_playlist_cover_if_cached(old);
        Ok(())
    }

    pub(crate) fn remove_playlist_cover_if_cached(&self, old: Option<String>) {
        let Some(old) = old else { return };
        if old.starts_with("preset:") {
            return;
        }
        let path = Path::new(&old);
        if path.starts_with(self.playlist_covers_dir())
            || path.starts_with(self.legacy_playlist_covers_dir())
        {
            let _ = std::fs::remove_file(path);
        }
    }

    pub fn playlist_tracks(&self, id: i64, offset: u64, limit: u64) -> Result<Vec<TrackRow>> {
        db::playlist_tracks(
            &self.conn(),
            self.active_profile(),
            id,
            offset,
            limit.min(1000),
        )
    }

    /// Playlist contents in order, ready for the queue.
    pub fn playlist_queue_tracks(&self, id: i64) -> Result<Vec<Track>> {
        db::playlist_queue_tracks(&self.conn(), self.active_profile(), id)
    }

    /// Appends tracks; ids that are not in the library are skipped.
    /// Returns the number of entries added.
    pub fn playlist_add_tracks(&self, id: i64, track_ids: &[i64]) -> Result<usize> {
        db::playlist_add_tracks(&mut self.conn(), self.active_profile(), id, track_ids)
    }

    pub fn playlist_add_album(&self, id: i64, album_id: i64) -> Result<usize> {
        db::playlist_add_album(&mut self.conn(), self.active_profile(), id, album_id)
    }

    /// Removes the entries at the given indexes.
    pub fn playlist_remove(&self, id: i64, indexes: &[usize]) -> Result<()> {
        db::playlist_remove(&mut self.conn(), self.active_profile(), id, indexes)
    }

    pub fn playlists_with_track(&self, track_id: i64) -> Result<Vec<i64>> {
        db::playlists_with_track(&self.conn(), self.active_profile(), track_id)
    }

    pub fn playlist_remove_track(&self, id: i64, track_id: i64) -> Result<()> {
        db::playlist_remove_track(&mut self.conn(), self.active_profile(), id, track_id)
    }

    pub fn playlist_move(&self, id: i64, from: usize, to: usize) -> Result<()> {
        db::playlist_move(&mut self.conn(), self.active_profile(), id, from, to)
    }

    pub fn favorites(&self) -> Result<Vec<FavoriteRef>> {
        db::favorites(&self.conn(), self.active_profile())
    }

    pub fn set_favorites(&self, track_ids: &[i64], on: bool) -> Result<usize> {
        db::set_favorites(
            &mut self.conn(),
            self.active_profile(),
            track_ids,
            on,
            unix_now(),
        )
    }

    pub fn toggle_favorite(&self, track_id: i64) -> Result<bool> {
        db::toggle_favorite(&self.conn(), self.active_profile(), track_id, unix_now())
    }

    pub fn toggle_favorite_by_path(&self, path: &str) -> Result<bool> {
        let p = Path::new(path);
        let canonical = std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf());
        let key = scan::display_path(&canonical);
        let conn = self.conn();
        let keys = if key == path {
            vec![key]
        } else {
            vec![key, path.to_owned()]
        };
        let found = db::track_ids_by_paths(&conn, &keys)?;
        let Some(track_id) = found.into_iter().flatten().next() else {
            return Err(LibraryError::Other("track is not in the library".into()));
        };
        db::toggle_favorite(&conn, self.active_profile(), track_id, unix_now())
    }

    pub fn favorites_page(&self, offset: u64, limit: u64) -> Result<Page<TrackRow>> {
        db::favorites_page(&self.conn(), self.active_profile(), offset, limit.min(500))
    }

    pub fn favorites_queue_tracks(&self) -> Result<Vec<Track>> {
        db::favorites_queue_tracks(&self.conn(), self.active_profile())
    }

    /// Creates a playlist from file paths (e.g. the queue). Files that are
    /// not in the library are skipped and counted.
    pub fn playlist_from_paths(&self, name: &str, paths: &[String]) -> Result<SavedPlaylist> {
        // Library paths are canonical (folders are canonicalized when added),
        // so canonicalize here too: on Windows a path can differ only by
        // 8.3 short names (e.g. `RUNNER~1`) or case and would not match.
        let keys: Vec<String> = paths
            .iter()
            .map(|p| {
                let p = Path::new(p);
                let canonical = std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf());
                scan::display_path(&canonical)
            })
            .collect();
        let mut conn = self.conn();
        let found = db::track_ids_by_paths(&conn, &keys)?;
        let ids: Vec<i64> = found.iter().flatten().copied().collect();
        let playlist =
            db::create_playlist(&mut conn, self.active_profile(), name, &ids, unix_now())?;
        Ok(SavedPlaylist {
            playlist,
            skipped: found.len() - ids.len(),
        })
    }

    /// The playlist as extended M3U text.
    pub fn export_m3u(&self, id: i64) -> Result<String> {
        let rows =
            db::playlist_tracks(&self.conn(), self.active_profile(), id, 0, u32::MAX as u64)?;
        Ok(m3u::render(&rows))
    }

    /// Creates a playlist from M3U text, matching entries to this library
    /// (see [`m3u`]). Relative paths are resolved against `base`.
    pub fn import_m3u(
        &self,
        name: &str,
        text: &str,
        base: Option<&Path>,
    ) -> Result<ImportedPlaylist> {
        let mut entries = m3u::parse(text);
        if let Some(base) = base {
            for e in &mut entries {
                let p = Path::new(&e.path);
                if p.is_relative() && !e.path.contains(['\\', ':']) {
                    e.path = scan::display_path(&base.join(p));
                }
            }
        }
        let mut conn = self.conn();
        let library = db::match_candidates(&conn)?;
        let found = m3u::resolve(&entries, &library);
        let ids: Vec<i64> = found.iter().flatten().copied().collect();
        let playlist =
            db::create_playlist(&mut conn, self.active_profile(), name, &ids, unix_now())?;
        Ok(ImportedPlaylist {
            playlist,
            matched: ids.len(),
            missing: found.len() - ids.len(),
        })
    }

    /// Records one completed or interrupted playback session.
    pub fn record_listen_event(&self, event: NewListenEvent) -> Result<()> {
        db::record_listen_event(&self.conn(), self.active_profile(), &event)
    }

    /// Aggregated listening statistics for the `[from, to)` Unix-second range.
    pub fn listening_stats(&self, from: Option<i64>, to: Option<i64>) -> Result<ListeningStats> {
        db::listening_stats(&self.conn(), self.active_profile(), from, to, 15)
    }

    /// Removes all recorded listening history entries and returns rows deleted.
    pub fn clear_listen_history(&self) -> Result<u64> {
        db::clear_listen_history(&self.conn(), self.active_profile())
    }

    pub fn search_artists_page(
        &self,
        offset: u64,
        limit: u64,
        query: &str,
    ) -> Result<Page<ArtistRow>> {
        db::search_artists_page(&self.conn(), self.active_profile(), offset, limit, query)
    }

    pub fn artist_profile(&self, name: &str) -> Result<ArtistProfile> {
        db::artist_profile(&self.conn(), self.active_profile(), name)
    }

    pub fn artist_tracks(&self, name: &str) -> Result<Vec<Track>> {
        db::artist_queue_tracks(&self.conn(), name)
    }

    pub fn genres(&self) -> Result<Vec<GenreRow>> {
        db::genres(&self.conn())
    }

    pub fn genre_detail(&self, name: &str) -> Result<GenreDetail> {
        db::genre_detail(&self.conn(), name)
    }

    pub fn genre_tracks_page(&self, name: &str, offset: u64, limit: u64) -> Result<Page<TrackRow>> {
        db::genre_tracks_page(&self.conn(), self.active_profile(), name, offset, limit)
    }

    pub fn genre_tracks(&self, name: &str) -> Result<Vec<Track>> {
        db::genre_queue_tracks(&self.conn(), name)
    }

    pub fn artist_meta(&self, name: &str) -> Result<Option<ArtistMeta>> {
        db::artist_meta(&self.conn(), name)
    }

    pub fn all_artist_names(&self) -> Result<Vec<String>> {
        db::all_artist_names(&self.conn())
    }

    /// Autoplay: up to `n` library songs that fit `seeds` (paths, most
    /// recent last), none of `exclude`.
    pub fn autoplay_picks(
        &self,
        seeds: &[String],
        exclude: &std::collections::HashSet<String>,
        n: usize,
    ) -> Result<Vec<autoplay::AutoTrack>> {
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(1, |d| d.as_nanos() as u64);
        autoplay::pick(
            &self.conn(),
            self.active_profile(),
            seeds,
            exclude,
            n,
            unix_now(),
            seed,
        )
    }

    pub fn save_artist_meta(
        &self,
        name: &str,
        image: Option<&str>,
        bio: Option<&str>,
    ) -> Result<ArtistMeta> {
        db::save_artist_meta(&self.conn(), name, image, bio, unix_now())
    }

    /// Library file paths (and their folder ids) for the given track ids, in
    /// the same order. Unknown ids are skipped.
    pub fn track_files(&self, ids: &[i64]) -> Result<Vec<(i64, String, i64)>> {
        db::track_files_by_ids(&self.conn(), ids)
    }

    /// Re-reads the tags of the given files into the database (after a tag
    /// edit) and notifies the host. `files` are `(path, folder id)` pairs.
    pub fn rescan_files(&self, files: &[(String, i64)]) -> Result<usize> {
        scan::rescan_files(self, files)
    }

    pub fn track_by_id(&self, track_id: i64) -> Result<Option<TrackRow>> {
        db::track_by_id(&self.conn(), self.active_profile(), track_id)
    }

    pub fn track_row_by_path(&self, path: &str) -> Result<Option<TrackRow>> {
        let key = scan::display_path(Path::new(path));
        db::track_row_by_path(&self.conn(), self.active_profile(), &key)
    }

    pub fn track_id_by_path(&self, path: &str) -> Result<Option<i64>> {
        db::track_id_by_path(&self.conn(), path)
    }

    /// The album a track currently belongs to.
    pub fn track_album(&self, track_id: i64) -> Result<Option<AlbumRow>> {
        db::track_album(&self.conn(), track_id)
    }

    /// Sets an album's cover file (path inside the covers cache) and
    /// notifies the host.
    pub fn set_album_cover(&self, album_id: i64, cover: &str) -> Result<()> {
        db::set_album_cover(&self.conn(), album_id, cover)?;
        self.bump();
        Ok(())
    }

    /// Encodes a user-chosen image as a 600x600 JPEG in `downloaded_album_covers_dir`
    /// with a `custom_` prefix so scans never overwrite it.
    pub fn set_album_cover_file(&self, album_id: i64, image_path: &Path) -> Result<AlbumRow> {
        self.album_info(album_id)?
            .ok_or_else(|| LibraryError::NotFound(format!("album {album_id}")))?;
        let bytes = encode_cover_jpeg(image_path)?;
        let dir = self.downloaded_album_covers_dir();
        std::fs::create_dir_all(&dir)?;
        let hash = scan::fnv1a(&bytes);
        let dest = dir.join(format!("custom_{album_id}_{hash:016x}.jpg"));
        scan::write_atomic(&dest, &bytes)?;
        let dest_str = scan::display_path(&dest);
        let prev = match db::set_album_cover(&self.conn(), album_id, &dest_str) {
            Ok(p) => p,
            Err(e) => {
                let _ = std::fs::remove_file(&dest);
                return Err(e);
            }
        };
        if let Some(old) = prev
            && old != dest_str
            && db::is_custom_album_cover_path(&old)
            && Path::new(&old).starts_with(&dir)
        {
            let _ = std::fs::remove_file(&old);
        }
        self.bump();
        self.album_info(album_id)?
            .ok_or_else(|| LibraryError::NotFound(format!("album {album_id}")))
    }

    /// Clears an album's cover, deletes any custom or cached cover file, and
    /// immediately re-extracts embedded or folder art from the album's tracks.
    pub fn clear_album_cover(&self, album_id: i64) -> Result<AlbumRow> {
        let album = self
            .album_info(album_id)?
            .ok_or_else(|| LibraryError::NotFound(format!("album {album_id}")))?;
        let prev = db::clear_album_cover(&self.conn(), album_id)?;
        if let Some(old) = prev {
            let old_path = Path::new(&old);
            if old_path.starts_with(self.downloaded_album_covers_dir())
                || old_path.starts_with(self.covers_dir())
            {
                let _ = std::fs::remove_file(old_path);
            }
        }
        for ext in ["jpg", "png", "gif", "bmp", "webp"] {
            let name = scan::cover_file_name(
                &album.album_artist,
                &album.title,
                album.year.map(i64::from),
                ext,
            );
            let _ = std::fs::remove_file(self.covers_dir().join(name));
        }
        let files: Vec<(String, i64)> = {
            let conn = self.conn();
            let mut st = conn.prepare(
                "SELECT path, folder_id FROM tracks WHERE album_id = ?1 ORDER BY disc_no, track_no, id",
            )?;
            let rows = st.query_map([album_id], |r| Ok((r.get(0)?, r.get(1)?)))?;
            rows.collect::<std::result::Result<Vec<_>, _>>()?
        };
        if !files.is_empty() {
            let _ = scan::rescan_files(self, &files);
        }
        self.bump();
        self.album_info(album_id)?
            .ok_or_else(|| LibraryError::NotFound(format!("album {album_id}")))
    }

    /// Removes `cover` from every album that uses it (undo of an added cover).
    pub fn clear_album_cover_path(&self, cover: &str) -> Result<()> {
        let n = self
            .conn()
            .execute("UPDATE albums SET cover = NULL WHERE cover = ?1", [cover])?;
        if n > 0 {
            self.bump();
        }
        Ok(())
    }

    /// Next id for a group of tag changes that can be undone together.
    pub fn next_tag_batch_id(&self) -> Result<i64> {
        db::next_tag_batch_id(&self.conn())
    }

    /// Stores the tags a track had before a metadata write (JSON).
    pub fn save_tag_history(
        &self,
        batch_id: i64,
        track_id: Option<i64>,
        path: &str,
        old_json: &str,
    ) -> Result<i64> {
        db::insert_tag_history(&self.conn(), batch_id, track_id, path, unix_now(), old_json)
    }

    pub fn delete_tag_history_row(&self, id: i64) -> Result<()> {
        db::delete_tag_history_row(&self.conn(), id)
    }

    /// Home overview feed: recent albums & tracks, favorites, recently added,
    /// and local rule-based dynamic mixes.
    pub fn home_feed(&self) -> Result<HomeFeed> {
        db::home_feed(&self.conn(), self.active_profile(), unix_now())
    }

    pub fn home_mix_detail(&self, mix_id: &str) -> Result<Option<HomeMixDetail>> {
        db::home_mix_detail(&self.conn(), self.active_profile(), mix_id, unix_now())
    }

    pub fn home_mix_queue_tracks(&self, mix_id: &str) -> Result<Vec<Track>> {
        db::home_mix_queue_tracks(&self.conn(), self.active_profile(), mix_id, unix_now())
    }

    pub fn save_mix_as_playlist(&self, mix_id: &str, name: &str) -> Result<PlaylistInfo> {
        db::save_mix_as_playlist(
            &mut self.conn(),
            self.active_profile(),
            mix_id,
            name,
            unix_now(),
        )
    }

    pub fn tag_history_batch(&self, batch_id: i64) -> Result<Vec<db::TagHistoryRow>> {
        db::tag_history_batch(&self.conn(), batch_id)
    }

    /// Queues the given folders for scanning and starts the worker thread if
    /// none is running. Folders already queued are not queued twice.
    pub fn start_scan(self: &Arc<Self>, folders: Vec<FolderInfo>) {
        {
            let mut q = self.queue.lock().unwrap_or_else(|p| p.into_inner());
            for f in folders {
                if !q.iter().any(|(id, _)| *id == f.id) {
                    q.push_back((f.id, PathBuf::from(f.path)));
                }
            }
        }
        if self
            .scanning
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return; // the running worker will pick the queued folders up
        }
        let lib = Arc::clone(self);
        let spawned = std::thread::Builder::new()
            .name("library-scan".into())
            .spawn(move || lib.scan_worker());
        if let Err(e) = spawned {
            log::error!("failed to start scan thread: {e}");
            self.scanning.store(false, Ordering::SeqCst);
        }
    }

    fn scan_worker(self: Arc<Self>) {
        loop {
            let next = {
                let mut q = self.queue.lock().unwrap_or_else(|p| p.into_inner());
                let next = q.pop_front();
                if next.is_none() {
                    // Clear the flag while holding the queue lock so that a
                    // concurrent start_scan cannot be lost.
                    self.scanning.store(false, Ordering::SeqCst);
                }
                next
            };
            let Some((id, path)) = next else { break };
            match scan::scan_folder(&self, id, &path) {
                Ok(stats) => log::info!("scanned {}: {stats:?}", path.display()),
                Err(e) => {
                    log::warn!("scan of {} failed: {e}", path.display());
                    self.progress(ScanProgress {
                        folder: path.to_string_lossy().into_owned(),
                        scanned: 0,
                        done: true,
                    });
                }
            }
        }
        self.bump();
    }
}

/// Writes `library-before-profiles.sqlite3` next to the database when it is
/// about to be migrated to schema v14 (the migration rebuilds tables).
fn backup_before_profiles(conn: &Connection, db_path: &Path) -> Result<()> {
    let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    let has_tables: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table')",
        [],
        |r| r.get(0),
    )?;
    if version >= 14 || !has_tables {
        return Ok(());
    }
    let backup = db_path.with_file_name(BEFORE_PROFILES_BACKUP);
    if backup.exists() {
        return Ok(());
    }
    // VACUUM INTO writes a consistent copy (WAL included) and refuses to
    // overwrite; build it under a temporary name so a crash never leaves a
    // half-written file that would pass the exists() check.
    let tmp = backup.with_extension("tmp");
    let _ = std::fs::remove_file(&tmp);
    conn.execute("VACUUM INTO ?1", [tmp.to_string_lossy().as_ref()])?;
    std::fs::rename(&tmp, &backup)?;
    Ok(())
}

fn encode_cover_jpeg(image_path: &Path) -> Result<Vec<u8>> {
    const MAX_COVER_FILE_BYTES: u64 = 15 * 1024 * 1024;
    if std::fs::metadata(image_path)?.len() > MAX_COVER_FILE_BYTES {
        return Err(LibraryError::Other(
            "cover image exceeds the 15 MB size limit".into(),
        ));
    }
    let img = image::ImageReader::open(image_path)?
        .with_guessed_format()?
        .decode()
        .map_err(|e| LibraryError::Other(format!("invalid image: {e}")))?;
    let rgb = img
        .resize_to_fill(600, 600, image::imageops::FilterType::Triangle)
        .into_rgb8();
    let mut buf = Vec::new();
    rgb.write_to(
        &mut std::io::Cursor::new(&mut buf),
        image::ImageFormat::Jpeg,
    )
    .map_err(|e| LibraryError::Other(format!("failed to encode cover: {e}")))?;
    Ok(buf)
}

fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

#[cfg(test)]
mod large_library;

#[cfg(test)]
mod profile_tests;

#[cfg(test)]
mod tests;

/// Marks a tag-history row that records a cover "Find info" added (its undo
/// removes the file).
pub const ADDED_COVER_MARK: &str = r#"{"addedCover":true}"#;

/// Moves `old` into `to` when it is a file inside the cache folder `cache`.
/// Returns the new path, or `None` when there was nothing to move (already
/// moved, elsewhere, or the cache was cleared).
fn move_into(cache: &Path, to: &Path, old: &str) -> Result<Option<String>> {
    let old_path = Path::new(old);
    if !old_path.starts_with(cache) || old_path.starts_with(to) || !old_path.is_file() {
        return Ok(None);
    }
    let Some(name) = old_path.file_name() else {
        return Ok(None);
    };
    std::fs::create_dir_all(to)?;
    let new_path = to.join(name);
    if std::fs::rename(old_path, &new_path).is_err() {
        std::fs::copy(old_path, &new_path)?;
        let _ = std::fs::remove_file(old_path);
    }
    Ok(Some(scan::display_path(&new_path)))
}

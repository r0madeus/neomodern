//! SQLite schema and queries. All functions take a plain `&Connection` so
//! they can be tested without the [`super::Library`] facade.

use super::profiles::{DEFAULT_FIRST_PROFILE_NAME, PROFILE_COLORS, ProfileId};
use super::{
    AlbumDetail, AlbumRow, ArtistMeta, ArtistProfile, ArtistRow, ArtistTopTrack, BucketStat,
    DynamicMix, FavoriteRef, FolderInfo, GenreDetail, GenreRow, HomeFeed, HomeMixDetail,
    ListeningStats, NewListenEvent, Page, PlaylistInfo, RecentListen, RecentTrack, Result,
    StatsSummary, TopAlbumStat, TopArtistStat, TopGenreStat, TopTrackStat, TrackMeta, TrackRow,
};
use crate::queue::Track;
use rusqlite::types::Value;
use rusqlite::{Connection, OptionalExtension, Row, params_from_iter};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

const SCHEMA_VERSION: i64 = 15;

pub(super) const SCHEMA_V1: &str = "
CREATE TABLE folders (
    id   INTEGER PRIMARY KEY,
    path TEXT NOT NULL UNIQUE
);
CREATE TABLE albums (
    id           INTEGER PRIMARY KEY,
    title        TEXT NOT NULL COLLATE NOCASE,
    album_artist TEXT NOT NULL COLLATE NOCASE,
    year         INTEGER,
    cover        TEXT,
    UNIQUE (title, album_artist)
);
CREATE TABLE tracks (
    id          INTEGER PRIMARY KEY,
    folder_id   INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
    path        TEXT NOT NULL UNIQUE,
    mtime       INTEGER NOT NULL,
    size        INTEGER NOT NULL,
    title       TEXT NOT NULL COLLATE NOCASE,
    artist      TEXT NOT NULL COLLATE NOCASE,
    album_id    INTEGER REFERENCES albums(id),
    track_no    INTEGER,
    disc_no     INTEGER,
    year        INTEGER,
    duration_ms INTEGER,
    genre       TEXT,
    added_at    INTEGER NOT NULL
);
CREATE INDEX tracks_folder   ON tracks(folder_id);
CREATE INDEX tracks_album    ON tracks(album_id, disc_no, track_no, title);
CREATE INDEX tracks_artist   ON tracks(artist, title);
CREATE INDEX tracks_title    ON tracks(title);
CREATE INDEX tracks_added    ON tracks(added_at DESC);
";

pub(super) const SCHEMA_V2: &str = "
CREATE TABLE playlists (
    id         INTEGER PRIMARY KEY,
    name       TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE playlist_tracks (
    playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    position    INTEGER NOT NULL,
    track_id    INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    PRIMARY KEY (playlist_id, position)
);
CREATE INDEX playlist_tracks_track ON playlist_tracks(track_id);
";

const SCHEMA_V3: &str = "
CREATE TABLE albums_v3 (
    id           INTEGER PRIMARY KEY,
    title        TEXT NOT NULL COLLATE NOCASE,
    album_artist TEXT NOT NULL COLLATE NOCASE,
    year         INTEGER,
    cover        TEXT
);
INSERT INTO albums_v3(id, title, album_artist, year, cover)
SELECT id, title, album_artist, year, cover FROM albums;
DROP TABLE albums;
ALTER TABLE albums_v3 RENAME TO albums;
CREATE UNIQUE INDEX albums_key ON albums(title, album_artist, COALESCE(year, -1));
INSERT OR IGNORE INTO albums(title, album_artist, year, cover)
SELECT DISTINCT a.title, a.album_artist, t.year, a.cover
FROM tracks t
JOIN albums a ON a.id = t.album_id
WHERE COALESCE(t.year, -1) != COALESCE(a.year, -1);
UPDATE tracks
SET album_id = (
    SELECT target.id
    FROM albums cur
    JOIN albums target
      ON target.title = cur.title
     AND target.album_artist = cur.album_artist
     AND COALESCE(target.year, -1) = COALESCE(tracks.year, -1)
    WHERE cur.id = tracks.album_id
)
WHERE album_id IS NOT NULL
  AND COALESCE(year, -1) != (
      SELECT COALESCE(a.year, -1) FROM albums a WHERE a.id = tracks.album_id
  );
";

const SCHEMA_V4: &str = "
CREATE TABLE favorites (
    track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
    added_at INTEGER NOT NULL
);
CREATE INDEX favorites_added ON favorites(added_at DESC);
";

const SCHEMA_V5: &str = "
ALTER TABLE playlists ADD COLUMN cover TEXT;
";

const SCHEMA_V6: &str = "
CREATE TABLE listen_events (
    id          INTEGER PRIMARY KEY,
    track_id    INTEGER REFERENCES tracks(id) ON DELETE SET NULL,
    path        TEXT NOT NULL,
    title       TEXT NOT NULL COLLATE NOCASE,
    artist      TEXT NOT NULL COLLATE NOCASE,
    album       TEXT NOT NULL COLLATE NOCASE,
    genre       TEXT NOT NULL COLLATE NOCASE,
    duration_ms INTEGER,
    started_at  INTEGER NOT NULL,
    ended_at    INTEGER NOT NULL,
    listened_ms INTEGER NOT NULL,
    completed   INTEGER NOT NULL DEFAULT 0,
    skipped     INTEGER NOT NULL DEFAULT 0,
    source      TEXT NOT NULL DEFAULT 'local'
);
CREATE INDEX listen_events_started ON listen_events(started_at DESC);
CREATE INDEX listen_events_artist ON listen_events(artist, started_at);
CREATE INDEX listen_events_track ON listen_events(track_id);
";

const SCHEMA_V7: &str = "
CREATE TABLE track_artists (
    track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    artist   TEXT NOT NULL COLLATE NOCASE,
    position INTEGER NOT NULL,
    PRIMARY KEY (track_id, artist)
);
CREATE INDEX track_artists_artist ON track_artists(artist, track_id);

CREATE TABLE artists_meta (
    name_key   TEXT PRIMARY KEY COLLATE NOCASE,
    display    TEXT NOT NULL,
    image      TEXT,
    bio        TEXT,
    fetched_at INTEGER NOT NULL
);
";

/// Home-feed queries match listen events to tracks by path when the track
/// id was lost, so `path` needs an index.
const SCHEMA_V10: &str = "
CREATE INDEX IF NOT EXISTS listen_events_path ON listen_events(path);
";

pub(super) const SCHEMA_V9: &str = "
CREATE TABLE IF NOT EXISTS tag_history (
    id       INTEGER PRIMARY KEY,
    batch_id INTEGER NOT NULL,
    track_id INTEGER,
    path     TEXT NOT NULL,
    saved_at INTEGER NOT NULL,
    old_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS tag_history_batch ON tag_history(batch_id);
";

/// PC <-> phone sync (docs/SYNC.md): the replicated record of favourites,
/// playlists and listening history, plus local-only bookkeeping. Sync rows
/// store track *keys*, never `tracks.id`, so they have no foreign keys into
/// the library: a song missing on this device must not cascade them away.
pub(crate) const SCHEMA_V13: &str = "
CREATE TABLE IF NOT EXISTS sync_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sync_favorites (
    key         TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    artist      TEXT NOT NULL,
    album       TEXT NOT NULL,
    duration_ms INTEGER,
    is_on       INTEGER NOT NULL,
    hlc         TEXT NOT NULL,
    seq         INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS sync_favorites_seq ON sync_favorites(seq);
CREATE TABLE IF NOT EXISTS sync_playlists (
    uuid         TEXT PRIMARY KEY,
    name         TEXT NOT NULL,
    name_hlc     TEXT NOT NULL,
    cover_preset TEXT,
    cover_hlc    TEXT NOT NULL,
    deleted      INTEGER NOT NULL,
    deleted_hlc  TEXT NOT NULL,
    created_at   INTEGER NOT NULL,
    reconciled   INTEGER NOT NULL DEFAULT 1,
    seq          INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS sync_playlists_seq ON sync_playlists(seq);
CREATE TABLE IF NOT EXISTS sync_playlist_entries (
    uuid          TEXT PRIMARY KEY,
    playlist_uuid TEXT NOT NULL,
    key           TEXT NOT NULL,
    title         TEXT NOT NULL,
    artist        TEXT NOT NULL,
    album         TEXT NOT NULL,
    duration_ms   INTEGER,
    added_at      INTEGER NOT NULL,
    pos           TEXT NOT NULL,
    pos_hlc       TEXT NOT NULL,
    deleted       INTEGER NOT NULL,
    deleted_hlc   TEXT NOT NULL,
    seq           INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS sync_playlist_entries_list
    ON sync_playlist_entries(playlist_uuid, pos, uuid);
CREATE INDEX IF NOT EXISTS sync_playlist_entries_seq ON sync_playlist_entries(seq);
CREATE TABLE IF NOT EXISTS sync_listens (
    uid         TEXT PRIMARY KEY,
    key         TEXT NOT NULL,
    title       TEXT NOT NULL,
    artist      TEXT NOT NULL,
    album       TEXT NOT NULL,
    genre       TEXT NOT NULL,
    duration_ms INTEGER,
    path        TEXT NOT NULL,
    started_at  INTEGER NOT NULL,
    ended_at    INTEGER NOT NULL,
    listened_ms INTEGER NOT NULL,
    completed   INTEGER NOT NULL,
    skipped     INTEGER NOT NULL,
    seq         INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS sync_listens_seq ON sync_listens(seq);
CREATE TABLE IF NOT EXISTS sync_playlist_map (
    playlist_id INTEGER PRIMARY KEY,
    uuid        TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS sync_peers (
    device_id         TEXT PRIMARY KEY,
    name              TEXT NOT NULL,
    secret            BLOB NOT NULL,
    last_seq_sent     INTEGER NOT NULL DEFAULT 0,
    last_seq_received INTEGER NOT NULL DEFAULT 0,
    last_sync_at      INTEGER
);
CREATE TABLE IF NOT EXISTS sync_present (
    track_id INTEGER PRIMARY KEY,
    key      TEXT NOT NULL
);
";

/// Profiles (K24): the `profiles` table and the `profile_id` columns. Runs
/// with `foreign_keys = OFF` (a column with a REFERENCES clause and a
/// non-NULL default cannot be added otherwise, and `favorites` is rebuilt).
/// The `DEFAULT 1` only lets ALTER TABLE work and keeps old sync SQL on
/// profile 1; every library INSERT sets `profile_id` explicitly.
const SCHEMA_V14: &str = "
CREATE TABLE IF NOT EXISTS profiles (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT NOT NULL,
    color      TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
";

const SCHEMA_V14_FAVORITES: &str = "
CREATE TABLE favorites_v14 (
    profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    track_id   INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    added_at   INTEGER NOT NULL,
    PRIMARY KEY (profile_id, track_id)
);
INSERT INTO favorites_v14(profile_id, track_id, added_at)
SELECT 1, track_id, added_at FROM favorites;
DROP TABLE favorites;
ALTER TABLE favorites_v14 RENAME TO favorites;
";

/// The listening indexes the profile-scoped ones replace.
const SCHEMA_V14_DROP_INDEXES: &str = "
DROP INDEX IF EXISTS listen_events_started;
DROP INDEX IF EXISTS listen_events_artist;
DROP INDEX IF EXISTS listen_events_track;
DROP INDEX IF EXISTS listen_events_path;
DROP INDEX IF EXISTS idx_listen_events_artist_nocase;
DROP INDEX IF EXISTS idx_listen_events_track_play;
DROP INDEX IF EXISTS idx_listen_events_unlinked_path_play;
DROP INDEX IF EXISTS idx_listen_events_started_at;
";

fn has_column(conn: &Connection, table: &str, column: &str) -> Result<bool> {
    Ok(conn.query_row(
        "SELECT COUNT(*) > 0 FROM pragma_table_info(?1) WHERE name = ?2",
        [table, column],
        |r| r.get(0),
    )?)
}

/// Schema v14, written so a repeated run is harmless (like v13).
fn migrate_v14(conn: &Connection, first_profile_name: &str) -> Result<()> {
    let tx = conn.unchecked_transaction()?;
    tx.execute_batch(SCHEMA_V14)?;
    tx.execute(
        "INSERT OR IGNORE INTO profiles(id, name, color, created_at) VALUES (1, ?1, ?2, ?3)",
        rusqlite::params![first_profile_name, PROFILE_COLORS[0], now_secs()],
    )?;
    for table in ["playlists", "listen_events"] {
        if !has_column(&tx, table, "profile_id")? {
            tx.execute_batch(&format!(
                "ALTER TABLE {table}
                 ADD COLUMN profile_id INTEGER NOT NULL DEFAULT 1 REFERENCES profiles(id) ON DELETE CASCADE;"
            ))?;
        }
    }
    if !has_column(&tx, "favorites", "profile_id")? {
        tx.execute_batch(SCHEMA_V14_FAVORITES)?;
    }
    tx.execute_batch(SCHEMA_V14_DROP_INDEXES)?;
    tx.pragma_update(None, "user_version", 14)?;
    tx.commit()?;
    Ok(())
}

/// Per-profile sync (K24, `docs/PROFILES.md`): every pairing is bound to one
/// profile and the replicated rows carry the profile they belong to.
/// `sync_playlist_map` (playlist ids are global) and `sync_present`
/// (presence is about the library) stay shared. Runs with
/// `foreign_keys = OFF`, like v14.
const SCHEMA_V15_FAVORITES: &str = "
CREATE TABLE sync_favorites_v15 (
    profile_id  INTEGER NOT NULL DEFAULT 1 REFERENCES profiles(id) ON DELETE CASCADE,
    key         TEXT NOT NULL,
    title       TEXT NOT NULL,
    artist      TEXT NOT NULL,
    album       TEXT NOT NULL,
    duration_ms INTEGER,
    is_on       INTEGER NOT NULL,
    hlc         TEXT NOT NULL,
    seq         INTEGER NOT NULL,
    PRIMARY KEY (profile_id, key)
);
INSERT INTO sync_favorites_v15(profile_id, key, title, artist, album, duration_ms, is_on, hlc, seq)
SELECT 1, key, title, artist, album, duration_ms, is_on, hlc, seq FROM sync_favorites;
DROP TABLE sync_favorites;
ALTER TABLE sync_favorites_v15 RENAME TO sync_favorites;
";

const SCHEMA_V15_INDEXES: &str = "
DROP INDEX IF EXISTS sync_favorites_seq;
DROP INDEX IF EXISTS sync_playlists_seq;
DROP INDEX IF EXISTS sync_playlist_entries_seq;
DROP INDEX IF EXISTS sync_listens_seq;
CREATE INDEX IF NOT EXISTS sync_favorites_profile_seq ON sync_favorites(profile_id, seq);
CREATE INDEX IF NOT EXISTS sync_playlists_profile_seq ON sync_playlists(profile_id, seq);
CREATE INDEX IF NOT EXISTS sync_playlist_entries_profile_seq ON sync_playlist_entries(profile_id, seq);
CREATE INDEX IF NOT EXISTS sync_listens_profile_seq ON sync_listens(profile_id, seq);
";

/// Schema v15, written so a repeated run is harmless (like v13 and v14).
fn migrate_v15(conn: &Connection) -> Result<()> {
    let tx = conn.unchecked_transaction()?;
    for table in [
        "sync_peers",
        "sync_playlists",
        "sync_playlist_entries",
        "sync_listens",
    ] {
        if !has_column(&tx, table, "profile_id")? {
            tx.execute_batch(&format!(
                "ALTER TABLE {table}
                 ADD COLUMN profile_id INTEGER NOT NULL DEFAULT 1 REFERENCES profiles(id) ON DELETE CASCADE;"
            ))?;
        }
    }
    if !has_column(&tx, "sync_favorites", "profile_id")? {
        tx.execute_batch(SCHEMA_V15_FAVORITES)?;
    }
    tx.execute_batch(SCHEMA_V15_INDEXES)?;
    tx.pragma_update(None, "user_version", 15)?;
    tx.commit()?;
    Ok(())
}

/// Opens-time setup: pragmas and migrations. A database that gets its first
/// profile in this call names it [`DEFAULT_FIRST_PROFILE_NAME`].
pub fn init(conn: &Connection) -> Result<()> {
    init_with_first_profile(conn, DEFAULT_FIRST_PROFILE_NAME)
}

/// Like [`init`]; `first_profile_name` names profile 1 when the v14
/// migration creates it.
pub fn init_with_first_profile(conn: &Connection, first_profile_name: &str) -> Result<()> {
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "foreign_keys", true)?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version > SCHEMA_VERSION {
        return Err(super::LibraryError::Other(format!(
            "library database version {version} is newer than supported {SCHEMA_VERSION}"
        )));
    }
    if version < 1 {
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch(SCHEMA_V1)?;
        tx.pragma_update(None, "user_version", 1)?;
        tx.commit()?;
    }
    if version < 2 {
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch(SCHEMA_V2)?;
        tx.pragma_update(None, "user_version", 2)?;
        tx.commit()?;
    }
    if version < 3 {
        // Dropping `albums` to replace its UNIQUE constraint requires
        // `foreign_keys = OFF` outside the transaction; FKs are re-enabled
        // before returning.
        conn.pragma_update(None, "foreign_keys", false)?;
        let res = (|| -> Result<()> {
            let tx = conn.unchecked_transaction()?;
            tx.execute_batch(SCHEMA_V3)?;
            delete_empty_albums(&tx)?;
            tx.pragma_update(None, "user_version", 3)?;
            tx.commit()?;
            Ok(())
        })();
        conn.pragma_update(None, "foreign_keys", true)?;
        res?;
    }
    if version < 4 {
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch(SCHEMA_V4)?;
        tx.pragma_update(None, "user_version", 4)?;
        tx.commit()?;
    }
    if version < 5 {
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch(SCHEMA_V5)?;
        tx.pragma_update(None, "user_version", 5)?;
        tx.commit()?;
    }
    if version < 6 {
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch(SCHEMA_V6)?;
        tx.pragma_update(None, "user_version", 6)?;
        tx.commit()?;
    }
    if version < 7 {
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch(SCHEMA_V7)?;
        backfill_track_artists(&tx)?;
        tx.pragma_update(None, "user_version", 7)?;
        tx.commit()?;
    }
    if version < 8 {
        // v3 keyed albums by each track's own year, which split albums whose
        // tracks carry different or missing years. Re-derive albums per
        // folder group, and re-split artists with the corrected rules.
        let tx = conn.unchecked_transaction()?;
        regroup_all_albums(&tx)?;
        let orphan_covers = delete_empty_albums(&tx)?;
        backfill_track_artists(&tx)?;
        tx.pragma_update(None, "user_version", 8)?;
        tx.commit()?;
        for cover in orphan_covers {
            if let Err(e) = std::fs::remove_file(&cover) {
                log::debug!("could not remove cover {cover}: {e}");
            }
        }
    }
    if version < 9 {
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch(SCHEMA_V9)?;
        tx.pragma_update(None, "user_version", 9)?;
        tx.commit()?;
    }
    if version < 10 {
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch(SCHEMA_V10)?;
        tx.pragma_update(None, "user_version", 10)?;
        tx.commit()?;
    }
    if version < 11 {
        // Artist splitting changed ("A, B & C" is three artists unless it is
        // a known band): split every track's artists again.
        let tx = conn.unchecked_transaction()?;
        backfill_track_artists(&tx)?;
        tx.pragma_update(None, "user_version", 11)?;
        tx.commit()?;
    }
    if version < 12 {
        // When each song was added to its playlist ("Date added"). Older
        // entries get the playlist's creation time: the best guess there is.
        let tx = conn.unchecked_transaction()?;
        let has_column: bool = tx.query_row(
            "SELECT COUNT(*) > 0 FROM pragma_table_info('playlist_tracks') WHERE name = 'added_at'",
            [],
            |r| r.get(0),
        )?;
        if !has_column {
            tx.execute_batch("ALTER TABLE playlist_tracks ADD COLUMN added_at INTEGER;")?;
        }
        tx.execute(
            "UPDATE playlist_tracks SET added_at =
                 (SELECT created_at FROM playlists p WHERE p.id = playlist_tracks.playlist_id)
             WHERE added_at IS NULL",
            [],
        )?;
        tx.pragma_update(None, "user_version", 12)?;
        tx.commit()?;
    }
    if version < 13 {
        // Sync tables, and a stable identity for every listening-history
        // row. Written so a half-applied or repeated run is harmless.
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch(SCHEMA_V13)?;
        let has_uid: bool = tx.query_row(
            "SELECT COUNT(*) > 0 FROM pragma_table_info('listen_events') WHERE name = 'uid'",
            [],
            |r| r.get(0),
        )?;
        if !has_uid {
            tx.execute_batch("ALTER TABLE listen_events ADD COLUMN uid TEXT;")?;
        }
        // SQLite's randomblob() draws from its own CSPRNG seeded by the OS,
        // so no extra crate is needed for 128-bit ids.
        tx.execute(
            "UPDATE listen_events SET uid = lower(hex(randomblob(16))) WHERE uid IS NULL",
            [],
        )?;
        tx.execute_batch(
            "CREATE UNIQUE INDEX IF NOT EXISTS listen_events_uid ON listen_events(uid);",
        )?;
        tx.pragma_update(None, "user_version", 13)?;
        tx.commit()?;
    }
    if version < 14 {
        conn.pragma_update(None, "foreign_keys", false)?;
        let res = migrate_v14(conn, first_profile_name);
        conn.pragma_update(None, "foreign_keys", true)?;
        res?;
    }
    if version < 15 {
        conn.pragma_update(None, "foreign_keys", false)?;
        let res = migrate_v15(conn);
        conn.pragma_update(None, "foreign_keys", true)?;
        res?;
    }
    // Indexes of the profile-scoped queries lead with `profile_id`.
    conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_tracks_genre_norm ON tracks(LOWER(TRIM(genre)));
         CREATE INDEX IF NOT EXISTS idx_tracks_album_added ON tracks(album_id, added_at DESC);
         CREATE INDEX IF NOT EXISTS favorites_added ON favorites(profile_id, added_at DESC);
         CREATE INDEX IF NOT EXISTS playlists_profile ON playlists(profile_id, name COLLATE NOCASE);
         CREATE INDEX IF NOT EXISTS listen_events_profile_started ON listen_events(profile_id, started_at);
         CREATE INDEX IF NOT EXISTS listen_events_profile_artist ON listen_events(profile_id, artist COLLATE NOCASE, started_at);
         CREATE INDEX IF NOT EXISTS listen_events_profile_track ON listen_events(profile_id, track_id, completed, listened_ms);
         CREATE INDEX IF NOT EXISTS listen_events_profile_path ON listen_events(profile_id, path, completed, listened_ms) WHERE track_id IS NULL;
         CREATE INDEX IF NOT EXISTS tracks_title_artist ON tracks(title, artist, id);
         CREATE INDEX IF NOT EXISTS tracks_title_desc ON tracks(title DESC, artist, id);
         CREATE INDEX IF NOT EXISTS tracks_duration_asc ON tracks((duration_ms IS NULL), duration_ms, title, id);
         CREATE INDEX IF NOT EXISTS tracks_duration_desc ON tracks((duration_ms IS NULL), duration_ms DESC, title, id);
         CREATE INDEX IF NOT EXISTS listen_events_profile_artist_plays ON listen_events(profile_id, artist COLLATE NOCASE, listened_ms, completed);
         CREATE INDEX IF NOT EXISTS listen_events_profile_stats ON listen_events(profile_id, started_at, track_id, listened_ms, completed, skipped, title, artist, album, genre);",
    )?;
    Ok(())
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

/// The year shown for an album: the most common track year, the latest one
/// on a tie (a compilation's tracks all differ; its release is the latest).
/// Tracks without a year are ignored.
pub fn pick_album_year(years: impl IntoIterator<Item = Option<i64>>) -> Option<i64> {
    let mut counts: HashMap<i64, usize> = HashMap::new();
    for y in years.into_iter().flatten() {
        *counts.entry(y).or_default() += 1;
    }
    counts
        .into_iter()
        .max_by_key(|&(year, n)| (n, year))
        .map(|(year, _)| year)
}

/// A track with its current album, as needed to re-derive album groups.
struct GroupedTrack {
    track_id: i64,
    path: String,
    year: Option<i64>,
    album_id: i64,
    title: String,
    album_artist: String,
    album_year: Option<i64>,
    cover: Option<String>,
}

const GROUPED_TRACK_SELECT: &str = "SELECT t.id, t.path, t.year, a.id, a.title,
        a.album_artist, a.year, a.cover
     FROM tracks t JOIN albums a ON a.id = t.album_id";

fn grouped_track(r: &Row<'_>) -> rusqlite::Result<GroupedTrack> {
    Ok(GroupedTrack {
        track_id: r.get(0)?,
        path: r.get(1)?,
        year: r.get(2)?,
        album_id: r.get(3)?,
        title: r.get(4)?,
        album_artist: r.get(5)?,
        album_year: r.get(6)?,
        cover: r.get(7)?,
    })
}

/// Re-derives the albums of the tracks directly inside `dirs`. An album is
/// one (folder, album title, album artist) group; its year comes from
/// [`pick_album_year`], so a track's own year never splits it off. Groups in
/// different folders that end up with the same title, artist and year share
/// one album (e.g. `CD1`/`CD2` folders). Albums left empty are not deleted
/// here; call [`delete_empty_albums`] afterwards.
pub fn regroup_albums_in_dirs(conn: &Connection, dirs: &HashSet<PathBuf>) -> Result<()> {
    let mut st = conn.prepare_cached(&format!(
        "{GROUPED_TRACK_SELECT} WHERE t.path >= ?1 AND t.path < ?2"
    ))?;
    let mut rows = Vec::new();
    for dir in dirs {
        let lower = dir.to_string_lossy().into_owned();
        // Every path that starts with `lower`; the filter below keeps only
        // the files directly inside `dir`.
        let upper = format!("{lower}\u{10FFFF}");
        for row in st.query_map([&lower, &upper], grouped_track)? {
            let row = row?;
            if Path::new(&row.path).parent() == Some(dir.as_path()) {
                rows.push(row);
            }
        }
    }
    apply_regroup(conn, rows)
}

fn regroup_all_albums(conn: &Connection) -> Result<()> {
    let mut st = conn.prepare(GROUPED_TRACK_SELECT)?;
    let rows = st
        .query_map([], grouped_track)?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    apply_regroup(conn, rows)
}

fn apply_regroup(conn: &Connection, rows: Vec<GroupedTrack>) -> Result<()> {
    let mut groups: HashMap<(PathBuf, String, String), Vec<GroupedTrack>> = HashMap::new();
    for row in rows {
        let dir = Path::new(&row.path)
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default();
        let key = (
            dir,
            row.title.to_lowercase(),
            row.album_artist.to_lowercase(),
        );
        groups.entry(key).or_default().push(row);
    }
    let mut upsert = conn.prepare_cached(
        "INSERT INTO albums(title, album_artist, year, cover) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(title, album_artist, COALESCE(year, -1)) DO UPDATE SET
            cover = CASE
                WHEN cover IS NOT NULL AND (cover LIKE '%/custom_%' OR cover LIKE '%\\custom_%') THEN cover
                WHEN excluded.cover IS NOT NULL AND (excluded.cover LIKE '%/custom_%' OR excluded.cover LIKE '%\\custom_%') THEN excluded.cover
                ELSE COALESCE(cover, excluded.cover)
            END
         RETURNING id",
    )?;
    let mut move_track = conn.prepare_cached("UPDATE tracks SET album_id = ?1 WHERE id = ?2")?;
    for members in groups.values() {
        let year = pick_album_year(members.iter().map(|m| m.year));
        let first = &members[0];
        let settled = members
            .iter()
            .all(|m| m.album_id == first.album_id && m.album_year == year);
        if settled {
            continue;
        }
        let cover = members
            .iter()
            .filter(|m| m.cover.as_deref().is_some_and(is_custom_album_cover_path))
            .chain(members.iter().filter(|m| m.album_year == year))
            .chain(members.iter())
            .find_map(|m| m.cover.clone());
        let target: i64 = upsert.query_row(
            rusqlite::params![first.title, first.album_artist, year, cover],
            |r| r.get(0),
        )?;
        for m in members.iter().filter(|m| m.album_id != target) {
            move_track.execute([target, m.track_id])?;
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SortOrder {
    Artist,
    Title,
    Album,
    Added,
    Duration,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SortDir {
    Asc,
    Desc,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SortSpec {
    pub order: SortOrder,
    pub dir: SortDir,
}

impl SortOrder {
    /// Unknown names fall back to the default (`Artist`).
    pub fn parse(s: &str) -> Self {
        match s {
            "title" => Self::Title,
            "album" => Self::Album,
            "added" => Self::Added,
            "duration" => Self::Duration,
            _ => Self::Artist,
        }
    }

    pub fn default_dir(self) -> SortDir {
        match self {
            Self::Added => SortDir::Desc,
            _ => SortDir::Asc,
        }
    }
}

impl SortDir {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "asc" => Some(Self::Asc),
            "desc" => Some(Self::Desc),
            _ => None,
        }
    }
}

impl SortSpec {
    pub fn new(order: SortOrder, dir: SortDir) -> Self {
        Self { order, dir }
    }

    pub fn parse(sort: &str, dir: Option<&str>) -> Self {
        let order = SortOrder::parse(sort);
        let dir = dir
            .and_then(SortDir::parse)
            .unwrap_or_else(|| order.default_dir());
        Self { order, dir }
    }

    fn order_by(self) -> &'static str {
        match (self.order, self.dir) {
            (SortOrder::Artist, SortDir::Asc) => {
                "t.artist, a.title, a.year, a.id, t.disc_no, t.track_no, t.title, t.id"
            }
            (SortOrder::Artist, SortDir::Desc) => {
                "t.artist DESC, a.title, a.year, a.id, t.disc_no, t.track_no, t.title, t.id"
            }
            (SortOrder::Title, SortDir::Asc) => "t.title, t.artist, t.id",
            (SortOrder::Title, SortDir::Desc) => "t.title DESC, t.artist, t.id",
            (SortOrder::Album, SortDir::Asc) => {
                "a.title, a.album_artist, a.year, a.id, t.disc_no, t.track_no, t.title, t.id"
            }
            (SortOrder::Album, SortDir::Desc) => {
                "a.title DESC, a.album_artist DESC, a.year DESC, a.id DESC, t.disc_no, t.track_no, t.title, t.id"
            }
            (SortOrder::Added, SortDir::Asc) => "t.added_at ASC, t.id ASC",
            (SortOrder::Added, SortDir::Desc) => "t.added_at DESC, t.id",
            (SortOrder::Duration, SortDir::Asc) => {
                "t.duration_ms IS NULL, t.duration_ms ASC, t.title, t.id"
            }
            (SortOrder::Duration, SortDir::Desc) => {
                "t.duration_ms IS NULL, t.duration_ms DESC, t.title, t.id"
            }
        }
    }
}

impl From<SortOrder> for SortSpec {
    fn from(order: SortOrder) -> Self {
        Self {
            order,
            dir: order.default_dir(),
        }
    }
}

pub fn folders(conn: &Connection) -> Result<Vec<FolderInfo>> {
    let mut st = conn.prepare("SELECT id, path FROM folders ORDER BY id")?;
    let rows = st.query_map([], |r| {
        Ok(FolderInfo {
            id: r.get(0)?,
            path: r.get(1)?,
        })
    })?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

pub fn add_folder(conn: &Connection, path: &str) -> Result<i64> {
    conn.execute(
        "INSERT INTO folders(path) VALUES (?1) ON CONFLICT(path) DO NOTHING",
        [path],
    )?;
    Ok(
        conn.query_row("SELECT id FROM folders WHERE path = ?1", [path], |r| {
            r.get(0)
        })?,
    )
}

/// Deletes a folder (tracks cascade) and returns cover files of albums that
/// became empty; the caller deletes the files.
pub fn remove_folder(conn: &mut Connection, id: i64) -> Result<Vec<String>> {
    let tx = conn.transaction()?;
    tx.execute("DELETE FROM folders WHERE id = ?1", [id])?;
    let covers = delete_empty_albums(&tx)?;
    tx.commit()?;
    Ok(covers)
}

/// Deletes albums without tracks; returns their cover paths (excluding any
/// still referenced by another non-empty album).
pub fn delete_empty_albums(conn: &Connection) -> Result<Vec<String>> {
    let mut st = conn.prepare(
        "SELECT DISTINCT cover FROM albums WHERE cover IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM tracks WHERE album_id = albums.id)
         AND NOT EXISTS (
             SELECT 1 FROM albums other
             WHERE other.cover = albums.cover
               AND EXISTS (SELECT 1 FROM tracks WHERE album_id = other.id)
         )",
    )?;
    let covers = st
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    conn.execute(
        "DELETE FROM albums WHERE NOT EXISTS (SELECT 1 FROM tracks WHERE album_id = albums.id)",
        [],
    )?;
    Ok(covers)
}

pub fn counts(conn: &Connection) -> Result<(u64, u64)> {
    let tracks: i64 = conn.query_row("SELECT COUNT(*) FROM tracks", [], |r| r.get(0))?;
    let albums: i64 = conn.query_row("SELECT COUNT(*) FROM albums", [], |r| r.get(0))?;
    Ok((tracks as u64, albums as u64))
}

/// Track columns, then `plays`: this profile's listens that count as a play
/// (finished or at least 15 s, same rule as `PLAY_EXPR`), matched by track
/// id or path. The profile id is a number, so it is written into the SQL.
fn track_columns(profile: ProfileId) -> String {
    let p = profile.0;
    format!(
        "SELECT t.id, t.title, t.artist, COALESCE(a.title, ''), t.album_id,
        t.track_no, t.disc_no, t.year, t.duration_ms, t.path, a.cover,
        ((SELECT COUNT(*) FROM listen_events le
           WHERE le.profile_id = {p} AND le.track_id = t.id
             AND (le.completed = 1 OR le.listened_ms >= 15000))
         + (SELECT COUNT(*) FROM listen_events le
           WHERE le.profile_id = {p} AND le.track_id IS NULL AND le.path = t.path
             AND (le.completed = 1 OR le.listened_ms >= 15000))) AS plays"
    )
}

fn track_select(profile: ProfileId) -> String {
    format!(
        "{} FROM tracks t LEFT JOIN albums a ON a.id = t.album_id",
        track_columns(profile)
    )
}

/// Playlist entries: the track columns plus when it was added.
fn playlist_track_select(profile: ProfileId) -> String {
    format!(
        "{}, pt.added_at AS entry_added_at
     FROM playlist_tracks pt JOIN tracks t ON t.id = pt.track_id
     LEFT JOIN albums a ON a.id = t.album_id",
        track_columns(profile)
    )
}

fn opt_u32(v: Option<i64>) -> Option<u32> {
    v.and_then(|n| u32::try_from(n).ok())
}

fn track_row(r: &Row<'_>) -> rusqlite::Result<TrackRow> {
    Ok(TrackRow {
        id: r.get(0)?,
        title: r.get(1)?,
        artist: r.get(2)?,
        album: r.get(3)?,
        album_id: r.get(4)?,
        track_no: opt_u32(r.get(5)?),
        disc_no: opt_u32(r.get(6)?),
        year: r
            .get::<_, Option<i64>>(7)?
            .and_then(|n| i32::try_from(n).ok()),
        duration_ms: r
            .get::<_, Option<i64>>(8)?
            .and_then(|n| u64::try_from(n).ok()),
        path: r.get(9)?,
        cover: r.get(10)?,
        added_to_playlist: r
            .as_ref()
            .column_index("entry_added_at")
            .ok()
            .and_then(|i| r.get::<_, Option<i64>>(i).ok().flatten()),
        // Only queries that select a `plays` column have it.
        plays: r
            .as_ref()
            .column_index("plays")
            .ok()
            .and_then(|i| r.get::<_, Option<i64>>(i).ok().flatten())
            .and_then(|n| u32::try_from(n).ok())
            .unwrap_or(0),
    })
}

struct Filter {
    where_sql: String,
    params: Vec<String>,
}

fn build_filter(query: &str, clause_for_param: impl Fn(usize) -> String) -> Filter {
    let params: Vec<String> = query
        .split_whitespace()
        .take(8)
        .map(|tok| {
            let escaped = tok
                .replace('\\', "\\\\")
                .replace('%', "\\%")
                .replace('_', "\\_");
            format!("%{escaped}%")
        })
        .collect();
    if params.is_empty() {
        return Filter {
            where_sql: String::new(),
            params,
        };
    }
    let parts: Vec<String> = (1..=params.len()).map(clause_for_param).collect();
    Filter {
        where_sql: format!("WHERE {}", parts.join(" AND ")),
        params,
    }
}

fn track_filter(query: &str) -> Filter {
    build_filter(query, |i| {
        format!(
            "(t.title LIKE ?{i} ESCAPE '\\' OR t.artist LIKE ?{i} ESCAPE '\\' \
             OR COALESCE(a.title, '') LIKE ?{i} ESCAPE '\\')"
        )
    })
}

fn album_filter(query: &str) -> Filter {
    build_filter(query, |i| {
        format!(
            "(a.title LIKE ?{i} ESCAPE '\\' OR a.album_artist LIKE ?{i} ESCAPE '\\' \
             OR EXISTS (SELECT 1 FROM tracks t WHERE t.album_id = a.id \
             AND (t.title LIKE ?{i} ESCAPE '\\' OR t.artist LIKE ?{i} ESCAPE '\\')))"
        )
    })
}

pub fn tracks_page(
    conn: &Connection,
    profile: ProfileId,
    offset: u64,
    limit: u64,
    sort: impl Into<SortSpec>,
) -> Result<Vec<TrackRow>> {
    Ok(search_tracks_page(conn, profile, offset, limit, sort, "")?.items)
}

fn query_page<T>(
    conn: &Connection,
    count_sql: &str,
    page_sql: &str,
    filter_params: Vec<String>,
    offset: u64,
    limit: u64,
    mapper: impl FnMut(&Row<'_>) -> rusqlite::Result<T>,
) -> Result<Page<T>> {
    let mut values: Vec<Value> = filter_params.into_iter().map(Value::Text).collect();
    let total: i64 = conn.query_row(count_sql, params_from_iter(values.iter()), |r| r.get(0))?;
    values.push(Value::Integer(limit as i64));
    values.push(Value::Integer(offset as i64));
    let mut st = conn.prepare(page_sql)?;
    let rows = st.query_map(params_from_iter(values.iter()), mapper)?;
    Ok(Page {
        total: total.max(0) as u64,
        items: rows.collect::<std::result::Result<_, _>>()?,
    })
}

pub fn search_tracks_page(
    conn: &Connection,
    profile: ProfileId,
    offset: u64,
    limit: u64,
    sort: impl Into<SortSpec>,
    query: &str,
) -> Result<Page<TrackRow>> {
    let sort = sort.into();
    let f = track_filter(query);
    let n = f.params.len();
    let count_sql = format!(
        "SELECT COUNT(*) FROM tracks t LEFT JOIN albums a ON a.id = t.album_id {}",
        f.where_sql
    );
    // Pick the page's ids first (sort and OFFSET on minimal columns), then
    // load the rows and their play counts for those ids only; the outer
    // ORDER BY re-sorts just the page.
    let cols = track_columns(profile);
    let order = sort.order_by();
    let page_sql = format!(
        "{cols}
         FROM (SELECT t.id AS id
               FROM tracks t LEFT JOIN albums a ON a.id = t.album_id
               {} ORDER BY {order} LIMIT ?{} OFFSET ?{}) p
         JOIN tracks t ON t.id = p.id
         LEFT JOIN albums a ON a.id = t.album_id
         ORDER BY {order}",
        f.where_sql,
        n + 1,
        n + 2
    );
    if f.params.is_empty()
        && offset >= DEEP_PAGE_OFFSET
        && sort.order == SortOrder::Artist
        && let Some(items) = deep_artist_page(conn, profile, offset, limit, sort.dir)?
    {
        let total: i64 = conn.query_row(&count_sql, [], |r| r.get(0))?;
        return Ok(Page {
            total: total.max(0) as u64,
            items,
        });
    }
    query_page(
        conn, &count_sql, &page_sql, f.params, offset, limit, track_row,
    )
}

/// From this offset on, an unfiltered artist-sorted page skips the sort of
/// the whole library (see `deep_artist_page`).
const DEEP_PAGE_OFFSET: u64 = if cfg!(test) { 20 } else { 1_000 };

/// A deep page of the artist-sorted song list without sorting every track:
/// the artist at `offset` and the number of tracks before that artist come
/// from the `(artist, title)` index, so only the tracks from that artist on
/// are sorted, with the offset reduced by the tracks skipped. Same rows in
/// the same order as the plain query; `None` when the offset is past the end.
fn deep_artist_page(
    conn: &Connection,
    profile: ProfileId,
    offset: u64,
    limit: u64,
    dir: SortDir,
) -> Result<Option<Vec<TrackRow>>> {
    let (cmp, dir_sql) = match dir {
        SortDir::Asc => (">=", ""),
        SortDir::Desc => ("<=", " DESC"),
    };
    let Some(boundary): Option<String> = conn
        .query_row(
            &format!("SELECT artist FROM tracks ORDER BY artist{dir_sql} LIMIT 1 OFFSET ?1"),
            [offset as i64],
            |r| r.get(0),
        )
        .optional()?
    else {
        return Ok(None);
    };
    let before_cmp = if dir == SortDir::Asc { "<" } else { ">" };
    let before: i64 = conn.query_row(
        &format!("SELECT COUNT(*) FROM tracks WHERE artist {before_cmp} ?1"),
        [&boundary],
        |r| r.get(0),
    )?;
    let cols = track_columns(profile);
    let order = SortSpec::new(SortOrder::Artist, dir).order_by();
    let mut st = conn.prepare(&format!(
        "{cols}
         FROM (SELECT t.id AS id
               FROM tracks t LEFT JOIN albums a ON a.id = t.album_id
               WHERE t.artist {cmp} ?1 ORDER BY {order} LIMIT ?2 OFFSET ?3) p
         JOIN tracks t ON t.id = p.id
         LEFT JOIN albums a ON a.id = t.album_id
         ORDER BY {order}"
    ))?;
    let rows = st.query_map(
        rusqlite::params![&boundary, limit as i64, offset as i64 - before],
        track_row,
    )?;
    Ok(Some(rows.collect::<std::result::Result<_, _>>()?))
}

/// Row → queue track (path, title, artist) for the three-column selects below.
fn queue_track(r: &rusqlite::Row<'_>) -> rusqlite::Result<Track> {
    Ok(Track {
        path: PathBuf::from(r.get::<_, String>(0)?),
        title: Some(r.get(1)?),
        artist: Some(r.get(2)?),
    })
}

pub fn all_tracks(conn: &Connection, sort: impl Into<SortSpec>) -> Result<Vec<Track>> {
    matching_tracks(conn, sort, "")
}

pub fn matching_tracks(
    conn: &Connection,
    sort: impl Into<SortSpec>,
    query: &str,
) -> Result<Vec<Track>> {
    let sort = sort.into();
    let f = track_filter(query);
    let sql = format!(
        "SELECT t.path, t.title, t.artist FROM tracks t \
         LEFT JOIN albums a ON a.id = t.album_id {} ORDER BY {}",
        f.where_sql,
        sort.order_by()
    );
    let values: Vec<Value> = f.params.into_iter().map(Value::Text).collect();
    let mut st = conn.prepare(&sql)?;
    let rows = st.query_map(params_from_iter(values.iter()), queue_track)?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

const ALBUM_SELECT: &str = "SELECT a.id, a.title, a.album_artist, a.year,
        (SELECT COUNT(*) FROM tracks WHERE album_id = a.id), a.cover
     FROM albums a";

fn album_row(r: &Row<'_>) -> rusqlite::Result<AlbumRow> {
    Ok(AlbumRow {
        id: r.get(0)?,
        title: r.get(1)?,
        album_artist: r.get(2)?,
        year: r
            .get::<_, Option<i64>>(3)?
            .and_then(|n| i32::try_from(n).ok()),
        track_count: r.get::<_, i64>(4)?.try_into().unwrap_or(u32::MAX),
        cover: r.get(5)?,
    })
}

pub fn albums_page(conn: &Connection, offset: u64, limit: u64) -> Result<Vec<AlbumRow>> {
    Ok(search_albums_page(conn, offset, limit, "")?.items)
}

pub fn search_albums_page(
    conn: &Connection,
    offset: u64,
    limit: u64,
    query: &str,
) -> Result<Page<AlbumRow>> {
    let f = album_filter(query);
    let n = f.params.len();
    let count_sql = format!("SELECT COUNT(*) FROM albums a {}", f.where_sql);
    let page_sql = format!(
        "{ALBUM_SELECT} {} ORDER BY a.album_artist, a.title, a.year, a.id LIMIT ?{} OFFSET ?{}",
        f.where_sql,
        n + 1,
        n + 2
    );
    query_page(
        conn, &count_sql, &page_sql, f.params, offset, limit, album_row,
    )
}

const ALBUM_TRACK_ORDER: &str = "t.disc_no, t.track_no, t.title, t.id";

pub fn album_info(conn: &Connection, album_id: i64) -> Result<Option<AlbumRow>> {
    Ok(conn
        .query_row(
            &format!("{ALBUM_SELECT} WHERE a.id = ?1"),
            [album_id],
            album_row,
        )
        .optional()?)
}

pub fn album_detail(conn: &Connection, profile: ProfileId, album_id: i64) -> Result<AlbumDetail> {
    let album = album_info(conn, album_id)?
        .ok_or_else(|| super::LibraryError::Other(format!("album {album_id} not found")))?;
    let ts = track_select(profile);
    let mut st = conn.prepare(&format!(
        "{ts} WHERE t.album_id = ?1 ORDER BY {ALBUM_TRACK_ORDER}"
    ))?;
    let tracks = st
        .query_map([album_id], track_row)?
        .collect::<std::result::Result<_, _>>()?;
    Ok(AlbumDetail { album, tracks })
}

pub fn album_tracks(conn: &Connection, album_id: i64) -> Result<Vec<Track>> {
    let mut st = conn.prepare(&format!(
        "SELECT t.path, t.title, t.artist FROM tracks t WHERE t.album_id = ?1 ORDER BY {ALBUM_TRACK_ORDER}"
    ))?;
    let rows = st.query_map([album_id], queue_track)?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

/// Cover file of the album a track belongs to, if any.
pub fn track_cover_by_path(conn: &Connection, path: &str) -> Result<Option<String>> {
    conn.query_row(
        "SELECT a.cover FROM tracks t JOIN albums a ON a.id = t.album_id
         WHERE t.path = ?1",
        [path],
        |r| r.get::<_, Option<String>>(0),
    )
    .optional()
    .map(Option::flatten)
    .map_err(Into::into)
}

#[derive(Debug, Clone)]
pub struct TrackLyricsMeta {
    pub path: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_seconds: Option<f64>,
}

pub fn all_tracks_lyrics_meta(conn: &Connection) -> Result<Vec<TrackLyricsMeta>> {
    let mut st = conn.prepare(
        "SELECT t.path, t.title, t.artist, COALESCE(a.title, ''), t.duration_ms
         FROM tracks t
         LEFT JOIN albums a ON a.id = t.album_id
         ORDER BY t.id",
    )?;
    let rows = st.query_map([], |r| {
        let duration_ms: Option<i64> = r.get(4)?;
        Ok(TrackLyricsMeta {
            path: r.get(0)?,
            title: r.get(1)?,
            artist: r.get(2)?,
            album: r.get(3)?,
            duration_seconds: duration_ms.map(|ms| ms as f64 / 1000.0),
        })
    })?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

pub fn track_meta_by_path(conn: &Connection, path: &str) -> Result<Option<TrackMeta>> {
    conn.query_row(
        "SELECT t.title, t.artist, COALESCE(a.title, ''), t.duration_ms
         FROM tracks t LEFT JOIN albums a ON a.id = t.album_id
         WHERE t.path = ?1",
        [path],
        |r| {
            Ok(TrackMeta {
                title: r.get(0)?,
                artist: r.get(1)?,
                album: r.get(2)?,
                duration_ms: r
                    .get::<_, Option<i64>>(3)?
                    .and_then(|n| u64::try_from(n).ok()),
            })
        },
    )
    .optional()
    .map_err(Into::into)
}

// ---------------------------------------------------------------------
// Playlists
//
// Entries are ordered by `position`. Positions can have gaps (a track that
// disappears in a rescan cascades its entries away), so the public API
// addresses entries by their *index* in that order, and every edit rewrites
// the playlist compactly (0..n).
// ---------------------------------------------------------------------

fn playlist_not_found(id: i64) -> super::LibraryError {
    super::LibraryError::Other(format!("playlist {id} not found"))
}

fn clean_name(name: &str) -> Result<&str> {
    let name = name.trim();
    if name.is_empty() {
        return Err(super::LibraryError::Other(
            "playlist name must not be empty".into(),
        ));
    }
    Ok(name)
}

fn ensure_playlist(conn: &Connection, profile: ProfileId, id: i64) -> Result<()> {
    let found: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM playlists WHERE id = ?1 AND profile_id = ?2)",
        rusqlite::params![id, profile.0],
        |r| r.get(0),
    )?;
    if found {
        Ok(())
    } else {
        Err(playlist_not_found(id))
    }
}

fn playlist_album_covers(conn: &Connection, id: i64) -> Result<Vec<String>> {
    let mut st = conn.prepare_cached(
        "SELECT a.cover
         FROM playlist_tracks pt
         JOIN tracks t ON t.id = pt.track_id
         JOIN albums a ON a.id = t.album_id
         WHERE pt.playlist_id = ?1 AND a.cover IS NOT NULL AND a.cover != ''
         GROUP BY a.id
         ORDER BY MIN(pt.position)
         LIMIT 4",
    )?;
    let rows = st.query_map([id], |r| r.get::<_, String>(0))?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

pub fn playlist_info(conn: &Connection, profile: ProfileId, id: i64) -> Result<PlaylistInfo> {
    let mut info = conn
        .query_row(
            "SELECT p.id, p.name,
                    (SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = p.id),
                    p.cover
             FROM playlists p WHERE p.id = ?1 AND p.profile_id = ?2",
            rusqlite::params![id, profile.0],
            |r| {
                Ok(PlaylistInfo {
                    id: r.get(0)?,
                    name: r.get(1)?,
                    track_count: r.get::<_, i64>(2)?.try_into().unwrap_or(u32::MAX),
                    cover: r.get(3)?,
                    album_covers: Vec::new(),
                })
            },
        )
        .optional()?
        .ok_or_else(|| playlist_not_found(id))?;
    info.album_covers = playlist_album_covers(conn, info.id)?;
    Ok(info)
}

pub fn playlists(conn: &Connection, profile: ProfileId) -> Result<Vec<PlaylistInfo>> {
    let mut st = conn.prepare(
        "SELECT p.id, p.name, COUNT(pt.track_id), p.cover
         FROM playlists p LEFT JOIN playlist_tracks pt ON pt.playlist_id = p.id
         WHERE p.profile_id = ?1
         GROUP BY p.id ORDER BY p.name COLLATE NOCASE, p.id",
    )?;
    let rows = st.query_map([profile.0], |r| {
        Ok(PlaylistInfo {
            id: r.get(0)?,
            name: r.get(1)?,
            track_count: r.get::<_, i64>(2)?.try_into().unwrap_or(u32::MAX),
            cover: r.get(3)?,
            album_covers: Vec::new(),
        })
    })?;
    let mut out: Vec<PlaylistInfo> = rows.collect::<std::result::Result<_, _>>()?;
    for item in &mut out {
        item.album_covers = playlist_album_covers(conn, item.id)?;
    }
    Ok(out)
}

/// Appends the tracks that exist in the library; unknown ids are skipped.
/// Returns how many entries were added.
fn append_tracks(conn: &Connection, id: i64, track_ids: &[i64]) -> Result<usize> {
    let mut next: i64 = conn.query_row(
        "SELECT COALESCE(MAX(position) + 1, 0) FROM playlist_tracks WHERE playlist_id = ?1",
        [id],
        |r| r.get(0),
    )?;
    let mut insert = conn.prepare_cached(
        "INSERT INTO playlist_tracks(playlist_id, position, track_id, added_at)
         SELECT ?1, ?2, id, ?4 FROM tracks WHERE id = ?3",
    )?;
    let now = now_secs();
    let mut added = 0;
    for track_id in track_ids {
        if insert.execute(rusqlite::params![id, next, track_id, now])? > 0 {
            next += 1;
            added += 1;
        }
    }
    Ok(added)
}

pub fn create_playlist(
    conn: &mut Connection,
    profile: ProfileId,
    name: &str,
    track_ids: &[i64],
    now: i64,
) -> Result<PlaylistInfo> {
    let name = clean_name(name)?;
    let tx = conn.transaction()?;
    tx.execute(
        "INSERT INTO playlists(name, created_at, profile_id) VALUES (?1, ?2, ?3)",
        rusqlite::params![name, now, profile.0],
    )?;
    let id = tx.last_insert_rowid();
    append_tracks(&tx, id, track_ids)?;
    let info = playlist_info(&tx, profile, id)?;
    tx.commit()?;
    Ok(info)
}

pub fn rename_playlist(conn: &Connection, profile: ProfileId, id: i64, name: &str) -> Result<()> {
    let name = clean_name(name)?;
    let n = conn.execute(
        "UPDATE playlists SET name = ?2 WHERE id = ?1 AND profile_id = ?3",
        rusqlite::params![id, name, profile.0],
    )?;
    if n == 0 {
        return Err(playlist_not_found(id));
    }
    Ok(())
}

/// (profile, playlist id, cover) for every playlist of every profile with an
/// image file as cover (a device-wide clean-up, not a per-profile read).
pub fn playlist_cover_paths(conn: &Connection) -> Result<Vec<(ProfileId, i64, String)>> {
    let mut st = conn.prepare(
        "SELECT profile_id, id, cover FROM playlists
         WHERE cover IS NOT NULL AND cover NOT LIKE 'preset:%'",
    )?;
    let rows = st.query_map([], |r| Ok((ProfileId(r.get(0)?), r.get(1)?, r.get(2)?)))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub fn set_playlist_cover(
    conn: &Connection,
    profile: ProfileId,
    id: i64,
    cover: Option<&str>,
) -> Result<Option<String>> {
    let old: Option<String> = conn
        .query_row(
            "SELECT cover FROM playlists WHERE id = ?1 AND profile_id = ?2",
            rusqlite::params![id, profile.0],
            |r| r.get(0),
        )
        .optional()?
        .flatten();
    let n = conn.execute(
        "UPDATE playlists SET cover = ?2 WHERE id = ?1 AND profile_id = ?3",
        rusqlite::params![id, cover, profile.0],
    )?;
    if n == 0 {
        return Err(playlist_not_found(id));
    }
    Ok(old)
}

pub fn delete_playlist(conn: &Connection, profile: ProfileId, id: i64) -> Result<Option<String>> {
    let old: Option<String> = conn
        .query_row(
            "SELECT cover FROM playlists WHERE id = ?1 AND profile_id = ?2",
            rusqlite::params![id, profile.0],
            |r| r.get(0),
        )
        .optional()?
        .flatten();
    let n = conn.execute(
        "DELETE FROM playlists WHERE id = ?1 AND profile_id = ?2",
        rusqlite::params![id, profile.0],
    )?;
    if n == 0 {
        return Err(playlist_not_found(id));
    }
    Ok(old)
}

pub fn playlist_tracks(
    conn: &Connection,
    profile: ProfileId,
    id: i64,
    offset: u64,
    limit: u64,
) -> Result<Vec<TrackRow>> {
    ensure_playlist(conn, profile, id)?;
    let pts = playlist_track_select(profile);
    let mut st = conn.prepare(&format!(
        "{pts}
         WHERE pt.playlist_id = ?1 ORDER BY pt.position LIMIT ?2 OFFSET ?3"
    ))?;
    let rows = st.query_map(
        rusqlite::params![id, limit as i64, offset as i64],
        track_row,
    )?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

/// Playlist contents in order, ready for the queue.
pub fn playlist_queue_tracks(conn: &Connection, profile: ProfileId, id: i64) -> Result<Vec<Track>> {
    ensure_playlist(conn, profile, id)?;
    let mut st = conn.prepare(
        "SELECT t.path, t.title, t.artist FROM playlist_tracks pt
         JOIN tracks t ON t.id = pt.track_id
         WHERE pt.playlist_id = ?1 ORDER BY pt.position",
    )?;
    let rows = st.query_map([id], queue_track)?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

pub fn playlist_add_tracks(
    conn: &mut Connection,
    profile: ProfileId,
    id: i64,
    track_ids: &[i64],
) -> Result<usize> {
    let tx = conn.transaction()?;
    ensure_playlist(&tx, profile, id)?;
    let added = append_tracks(&tx, id, track_ids)?;
    tx.commit()?;
    Ok(added)
}

pub fn playlist_add_album(
    conn: &mut Connection,
    profile: ProfileId,
    id: i64,
    album_id: i64,
) -> Result<usize> {
    let tx = conn.transaction()?;
    ensure_playlist(&tx, profile, id)?;
    let ids = {
        let mut st = tx.prepare(&format!(
            "SELECT t.id FROM tracks t WHERE t.album_id = ?1 ORDER BY {ALBUM_TRACK_ORDER}"
        ))?;
        st.query_map([album_id], |r| r.get::<_, i64>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?
    };
    let added = append_tracks(&tx, id, &ids)?;
    tx.commit()?;
    Ok(added)
}

/// A playlist entry: the track and when it was added.
type Entry = (i64, Option<i64>);

/// Entries of a playlist in order.
fn order(conn: &Connection, id: i64) -> Result<Vec<Entry>> {
    let mut st = conn.prepare_cached(
        "SELECT track_id, added_at FROM playlist_tracks WHERE playlist_id = ?1 ORDER BY position",
    )?;
    Ok(st
        .query_map([id], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<std::result::Result<_, _>>()?)
}

/// Replaces the playlist's entries with `entries` at positions 0..n; each
/// keeps its "added" time.
fn rewrite(conn: &Connection, id: i64, entries: &[Entry]) -> Result<()> {
    conn.execute("DELETE FROM playlist_tracks WHERE playlist_id = ?1", [id])?;
    let mut insert = conn.prepare_cached(
        "INSERT INTO playlist_tracks(playlist_id, position, track_id, added_at)
         VALUES (?1, ?2, ?3, ?4)",
    )?;
    for (pos, (track_id, added_at)) in entries.iter().enumerate() {
        insert.execute(rusqlite::params![id, pos as i64, track_id, added_at])?;
    }
    Ok(())
}

/// Removes the entries at the given indexes (duplicates and out-of-range
/// indexes are ignored) and closes the gaps.
/// Ids of the playlists that contain `track_id`.
pub fn playlists_with_track(
    conn: &Connection,
    profile: ProfileId,
    track_id: i64,
) -> Result<Vec<i64>> {
    let mut st = conn.prepare_cached(
        "SELECT DISTINCT pt.playlist_id FROM playlist_tracks pt
         JOIN playlists p ON p.id = pt.playlist_id
         WHERE pt.track_id = ?1 AND p.profile_id = ?2
         ORDER BY pt.playlist_id",
    )?;
    Ok(st
        .query_map(rusqlite::params![track_id, profile.0], |r| r.get(0))?
        .collect::<std::result::Result<_, _>>()?)
}

/// Removes every entry of `track_id` from playlist `id`.
pub fn playlist_remove_track(
    conn: &mut Connection,
    profile: ProfileId,
    id: i64,
    track_id: i64,
) -> Result<()> {
    let tx = conn.transaction()?;
    ensure_playlist(&tx, profile, id)?;
    let kept: Vec<Entry> = order(&tx, id)?
        .into_iter()
        .filter(|(t, _)| *t != track_id)
        .collect();
    rewrite(&tx, id, &kept)?;
    tx.commit()?;
    Ok(())
}

pub fn playlist_remove(
    conn: &mut Connection,
    profile: ProfileId,
    id: i64,
    indexes: &[usize],
) -> Result<()> {
    let tx = conn.transaction()?;
    ensure_playlist(&tx, profile, id)?;
    let drop: std::collections::HashSet<usize> = indexes.iter().copied().collect();
    let kept: Vec<Entry> = order(&tx, id)?
        .into_iter()
        .enumerate()
        .filter(|(i, _)| !drop.contains(i))
        .map(|(_, t)| t)
        .collect();
    rewrite(&tx, id, &kept)?;
    tx.commit()?;
    Ok(())
}

/// Moves the entry at index `from` so that it ends up at index `to`.
pub fn playlist_move(
    conn: &mut Connection,
    profile: ProfileId,
    id: i64,
    from: usize,
    to: usize,
) -> Result<()> {
    let tx = conn.transaction()?;
    ensure_playlist(&tx, profile, id)?;
    let mut ids = order(&tx, id)?;
    if from >= ids.len() || to >= ids.len() {
        return Err(super::LibraryError::Other(format!(
            "index out of range (from {from}, to {to}, length {})",
            ids.len()
        )));
    }
    let moved = ids.remove(from);
    ids.insert(to, moved);
    rewrite(&tx, id, &ids)?;
    tx.commit()?;
    Ok(())
}

/// Library track id for each path (`None` when the file is not in the library).
pub fn track_ids_by_paths(conn: &Connection, paths: &[String]) -> Result<Vec<Option<i64>>> {
    let mut st = conn.prepare_cached("SELECT id FROM tracks WHERE path = ?1")?;
    paths
        .iter()
        .map(|p| Ok(st.query_row([p], |r| r.get(0)).optional()?))
        .collect()
}

/// Every track, for matching imported playlists.
pub fn match_candidates(conn: &Connection) -> Result<Vec<super::m3u::Candidate>> {
    let mut st = conn.prepare("SELECT id, path, artist, title, duration_ms FROM tracks")?;
    let rows = st.query_map([], |r| {
        Ok(super::m3u::Candidate {
            id: r.get(0)?,
            path: r.get(1)?,
            artist: r.get(2)?,
            title: r.get(3)?,
            duration_ms: r
                .get::<_, Option<i64>>(4)?
                .and_then(|n| u64::try_from(n).ok()),
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// Id, path and folder of each existing track, in the order of `ids`.
/// Unknown ids are skipped.
pub fn track_files_by_ids(conn: &Connection, ids: &[i64]) -> Result<Vec<(i64, String, i64)>> {
    let mut st = conn.prepare_cached("SELECT path, folder_id FROM tracks WHERE id = ?1")?;
    let mut out = Vec::with_capacity(ids.len());
    for &id in ids {
        if let Some((path, folder)) = st
            .query_row([id], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))
            .optional()?
        {
            out.push((id, path, folder));
        }
    }
    Ok(out)
}

// ---------------------------------------------------------------------
// Favorites
// ---------------------------------------------------------------------

pub fn favorites(conn: &Connection, profile: ProfileId) -> Result<Vec<FavoriteRef>> {
    let mut st = conn.prepare(
        "SELECT f.track_id, t.path
         FROM favorites f
         JOIN tracks t ON t.id = f.track_id
         WHERE f.profile_id = ?1
         ORDER BY f.added_at DESC, t.title COLLATE NOCASE, f.track_id",
    )?;
    let rows = st.query_map([profile.0], |r| {
        Ok(FavoriteRef {
            track_id: r.get(0)?,
            path: r.get(1)?,
        })
    })?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

pub fn toggle_favorite(
    conn: &Connection,
    profile: ProfileId,
    track_id: i64,
    now: i64,
) -> Result<bool> {
    let removed = conn.execute(
        "DELETE FROM favorites WHERE profile_id = ?1 AND track_id = ?2",
        rusqlite::params![profile.0, track_id],
    )?;
    if removed > 0 {
        return Ok(false);
    }
    let inserted = conn.execute(
        "INSERT INTO favorites(profile_id, track_id, added_at)
         SELECT ?3, id, ?2 FROM tracks WHERE id = ?1",
        rusqlite::params![track_id, now, profile.0],
    )?;
    if inserted == 0 {
        return Err(super::LibraryError::Other(format!(
            "track {track_id} not found"
        )));
    }
    Ok(true)
}

/// Adds (`on`) or removes every track in `track_ids` from the favorites;
/// returns how many changed. Ids not in the library are ignored.
pub fn set_favorites(
    conn: &mut Connection,
    profile: ProfileId,
    track_ids: &[i64],
    on: bool,
    now: i64,
) -> Result<usize> {
    let tx = conn.transaction()?;
    let mut changed = 0;
    {
        let mut add = tx.prepare_cached(
            "INSERT OR IGNORE INTO favorites(profile_id, track_id, added_at)
             SELECT ?3, id, ?2 FROM tracks WHERE id = ?1",
        )?;
        let mut del =
            tx.prepare_cached("DELETE FROM favorites WHERE track_id = ?1 AND profile_id = ?2")?;
        // Later items get later times, so the list keeps the chosen order
        // (newest first) like single stars do.
        for (i, id) in track_ids.iter().enumerate() {
            changed += if on {
                add.execute(rusqlite::params![id, now + i as i64, profile.0])?
            } else {
                del.execute(rusqlite::params![id, profile.0])?
            };
        }
    }
    tx.commit()?;
    Ok(changed)
}

pub fn favorites_page(
    conn: &Connection,
    profile: ProfileId,
    offset: u64,
    limit: u64,
) -> Result<Page<TrackRow>> {
    let total: i64 = conn.query_row(
        "SELECT COUNT(*) FROM favorites WHERE profile_id = ?1",
        [profile.0],
        |r| r.get(0),
    )?;
    let ts = track_select(profile);
    let pr = profile.0;
    let mut st = conn.prepare(&format!(
        "{ts} JOIN favorites f ON f.track_id = t.id AND f.profile_id = {pr}
         ORDER BY f.added_at DESC, t.title COLLATE NOCASE, f.track_id
         LIMIT ?1 OFFSET ?2"
    ))?;
    let rows = st.query_map(rusqlite::params![limit as i64, offset as i64], track_row)?;
    let items = rows.collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(Page {
        total: u64::try_from(total).unwrap_or(0),
        items,
    })
}

pub fn favorites_queue_tracks(conn: &Connection, profile: ProfileId) -> Result<Vec<Track>> {
    let mut st = conn.prepare(
        "SELECT t.path, t.title, t.artist
         FROM favorites f
         JOIN tracks t ON t.id = f.track_id
         WHERE f.profile_id = ?1
         ORDER BY f.added_at DESC, t.title COLLATE NOCASE, f.track_id",
    )?;
    let rows = st.query_map([profile.0], queue_track)?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

// ---------------------------------------------------------------------
// Listening history & stats
// ---------------------------------------------------------------------

/// `WHERE` clause of the listening queries: this profile's events inside the
/// optional `[?1, ?2)` range.
const PLAY_EXPR: &str = "CASE WHEN e.completed = 1 OR e.listened_ms >= 15000 THEN 1 ELSE 0 END";

pub fn record_listen_event(
    conn: &Connection,
    profile: ProfileId,
    ev: &NewListenEvent,
) -> Result<()> {
    let matched: Option<(i64, String, String, String, String, Option<i64>)> = conn
        .query_row(
            "SELECT t.id, t.title, t.artist, COALESCE(a.title, ''),
                    COALESCE(t.genre, ''), t.duration_ms
             FROM tracks t
             LEFT JOIN albums a ON a.id = t.album_id
             WHERE t.path = ?1",
            [&ev.path],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                ))
            },
        )
        .optional()?;

    let (track_id, title, artist, album, genre, lib_duration) = match matched {
        Some((id, t, ar, al, ge, dur)) => (
            Some(id),
            if t.trim().is_empty() {
                ev.title.clone()
            } else {
                t
            },
            if ar.trim().is_empty() {
                ev.artist.clone()
            } else {
                ar
            },
            al,
            ge,
            dur,
        ),
        None => (
            None,
            ev.title.clone(),
            ev.artist.clone(),
            String::new(),
            String::new(),
            None,
        ),
    };

    let duration_ms =
        lib_duration.or_else(|| ev.duration_ms.map(|d| i64::try_from(d).unwrap_or(i64::MAX)));
    let listened_ms = i64::try_from(ev.listened_ms).unwrap_or(i64::MAX);
    let source = if ev.path.starts_with("http://") || ev.path.starts_with("https://") {
        "online"
    } else {
        "local"
    };

    conn.execute(
        "INSERT INTO listen_events(
             track_id, path, title, artist, album, genre, duration_ms,
             started_at, ended_at, listened_ms, completed, skipped, source, profile_id
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
        rusqlite::params![
            track_id,
            ev.path,
            title,
            artist,
            album,
            genre,
            duration_ms,
            ev.started_at,
            ev.ended_at,
            listened_ms,
            i64::from(ev.completed),
            i64::from(ev.skipped),
            source,
            profile.0,
        ],
    )?;
    Ok(())
}

pub fn clear_listen_history(conn: &Connection, profile: ProfileId) -> Result<u64> {
    let n = conn.execute(
        "DELETE FROM listen_events WHERE profile_id = ?1",
        [profile.0],
    )?;
    Ok(n as u64)
}

fn u64_col(r: &Row<'_>, idx: usize) -> rusqlite::Result<u64> {
    let v: i64 = r.get(idx)?;
    Ok(u64::try_from(v).unwrap_or(0))
}

/// Days since 1970-01-01 -> (year, month) in the proleptic Gregorian
/// calendar (Howard Hinnant's `civil_from_days`).
fn year_month_of_day(days: i64) -> (i64, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = yoe + era * 400 + i64::from(m <= 2);
    (y, m)
}

/// Local-time offset (seconds east of UTC) at `ts`, as SQLite's
/// `'localtime'` modifier sees it.
fn local_offset(st: &mut rusqlite::Statement<'_>, ts: i64) -> Result<i64> {
    Ok(st.query_row([ts, ts], |r| r.get::<_, i64>(0))?)
}

/// Everything the stats view derives from time buckets, from one pass over
/// the events: summary sums, hour / weekday / month totals and the distinct
/// local days (for active days and streaks).
struct TimeBuckets {
    total_listened_ms: u64,
    play_count: u64,
    raw_event_count: u64,
    skip_count: u64,
    completed_count: u64,
    first_listen_at: Option<i64>,
    by_hour: Vec<BucketStat>,
    by_weekday: Vec<BucketStat>,
    by_month: Vec<BucketStat>,
    /// Distinct local days (days since 1970-01-01, local calendar), ascending.
    days: Vec<i64>,
}

/// Events are summed per 15-minute UTC window first (integer maths on the
/// index, no per-event `localtime`; calling `strftime` for every event was
/// most of the old cost), then each window is placed in local
/// time. Every real UTC offset and DST change is a multiple of 15 minutes, so
/// a window never straddles a local hour or day boundary.
fn time_buckets(conn: &Connection, range: &str) -> Result<TimeBuckets> {
    // Ascending by `started_at` straight off the covering index; windows
    // are contiguous, so they are summed on the fly without a sorter.
    let sql = format!(
        "SELECT e.started_at, e.listened_ms,
                CASE WHEN e.completed = 1 OR e.listened_ms >= 15000 THEN 1 ELSE 0 END,
                e.skipped, e.completed
         FROM listen_events e
         WHERE {range}
         ORDER BY e.started_at"
    );
    let mut st = conn.prepare(&sql)?;
    let mut off_st =
        conn.prepare("SELECT CAST(strftime('%s', ?1, 'unixepoch', 'localtime') AS INTEGER) - ?2")?;
    let mut t = TimeBuckets {
        total_listened_ms: 0,
        play_count: 0,
        raw_event_count: 0,
        skip_count: 0,
        completed_count: 0,
        first_listen_at: None,
        by_hour: (0..24)
            .map(|h| BucketStat {
                label: format!("{h:02}"),
                listened_ms: 0,
                play_count: 0,
            })
            .collect(),
        by_weekday: (0..7)
            .map(|w| BucketStat {
                label: w.to_string(),
                listened_ms: 0,
                play_count: 0,
            })
            .collect(),
        by_month: Vec::new(),
        days: Vec::new(),
    };
    let mut months: std::collections::BTreeMap<String, (u64, u64)> = Default::default();
    let mut days: std::collections::BTreeSet<i64> = Default::default();
    // One 15-minute window: first timestamp, then sums.
    struct Window {
        id: i64,
        first: i64,
        ms: u64,
        plays: u64,
        events: u64,
        skips: u64,
        completed: u64,
    }
    let mut place = |w: &Window, t: &mut TimeBuckets| -> Result<()> {
        t.raw_event_count += w.events;
        t.skip_count += w.skips;
        t.completed_count += w.completed;
        t.total_listened_ms += w.ms;
        t.play_count += w.plays;
        t.first_listen_at = Some(t.first_listen_at.map_or(w.first, |f| f.min(w.first)));
        let local = w.first + local_offset(&mut off_st, w.first)?;
        let day = local.div_euclid(SECS_PER_DAY);
        let hour = (local.rem_euclid(SECS_PER_DAY) / 3_600) as usize;
        // 1970-01-01 was a Thursday; SQLite `%w` has Sunday = 0.
        let sqlite_wday = (day + 4).rem_euclid(7);
        // Monday-first: 0 = Mon .. 6 = Sun.
        let wday = ((sqlite_wday + 6) % 7) as usize;
        t.by_hour[hour].listened_ms += w.ms;
        t.by_hour[hour].play_count += w.plays;
        t.by_weekday[wday].listened_ms += w.ms;
        t.by_weekday[wday].play_count += w.plays;
        let (y, m) = year_month_of_day(day);
        let e = months.entry(format!("{y:04}-{m:02}")).or_default();
        e.0 += w.ms;
        e.1 += w.plays;
        days.insert(day);
        Ok(())
    };
    let mut cur: Option<Window> = None;
    let mut rows = st.query([])?;
    while let Some(r) = rows.next()? {
        let started: i64 = r.get(0)?;
        let id = started.div_euclid(900);
        if cur.as_ref().is_some_and(|w| w.id != id)
            && let Some(w) = cur.take()
        {
            place(&w, &mut t)?;
        }
        let w = cur.get_or_insert(Window {
            id,
            first: started,
            ms: 0,
            plays: 0,
            events: 0,
            skips: 0,
            completed: 0,
        });
        w.first = w.first.min(started);
        w.ms += u64_col(r, 1)?;
        w.plays += u64_col(r, 2)?;
        w.events += 1;
        w.skips += u64_col(r, 3)?;
        w.completed += u64_col(r, 4)?;
    }
    if let Some(w) = cur.take() {
        place(&w, &mut t)?;
    }
    // Last 24 months, oldest first.
    let skip = months.len().saturating_sub(24);
    t.by_month = months
        .into_iter()
        .skip(skip)
        .map(|(label, (listened_ms, play_count))| BucketStat {
            label,
            listened_ms,
            play_count,
        })
        .collect();
    t.days = days.into_iter().collect();
    Ok(t)
}

/// Active days, longest streak and current streak from the ascending
/// distinct local days.
fn streaks_from_days(conn: &Connection, days: &[i64]) -> Result<(u64, u64, u64)> {
    if days.is_empty() {
        return Ok((0, 0, 0));
    }
    let today: i64 = conn.query_row(
        "SELECT CAST(strftime('%s', 'now', 'localtime') AS INTEGER) / 86400",
        [],
        |r| r.get(0),
    )?;
    let mut longest = 1u64;
    let mut run = 1u64;
    for pair in days.windows(2) {
        if pair[1] == pair[0] + 1 {
            run += 1;
            longest = longest.max(run);
        } else {
            run = 1;
        }
    }
    let last_day = *days.last().unwrap_or(&0);
    let current = if last_day == today || last_day == today - 1 {
        run
    } else {
        0
    };
    Ok((days.len() as u64, longest, current))
}

/// `WHERE` clause for the events of one profile in `[from, to)`. The bounds
/// are written into the SQL only when present (they are integers), so SQLite
/// can use the `(profile_id, started_at)` index range; `(?1 IS NULL OR ...)`
/// forms made it scan the whole profile.
fn listen_range(profile: ProfileId, from: Option<i64>, to: Option<i64>) -> String {
    let mut s = format!("e.profile_id = {}", profile.0);
    if let Some(f) = from {
        s.push_str(&format!(" AND e.started_at >= {f}"));
    }
    if let Some(t) = to {
        s.push_str(&format!(" AND e.started_at < {t}"));
    }
    s
}

/// Scratch tables of `listening_stats`, dropped when the call ends.
struct StatsScratch<'a>(&'a Connection);

impl StatsScratch<'_> {
    const DROP: &'static str = "DROP TABLE IF EXISTS temp.stats_tracks;
                                DROP TABLE IF EXISTS temp.stats_albums;
                                DROP TABLE IF EXISTS temp.stats_fine;";
}

impl Drop for StatsScratch<'_> {
    fn drop(&mut self) {
        let _ = self.0.execute_batch(Self::DROP);
    }
}

pub fn listening_stats(
    conn: &Connection,
    profile: ProfileId,
    from: Option<i64>,
    to: Option<i64>,
    limit: usize,
) -> Result<ListeningStats> {
    let range = listen_range(profile, from, to);
    let buckets = time_buckets(conn, &range)?;
    let (active_days, longest_streak_days, current_streak_days) =
        streaks_from_days(conn, &buckets.days)?;

    // One grouping pass per kind. Tracks are grouped once and serve the two
    // top-track lists, the unique-track count and (re-grouped by artist) the
    // artist list; albums are grouped once for the list and their count.
    let _scratch = StatsScratch(conn);
    conn.execute_batch(StatsScratch::DROP)?;
    conn.execute_batch(&format!(
        "CREATE TEMP TABLE stats_fine(
             track_id INTEGER, title TEXT COLLATE NOCASE, artist TEXT COLLATE NOCASE,
             album TEXT COLLATE NOCASE, genre TEXT COLLATE NOCASE,
             plays INTEGER, total_ms INTEGER, skips INTEGER
         );
         INSERT INTO stats_fine
         SELECT e.track_id, MAX(e.title), MAX(e.artist), MAX(e.album), MAX(e.genre),
                SUM({PLAY_EXPR}), SUM(e.listened_ms), SUM(e.skipped)
         FROM listen_events e
         WHERE {range}
         GROUP BY e.track_id, e.title, e.artist, e.album, e.genre;
         CREATE TEMP TABLE stats_tracks(
             track_id INTEGER, title TEXT COLLATE NOCASE, artist TEXT COLLATE NOCASE,
             album TEXT COLLATE NOCASE, plays INTEGER, total_ms INTEGER, skips INTEGER,
             min_title TEXT COLLATE NOCASE
         );
         INSERT INTO stats_tracks
         SELECT MAX(track_id), MAX(title), MAX(artist), MAX(album),
                SUM(plays), SUM(total_ms), SUM(skips), MIN(title)
         FROM stats_fine
         GROUP BY LOWER(title), LOWER(artist);
         CREATE TEMP TABLE stats_albums(
             album TEXT COLLATE NOCASE, artist TEXT COLLATE NOCASE, album_id INTEGER,
             cover TEXT, plays INTEGER, total_ms INTEGER
         );
         INSERT INTO stats_albums
         SELECT MAX(f.album), MAX(f.artist), MAX(t.album_id), MAX(a.cover),
                SUM(f.plays), SUM(f.total_ms)
         FROM stats_fine f
         LEFT JOIN tracks t ON t.id = f.track_id
         LEFT JOIN albums a ON a.id = t.album_id
         WHERE TRIM(f.album) != ''
         GROUP BY LOWER(f.album);"
    ))?;
    let (unique_tracks, unique_artists): (u64, u64) = conn.query_row(
        "SELECT COUNT(*), COUNT(DISTINCT CASE WHEN TRIM(artist) != '' THEN LOWER(artist) END)
         FROM temp.stats_tracks",
        [],
        |r| Ok((u64_col(r, 0)?, u64_col(r, 1)?)),
    )?;
    let unique_albums: u64 = conn.query_row("SELECT COUNT(*) FROM temp.stats_albums", [], |r| {
        u64_col(r, 0)
    })?;

    // Path and cover are not part of the grouping (they would force table
    // reads for every event); the few listed groups look them up.
    let mut detail_st = conn.prepare(&format!(
        "SELECT MAX(e.path), MAX(a.cover)
         FROM listen_events e
         LEFT JOIN tracks t ON t.id = e.track_id
         LEFT JOIN albums a ON a.id = t.album_id
         WHERE {range} AND e.artist = ?1 AND e.title = ?2"
    ))?;
    let mut top_tracks = |order_by_time: bool| -> Result<Vec<TopTrackStat>> {
        let (order, having) = if order_by_time {
            ("total_ms DESC, plays DESC, min_title COLLATE NOCASE", "")
        } else {
            (
                "plays DESC, total_ms DESC, min_title COLLATE NOCASE",
                "WHERE plays > 0",
            )
        };
        let mut st = conn.prepare(&format!(
            "SELECT track_id, title, artist, album, plays, total_ms, skips
             FROM temp.stats_tracks {having} ORDER BY {order} LIMIT ?1"
        ))?;
        let rows = st
            .query_map([limit as i64], |r| {
                Ok((
                    r.get::<_, Option<i64>>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    u64_col(r, 4)?,
                    u64_col(r, 5)?,
                    u64_col(r, 6)?,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut out = Vec::with_capacity(rows.len());
        for (track_id, title, artist, album, play_count, listened_ms, skip_count) in rows {
            let (path, cover): (String, Option<String>) = detail_st
                .query_row(rusqlite::params![&artist, &title], |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })?;
            out.push(TopTrackStat {
                track_id,
                path,
                title,
                artist,
                album,
                cover,
                play_count,
                listened_ms,
                skip_count,
            });
        }
        Ok(out)
    };
    let top_tracks_by_plays = top_tracks(false)?;
    let top_tracks_by_time = top_tracks(true)?;

    let mut cover_st = conn.prepare(&format!(
        "SELECT MAX(a.cover)
         FROM listen_events e
         LEFT JOIN tracks t ON t.id = e.track_id
         LEFT JOIN albums a ON a.id = t.album_id
         WHERE {range} AND e.artist = ?1"
    ))?;
    let mut artist_st = conn.prepare(
        "SELECT MAX(artist COLLATE NOCASE), SUM(plays) AS plays, SUM(total_ms) AS total_ms,
                COUNT(*), SUM(skips)
         FROM temp.stats_tracks
         WHERE TRIM(artist) != ''
         GROUP BY LOWER(artist)
         ORDER BY total_ms DESC, plays DESC, MAX(artist COLLATE NOCASE) COLLATE NOCASE
         LIMIT ?1",
    )?;
    let artist_rows = artist_st
        .query_map([limit as i64], |r| {
            Ok(TopArtistStat {
                artist: r.get(0)?,
                cover: None,
                play_count: u64_col(r, 1)?,
                listened_ms: u64_col(r, 2)?,
                unique_tracks: u64_col(r, 3)?,
                skip_count: u64_col(r, 4)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut top_artists_by_time = Vec::with_capacity(artist_rows.len());
    for mut a in artist_rows {
        a.cover = cover_st.query_row([&a.artist], |r| r.get(0))?;
        top_artists_by_time.push(a);
    }

    let mut album_st = conn.prepare(
        "SELECT album, artist, album_id, cover, plays, total_ms
         FROM temp.stats_albums
         ORDER BY total_ms DESC, plays DESC, album COLLATE NOCASE
         LIMIT ?1",
    )?;
    let top_albums_by_time = album_st
        .query_map([limit as i64], |r| {
            Ok(TopAlbumStat {
                album: r.get(0)?,
                artist: r.get(1)?,
                album_id: r.get(2)?,
                cover: r.get(3)?,
                play_count: u64_col(r, 4)?,
                listened_ms: u64_col(r, 5)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let genre_sql = "SELECT MAX(genre), SUM(plays) AS plays, SUM(total_ms) AS total_ms
         FROM temp.stats_fine
         WHERE TRIM(genre) != ''
         GROUP BY LOWER(genre)
         ORDER BY total_ms DESC, plays DESC, MAX(genre) COLLATE NOCASE
         LIMIT ?1";
    let mut genre_st = conn.prepare(genre_sql)?;
    let top_genres = genre_st
        .query_map([limit as i64], |r| {
            Ok(TopGenreStat {
                genre: r.get(0)?,
                play_count: u64_col(r, 1)?,
                listened_ms: u64_col(r, 2)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let by_hour = buckets.by_hour;
    let top_hour = by_hour
        .iter()
        .enumerate()
        .filter(|(_, b)| b.listened_ms > 0)
        .max_by_key(|(_, b)| b.listened_ms)
        .map(|(idx, _)| idx as u32);
    let by_weekday = buckets.by_weekday;
    let top_weekday = by_weekday
        .iter()
        .enumerate()
        .filter(|(_, b)| b.listened_ms > 0)
        .max_by_key(|(_, b)| b.listened_ms)
        .map(|(idx, _)| idx as u32);
    let by_month = buckets.by_month;

    let recent_sql = format!(
        "SELECT e.id, e.track_id, e.path, e.title, e.artist, e.album, a.cover,
                e.started_at, e.listened_ms, e.completed, e.skipped, e.source
         FROM listen_events e
         LEFT JOIN tracks t ON t.id = e.track_id
         LEFT JOIN albums a ON a.id = t.album_id
         WHERE {range}
         ORDER BY e.started_at DESC, e.id DESC
         LIMIT 50"
    );
    let mut recent_st = conn.prepare(&recent_sql)?;
    let recent = recent_st
        .query_map([], |r| {
            Ok(RecentListen {
                id: r.get(0)?,
                track_id: r.get(1)?,
                path: r.get(2)?,
                title: r.get(3)?,
                artist: r.get(4)?,
                album: r.get(5)?,
                cover: r.get(6)?,
                started_at: r.get(7)?,
                listened_ms: u64_col(r, 8)?,
                completed: r.get::<_, i64>(9)? != 0,
                skipped: r.get::<_, i64>(10)? != 0,
                source: r.get(11)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let available_years = available_listen_years(conn, profile)?;

    Ok(ListeningStats {
        summary: StatsSummary {
            total_listened_ms: buckets.total_listened_ms,
            play_count: buckets.play_count,
            raw_event_count: buckets.raw_event_count,
            skip_count: buckets.skip_count,
            completed_count: buckets.completed_count,
            unique_tracks,
            unique_artists,
            unique_albums,
            active_days,
            longest_streak_days,
            current_streak_days,
            top_hour,
            top_weekday,
            first_listen_at: buckets.first_listen_at,
        },
        top_tracks_by_plays,
        top_tracks_by_time,
        top_artists_by_time,
        top_albums_by_time,
        top_genres,
        by_hour,
        by_weekday,
        by_month,
        recent,
        available_years,
    })
}

/// Local calendar years with at least one listen, newest first. Hops from
/// year to year with an index seek each instead of scanning every event.
fn available_listen_years(conn: &Connection, profile: ProfileId) -> Result<Vec<i32>> {
    let mut st = conn.prepare(
        "SELECT CAST(strftime('%Y', m, 'unixepoch', 'localtime') AS INTEGER)
         FROM (SELECT MIN(started_at) AS m FROM listen_events
               WHERE profile_id = ?1 AND started_at >= ?2)
         WHERE m IS NOT NULL",
    )?;
    let mut next_start = conn.prepare(
        "SELECT CAST(strftime('%s', printf('%04d-01-01 00:00:00', ?1 + 1), 'utc') AS INTEGER)",
    )?;
    let mut years = Vec::new();
    let mut bound = i64::MIN;
    while let Some(y) = st
        .query_row(rusqlite::params![profile.0, bound], |r| {
            r.get::<_, Option<i32>>(0)
        })
        .optional()?
        .flatten()
    {
        years.push(y);
        let nb: i64 = next_start.query_row([y], |r| r.get(0))?;
        if nb <= bound {
            break;
        }
        bound = nb;
    }
    years.reverse();
    Ok(years)
}

#[cfg(test)]
#[path = "db_stats_reference.rs"]
mod stats_reference;

#[cfg(test)]
#[path = "db_perf_tests.rs"]
mod perf_tests;

// ---------------------------------------------------------------------
// Artists & profiles
// ---------------------------------------------------------------------

/// Feature markers, matched ASCII-case-insensitively. Longer variants come
/// first so `" feat. "` wins over `" feat "`.
const FEATURE_TOKENS: &[&str] = &[
    "(featuring ",
    "[featuring ",
    "(feat.",
    "[feat.",
    "(ft.",
    "[ft.",
    " featuring ",
    " feat. ",
    " feat ",
    " ft. ",
    " ft ",
];

/// Splits compound artist strings (`"A feat. B"`, `"A, B"`, `"A; B"`) into
/// distinct artists. Group names stay whole: `&` and `+` never split, a part
/// starting with "The" belongs to the name before it (`"Tyler, The
/// Creator"`), and a list of three or more single words joined by a final
/// `&`/`and` is a band (`"Earth, Wind & Fire"`).
///
/// The UI mirrors these rules in `src/lib/artistNames.ts`; both are checked
/// against `fixtures/artist-split-cases.json`.
pub fn split_artists(raw: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for segment in feature_segments(raw.trim()) {
        for piece in segment.split(';') {
            for name in split_name_list(piece) {
                if seen.insert(name.to_lowercase()) {
                    out.push(name);
                }
            }
        }
    }
    out
}

/// Cuts `raw` at feature markers. Matching runs on the original bytes: the
/// markers are ASCII, so cut points are always char boundaries (lowercasing
/// first would shift byte offsets for letters such as `İ`).
fn feature_segments(raw: &str) -> Vec<&str> {
    let bytes = raw.as_bytes();
    let mut segments = Vec::new();
    let (mut start, mut i) = (0, 0);
    while i < bytes.len() {
        let hit = FEATURE_TOKENS.iter().find(|tok| {
            bytes
                .get(i..i + tok.len())
                .is_some_and(|b| b.eq_ignore_ascii_case(tok.as_bytes()))
        });
        match hit {
            Some(tok) => {
                segments.push(&raw[start..i]);
                i += tok.len();
                start = i;
            }
            None => i += 1,
        }
    }
    segments.push(&raw[start..]);
    segments
}

/// Drops a closing bracket left over from `"(feat. X)"`.
fn strip_unmatched_close(part: &str) -> &str {
    let mut p = part.trim();
    if let Some(s) = p.strip_suffix(')').filter(|s| !s.contains('(')) {
        p = s.trim();
    }
    if let Some(s) = p.strip_suffix(']').filter(|s| !s.contains('[')) {
        p = s.trim();
    }
    p
}

fn starts_with_ignore_ascii_case(s: &str, prefix: &str) -> bool {
    s.as_bytes()
        .get(..prefix.len())
        .is_some_and(|b| b.eq_ignore_ascii_case(prefix.as_bytes()))
}

/// Bands whose name is itself a comma list, compared after
/// [`normalize_group`]. Any other `"A, B & C"` is three artists.
const COMMA_GROUPS: &[&str] = &[
    "earth, wind & fire",
    "crosby, stills, nash & young",
    "crosby, stills & nash",
    "peter, paul & mary",
    "emerson, lake & palmer",
    "blood, sweat & tears",
    "dave dee, dozy, beaky, mick & tich",
];

/// Words after `&` that make it part of one band name (`"Mumford & Sons"`,
/// `"Bob Marley & The Wailers"`), not a list.
const GROUP_TAILS: &[&str] = &[
    "sons",
    "daughters",
    "friends",
    "co",
    "co.",
    "company",
    "brothers",
    "sisters",
];
const GROUP_TAIL_PREFIXES: &[&str] = &["the ", "his ", "her ", "their "];

/// Lowercase, `and` written as `&`, single spaces.
fn normalize_group(s: &str) -> String {
    s.to_lowercase()
        .split_whitespace()
        .map(|w| if w == "and" { "&" } else { w })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Whether `"X & tail"` reads as one band (`tail` is the part after `&`).
fn is_group_tail(tail: &str) -> bool {
    let t = tail.trim().to_lowercase();
    GROUP_TAILS.contains(&t.as_str()) || GROUP_TAIL_PREFIXES.iter().any(|p| t.starts_with(p))
}

/// Splits one comma-separated name list, keeping group names whole. In a
/// list, the last `&` joins two more names (`"A, B & C"`), unless it is part
/// of a band name.
fn split_name_list(list: &str) -> Vec<String> {
    let whole = strip_unmatched_close(list);
    if COMMA_GROUPS.contains(&normalize_group(whole).as_str()) {
        return vec![whole.to_owned()];
    }
    let mut parts: Vec<String> = Vec::new();
    for part in list
        .split(',')
        .map(strip_unmatched_close)
        .filter(|p| !p.is_empty())
    {
        match parts.last_mut() {
            Some(prev) if starts_with_ignore_ascii_case(part, "the ") => {
                prev.push_str(", ");
                prev.push_str(part);
            }
            _ => parts.push(part.to_owned()),
        }
    }
    if parts.len() > 1
        && let Some(last) = parts.pop()
    {
        match last.rsplit_once(" & ") {
            Some((a, b)) if !a.trim().is_empty() && !b.trim().is_empty() && !is_group_tail(b) => {
                parts.push(a.trim().to_owned());
                parts.push(b.trim().to_owned());
            }
            _ => parts.push(last),
        }
    }
    parts
}

pub fn sync_track_artists(conn: &Connection, track_id: i64, raw_artist: &str) -> Result<()> {
    conn.execute("DELETE FROM track_artists WHERE track_id = ?1", [track_id])?;
    let mut st = conn.prepare_cached(
        "INSERT OR IGNORE INTO track_artists(track_id, artist, position)
         VALUES (?1, ?2, ?3)",
    )?;
    for (idx, name) in split_artists(raw_artist).into_iter().enumerate() {
        st.execute(rusqlite::params![track_id, name, idx as i64])?;
    }
    Ok(())
}

fn backfill_track_artists(conn: &Connection) -> Result<()> {
    let mut st = conn.prepare("SELECT id, artist FROM tracks")?;
    let rows: Vec<(i64, String)> = st
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    for (id, artist) in rows {
        sync_track_artists(conn, id, &artist)?;
    }
    Ok(())
}

pub fn search_artists_page(
    conn: &Connection,
    profile: ProfileId,
    offset: u64,
    limit: u64,
    query: &str,
) -> Result<Page<ArtistRow>> {
    let f = build_filter(query, |i| format!("ta.artist LIKE ?{i} ESCAPE '\\'"));
    let n = f.params.len();
    let count_sql = format!(
        "SELECT COUNT(DISTINCT ta.artist) FROM track_artists ta {}",
        f.where_sql
    );
    let pr = profile.0;
    // Page the artist names first (index-only scan of `track_artists`), then
    // compute counts and plays for those names only.
    let page_sql = format!(
        "WITH page(name) AS MATERIALIZED (
             SELECT MIN(ta.artist) FROM track_artists ta {}
             GROUP BY ta.artist
             ORDER BY MIN(ta.artist) COLLATE NOCASE
             LIMIT ?{} OFFSET ?{}
         )
         SELECT MIN(ta.artist),
                COUNT(DISTINCT ta.track_id) AS tracks_n,
                COUNT(DISTINCT t.album_id) AS albums_n,
                COALESCE(MAX(am.image), MAX(a.cover)),
                COALESCE((
                    SELECT SUM({PLAY_EXPR}) FROM listen_events e
                    WHERE e.profile_id = {pr} AND e.artist = ta.artist COLLATE NOCASE
                ), 0),
                COALESCE((
                    SELECT SUM(e.listened_ms) FROM listen_events e
                    WHERE e.profile_id = {pr} AND e.artist = ta.artist COLLATE NOCASE
                ), 0)
         FROM track_artists ta
         JOIN tracks t ON t.id = ta.track_id
         LEFT JOIN albums a ON a.id = t.album_id
         LEFT JOIN artists_meta am ON am.name_key = ta.artist
         WHERE ta.artist IN (SELECT name FROM page)
         GROUP BY ta.artist
         ORDER BY MIN(ta.artist) COLLATE NOCASE",
        f.where_sql,
        n + 1,
        n + 2
    );
    query_page(conn, &count_sql, &page_sql, f.params, offset, limit, |r| {
        Ok(ArtistRow {
            name: r.get(0)?,
            track_count: r.get::<_, i64>(1)?.max(0) as u32,
            album_count: r.get::<_, i64>(2)?.max(0) as u32,
            cover: r.get(3)?,
            play_count: u64_col(r, 4)?,
            listened_ms: u64_col(r, 5)?,
        })
    })
}

/// Distinct artist names in the library, sorted case-insensitively.
pub fn all_artist_names(conn: &Connection) -> Result<Vec<String>> {
    let mut st = conn.prepare(
        "SELECT MIN(ta.artist)
         FROM track_artists ta
         GROUP BY ta.artist
         ORDER BY MIN(ta.artist) COLLATE NOCASE",
    )?;
    let rows = st.query_map([], |r| r.get(0))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub fn artist_meta(conn: &Connection, name: &str) -> Result<Option<ArtistMeta>> {
    conn.query_row(
        "SELECT display, image, bio, fetched_at
         FROM artists_meta
         WHERE name_key = ?1 COLLATE NOCASE",
        [name],
        |r| {
            Ok(ArtistMeta {
                name: r.get(0)?,
                image: r.get(1)?,
                bio: r.get(2)?,
                fetched_at: r.get(3)?,
            })
        },
    )
    .optional()
    .map_err(Into::into)
}

pub fn save_artist_meta(
    conn: &Connection,
    name: &str,
    image: Option<&str>,
    bio: Option<&str>,
    fetched_at: i64,
) -> Result<ArtistMeta> {
    conn.execute(
        "INSERT INTO artists_meta(name_key, display, image, bio, fetched_at)
         VALUES (?1, ?1, ?2, ?3, ?4)
         ON CONFLICT(name_key) DO UPDATE SET
            display = excluded.display,
            image = COALESCE(excluded.image, image),
            bio = COALESCE(excluded.bio, bio),
            fetched_at = excluded.fetched_at",
        rusqlite::params![name, image, bio, fetched_at],
    )?;
    artist_meta(conn, name)?.ok_or_else(|| super::LibraryError::Other("meta save failed".into()))
}

pub fn artist_queue_tracks(conn: &Connection, name: &str) -> Result<Vec<Track>> {
    let mut st = conn.prepare(
        "SELECT t.path, t.title, t.artist
         FROM track_artists ta
         JOIN tracks t ON t.id = ta.track_id
         LEFT JOIN albums a ON a.id = t.album_id
         WHERE ta.artist = ?1 COLLATE NOCASE
         ORDER BY COALESCE(a.year, 0) DESC, a.title COLLATE NOCASE,
                  t.disc_no, t.track_no, t.title COLLATE NOCASE, t.id",
    )?;
    let rows = st.query_map([name], queue_track)?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub fn artist_profile(conn: &Connection, profile: ProfileId, name: &str) -> Result<ArtistProfile> {
    let ts = track_select(profile);
    let pr = profile.0;
    let mut tr_st = conn.prepare(&format!(
        "{ts}
         JOIN track_artists ta ON ta.track_id = t.id
         WHERE ta.artist = ?1 COLLATE NOCASE
         ORDER BY COALESCE(a.year, 0) DESC, a.title COLLATE NOCASE,
                  t.disc_no, t.track_no, t.title COLLATE NOCASE, t.id"
    ))?;
    let tracks = tr_st
        .query_map([name], track_row)?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let mut al_st = conn.prepare(&format!(
        "{ALBUM_SELECT}
         WHERE a.album_artist = ?1 COLLATE NOCASE
            OR EXISTS (
                SELECT 1 FROM tracks t
                JOIN track_artists ta ON ta.track_id = t.id
                WHERE t.album_id = a.id AND ta.artist = ?1 COLLATE NOCASE
            )
         ORDER BY COALESCE(a.year, 0) DESC, a.title COLLATE NOCASE, a.id"
    ))?;
    let albums = al_st
        .query_map([name], album_row)?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let mut pop_st = conn.prepare(&format!(
        "SELECT t.id, t.title, t.artist, COALESCE(a.title, ''), t.album_id,
                t.track_no, t.disc_no, t.year, t.duration_ms, t.path, a.cover,
                COALESCE(SUM({PLAY_EXPR}), 0) AS plays,
                COALESCE(SUM(e.listened_ms), 0) AS total_ms
         FROM track_artists ta
         JOIN tracks t ON t.id = ta.track_id
         LEFT JOIN albums a ON a.id = t.album_id
         LEFT JOIN listen_events e ON e.track_id = t.id AND e.profile_id = {pr}
         WHERE ta.artist = ?1 COLLATE NOCASE
         GROUP BY t.id
         ORDER BY plays DESC, total_ms DESC, t.disc_no, t.track_no, t.title COLLATE NOCASE
         LIMIT 10"
    ))?;
    let popular_tracks = pop_st
        .query_map([name], |r| {
            let track = track_row(r)?;
            let play_count = u64_col(r, 11)?;
            let listened_ms = u64_col(r, 12)?;
            Ok(ArtistTopTrack {
                track,
                play_count,
                listened_ms,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let (play_count, listened_ms): (u64, u64) = conn.query_row(
        &format!(
            "SELECT COALESCE(SUM({PLAY_EXPR}), 0), COALESCE(SUM(e.listened_ms), 0)
             FROM listen_events e
             WHERE e.profile_id = {pr}
               AND (e.artist = ?1 COLLATE NOCASE
                OR e.track_id IN (
                    SELECT ta.track_id FROM track_artists ta
                    WHERE ta.artist = ?1 COLLATE NOCASE
                ))"
        ),
        [name],
        |r| Ok((u64_col(r, 0)?, u64_col(r, 1)?)),
    )?;

    let mut gen_st = conn.prepare(
        "SELECT TRIM(t.genre) AS g, COUNT(*) AS n
         FROM track_artists ta
         JOIN tracks t ON t.id = ta.track_id
         WHERE ta.artist = ?1 COLLATE NOCASE AND TRIM(COALESCE(t.genre, '')) != ''
         GROUP BY LOWER(TRIM(t.genre))
         ORDER BY n DESC, g COLLATE NOCASE
         LIMIT 5",
    )?;
    let genres = gen_st
        .query_map([name], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let meta = artist_meta(conn, name)?;
    let canonical = tracks
        .first()
        .and_then(|t| {
            split_artists(&t.artist)
                .into_iter()
                .find(|a| a.eq_ignore_ascii_case(name))
        })
        .or_else(|| meta.as_ref().map(|m| m.name.clone()))
        .unwrap_or_else(|| name.to_owned());

    let total_duration_ms: u64 = tracks.iter().filter_map(|t| t.duration_ms).sum();
    let fallback_cover = albums
        .iter()
        .find_map(|a| a.cover.clone())
        .or_else(|| tracks.iter().find_map(|t| t.cover.clone()));

    Ok(ArtistProfile {
        name: canonical,
        track_count: tracks.len() as u32,
        album_count: albums.len() as u32,
        total_duration_ms,
        genres,
        play_count,
        listened_ms,
        image: meta.as_ref().and_then(|m| m.image.clone()),
        bio: meta.as_ref().and_then(|m| m.bio.clone()),
        fetched_at: meta.as_ref().map(|m| m.fetched_at),
        fallback_cover,
        popular_tracks,
        albums,
        tracks,
    })
}

const GENRE_FILTER: &str = "LOWER(TRIM(COALESCE(t.genre, ''))) = LOWER(TRIM(?1))";
const GENRE_TRACK_ORDER: &str = "t.artist COLLATE NOCASE, COALESCE(a.title, '') COLLATE NOCASE, t.disc_no, t.track_no, t.title COLLATE NOCASE, t.id";

pub fn genres(conn: &Connection) -> Result<Vec<GenreRow>> {
    let mut st = conn.prepare(
        "SELECT MIN(TRIM(t.genre)) AS name,
                COUNT(*) AS track_count,
                MAX(CASE WHEN a.cover IS NOT NULL AND a.cover != '' THEN a.cover END) AS cover
         FROM tracks t
         LEFT JOIN albums a ON a.id = t.album_id
         WHERE TRIM(COALESCE(t.genre, '')) != ''
         GROUP BY LOWER(TRIM(t.genre))
         ORDER BY track_count DESC, name COLLATE NOCASE",
    )?;
    let rows = st.query_map([], |r| {
        Ok(GenreRow {
            name: r.get(0)?,
            track_count: r.get::<_, i64>(1)?.try_into().unwrap_or(u32::MAX),
            cover: r.get(2)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

pub fn genre_detail(conn: &Connection, name: &str) -> Result<GenreDetail> {
    let (track_count, duration_ms): (i64, i64) = conn.query_row(
        &format!(
            "SELECT COUNT(*), COALESCE(SUM(t.duration_ms), 0) FROM tracks t WHERE {GENRE_FILTER}"
        ),
        [name],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;

    let mut al_st = conn.prepare(&format!(
        "{ALBUM_SELECT}
         WHERE EXISTS (SELECT 1 FROM tracks t WHERE t.album_id = a.id AND {GENRE_FILTER})
         ORDER BY COALESCE(a.year, 0) DESC, a.title COLLATE NOCASE, a.id"
    ))?;
    let albums = al_st
        .query_map([name], album_row)?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let canonical = conn
        .query_row(
            &format!("SELECT TRIM(t.genre) FROM tracks t WHERE {GENRE_FILTER} LIMIT 1"),
            [name],
            |r| r.get::<_, String>(0),
        )
        .optional()?
        .unwrap_or_else(|| name.trim().to_owned());

    Ok(GenreDetail {
        name: canonical,
        albums,
        track_count: u32::try_from(track_count).unwrap_or(u32::MAX),
        duration_ms: u64::try_from(duration_ms).unwrap_or(0),
    })
}

/// One page of a genre's tracks, in queue order (see `genre_queue_tracks`).
pub fn genre_tracks_page(
    conn: &Connection,
    profile: ProfileId,
    name: &str,
    offset: u64,
    limit: u64,
) -> Result<Page<TrackRow>> {
    let ts = track_select(profile);
    query_page(
        conn,
        &format!("SELECT COUNT(*) FROM tracks t WHERE {GENRE_FILTER}"),
        &format!("{ts} WHERE {GENRE_FILTER} ORDER BY {GENRE_TRACK_ORDER} LIMIT ?2 OFFSET ?3"),
        vec![name.to_owned()],
        offset,
        limit,
        track_row,
    )
}

pub fn genre_queue_tracks(conn: &Connection, name: &str) -> Result<Vec<Track>> {
    let mut st = conn.prepare(&format!(
        "SELECT t.path, t.title, t.artist
         FROM tracks t
         LEFT JOIN albums a ON a.id = t.album_id
         WHERE {GENRE_FILTER}
         ORDER BY {GENRE_TRACK_ORDER}"
    ))?;
    let rows = st.query_map([name], queue_track)?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

// ---------------------------------------------------------------------
// Tag history (undo for automatic metadata matching)
// ---------------------------------------------------------------------

/// One saved "before" state of a track's tags.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TagHistoryRow {
    pub id: i64,
    pub batch_id: i64,
    pub track_id: Option<i64>,
    pub path: String,
    pub old_json: String,
}

/// A fresh batch id (one per apply call).
pub fn next_tag_batch_id(conn: &Connection) -> Result<i64> {
    let max: Option<i64> =
        conn.query_row("SELECT MAX(batch_id) FROM tag_history", [], |r| r.get(0))?;
    Ok(max.unwrap_or(0) + 1)
}

pub fn insert_tag_history(
    conn: &Connection,
    batch_id: i64,
    track_id: Option<i64>,
    path: &str,
    saved_at: i64,
    old_json: &str,
) -> Result<i64> {
    conn.execute(
        "INSERT INTO tag_history(batch_id, track_id, path, saved_at, old_json)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        rusqlite::params![batch_id, track_id, path, saved_at, old_json],
    )?;
    Ok(conn.last_insert_rowid())
}

pub fn delete_tag_history_row(conn: &Connection, id: i64) -> Result<()> {
    conn.execute("DELETE FROM tag_history WHERE id = ?1", [id])?;
    Ok(())
}

pub fn tag_history_batch(conn: &Connection, batch_id: i64) -> Result<Vec<TagHistoryRow>> {
    let mut st = conn.prepare(
        "SELECT id, batch_id, track_id, path, old_json FROM tag_history
         WHERE batch_id = ?1 ORDER BY id",
    )?;
    let rows = st.query_map([batch_id], |r| {
        Ok(TagHistoryRow {
            id: r.get(0)?,
            batch_id: r.get(1)?,
            track_id: r.get(2)?,
            path: r.get(3)?,
            old_json: r.get(4)?,
        })
    })?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

/// Id of the library track stored for `path`.
pub fn track_id_by_path(conn: &Connection, path: &str) -> Result<Option<i64>> {
    Ok(conn
        .query_row("SELECT id FROM tracks WHERE path = ?1", [path], |r| {
            r.get(0)
        })
        .optional()?)
}

/// Album row of the album a track currently belongs to.
pub fn track_album(conn: &Connection, track_id: i64) -> Result<Option<AlbumRow>> {
    Ok(conn
        .query_row(
            &format!("{ALBUM_SELECT} WHERE a.id = (SELECT album_id FROM tracks WHERE id = ?1)"),
            [track_id],
            album_row,
        )
        .optional()?)
}

/// One track by id, in the same shape as album listings.
pub fn track_by_id(
    conn: &Connection,
    profile: ProfileId,
    track_id: i64,
) -> Result<Option<TrackRow>> {
    Ok(conn
        .query_row(
            &format!("{} WHERE t.id = ?1", track_select(profile)),
            [track_id],
            track_row,
        )
        .optional()?)
}

/// One track by filesystem path, in the same shape as album listings.
pub fn track_row_by_path(
    conn: &Connection,
    profile: ProfileId,
    path: &str,
) -> Result<Option<TrackRow>> {
    Ok(conn
        .query_row(
            &format!("{} WHERE t.path = ?1", track_select(profile)),
            [path],
            track_row,
        )
        .optional()?)
}

pub fn is_custom_album_cover_path(path: &str) -> bool {
    let name = path.rsplit(['/', '\\']).next().unwrap_or(path);
    name.starts_with("custom_")
}

pub fn set_album_cover(conn: &Connection, album_id: i64, cover: &str) -> Result<Option<String>> {
    let old: Option<String> = conn
        .query_row("SELECT cover FROM albums WHERE id = ?1", [album_id], |r| {
            r.get(0)
        })
        .optional()?
        .flatten();
    let updated = conn.execute(
        "UPDATE albums SET cover = ?1 WHERE id = ?2",
        rusqlite::params![cover, album_id],
    )?;
    if updated == 0 {
        return Err(super::LibraryError::NotFound(format!("album {album_id}")));
    }
    Ok(old)
}

pub fn clear_album_cover(conn: &Connection, album_id: i64) -> Result<Option<String>> {
    let old: Option<String> = conn
        .query_row("SELECT cover FROM albums WHERE id = ?1", [album_id], |r| {
            r.get(0)
        })
        .optional()?
        .flatten();
    let updated = conn.execute("UPDATE albums SET cover = NULL WHERE id = ?1", [album_id])?;
    if updated == 0 {
        return Err(super::LibraryError::NotFound(format!("album {album_id}")));
    }
    Ok(old)
}

// ---------------------------------------------------------------------
// Home feed & local rule-based dynamic mixes
// ---------------------------------------------------------------------

const SECS_PER_DAY: i64 = 86_400;
const MIN_MIX_TRACKS: usize = 3;
const MIX_LIMIT: i64 = 25;

const MIX_WEEKLY_FAVORITES: &str = "weekly-favorites";
const MIX_ON_REPEAT: &str = "on-repeat";
const MIX_REDISCOVER: &str = "rediscover";
const MIX_FOCUS: &str = "focus-mix";

fn mix_album_covers(tracks: &[TrackRow]) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut covers = Vec::with_capacity(4);
    for t in tracks {
        if let Some(c) = t.cover.as_deref()
            && !c.is_empty()
            && seen.insert(c.to_string())
        {
            covers.push(c.to_string());
            if covers.len() == 4 {
                break;
            }
        }
    }
    covers
}

fn build_mix_meta(
    id: &str,
    kind: &str,
    title_key: &str,
    subject: Option<String>,
    subtitle_key: &str,
    tracks: &[TrackRow],
) -> DynamicMix {
    DynamicMix {
        id: id.to_string(),
        kind: kind.to_string(),
        title_key: title_key.to_string(),
        subject,
        subtitle_key: subtitle_key.to_string(),
        track_count: u32::try_from(tracks.len()).unwrap_or(u32::MAX),
        album_covers: mix_album_covers(tracks),
    }
}

fn daily_rank(track_id: i64, day_seed: i64) -> u64 {
    let mut x = (track_id as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15)
        ^ (day_seed as u64).wrapping_add(0xBF58_476D_1CE4_E5B9);
    x ^= x >> 30;
    x = x.wrapping_mul(0xBF58_476D_1CE4_E5B9);
    x ^= x >> 27;
    x = x.wrapping_mul(0x94D0_49BB_1331_11EB);
    x ^ (x >> 31)
}

fn has_listen_history(conn: &Connection, profile: ProfileId) -> Result<bool> {
    let pr = profile.0;
    let exists: bool = conn.query_row(
        &format!(
            "SELECT EXISTS(SELECT 1 FROM listen_events e WHERE e.profile_id = {pr} AND {PLAY_EXPR} = 1)"
        ),
        [],
        |r| r.get(0),
    )?;
    Ok(exists)
}

/// The most recent distinct keys (track or album ids) among this profile's
/// plays, newest first, ties by key descending. Walks the plays from the
/// newest and stops once `limit` keys are known and the next play is older
/// than the last of them, so it never touches the whole history.
/// `key_of` maps a resolved track id to the key (or `None` to skip it).
fn recent_play_keys(
    conn: &Connection,
    profile: ProfileId,
    limit: usize,
    key_of: &mut dyn FnMut(i64) -> Result<Option<i64>>,
) -> Result<Vec<(i64, i64)>> {
    let pr = profile.0;
    let mut st = conn.prepare(&format!(
        "SELECT e.track_id, e.started_at, CASE WHEN e.track_id IS NULL THEN e.path END
         FROM listen_events e
         WHERE e.profile_id = {pr} AND {PLAY_EXPR} = 1
         ORDER BY e.started_at DESC"
    ))?;
    let mut path_st = conn.prepare("SELECT id FROM tracks WHERE path = ?1")?;
    let mut rows = st.query([])?;
    let mut seen: HashMap<i64, i64> = HashMap::new();
    // `started_at` of the newest play of the `limit`-th key so far.
    let mut cutoff: Option<i64> = None;
    while let Some(r) = rows.next()? {
        let started: i64 = r.get(1)?;
        if let Some(c) = cutoff
            && started < c
        {
            break;
        }
        let tid = match r.get::<_, Option<i64>>(0)? {
            Some(id) => Some(id),
            None => {
                let path: Option<String> = r.get(2)?;
                match path {
                    Some(p) => path_st.query_row([p], |x| x.get(0)).optional()?,
                    None => None,
                }
            }
        };
        let Some(tid) = tid else { continue };
        let Some(key) = key_of(tid)? else { continue };
        // Rows come newest first, so the first sighting is the newest play.
        seen.entry(key).or_insert(started);
        if cutoff.is_none() && seen.len() >= limit {
            let mut times: Vec<i64> = seen.values().copied().collect();
            times.sort_unstable_by(|a, b| b.cmp(a));
            cutoff = times.get(limit - 1).copied();
        }
    }
    let mut out: Vec<(i64, i64)> = seen.into_iter().collect();
    out.sort_by(|a, b| b.1.cmp(&a.1).then(b.0.cmp(&a.0)));
    out.truncate(limit);
    Ok(out)
}

fn recently_played_tracks(
    conn: &Connection,
    profile: ProfileId,
    limit: i64,
) -> Result<Vec<RecentTrack>> {
    let keys = recent_play_keys(
        conn,
        profile,
        usize::try_from(limit).unwrap_or(0),
        &mut |tid| Ok(Some(tid)),
    )?;
    let mut st = conn.prepare(
        "SELECT t.id, t.title, t.artist, COALESCE(a.title, ''), t.album_id,
                t.track_no, t.disc_no, t.year, t.duration_ms, t.path, a.cover
         FROM tracks t LEFT JOIN albums a ON a.id = t.album_id
         WHERE t.id = ?1",
    )?;
    let mut out = Vec::with_capacity(keys.len());
    for (id, started_at) in keys {
        // A play whose track row is gone resolves to nothing, as the join did.
        if let Some(track) = st.query_row([id], track_row).optional()? {
            out.push(RecentTrack { track, started_at });
        }
    }
    Ok(out)
}

fn recently_played_albums(
    conn: &Connection,
    profile: ProfileId,
    limit: i64,
) -> Result<Vec<AlbumRow>> {
    let mut album_of = conn.prepare("SELECT album_id FROM tracks WHERE id = ?1")?;
    let keys = recent_play_keys(
        conn,
        profile,
        usize::try_from(limit).unwrap_or(0),
        &mut |tid| {
            Ok(album_of
                .query_row([tid], |r| r.get::<_, Option<i64>>(0))
                .optional()?
                .flatten())
        },
    )?;
    let mut st = conn.prepare(&format!("{ALBUM_SELECT} WHERE a.id = ?1"))?;
    let mut out = Vec::with_capacity(keys.len());
    for (id, _) in keys {
        if let Some(album) = st.query_row([id], album_row).optional()? {
            out.push(album);
        }
    }
    Ok(out)
}

fn recently_added_albums(conn: &Connection, limit: i64) -> Result<Vec<AlbumRow>> {
    let mut st = conn.prepare(&format!(
        "{ALBUM_SELECT}
         ORDER BY (SELECT COALESCE(MAX(t.added_at), 0) FROM tracks t WHERE t.album_id = a.id) DESC,
                  a.id DESC
         LIMIT ?1"
    ))?;
    let rows = st.query_map([limit], album_row)?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

/// The profile's events since `?{since}` with the track resolved: by id, or
/// by path when the id was lost. Written as two selects so the (many) events
/// with a track id are read from the covering index alone; only the few
/// without one touch the table.
fn resolved_events_cte(pr: i64, since: usize) -> String {
    format!(
        "ev(tid, started_at, completed, listened_ms, skipped) AS (
             SELECT e.track_id, e.started_at, e.completed, e.listened_ms, e.skipped
             FROM listen_events e
             WHERE e.profile_id = {pr} AND e.started_at >= ?{since} AND e.track_id IS NOT NULL
             UNION ALL
             SELECT tp.id, e.started_at, e.completed, e.listened_ms, e.skipped
             FROM listen_events e JOIN tracks tp ON tp.path = e.path
             WHERE e.profile_id = {pr} AND e.started_at >= ?{since} AND e.track_id IS NULL
         )"
    )
}

/// Plain track rows (no play count) for `ids`, in the order of `ids`.
fn plain_tracks_by_ids_in_order(conn: &Connection, ids: &[i64]) -> Result<Vec<TrackRow>> {
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    let list = ids.iter().map(i64::to_string).collect::<Vec<_>>().join(",");
    let mut st = conn.prepare(&format!(
        "SELECT t.id, t.title, t.artist, COALESCE(a.title, ''), t.album_id,
                t.track_no, t.disc_no, t.year, t.duration_ms, t.path, a.cover
         FROM tracks t LEFT JOIN albums a ON a.id = t.album_id
         WHERE t.id IN ({list})"
    ))?;
    let mut by_id: HashMap<i64, TrackRow> = st
        .query_map([], track_row)?
        .map(|r| r.map(|t| (t.id, t)))
        .collect::<rusqlite::Result<_>>()?;
    Ok(ids.iter().filter_map(|id| by_id.remove(id)).collect())
}

fn weekly_favorites_tracks(
    conn: &Connection,
    profile: ProfileId,
    now: i64,
) -> Result<Vec<TrackRow>> {
    let since = now.saturating_sub(7 * SECS_PER_DAY);
    let cte = resolved_events_cte(profile.0, 1);
    let sql = format!(
        "WITH {cte}
         SELECT ev.tid
         FROM ev JOIN tracks t ON t.id = ev.tid
         GROUP BY ev.tid
         HAVING SUM(
             ev.completed * 3.0
             + MIN(ev.listened_ms, 600000) / 30000.0
             - ev.skipped * 2.0
         ) > 0
           AND SUM(CASE WHEN ev.completed = 1 OR ev.listened_ms >= 15000 THEN 1 ELSE 0 END) >= 1
         ORDER BY SUM(
             ev.completed * 3.0
             + MIN(ev.listened_ms, 600000) / 30000.0
             - ev.skipped * 2.0
         ) DESC,
         MAX(ev.started_at) DESC,
         ev.tid ASC
         LIMIT ?2"
    );
    let mut st = conn.prepare(&sql)?;
    let ids = st
        .query_map(rusqlite::params![since, MIX_LIMIT], |r| r.get::<_, i64>(0))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    plain_tracks_by_ids_in_order(conn, &ids)
}

fn on_repeat_tracks(conn: &Connection, profile: ProfileId, now: i64) -> Result<Vec<TrackRow>> {
    let since = now.saturating_sub(30 * SECS_PER_DAY);
    let cte = resolved_events_cte(profile.0, 1);
    let play = "CASE WHEN ev.completed = 1 OR ev.listened_ms >= 15000 THEN 1 ELSE 0 END";
    let sql = format!(
        "WITH {cte}
         SELECT ev.tid
         FROM ev JOIN tracks t ON t.id = ev.tid
         GROUP BY ev.tid
         HAVING SUM({play}) >= 2
         ORDER BY SUM({play}) DESC, SUM(ev.listened_ms) DESC, MAX(ev.started_at) DESC, ev.tid ASC
         LIMIT ?2"
    );
    let mut st = conn.prepare(&sql)?;
    let ids = st
        .query_map(rusqlite::params![since, MIX_LIMIT], |r| r.get::<_, i64>(0))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    plain_tracks_by_ids_in_order(conn, &ids)
}

fn rediscover_tracks(conn: &Connection, profile: ProfileId, now: i64) -> Result<Vec<TrackRow>> {
    let recent_cutoff = now.saturating_sub(30 * SECS_PER_DAY);
    let pr = profile.0;
    // Set-based: candidates are favourites plus tracks with a real listen,
    // minus tracks played since the cutoff. Events match a track by id, or
    // by path when the id was lost.
    let sql = format!(
        "WITH liked(id) AS (
             SELECT f.track_id FROM favorites f WHERE f.profile_id = {pr}
             UNION
             SELECT e.track_id FROM listen_events e
             WHERE e.profile_id = {pr} AND e.track_id IS NOT NULL
               AND (e.completed = 1 OR e.listened_ms >= 30000)
             UNION
             SELECT tp.id FROM listen_events e JOIN tracks tp ON tp.path = e.path
             WHERE e.profile_id = {pr} AND e.track_id IS NULL
               AND (e.completed = 1 OR e.listened_ms >= 30000)
         ),
         recent(id) AS (
             SELECT e.track_id FROM listen_events e
             WHERE e.profile_id = {pr} AND e.started_at >= ?1
               AND e.track_id IS NOT NULL AND {PLAY_EXPR} = 1
             UNION
             SELECT tp.id FROM listen_events e JOIN tracks tp ON tp.path = e.path
             WHERE e.profile_id = {pr} AND e.started_at >= ?1
               AND e.track_id IS NULL AND {PLAY_EXPR} = 1
         )
         SELECT t.id FROM tracks t
         WHERE t.id IN (SELECT id FROM liked) AND t.id NOT IN (SELECT id FROM recent)"
    );
    let mut st = conn.prepare(&sql)?;
    let mut ids = st
        .query_map([recent_cutoff], |r| r.get::<_, i64>(0))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let day_seed = now.div_euclid(SECS_PER_DAY);
    ids.sort_by_key(|id| daily_rank(*id, day_seed));
    ids.truncate(MIX_LIMIT as usize);
    tracks_by_ids_in_order(conn, profile, &ids)
}

/// Full track rows (with plays) for `ids`, in the order of `ids`. Missing
/// ids are skipped. Used after the ids were chosen with cheap queries so the
/// per-row play counts are computed for the final handful only.
fn tracks_by_ids_in_order(
    conn: &Connection,
    profile: ProfileId,
    ids: &[i64],
) -> Result<Vec<TrackRow>> {
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    let ts = track_select(profile);
    let list = ids.iter().map(i64::to_string).collect::<Vec<_>>().join(",");
    let mut st = conn.prepare(&format!("{ts} WHERE t.id IN ({list})"))?;
    let mut by_id: HashMap<i64, TrackRow> = st
        .query_map([], track_row)?
        .map(|r| r.map(|t| (t.id, t)))
        .collect::<rusqlite::Result<_>>()?;
    Ok(ids.iter().filter_map(|id| by_id.remove(id)).collect())
}

/// Per-track focus score over the window `?2` (a CTE for the queries that
/// rank a mix's candidates). Events match a track by id, or by path when
/// the id was lost.
fn focus_scores_cte(pr: i64) -> String {
    let ev = resolved_events_cte(pr, 2);
    format!(
        "WITH {ev},
         focus_score(tid, score) AS (
             SELECT tid, SUM(completed * 2 + listened_ms / 30000.0 - skipped)
             FROM ev GROUP BY tid
         )"
    )
}

fn focus_mix_data(
    conn: &Connection,
    profile: ProfileId,
    now: i64,
) -> Result<Option<(String, Vec<TrackRow>)>> {
    let since = now.saturating_sub(14 * SECS_PER_DAY);
    let pr = profile.0;
    let top_artist: Option<String> = conn
        .query_row(
            &format!(
                "WITH {ev}
             SELECT ta.artist
             FROM ev
             JOIN track_artists ta ON ta.track_id = ev.tid
             WHERE ev.skipped = 0
               AND TRIM(ta.artist) != ''
             GROUP BY ta.artist COLLATE NOCASE
             HAVING (
                 SELECT COUNT(DISTINCT ta2.track_id)
                 FROM track_artists ta2
                 WHERE ta2.artist = ta.artist
             ) >= ?2
             ORDER BY SUM(ev.listened_ms) DESC, COUNT(*) DESC
             LIMIT 1",
                ev = resolved_events_cte(pr, 1)
            ),
            rusqlite::params![since, MIN_MIX_TRACKS as i64],
            |r| r.get(0),
        )
        .optional()?;

    if let Some(artist) = top_artist {
        let mut st = conn.prepare(&format!(
            "{FOCUS_SCORES_CTE}
             SELECT t.id FROM tracks t LEFT JOIN focus_score fs ON fs.tid = t.id
             WHERE EXISTS (
                 SELECT 1 FROM track_artists ta
                 WHERE ta.track_id = t.id AND ta.artist = ?1 COLLATE NOCASE
             )
             ORDER BY COALESCE(fs.score, 0) DESC, t.added_at DESC, t.id ASC
             LIMIT ?3",
            FOCUS_SCORES_CTE = focus_scores_cte(pr)
        ))?;
        let ids = st
            .query_map(rusqlite::params![&artist, since, MIX_LIMIT], |r| {
                r.get::<_, i64>(0)
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let tracks = tracks_by_ids_in_order(conn, profile, &ids)?;
        if tracks.len() >= MIN_MIX_TRACKS {
            return Ok(Some((artist, tracks)));
        }
    }

    let top_genre: Option<String> = conn
        .query_row(
            &format!(
                "WITH genre_counts AS (
                 SELECT TRIM(genre) AS g, COUNT(*) AS n
                 FROM tracks
                 WHERE genre IS NOT NULL AND TRIM(genre) != ''
                 GROUP BY TRIM(genre) COLLATE NOCASE
             )
             SELECT TRIM(t.genre)
             FROM listen_events e
             LEFT JOIN tracks tp ON e.track_id IS NULL AND tp.path = e.path
             JOIN tracks t ON t.id = COALESCE(e.track_id, tp.id)
             JOIN genre_counts gc ON gc.g = TRIM(t.genre) COLLATE NOCASE AND gc.n >= ?2
             WHERE e.profile_id = {pr}
               AND e.started_at >= ?1
               AND e.skipped = 0
               AND t.genre IS NOT NULL AND TRIM(t.genre) != ''
             GROUP BY TRIM(t.genre) COLLATE NOCASE
             ORDER BY SUM(e.listened_ms) DESC, COUNT(*) DESC
             LIMIT 1"
            ),
            rusqlite::params![since, MIN_MIX_TRACKS as i64],
            |r| r.get(0),
        )
        .optional()?;

    if let Some(genre) = top_genre {
        let mut st = conn.prepare(&format!(
            "{FOCUS_SCORES_CTE}
             SELECT t.id FROM tracks t LEFT JOIN focus_score fs ON fs.tid = t.id
             WHERE TRIM(COALESCE(t.genre, '')) = ?1 COLLATE NOCASE
             ORDER BY COALESCE(fs.score, 0) DESC, t.added_at DESC, t.id ASC
             LIMIT ?3",
            FOCUS_SCORES_CTE = focus_scores_cte(pr)
        ))?;
        let ids = st
            .query_map(rusqlite::params![&genre, since, MIX_LIMIT], |r| {
                r.get::<_, i64>(0)
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let tracks = tracks_by_ids_in_order(conn, profile, &ids)?;
        if tracks.len() >= MIN_MIX_TRACKS {
            return Ok(Some((genre, tracks)));
        }
    }

    Ok(None)
}

fn mix_detail_for_id(
    conn: &Connection,
    profile: ProfileId,
    mix_id: &str,
    now: i64,
) -> Result<Option<HomeMixDetail>> {
    match mix_id {
        MIX_WEEKLY_FAVORITES => {
            let tracks = weekly_favorites_tracks(conn, profile, now)?;
            if tracks.len() < MIN_MIX_TRACKS {
                return Ok(None);
            }
            let mix = build_mix_meta(
                MIX_WEEKLY_FAVORITES,
                MIX_WEEKLY_FAVORITES,
                "Weekly Favorites",
                None,
                "Most played and finished over the last 7 days",
                &tracks,
            );
            Ok(Some(HomeMixDetail { mix, tracks }))
        }
        MIX_ON_REPEAT => {
            let tracks = on_repeat_tracks(conn, profile, now)?;
            if tracks.len() < MIN_MIX_TRACKS {
                return Ok(None);
            }
            let mix = build_mix_meta(
                MIX_ON_REPEAT,
                MIX_ON_REPEAT,
                "On Repeat",
                None,
                "Songs you kept coming back to this month",
                &tracks,
            );
            Ok(Some(HomeMixDetail { mix, tracks }))
        }
        MIX_REDISCOVER => {
            let tracks = rediscover_tracks(conn, profile, now)?;
            if tracks.len() < MIN_MIX_TRACKS {
                return Ok(None);
            }
            let mix = build_mix_meta(
                MIX_REDISCOVER,
                MIX_REDISCOVER,
                "Rediscover",
                None,
                "Favorites and past listens you haven't played lately",
                &tracks,
            );
            Ok(Some(HomeMixDetail { mix, tracks }))
        }
        MIX_FOCUS => {
            let Some((subject, tracks)) = focus_mix_data(conn, profile, now)? else {
                return Ok(None);
            };
            let mix = build_mix_meta(
                MIX_FOCUS,
                MIX_FOCUS,
                "{name} Mix",
                Some(subject),
                "Inspired by what you played most lately",
                &tracks,
            );
            Ok(Some(HomeMixDetail { mix, tracks }))
        }
        _ => Ok(None),
    }
}

pub fn home_mix_detail(
    conn: &Connection,
    profile: ProfileId,
    mix_id: &str,
    now: i64,
) -> Result<Option<HomeMixDetail>> {
    mix_detail_for_id(conn, profile, mix_id, now)
}

pub fn home_mix_queue_tracks(
    conn: &Connection,
    profile: ProfileId,
    mix_id: &str,
    now: i64,
) -> Result<Vec<Track>> {
    let Some(detail) = mix_detail_for_id(conn, profile, mix_id, now)? else {
        return Ok(Vec::new());
    };
    Ok(detail
        .tracks
        .into_iter()
        .map(|t| Track {
            path: PathBuf::from(t.path),
            title: Some(t.title),
            artist: Some(t.artist),
        })
        .collect())
}

/// Where playback of a freshly recomputed mix should start. `start_path`
/// is matched against the recomputed tracks (the mix may have changed since
/// the UI rendered it); `None` starts at the first track. Errors leave the
/// caller's queue untouched.
pub fn resolve_mix_start(
    tracks: &[Track],
    start_path: Option<&str>,
) -> std::result::Result<usize, String> {
    if tracks.is_empty() {
        return Err("This mix is empty or no longer available".to_owned());
    }
    match start_path {
        None => Ok(0),
        Some(wanted) => tracks
            .iter()
            .position(|t| t.path.as_path() == Path::new(wanted))
            .ok_or_else(|| "That track is no longer in this mix".to_owned()),
    }
}

pub fn save_mix_as_playlist(
    conn: &mut Connection,
    profile: ProfileId,
    mix_id: &str,
    name: &str,
    now: i64,
) -> Result<PlaylistInfo> {
    let detail = mix_detail_for_id(conn, profile, mix_id, now)?
        .ok_or_else(|| super::LibraryError::Other(format!("mix '{mix_id}' is unavailable")))?;
    let ids: Vec<i64> = detail.tracks.iter().map(|t| t.id).collect();
    create_playlist(conn, profile, name, &ids, now)
}

pub fn home_feed(conn: &Connection, profile: ProfileId, now: i64) -> Result<HomeFeed> {
    let has_history = has_listen_history(conn, profile)?;
    let recently_played_albums = if has_history {
        recently_played_albums(conn, profile, 12)?
    } else {
        Vec::new()
    };
    let recently_played_tracks = if has_history {
        recently_played_tracks(conn, profile, 8)?
    } else {
        Vec::new()
    };
    let recently_added_albums = recently_added_albums(conn, 12)?;
    let favs = favorites_page(conn, profile, 0, 8)?;

    let mut mixes = Vec::new();
    for id in [
        MIX_WEEKLY_FAVORITES,
        MIX_ON_REPEAT,
        MIX_REDISCOVER,
        MIX_FOCUS,
    ] {
        if let Some(detail) = mix_detail_for_id(conn, profile, id, now)? {
            mixes.push(detail.mix);
        }
    }

    Ok(HomeFeed {
        recently_played_albums,
        recently_played_tracks,
        recently_added_albums,
        favorite_tracks: favs.items,
        favorite_count: favs.total,
        mixes,
        has_history,
    })
}

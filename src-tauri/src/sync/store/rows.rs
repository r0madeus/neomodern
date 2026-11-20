//! Reading and writing the `sync_*` tables. Every write sets `seq`.

use super::{EntryRecord, FavoriteRecord, ListenRecord, PlaylistRecord, Result};
use crate::library::ProfileId;
use rusqlite::{Connection, OptionalExtension, Row, params};
use std::collections::HashMap;

pub(super) const FAVORITE_COLS: &str = "key, title, artist, album, duration_ms, is_on, hlc";
pub(super) const PLAYLIST_COLS: &str =
    "uuid, name, name_hlc, cover_preset, cover_hlc, deleted, deleted_hlc, created_at";
pub(super) const ENTRY_COLS: &str = "uuid, playlist_uuid, key, title, artist, album, duration_ms,
     added_at, pos, pos_hlc, deleted, deleted_hlc";
pub(super) const LISTEN_COLS: &str = "uid, key, title, artist, album, genre, duration_ms, path,
     started_at, ended_at, listened_ms, completed, skipped";

pub(super) fn favorite(r: &Row<'_>) -> rusqlite::Result<FavoriteRecord> {
    Ok(FavoriteRecord {
        key: r.get(0)?,
        title: r.get(1)?,
        artist: r.get(2)?,
        album: r.get(3)?,
        duration_ms: r.get(4)?,
        on: r.get(5)?,
        hlc: r.get(6)?,
    })
}

pub(super) fn playlist(r: &Row<'_>) -> rusqlite::Result<PlaylistRecord> {
    Ok(PlaylistRecord {
        uuid: r.get(0)?,
        name: r.get(1)?,
        name_hlc: r.get(2)?,
        cover_preset: r.get(3)?,
        cover_hlc: r.get(4)?,
        deleted: r.get(5)?,
        deleted_hlc: r.get(6)?,
        created_at: r.get(7)?,
    })
}

pub(super) fn entry(r: &Row<'_>) -> rusqlite::Result<EntryRecord> {
    Ok(EntryRecord {
        uuid: r.get(0)?,
        playlist_uuid: r.get(1)?,
        key: r.get(2)?,
        title: r.get(3)?,
        artist: r.get(4)?,
        album: r.get(5)?,
        duration_ms: r.get(6)?,
        added_at: r.get(7)?,
        pos: r.get(8)?,
        pos_hlc: r.get(9)?,
        deleted: r.get(10)?,
        deleted_hlc: r.get(11)?,
    })
}

pub(super) fn listen(r: &Row<'_>) -> rusqlite::Result<ListenRecord> {
    Ok(ListenRecord {
        uid: r.get(0)?,
        key: r.get(1)?,
        title: r.get(2)?,
        artist: r.get(3)?,
        album: r.get(4)?,
        genre: r.get(5)?,
        duration_ms: r.get(6)?,
        path: r.get(7)?,
        started_at: r.get(8)?,
        ended_at: r.get(9)?,
        listened_ms: r.get(10)?,
        completed: r.get(11)?,
        skipped: r.get(12)?,
    })
}

// --- favourites ---------------------------------------------------------

pub(super) fn all_favorites(conn: &Connection, p: ProfileId) -> Result<Vec<FavoriteRecord>> {
    let mut st = conn.prepare(&format!(
        "SELECT {FAVORITE_COLS} FROM sync_favorites WHERE profile_id = ?1 ORDER BY key"
    ))?;
    let rows = st.query_map([p.0], favorite)?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub(super) fn get_favorite(
    conn: &Connection,
    p: ProfileId,
    key: &str,
) -> Result<Option<FavoriteRecord>> {
    let mut st = conn.prepare_cached(&format!(
        "SELECT {FAVORITE_COLS} FROM sync_favorites WHERE profile_id = ?1 AND key = ?2"
    ))?;
    Ok(st.query_row(params![p.0, key], favorite).optional()?)
}

pub(super) fn put_favorite(
    conn: &Connection,
    p: ProfileId,
    f: &FavoriteRecord,
    seq: i64,
) -> Result<()> {
    let mut st = conn.prepare_cached(
        "INSERT INTO sync_favorites(key, title, artist, album, duration_ms, is_on, hlc, seq,
                                    profile_id)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
         ON CONFLICT(profile_id, key) DO UPDATE SET
            title = excluded.title, artist = excluded.artist, album = excluded.album,
            duration_ms = excluded.duration_ms, is_on = excluded.is_on,
            hlc = excluded.hlc, seq = excluded.seq",
    )?;
    st.execute(params![
        f.key,
        f.title,
        f.artist,
        f.album,
        f.duration_ms,
        f.on,
        f.hlc,
        seq,
        p.0
    ])?;
    Ok(())
}

// --- playlists ------------------------------------------------------------

/// A playlist row plus the local-only `reconciled` flag (false while a
/// playlist received from a peer waits for first-sync reconciliation).
#[derive(Debug, Clone)]
pub(super) struct PlaylistRow {
    pub rec: PlaylistRecord,
    pub reconciled: bool,
}

pub(super) fn all_playlists(conn: &Connection, p: ProfileId) -> Result<Vec<PlaylistRow>> {
    let mut st = conn.prepare(&format!(
        "SELECT {PLAYLIST_COLS}, reconciled FROM sync_playlists WHERE profile_id = ?1
         ORDER BY uuid"
    ))?;
    let rows = st.query_map([p.0], |r| {
        Ok(PlaylistRow {
            rec: playlist(r)?,
            reconciled: r.get(8)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub(super) fn get_playlist(
    conn: &Connection,
    p: ProfileId,
    uuid: &str,
) -> Result<Option<PlaylistRow>> {
    let mut st = conn.prepare_cached(&format!(
        "SELECT {PLAYLIST_COLS}, reconciled FROM sync_playlists
         WHERE profile_id = ?1 AND uuid = ?2"
    ))?;
    Ok(st
        .query_row(params![p.0, uuid], |r| {
            Ok(PlaylistRow {
                rec: playlist(r)?,
                reconciled: r.get(8)?,
            })
        })
        .optional()?)
}

/// Inserts or updates a playlist of profile `profile`. A uuid that already
/// belongs to another profile is left alone (uuids are random, so this only
/// guards against a hostile or broken peer reusing one).
pub(super) fn put_playlist(
    conn: &Connection,
    profile: ProfileId,
    p: &PlaylistRecord,
    reconciled: bool,
    seq: i64,
) -> Result<()> {
    let mut st = conn.prepare_cached(
        "INSERT INTO sync_playlists(uuid, name, name_hlc, cover_preset, cover_hlc, deleted,
                                    deleted_hlc, created_at, reconciled, seq, profile_id)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
         ON CONFLICT(uuid) DO UPDATE SET
            name = excluded.name, name_hlc = excluded.name_hlc,
            cover_preset = excluded.cover_preset, cover_hlc = excluded.cover_hlc,
            deleted = excluded.deleted, deleted_hlc = excluded.deleted_hlc,
            created_at = excluded.created_at, reconciled = excluded.reconciled,
            seq = excluded.seq
         WHERE sync_playlists.profile_id = excluded.profile_id",
    )?;
    st.execute(params![
        p.uuid,
        p.name,
        p.name_hlc,
        p.cover_preset,
        p.cover_hlc,
        p.deleted,
        p.deleted_hlc,
        p.created_at,
        reconciled,
        seq,
        profile.0
    ])?;
    Ok(())
}

// --- playlist entries -----------------------------------------------------

/// Live (not deleted) entries of a playlist in display order.
pub(super) fn live_entries(conn: &Connection, playlist_uuid: &str) -> Result<Vec<EntryRecord>> {
    let mut st = conn.prepare_cached(&format!(
        "SELECT {ENTRY_COLS} FROM sync_playlist_entries
         WHERE playlist_uuid = ?1 AND deleted = 0 ORDER BY pos, uuid"
    ))?;
    let rows = st.query_map([playlist_uuid], entry)?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub(super) fn get_entry(
    conn: &Connection,
    p: ProfileId,
    uuid: &str,
) -> Result<Option<EntryRecord>> {
    let mut st = conn.prepare_cached(&format!(
        "SELECT {ENTRY_COLS} FROM sync_playlist_entries WHERE profile_id = ?1 AND uuid = ?2"
    ))?;
    Ok(st.query_row(params![p.0, uuid], entry).optional()?)
}

pub(super) fn put_entry(
    conn: &Connection,
    profile: ProfileId,
    e: &EntryRecord,
    seq: i64,
) -> Result<()> {
    let mut st = conn.prepare_cached(
        "INSERT INTO sync_playlist_entries(uuid, playlist_uuid, key, title, artist, album,
                duration_ms, added_at, pos, pos_hlc, deleted, deleted_hlc, seq, profile_id)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
         ON CONFLICT(uuid) DO UPDATE SET
            pos = excluded.pos, pos_hlc = excluded.pos_hlc,
            deleted = excluded.deleted, deleted_hlc = excluded.deleted_hlc,
            seq = excluded.seq
         WHERE sync_playlist_entries.profile_id = excluded.profile_id",
    )?;
    st.execute(params![
        e.uuid,
        e.playlist_uuid,
        e.key,
        e.title,
        e.artist,
        e.album,
        e.duration_ms,
        e.added_at,
        e.pos,
        e.pos_hlc,
        e.deleted,
        e.deleted_hlc,
        seq,
        profile.0
    ])?;
    Ok(())
}

// --- listens --------------------------------------------------------------

/// Inserts a history row unless it is already there; true when inserted.
pub(super) fn insert_listen(
    conn: &Connection,
    p: ProfileId,
    l: &ListenRecord,
    seq: i64,
) -> Result<bool> {
    let mut st = conn.prepare_cached(
        "INSERT OR IGNORE INTO sync_listens(uid, key, title, artist, album, genre, duration_ms,
                path, started_at, ended_at, listened_ms, completed, skipped, seq, profile_id)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
    )?;
    let n = st.execute(params![
        l.uid,
        l.key,
        l.title,
        l.artist,
        l.album,
        l.genre,
        l.duration_ms,
        l.path,
        l.started_at,
        l.ended_at,
        l.listened_ms,
        l.completed,
        l.skipped,
        seq,
        p.0
    ])?;
    Ok(n > 0)
}

/// Listen uids are global: a uid already stored for any profile counts.
pub(super) fn listen_exists(conn: &Connection, uid: &str) -> Result<bool> {
    let mut st = conn.prepare_cached("SELECT EXISTS(SELECT 1 FROM sync_listens WHERE uid = ?1)")?;
    Ok(st.query_row([uid], |r| r.get(0))?)
}

pub(super) fn get_listen(
    conn: &Connection,
    p: ProfileId,
    uid: &str,
) -> Result<Option<ListenRecord>> {
    let mut st = conn.prepare_cached(&format!(
        "SELECT {LISTEN_COLS} FROM sync_listens WHERE profile_id = ?1 AND uid = ?2"
    ))?;
    Ok(st.query_row(params![p.0, uid], listen).optional()?)
}

// --- local playlist id <-> uuid -------------------------------------------

/// The local playlist id <-> uuid pairs of profile `p` (the map itself is
/// shared; the sync playlist row says which profile a uuid belongs to).
pub(super) fn playlist_map(conn: &Connection, p: ProfileId) -> Result<HashMap<i64, String>> {
    let mut st = conn.prepare(
        "SELECT m.playlist_id, m.uuid FROM sync_playlist_map m
         JOIN sync_playlists s ON s.uuid = m.uuid WHERE s.profile_id = ?1",
    )?;
    let rows = st.query_map([p.0], |r| Ok((r.get(0)?, r.get(1)?)))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub(super) fn set_map(conn: &Connection, playlist_id: i64, uuid: &str) -> Result<()> {
    // A uuid maps to at most one local playlist.
    conn.execute("DELETE FROM sync_playlist_map WHERE uuid = ?1", [uuid])?;
    conn.execute(
        "INSERT OR REPLACE INTO sync_playlist_map(playlist_id, uuid) VALUES (?1, ?2)",
        params![playlist_id, uuid],
    )?;
    Ok(())
}

pub(super) fn delete_map(conn: &Connection, playlist_id: i64) -> Result<()> {
    conn.execute(
        "DELETE FROM sync_playlist_map WHERE playlist_id = ?1",
        [playlist_id],
    )?;
    Ok(())
}

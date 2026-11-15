//! The app's own tables, as capture and materialise see them.

use super::key::truncate_bytes;
use super::{MAX_NAME_CHARS, MAX_STR_BYTES, Result};
use rusqlite::{Connection, params};
use std::collections::HashMap;

const PRESET_PREFIX: &str = "preset:";
/// Same limit the app enforces when a preset is chosen.
const MAX_PRESET_BYTES: usize = 64;

#[derive(Debug, Clone)]
pub(super) struct LocalPlaylist {
    pub id: i64,
    pub name: String,
    pub cover: Option<String>,
    pub created_at: i64,
}

/// What a local cover means for sync: a preset (or none) is replicated; an
/// image file is local-only and must be neither captured nor overwritten.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum CoverView {
    Preset(Option<String>),
    Image,
}

pub(super) fn cover_view(cover: Option<&str>) -> CoverView {
    match cover {
        None => CoverView::Preset(None),
        Some(c) if c.starts_with(PRESET_PREFIX) && c.len() <= MAX_PRESET_BYTES => {
            CoverView::Preset(Some(c.to_owned()))
        }
        Some(_) => CoverView::Image,
    }
}

pub(super) fn is_valid_preset(p: &str) -> bool {
    p.starts_with(PRESET_PREFIX) && p.len() <= MAX_PRESET_BYTES
}

/// The replicated form of a local playlist name: trimmed, at most 200
/// characters, never empty. Comparing through this function keeps capture
/// from re-stamping names it cannot represent exactly.
pub(super) fn sync_name(local: &str) -> String {
    let trimmed = local.trim();
    if trimmed.is_empty() {
        return "Untitled".to_owned();
    }
    let short: String = trimmed.chars().take(MAX_NAME_CHARS).collect();
    truncate_bytes(&short, MAX_STR_BYTES).trim_end().to_owned()
}

/// A display string cut to the 1 KiB record limit.
pub(super) fn field(s: &str) -> String {
    truncate_bytes(s, MAX_STR_BYTES).to_owned()
}

pub(super) fn playlists(conn: &Connection) -> Result<Vec<LocalPlaylist>> {
    let mut st = conn.prepare("SELECT id, name, cover, created_at FROM playlists ORDER BY id")?;
    let rows = st.query_map([], |r| {
        Ok(LocalPlaylist {
            id: r.get(0)?,
            name: r.get(1)?,
            cover: r.get(2)?,
            created_at: r.get(3)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// `(track_id, added_at)` of a playlist in order.
pub(super) fn entries(conn: &Connection, playlist_id: i64) -> Result<Vec<(i64, Option<i64>)>> {
    let mut st = conn.prepare_cached(
        "SELECT track_id, added_at FROM playlist_tracks WHERE playlist_id = ?1 ORDER BY position",
    )?;
    let rows = st.query_map([playlist_id], |r| Ok((r.get(0)?, r.get(1)?)))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// Replaces a playlist's entries (positions 0..n), like the app's own
/// playlist edits do.
pub(super) fn rewrite_entries(
    conn: &Connection,
    playlist_id: i64,
    list: &[(i64, i64)],
) -> Result<()> {
    conn.execute(
        "DELETE FROM playlist_tracks WHERE playlist_id = ?1",
        [playlist_id],
    )?;
    let mut st = conn.prepare_cached(
        "INSERT INTO playlist_tracks(playlist_id, position, track_id, added_at)
         VALUES (?1, ?2, ?3, ?4)",
    )?;
    for (pos, (track_id, added_at)) in list.iter().enumerate() {
        st.execute(params![playlist_id, pos as i64, track_id, added_at])?;
    }
    Ok(())
}

/// track id -> added_at of every local favourite.
pub(super) fn favorites(conn: &Connection) -> Result<HashMap<i64, i64>> {
    let mut st = conn.prepare("SELECT track_id, added_at FROM favorites")?;
    let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

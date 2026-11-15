//! Outgoing changes: every replicated row with `seq` above a peer's
//! watermark, in `seq` order, a page at a time.

use super::ctx::{current_seq, device_id};
use super::rows::{self, ENTRY_COLS, FAVORITE_COLS, LISTEN_COLS, PLAYLIST_COLS};
use super::{
    Batch, EntryRecord, FavoriteRecord, ListenRecord, MAX_RECORDS, PlaylistRecord, Result,
};
use rusqlite::{Connection, Row};

/// The highest sequence number handed out on this device.
pub fn max_seq(conn: &Connection) -> Result<i64> {
    current_seq(conn)
}

enum Record {
    Favorite(FavoriteRecord),
    Playlist(PlaylistRecord),
    Entry(EntryRecord),
    Listen(ListenRecord),
}

/// Rows with `seq > after`, at most `limit` (capped at the batch limit).
/// `upto_seq` is the highest seq included; `more` says whether rows remain.
pub fn changes_since(conn: &Connection, after: i64, limit: usize) -> Result<Batch> {
    let limit = limit.clamp(1, MAX_RECORDS);
    let mut found: Vec<(i64, Record)> = Vec::new();
    found.extend(read(
        conn,
        "sync_favorites",
        FAVORITE_COLS,
        after,
        limit,
        |r| rows::favorite(r).map(Record::Favorite),
    )?);
    found.extend(read(
        conn,
        "sync_playlists",
        PLAYLIST_COLS,
        after,
        limit,
        |r| rows::playlist(r).map(Record::Playlist),
    )?);
    found.extend(read(
        conn,
        "sync_playlist_entries",
        ENTRY_COLS,
        after,
        limit,
        |r| rows::entry(r).map(Record::Entry),
    )?);
    found.extend(read(
        conn,
        "sync_listens",
        LISTEN_COLS,
        after,
        limit,
        |r| rows::listen(r).map(Record::Listen),
    )?);
    found.sort_by_key(|(seq, _)| *seq);
    let more = found.len() > limit;
    found.truncate(limit);

    let mut batch = Batch {
        from_device: device_id(conn)?,
        upto_seq: found.last().map_or(after.max(0), |(seq, _)| *seq),
        more,
        ..Batch::default()
    };
    // Nothing left: jump the watermark to the current sequence so gaps
    // (numbers handed out to rows later changed again) are not re-asked.
    if !more {
        batch.upto_seq = batch.upto_seq.max(current_seq(conn)?);
    }
    for (_, rec) in found {
        match rec {
            Record::Favorite(f) => batch.favorites.push(f),
            Record::Playlist(p) => batch.playlists.push(p),
            Record::Entry(e) => batch.entries.push(e),
            Record::Listen(l) => batch.listens.push(l),
        }
    }
    Ok(batch)
}

/// Up to `limit + 1` rows of one table (one extra to detect `more`).
fn read(
    conn: &Connection,
    table: &str,
    cols: &str,
    after: i64,
    limit: usize,
    map: impl Fn(&Row<'_>) -> rusqlite::Result<Record>,
) -> Result<Vec<(i64, Record)>> {
    let n_cols = cols.split(',').count();
    let mut st = conn.prepare(&format!(
        "SELECT {cols}, seq FROM {table} WHERE seq > ?1 ORDER BY seq LIMIT ?2"
    ))?;
    let rows = st.query_map(
        rusqlite::params![after, i64::try_from(limit + 1).unwrap_or(i64::MAX)],
        |r| Ok((r.get::<_, i64>(n_cols)?, map(r)?)),
    )?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

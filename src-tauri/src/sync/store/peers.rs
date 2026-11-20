//! Paired devices and their sync watermarks (local only).

use super::ctx::{get_meta, random_id, set_meta};
use super::hlc::is_id;
use super::{MAX_NAME_CHARS, Result, SyncError};
use crate::library::ProfileId;
use rusqlite::{Connection, OptionalExtension, Row, params};
use std::collections::HashMap;

#[derive(Clone, PartialEq, Eq)]
pub struct Peer {
    pub device_id: String,
    pub name: String,
    /// The per-device pairing secret (never logged).
    pub secret: Vec<u8>,
    /// The local profile this pairing syncs: only its favourites, playlists
    /// and listens travel to this peer.
    pub profile: ProfileId,
    /// Our highest seq the peer has acknowledged.
    pub last_seq_sent: i64,
    /// The peer's highest seq we have applied.
    pub last_seq_received: i64,
    /// Unix milliseconds of the last completed apply from this peer.
    pub last_sync_at: Option<i64>,
}

impl std::fmt::Debug for Peer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Peer")
            .field("device_id", &self.device_id)
            .field("name", &self.name)
            .field("secret", &"<redacted>")
            .field("profile", &self.profile)
            .field("last_seq_sent", &self.last_seq_sent)
            .field("last_seq_received", &self.last_seq_received)
            .field("last_sync_at", &self.last_sync_at)
            .finish()
    }
}

const COLS: &str =
    "device_id, name, secret, last_seq_sent, last_seq_received, last_sync_at, profile_id";

fn row(r: &Row<'_>) -> rusqlite::Result<Peer> {
    Ok(Peer {
        device_id: r.get(0)?,
        name: r.get(1)?,
        secret: r.get(2)?,
        last_seq_sent: r.get(3)?,
        last_seq_received: r.get(4)?,
        last_sync_at: r.get(5)?,
        profile: ProfileId(r.get(6)?),
    })
}

pub fn peers(conn: &Connection) -> Result<Vec<Peer>> {
    let mut st = conn.prepare(&format!(
        "SELECT {COLS} FROM sync_peers ORDER BY name, device_id"
    ))?;
    let rows = st.query_map([], row)?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub fn peer(conn: &Connection, device_id: &str) -> Result<Option<Peer>> {
    Ok(conn
        .query_row(
            &format!("SELECT {COLS} FROM sync_peers WHERE device_id = ?1"),
            [device_id],
            row,
        )
        .optional()?)
}

/// The profiles that have at least one pairing, in id order. Capture runs
/// for exactly these.
pub fn bound_profiles(conn: &Connection) -> Result<Vec<ProfileId>> {
    let mut st = conn.prepare("SELECT DISTINCT profile_id FROM sync_peers ORDER BY profile_id")?;
    let rows = st.query_map([], |r| Ok(ProfileId(r.get(0)?)))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// Profile id -> name, for showing which profile a pairing syncs.
pub fn profile_names(conn: &Connection) -> Result<HashMap<ProfileId, String>> {
    let mut st = conn.prepare("SELECT id, name FROM profiles")?;
    let rows = st.query_map([], |r| Ok((ProfileId(r.get(0)?), r.get(1)?)))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// Adds a paired device bound to `profile`, or updates its name, secret and
/// profile. Pairing again re-binds, and the watermarks start over: the
/// peer's profile may have changed too (it is not told to us), so the next
/// round re-sends this profile's changes in full. That is cheap and safe,
/// because merging is idempotent.
pub fn upsert_peer(
    conn: &Connection,
    device_id: &str,
    name: &str,
    secret: &[u8],
    profile: ProfileId,
) -> Result<()> {
    if !is_id(device_id) {
        return Err(SyncError::Other("malformed device id".into()));
    }
    let name = name.trim();
    if name.is_empty() || name.chars().count() > MAX_NAME_CHARS {
        return Err(SyncError::Other("invalid device name".into()));
    }
    let exists: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM profiles WHERE id = ?1)",
        [profile.0],
        |r| r.get(0),
    )?;
    if !exists {
        return Err(SyncError::Other("no such profile".into()));
    }
    conn.execute(
        "INSERT INTO sync_peers(device_id, name, secret, profile_id) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(device_id) DO UPDATE SET
            name = excluded.name, secret = excluded.secret, profile_id = excluded.profile_id,
            last_seq_sent = 0, last_seq_received = 0",
        params![device_id, name, secret, profile.0],
    )?;
    Ok(())
}

/// Forgets a paired device (its secret and stored address are deleted).
/// Synced data stays.
pub fn remove_peer(conn: &Connection, device_id: &str) -> Result<bool> {
    conn.execute(
        "DELETE FROM sync_meta WHERE key IN (?1, ?2)",
        [address_key(device_id), wire_key(device_id)],
    )?;
    Ok(conn.execute("DELETE FROM sync_peers WHERE device_id = ?1", [device_id])? > 0)
}

fn wire_key(device_id: &str) -> String {
    format!("peer_wire:{device_id}")
}

/// The id the peer of row `key` uses on the wire: the row key itself,
/// except for a computer that a second phone profile paired with (see
/// [`pairing_key`]).
pub fn peer_wire_id(conn: &Connection, key: &str) -> Result<String> {
    wire_id(conn, key)
}

/// Remembers that the row `key` is a pairing with the computer `wire`.
pub fn set_peer_wire_id(conn: &Connection, key: &str, wire: &str) -> Result<()> {
    if peer(conn, key)?.is_none() || !is_id(wire) {
        return Err(SyncError::Other("unknown peer".into()));
    }
    set_meta(conn, &wire_key(key), wire)
}

pub(super) fn wire_id(conn: &Connection, key: &str) -> Result<String> {
    Ok(get_meta(conn, &wire_key(key))?
        .filter(|w| is_id(w))
        .unwrap_or_else(|| key.to_owned()))
}

/// The `sync_peers` row key for the pairing of local `profile` with the
/// computer whose wire id is `wire` (phone side, K25). One computer can be
/// paired by several phone profiles, each over its own link identity, so
/// each pairing needs its own row: an existing pairing of this profile with
/// that computer keeps its row; otherwise the computer's own id is used when
/// that row is free (pairings made before K25 look like this), else a fresh
/// random key (the caller then records the wire id with
/// [`set_peer_wire_id`]).
pub fn pairing_key(conn: &Connection, wire: &str, profile: ProfileId) -> Result<String> {
    for p in peers(conn)? {
        if p.profile == profile && wire_id(conn, &p.device_id)? == wire {
            return Ok(p.device_id);
        }
    }
    if peer(conn, wire)?.is_none() {
        return Ok(wire.to_owned());
    }
    random_id(conn)
}

fn address_key(device_id: &str) -> String {
    format!("peer_address:{device_id}")
}

/// Where a paired computer listens (`ip:port`), for the phone to dial.
/// Only computers the phone paired with have one (kept in `sync_meta`).
pub fn peer_address(conn: &Connection, device_id: &str) -> Result<Option<String>> {
    get_meta(conn, &address_key(device_id))
}

/// Stores the address of a paired peer (the peer must exist).
pub fn set_peer_address(conn: &Connection, device_id: &str, address: &str) -> Result<()> {
    if peer(conn, device_id)?.is_none() {
        return Err(SyncError::Other("unknown peer".into()));
    }
    if address.is_empty() || address.len() > 64 || address.chars().any(char::is_control) {
        return Err(SyncError::Other("invalid address".into()));
    }
    set_meta(conn, &address_key(device_id), address)
}

/// The peer acknowledged our changes up to `seq`. Never moves backwards.
pub fn ack_sent(conn: &Connection, device_id: &str, seq: i64) -> Result<()> {
    let n = conn.execute(
        "UPDATE sync_peers SET last_seq_sent = MAX(last_seq_sent, ?2) WHERE device_id = ?1",
        params![device_id, seq],
    )?;
    if n == 0 {
        return Err(SyncError::Other("unknown peer".into()));
    }
    Ok(())
}

/// Moves the "received" watermark (inside the apply transaction).
pub(super) fn mark_received(
    conn: &Connection,
    device_id: &str,
    seq: i64,
    now_ms: i64,
) -> Result<()> {
    let n = conn.execute(
        "UPDATE sync_peers
         SET last_seq_received = MAX(last_seq_received, ?2), last_sync_at = ?3
         WHERE device_id = ?1",
        params![device_id, seq, now_ms],
    )?;
    if n == 0 {
        return Err(SyncError::Other("unknown peer".into()));
    }
    Ok(())
}

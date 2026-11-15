//! Paired devices and their sync watermarks (local only).

use super::ctx::{get_meta, set_meta};
use super::hlc::is_id;
use super::{MAX_NAME_CHARS, Result, SyncError};
use rusqlite::{Connection, OptionalExtension, Row, params};

#[derive(Clone, PartialEq, Eq)]
pub struct Peer {
    pub device_id: String,
    pub name: String,
    /// The per-device pairing secret (never logged).
    pub secret: Vec<u8>,
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
            .field("last_seq_sent", &self.last_seq_sent)
            .field("last_seq_received", &self.last_seq_received)
            .field("last_sync_at", &self.last_sync_at)
            .finish()
    }
}

const COLS: &str = "device_id, name, secret, last_seq_sent, last_seq_received, last_sync_at";

fn row(r: &Row<'_>) -> rusqlite::Result<Peer> {
    Ok(Peer {
        device_id: r.get(0)?,
        name: r.get(1)?,
        secret: r.get(2)?,
        last_seq_sent: r.get(3)?,
        last_seq_received: r.get(4)?,
        last_sync_at: r.get(5)?,
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

/// Adds a paired device, or updates its name and secret (re-pairing keeps
/// the watermarks: the data on both sides is unchanged).
pub fn upsert_peer(conn: &Connection, device_id: &str, name: &str, secret: &[u8]) -> Result<()> {
    if !is_id(device_id) {
        return Err(SyncError::Other("malformed device id".into()));
    }
    let name = name.trim();
    if name.is_empty() || name.chars().count() > MAX_NAME_CHARS {
        return Err(SyncError::Other("invalid device name".into()));
    }
    conn.execute(
        "INSERT INTO sync_peers(device_id, name, secret) VALUES (?1, ?2, ?3)
         ON CONFLICT(device_id) DO UPDATE SET name = excluded.name, secret = excluded.secret",
        params![device_id, name, secret],
    )?;
    Ok(())
}

/// Forgets a paired device (its secret and stored address are deleted).
/// Synced data stays.
pub fn remove_peer(conn: &Connection, device_id: &str) -> Result<bool> {
    conn.execute(
        "DELETE FROM sync_meta WHERE key = ?1",
        [address_key(device_id)],
    )?;
    Ok(conn.execute("DELETE FROM sync_peers WHERE device_id = ?1", [device_id])? > 0)
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

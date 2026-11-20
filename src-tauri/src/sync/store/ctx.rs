//! Per-operation state: the connection (inside the caller's transaction),
//! the hybrid logical clock and the local change sequence, loaded from
//! `sync_meta` at the start and written back by [`Ctx::save`].

use super::hlc::{Clock, Hlc, is_id};
use super::{MAX_NAME_CHARS, Result, SyncError};
use crate::library::ProfileId;
use rusqlite::{Connection, OptionalExtension};

const META_DEVICE_ID: &str = "device_id";
const META_DEVICE_NAME: &str = "device_name";
const META_HLC_WALL: &str = "hlc_wall";
const META_HLC_COUNTER: &str = "hlc_counter";
const META_SEQ: &str = "seq";

pub(super) fn get_meta(conn: &Connection, key: &str) -> Result<Option<String>> {
    Ok(conn
        .query_row("SELECT value FROM sync_meta WHERE key = ?1", [key], |r| {
            r.get(0)
        })
        .optional()?)
}

pub(super) fn set_meta(conn: &Connection, key: &str, value: &str) -> Result<()> {
    conn.execute(
        "INSERT INTO sync_meta(key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [key, value],
    )?;
    Ok(())
}

/// A fresh random 128-bit id (32 hex characters) from SQLite's CSPRNG,
/// which is seeded by the operating system.
pub(super) fn random_id(conn: &Connection) -> Result<String> {
    Ok(conn.query_row("SELECT lower(hex(randomblob(16)))", [], |r| r.get(0))?)
}

/// This install's device id, created on first use.
pub fn device_id(conn: &Connection) -> Result<String> {
    if let Some(id) = get_meta(conn, META_DEVICE_ID)?
        && is_id(&id)
    {
        return Ok(id);
    }
    let id = random_id(conn)?;
    set_meta(conn, META_DEVICE_ID, &id)?;
    Ok(id)
}

/// The id this phone uses on the wire for the pairing of `profile`
/// (decision K25). The PC keys `sync_peers` by device id, so each phone
/// profile that pairs needs an id of its own. The first profile keeps the
/// install's device id (pairings made before profiles keep working); every
/// other profile gets a random id, created on first use and kept in
/// `sync_meta` (`device_id:profile:<id>`).
///
/// The clock's node id stays the install's device id on purpose: one clock
/// serves all profiles (stamps stay strictly increasing and the sequence
/// number is global), and two profiles never share a record, so ties
/// cannot occur.
pub fn link_device_id(conn: &Connection, profile: ProfileId) -> Result<String> {
    if profile == ProfileId::FIRST {
        return device_id(conn);
    }
    let key = profile_id_key(profile);
    if let Some(id) = get_meta(conn, &key)?
        && is_id(&id)
    {
        return Ok(id);
    }
    let id = random_id(conn)?;
    set_meta(conn, &key, &id)?;
    Ok(id)
}

fn profile_id_key(profile: ProfileId) -> String {
    format!("{META_DEVICE_ID}:profile:{}", profile.0)
}

/// Forgets the wire id of a deleted profile.
pub fn forget_link_device_id(conn: &Connection, profile: ProfileId) -> Result<()> {
    conn.execute(
        "DELETE FROM sync_meta WHERE key = ?1",
        [profile_id_key(profile)],
    )?;
    Ok(())
}

/// Is `id` one of this install's own ids (the device id or a profile's)?
pub(super) fn is_own_id(conn: &Connection, id: &str) -> Result<bool> {
    if id == device_id(conn)? {
        return Ok(true);
    }
    Ok(conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sync_meta WHERE key LIKE 'device\\_id:profile:%' ESCAPE '\\'
                         AND value = ?1)",
        [id],
        |r| r.get(0),
    )?)
}

/// The display name other devices see, if one was set.
pub fn device_name(conn: &Connection) -> Result<Option<String>> {
    get_meta(conn, META_DEVICE_NAME)
}

pub fn set_device_name(conn: &Connection, name: &str) -> Result<()> {
    let name = name.trim();
    if name.is_empty() || name.chars().count() > MAX_NAME_CHARS {
        return Err(SyncError::Other("invalid device name".into()));
    }
    set_meta(conn, META_DEVICE_NAME, name)
}

fn meta_number<T: std::str::FromStr + Default>(conn: &Connection, key: &str) -> Result<T> {
    Ok(get_meta(conn, key)?
        .and_then(|v| v.parse().ok())
        .unwrap_or_default())
}

pub(super) struct Ctx<'c> {
    pub conn: &'c Connection,
    pub now_ms: i64,
    /// The profile whose rows this operation reads and writes. Capture
    /// visits every bound profile in turn; everything else works on the
    /// profile of the pairing.
    pub profile: ProfileId,
    pub clock: Clock,
    /// Last sequence number handed out.
    seq: i64,
}

impl<'c> Ctx<'c> {
    pub fn load(conn: &'c Connection, now_ms: i64, profile: ProfileId) -> Result<Self> {
        let device = device_id(conn)?;
        Ok(Self {
            conn,
            now_ms,
            profile,
            clock: Clock {
                wall_ms: meta_number(conn, META_HLC_WALL)?,
                counter: meta_number(conn, META_HLC_COUNTER)?,
                device,
            },
            seq: meta_number(conn, META_SEQ)?,
        })
    }

    pub fn device(&self) -> &str {
        &self.clock.device
    }

    /// A new local stamp.
    pub fn stamp(&mut self) -> String {
        self.clock.tick(self.now_ms).encode()
    }

    pub fn observe(&mut self, stamp: &Hlc) {
        self.clock.observe(stamp, self.now_ms);
    }

    /// The next local sequence number (strictly increasing).
    pub fn next_seq(&mut self) -> i64 {
        self.seq += 1;
        self.seq
    }

    pub fn save(&self) -> Result<()> {
        set_meta(self.conn, META_HLC_WALL, &self.clock.wall_ms.to_string())?;
        set_meta(self.conn, META_HLC_COUNTER, &self.clock.counter.to_string())?;
        set_meta(self.conn, META_SEQ, &self.seq.to_string())
    }
}

/// The highest sequence number handed out so far.
pub(super) fn current_seq(conn: &Connection) -> Result<i64> {
    meta_number(conn, META_SEQ)
}

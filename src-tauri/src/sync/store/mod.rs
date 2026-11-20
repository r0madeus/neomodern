//! The replicated data model of PC <-> phone sync (`docs/SYNC.md`): pure
//! SQLite, no networking.
//!
//! The app keeps reading and writing its own tables (`favorites`,
//! `playlists`, `playlist_tracks`, `listen_events`). The `sync_*` tables are
//! the replicated record, kept in step by
//!
//! * **capture** ([`capture`]) – local tables → sync tables, stamping every
//!   local change with a hybrid logical clock;
//! * **merge** – incoming records → sync tables (last writer wins per field,
//!   append-only history), commutative, associative and idempotent;
//! * **materialise** – sync tables → local tables.
//!
//! [`apply`] runs capture → mass-delete guard → merge → first-sync
//! reconciliation → materialise → watermark in one transaction, so an
//! error or a dropped connection leaves the database exactly as it was.

mod backup;
mod capture;
mod changes;
mod ctx;
mod hlc;
mod key;
mod lcs;
mod local;
mod materialize;
mod merge;
mod peers;
mod plan;
mod pos;
mod reconcile;
mod rows;
mod validate;

#[cfg(test)]
mod tests;

pub use backup::{BACKUP_INTERVAL_MS, BACKUPS_KEPT, backup_if_due};
pub use changes::{changes_since, max_seq};
pub use ctx::{device_id, device_name, set_device_name};
pub use hlc::Hlc;
pub use key::{norm, track_key};
pub use peers::{
    Peer, ack_sent, bound_profiles, peer, peer_address, peers, profile_names, remove_peer,
    set_peer_address, upsert_peer,
};
pub use plan::{GuardTrip, Plan, PlaylistLoss};
pub use validate::check_batch;

use crate::library::ProfileId;
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Longest string accepted in a record (bytes).
pub const MAX_STR_BYTES: usize = 1024;
/// Longest playlist name (characters).
pub const MAX_NAME_CHARS: usize = 200;
/// Most records in one batch.
pub const MAX_RECORDS: usize = 200_000;
/// Most playlists in one batch.
pub const MAX_PLAYLISTS: usize = 5_000;

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("database error: {0}")]
    Db(#[from] rusqlite::Error),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("malformed sync message: {0}")]
    Json(#[from] serde_json::Error),
    /// The batch failed validation; nothing was applied.
    #[error("invalid sync batch: {0}")]
    Invalid(String),
    /// Applying would delete a lot of data; nothing was applied. The caller
    /// asks the user and calls [`apply`] again with `allow_mass_delete`.
    #[error("sync stopped: the other device would remove a lot of data")]
    MassDelete(Box<Plan>),
    /// `PRAGMA quick_check` failed after a sync. The data was committed;
    /// syncing must stop and the user be told (a backup exists).
    #[error("database integrity check failed: {0}")]
    Integrity(String),
    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, SyncError>;

/// Favourite state of one song (LWW register).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FavoriteRecord {
    pub key: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: Option<i64>,
    pub on: bool,
    pub hlc: String,
}

/// A playlist: one LWW register per mutable field.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PlaylistRecord {
    pub uuid: String,
    pub name: String,
    pub name_hlc: String,
    /// `preset:…` cover, or none. Image covers are files and not synced.
    pub cover_preset: Option<String>,
    pub cover_hlc: String,
    pub deleted: bool,
    pub deleted_hlc: String,
    /// Unix seconds; immutable.
    pub created_at: i64,
}

/// One song in a playlist. `pos` and `deleted` are LWW registers; the rest
/// is immutable.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EntryRecord {
    pub uuid: String,
    pub playlist_uuid: String,
    pub key: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: Option<i64>,
    /// Unix seconds: when the song was added to the playlist.
    pub added_at: i64,
    pub pos: String,
    pub pos_hlc: String,
    pub deleted: bool,
    pub deleted_hlc: String,
}

/// One listening-history event (immutable; history is an append-only union).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ListenRecord {
    pub uid: String,
    pub key: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub genre: String,
    pub duration_ms: Option<i64>,
    /// The sender's path; used only when the song is not in our library.
    pub path: String,
    pub started_at: i64,
    pub ended_at: i64,
    pub listened_ms: i64,
    pub completed: bool,
    pub skipped: bool,
}

/// One page of changes: every record with `seq` in `(after, upto_seq]` on
/// the sender, up to the page limit.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Batch {
    pub from_device: String,
    /// The sender's watermark after this page: acknowledge it, ask for
    /// changes after it next time.
    pub upto_seq: i64,
    /// More pages follow. First-sync reconciliation waits for the last page
    /// so it sees whole playlists.
    pub more: bool,
    pub favorites: Vec<FavoriteRecord>,
    pub playlists: Vec<PlaylistRecord>,
    pub entries: Vec<EntryRecord>,
    pub listens: Vec<ListenRecord>,
}

impl Batch {
    pub fn len(&self) -> usize {
        self.favorites.len() + self.playlists.len() + self.entries.len() + self.listens.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Parses and validates a batch received from a peer.
    pub fn from_json(bytes: &[u8]) -> Result<Self> {
        let batch: Self = serde_json::from_slice(bytes)?;
        check_batch(&batch)?;
        Ok(batch)
    }
}

#[derive(Debug, Clone)]
pub struct ApplyOptions {
    /// The local profile the sending peer is bound to: the batch is merged
    /// into, and materialised for, this profile only.
    pub profile: ProfileId,
    /// Moves this peer's "received" watermark to `batch.upto_seq` in the
    /// same transaction. The peer must be in `sync_peers`.
    pub peer_id: Option<String>,
    /// Shown in "Name (Device)" when a first sync keeps two playlists with
    /// the same name.
    pub peer_name: String,
    /// The user chose "Apply" after the mass-delete guard stopped a sync.
    pub allow_mass_delete: bool,
    /// When set, a batch that changes data first gets a database backup
    /// here (`<data>/sync-backups`), at most once per 6 h.
    pub backup_dir: Option<PathBuf>,
    pub now_ms: i64,
}

/// How many records a merge changed.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MergeStats {
    pub favorites: usize,
    pub playlists: usize,
    pub entries: usize,
    pub listens: usize,
}

#[derive(Debug, Clone, Default)]
pub struct ApplyReport {
    pub plan: Plan,
    pub merged: MergeStats,
    /// Local tables changed: the caller must bump the library version so
    /// the UI refreshes.
    pub local_changed: bool,
    /// Image covers of playlists the sync deleted. The sync code never
    /// deletes files; the caller may remove them like a local delete does.
    pub orphan_covers: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CaptureReport {
    /// Sync rows stamped by this capture.
    pub stamped: usize,
    /// Local rows written back (a song that reappeared got its favourite or
    /// playlist entries back): the caller must bump the library version.
    pub local_changed: bool,
}

/// Copies local changes of the given profiles (the bound ones, see
/// [`bound_profiles`]) into the sync tables in one transaction. The presence
/// snapshot is library-wide, so it is read once and saved once for all of
/// them.
pub fn capture(conn: &Connection, now_ms: i64, profiles: &[ProfileId]) -> Result<CaptureReport> {
    let first = profiles.first().copied().unwrap_or(ProfileId::FIRST);
    let tx = conn.unchecked_transaction()?;
    let mut ctx = ctx::Ctx::load(&tx, now_ms, first)?;
    let res = key::Resolver::load(&tx)?;
    let report = capture::run(&mut ctx, &res, profiles)?;
    ctx.save()?;
    tx.commit()?;
    Ok(report)
}

/// The profiles an operation for `profile` captures: every bound profile,
/// plus `profile` itself.
fn capture_set(conn: &Connection, profile: ProfileId) -> Result<Vec<ProfileId>> {
    let mut all = bound_profiles(conn)?;
    if !all.contains(&profile) {
        all.push(profile);
    }
    Ok(all)
}

/// What applying `batch` to `profile` would do, without writing anything
/// (the local capture it needs runs in a transaction that is rolled back).
pub fn plan(conn: &Connection, profile: ProfileId, batch: &Batch, now_ms: i64) -> Result<Plan> {
    check_batch(batch)?;
    let tx = conn.unchecked_transaction()?;
    let mut ctx = ctx::Ctx::load(&tx, now_ms, profile)?;
    let res = key::Resolver::load(&tx)?;
    capture::run(&mut ctx, &res, &capture_set(&tx, profile)?)?;
    let plan = plan::compute(&ctx, &res, batch)?;
    tx.rollback()?;
    Ok(plan)
}

/// Validates and applies one incoming batch: capture, guard, merge,
/// reconcile (on the last page), materialise and the peer watermark commit
/// together or not at all. A `PRAGMA quick_check` runs afterwards.
pub fn apply(conn: &Connection, batch: &Batch, opts: &ApplyOptions) -> Result<ApplyReport> {
    check_batch(batch)?;
    let own = device_id(conn)?;
    if batch.from_device == own {
        return Err(SyncError::Invalid("batch comes from this device".into()));
    }
    if let Some(peer) = &opts.peer_id {
        if *peer != batch.from_device {
            return Err(SyncError::Invalid("batch is not from this peer".into()));
        }
        match self::peer(conn, peer)? {
            Some(p) if p.profile != opts.profile => {
                return Err(SyncError::Invalid(
                    "batch is for a different profile than the pairing".into(),
                ));
            }
            _ => {}
        }
    }
    if let Some(dir) = &opts.backup_dir {
        // VACUUM INTO cannot run inside the apply transaction, so the
        // (read-only) plan decides first whether this batch changes data.
        let p = plan(conn, opts.profile, batch, opts.now_ms)?;
        if p.changes_anything() && (p.guard.is_none() || opts.allow_mass_delete) {
            backup_if_due(conn, dir, opts.now_ms)?;
        }
    }
    let report = {
        let tx = conn.unchecked_transaction()?;
        let mut ctx = ctx::Ctx::load(&tx, opts.now_ms, opts.profile)?;
        let res = key::Resolver::load(&tx)?;
        // Every bound profile is captured, not just this peer's: the
        // presence snapshot is saved for the whole library, and a profile
        // left out would miss a song that reappeared.
        let captured = capture::run(&mut ctx, &res, &capture_set(&tx, opts.profile)?)?;
        let plan = plan::compute(&ctx, &res, batch)?;
        if plan.guard.is_some() && !opts.allow_mass_delete {
            // Dropping `tx` rolls the capture back too.
            return Err(SyncError::MassDelete(Box::new(plan)));
        }
        let merged = merge::run(&mut ctx, batch)?;
        let reconciled = !batch.more && reconcile::run(&mut ctx, &res, &opts.peer_name)?;
        let materialized = materialize::run(&ctx, &res, &merged.new_listens)?;
        if let Some(peer) = &opts.peer_id {
            peers::mark_received(&tx, peer, batch.upto_seq, opts.now_ms)?;
        }
        ctx.save()?;
        tx.commit()?;
        // An idle round (the periodic sync with nothing new on either side)
        // writes only bookkeeping (clock, watermark); the full-database
        // `quick_check` is then skipped, so it does not hold the library
        // lock every ten minutes for nothing.
        let wrote_data = !batch.is_empty()
            || captured.stamped > 0
            || captured.local_changed
            || reconciled
            || materialized.changed;
        (
            ApplyReport {
                plan,
                merged: merged.stats,
                local_changed: captured.local_changed || materialized.changed,
                orphan_covers: materialized.orphan_covers,
            },
            wrote_data,
        )
    };
    let (report, wrote_data) = report;
    if wrote_data {
        quick_check(conn)?;
    }
    Ok(report)
}

/// The local track a synced key refers to (canonical id), with the same
/// rules capture and materialise use. Loads the whole track list, so call
/// it for single lookups (the remote's now-playing cover), not in loops.
pub fn resolve_key(conn: &Connection, key: &str, duration_ms: Option<i64>) -> Result<Option<i64>> {
    Ok(key::Resolver::load(conn)?.resolve(key, duration_ms))
}

/// `PRAGMA quick_check`; anything but "ok" is an [`SyncError::Integrity`].
pub fn quick_check(conn: &Connection) -> Result<()> {
    let mut st = conn.prepare("PRAGMA quick_check")?;
    let lines = st
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if lines.len() == 1 && lines[0] == "ok" {
        Ok(())
    } else {
        Err(SyncError::Integrity(lines.join("; ")))
    }
}

//! Merge: incoming records → sync tables.
//!
//! Every mutable field is a last-writer-wins register compared by HLC
//! string (ties are impossible: the device id is part of the stamp);
//! immutable fields keep the first value seen; history is an append-only
//! union. That makes merging commutative, associative and idempotent.
//! A row that changes gets a new local `seq`, so it is relayed to other
//! peers.

use super::ctx::Ctx;
use super::hlc::Hlc;
use super::rows;
use super::{Batch, EntryRecord, FavoriteRecord, ListenRecord, MergeStats, PlaylistRecord, Result};

pub(super) struct MergeOutcome {
    pub stats: MergeStats,
    /// History rows that were new here; materialise copies exactly these
    /// into `listen_events` (so clearing local history is never undone).
    pub new_listens: Vec<String>,
}

pub(super) fn run(ctx: &mut Ctx<'_>, batch: &Batch) -> Result<MergeOutcome> {
    observe_all(ctx, batch);
    let mut stats = MergeStats::default();
    for f in &batch.favorites {
        stats.favorites += usize::from(favorite(ctx, f)?);
    }
    for p in &batch.playlists {
        stats.playlists += usize::from(playlist(ctx, p)?);
    }
    for e in &batch.entries {
        stats.entries += usize::from(entry(ctx, e)?);
    }
    let mut new_listens = Vec::new();
    for l in &batch.listens {
        if listen(ctx, l)? {
            new_listens.push(l.uid.clone());
        }
    }
    stats.listens = new_listens.len();
    Ok(MergeOutcome { stats, new_listens })
}

/// Receiving a stamp advances our clock, so later local edits win over
/// everything we have seen.
fn observe_all(ctx: &mut Ctx<'_>, batch: &Batch) {
    let stamps = batch
        .favorites
        .iter()
        .map(|f| f.hlc.as_str())
        .chain(batch.playlists.iter().flat_map(|p| {
            [
                p.name_hlc.as_str(),
                p.cover_hlc.as_str(),
                p.deleted_hlc.as_str(),
            ]
        }))
        .chain(
            batch
                .entries
                .iter()
                .flat_map(|e| [e.pos_hlc.as_str(), e.deleted_hlc.as_str()]),
        );
    if let Some(newest) = stamps.max().and_then(Hlc::parse) {
        ctx.observe(&newest);
    }
}

fn favorite(ctx: &mut Ctx<'_>, incoming: &FavoriteRecord) -> Result<bool> {
    let current = rows::get_favorite(ctx.conn, ctx.profile, &incoming.key)?;
    if current.as_ref().is_some_and(|c| c.hlc >= incoming.hlc) {
        return Ok(false);
    }
    let seq = ctx.next_seq();
    rows::put_favorite(ctx.conn, ctx.profile, incoming, seq)?;
    Ok(true)
}

/// Takes `theirs` when its stamp is newer; true when it did.
fn lww<T: Clone>(mine: &mut T, mine_hlc: &mut String, theirs: &T, theirs_hlc: &str) -> bool {
    if theirs_hlc > mine_hlc.as_str() {
        *mine = theirs.clone();
        *mine_hlc = theirs_hlc.to_owned();
        true
    } else {
        false
    }
}

fn playlist(ctx: &mut Ctx<'_>, incoming: &PlaylistRecord) -> Result<bool> {
    let Some(row) = rows::get_playlist(ctx.conn, ctx.profile, &incoming.uuid)? else {
        // New here: it waits for first-sync reconciliation before it is
        // shown (see `reconcile`).
        let seq = ctx.next_seq();
        rows::put_playlist(ctx.conn, ctx.profile, incoming, false, seq)?;
        return Ok(true);
    };
    let mut rec = row.rec;
    let mut changed = lww(
        &mut rec.name,
        &mut rec.name_hlc,
        &incoming.name,
        &incoming.name_hlc,
    );
    changed |= lww(
        &mut rec.cover_preset,
        &mut rec.cover_hlc,
        &incoming.cover_preset,
        &incoming.cover_hlc,
    );
    changed |= lww(
        &mut rec.deleted,
        &mut rec.deleted_hlc,
        &incoming.deleted,
        &incoming.deleted_hlc,
    );
    if changed {
        let seq = ctx.next_seq();
        rows::put_playlist(ctx.conn, ctx.profile, &rec, row.reconciled, seq)?;
    }
    Ok(changed)
}

fn entry(ctx: &mut Ctx<'_>, incoming: &EntryRecord) -> Result<bool> {
    let Some(mut rec) = rows::get_entry(ctx.conn, ctx.profile, &incoming.uuid)? else {
        let seq = ctx.next_seq();
        rows::put_entry(ctx.conn, ctx.profile, incoming, seq)?;
        return Ok(true);
    };
    let mut changed = lww(
        &mut rec.pos,
        &mut rec.pos_hlc,
        &incoming.pos,
        &incoming.pos_hlc,
    );
    changed |= lww(
        &mut rec.deleted,
        &mut rec.deleted_hlc,
        &incoming.deleted,
        &incoming.deleted_hlc,
    );
    if changed {
        let seq = ctx.next_seq();
        rows::put_entry(ctx.conn, ctx.profile, &rec, seq)?;
    }
    Ok(changed)
}

fn listen(ctx: &mut Ctx<'_>, incoming: &ListenRecord) -> Result<bool> {
    if rows::listen_exists(ctx.conn, &incoming.uid)? {
        return Ok(false);
    }
    let seq = ctx.next_seq();
    rows::insert_listen(ctx.conn, ctx.profile, incoming, seq)
}

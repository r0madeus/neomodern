//! First-sync rules for playlists received from a peer.
//!
//! Two devices usually already have playlists of their own. A playlist
//! that arrives with a new uuid is held back (not materialised) until the
//! last page of a sync, then compared with the playlists already shown
//! here that have the same name (case-insensitive):
//!
//! * same resolved song list → **unified**: one uuid survives (the smaller,
//!   so every device picks the same one) and the other is marked deleted;
//! * different songs → **both kept**; the incoming one is renamed
//!   "Name (Device)".
//!
//! Both outcomes are ordinary stamped edits, so they replicate and the
//! devices converge whatever order they sync in. Nothing the user made is
//! lost: a unified pair has the same songs, and a playlist with songs this
//! device cannot resolve is never unified.

use super::ctx::Ctx;
use super::key::Resolver;
use super::rows::{self, PlaylistRow};
use super::{MAX_NAME_CHARS, PlaylistRecord, Result};

/// Returns whether any playlist was waiting to be reconciled (rows written).
pub(super) fn run(ctx: &mut Ctx<'_>, res: &Resolver, peer_name: &str) -> Result<bool> {
    let all = rows::all_playlists(ctx.conn)?;
    let (pending, settled): (Vec<PlaylistRow>, Vec<PlaylistRow>) =
        all.into_iter().partition(|row| !row.reconciled);
    if pending.is_empty() {
        return Ok(false);
    }
    let mut shown: Vec<PlaylistRecord> = settled
        .into_iter()
        .filter(|row| !row.rec.deleted)
        .map(|row| row.rec)
        .collect();
    // `all_playlists` is ordered by uuid, so the outcome is deterministic.
    for row in pending {
        let incoming = row.rec;
        if incoming.deleted {
            mark_reconciled(ctx, &incoming.uuid)?;
            continue;
        }
        let folded = fold(&incoming.name);
        let same_name: Vec<PlaylistRecord> = shown
            .iter()
            .filter(|p| fold(&p.name) == folded)
            .cloned()
            .collect();
        if same_name.is_empty() {
            mark_reconciled(ctx, &incoming.uuid)?;
            shown.push(incoming);
            continue;
        }
        let songs = song_list(ctx, res, &incoming.uuid)?;
        let mut twin = None;
        if songs.is_some() {
            for candidate in same_name {
                if song_list(ctx, res, &candidate.uuid)? == songs {
                    twin = Some(candidate);
                    break;
                }
            }
        }
        match twin {
            Some(local) => unify(ctx, &mut shown, local, incoming)?,
            None => {
                let renamed = rename(ctx, incoming, peer_name)?;
                shown.push(renamed);
            }
        }
    }
    Ok(true)
}

fn fold(name: &str) -> String {
    name.trim().to_lowercase()
}

/// Resolved songs of a playlist in order; `None` when an entry does not
/// resolve here (such a playlist is never unified: its unknown songs
/// would be lost on the device that has them).
fn song_list(ctx: &Ctx<'_>, res: &Resolver, uuid: &str) -> Result<Option<Vec<i64>>> {
    let entries = rows::live_entries(ctx.conn, uuid)?;
    Ok(entries
        .iter()
        .map(|e| res.resolve(&e.key, e.duration_ms))
        .collect())
}

fn mark_reconciled(ctx: &Ctx<'_>, uuid: &str) -> Result<()> {
    // Local-only flag: not replicated, so `seq` does not move.
    ctx.conn.execute(
        "UPDATE sync_playlists SET reconciled = 1 WHERE uuid = ?1",
        [uuid],
    )?;
    Ok(())
}

fn stamp_deleted(ctx: &mut Ctx<'_>, mut rec: PlaylistRecord) -> Result<()> {
    rec.deleted = true;
    rec.deleted_hlc = ctx.stamp();
    let seq = ctx.next_seq();
    rows::put_playlist(ctx.conn, &rec, true, seq)
}

fn unify(
    ctx: &mut Ctx<'_>,
    shown: &mut Vec<PlaylistRecord>,
    local: PlaylistRecord,
    incoming: PlaylistRecord,
) -> Result<()> {
    if incoming.uuid < local.uuid {
        // The incoming uuid wins: the local playlist now follows it (it
        // keeps its local id; materialise updates its name and entries).
        let map = rows::playlist_map(ctx.conn)?;
        if let Some((&id, _)) = map.iter().find(|(_, u)| **u == local.uuid) {
            rows::set_map(ctx.conn, id, &incoming.uuid)?;
        }
        mark_reconciled(ctx, &incoming.uuid)?;
        shown.retain(|p| p.uuid != local.uuid);
        shown.push(incoming);
        stamp_deleted(ctx, local)
    } else {
        stamp_deleted(ctx, incoming)
    }
}

fn rename(ctx: &mut Ctx<'_>, mut rec: PlaylistRecord, peer_name: &str) -> Result<PlaylistRecord> {
    let peer = peer_name.trim();
    let peer = if peer.is_empty() {
        "other device"
    } else {
        peer
    };
    let suffix: String = format!(" ({peer})")
        .chars()
        .take(MAX_NAME_CHARS / 2)
        .collect();
    let room = MAX_NAME_CHARS - suffix.chars().count();
    let base: String = rec.name.trim().chars().take(room).collect();
    rec.name = format!("{}{suffix}", base.trim_end());
    rec.name_hlc = ctx.stamp();
    let seq = ctx.next_seq();
    rows::put_playlist(ctx.conn, &rec, true, seq)?;
    Ok(rec)
}

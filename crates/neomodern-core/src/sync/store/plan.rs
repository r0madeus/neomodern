//! What a batch would change, and the mass-delete guard.
//!
//! A peer with a bug, a wiped database or a broken clock could send a batch
//! that removes most of the user's data. Such a batch stops before anything
//! is applied and the UI asks "Apply / Skip".

use super::ctx::Ctx;
use super::key::Resolver;
use super::local;
use super::rows;
use super::{Batch, Result};
use serde::Serialize;
use std::collections::{BTreeMap, HashSet};

/// Turning off more than this share of the local favourites trips the guard…
const FAVORITES_SHARE: f64 = 0.25;
/// …when at least this many are turned off.
const FAVORITES_MIN: usize = 10;
/// Deleting more playlists than this trips the guard.
const PLAYLISTS_MAX: usize = 2;
/// Removing more than this share of one playlist's songs trips the guard…
const SONGS_SHARE: f64 = 0.5;
/// …when at least this many are removed.
const SONGS_MIN: usize = 10;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaylistLoss {
    pub uuid: String,
    pub name: String,
    pub removed: usize,
    pub total: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum GuardTrip {
    Favorites { off: usize, total: usize },
    Playlists { names: Vec<String> },
    Songs { loss: PlaylistLoss },
}

/// Counts of what a batch would change here.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub favorites: usize,
    pub playlists: usize,
    pub entries: usize,
    pub listens: usize,
    pub local_favorites: usize,
    pub favorites_turned_off: usize,
    pub playlists_deleted: Vec<String>,
    pub songs_removed: Vec<PlaylistLoss>,
    /// Set when the mass-delete guard would stop this batch.
    pub guard: Option<GuardTrip>,
}

impl Plan {
    /// Whether applying would change any synced data (a backup is due
    /// before the first such apply).
    pub fn changes_anything(&self) -> bool {
        self.favorites + self.playlists + self.entries + self.listens > 0
    }
}

pub(super) fn compute(ctx: &Ctx<'_>, res: &Resolver, batch: &Batch) -> Result<Plan> {
    let mut plan = Plan::default();
    favorites(ctx, res, batch, &mut plan)?;
    let deleted = playlists(ctx, batch, &mut plan)?;
    entries(ctx, res, batch, &deleted, &mut plan)?;
    for l in &batch.listens {
        plan.listens += usize::from(!rows::listen_exists(ctx.conn, &l.uid)?);
    }
    plan.guard = guard(&plan);
    Ok(plan)
}

fn favorites(ctx: &Ctx<'_>, res: &Resolver, batch: &Batch, plan: &mut Plan) -> Result<()> {
    let local_songs: HashSet<i64> = local::favorites(ctx.conn, ctx.profile)?
        .into_keys()
        .filter_map(|t| res.canon(t))
        .collect();
    plan.local_favorites = local_songs.len();
    let mut turned_off = HashSet::new();
    for f in &batch.favorites {
        let current = rows::get_favorite(ctx.conn, ctx.profile, &f.key)?;
        if current.as_ref().is_some_and(|c| c.hlc >= f.hlc) {
            continue;
        }
        plan.favorites += 1;
        if !f.on
            && let Some(song) = res.resolve(&f.key, f.duration_ms)
            && local_songs.contains(&song)
        {
            turned_off.insert(song);
        }
    }
    plan.favorites_turned_off = turned_off.len();
    Ok(())
}

/// Counts playlist changes; returns the uuids the batch would delete.
fn playlists(ctx: &Ctx<'_>, batch: &Batch, plan: &mut Plan) -> Result<HashSet<String>> {
    let mut deleted = HashSet::new();
    for p in &batch.playlists {
        let Some(row) = rows::get_playlist(ctx.conn, ctx.profile, &p.uuid)? else {
            plan.playlists += 1;
            continue;
        };
        let cur = &row.rec;
        let wins = p.name_hlc > cur.name_hlc
            || p.cover_hlc > cur.cover_hlc
            || p.deleted_hlc > cur.deleted_hlc;
        plan.playlists += usize::from(wins);
        let deletes = p.deleted && p.deleted_hlc > cur.deleted_hlc && !cur.deleted;
        if deletes && row.reconciled {
            plan.playlists_deleted.push(cur.name.clone());
            deleted.insert(p.uuid.clone());
        }
    }
    Ok(deleted)
}

fn entries(
    ctx: &Ctx<'_>,
    res: &Resolver,
    batch: &Batch,
    deleted_playlists: &HashSet<String>,
    plan: &mut Plan,
) -> Result<()> {
    let mut removed: BTreeMap<String, usize> = BTreeMap::new();
    for e in &batch.entries {
        let Some(cur) = rows::get_entry(ctx.conn, ctx.profile, &e.uuid)? else {
            plan.entries += 1;
            continue;
        };
        let wins = e.pos_hlc > cur.pos_hlc || e.deleted_hlc > cur.deleted_hlc;
        plan.entries += usize::from(wins);
        let removes = e.deleted && e.deleted_hlc > cur.deleted_hlc && !cur.deleted;
        if removes
            && !deleted_playlists.contains(&cur.playlist_uuid)
            && res.resolve(&cur.key, cur.duration_ms).is_some()
        {
            *removed.entry(cur.playlist_uuid.clone()).or_default() += 1;
        }
    }
    for (uuid, count) in removed {
        let Some(row) = rows::get_playlist(ctx.conn, ctx.profile, &uuid)? else {
            continue;
        };
        if row.rec.deleted || !row.reconciled {
            continue;
        }
        let total = rows::live_entries(ctx.conn, &uuid)?
            .iter()
            .filter(|e| res.resolve(&e.key, e.duration_ms).is_some())
            .count();
        plan.songs_removed.push(PlaylistLoss {
            uuid,
            name: row.rec.name,
            removed: count,
            total,
        });
    }
    Ok(())
}

fn guard(plan: &Plan) -> Option<GuardTrip> {
    let off = plan.favorites_turned_off;
    if off >= FAVORITES_MIN && off as f64 > plan.local_favorites as f64 * FAVORITES_SHARE {
        return Some(GuardTrip::Favorites {
            off,
            total: plan.local_favorites,
        });
    }
    if plan.playlists_deleted.len() > PLAYLISTS_MAX {
        return Some(GuardTrip::Playlists {
            names: plan.playlists_deleted.clone(),
        });
    }
    plan.songs_removed
        .iter()
        .find(|l| l.removed >= SONGS_MIN && l.removed as f64 > l.total as f64 * SONGS_SHARE)
        .map(|loss| GuardTrip::Songs { loss: loss.clone() })
}

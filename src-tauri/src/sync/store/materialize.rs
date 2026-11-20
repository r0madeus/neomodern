//! Materialise: sync tables → local tables.
//!
//! Runs in the same transaction as capture and merge, so before the merge
//! the local tables and the sync tables agreed; every difference found
//! here comes from the merge (or reconciliation). Each write makes the
//! local tables equal to what capture would produce from them, so a
//! capture right after materialise stamps nothing.

use super::capture::newest_wall_secs;
use super::ctx::Ctx;
use super::key::Resolver;
use super::local::{self, CoverView, cover_view, is_valid_preset, sync_name};
use super::rows::{self, PlaylistRow};
use super::{PlaylistRecord, Result};
use rusqlite::params;
use std::collections::{BTreeMap, HashMap};

#[derive(Debug, Default)]
pub(super) struct Outcome {
    pub changed: bool,
    pub orphan_covers: Vec<String>,
}

pub(super) fn run(ctx: &Ctx<'_>, res: &Resolver, new_listens: &[String]) -> Result<Outcome> {
    let mut out = Outcome::default();
    favorites(ctx, res, &mut out)?;
    playlists(ctx, res, &mut out)?;
    listens(ctx, res, new_listens, &mut out)?;
    Ok(out)
}

// --- favourites -----------------------------------------------------------

/// `favorites` = the songs resolved from records that are on. A song that
/// was already a favourite keeps its `added_at`.
fn favorites(ctx: &Ctx<'_>, res: &Resolver, out: &mut Outcome) -> Result<()> {
    let mut wanted: BTreeMap<i64, Vec<String>> = BTreeMap::new();
    for r in rows::all_favorites(ctx.conn)?.into_iter().filter(|r| r.on) {
        if let Some(song) = res.resolve(&r.key, r.duration_ms) {
            wanted.entry(song).or_default().push(r.hlc);
        }
    }
    let mut have: HashMap<i64, Vec<i64>> = HashMap::new();
    for (track, _) in local::favorites(ctx.conn)? {
        if let Some(song) = res.canon(track) {
            have.entry(song).or_default().push(track);
        }
    }
    for (song, stamps) in &wanted {
        if !have.contains_key(song) {
            let added_at = newest_wall_secs(stamps.iter().map(String::as_str));
            // K24: sync is bound to profile 1 until per-profile sync lands
            ctx.conn.execute(
                "INSERT OR IGNORE INTO favorites(profile_id, track_id, added_at) VALUES (1, ?1, ?2)",
                params![song, added_at],
            )?;
            out.changed = true;
        }
    }
    for (song, tracks) in &have {
        if !wanted.contains_key(song) {
            for track in tracks {
                // K24: sync is bound to profile 1 until per-profile sync lands
                ctx.conn.execute(
                    "DELETE FROM favorites WHERE profile_id = 1 AND track_id = ?1",
                    [track],
                )?;
            }
            out.changed = true;
        }
    }
    Ok(())
}

// --- playlists ------------------------------------------------------------

fn playlists(ctx: &Ctx<'_>, res: &Resolver, out: &mut Outcome) -> Result<()> {
    let locals: HashMap<i64, local::LocalPlaylist> = local::playlists(ctx.conn)?
        .into_iter()
        .map(|p| (p.id, p))
        .collect();
    let by_uuid: HashMap<String, i64> = rows::playlist_map(ctx.conn)?
        .into_iter()
        .map(|(id, uuid)| (uuid, id))
        .collect();
    for PlaylistRow { rec, reconciled } in rows::all_playlists(ctx.conn)? {
        // Playlists waiting for first-sync reconciliation are not shown yet.
        if !reconciled {
            continue;
        }
        let existing = by_uuid.get(&rec.uuid).and_then(|id| locals.get(id));
        match (rec.deleted, existing) {
            (true, Some(p)) => delete_local(ctx, p, out)?,
            (true, None) => {}
            (false, Some(p)) => update_local(ctx, res, p, &rec, out)?,
            (false, None) => create_local(ctx, res, &rec, out)?,
        }
    }
    Ok(())
}

fn delete_local(ctx: &Ctx<'_>, p: &local::LocalPlaylist, out: &mut Outcome) -> Result<()> {
    // K24: sync is bound to profile 1 until per-profile sync lands
    ctx.conn.execute(
        "DELETE FROM playlists WHERE id = ?1 AND profile_id = 1",
        [p.id],
    )?;
    rows::delete_map(ctx.conn, p.id)?;
    if cover_view(p.cover.as_deref()) == CoverView::Image
        && let Some(cover) = &p.cover
    {
        out.orphan_covers.push(cover.clone());
    }
    out.changed = true;
    Ok(())
}

fn create_local(
    ctx: &Ctx<'_>,
    res: &Resolver,
    rec: &PlaylistRecord,
    out: &mut Outcome,
) -> Result<()> {
    let cover = rec.cover_preset.as_deref().filter(|c| is_valid_preset(c));
    // K24: sync is bound to profile 1 until per-profile sync lands
    ctx.conn.execute(
        "INSERT INTO playlists(name, created_at, cover, profile_id) VALUES (?1, ?2, ?3, 1)",
        params![rec.name, rec.created_at, cover],
    )?;
    let id = ctx.conn.last_insert_rowid();
    rows::set_map(ctx.conn, id, &rec.uuid)?;
    let wanted = wanted_entries(ctx, res, &rec.uuid)?;
    local::rewrite_entries(ctx.conn, id, &wanted)?;
    out.changed = true;
    Ok(())
}

fn update_local(
    ctx: &Ctx<'_>,
    res: &Resolver,
    p: &local::LocalPlaylist,
    rec: &PlaylistRecord,
    out: &mut Outcome,
) -> Result<()> {
    if sync_name(&p.name) != rec.name {
        ctx.conn.execute(
            "UPDATE playlists SET name = ?2 WHERE id = ?1",
            params![p.id, rec.name],
        )?;
        out.changed = true;
    }
    // An image cover is local-only: neither captured nor overwritten.
    if let CoverView::Preset(current) = cover_view(p.cover.as_deref())
        && current != rec.cover_preset
    {
        let cover = rec.cover_preset.as_deref().filter(|c| is_valid_preset(c));
        ctx.conn.execute(
            "UPDATE playlists SET cover = ?2 WHERE id = ?1",
            params![p.id, cover],
        )?;
        out.changed = true;
    }
    let wanted = wanted_entries(ctx, res, &rec.uuid)?;
    let current: Vec<(i64, Option<i64>)> = local::entries(ctx.conn, p.id)?
        .into_iter()
        .map(|(t, added)| (res.canon(t).unwrap_or(t), added))
        .collect();
    let same = current.len() == wanted.len()
        && current
            .iter()
            .zip(&wanted)
            .all(|(&(t, a), &(wt, wa))| t == wt && a == Some(wa));
    if !same {
        local::rewrite_entries(ctx.conn, p.id, &wanted)?;
        out.changed = true;
    }
    Ok(())
}

/// The resolved live entries of a playlist, in order, as
/// `(track_id, added_at)`.
fn wanted_entries(ctx: &Ctx<'_>, res: &Resolver, uuid: &str) -> Result<Vec<(i64, i64)>> {
    Ok(rows::live_entries(ctx.conn, uuid)?
        .iter()
        .filter_map(|e| {
            res.resolve(&e.key, e.duration_ms)
                .map(|song| (song, e.added_at))
        })
        .collect())
}

// --- listening history ----------------------------------------------------

/// Copies history rows that are new on this device into `listen_events`.
fn listens(ctx: &Ctx<'_>, res: &Resolver, uids: &[String], out: &mut Outcome) -> Result<()> {
    // K24: sync is bound to profile 1 until per-profile sync lands
    let mut insert = ctx.conn.prepare_cached(
        "INSERT OR IGNORE INTO listen_events(
             uid, track_id, path, title, artist, album, genre, duration_ms,
             started_at, ended_at, listened_ms, completed, skipped, source, profile_id
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, 'sync', 1)",
    )?;
    for uid in uids {
        let Some(l) = rows::get_listen(ctx.conn, uid)? else {
            continue;
        };
        let track = res.resolve(&l.key, l.duration_ms);
        let path = track
            .and_then(|id| res.track(id))
            .map_or(l.path.as_str(), |t| t.path.as_str());
        let n = insert.execute(params![
            l.uid,
            track,
            path,
            l.title,
            l.artist,
            l.album,
            l.genre,
            l.duration_ms,
            l.started_at,
            l.ended_at,
            l.listened_ms,
            l.completed,
            l.skipped,
        ])?;
        out.changed |= n > 0;
    }
    Ok(())
}

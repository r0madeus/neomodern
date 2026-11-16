//! Capture: local tables → sync tables.
//!
//! The central rule: a song that is not in the local library is never
//! touched. A removed music folder or an unplugged drive cascades the
//! song's rows out of `favorites` / `playlist_tracks`, but that is not an
//! "unfavourite" or a "remove from playlist" and must not reach other
//! devices. To tell the two apart, `sync_present` remembers which tracks
//! were present at the previous capture: when a song *re-appears*, its
//! synced state is restored locally instead of being read as a removal.

use super::ctx::{Ctx, random_id};
use super::hlc::Hlc;
use super::key::{LocalTrack, Resolver, track_key};
use super::lcs::{lcs, lis};
use super::local::{self, CoverView, LocalPlaylist, cover_view, field, sync_name};
use super::rows::{self, PlaylistRow};
use super::{CaptureReport, EntryRecord, FavoriteRecord, ListenRecord, PlaylistRecord, Result};
use super::{MAX_STR_BYTES, pos};
use std::collections::{BTreeSet, HashMap, HashSet};

/// Positions longer than this trigger a re-spread of the playlist (well
/// under the 1 KiB limit the receiver enforces).
const MAX_POS_BYTES: usize = MAX_STR_BYTES - 124;

pub(super) fn run(ctx: &mut Ctx<'_>, res: &Resolver) -> Result<CaptureReport> {
    let mut report = CaptureReport::default();
    let snapshot = load_snapshot(ctx)?;
    let reappeared = reappeared_songs(res, &snapshot);
    favorites(ctx, res, &reappeared, &mut report)?;
    playlists(ctx, res, &reappeared, &mut report)?;
    listens(ctx, &mut report)?;
    save_snapshot(ctx, res, &snapshot)?;
    Ok(report)
}

pub(super) fn now_secs(ctx: &Ctx<'_>) -> i64 {
    ctx.now_ms.div_euclid(1000)
}

// --- presence snapshot ----------------------------------------------------

fn load_snapshot(ctx: &Ctx<'_>) -> Result<HashMap<i64, String>> {
    let mut st = ctx.conn.prepare("SELECT track_id, key FROM sync_present")?;
    let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// Canonical ids of songs that were not present (under the same key) at
/// the previous capture.
fn reappeared_songs(res: &Resolver, snapshot: &HashMap<i64, String>) -> HashSet<i64> {
    res.track_ids()
        .filter(|id| {
            let key = res.track(*id).map(|t| &t.key);
            snapshot.get(id) != key
        })
        .filter_map(|id| res.canon(id))
        .collect()
}

fn save_snapshot(ctx: &Ctx<'_>, res: &Resolver, old: &HashMap<i64, String>) -> Result<()> {
    let mut del = ctx
        .conn
        .prepare_cached("DELETE FROM sync_present WHERE track_id = ?1")?;
    for id in old.keys() {
        if res.track(*id).is_none() {
            del.execute([id])?;
        }
    }
    let mut put = ctx
        .conn
        .prepare_cached("INSERT OR REPLACE INTO sync_present(track_id, key) VALUES (?1, ?2)")?;
    for id in res.track_ids() {
        if let Some(t) = res.track(id)
            && old.get(&id) != Some(&t.key)
        {
            put.execute(rusqlite::params![id, t.key])?;
        }
    }
    Ok(())
}

// --- favourites -----------------------------------------------------------

fn favorites(
    ctx: &mut Ctx<'_>,
    res: &Resolver,
    reappeared: &HashSet<i64>,
    report: &mut CaptureReport,
) -> Result<()> {
    let records = rows::all_favorites(ctx.conn)?;
    let by_key: HashMap<&str, &FavoriteRecord> =
        records.iter().map(|r| (r.key.as_str(), r)).collect();
    let mut on_by_song: HashMap<i64, Vec<&FavoriteRecord>> = HashMap::new();
    for r in records.iter().filter(|r| r.on) {
        if let Some(song) = res.resolve(&r.key, r.duration_ms) {
            on_by_song.entry(song).or_default().push(r);
        }
    }
    // Duplicates of a song share its canonical id: one favourite state.
    let mut local_favs: HashMap<i64, i64> = HashMap::new();
    for (track, added_at) in local::favorites(ctx.conn)? {
        if let Some(song) = res.canon(track) {
            let slot = local_favs.entry(song).or_insert(added_at);
            *slot = (*slot).max(added_at);
        }
    }
    let songs: BTreeSet<i64> = res.track_ids().filter_map(|id| res.canon(id)).collect();
    for song in songs {
        let on = on_by_song.get(&song).map(Vec::as_slice).unwrap_or(&[]);
        match (local_favs.get(&song), on.is_empty()) {
            (Some(&added_at), true) => {
                let Some(track) = res.track(song) else {
                    continue;
                };
                let existing = by_key.get(track.key.as_str()).copied();
                stamp_on(ctx, track, added_at, existing)?;
                report.stamped += 1;
            }
            (None, false) if reappeared.contains(&song) => {
                restore_favorite(ctx, song, on)?;
                report.local_changed = true;
            }
            (None, false) => {
                for r in on {
                    let mut off = (*r).clone();
                    off.on = false;
                    off.hlc = ctx.stamp();
                    let seq = ctx.next_seq();
                    rows::put_favorite(ctx.conn, &off, seq)?;
                    report.stamped += 1;
                }
            }
            _ => {}
        }
    }
    Ok(())
}

/// Stamps a favourite `on`. The stamp's wall time is when the song was
/// starred (if that is newer than the stored stamp), so a star made
/// offline does not override a later "unstar" made elsewhere.
fn stamp_on(
    ctx: &mut Ctx<'_>,
    track: &LocalTrack,
    added_at: i64,
    existing: Option<&FavoriteRecord>,
) -> Result<()> {
    let candidate = Hlc {
        wall_ms: u64::try_from(added_at).unwrap_or(0).saturating_mul(1000),
        counter: 0,
        device: ctx.device().to_owned(),
    };
    let encoded = candidate.encode();
    let fits = Hlc::parse(&encoded).is_some();
    let hlc = match existing {
        Some(e) if !fits || encoded <= e.hlc => ctx.stamp(),
        None if !fits => ctx.stamp(),
        _ => {
            ctx.observe(&candidate);
            encoded
        }
    };
    let rec = FavoriteRecord {
        key: track.key.clone(),
        title: field(&track.title),
        artist: field(&track.artist),
        album: field(&track.album),
        duration_ms: track.duration_ms.filter(|d| *d >= 0),
        on: true,
        hlc,
    };
    let seq = ctx.next_seq();
    rows::put_favorite(ctx.conn, &rec, seq)
}

fn restore_favorite(ctx: &Ctx<'_>, song: i64, on: &[&FavoriteRecord]) -> Result<()> {
    let added_at = newest_wall_secs(on.iter().map(|r| r.hlc.as_str()));
    ctx.conn.execute(
        "INSERT OR IGNORE INTO favorites(track_id, added_at) VALUES (?1, ?2)",
        rusqlite::params![song, added_at],
    )?;
    Ok(())
}

/// Unix seconds of the newest stamp (0 when none parses).
pub(super) fn newest_wall_secs<'a>(stamps: impl Iterator<Item = &'a str>) -> i64 {
    stamps
        .filter_map(Hlc::parse)
        .map(|h| i64::try_from(h.wall_ms / 1000).unwrap_or(0))
        .max()
        .unwrap_or(0)
}

// --- playlists ------------------------------------------------------------

fn playlists(
    ctx: &mut Ctx<'_>,
    res: &Resolver,
    reappeared: &HashSet<i64>,
    report: &mut CaptureReport,
) -> Result<()> {
    let locals = local::playlists(ctx.conn)?;
    let alive: HashSet<i64> = locals.iter().map(|p| p.id).collect();
    let mut map: Vec<(i64, String)> = rows::playlist_map(ctx.conn)?.into_iter().collect();
    map.sort();
    for (id, uuid) in &map {
        if !alive.contains(id) {
            stamp_deleted(ctx, uuid, report)?;
            rows::delete_map(ctx.conn, *id)?;
        }
    }
    let map = rows::playlist_map(ctx.conn)?;
    for p in &locals {
        let row = match map.get(&p.id) {
            Some(uuid) => rows::get_playlist(ctx.conn, uuid)?,
            None => None,
        };
        match row {
            Some(row) => update_playlist(ctx, res, p, row, reappeared, report)?,
            None => create_playlist(ctx, res, p, reappeared, report)?,
        }
    }
    Ok(())
}

/// A local playlist was deleted.
fn stamp_deleted(ctx: &mut Ctx<'_>, uuid: &str, report: &mut CaptureReport) -> Result<()> {
    let Some(mut row) = rows::get_playlist(ctx.conn, uuid)? else {
        return Ok(());
    };
    if row.rec.deleted {
        return Ok(());
    }
    row.rec.deleted = true;
    row.rec.deleted_hlc = ctx.stamp();
    let seq = ctx.next_seq();
    rows::put_playlist(ctx.conn, &row.rec, row.reconciled, seq)?;
    report.stamped += 1;
    Ok(())
}

fn create_playlist(
    ctx: &mut Ctx<'_>,
    res: &Resolver,
    p: &LocalPlaylist,
    reappeared: &HashSet<i64>,
    report: &mut CaptureReport,
) -> Result<()> {
    let uuid = random_id(ctx.conn)?;
    let hlc = ctx.stamp();
    let cover_preset = match cover_view(p.cover.as_deref()) {
        CoverView::Preset(preset) => preset,
        CoverView::Image => None,
    };
    let rec = PlaylistRecord {
        uuid: uuid.clone(),
        name: sync_name(&p.name),
        name_hlc: hlc.clone(),
        cover_preset,
        cover_hlc: hlc.clone(),
        deleted: false,
        deleted_hlc: hlc,
        created_at: p.created_at,
    };
    let seq = ctx.next_seq();
    rows::put_playlist(ctx.conn, &rec, true, seq)?;
    rows::set_map(ctx.conn, p.id, &uuid)?;
    report.stamped += 1;
    align_entries(ctx, res, p.id, &uuid, reappeared, report)?;
    Ok(())
}

fn update_playlist(
    ctx: &mut Ctx<'_>,
    res: &Resolver,
    p: &LocalPlaylist,
    row: PlaylistRow,
    reappeared: &HashSet<i64>,
    report: &mut CaptureReport,
) -> Result<()> {
    let mut rec = row.rec;
    // A local playlist that exists is alive, whatever the record says.
    let mut touched = rec.deleted;
    let name = sync_name(&p.name);
    if name != rec.name {
        rec.name = name;
        rec.name_hlc = ctx.stamp();
        touched = true;
    }
    if let CoverView::Preset(preset) = cover_view(p.cover.as_deref())
        && preset != rec.cover_preset
    {
        rec.cover_preset = preset;
        rec.cover_hlc = ctx.stamp();
        touched = true;
    }
    touched |= align_entries(ctx, res, p.id, &rec.uuid, reappeared, report)?;
    if touched {
        // Every edit also re-stamps `deleted = false`: a concurrent delete
        // and edit are then decided by LWW (the later one wins).
        rec.deleted = false;
        rec.deleted_hlc = ctx.stamp();
        let seq = ctx.next_seq();
        rows::put_playlist(ctx.conn, &rec, true, seq)?;
        report.stamped += 1;
    }
    Ok(())
}

/// Where an item of the new order comes from.
#[derive(Debug, Clone, Copy)]
enum Slot {
    /// Index into the local list.
    Local(usize),
    /// Index into the resolved sync entries: a song that re-appeared in the
    /// library and gets its old place back.
    Restored(usize),
}

/// Aligns a playlist's local entries with its live, resolved sync entries
/// (by song, using LCS): matched entries keep their uuid (and their `pos`
/// unless their relative order changed), local-only entries are added,
/// sync entries whose song is present but no longer listed are deleted,
/// and unresolved entries are left alone. Returns whether a sync row
/// changed.
fn align_entries(
    ctx: &mut Ctx<'_>,
    res: &Resolver,
    playlist_id: i64,
    uuid: &str,
    reappeared: &HashSet<i64>,
    report: &mut CaptureReport,
) -> Result<bool> {
    let local_list = local::entries(ctx.conn, playlist_id)?;
    let local_songs: Vec<i64> = local_list
        .iter()
        .map(|(t, _)| res.canon(*t).unwrap_or(*t))
        .collect();
    let synced = rows::live_entries(ctx.conn, uuid)?;
    let resolved: Vec<(&EntryRecord, i64)> = synced
        .iter()
        .filter_map(|e| res.resolve(&e.key, e.duration_ms).map(|song| (e, song)))
        .collect();
    let sync_songs: Vec<i64> = resolved.iter().map(|(_, s)| *s).collect();
    if local_songs == sync_songs {
        return Ok(false);
    }

    let mut local_match: Vec<Option<usize>> = vec![None; local_list.len()];
    let mut sync_match: Vec<Option<usize>> = vec![None; resolved.len()];
    for (li, si) in lcs(&local_songs, &sync_songs) {
        local_match[li] = Some(si);
        sync_match[si] = Some(li);
    }

    let mut changed = false;
    let mut restored = Vec::new();
    for (si, (entry, song)) in resolved.iter().enumerate() {
        if sync_match[si].is_some() {
            continue;
        }
        if reappeared.contains(song) {
            restored.push(si);
        } else {
            let mut gone = (*entry).clone();
            gone.deleted = true;
            gone.deleted_hlc = ctx.stamp();
            let seq = ctx.next_seq();
            rows::put_entry(ctx.conn, &gone, seq)?;
            report.stamped += 1;
            changed = true;
        }
    }

    let slots = order_slots(&local_match, &restored);
    let existing: Vec<Option<(&str, &str)>> = slots
        .iter()
        .map(|slot| {
            let si = match *slot {
                Slot::Local(li) => local_match[li]?,
                Slot::Restored(si) => si,
            };
            let e = resolved[si].0;
            Some((e.pos.as_str(), e.uuid.as_str()))
        })
        .collect();
    let positions = assign_positions(&existing);

    for (i, slot) in slots.iter().enumerate() {
        let Some(new_pos) = &positions[i] else {
            continue;
        };
        let matched = match *slot {
            Slot::Local(li) => local_match[li],
            Slot::Restored(si) => Some(si),
        };
        match (matched, *slot) {
            (Some(si), _) => {
                let mut moved = resolved[si].0.clone();
                moved.pos = new_pos.clone();
                moved.pos_hlc = ctx.stamp();
                let seq = ctx.next_seq();
                rows::put_entry(ctx.conn, &moved, seq)?;
            }
            (None, Slot::Local(li)) => {
                let (track, added_at) = local_list[li];
                let Some(t) = res.track(track) else { continue };
                let added_at = added_at.unwrap_or_else(|| now_secs(ctx));
                new_entry(ctx, uuid, t, added_at, new_pos)?;
            }
            (None, Slot::Restored(_)) => continue,
        }
        report.stamped += 1;
        changed = true;
    }

    if !restored.is_empty() {
        let now = now_secs(ctx);
        let list: Vec<(i64, i64)> = slots
            .iter()
            .map(|slot| match *slot {
                Slot::Local(li) => (local_list[li].0, local_list[li].1.unwrap_or(now)),
                Slot::Restored(si) => (resolved[si].1, resolved[si].0.added_at),
            })
            .collect();
        local::rewrite_entries(ctx.conn, playlist_id, &list)?;
        report.local_changed = true;
    }
    Ok(changed)
}

/// The new order: the local list, with re-appeared songs put back right
/// before the local item matched to the next sync entry after them.
fn order_slots(local_match: &[Option<usize>], restored: &[usize]) -> Vec<Slot> {
    let mut slots = Vec::with_capacity(local_match.len() + restored.len());
    let mut next = 0;
    for (li, matched) in local_match.iter().enumerate() {
        if let Some(si) = matched {
            while next < restored.len() && restored[next] < *si {
                slots.push(Slot::Restored(restored[next]));
                next += 1;
            }
        }
        slots.push(Slot::Local(li));
    }
    slots.extend(restored[next..].iter().map(|&si| Slot::Restored(si)));
    slots
}

/// New positions for an ordered list where some items already have one
/// (`(pos, uuid)`). Items on a longest increasing run keep theirs (`None`
/// in the result); the others get positions between their kept
/// neighbours.
fn assign_positions(existing: &[Option<(&str, &str)>]) -> Vec<Option<String>> {
    let mut keep = vec![false; existing.len()];
    for i in lis(existing) {
        keep[i] = true;
    }
    let mut out: Vec<Option<String>> = vec![None; existing.len()];
    let mut lo: Option<&str> = None;
    let mut pending: Vec<usize> = Vec::new();
    for i in 0..existing.len() {
        let anchor = existing[i].filter(|_| keep[i]).map(|(p, _)| p);
        let Some(hi) = anchor else {
            pending.push(i);
            continue;
        };
        // Equal positions (concurrent inserts) leave no room between them:
        // move the right-hand one too.
        if !pending.is_empty() && lo.is_some_and(|l| l >= hi) {
            pending.push(i);
            continue;
        }
        fill(&mut out, &pending, lo, Some(hi));
        pending.clear();
        lo = Some(hi);
    }
    fill(&mut out, &pending, lo, None);
    if out.iter().flatten().any(|p| p.len() > MAX_POS_BYTES) {
        // Pathological growth: re-spread the whole playlist.
        return pos::spread(None, None, existing.len())
            .into_iter()
            .map(Some)
            .collect();
    }
    out
}

fn fill(out: &mut [Option<String>], idx: &[usize], lo: Option<&str>, hi: Option<&str>) {
    for (&i, p) in idx.iter().zip(pos::spread(lo, hi, idx.len())) {
        out[i] = Some(p);
    }
}

fn new_entry(
    ctx: &mut Ctx<'_>,
    playlist_uuid: &str,
    t: &LocalTrack,
    added_at: i64,
    position: &str,
) -> Result<()> {
    let hlc = ctx.stamp();
    let rec = EntryRecord {
        uuid: random_id(ctx.conn)?,
        playlist_uuid: playlist_uuid.to_owned(),
        key: t.key.clone(),
        title: field(&t.title),
        artist: field(&t.artist),
        album: field(&t.album),
        duration_ms: t.duration_ms.filter(|d| *d >= 0),
        added_at,
        pos: position.to_owned(),
        pos_hlc: hlc.clone(),
        deleted: false,
        deleted_hlc: hlc,
    };
    let seq = ctx.next_seq();
    rows::put_entry(ctx.conn, &rec, seq)
}

// --- listening history ----------------------------------------------------

fn listens(ctx: &mut Ctx<'_>, report: &mut CaptureReport) -> Result<()> {
    ctx.conn.execute(
        "UPDATE listen_events SET uid = lower(hex(randomblob(16))) WHERE uid IS NULL",
        [],
    )?;
    let fresh: Vec<ListenRecord> = {
        let mut st = ctx.conn.prepare(
            "SELECT e.uid, e.title, e.artist, e.album, e.genre, e.duration_ms, e.path,
                    e.started_at, e.ended_at, e.listened_ms, e.completed, e.skipped
             FROM listen_events e
             WHERE NOT EXISTS (SELECT 1 FROM sync_listens s WHERE s.uid = e.uid)
             ORDER BY e.id",
        )?;
        let rows = st.query_map([], |r| {
            let title: String = r.get(1)?;
            let artist: String = r.get(2)?;
            let album: String = r.get(3)?;
            Ok(ListenRecord {
                uid: r.get(0)?,
                key: track_key(&artist, &album, &title),
                title: field(&title),
                artist: field(&artist),
                album: field(&album),
                genre: field(&r.get::<_, String>(4)?),
                duration_ms: r.get::<_, Option<i64>>(5)?.filter(|d| *d >= 0),
                path: field(&r.get::<_, String>(6)?),
                started_at: r.get(7)?,
                ended_at: r.get(8)?,
                listened_ms: r.get::<_, i64>(9)?.max(0),
                completed: r.get(10)?,
                skipped: r.get(11)?,
            })
        })?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    for rec in &fresh {
        let seq = ctx.next_seq();
        if rows::insert_listen(ctx.conn, rec, seq)? {
            report.stamped += 1;
        }
    }
    Ok(())
}

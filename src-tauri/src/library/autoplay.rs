//! Autoplay (decision K18): when the queue runs out, pick songs from the
//! library that fit what was just playing, like Spotify's autoplay, but
//! entirely local.
//!
//! Each candidate gets a score from the "seed" songs (the last ones in the
//! queue): a shared artist, artists the user listens to together with the
//! seed artists (from the listening history), the same genre, a near year;
//! favourites and often played songs get a little more, songs played in the
//! last days a little less. Picks are drawn among the best candidates with
//! some randomness so the same list does not come back every time, with at
//! most two songs per artist in one batch. Songs in `exclude` (already
//! played in this session or still queued) are never picked. When nothing
//! is left the caller may clear its played set and ask again.

use std::collections::{HashMap, HashSet};

use rusqlite::Connection;

use super::Result;

/// A picked song, ready for the queue.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutoTrack {
    pub path: String,
    pub title: String,
    pub artist: String,
}

struct Candidate {
    path: String,
    title: String,
    artist: String,
    artists: Vec<String>,
    genre: String,
    year: Option<i64>,
    album_id: Option<i64>,
    plays: i64,
    last_played: Option<i64>,
    favorite: bool,
}

/// Up to `n` songs that fit `seeds` (paths, most recent last).
pub fn pick(
    conn: &Connection,
    seeds: &[String],
    exclude: &HashSet<String>,
    n: usize,
    now: i64,
    random_seed: u64,
) -> Result<Vec<AutoTrack>> {
    let all = candidates(conn)?;
    if n == 0 || all.is_empty() {
        return Ok(Vec::new());
    }
    let by_path: HashMap<&str, &Candidate> = all.iter().map(|c| (c.path.as_str(), c)).collect();

    // What the seeds have in common, the most recent seed counting most.
    let mut seed_artists: HashMap<String, f64> = HashMap::new();
    let mut seed_genres: HashMap<String, f64> = HashMap::new();
    let mut seed_years: Vec<i64> = Vec::new();
    let mut seed_albums: HashSet<i64> = HashSet::new();
    let count = seeds.len();
    for (i, path) in seeds.iter().enumerate() {
        let weight = if i + 1 == count { 1.0 } else { 0.6 };
        let Some(c) = by_path.get(path.as_str()) else {
            continue;
        };
        for a in &c.artists {
            let e = seed_artists.entry(a.clone()).or_default();
            *e = e.max(weight);
        }
        if !c.genre.is_empty() {
            let e = seed_genres.entry(c.genre.clone()).or_default();
            *e = e.max(weight);
        }
        if let Some(y) = c.year {
            seed_years.push(y);
        }
        if let Some(a) = c.album_id {
            seed_albums.insert(a);
        }
    }
    let together = listened_together(conn, &seed_artists, now)?;

    let mut scored: Vec<(f64, &Candidate)> = all
        .iter()
        .filter(|c| !exclude.contains(&c.path) && !seeds.contains(&c.path))
        .map(|c| {
            let mut s = 0.0;
            let shared = c
                .artists
                .iter()
                .filter_map(|a| seed_artists.get(a))
                .fold(0.0_f64, |m, w| m.max(*w));
            s += 4.0 * shared;
            let with = c
                .artists
                .iter()
                .filter_map(|a| together.get(a))
                .fold(0.0_f64, |m, w| m.max(*w));
            s += 3.0 * with;
            if let Some(w) = seed_genres.get(&c.genre) {
                s += 2.5 * w;
            }
            if c.year
                .is_some_and(|y| seed_years.iter().any(|sy| (y - sy).abs() <= 5))
            {
                s += 1.0;
            }
            if c.album_id.is_some_and(|a| seed_albums.contains(&a)) {
                s += 0.5;
            }
            if c.favorite {
                s += 1.0;
            }
            s += 0.5 * (c.plays as f64 / 5.0).min(1.0);
            if c.last_played.is_some_and(|t| now - t < 3 * 86_400) {
                s -= 2.0;
            }
            (s, c)
        })
        .collect();

    // Some randomness among the best, so autoplay does not repeat itself.
    let mut rng = random_seed | 1;
    for (s, _) in &mut scored {
        *s += 1.5 * unit(&mut rng);
    }
    scored.sort_by(|a, b| b.0.total_cmp(&a.0));

    let mut out = Vec::with_capacity(n);
    let mut per_artist: HashMap<&str, usize> = HashMap::new();
    for pass in 0..2 {
        for (_, c) in &scored {
            if out.len() == n {
                break;
            }
            if out.iter().any(|t: &AutoTrack| t.path == c.path) {
                continue;
            }
            let key = c.artists.first().map_or("", String::as_str);
            let used = per_artist.entry(key).or_default();
            // First pass: at most two songs per artist; second: fill up.
            if pass == 0 && *used >= 2 {
                continue;
            }
            *used += 1;
            out.push(AutoTrack {
                path: c.path.clone(),
                title: c.title.clone(),
                artist: c.artist.clone(),
            });
        }
    }
    Ok(out)
}

/// A number in [0, 1) from a splitmix64 step.
fn unit(state: &mut u64) -> f64 {
    *state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut z = *state;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    ((z ^ (z >> 31)) >> 11) as f64 / (1u64 << 53) as f64
}

fn candidates(conn: &Connection) -> Result<Vec<Candidate>> {
    let mut artists: HashMap<i64, Vec<String>> = HashMap::new();
    {
        let mut st =
            conn.prepare("SELECT track_id, artist FROM track_artists ORDER BY track_id, position")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?;
        for row in rows {
            let (id, a) = row?;
            artists.entry(id).or_default().push(a.to_lowercase());
        }
    }
    let mut st = conn.prepare(
        "SELECT t.id, t.path, t.title, t.artist, COALESCE(t.genre, ''), t.year, t.album_id,
                (SELECT COUNT(*) FROM listen_events le
                  WHERE le.track_id = t.id AND (le.completed = 1 OR le.listened_ms >= 15000)),
                (SELECT MAX(le.started_at) FROM listen_events le WHERE le.track_id = t.id),
                EXISTS (SELECT 1 FROM favorites f WHERE f.track_id = t.id)
         FROM tracks t",
    )?;
    let rows = st.query_map([], |r| {
        let id: i64 = r.get(0)?;
        let artist: String = r.get(3)?;
        Ok(Candidate {
            artists: artists
                .get(&id)
                .cloned()
                .unwrap_or_else(|| vec![artist.to_lowercase()]),
            path: r.get(1)?,
            title: r.get(2)?,
            artist,
            genre: r.get::<_, String>(4)?.trim().to_lowercase(),
            year: r.get(5)?,
            album_id: r.get(6)?,
            plays: r.get(7)?,
            last_played: r.get(8)?,
            favorite: r.get(9)?,
        })
    })?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

/// Artists the user played within 45 minutes of a seed artist (last 180
/// days), as a weight in 0..=1 (three such listens count fully).
fn listened_together(
    conn: &Connection,
    seed_artists: &HashMap<String, f64>,
    now: i64,
) -> Result<HashMap<String, f64>> {
    let mut out = HashMap::new();
    if seed_artists.is_empty() {
        return Ok(out);
    }
    let mut st = conn.prepare_cached(
        "SELECT LOWER(b.artist), COUNT(*)
         FROM listen_events a
         JOIN listen_events b
           ON b.started_at BETWEEN a.started_at - 2700 AND a.started_at + 2700
          AND b.id <> a.id
         WHERE a.started_at > ?1 AND LOWER(a.artist) LIKE '%' || ?2 || '%'
           AND LOWER(b.artist) NOT LIKE '%' || ?2 || '%'
         GROUP BY LOWER(b.artist)",
    )?;
    for (seed, weight) in seed_artists {
        let rows = st.query_map(rusqlite::params![now - 180 * 86_400, seed], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
        })?;
        for row in rows {
            let (artist, n) = row?;
            let w = (n as f64 / 3.0).min(1.0) * weight;
            // Listen rows keep the whole artist string ("A, B"); credit each.
            for part in artist
                .split([',', '&'])
                .map(str::trim)
                .filter(|p| !p.is_empty())
            {
                let e = out.entry(part.to_string()).or_insert(0.0_f64);
                *e = e.max(w);
            }
        }
    }
    Ok(out)
}

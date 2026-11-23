//! Track identity across devices: paths differ between a PC and a phone,
//! so a song is identified by a normalised `artist / album / title` key.

use super::Result;
use rusqlite::Connection;
use std::collections::HashMap;

/// Separates the key parts; it cannot occur inside a part (see [`norm`]).
pub const SEP: char = '\u{1f}';
/// Each part is cut to this many bytes so a key always fits the 1 KiB
/// string limit the receiver enforces.
const MAX_PART_BYTES: usize = 300;
/// Fallback matches by artist + title must agree on duration this closely.
const DURATION_SLACK_MS: u64 = 3_000;

/// Unicode lower-case, trimmed, inner whitespace collapsed to one space.
/// The separator character is treated as whitespace so it can never appear
/// inside a part.
pub fn norm(s: &str) -> String {
    let lowered = s.to_lowercase().replace(SEP, " ");
    let joined = lowered.split_whitespace().collect::<Vec<_>>().join(" ");
    truncate_bytes(&joined, MAX_PART_BYTES)
        .trim_end()
        .to_owned()
}

pub fn track_key(artist: &str, album: &str, title: &str) -> String {
    format!("{}{SEP}{}{SEP}{}", norm(artist), norm(album), norm(title))
}

/// `(artist, album, title)` of a key with exactly three parts.
pub fn split_key(key: &str) -> Option<(&str, &str, &str)> {
    let mut parts = key.split(SEP);
    let artist = parts.next()?;
    let album = parts.next()?;
    let title = parts.next()?;
    parts.next().is_none().then_some((artist, album, title))
}

/// True when `key` is exactly what [`track_key`] would produce.
pub fn is_normalized_key(key: &str) -> bool {
    split_key(key).is_some_and(|(a, b, c)| norm(a) == a && norm(b) == b && norm(c) == c)
}

/// The longest prefix of `s` with at most `max` bytes, cut on a character
/// boundary.
pub fn truncate_bytes(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

/// A track present in the local library.
#[derive(Debug, Clone)]
pub struct LocalTrack {
    pub key: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: Option<i64>,
    pub path: String,
}

/// Maps keys to local tracks. Built once per operation from the `tracks`
/// table so capture, merge and materialise all agree on every resolution.
///
/// Every track has a *canonical* id: the smallest id among the tracks with
/// the same key. Resolution always returns canonical ids, so duplicates of
/// one song (two files with identical tags) count as one song.
#[derive(Debug, Default)]
pub struct Resolver {
    tracks: HashMap<i64, LocalTrack>,
    by_key: HashMap<String, i64>,
    /// `(norm artist, norm title)` -> ids in ascending order.
    by_artist_title: HashMap<(String, String), Vec<i64>>,
}

impl Resolver {
    pub fn load(conn: &Connection) -> Result<Self> {
        let mut st = conn.prepare(
            "SELECT t.id, t.title, t.artist, COALESCE(a.title, ''), t.duration_ms, t.path
             FROM tracks t LEFT JOIN albums a ON a.id = t.album_id
             ORDER BY t.id",
        )?;
        let rows = st.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, Option<i64>>(4)?,
                r.get::<_, String>(5)?,
            ))
        })?;
        let mut res = Self::default();
        for row in rows {
            let (id, title, artist, album, duration_ms, path) = row?;
            let key = track_key(&artist, &album, &title);
            // Rows come in id order, so the first id seen per key is the
            // smallest one.
            res.by_key.entry(key.clone()).or_insert(id);
            res.by_artist_title
                .entry((norm(&artist), norm(&title)))
                .or_default()
                .push(id);
            res.tracks.insert(
                id,
                LocalTrack {
                    key,
                    title,
                    artist,
                    album,
                    duration_ms,
                    path,
                },
            );
        }
        Ok(res)
    }

    pub fn track(&self, id: i64) -> Option<&LocalTrack> {
        self.tracks.get(&id)
    }

    pub fn track_ids(&self) -> impl Iterator<Item = i64> + '_ {
        self.tracks.keys().copied()
    }

    /// The canonical id of a present track.
    pub fn canon(&self, id: i64) -> Option<i64> {
        let key = &self.tracks.get(&id)?.key;
        self.by_key.get(key).copied()
    }

    /// The local song a synced record refers to: (1) the exact key; (2) the
    /// first (smallest id) track with the same artist and title whose
    /// duration is within 3 s when both are known.
    pub fn resolve(&self, key: &str, duration_ms: Option<i64>) -> Option<i64> {
        if let Some(&id) = self.by_key.get(key) {
            return Some(id);
        }
        let (artist, _, title) = split_key(key)?;
        let candidates = self
            .by_artist_title
            .get(&(artist.to_owned(), title.to_owned()))?;
        let found = candidates.iter().copied().find(|id| {
            let theirs = self.tracks.get(id).and_then(|t| t.duration_ms);
            match (duration_ms, theirs) {
                (Some(a), Some(b)) => a.abs_diff(b) <= DURATION_SLACK_MS,
                _ => true,
            }
        })?;
        self.canon(found)
    }
}

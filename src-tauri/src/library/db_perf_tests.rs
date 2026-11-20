//! The optimised queries (songs pages, artist directory and profile, home
//! feed, listening stats) must return exactly what the straightforward
//! versions they replaced returned. The old SQL is kept here as the
//! reference and compared on a seeded library with two profiles.

use super::*;
use crate::library::{Hooks, Library};
use rusqlite::params;

const P1: ProfileId = ProfileId(1);

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        self.0 >> 33
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

const NOW: i64 = 1_800_000_000;
const DAY: i64 = 86_400;

fn p2() -> ProfileId {
    ProfileId(2)
}

/// 300 tracks (compound artists, some without album, NULL durations, shared
/// titles, upper/lower-case variants), 24 albums, two profiles with ~4 000
/// listens over 400 days, a few of them with a lost `track_id`.
fn seeded() -> (tempfile::TempDir, Library) {
    let tmp = tempfile::tempdir().unwrap();
    let lib = Library::open(
        &tmp.path().join("l.sqlite3"),
        &tmp.path().join("covers"),
        Hooks::none(),
    )
    .unwrap();
    {
        let mut conn = lib.conn();
        let tx = conn.transaction().unwrap();
        tx.execute(
            "INSERT INTO profiles(id, name, color, created_at) VALUES (2, 'Second', 'blue', 1)",
            [],
        )
        .unwrap();
        tx.execute("INSERT INTO folders(id, path) VALUES (1, '/m')", [])
            .unwrap();
        for a in 1..=24 {
            tx.execute(
                "INSERT INTO albums(id, title, album_artist, year, cover) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    a,
                    format!("Album {}", a % 17),
                    format!("Band {}", a % 9),
                    2000 + a % 11,
                    if a % 3 == 0 { None } else { Some(format!("cover{a}.jpg")) },
                ],
            )
            .unwrap();
        }
        let mut rng = Rng(7);
        for id in 1..=300i64 {
            let artist = match id % 7 {
                0 => format!("Band {} feat. Guest {}", id % 9, id % 4),
                1 => format!("band {}", id % 9),
                _ => format!("Band {}", id % 9),
            };
            let album = if id % 10 == 0 {
                None
            } else {
                Some(1 + id % 24)
            };
            let duration = if id % 13 == 0 {
                None
            } else {
                Some(100_000 + (rng.below(40) as i64) * 7_000)
            };
            let genre = ["Rock", "rock ", "Jazz", "Pop", ""][(id % 5) as usize];
            tx.execute(
                "INSERT INTO tracks(id, folder_id, path, mtime, size, title, artist, album_id,
                                    track_no, disc_no, year, duration_ms, genre, added_at)
                 VALUES (?1, 1, ?2, 1, 1, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![
                    id,
                    format!("/m/{id}.flac"),
                    format!("Song {}", id % 40),
                    artist,
                    album,
                    1 + id % 12,
                    1 + id % 2,
                    2000 + id % 20,
                    duration,
                    genre,
                    1_000 + (id % 50) * 10,
                ],
            )
            .unwrap();
            sync_track_artists(&tx, id, &artist).unwrap();
        }
        for i in 0..4_000i64 {
            let profile = if i % 3 == 0 { 2 } else { 1 };
            let tid = 1 + rng.below(300) as i64;
            let lost = i % 41 == 0;
            let title = if i % 5 == 0 {
                format!("SONG {}", tid % 40)
            } else {
                format!("Song {}", tid % 40)
            };
            let artist = format!("Band {}", tid % 9);
            let started = NOW - (rng.below(400 * DAY as u64) as i64);
            let listened = [2_000, 9_000, 16_000, 40_000, 200_000][rng.below(5) as usize];
            tx.execute(
                "INSERT INTO listen_events(track_id, path, title, artist, album, genre, duration_ms,
                                           started_at, ended_at, listened_ms, completed, skipped,
                                           source, uid, profile_id)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 200000, ?7, ?8, ?9, ?10, ?11, 'local', ?12, ?13)",
                params![
                    if lost { None } else { Some(tid) },
                    if i % 97 == 0 { "/gone.mp3".to_string() } else { format!("/m/{tid}.flac") },
                    title,
                    artist,
                    format!("Album {}", tid % 17),
                    ["Rock", "Jazz", "Pop", ""][(tid % 4) as usize],
                    started,
                    started + 100,
                    listened,
                    i64::from(listened >= 200_000 || i % 11 == 0),
                    i64::from(listened < 9_000),
                    format!("u{i}"),
                    profile,
                ],
            )
            .unwrap();
        }
        for (f, p) in [(1, 1), (5, 1), (9, 1), (12, 2), (33, 1), (34, 1)] {
            tx.execute(
                "INSERT INTO favorites(profile_id, track_id, added_at) VALUES (?1, ?2, ?3)",
                params![p, f, f * 10],
            )
            .unwrap();
        }
        tx.commit().unwrap();
    }
    (tmp, lib)
}

// ------------------------------------------------------------------ songs

#[test]
fn songs_pages_match_the_plain_query_for_every_sort_offset_and_filter() {
    let (_t, lib) = seeded();
    let conn = lib.conn();
    for profile in [P1, p2()] {
        for order in [
            SortOrder::Artist,
            SortOrder::Title,
            SortOrder::Album,
            SortOrder::Added,
            SortOrder::Duration,
        ] {
            for dir in [SortDir::Asc, SortDir::Desc] {
                let spec = SortSpec::new(order, dir);
                for query in ["", "song 1", "band"] {
                    for offset in [0u64, 1, 37, 150, 290, 299, 400] {
                        let got =
                            search_tracks_page(&conn, profile, offset, 25, spec, query).unwrap();
                        let f = track_filter(query);
                        let n = f.params.len();
                        let ts = track_select(profile);
                        let sql = format!(
                            "{ts} {} ORDER BY {} LIMIT ?{} OFFSET ?{}",
                            f.where_sql,
                            spec.order_by(),
                            n + 1,
                            n + 2
                        );
                        let count_sql = format!(
                            "SELECT COUNT(*) FROM tracks t LEFT JOIN albums a ON a.id = t.album_id {}",
                            f.where_sql
                        );
                        let want =
                            query_page(&conn, &count_sql, &sql, f.params, offset, 25, track_row)
                                .unwrap();
                        assert_eq!(got.total, want.total);
                        assert_eq!(
                            got.items, want.items,
                            "profile {profile:?} {order:?} {dir:?} q={query:?} @{offset}"
                        );
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------- artists

fn artists_page_reference(
    conn: &Connection,
    profile: ProfileId,
    offset: u64,
    limit: u64,
    query: &str,
) -> Vec<ArtistRow> {
    let f = build_filter(query, |i| format!("ta.artist LIKE ?{i} ESCAPE '\\'"));
    let n = f.params.len();
    let pr = profile.0;
    let sql = format!(
        "SELECT MIN(ta.artist),
                COUNT(DISTINCT ta.track_id) AS tracks_n,
                COUNT(DISTINCT t.album_id) AS albums_n,
                COALESCE(MAX(am.image), MAX(a.cover)),
                COALESCE((SELECT SUM({PLAY_EXPR}) FROM listen_events e
                          WHERE e.profile_id = {pr} AND e.artist = ta.artist COLLATE NOCASE), 0),
                COALESCE((SELECT SUM(e.listened_ms) FROM listen_events e
                          WHERE e.profile_id = {pr} AND e.artist = ta.artist COLLATE NOCASE), 0)
         FROM track_artists ta
         JOIN tracks t ON t.id = ta.track_id
         LEFT JOIN albums a ON a.id = t.album_id
         LEFT JOIN artists_meta am ON am.name_key = ta.artist
         {}
         GROUP BY ta.artist
         ORDER BY MIN(ta.artist) COLLATE NOCASE
         LIMIT ?{} OFFSET ?{}",
        f.where_sql,
        n + 1,
        n + 2
    );
    let mut values: Vec<Value> = f.params.into_iter().map(Value::Text).collect();
    values.push(Value::Integer(limit as i64));
    values.push(Value::Integer(offset as i64));
    let mut st = conn.prepare(&sql).unwrap();
    st.query_map(params_from_iter(values.iter()), |r| {
        Ok(ArtistRow {
            name: r.get(0)?,
            track_count: r.get::<_, i64>(1)?.max(0) as u32,
            album_count: r.get::<_, i64>(2)?.max(0) as u32,
            cover: r.get(3)?,
            play_count: u64_col(r, 4)?,
            listened_ms: u64_col(r, 5)?,
        })
    })
    .unwrap()
    .collect::<rusqlite::Result<_>>()
    .unwrap()
}

#[test]
fn artist_directory_matches_the_plain_query_at_every_offset() {
    let (_t, lib) = seeded();
    let conn = lib.conn();
    for profile in [P1, p2()] {
        for query in ["", "band", "guest", "zzz", "1"] {
            for offset in [0u64, 1, 3, 7, 12, 40] {
                let got = search_artists_page(&conn, profile, offset, 5, query).unwrap();
                let want = artists_page_reference(&conn, profile, offset, 5, query);
                assert_eq!(got.items, want, "{profile:?} q={query:?} @{offset}");
            }
        }
    }
}

#[test]
fn artist_profile_totals_match_the_plain_query() {
    let (_t, lib) = seeded();
    let conn = lib.conn();
    for profile in [P1, p2()] {
        let pr = profile.0;
        for name in ["Band 3", "band 0", "Guest 2", "Nobody"] {
            let got = artist_profile(&conn, profile, name).unwrap();
            let (plays, ms): (u64, u64) = conn
                .query_row(
                    &format!(
                        "SELECT COALESCE(SUM({PLAY_EXPR}), 0), COALESCE(SUM(e.listened_ms), 0)
                         FROM listen_events e
                         WHERE e.profile_id = {pr}
                           AND (e.artist = ?1 COLLATE NOCASE
                            OR EXISTS (
                                SELECT 1 FROM track_artists ta
                                WHERE ta.track_id = e.track_id AND ta.artist = ?1 COLLATE NOCASE
                            ))"
                    ),
                    [name],
                    |r| Ok((u64_col(r, 0)?, u64_col(r, 1)?)),
                )
                .unwrap();
            assert_eq!((got.play_count, got.listened_ms), (plays, ms), "{name}");
        }
    }
}

// ------------------------------------------------------------------- home

fn ids(tracks: &[TrackRow]) -> Vec<i64> {
    tracks.iter().map(|t| t.id).collect()
}

#[test]
fn recently_played_matches_the_grouped_queries() {
    let (_t, lib) = seeded();
    let conn = lib.conn();
    for profile in [P1, p2()] {
        let pr = profile.0;
        for limit in [1i64, 8, 12, 500] {
            let got = recently_played_tracks(&conn, profile, limit).unwrap();
            let mut st = conn
                .prepare(&format!(
                    "SELECT t.id, MAX(e.started_at) AS last_started
                     FROM listen_events e
                     LEFT JOIN tracks tp ON e.track_id IS NULL AND tp.path = e.path
                     JOIN tracks t ON t.id = COALESCE(e.track_id, tp.id)
                     WHERE e.profile_id = {pr} AND {PLAY_EXPR} = 1
                     GROUP BY t.id ORDER BY last_started DESC, t.id DESC LIMIT ?1"
                ))
                .unwrap();
            let want: Vec<(i64, i64)> = st
                .query_map([limit], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap()
                .collect::<rusqlite::Result<_>>()
                .unwrap();
            let got: Vec<(i64, i64)> = got.iter().map(|r| (r.track.id, r.started_at)).collect();
            assert_eq!(got, want, "tracks {profile:?} limit {limit}");

            let got = recently_played_albums(&conn, profile, limit).unwrap();
            let mut st = conn
                .prepare(&format!(
                    "SELECT a.id
                     FROM listen_events e
                     LEFT JOIN tracks tp ON e.track_id IS NULL AND tp.path = e.path
                     JOIN tracks t ON t.id = COALESCE(e.track_id, tp.id)
                     JOIN albums a ON a.id = t.album_id
                     WHERE e.profile_id = {pr} AND {PLAY_EXPR} = 1
                     GROUP BY a.id ORDER BY MAX(e.started_at) DESC, a.id DESC LIMIT ?1"
                ))
                .unwrap();
            let want: Vec<i64> = st
                .query_map([limit], |r| r.get(0))
                .unwrap()
                .collect::<rusqlite::Result<_>>()
                .unwrap();
            let got: Vec<i64> = got.iter().map(|a| a.id).collect();
            assert_eq!(got, want, "albums {profile:?} limit {limit}");
        }
    }
}

#[test]
fn rediscover_matches_the_per_track_exists_query() {
    let (_t, lib) = seeded();
    let conn = lib.conn();
    for profile in [P1, p2()] {
        let pr = profile.0;
        let cutoff = NOW - 30 * SECS_PER_DAY;
        let ts = track_select(profile);
        let mut st = conn
            .prepare(&format!(
                "{ts}
                 WHERE (
                     EXISTS (SELECT 1 FROM favorites f WHERE f.track_id = t.id AND f.profile_id = {pr})
                     OR EXISTS (
                         SELECT 1 FROM listen_events e
                         WHERE e.profile_id = {pr} AND (e.track_id = t.id OR (e.track_id IS NULL AND e.path = t.path))
                           AND (e.completed = 1 OR e.listened_ms >= 30000)
                     )
                 )
                 AND NOT EXISTS (
                     SELECT 1 FROM listen_events e
                     WHERE e.profile_id = {pr} AND (e.track_id = t.id OR (e.track_id IS NULL AND e.path = t.path))
                       AND e.started_at >= ?1
                       AND {PLAY_EXPR} = 1
                 )"
            ))
            .unwrap();
        let mut want = st
            .query_map([cutoff], track_row)
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap();
        let seed = NOW.div_euclid(SECS_PER_DAY);
        want.sort_by_key(|t| daily_rank(t.id, seed));
        want.truncate(MIX_LIMIT as usize);
        let got = rediscover_tracks(&conn, profile, NOW).unwrap();
        assert!(!want.is_empty());
        assert_eq!(got, want, "{profile:?}");
    }
}

#[test]
fn focus_mix_matches_the_per_track_score_query() {
    let (_t, lib) = seeded();
    let conn = lib.conn();
    for profile in [P1, p2()] {
        let pr = profile.0;
        let since = NOW - 14 * SECS_PER_DAY;
        // Recent plays are needed for the focus mix: add some in the window.
        for i in 0..60i64 {
            conn.execute(
                "INSERT INTO listen_events(track_id, path, title, artist, album, genre, duration_ms,
                                           started_at, ended_at, listened_ms, completed, skipped,
                                           source, uid, profile_id)
                 VALUES (?1, ?2, 'x', 'Band 3', '', '', 1, ?3, ?3, 50000, 1, 0, 'local', ?4, ?5)",
                params![
                    3 + (i % 20) * 9,
                    format!("/m/{}.flac", 3 + (i % 20) * 9),
                    NOW - 1_000 - i * 300,
                    format!("focus{pr}-{i}"),
                    pr
                ],
            )
            .unwrap();
        }
        let got = focus_mix_data(&conn, profile, NOW)
            .unwrap()
            .expect("a focus mix");
        let ts = track_select(profile);
        let mut st = conn
            .prepare(&format!(
                "{ts}
                 WHERE EXISTS (
                     SELECT 1 FROM track_artists ta
                     WHERE ta.track_id = t.id AND ta.artist = ?1 COLLATE NOCASE
                 )
                 ORDER BY COALESCE((
                     SELECT SUM(e.completed * 2 + e.listened_ms / 30000.0 - e.skipped)
                     FROM listen_events e
                     WHERE e.profile_id = {pr}
                       AND (e.track_id = t.id OR (e.track_id IS NULL AND e.path = t.path))
                       AND e.started_at >= ?2
                 ), 0) DESC, t.added_at DESC, t.id ASC
                 LIMIT ?3"
            ))
            .unwrap();
        let want = st
            .query_map(params![&got.0, since, MIX_LIMIT], track_row)
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap();
        assert_eq!(ids(&got.1), ids(&want), "{profile:?} {}", got.0);
        assert_eq!(got.1, want);
    }
}

// ------------------------------------------------------------------ stats

#[test]
fn listening_stats_match_the_reference_for_every_period() {
    let (_t, lib) = seeded();
    let conn = lib.conn();
    let now = NOW;
    let periods: [(Option<i64>, Option<i64>); 8] = [
        (None, None),
        (Some(now - 7 * DAY), Some(now + DAY)),
        (Some(now - 30 * DAY), Some(now + DAY)),
        (Some(now - 90 * DAY), Some(now + DAY)),
        (Some(now - 320 * DAY), Some(now + DAY)),
        (Some(now - 685 * DAY), Some(now - 320 * DAY)),
        (Some(now + 10 * DAY), Some(now + 20 * DAY)),
        (None, Some(now - 200 * DAY)),
    ];
    for profile in [P1, p2()] {
        for (from, to) in periods {
            let mut got = listening_stats(&conn, profile, from, to, 10).unwrap();
            let mut want =
                stats_reference::listening_stats_ref(&conn, profile, from, to, 10).unwrap();
            // A group's display name is `MAX(name)` under NOCASE; spellings that
            // differ only in case tie, and which one wins depended on the scan
            // order of the old plan. Compare those names case-insensitively.
            for st in [&mut got, &mut want] {
                for t in st
                    .top_tracks_by_plays
                    .iter_mut()
                    .chain(st.top_tracks_by_time.iter_mut())
                {
                    t.title = t.title.to_lowercase();
                    t.artist = t.artist.to_lowercase();
                    t.album = t.album.to_lowercase();
                }
                for a in &mut st.top_artists_by_time {
                    a.artist = a.artist.to_lowercase();
                }
                for a in &mut st.top_albums_by_time {
                    a.album = a.album.to_lowercase();
                    a.artist = a.artist.to_lowercase();
                }
                for g in &mut st.top_genres {
                    g.genre = g.genre.to_lowercase();
                }
            }
            assert_eq!(got, want, "{profile:?} {from:?}..{to:?}");
        }
    }
    // Nothing left behind on the connection.
    let leftovers: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_temp_master WHERE name LIKE 'stats_%'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(leftovers, 0);
}

#[test]
fn year_and_month_of_day_match_sqlite() {
    let conn = Connection::open_in_memory().unwrap();
    for day in [
        -800, -1, 0, 1, 58, 59, 60, 365, 11_016, 11_017, 19_000, 20_500, 47_000,
    ] {
        let (y, m): (i64, u32) = conn
            .query_row(
                "SELECT CAST(strftime('%Y', ?1 * 86400, 'unixepoch') AS INTEGER),
                        CAST(strftime('%m', ?1 * 86400, 'unixepoch') AS INTEGER)",
                [day],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(year_month_of_day(day), (y, m), "day {day}");
    }
}

#[test]
fn weekly_and_on_repeat_match_the_joined_queries() {
    let (_t, lib) = seeded();
    let conn = lib.conn();
    for profile in [P1, p2()] {
        let pr = profile.0;
        let cols = "SELECT t.id, t.title, t.artist, COALESCE(a.title, ''), t.album_id,
                t.track_no, t.disc_no, t.year, t.duration_ms, t.path, a.cover";
        let weekly = format!(
            "{cols}
             FROM listen_events e
             LEFT JOIN tracks tp ON e.track_id IS NULL AND tp.path = e.path
             JOIN tracks t ON t.id = COALESCE(e.track_id, tp.id)
             LEFT JOIN albums a ON a.id = t.album_id
             WHERE e.profile_id = {pr} AND e.started_at >= ?1
             GROUP BY t.id
             HAVING SUM(e.completed * 3.0 + MIN(e.listened_ms, 600000) / 30000.0 - e.skipped * 2.0) > 0
               AND SUM({PLAY_EXPR}) >= 1
             ORDER BY SUM(e.completed * 3.0 + MIN(e.listened_ms, 600000) / 30000.0 - e.skipped * 2.0) DESC,
                      MAX(e.started_at) DESC, t.id ASC
             LIMIT ?2"
        );
        let on_repeat = format!(
            "{cols}
             FROM listen_events e
             LEFT JOIN tracks tp ON e.track_id IS NULL AND tp.path = e.path
             JOIN tracks t ON t.id = COALESCE(e.track_id, tp.id)
             LEFT JOIN albums a ON a.id = t.album_id
             WHERE e.profile_id = {pr} AND e.started_at >= ?1
             GROUP BY t.id
             HAVING SUM({PLAY_EXPR}) >= 2
             ORDER BY SUM({PLAY_EXPR}) DESC, SUM(e.listened_ms) DESC, MAX(e.started_at) DESC, t.id ASC
             LIMIT ?2"
        );
        for (name, sql, days) in [("weekly", weekly, 7), ("on repeat", on_repeat, 30)] {
            let since = NOW - days * SECS_PER_DAY;
            let mut st = conn.prepare(&sql).unwrap();
            let want = st
                .query_map(params![since, MIX_LIMIT], track_row)
                .unwrap()
                .collect::<rusqlite::Result<Vec<_>>>()
                .unwrap();
            let got = if name == "weekly" {
                weekly_favorites_tracks(&conn, profile, NOW)
            } else {
                on_repeat_tracks(&conn, profile, NOW)
            }
            .unwrap();
            assert!(!want.is_empty(), "{name} {profile:?}");
            assert_eq!(got, want, "{name} {profile:?}");
        }
    }
}

//! The pre-optimisation statistics queries, kept verbatim as the reference
//! the optimised `listening_stats` must match (see `stats_tests`).

use super::super::ListeningStats;
use super::super::profiles::ProfileId;
use super::super::{
    BucketStat, RecentListen, Result, StatsSummary, TopAlbumStat, TopArtistStat, TopGenreStat,
    TopTrackStat,
};
use super::{PLAY_EXPR, u64_col};
use rusqlite::Connection;

fn listen_range_ref(profile: ProfileId) -> String {
    format!(
        "e.profile_id = {} AND (?1 IS NULL OR e.started_at >= ?1) AND (?2 IS NULL OR e.started_at < ?2)",
        profile.0
    )
}
fn query_top_tracks_ref(
    conn: &Connection,
    profile: ProfileId,
    from: Option<i64>,
    to: Option<i64>,
    order_by_time: bool,
    limit: usize,
) -> Result<Vec<TopTrackStat>> {
    let order = if order_by_time {
        "total_ms DESC, plays DESC, MIN(e.title) COLLATE NOCASE"
    } else {
        "plays DESC, total_ms DESC, MIN(e.title) COLLATE NOCASE"
    };
    let having = if order_by_time {
        ""
    } else {
        "HAVING plays > 0"
    };
    let range = listen_range_ref(profile);
    let sql = format!(
        "SELECT MAX(e.track_id), MAX(e.path), MAX(e.title), MAX(e.artist),
                MAX(e.album), MAX(a.cover),
                SUM({PLAY_EXPR}) AS plays,
                SUM(e.listened_ms) AS total_ms,
                SUM(e.skipped) AS skips
         FROM listen_events e
         LEFT JOIN tracks t ON t.id = e.track_id
         LEFT JOIN albums a ON a.id = t.album_id
         WHERE {range}
         GROUP BY LOWER(e.title), LOWER(e.artist)
         {having}
         ORDER BY {order}
         LIMIT ?3"
    );
    let mut st = conn.prepare(&sql)?;
    let rows = st.query_map(rusqlite::params![from, to, limit as i64], |r| {
        Ok(TopTrackStat {
            track_id: r.get(0)?,
            path: r.get(1)?,
            title: r.get(2)?,
            artist: r.get(3)?,
            album: r.get(4)?,
            cover: r.get(5)?,
            play_count: u64_col(r, 6)?,
            listened_ms: u64_col(r, 7)?,
            skip_count: u64_col(r, 8)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

fn streak_stats_ref(
    conn: &Connection,
    profile: ProfileId,
    from: Option<i64>,
    to: Option<i64>,
) -> Result<(u64, u64, u64)> {
    let range = listen_range_ref(profile);
    let sql = format!(
        "SELECT DISTINCT
             CAST(
                 julianday(e.started_at, 'unixepoch', 'localtime', 'start of day') + 0.5
                 AS INTEGER
             ) AS d
         FROM listen_events e
         WHERE {range}
         ORDER BY d ASC"
    );
    let mut st = conn.prepare(&sql)?;
    let days: Vec<i64> = st
        .query_map(rusqlite::params![from, to], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    if days.is_empty() {
        return Ok((0, 0, 0));
    }
    let today: i64 = conn.query_row(
        "SELECT CAST(julianday('now', 'localtime', 'start of day') + 0.5 AS INTEGER)",
        [],
        |r| r.get(0),
    )?;
    let mut longest = 1u64;
    let mut run = 1u64;
    for pair in days.windows(2) {
        if pair[1] == pair[0] + 1 {
            run += 1;
            longest = longest.max(run);
        } else {
            run = 1;
        }
    }
    let last_day = *days.last().unwrap_or(&0);
    let current = if last_day == today || last_day == today - 1 {
        run
    } else {
        0
    };
    Ok((days.len() as u64, longest, current))
}

pub fn listening_stats_ref(
    conn: &Connection,
    profile: ProfileId,
    from: Option<i64>,
    to: Option<i64>,
    limit: usize,
) -> Result<ListeningStats> {
    let range = listen_range_ref(profile);
    let summary_sql = format!(
        "SELECT COALESCE(SUM(e.listened_ms), 0),
                COALESCE(SUM({PLAY_EXPR}), 0),
                COUNT(*),
                COALESCE(SUM(e.skipped), 0),
                COALESCE(SUM(e.completed), 0),
                COUNT(DISTINCT LOWER(e.title) || char(0) || LOWER(e.artist)),
                COUNT(DISTINCT CASE WHEN TRIM(e.artist) != '' THEN LOWER(e.artist) END),
                COUNT(DISTINCT CASE WHEN TRIM(e.album) != '' THEN LOWER(e.album) END),
                MIN(e.started_at)
         FROM listen_events e
         WHERE {range}"
    );
    let (
        total_listened_ms,
        play_count,
        raw_event_count,
        skip_count,
        completed_count,
        unique_tracks,
        unique_artists,
        unique_albums,
        first_listen_at,
    ) = conn.query_row(&summary_sql, rusqlite::params![from, to], |r| {
        Ok((
            u64_col(r, 0)?,
            u64_col(r, 1)?,
            u64_col(r, 2)?,
            u64_col(r, 3)?,
            u64_col(r, 4)?,
            u64_col(r, 5)?,
            u64_col(r, 6)?,
            u64_col(r, 7)?,
            r.get::<_, Option<i64>>(8)?,
        ))
    })?;

    let (active_days, longest_streak_days, current_streak_days) =
        streak_stats_ref(conn, profile, from, to)?;

    let top_tracks_by_plays = query_top_tracks_ref(conn, profile, from, to, false, limit)?;
    let top_tracks_by_time = query_top_tracks_ref(conn, profile, from, to, true, limit)?;

    let artist_sql = format!(
        "SELECT MAX(e.artist), MAX(a.cover),
                SUM({PLAY_EXPR}) AS plays,
                SUM(e.listened_ms) AS total_ms,
                COUNT(DISTINCT LOWER(e.title)) AS uniq,
                SUM(e.skipped) AS skips
         FROM listen_events e
         LEFT JOIN tracks t ON t.id = e.track_id
         LEFT JOIN albums a ON a.id = t.album_id
         WHERE {range} AND TRIM(e.artist) != ''
         GROUP BY LOWER(e.artist)
         ORDER BY total_ms DESC, plays DESC, MAX(e.artist) COLLATE NOCASE
         LIMIT ?3"
    );
    let mut artist_st = conn.prepare(&artist_sql)?;
    let top_artists_by_time = artist_st
        .query_map(rusqlite::params![from, to, limit as i64], |r| {
            Ok(TopArtistStat {
                artist: r.get(0)?,
                cover: r.get(1)?,
                play_count: u64_col(r, 2)?,
                listened_ms: u64_col(r, 3)?,
                unique_tracks: u64_col(r, 4)?,
                skip_count: u64_col(r, 5)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let album_sql = format!(
        "SELECT MAX(e.album), MAX(e.artist), MAX(t.album_id), MAX(a.cover),
                SUM({PLAY_EXPR}) AS plays,
                SUM(e.listened_ms) AS total_ms
         FROM listen_events e
         LEFT JOIN tracks t ON t.id = e.track_id
         LEFT JOIN albums a ON a.id = t.album_id
         WHERE {range} AND TRIM(e.album) != ''
         GROUP BY LOWER(e.album)
         ORDER BY total_ms DESC, plays DESC, MAX(e.album) COLLATE NOCASE
         LIMIT ?3"
    );
    let mut album_st = conn.prepare(&album_sql)?;
    let top_albums_by_time = album_st
        .query_map(rusqlite::params![from, to, limit as i64], |r| {
            Ok(TopAlbumStat {
                album: r.get(0)?,
                artist: r.get(1)?,
                album_id: r.get(2)?,
                cover: r.get(3)?,
                play_count: u64_col(r, 4)?,
                listened_ms: u64_col(r, 5)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let genre_sql = format!(
        "SELECT MAX(e.genre), SUM({PLAY_EXPR}) AS plays, SUM(e.listened_ms) AS total_ms
         FROM listen_events e
         WHERE {range} AND TRIM(e.genre) != ''
         GROUP BY LOWER(e.genre)
         ORDER BY total_ms DESC, plays DESC, MAX(e.genre) COLLATE NOCASE
         LIMIT ?3"
    );
    let mut genre_st = conn.prepare(&genre_sql)?;
    let top_genres = genre_st
        .query_map(rusqlite::params![from, to, limit as i64], |r| {
            Ok(TopGenreStat {
                genre: r.get(0)?,
                play_count: u64_col(r, 1)?,
                listened_ms: u64_col(r, 2)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let mut by_hour: Vec<BucketStat> = (0..24)
        .map(|h| BucketStat {
            label: format!("{h:02}"),
            listened_ms: 0,
            play_count: 0,
        })
        .collect();
    let hour_sql = format!(
        "SELECT CAST(strftime('%H', e.started_at, 'unixepoch', 'localtime') AS INTEGER) AS h,
                SUM(e.listened_ms), SUM({PLAY_EXPR})
         FROM listen_events e
         WHERE {range}
         GROUP BY h"
    );
    let mut hour_st = conn.prepare(&hour_sql)?;
    let hour_rows = hour_st.query_map(rusqlite::params![from, to], |r| {
        Ok((r.get::<_, i64>(0)?, u64_col(r, 1)?, u64_col(r, 2)?))
    })?;
    for row in hour_rows {
        let (h, ms, plays) = row?;
        if let Ok(idx) = usize::try_from(h)
            && idx < 24
        {
            by_hour[idx].listened_ms = ms;
            by_hour[idx].play_count = plays;
        }
    }
    let top_hour = by_hour
        .iter()
        .enumerate()
        .filter(|(_, b)| b.listened_ms > 0)
        .max_by_key(|(_, b)| b.listened_ms)
        .map(|(idx, _)| idx as u32);

    let mut by_weekday: Vec<BucketStat> = (0..7)
        .map(|w| BucketStat {
            label: w.to_string(),
            listened_ms: 0,
            play_count: 0,
        })
        .collect();
    let wday_sql = format!(
        "SELECT CAST(strftime('%w', e.started_at, 'unixepoch', 'localtime') AS INTEGER) AS w,
                SUM(e.listened_ms), SUM({PLAY_EXPR})
         FROM listen_events e
         WHERE {range}
         GROUP BY w"
    );
    let mut wday_st = conn.prepare(&wday_sql)?;
    let wday_rows = wday_st.query_map(rusqlite::params![from, to], |r| {
        Ok((r.get::<_, i64>(0)?, u64_col(r, 1)?, u64_col(r, 2)?))
    })?;
    for row in wday_rows {
        let (w, ms, plays) = row?;
        // Convert SQLite %w (0 = Sun .. 6 = Sat) to Monday-first (0 = Mon .. 6 = Sun).
        let idx = ((w.rem_euclid(7) + 6) % 7) as usize;
        by_weekday[idx].listened_ms = ms;
        by_weekday[idx].play_count = plays;
    }
    let top_weekday = by_weekday
        .iter()
        .enumerate()
        .filter(|(_, b)| b.listened_ms > 0)
        .max_by_key(|(_, b)| b.listened_ms)
        .map(|(idx, _)| idx as u32);

    let month_sql = format!(
        "SELECT m, total_ms, plays FROM (
             SELECT strftime('%Y-%m', e.started_at, 'unixepoch', 'localtime') AS m,
                    SUM(e.listened_ms) AS total_ms,
                    SUM({PLAY_EXPR}) AS plays
             FROM listen_events e
             WHERE {range}
             GROUP BY m
             ORDER BY m DESC
             LIMIT 24
         ) ORDER BY m ASC"
    );
    let mut month_st = conn.prepare(&month_sql)?;
    let by_month = month_st
        .query_map(rusqlite::params![from, to], |r| {
            Ok(BucketStat {
                label: r.get(0)?,
                listened_ms: u64_col(r, 1)?,
                play_count: u64_col(r, 2)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let recent_sql = format!(
        "SELECT e.id, e.track_id, e.path, e.title, e.artist, e.album, a.cover,
                e.started_at, e.listened_ms, e.completed, e.skipped, e.source
         FROM listen_events e
         LEFT JOIN tracks t ON t.id = e.track_id
         LEFT JOIN albums a ON a.id = t.album_id
         WHERE {range}
         ORDER BY e.started_at DESC, e.id DESC
         LIMIT 50"
    );
    let mut recent_st = conn.prepare(&recent_sql)?;
    let recent = recent_st
        .query_map(rusqlite::params![from, to], |r| {
            Ok(RecentListen {
                id: r.get(0)?,
                track_id: r.get(1)?,
                path: r.get(2)?,
                title: r.get(3)?,
                artist: r.get(4)?,
                album: r.get(5)?,
                cover: r.get(6)?,
                started_at: r.get(7)?,
                listened_ms: u64_col(r, 8)?,
                completed: r.get::<_, i64>(9)? != 0,
                skipped: r.get::<_, i64>(10)? != 0,
                source: r.get(11)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let mut year_st = conn.prepare(
        "SELECT DISTINCT CAST(strftime('%Y', started_at, 'unixepoch', 'localtime') AS INTEGER) AS y
         FROM listen_events
         WHERE profile_id = ?1
         ORDER BY y DESC",
    )?;
    let available_years = year_st
        .query_map([profile.0], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    Ok(ListeningStats {
        summary: StatsSummary {
            total_listened_ms,
            play_count,
            raw_event_count,
            skip_count,
            completed_count,
            unique_tracks,
            unique_artists,
            unique_albums,
            active_days,
            longest_streak_days,
            current_streak_days,
            top_hour,
            top_weekday,
            first_listen_at,
        },
        top_tracks_by_plays,
        top_tracks_by_time,
        top_artists_by_time,
        top_albums_by_time,
        top_genres,
        by_hour,
        by_weekday,
        by_month,
        recent,
        available_years,
    })
}

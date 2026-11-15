//! Database backups before a sync changes data: at most one every 6 h, the
//! 5 newest kept, written with `VACUUM INTO` (a consistent copy even while
//! the app keeps the database open).

use super::{Result, SyncError};
use rusqlite::Connection;
use std::path::{Path, PathBuf};

pub const BACKUP_INTERVAL_MS: i64 = 6 * 60 * 60 * 1000;
pub const BACKUPS_KEPT: usize = 5;
const PREFIX: &str = "library-";
const SUFFIX: &str = ".sqlite3";

/// Writes `library-<utc>.sqlite3` into `dir` unless the newest backup there
/// is less than 6 h old; then keeps only the 5 newest. Returns the new
/// file, if one was written. Only files with the exact backup name pattern
/// are ever deleted.
pub fn backup_if_due(conn: &Connection, dir: &Path, now_ms: i64) -> Result<Option<PathBuf>> {
    std::fs::create_dir_all(dir)?;
    let newest = backups(dir)?.into_iter().map(|(t, _)| t).max();
    // A backup "from the future" (the clock went back) does not block.
    if let Some(t) = newest
        && t <= now_ms
        && now_ms - t < BACKUP_INTERVAL_MS
    {
        return Ok(None);
    }
    let path = dir.join(format!("{PREFIX}{}{SUFFIX}", utc_stamp(now_ms)));
    if path.exists() {
        return Ok(None);
    }
    let target = path
        .to_str()
        .ok_or_else(|| SyncError::Other("backup path is not valid UTF-8".into()))?;
    conn.execute("VACUUM INTO ?1", [target])?;
    rotate(dir)?;
    Ok(Some(path))
}

fn rotate(dir: &Path) -> Result<()> {
    let mut all = backups(dir)?;
    all.sort_by_key(|(t, _)| std::cmp::Reverse(*t));
    for (_, path) in all.into_iter().skip(BACKUPS_KEPT) {
        std::fs::remove_file(path)?;
    }
    Ok(())
}

/// `(unix ms, path)` of every backup file in `dir`.
fn backups(dir: &Path) -> Result<Vec<(i64, PathBuf)>> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(stamp) = name
            .strip_prefix(PREFIX)
            .and_then(|s| s.strip_suffix(SUFFIX))
        else {
            continue;
        };
        if let Some(ms) = parse_utc_stamp(stamp)
            && entry.file_type()?.is_file()
        {
            out.push((ms, entry.path()));
        }
    }
    Ok(out)
}

/// `YYYYMMDDTHHMMSSZ` for a unix-ms time.
pub(super) fn utc_stamp(ms: i64) -> String {
    let secs = ms.div_euclid(1000);
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}{m:02}{d:02}T{:02}{:02}{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

fn parse_utc_stamp(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() != 16 || b[8] != b'T' || b[15] != b'Z' {
        return None;
    }
    let num = |r: std::ops::Range<usize>| -> Option<i64> {
        let part = s.get(r)?;
        part.bytes()
            .all(|c| c.is_ascii_digit())
            .then(|| part.parse().ok())?
    };
    let (y, mo, d) = (num(0..4)?, num(4..6)?, num(6..8)?);
    let (h, mi, se) = (num(9..11)?, num(11..13)?, num(13..15)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || se > 59 {
        return None;
    }
    let days = days_from_civil(y, mo, d);
    Some((days * 86_400 + h * 3600 + mi * 60 + se) * 1000)
}

// Howard Hinnant's civil-calendar algorithms (proleptic Gregorian).
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    (y, m, d)
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utc_stamps_round_trip() {
        assert_eq!(utc_stamp(0), "19700101T000000Z");
        // 2026-11-15 12:34:56 UTC
        let ms = 1_794_746_096_000;
        assert_eq!(utc_stamp(ms), "20261115T123456Z");
        assert_eq!(parse_utc_stamp("20261115T123456Z"), Some(ms));
        assert_eq!(parse_utc_stamp("20261315T123456Z"), None);
        assert_eq!(parse_utc_stamp("library"), None);
    }
}

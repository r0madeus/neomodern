//! Automatic backup to a folder (docs/BACKUP.md, section 3), desktop only:
//! checked at start-up and every hour, the same export as a manual one,
//! the newest N files the app named kept.

use super::archive::{self, ExportInfo};
use super::{BackupError, BackupState, EXTENSION, Result, backup_file_name, now_ms};
use crate::library::Library;
use crate::session::{AutoBackup, BackupInterval, SessionStore};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

pub const NAME_PREFIX: &str = "NeoModern-backup-";
pub const CHECK_EVERY: Duration = Duration::from_secs(60 * 60);
/// Retry delay when a scan or another backup job is running.
pub const BUSY_RETRY: Duration = Duration::from_secs(5 * 60);

pub fn interval_ms(i: BackupInterval) -> i64 {
    match i {
        BackupInterval::Day => 24 * 60 * 60 * 1000,
        BackupInterval::Week => 7 * 24 * 60 * 60 * 1000,
    }
}

/// Whether a backup is due at `now_ms`. A last run "in the future" (the
/// clock went back) does not block.
pub fn is_due(a: &AutoBackup, now_ms: i64) -> bool {
    a.enabled
        && a.folder.is_some()
        && a.last_at
            .is_none_or(|t| t > now_ms || now_ms - t >= interval_ms(a.interval))
}

/// What the background task does at a check.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Run,
    /// Check again after this long.
    Wait(Duration),
}

/// One check: never during a scan, an import or another backup job.
pub fn decide(a: &AutoBackup, now_ms: i64, scanning: bool, busy: bool) -> Decision {
    if !is_due(a, now_ms) {
        return Decision::Wait(CHECK_EVERY);
    }
    if scanning || busy {
        return Decision::Wait(BUSY_RETRY);
    }
    Decision::Run
}

/// `(stamp, n)` of a file the app named:
/// `NeoModern-backup-yyyy-mm-dd-hhmm[-n].nmbackup`.
fn parse_name(name: &str) -> Option<(&str, u32)> {
    let rest = name
        .strip_prefix(NAME_PREFIX)?
        .strip_suffix(EXTENSION)?
        .strip_suffix('.')?;
    let (stamp, n) = match rest.get(15..) {
        Some("") => (rest, 1),
        Some(tail) => {
            let n = tail.strip_prefix('-')?;
            if n.is_empty() || !n.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            (&rest[..15], n.parse().ok()?)
        }
        None => return None,
    };
    let b = stamp.as_bytes();
    let ok = b.len() == 15
        && b.iter().enumerate().all(|(i, c)| match i {
            4 | 7 | 10 => *c == b'-',
            _ => c.is_ascii_digit(),
        });
    ok.then_some((stamp, n))
}

/// A free file name in `folder` for a backup made at `now_ms`.
pub fn target_in(folder: &Path, now_ms: i64) -> PathBuf {
    let name = backup_file_name(now_ms);
    let mut path = folder.join(&name);
    let mut n = 2;
    while path.exists() || archive::partial_path(&path).exists() {
        let stem = name.trim_end_matches(&format!(".{EXTENSION}"));
        path = folder.join(format!("{stem}-{n}.{EXTENSION}"));
        n += 1;
    }
    path
}

/// Deletes all but the newest `keep` backups the app named in `folder`;
/// other files are never touched. Returns the deleted files.
pub fn rotate(folder: &Path, keep: usize) -> std::io::Result<Vec<PathBuf>> {
    let mut ours: Vec<((String, u32), PathBuf)> = Vec::new();
    for entry in std::fs::read_dir(folder)? {
        let entry = entry?;
        let name = entry.file_name();
        let Some((stamp, n)) = name.to_str().and_then(parse_name) else {
            continue;
        };
        if entry.file_type()?.is_file() {
            ours.push(((stamp.to_string(), n), entry.path()));
        }
    }
    ours.sort_by(|a, b| b.0.cmp(&a.0));
    let mut removed = Vec::new();
    for (_, path) in ours.into_iter().skip(keep) {
        match std::fs::remove_file(&path) {
            Ok(()) => removed.push(path),
            Err(e) => log::warn!("could not remove old backup {}: {e}", path.display()),
        }
    }
    Ok(removed)
}

/// Writes a backup of `data_dir` into `folder` and rotates.
pub fn run(data_dir: &Path, folder: &Path, keep: u32, now_ms: i64) -> Result<ExportInfo> {
    if !folder.is_dir() {
        return Err(BackupError::Invalid(format!(
            "backup folder not found: {}",
            folder.display()
        )));
    }
    let info = archive::export(data_dir, &target_in(folder, now_ms), now_ms)?;
    rotate(folder, keep as usize)?;
    Ok(info)
}

/// Runs one automatic backup into the configured folder and persists the
/// outcome (`last_at`, `last_size`, `last_error`) into `store`.
pub async fn run_auto_once(
    state: &Arc<BackupState>,
    store: &Arc<SessionStore>,
    library: &Arc<Library>,
    save_session: Arc<dyn Fn() + Send + Sync>,
) -> std::result::Result<ExportInfo, String> {
    if cfg!(target_os = "android") {
        return Err("automatic backup is not available on Android".into());
    }
    if library.is_scanning() {
        return Err("the library is being scanned; try again when it is done".into());
    }
    let settings = store.auto_backup();
    let Some(folder) = settings.folder.clone() else {
        return Err("choose a folder for the backups first".into());
    };
    let started = now_ms();
    let state_clone = Arc::clone(state);
    let save_for_export = Arc::clone(&save_session);
    let job = tokio::task::spawn_blocking(move || {
        let _job = state_clone.begin()?;
        save_for_export();
        run(&state_clone.data_dir, &folder, settings.keep, started)
    })
    .await
    .map_err(|e| e.to_string())?;

    // A busy refusal is not a failed backup.
    if let Err(e @ BackupError::Busy(_)) = job {
        return Err(e.to_string());
    }
    let job = job.map_err(|e| e.to_string());
    store.update_auto_backup(|a| match &job {
        Ok(info) => {
            a.last_at = Some(started);
            a.last_size = Some(info.size);
            a.last_error = None;
        }
        Err(e) => a.last_error = Some(e.clone()),
    });
    match &job {
        Ok(info) => log::info!(
            "automatic backup written: {} ({} bytes)",
            info.path,
            info.size
        ),
        Err(e) => log::warn!("automatic backup failed: {e}"),
    }
    let _ = tokio::task::spawn_blocking(move || save_session()).await;
    job
}

/// Spawns the background automatic-backup loop (desktop only): checks at
/// start-up, then every hour (sooner after a skip because a scan was
/// running), and whenever settings change via [`BackupState::notify_auto`].
pub fn spawn_auto_backup(
    state: Arc<BackupState>,
    store: Arc<SessionStore>,
    library: Arc<Library>,
    save_session: Arc<dyn Fn() + Send + Sync>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            let scanning = library.is_scanning();
            let busy = state.busy() || state.import_pending();
            let wait = match decide(&store.auto_backup(), now_ms(), scanning, busy) {
                Decision::Wait(d) => d,
                Decision::Run => {
                    let _ =
                        run_auto_once(&state, &store, &library, Arc::clone(&save_session)).await;
                    CHECK_EVERY
                }
            };
            tokio::select! {
                _ = tokio::time::sleep(wait) => {}
                _ = state.wake.notified() => {}
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_the_app_wrote_are_recognised() {
        assert_eq!(
            parse_name("NeoModern-backup-2026-11-21-1030.nmbackup"),
            Some(("2026-11-21-1030", 1))
        );
        assert_eq!(
            parse_name("NeoModern-backup-2026-11-21-1030-3.nmbackup"),
            Some(("2026-11-21-1030", 3))
        );
        for other in [
            "NeoModern-backup-2026-11-21-1030.nmbackup.partial",
            "NeoModern-backup-2026-11-21.nmbackup",
            "NeoModern-backup-2026-11-21-1030-.nmbackup",
            "NeoModern-backup-2026-11-21-10x0.nmbackup",
            "my-NeoModern-backup-2026-11-21-1030.nmbackup",
            "NeoModern-backup-2026-11-21-1030 (copy).nmbackup",
        ] {
            assert_eq!(parse_name(other), None, "{other}");
        }
    }
}

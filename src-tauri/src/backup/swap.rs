//! Import, second step (docs/BACKUP.md, section 1): the validated backup
//! is staged in `data/import-staging/`, a copy of the current data goes to
//! `data/before-import-<utc>/`, and at the next start-up, before the
//! database is opened, the staged files are renamed into place. The data
//! they replace is first moved to `data/import-rollback/`, so a failed swap
//! (or one cut short by a crash) is undone.

use super::archive::{self, BackupSummary, Output};
use super::{DATA_FOLDERS, ImportOutcome, LIBRARY, Result, SESSION, entry_path};
use std::path::{Path, PathBuf};

pub const STAGING_DIR: &str = "import-staging";
pub const ROLLBACK_DIR: &str = "import-rollback";
pub const BEFORE_IMPORT_PREFIX: &str = "before-import-";
pub const BEFORE_IMPORT_KEPT: usize = 3;
/// Written last into the staging folder: the staged files are complete.
const READY: &str = ".ready";
/// In the rollback folder while a swap is under way.
const SWAPPING: &str = ".swapping";

/// Everything an import replaces, in swap order. The database's WAL files
/// are moved aside too: a stale WAL must never meet the new database.
const SLOTS: [&str; 8] = [
    LIBRARY,
    "library.sqlite3-wal",
    "library.sqlite3-shm",
    SESSION,
    DATA_FOLDERS[0],
    DATA_FOLDERS[1],
    DATA_FOLDERS[2],
    DATA_FOLDERS[3],
];

#[derive(Debug, Clone, serde::Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct StagedImport {
    pub restart_required: bool,
    pub before_import: String,
    pub summary: BackupSummary,
}

/// `YYYYMMDDTHHMMSSZ`.
fn utc_stamp(ms: i64) -> String {
    let (y, m, d, h, mi, s) = super::utc_parts(ms);
    format!("{y:04}{m:02}{d:02}T{h:02}{mi:02}{s:02}Z")
}

fn remove_path(p: &Path) -> std::io::Result<()> {
    match std::fs::symlink_metadata(p) {
        Ok(m) if m.is_dir() => std::fs::remove_dir_all(p),
        Ok(_) => std::fs::remove_file(p),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

fn copy_files(from: &Path, to: &Path) -> std::io::Result<()> {
    let Ok(read) = std::fs::read_dir(from) else {
        return Ok(());
    };
    std::fs::create_dir_all(to)?;
    for entry in read {
        let entry = entry?;
        if std::fs::symlink_metadata(entry.path())?.is_file() {
            std::fs::copy(entry.path(), to.join(entry.file_name()))?;
        }
    }
    Ok(())
}

/// Copies the entries an import replaces to `data/before-import-<utc>/`
/// (the database with `VACUUM INTO`) and keeps the newest 3 such folders.
pub fn copy_before_import(data_dir: &Path, now_ms: i64) -> Result<PathBuf> {
    let mut dir = data_dir.join(format!("{BEFORE_IMPORT_PREFIX}{}", utc_stamp(now_ms)));
    let mut n = 2;
    while dir.exists() {
        dir = data_dir.join(format!("{BEFORE_IMPORT_PREFIX}{}-{n}", utc_stamp(now_ms)));
        n += 1;
    }
    let partial = archive::partial_path(&dir);
    remove_path(&partial)?;
    std::fs::create_dir_all(&partial)?;
    let copied = (|| -> Result<()> {
        if data_dir.join(LIBRARY).is_file() {
            archive::copy_database(&data_dir.join(LIBRARY), &partial.join(LIBRARY))?;
        }
        if data_dir.join(SESSION).is_file() {
            std::fs::copy(data_dir.join(SESSION), partial.join(SESSION))?;
        }
        for folder in DATA_FOLDERS {
            copy_files(&entry_path(data_dir, folder), &entry_path(&partial, folder))?;
        }
        std::fs::rename(&partial, &dir)?;
        Ok(())
    })();
    if let Err(e) = copied {
        let _ = remove_path(&partial);
        return Err(e);
    }
    rotate_before_import(data_dir, BEFORE_IMPORT_KEPT);
    Ok(dir)
}

/// Keeps the newest `keep` `before-import-<utc>` folders; nothing else in
/// the data folder is touched.
pub fn rotate_before_import(data_dir: &Path, keep: usize) {
    let Ok(read) = std::fs::read_dir(data_dir) else {
        return;
    };
    let mut dirs: Vec<(String, PathBuf)> = read
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_str()?.to_owned();
            let stamp = name.strip_prefix(BEFORE_IMPORT_PREFIX)?;
            let (stamp, n) = match stamp.split_once('-') {
                Some((s, n)) if n.bytes().all(|b| b.is_ascii_digit()) && !n.is_empty() => (s, n),
                Some(_) => return None,
                None => (stamp, "1"),
            };
            let valid = stamp.len() == 16
                && stamp.as_bytes()[8] == b'T'
                && stamp.ends_with('Z')
                && stamp
                    .bytes()
                    .enumerate()
                    .all(|(i, b)| i == 8 || i == 15 || b.is_ascii_digit());
            let is_dir = e.file_type().ok()?.is_dir();
            (valid && is_dir).then(|| (format!("{stamp}{n:0>6}"), e.path()))
        })
        .collect();
    dirs.sort_by(|a, b| b.0.cmp(&a.0));
    for (_, dir) in dirs.into_iter().skip(keep) {
        if let Err(e) = std::fs::remove_dir_all(&dir) {
            log::warn!("could not remove old import copy {}: {e}", dir.display());
        }
    }
}

/// Keeps this device's automatic-backup settings in the staged
/// `session.json`: they name a folder of this computer.
fn keep_device_settings(data_dir: &Path, staged: &Path) -> Result<()> {
    let Ok(bytes) = std::fs::read(staged) else {
        return Ok(());
    };
    let Ok(serde_json::Value::Object(mut new)) = serde_json::from_slice(&bytes) else {
        return Ok(());
    };
    let current = std::fs::read(data_dir.join(SESSION))
        .ok()
        .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
        .and_then(|v| v.get("autoBackup").cloned());
    match current {
        Some(v) => new.insert("autoBackup".into(), v),
        None => new.remove("autoBackup"),
    };
    let json = serde_json::to_vec(&new).map_err(|e| super::BackupError::Invalid(e.to_string()))?;
    std::fs::write(staged, json)?;
    Ok(())
}

/// Validates `archive` again and stages it for the next start-up. Returns
/// the summary and the folder with the copy of the current data.
pub fn stage_import(archive: &Path, data_dir: &Path, now_ms: i64) -> Result<StagedImport> {
    let staging = data_dir.join(STAGING_DIR);
    remove_path(&staging)?;
    std::fs::create_dir_all(&staging)?;
    let staged = (|| -> Result<StagedImport> {
        let verified = archive::verify(archive, Output::Everything(&staging))?;
        let before = copy_before_import(data_dir, now_ms)?;
        // Kept images are stored with full paths into the source's data
        // folder; point them at this one.
        let here = crate::library::scan::display_path(data_dir);
        if verified.manifest.data_dir != here && !verified.manifest.data_dir.is_empty() {
            let conn = rusqlite::Connection::open(staging.join(LIBRARY))?;
            crate::library::db::register_collation(&conn)?;
            let n = crate::library::relocate::rebase_data_paths(
                &conn,
                &verified.manifest.data_dir,
                &here,
            )?;
            log::info!("import: {n} stored image paths point at this data folder");
        }
        keep_device_settings(data_dir, &staging.join(SESSION))?;
        let ready = serde_json::to_vec(&verified.summary)
            .map_err(|e| super::BackupError::Invalid(e.to_string()))?;
        std::fs::write(staging.join(READY), ready)?;
        Ok(StagedImport {
            restart_required: true,
            before_import: before.to_string_lossy().into_owned(),
            summary: verified.summary,
        })
    })();
    if staged.is_err() {
        let _ = remove_path(&staging);
    }
    staged
}

/// Whether a complete import waits in the staging folder.
pub fn import_staged(data_dir: &Path) -> bool {
    data_dir.join(STAGING_DIR).join(READY).is_file()
}

/// Moves what an interrupted swap set aside back into place.
fn restore_rollback(data_dir: &Path, rollback: &Path) -> std::io::Result<()> {
    for slot in SLOTS {
        let saved = entry_path(rollback, slot);
        if std::fs::symlink_metadata(&saved).is_ok() {
            let live = entry_path(data_dir, slot);
            remove_path(&live)?;
            std::fs::rename(&saved, &live)?;
        }
    }
    std::fs::remove_dir_all(rollback)
}

/// Run at start-up before the database is opened: swaps a staged import
/// into place. `None` when there was nothing to do.
pub fn apply_pending_import(data_dir: &Path) -> Option<ImportOutcome> {
    apply_pending_import_with(data_dir, &mut |_| Ok(()))
}

/// [`apply_pending_import`] with `before_place` called before each staged
/// entry is moved into place (tests inject failures there).
pub fn apply_pending_import_with(
    data_dir: &Path,
    before_place: &mut dyn FnMut(&str) -> std::io::Result<()>,
) -> Option<ImportOutcome> {
    let staging = data_dir.join(STAGING_DIR);
    let rollback = data_dir.join(ROLLBACK_DIR);
    if rollback.join(SWAPPING).is_file() {
        log::warn!("an import swap was interrupted; restoring the previous data");
        if let Err(e) = restore_rollback(data_dir, &rollback) {
            log::error!("could not restore the data from {}: {e}", rollback.display());
            return Some(ImportOutcome {
                applied: false,
                error: Some(format!("restoring after an interrupted import failed: {e}")),
            });
        }
    } else if rollback.exists() {
        let _ = remove_path(&rollback);
    }
    if !staging.exists() {
        return None;
    }
    if !import_staged(data_dir) {
        log::warn!("discarding an incomplete import");
        let _ = remove_path(&staging);
        return None;
    }
    let result = swap(data_dir, &staging, &rollback, before_place);
    let _ = remove_path(&staging);
    Some(match result {
        Ok(()) => {
            log::info!("backup imported");
            ImportOutcome {
                applied: true,
                error: None,
            }
        }
        Err(e) => {
            log::error!("import failed, previous data restored: {e}");
            ImportOutcome {
                applied: false,
                error: Some(e.to_string()),
            }
        }
    })
}

fn swap(
    data_dir: &Path,
    staging: &Path,
    rollback: &Path,
    before_place: &mut dyn FnMut(&str) -> std::io::Result<()>,
) -> std::io::Result<()> {
    std::fs::create_dir_all(rollback.join("images"))?;
    std::fs::write(rollback.join(SWAPPING), b"")?;
    let mut moved = Vec::new();
    let mut placed = Vec::new();
    let result = (|| -> std::io::Result<()> {
        for slot in SLOTS {
            let live = entry_path(data_dir, slot);
            if std::fs::symlink_metadata(&live).is_ok() {
                std::fs::rename(&live, entry_path(rollback, slot))?;
                moved.push(slot);
            }
        }
        for slot in SLOTS {
            let new = entry_path(staging, slot);
            if std::fs::symlink_metadata(&new).is_err() {
                continue;
            }
            before_place(slot)?;
            let live = entry_path(data_dir, slot);
            if let Some(parent) = live.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::rename(&new, &live)?;
            placed.push(slot);
        }
        Ok(())
    })();
    match result {
        Ok(()) => {
            // Done: the rollback copy is no longer needed (the
            // before-import copy is kept).
            std::fs::remove_file(rollback.join(SWAPPING))?;
            if let Err(e) = std::fs::remove_dir_all(rollback) {
                log::warn!("could not remove {}: {e}", rollback.display());
            }
            Ok(())
        }
        Err(e) => {
            for slot in placed {
                if let Err(e) = remove_path(&entry_path(data_dir, slot)) {
                    log::error!("rollback: could not remove imported {slot}: {e}");
                }
            }
            for slot in moved {
                if let Err(e) = std::fs::rename(entry_path(rollback, slot), entry_path(data_dir, slot)) {
                    log::error!("rollback: could not restore {slot}: {e}");
                }
            }
            if let Err(e) = remove_path(rollback) {
                log::warn!("could not remove {}: {e}", rollback.display());
            }
            Err(e)
        }
    }
}

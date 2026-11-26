//! Backup and restore (K28, docs/BACKUP.md): one `.nmbackup` zip with the
//! user's data (never the music), a two-step import that swaps the data in
//! at the next start-up, and an optional automatic backup to a folder.
//!
//! * [`archive`] – writing and validating the zip.
//! * [`swap`] – staging an import and swapping it in before the database
//!   is opened, with rollback.
//! * [`auto`] – the automatic backup: due logic, naming, rotation and the
//!   background task (desktop only).

pub mod archive;
pub mod auto;
pub mod swap;

#[cfg(test)]
mod tests;

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

/// Archive format written by this build; newer ones are refused.
pub const FORMAT_VERSION: u32 = 1;
/// Limits checked before anything is extracted.
pub const MAX_TOTAL_BYTES: u64 = 4 << 30;
pub const MAX_IMAGE_BYTES: u64 = 15 << 20;
pub const MAX_ENTRIES: usize = 200_000;
/// Files read into memory while validating.
const MAX_MANIFEST_BYTES: u64 = 64 << 20;
const MAX_SESSION_BYTES: u64 = 64 << 20;

pub const MANIFEST: &str = "manifest.json";
pub const LIBRARY: &str = "library.sqlite3";
pub const SESSION: &str = "session.json";
/// Folders of the data folder that are backed up, each holding files only.
pub const DATA_FOLDERS: [&str; 4] = [
    "images/playlists",
    "images/albums",
    "images/artists",
    "lyrics",
];
pub const EXTENSION: &str = "nmbackup";

#[derive(Debug, thiserror::Error)]
pub enum BackupError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("database error: {0}")]
    Db(#[from] rusqlite::Error),
    #[error("{0}")]
    Library(#[from] crate::library::LibraryError),
    #[error("zip error: {0}")]
    Zip(#[from] zip::result::ZipError),
    #[error("{0}")]
    Invalid(String),
    #[error("{0}")]
    Busy(String),
}

pub type Result<T> = std::result::Result<T, BackupError>;

fn invalid<T>(msg: impl Into<String>) -> Result<T> {
    Err(BackupError::Invalid(msg.into()))
}

/// What an archive entry is; anything else is refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryKind {
    Library,
    Session,
    Image,
    Lyrics,
}

/// A file name that is safe on every platform the app runs on.
fn safe_file_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && name != "."
        && name != ".."
        && !name.ends_with(['.', ' '])
        && !name.chars().any(|c| {
            c.is_control() || matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|')
        })
}

/// The kind of a backup entry name (`/`-separated, relative), or why it
/// is refused.
pub fn classify(name: &str) -> std::result::Result<EntryKind, String> {
    if name.starts_with(['/', '\\']) || name.as_bytes().get(1) == Some(&b':') {
        return Err(format!("absolute path in backup: {name}"));
    }
    if name.contains('\\') || name.split('/').any(|c| c == ".." || c == ".") {
        return Err(format!("path leaves the backup: {name}"));
    }
    match name {
        LIBRARY => return Ok(EntryKind::Library),
        SESSION => return Ok(EntryKind::Session),
        _ => {}
    }
    for folder in DATA_FOLDERS {
        if let Some(file) = name
            .strip_prefix(folder)
            .and_then(|rest| rest.strip_prefix('/'))
            && safe_file_name(file)
        {
            return Ok(if folder == "lyrics" {
                EntryKind::Lyrics
            } else {
                EntryKind::Image
            });
        }
    }
    Err(format!("unknown entry in backup: {name}"))
}

/// Where entry `name` lives under `root`.
pub fn entry_path(root: &Path, name: &str) -> PathBuf {
    name.split('/').fold(root.to_path_buf(), |p, c| p.join(c))
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

/// `(year, month, day, hour, minute, second)` in UTC for a unix-ms time.
pub fn utc_parts(ms: i64) -> (i64, i64, i64, i64, i64, i64) {
    let secs = ms.div_euclid(1000);
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // Howard Hinnant's civil-from-days (proleptic Gregorian).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    (y, m, d, rem / 3600, rem % 3600 / 60, rem % 60)
}

/// `NeoModern-backup-<yyyy-mm-dd-hhmm>.nmbackup` (UTC) for a unix-ms time.
pub fn backup_file_name(ms: i64) -> String {
    let (y, m, d, h, mi, _) = utc_parts(ms);
    format!(
        "{}{y:04}-{m:02}-{d:02}-{h:02}{mi:02}.{EXTENSION}",
        auto::NAME_PREFIX
    )
}

/// The result of the import swap done at this start-up, for the UI.
#[derive(Debug, Clone, serde::Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ImportOutcome {
    pub applied: bool,
    pub error: Option<String>,
}

/// App state: one backup job at a time, and whether an import waits for a
/// restart.
pub struct BackupState {
    pub data_dir: PathBuf,
    busy: AtomicBool,
    import_pending: AtomicBool,
    last_import: Mutex<Option<ImportOutcome>>,
    pub(crate) wake: tokio::sync::Notify,
}

/// Clears the busy flag when a job ends.
pub struct BusyGuard<'a>(&'a AtomicBool);

impl Drop for BusyGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

impl BackupState {
    pub fn new(data_dir: PathBuf, last_import: Option<ImportOutcome>) -> Self {
        Self {
            data_dir,
            busy: AtomicBool::new(false),
            import_pending: AtomicBool::new(false),
            last_import: Mutex::new(last_import),
            wake: tokio::sync::Notify::new(),
        }
    }

    /// Starts a job, or says why not.
    pub fn begin(&self) -> Result<BusyGuard<'_>> {
        if self.import_pending() {
            return Err(BackupError::Busy(
                "an import is waiting for the app to restart".into(),
            ));
        }
        if self
            .busy
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return Err(BackupError::Busy("a backup is already running".into()));
        }
        Ok(BusyGuard(&self.busy))
    }

    pub fn busy(&self) -> bool {
        self.busy.load(Ordering::SeqCst)
    }

    pub fn import_pending(&self) -> bool {
        self.import_pending.load(Ordering::SeqCst)
    }

    pub fn set_import_pending(&self) {
        self.import_pending.store(true, Ordering::SeqCst);
    }

    pub fn last_import(&self) -> Option<ImportOutcome> {
        self.last_import
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// Wakes the background automatic backup loop so changed settings take
    /// effect immediately.
    pub fn notify_auto(&self) {
        self.wake.notify_one();
    }
}

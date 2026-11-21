//! The `.nmbackup` zip: writing it from the data folder and validating one
//! before anything is touched (docs/BACKUP.md, section 1).

use super::{
    BackupError, DATA_FOLDERS, EntryKind, FORMAT_VERSION, LIBRARY, MANIFEST, MAX_ENTRIES,
    MAX_IMAGE_BYTES, MAX_MANIFEST_BYTES, MAX_SESSION_BYTES, MAX_TOTAL_BYTES, Result, SESSION,
    classify, entry_path, invalid,
};
use crate::library::db::{SCHEMA_VERSION, register_collation};
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ManifestEntry {
    pub name: String,
    pub size: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub format: u32,
    pub app_version: String,
    pub schema_version: i64,
    /// Unix ms, UTC.
    pub created_at: i64,
    pub platform: String,
    /// The source's data folder: stored paths of kept images point into it.
    pub data_dir: String,
    pub entries: Vec<ManifestEntry>,
}

/// What a backup holds, shown before an import.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct BackupSummary {
    pub created_at: i64,
    pub app_version: String,
    pub schema_version: i64,
    pub platform: String,
    pub profiles: Vec<String>,
    pub tracks: u64,
    pub playlists: u64,
    pub favorites: u64,
    pub listens: u64,
    pub folders: u64,
    pub entries: u64,
    /// Size of the backup file.
    pub size: u64,
    /// Size of its contents.
    pub content_size: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ExportInfo {
    pub path: String,
    pub size: u64,
    pub created_at: i64,
}

/// A file in the data folder that is deleted when dropped.
pub(crate) struct TempFile(pub PathBuf);

impl TempFile {
    pub fn new(dir: &Path, tag: &str) -> Self {
        static N: AtomicU64 = AtomicU64::new(0);
        let n = N.fetch_add(1, Ordering::SeqCst);
        let path = dir.join(format!(".{tag}-{}-{n}.tmp", std::process::id()));
        let _ = std::fs::remove_file(&path);
        Self(path)
    }
}

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
        for ext in ["-wal", "-shm", "-journal"] {
            let mut p = self.0.clone().into_os_string();
            p.push(ext);
            let _ = std::fs::remove_file(p);
        }
    }
}

fn sqlite_path(p: &Path) -> Result<&str> {
    p.to_str()
        .ok_or_else(|| BackupError::Invalid(format!("path is not valid UTF-8: {}", p.display())))
}

/// Writes a consistent copy of the live database `db` to `out` with
/// `VACUUM INTO`, through its own read-only connection: the app keeps
/// running and its connection is not held.
pub fn copy_database(db: &Path, out: &Path) -> Result<()> {
    if !db.is_file() {
        return invalid(format!("no library database at {}", db.display()));
    }
    let conn = Connection::open_with_flags(db, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    conn.busy_timeout(std::time::Duration::from_secs(10))?;
    register_collation(&conn)?;
    conn.execute("VACUUM INTO ?1", [sqlite_path(out)?])?;
    Ok(())
}

/// Files of the data folder that go into a backup: `(entry name, file)`.
/// Links and files with names the import would refuse are skipped.
fn data_files(data_dir: &Path) -> Result<Vec<(String, PathBuf)>> {
    let mut out = Vec::new();
    let session = data_dir.join(SESSION);
    if session.is_file() {
        out.push((SESSION.to_string(), session));
    }
    for folder in DATA_FOLDERS {
        let dir = entry_path(data_dir, folder);
        let Ok(read) = std::fs::read_dir(&dir) else {
            continue;
        };
        let mut files = Vec::new();
        for entry in read {
            let entry = entry?;
            let meta = std::fs::symlink_metadata(entry.path())?;
            if !meta.is_file() {
                continue;
            }
            let Some(file) = entry.file_name().to_str().map(str::to_owned) else {
                log::warn!("backup: skipping {} (name)", entry.path().display());
                continue;
            };
            let name = format!("{folder}/{file}");
            let kind = classify(&name);
            if kind.is_err() || file.ends_with(".tmp") {
                log::warn!("backup: skipping {}", entry.path().display());
                continue;
            }
            if kind == Ok(EntryKind::Image) && meta.len() > MAX_IMAGE_BYTES {
                log::warn!("backup: skipping {} (too large)", entry.path().display());
                continue;
            }
            files.push((name, entry.path()));
        }
        files.sort();
        out.extend(files);
    }
    Ok(out)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Copies `from` into `to`, returning its size and SHA-256.
fn copy_hashed(from: &mut impl Read, to: &mut impl Write) -> std::io::Result<(u64, String)> {
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    let mut size = 0u64;
    loop {
        let n = from.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        to.write_all(&buf[..n])?;
        size += n as u64;
    }
    Ok((size, hex(&hasher.finalize())))
}

/// `<path>.partial`.
pub fn partial_path(path: &Path) -> PathBuf {
    let mut p = path.as_os_str().to_owned();
    p.push(".partial");
    PathBuf::from(p)
}

/// Writes a backup of `data_dir` to `target` (first as
/// `<target>.partial`, then renamed, so nobody sees a half file).
pub fn export(data_dir: &Path, target: &Path, now_ms: i64) -> Result<ExportInfo> {
    let db = TempFile::new(data_dir, "backup-db");
    copy_database(&data_dir.join(LIBRARY), &db.0)?;
    let mut files = vec![(LIBRARY.to_string(), db.0.clone())];
    files.extend(data_files(data_dir)?);
    if files.len() > MAX_ENTRIES {
        return invalid(format!("too many files to back up ({})", files.len()));
    }
    let partial = partial_path(target);
    if let Some(dir) = target.parent()
        && !dir.as_os_str().is_empty()
    {
        std::fs::create_dir_all(dir)?;
    }
    let written = write_zip(data_dir, &files, &partial, now_ms).and_then(|()| {
        std::fs::rename(&partial, target)?;
        Ok(())
    });
    if let Err(e) = written {
        let _ = std::fs::remove_file(&partial);
        return Err(e);
    }
    Ok(ExportInfo {
        path: target.to_string_lossy().into_owned(),
        size: std::fs::metadata(target)?.len(),
        created_at: now_ms,
    })
}

fn write_zip(data_dir: &Path, files: &[(String, PathBuf)], out: &Path, now_ms: i64) -> Result<()> {
    use zip::write::SimpleFileOptions;
    let file = std::fs::File::create(out)?;
    let mut zip = zip::ZipWriter::new(std::io::BufWriter::new(file));
    let mut entries = Vec::with_capacity(files.len());
    let mut total = 0u64;
    for (name, path) in files {
        let mut src = match std::fs::File::open(path) {
            Ok(f) => f,
            // A lyrics file or image removed since the listing.
            Err(e) if e.kind() == std::io::ErrorKind::NotFound && name != LIBRARY => continue,
            Err(e) => return Err(e.into()),
        };
        let len = src.metadata()?.len();
        // Images are compressed already.
        let method = if name.starts_with("images/") {
            zip::CompressionMethod::Stored
        } else {
            zip::CompressionMethod::Deflated
        };
        let options = SimpleFileOptions::default()
            .compression_method(method)
            .large_file(len >= u64::from(u32::MAX) / 2);
        zip.start_file(name.as_str(), options)?;
        let (size, sha256) = copy_hashed(&mut src, &mut zip)?;
        total += size;
        if total > MAX_TOTAL_BYTES {
            return invalid("the data is larger than a backup may be (4 GiB)");
        }
        entries.push(ManifestEntry {
            name: name.clone(),
            size,
            sha256,
        });
    }
    let manifest = Manifest {
        format: FORMAT_VERSION,
        app_version: env!("CARGO_PKG_VERSION").to_string(),
        schema_version: SCHEMA_VERSION,
        created_at: now_ms,
        platform: std::env::consts::OS.to_string(),
        data_dir: crate::library::scan::display_path(data_dir),
        entries,
    };
    let json = serde_json::to_vec_pretty(&manifest)
        .map_err(|e| BackupError::Invalid(format!("manifest: {e}")))?;
    zip.start_file(MANIFEST, SimpleFileOptions::default())?;
    zip.write_all(&json)?;
    let file = zip.finish()?.into_inner().map_err(|e| e.into_error())?;
    file.sync_all()?;
    Ok(())
}

/// Size and count limits of an import (smaller ones in tests).
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub total_bytes: u64,
    pub image_bytes: u64,
    pub entries: usize,
}

impl Limits {
    pub const DEFAULT: Limits = Limits {
        total_bytes: MAX_TOTAL_BYTES,
        image_bytes: MAX_IMAGE_BYTES,
        entries: MAX_ENTRIES,
    };
}

/// A validated backup.
pub struct Verified {
    pub manifest: Manifest,
    pub summary: BackupSummary,
}

/// Where [`verify`] writes the entries it checks.
pub enum Output<'a> {
    /// Only the database, to this temporary file (for its checks).
    DatabaseOnly(&'a Path),
    /// Every entry, under this folder, at its entry name.
    Everything(&'a Path),
}

fn read_limited(r: impl Read, limit: u64, what: &str) -> Result<Vec<u8>> {
    let mut buf = Vec::new();
    r.take(limit + 1).read_to_end(&mut buf)?;
    if buf.len() as u64 > limit {
        return invalid(format!("{what} is too large"));
    }
    Ok(buf)
}

/// Checks everything docs/BACKUP.md lists before an import: a zip with a
/// manifest, no newer format or schema, only known names (no absolute
/// paths, `..` or links), size and count limits, every entry listed with
/// matching size and SHA-256, and a database that passes
/// `PRAGMA integrity_check`. Writes the entries to `out` while hashing
/// them, so what is extracted is exactly what was checked.
pub fn verify(archive: &Path, out: Output<'_>) -> Result<Verified> {
    verify_with(archive, out, Limits::DEFAULT)
}

/// [`verify`] with explicit limits.
pub fn verify_with(archive: &Path, out: Output<'_>, limits: Limits) -> Result<Verified> {
    let file = std::fs::File::open(archive)?;
    let size = file.metadata()?.len();
    let mut zip = zip::ZipArchive::new(std::io::BufReader::new(file))
        .map_err(|_| BackupError::Invalid("not a NeoModern backup (not a zip file)".into()))?;
    if zip.len() > limits.entries + 1 {
        return invalid(format!("too many files in backup ({})", zip.len()));
    }

    // Names, kinds and declared sizes, without decompressing anything.
    let mut index: BTreeMap<String, (usize, EntryKind, u64)> = BTreeMap::new();
    let mut manifest_at = None;
    let mut total = 0u64;
    for i in 0..zip.len() {
        let f = zip.by_index_raw(i)?;
        let name = f.name()?.into_owned();
        if f.is_symlink() {
            return invalid(format!("links are not allowed in a backup: {name}"));
        }
        if f.encrypted() {
            return invalid(format!("encrypted entry in backup: {name}"));
        }
        if f.is_dir() {
            return invalid(format!("unknown entry in backup: {name}"));
        }
        if name == MANIFEST {
            if manifest_at.replace(i).is_some() {
                return invalid("backup has two manifests");
            }
            continue;
        }
        let kind = classify(&name).map_err(BackupError::Invalid)?;
        if f.enclosed_name().is_none() {
            return invalid(format!("path leaves the backup: {name}"));
        }
        let len = f.size();
        if kind == EntryKind::Image && len > limits.image_bytes {
            return invalid(format!("image too large in backup: {name}"));
        }
        if kind == EntryKind::Session && len > MAX_SESSION_BYTES {
            return invalid("session.json is too large");
        }
        total = total.saturating_add(len);
        if total > limits.total_bytes {
            return invalid("backup contents are larger than 4 GiB");
        }
        if index.insert(name.clone(), (i, kind, len)).is_some() {
            return invalid(format!("duplicate entry in backup: {name}"));
        }
    }

    let Some(manifest_at) = manifest_at else {
        return invalid("not a NeoModern backup (no manifest)");
    };
    let manifest: Manifest = {
        let f = zip.by_index(manifest_at)?;
        let bytes = read_limited(f, MAX_MANIFEST_BYTES, "manifest")?;
        serde_json::from_slice(&bytes)
            .map_err(|e| BackupError::Invalid(format!("unreadable manifest: {e}")))?
    };
    if manifest.format > FORMAT_VERSION || manifest.format == 0 {
        return invalid("this backup was made by a newer version of NeoModern");
    }
    if manifest.schema_version > SCHEMA_VERSION {
        return invalid("this backup's library is from a newer version of NeoModern");
    }
    let mut listed = HashSet::new();
    for e in &manifest.entries {
        if !listed.insert(e.name.as_str()) {
            return invalid(format!("manifest lists {} twice", e.name));
        }
        match index.get(&e.name) {
            Some((_, _, len)) if *len == e.size => {}
            Some(_) => return invalid(format!("size mismatch: {}", e.name)),
            None => return invalid(format!("missing from backup: {}", e.name)),
        }
    }
    if let Some(extra) = index.keys().find(|n| !listed.contains(n.as_str())) {
        return invalid(format!("not listed in the manifest: {extra}"));
    }
    if !index.contains_key(LIBRARY) {
        return invalid("backup has no library database");
    }

    let db_path = match out {
        Output::DatabaseOnly(p) => p.to_path_buf(),
        Output::Everything(dir) => entry_path(dir, LIBRARY),
    };
    let expected: BTreeMap<&str, &ManifestEntry> = manifest
        .entries
        .iter()
        .map(|e| (e.name.as_str(), e))
        .collect();
    for (name, (i, kind, len)) in &index {
        let target = match (&out, kind) {
            (_, EntryKind::Library) => Some(db_path.clone()),
            (Output::Everything(dir), _) => Some(entry_path(dir, name)),
            (Output::DatabaseOnly(_), _) => None,
        };
        let f = zip.by_index(*i)?;
        let mut limited = f.take(len + 1);
        let mut session = Vec::new();
        let (got, sha) = match &target {
            _ if *kind == EntryKind::Session => {
                let r = copy_hashed(&mut limited, &mut session)?;
                if let Some(path) = &target {
                    std::fs::write(path, &session)?;
                }
                r
            }
            Some(path) => {
                if let Some(parent) = path.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                let mut w = std::io::BufWriter::new(std::fs::File::create(path)?);
                let r = copy_hashed(&mut limited, &mut w)?;
                w.into_inner().map_err(|e| e.into_error())?.sync_all()?;
                r
            }
            None => copy_hashed(&mut limited, &mut std::io::sink())?,
        };
        if got != *len || sha != expected[name.as_str()].sha256 {
            return invalid(format!("checksum mismatch: {name}"));
        }
        if *kind == EntryKind::Session
            && !serde_json::from_slice::<serde_json::Value>(&session).is_ok_and(|v| v.is_object())
        {
            return invalid("session.json is not valid");
        }
    }

    let mut summary = check_database(&db_path)?;
    summary.created_at = manifest.created_at;
    summary.app_version = manifest.app_version.clone();
    summary.schema_version = manifest.schema_version;
    summary.platform = manifest.platform.clone();
    summary.entries = index.len() as u64;
    summary.size = size;
    summary.content_size = total;
    Ok(Verified { manifest, summary })
}

/// `PRAGMA integrity_check` on the extracted copy, opened read-only, and
/// what it holds. Refuses a newer schema and triggers (the app has none).
fn check_database(path: &Path) -> Result<BackupSummary> {
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| BackupError::Invalid(format!("library database cannot be opened: {e}")))?;
    let bad =
        |e: rusqlite::Error| BackupError::Invalid(format!("library database is damaged: {e}"));
    conn.pragma_update(None, "trusted_schema", false)
        .map_err(bad)?;
    register_collation(&conn)?;
    let ok: String = conn
        .query_row("PRAGMA integrity_check(1)", [], |r| r.get(0))
        .map_err(bad)?;
    if ok != "ok" {
        return invalid(format!("library database is damaged: {ok}"));
    }
    let version: i64 = conn
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .map_err(bad)?;
    if version > SCHEMA_VERSION {
        return invalid("this backup's library is from a newer version of NeoModern");
    }
    let has = |kind: &str, name: Option<&str>| -> Result<bool> {
        Ok(conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = ?1 AND (?2 IS NULL OR name = ?2))",
            rusqlite::params![kind, name],
            |r| r.get(0),
        )?)
    };
    if has("trigger", None)? {
        return invalid("library database has unexpected triggers");
    }
    if !has("table", Some("tracks"))? || !has("table", Some("folders"))? {
        return invalid("not a NeoModern library database");
    }
    let count = |table: &str| -> Result<u64> {
        if !has("table", Some(table))? {
            return Ok(0);
        }
        let n: i64 = conn
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
            .map_err(bad)?;
        Ok(n.max(0) as u64)
    };
    let profiles = if has("table", Some("profiles"))? {
        let mut st = conn.prepare("SELECT name FROM profiles ORDER BY id")?;
        st.query_map([], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<_>>()
            .map_err(bad)?
    } else {
        Vec::new()
    };
    Ok(BackupSummary {
        created_at: 0,
        app_version: String::new(),
        schema_version: version,
        platform: String::new(),
        profiles,
        tracks: count("tracks")?,
        playlists: count("playlists")?,
        favorites: count("favorites")?,
        listens: count("listen_events")?,
        folders: count("folders")?,
        entries: 0,
        size: 0,
        content_size: 0,
    })
}

/// Validates `archive` and returns what it holds; nothing is kept.
pub fn inspect(archive: &Path, work_dir: &Path) -> Result<BackupSummary> {
    std::fs::create_dir_all(work_dir)?;
    let db = TempFile::new(work_dir, "inspect-db");
    Ok(verify(archive, Output::DatabaseOnly(&db.0))?.summary)
}

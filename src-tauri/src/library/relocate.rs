//! "Move folder" (docs/BACKUP.md, section 2): a music folder now lives at
//! another path. Its stored paths are rewritten in one transaction, keeping
//! track ids, so favourites, playlists and history stay attached. Nothing on
//! disk is touched.

use super::{FolderInfo, Library, LibraryError, Result, scan};
use serde::Serialize;
use std::collections::HashMap;
use std::path::Path;

/// A library folder and whether its root can be reached now.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct FolderStatus {
    pub id: i64,
    pub path: String,
    pub reachable: bool,
}

/// How many of a folder's known songs exist under a new path. `checked`
/// is `total` unless the folder is large, then an even sample is checked.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MoveCheck {
    pub exists: bool,
    pub found: u64,
    pub checked: u64,
    pub total: u64,
}

/// Songs checked at most by [`Library::folder_check_move`].
pub const MOVE_CHECK_SAMPLE: usize = 2000;

fn windows_style(p: &str) -> bool {
    let b = p.as_bytes();
    cfg!(windows) || p.contains('\\') || (b.len() >= 2 && b[0].is_ascii_alphabetic() && b[1] == b':')
}

fn components(p: &str, windows: bool) -> Vec<&str> {
    let p = p.strip_prefix(r"\\?\").unwrap_or(p);
    let parts: Vec<&str> = if windows {
        p.split(['\\', '/']).collect()
    } else {
        p.split('/').collect()
    };
    // Keep a leading empty part (an absolute path), drop the others
    // (doubled or trailing separators).
    parts
        .iter()
        .enumerate()
        .filter(|(i, c)| *i == 0 || !c.is_empty())
        .map(|(_, c)| *c)
        .collect()
}

/// The components of `path` below `root`, or `None` when `path` is not
/// `root` or inside it. Only whole components match (`D:\Music2` is not
/// under `D:\Music`). Under a Windows-style root (drive letter, backslash,
/// or any root on Windows) paths match without case and with either
/// separator.
pub fn relative_components<'a>(path: &'a str, root: &str) -> Option<Vec<&'a str>> {
    // The root decides: on Unix a backslash is an ordinary file-name character.
    let windows = windows_style(root);
    let p = components(path, windows);
    let r = components(root, windows);
    if r.len() > p.len() {
        return None;
    }
    let same = |a: &str, b: &str| {
        if windows {
            a == b || a.to_lowercase() == b.to_lowercase()
        } else {
            a == b
        }
    };
    if !r.iter().zip(&p).all(|(a, b)| same(a, b)) {
        return None;
    }
    Some(p[r.len()..].to_vec())
}

/// `path` moved from under `old_root` to under `new_root`, written with
/// `new_root`'s separator; `None` when `path` is not under `old_root`.
pub fn rebase(path: &str, old_root: &str, new_root: &str) -> Option<String> {
    let rest = relative_components(path, old_root)?;
    if rest.is_empty() {
        return Some(new_root.to_string());
    }
    let sep = if windows_style(new_root) { '\\' } else { '/' };
    let base = new_root.trim_end_matches(['\\', '/']);
    let mut out = String::with_capacity(new_root.len() + path.len());
    out.push_str(base);
    for c in rest {
        out.push(sep);
        out.push_str(c);
    }
    Some(out)
}

/// Rewrites every stored path inside the user's data folder `old_root`
/// (playlist covers, downloaded album covers, artist pictures and their
/// undo records) to `new_root`. Used when a backup from another computer is
/// imported. Returns the number of rows changed.
pub fn rebase_data_paths(
    conn: &rusqlite::Connection,
    old_root: &str,
    new_root: &str,
) -> rusqlite::Result<usize> {
    let mut changed = 0;
    for (table, key, column) in [
        ("albums", "id", "cover"),
        ("playlists", "id", "cover"),
        ("artists_meta", "name_key", "image"),
        ("tag_history", "id", "path"),
    ] {
        let rows: Vec<(rusqlite::types::Value, String)> = {
            let mut st = conn.prepare(&format!(
                "SELECT {key}, {column} FROM {table} WHERE {column} IS NOT NULL"
            ))?;
            st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<rusqlite::Result<_>>()?
        };
        let mut up = conn.prepare(&format!("UPDATE {table} SET {column} = ?1 WHERE {key} = ?2"))?;
        for (k, old) in rows {
            if let Some(new) = rebase(&old, old_root, new_root)
                && new != old
            {
                changed += up.execute(rusqlite::params![new, k])?;
            }
        }
    }
    Ok(changed)
}

fn normalized_dir(path: &str) -> Option<String> {
    let p = Path::new(path);
    if !p.is_dir() {
        return None;
    }
    let canonical = std::fs::canonicalize(p).ok()?;
    Some(scan::display_path(&canonical))
}

impl Library {
    /// Every folder with whether its root is reachable now.
    pub fn folder_status(&self) -> Result<Vec<FolderStatus>> {
        Ok(self
            .folders()?
            .into_iter()
            .map(|f| FolderStatus {
                reachable: Path::new(&f.path).is_dir(),
                id: f.id,
                path: f.path,
            })
            .collect())
    }

    fn folder(&self, id: i64) -> Result<FolderInfo> {
        self.folders()?
            .into_iter()
            .find(|f| f.id == id)
            .ok_or_else(|| LibraryError::NotFound(format!("folder {id}")))
    }

    /// How many of the folder's songs exist under `new_path` (see
    /// [`MoveCheck`]). Reads only file metadata.
    pub fn folder_check_move(&self, folder_id: i64, new_path: &str) -> Result<MoveCheck> {
        let folder = self.folder(folder_id)?;
        let paths: Vec<String> = {
            let conn = self.conn();
            let mut st = conn.prepare("SELECT path FROM tracks WHERE folder_id = ?1 ORDER BY id")?;
            st.query_map([folder_id], |r| r.get(0))?
                .collect::<std::result::Result<_, _>>()?
        };
        let total = paths.len() as u64;
        let Some(new_root) = normalized_dir(new_path) else {
            return Ok(MoveCheck {
                exists: false,
                found: 0,
                checked: 0,
                total,
            });
        };
        let step = paths.len().div_ceil(MOVE_CHECK_SAMPLE).max(1);
        let (mut found, mut checked) = (0, 0);
        for p in paths.iter().step_by(step) {
            checked += 1;
            if rebase(p, &folder.path, &new_root).is_some_and(|n| Path::new(&n).is_file()) {
                found += 1;
            }
        }
        Ok(MoveCheck {
            exists: true,
            found,
            checked,
            total,
        })
    }

    /// Points the folder at `new_path`: the folder path, its tracks' paths
    /// (ids kept), their album covers inside the folder, and the history
    /// and tag-undo rows of those tracks are rewritten in one transaction.
    /// The caller rescans the folder afterwards.
    pub fn move_folder(&self, folder_id: i64, new_path: &str) -> Result<FolderInfo> {
        let folder = self.folder(folder_id)?;
        let new_root = normalized_dir(new_path)
            .ok_or_else(|| LibraryError::Other(format!("not a folder: {new_path}")))?;
        if new_root == folder.path {
            return Ok(folder);
        }
        if let Some(other) = self.folders()?.into_iter().find(|f| {
            f.id != folder_id && relative_components(&f.path, &new_root).is_some_and(|r| r.is_empty())
        }) {
            return Err(LibraryError::Other(format!(
                "{} is already a library folder",
                other.path
            )));
        }
        let mut conn = self.conn();
        let tx = conn.transaction()?;
        let tracks: Vec<(i64, String)> = {
            let mut st = tx.prepare("SELECT id, path FROM tracks WHERE folder_id = ?1")?;
            st.query_map([folder_id], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<std::result::Result<_, _>>()?
        };
        let moved: HashMap<String, (i64, String)> = tracks
            .into_iter()
            .filter_map(|(id, old)| {
                let new = rebase(&old, &folder.path, &new_root)?;
                Some((old, (id, new)))
            })
            .collect();
        tx.execute(
            "UPDATE folders SET path = ?1 WHERE id = ?2",
            rusqlite::params![new_root, folder_id],
        )?;
        {
            // Two passes: a new path may equal another track's old one
            // (moving a folder into its own subfolder).
            let mut up = tx.prepare("UPDATE tracks SET path = ?1 WHERE id = ?2")?;
            for (id, _) in moved.values() {
                up.execute(rusqlite::params![format!("\0moving:{id}"), id])?;
            }
            for (id, new) in moved.values() {
                up.execute(rusqlite::params![new, id])?;
            }
        }
        {
            let covers: Vec<(i64, String)> = {
                let mut st = tx.prepare(
                    "SELECT DISTINCT a.id, a.cover FROM albums a JOIN tracks t ON t.album_id = a.id
                     WHERE t.folder_id = ?1 AND a.cover IS NOT NULL",
                )?;
                st.query_map([folder_id], |r| Ok((r.get(0)?, r.get(1)?)))?
                    .collect::<std::result::Result<_, _>>()?
            };
            let mut up = tx.prepare("UPDATE albums SET cover = ?1 WHERE id = ?2")?;
            for (id, cover) in covers {
                if let Some(new) = rebase(&cover, &folder.path, &new_root) {
                    up.execute(rusqlite::params![new, id])?;
                }
            }
        }
        for table in ["listen_events", "tag_history"] {
            let rows: Vec<(i64, String)> = {
                let mut st = tx.prepare(&format!("SELECT id, path FROM {table}"))?;
                st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                    .collect::<std::result::Result<_, _>>()?
            };
            let mut up = tx.prepare(&format!("UPDATE {table} SET path = ?1 WHERE id = ?2"))?;
            for (id, old) in rows {
                if let Some((_, new)) = moved.get(&old) {
                    up.execute(rusqlite::params![new, id])?;
                }
            }
        }
        tx.commit()?;
        drop(conn);
        log::info!(
            "moved library folder {} to {new_root} ({} tracks)",
            folder.path,
            moved.len()
        );
        self.bump();
        Ok(FolderInfo {
            id: folder_id,
            path: new_root,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_whole_components_match() {
        assert_eq!(
            rebase(r"D:\Music\a\b.flac", r"D:\Music", r"E:\Songs"),
            Some(r"E:\Songs\a\b.flac".into())
        );
        assert_eq!(rebase(r"D:\Music2\b.flac", r"D:\Music", r"E:\Songs"), None);
        assert_eq!(rebase("/music2/b.flac", "/music", "/new"), None);
        assert_eq!(rebase("/music/b.flac", "/music/", "/new/"), Some("/new/b.flac".into()));
        assert_eq!(rebase("/music", "/music", "/new"), Some("/new".into()));
        assert_eq!(rebase("/a/b.flac", "/", "/new"), Some("/new/a/b.flac".into()));
    }

    #[test]
    fn windows_paths_ignore_case_and_separator_style() {
        assert_eq!(
            rebase(r"d:\MUSIC\Rock/x.mp3", r"D:\Music\", r"\\nas\share\Music"),
            Some(r"\\nas\share\Music\Rock\x.mp3".into())
        );
        assert_eq!(
            rebase(r"\\?\D:\Music\x.mp3", r"D:\Music", "E:\\"),
            Some(r"E:\x.mp3".into())
        );
        // Windows to a Unix-style root (backup from a PC on a Mac).
        assert_eq!(
            rebase(r"C:\Users\me\Music\x.mp3", r"C:\Users\me\Music", "/Users/me/Music"),
            Some("/Users/me/Music/x.mp3".into())
        );
        // Unix paths keep case, and a backslash is part of a name.
        if !cfg!(windows) {
            assert_eq!(rebase("/Music/x.mp3", "/music", "/new"), None);
            assert_eq!(
                rebase(r"/music/AC\DC/x.mp3", "/music", "/new"),
                Some(r"/new/AC\DC/x.mp3".into())
            );
        }
    }
}

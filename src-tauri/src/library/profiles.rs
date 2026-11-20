//! Profiles (decision K24, `docs/PROFILES.md`): several people share one
//! library, each with their own favourites, playlists and listening history.
//!
//! Profiles are separation, not security. Every database function that
//! touches per-profile data takes a [`ProfileId`] explicitly (see `db.rs`);
//! [`Library`] passes its active profile.

use super::{Library, LibraryError, Result, unix_now};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use std::sync::atomic::Ordering;

/// The id of a profile (`profiles.id`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ProfileId(pub i64);

impl ProfileId {
    /// The profile every pre-profiles database migrates into.
    pub const FIRST: ProfileId = ProfileId(1);
}

/// At most this many profiles exist at once.
pub const MAX_PROFILES: usize = 8;
/// Longest profile name, in characters (after trimming).
pub const MAX_NAME_CHARS: usize = 40;

/// Profile colours: pleasant and distinct on dark and light themes.
pub const PROFILE_COLORS: [&str; 8] = [
    "#3e63dd", "#e5484d", "#30a46c", "#f76b15", "#8e4ec6", "#12a594", "#d6409f", "#e5a50a",
];

/// Name of the first profile when nothing better is known.
pub const DEFAULT_FIRST_PROFILE_NAME: &str = "Profile 1";

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    pub id: ProfileId,
    pub name: String,
    pub color: String,
    pub created_at: i64,
}

/// What deleting a profile would remove (shown in the confirmation).
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProfileSummary {
    pub favorites: u64,
    pub playlists: u64,
    pub listens: u64,
}

/// The first profile's default name: the OS user when known.
pub fn default_first_profile_name() -> String {
    ["USERNAME", "USER"]
        .iter()
        .filter_map(|k| std::env::var(k).ok())
        .map(|v| v.trim().chars().take(MAX_NAME_CHARS).collect::<String>())
        .map(|v| v.trim().to_owned())
        .find(|v| !v.is_empty())
        .unwrap_or_else(|| DEFAULT_FIRST_PROFILE_NAME.to_owned())
}

fn clean_profile_name(name: &str) -> Result<String> {
    let name = name.trim();
    if name.is_empty() {
        return Err(LibraryError::Other("profile name must not be empty".into()));
    }
    if name.chars().count() > MAX_NAME_CHARS {
        return Err(LibraryError::Other(format!(
            "profile name must be at most {MAX_NAME_CHARS} characters"
        )));
    }
    Ok(name.to_owned())
}

fn profile_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Profile> {
    Ok(Profile {
        id: ProfileId(r.get(0)?),
        name: r.get(1)?,
        color: r.get(2)?,
        created_at: r.get(3)?,
    })
}

fn profile_not_found(id: ProfileId) -> LibraryError {
    LibraryError::NotFound(format!("profile {}", id.0))
}

pub fn profiles(conn: &Connection) -> Result<Vec<Profile>> {
    let mut st = conn.prepare("SELECT id, name, color, created_at FROM profiles ORDER BY id")?;
    let rows = st.query_map([], profile_row)?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub fn profile_exists(conn: &Connection, id: ProfileId) -> Result<bool> {
    Ok(conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM profiles WHERE id = ?1)",
        [id.0],
        |r| r.get(0),
    )?)
}

fn name_taken(conn: &Connection, name: &str, except: Option<ProfileId>) -> Result<bool> {
    let wanted = name.to_lowercase();
    Ok(profiles(conn)?
        .iter()
        .any(|p| Some(p.id) != except && p.name.to_lowercase() == wanted))
}

pub fn create_profile(conn: &Connection, name: &str, now: i64) -> Result<Profile> {
    let name = clean_profile_name(name)?;
    let existing = profiles(conn)?;
    if existing.len() >= MAX_PROFILES {
        return Err(LibraryError::Other(format!(
            "at most {MAX_PROFILES} profiles are allowed"
        )));
    }
    if name_taken(conn, &name, None)? {
        return Err(LibraryError::Other(format!(
            "a profile named \"{name}\" already exists"
        )));
    }
    let color = PROFILE_COLORS
        .iter()
        .find(|c| !existing.iter().any(|p| p.color.eq_ignore_ascii_case(c)))
        .unwrap_or(&PROFILE_COLORS[existing.len() % PROFILE_COLORS.len()]);
    conn.execute(
        "INSERT INTO profiles(name, color, created_at) VALUES (?1, ?2, ?3)",
        rusqlite::params![name, color, now],
    )?;
    Ok(Profile {
        id: ProfileId(conn.last_insert_rowid()),
        name,
        color: (*color).to_owned(),
        created_at: now,
    })
}

pub fn rename_profile(conn: &Connection, id: ProfileId, name: &str) -> Result<()> {
    let name = clean_profile_name(name)?;
    if name_taken(conn, &name, Some(id))? {
        return Err(LibraryError::Other(format!(
            "a profile named \"{name}\" already exists"
        )));
    }
    let n = conn.execute(
        "UPDATE profiles SET name = ?2 WHERE id = ?1",
        rusqlite::params![id.0, name],
    )?;
    if n == 0 {
        return Err(profile_not_found(id));
    }
    Ok(())
}

pub fn set_profile_color(conn: &Connection, id: ProfileId, color: &str) -> Result<()> {
    let Some(color) = PROFILE_COLORS
        .iter()
        .find(|c| c.eq_ignore_ascii_case(color.trim()))
    else {
        return Err(LibraryError::Other("unknown profile colour".into()));
    };
    let n = conn.execute(
        "UPDATE profiles SET color = ?2 WHERE id = ?1",
        rusqlite::params![id.0, color],
    )?;
    if n == 0 {
        return Err(profile_not_found(id));
    }
    Ok(())
}

pub fn profile_summary(conn: &Connection, id: ProfileId) -> Result<ProfileSummary> {
    if !profile_exists(conn, id)? {
        return Err(profile_not_found(id));
    }
    let count = |sql: &str| -> Result<u64> {
        let n: i64 = conn.query_row(sql, [id.0], |r| r.get(0))?;
        Ok(u64::try_from(n).unwrap_or(0))
    };
    Ok(ProfileSummary {
        favorites: count("SELECT COUNT(*) FROM favorites WHERE profile_id = ?1")?,
        playlists: count("SELECT COUNT(*) FROM playlists WHERE profile_id = ?1")?,
        listens: count("SELECT COUNT(*) FROM listen_events WHERE profile_id = ?1")?,
    })
}

/// Deletes the profile and, by cascade, its favourites, playlists and
/// listening history. Returns the cover values of its playlists so the
/// caller can remove the image files.
pub fn delete_profile(
    conn: &mut Connection,
    id: ProfileId,
    active: ProfileId,
) -> Result<Vec<String>> {
    let tx = conn.transaction()?;
    if !profile_exists(&tx, id)? {
        return Err(profile_not_found(id));
    }
    if id == active {
        return Err(LibraryError::Other(
            "the active profile cannot be deleted; switch to another profile first".into(),
        ));
    }
    if profiles(&tx)?.len() <= 1 {
        return Err(LibraryError::Other(
            "the last profile cannot be deleted".into(),
        ));
    }
    let covers: Vec<String> = {
        let mut st = tx.prepare(
            "SELECT cover FROM playlists
             WHERE profile_id = ?1 AND cover IS NOT NULL AND cover NOT LIKE 'preset:%'",
        )?;
        st.query_map([id.0], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?
    };
    // Explicit deletes as well as the cascade, so a connection that somehow
    // runs with foreign keys off still leaves no orphans.
    tx.execute(
        "DELETE FROM playlist_tracks WHERE playlist_id IN
             (SELECT id FROM playlists WHERE profile_id = ?1)",
        [id.0],
    )?;
    tx.execute("DELETE FROM playlists WHERE profile_id = ?1", [id.0])?;
    tx.execute("DELETE FROM favorites WHERE profile_id = ?1", [id.0])?;
    tx.execute("DELETE FROM listen_events WHERE profile_id = ?1", [id.0])?;
    tx.execute("DELETE FROM profiles WHERE id = ?1", [id.0])?;
    tx.commit()?;
    Ok(covers)
}

impl Library {
    /// The profile whose favourites, playlists and history every method
    /// without an explicit profile uses.
    pub fn active_profile(&self) -> ProfileId {
        ProfileId(self.active.load(Ordering::SeqCst))
    }

    /// Makes `id` the active profile and tells the host to reload.
    pub fn set_active_profile(&self, id: ProfileId) -> Result<()> {
        if !profile_exists(&self.conn(), id)? {
            return Err(profile_not_found(id));
        }
        self.active.store(id.0, Ordering::SeqCst);
        self.bump();
        Ok(())
    }

    pub fn profiles(&self) -> Result<Vec<Profile>> {
        profiles(&self.conn())
    }

    pub fn create_profile(&self, name: &str) -> Result<Profile> {
        let p = create_profile(&self.conn(), name, unix_now())?;
        self.bump();
        Ok(p)
    }

    pub fn rename_profile(&self, id: ProfileId, name: &str) -> Result<()> {
        rename_profile(&self.conn(), id, name)?;
        self.bump();
        Ok(())
    }

    pub fn set_profile_color(&self, id: ProfileId, color: &str) -> Result<()> {
        set_profile_color(&self.conn(), id, color)?;
        self.bump();
        Ok(())
    }

    pub fn profile_summary(&self, id: ProfileId) -> Result<ProfileSummary> {
        profile_summary(&self.conn(), id)
    }

    /// Deletes a profile with its data. The last profile and the active one
    /// are refused.
    pub fn delete_profile(&self, id: ProfileId) -> Result<()> {
        let covers = delete_profile(&mut self.conn(), id, self.active_profile())?;
        for cover in covers {
            self.remove_playlist_cover_if_cached(Some(cover));
        }
        self.bump();
        Ok(())
    }

    /// Whether the profile exists (for validating a remembered id).
    pub fn profile_exists(&self, id: ProfileId) -> Result<bool> {
        profile_exists(&self.conn(), id)
    }
}

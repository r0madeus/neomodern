//! Profiles (decision K24, `docs/PROFILES.md`): Tauri commands to list,
//! manage and switch the people who use this app. The data lives in the
//! library database (per-profile favourites, playlists, listens) and in the
//! session file (per-profile queue, pins, autoplay); this module ties the two
//! together when switching.

use crate::library::{Library, Profile, ProfileId, ProfileSummary};
use crate::player::{Player, PlayerSnapshot};
use crate::session::SessionStore;
use crate::sync::SyncService;
use serde::Serialize;
use std::sync::Arc;
use tauri::{AppHandle, Emitter, State};

type Res<T> = Result<T, String>;

fn le<T>(r: Result<T, crate::library::LibraryError>) -> Res<T> {
    r.map_err(|e| e.to_string())
}

/// The profiles and which one is in use.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfilesState {
    pub active: i64,
    pub profiles: Vec<Profile>,
    /// The colours a profile can have.
    pub colors: Vec<String>,
    pub max_profiles: usize,
}

fn state(lib: &Library) -> Res<ProfilesState> {
    Ok(ProfilesState {
        active: lib.active_profile().0,
        profiles: le(lib.profiles())?,
        colors: crate::library::PROFILE_COLORS
            .iter()
            .map(|c| (*c).to_owned())
            .collect(),
        max_profiles: crate::library::MAX_PROFILES,
    })
}

fn changed(app: &AppHandle, s: &ProfilesState) {
    if let Err(e) = app.emit("profiles://changed", s) {
        log::warn!("failed to emit profiles change event: {e}");
    }
}

#[tauri::command(async)]
pub fn profiles_list(lib: State<'_, Arc<Library>>) -> Res<ProfilesState> {
    state(&lib)
}

/// Adds a profile (it is not switched to).
#[tauri::command(async)]
pub fn profile_create(
    app: AppHandle,
    lib: State<'_, Arc<Library>>,
    name: String,
) -> Res<ProfilesState> {
    le(lib.create_profile(&name))?;
    let s = state(&lib)?;
    changed(&app, &s);
    Ok(s)
}

#[tauri::command(async)]
pub fn profile_rename(
    app: AppHandle,
    lib: State<'_, Arc<Library>>,
    id: i64,
    name: String,
) -> Res<ProfilesState> {
    le(lib.rename_profile(ProfileId(id), &name))?;
    let s = state(&lib)?;
    changed(&app, &s);
    Ok(s)
}

#[tauri::command(async)]
pub fn profile_set_color(
    app: AppHandle,
    lib: State<'_, Arc<Library>>,
    id: i64,
    color: String,
) -> Res<ProfilesState> {
    le(lib.set_profile_color(ProfileId(id), &color))?;
    let s = state(&lib)?;
    changed(&app, &s);
    Ok(s)
}

/// What deleting the profile would remove, for the confirmation.
#[tauri::command(async)]
pub fn profile_summary(lib: State<'_, Arc<Library>>, id: i64) -> Res<ProfileSummary> {
    le(lib.profile_summary(ProfileId(id)))
}

/// Deletes a profile that is not in use, with its favourites, playlists,
/// listens, parked queue and pins (the last profile cannot be deleted).
#[tauri::command]
pub async fn profile_delete(
    app: AppHandle,
    lib: State<'_, Arc<Library>>,
    store: State<'_, Arc<SessionStore>>,
    player: State<'_, Arc<Player>>,
    sync: State<'_, SyncService>,
    id: i64,
) -> Res<ProfilesState> {
    if lib.active_profile().0 == id {
        return Err("switch to another profile before deleting this one".into());
    }
    le(lib.delete_profile(ProfileId(id)))?;
    // The database removed the profile's pairings; the sync service forgets
    // their sessions and secrets.
    sync.profile_deleted(ProfileId(id)).await?;
    store.forget_profile(id);
    store.save_now(&player.export_session());
    let s = state(&lib)?;
    changed(&app, &s);
    Ok(s)
}

/// Switches to profile `id`: the current profile's queue and position are
/// kept for later and its running listen is recorded for it; the other
/// profile's queue is loaded paused where it was left.
#[tauri::command]
pub async fn profile_switch(
    app: AppHandle,
    lib: State<'_, Arc<Library>>,
    store: State<'_, Arc<SessionStore>>,
    player: State<'_, Arc<Player>>,
    sync: State<'_, SyncService>,
    id: i64,
) -> Res<PlayerSnapshot> {
    switch(&lib, &store, &player, ProfileId(id))?;
    // The phone talks to the computer the new profile is paired with.
    if let Err(e) = sync.profile_switched().await {
        log::warn!("sync: could not follow the profile switch: {e}");
    }
    let s = state(&lib)?;
    changed(&app, &s);
    Ok(player.snapshot())
}

/// The switch itself, in the order that keeps each profile's data its own.
pub fn switch(lib: &Library, store: &SessionStore, player: &Player, to: ProfileId) -> Res<()> {
    if lib.active_profile() == to {
        return Ok(());
    }
    if !le(lib.profiles())?.iter().any(|p| p.id == to) {
        return Err("no such profile".into());
    }
    // 1. Stop: the running listen is recorded while the old profile is
    //    still active in the library.
    let leaving = player.take_for_profile_switch();
    // 2. Park the old profile's queue and pins; get the new one's.
    let next = store.switch_profile(leaving, to.0);
    // 3. Library queries now answer for the new profile (and the UI is told
    //    through the library change event).
    le(lib.set_active_profile(to))?;
    // 4. Load the new profile's queue, paused.
    player.load_profile_state(next);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::Hooks;
    use crate::player::PlayerEvent;
    use crate::player::bulk_tests::Silent;
    use crate::queue::Track;
    use std::path::PathBuf;
    use std::sync::Mutex;

    struct Setup {
        _tmp: tempfile::TempDir,
        lib: Arc<Library>,
        store: SessionStore,
        player: Player,
        /// (profile active when a listen arrived, its path)
        listens: Arc<Mutex<Vec<(i64, String)>>>,
    }

    fn setup() -> Setup {
        let tmp = tempfile::TempDir::new().unwrap();
        let lib = Arc::new(
            Library::open(
                &tmp.path().join("lib.sqlite3"),
                &tmp.path().join("covers"),
                Hooks::none(),
            )
            .unwrap(),
        );
        let store = SessionStore::new(tmp.path().join("session.json"));
        store.load();
        let listens = Arc::new(Mutex::new(Vec::new()));
        let (seen, l) = (Arc::clone(&listens), Arc::clone(&lib));
        let player = Player::new(
            Box::new(Silent),
            Box::new(move |e| {
                if let PlayerEvent::Listen(rec) = e {
                    seen.lock().unwrap().push((l.active_profile().0, rec.path));
                }
            }),
        );
        Setup {
            _tmp: tmp,
            lib,
            store,
            player,
            listens,
        }
    }

    fn queue(p: &Player) -> Vec<String> {
        p.queue_page(0, 100).into_iter().map(|t| t.path).collect()
    }

    #[test]
    fn each_profile_gets_its_own_queue_back_and_listens_stay_with_their_profile() {
        let s = setup();
        let two = s.lib.create_profile("Zeynep").unwrap().id;
        let tracks = |v: &[&str]| {
            v.iter()
                .map(|p| Track::from(PathBuf::from(p)))
                .collect::<Vec<_>>()
        };
        s.player
            .replace_queue(tracks(&["a.flac", "b.flac"]), 1)
            .unwrap();
        // Long enough to count as a listen.
        s.player
            .add_listened_for_test(std::time::Duration::from_secs(30));

        switch(&s.lib, &s.store, &s.player, two).unwrap();
        assert_eq!(s.lib.active_profile(), two);
        assert!(
            queue(&s.player).is_empty(),
            "a new profile starts with an empty queue"
        );
        assert_eq!(s.player.snapshot().status, crate::player::Status::Stopped);
        // Whatever was being heard counted for profile 1, not for the new one.
        assert_eq!(*s.listens.lock().unwrap(), vec![(1, "b.flac".to_owned())]);

        s.player.replace_queue(tracks(&["z.flac"]), 0).unwrap();
        switch(&s.lib, &s.store, &s.player, ProfileId::FIRST).unwrap();
        assert_eq!(queue(&s.player), ["a.flac", "b.flac"]);
        assert_eq!(s.player.snapshot().current_index, Some(1));
        // Loaded but not playing, like after a restart.
        assert_ne!(s.player.snapshot().status, crate::player::Status::Playing);

        switch(&s.lib, &s.store, &s.player, two).unwrap();
        assert_eq!(queue(&s.player), ["z.flac"]);
        // Switching to the profile in use, or to one that does not exist,
        // changes nothing.
        switch(&s.lib, &s.store, &s.player, two).unwrap();
        assert_eq!(queue(&s.player), ["z.flac"]);
        assert!(switch(&s.lib, &s.store, &s.player, ProfileId(99)).is_err());
        assert_eq!(s.lib.active_profile(), two);
    }
}

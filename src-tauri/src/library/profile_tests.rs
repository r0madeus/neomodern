//! Profiles (K24): migration to schema v14, the profile rules, and the
//! isolation of every per-profile read and write.

use super::{
    BEFORE_PROFILES_BACKUP, Hooks, Library, MAX_PROFILES, NewListenEvent, PROFILE_COLORS,
    ProfileId, SortOrder, autoplay, db,
};
use rusqlite::Connection;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use tempfile::TempDir;

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

// ---------------------------------------------------------------- migration

/// A hand-written schema v13 database (before profiles) with data.
fn write_v13_database(path: &Path) {
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(db::SCHEMA_V1).unwrap();
    conn.execute_batch(db::SCHEMA_V2).unwrap();
    conn.execute_batch(db::SCHEMA_V9).unwrap();
    conn.execute_batch(db::SCHEMA_V13).unwrap();
    conn.execute_batch(
        "ALTER TABLE playlists ADD COLUMN cover TEXT;
         ALTER TABLE playlist_tracks ADD COLUMN added_at INTEGER;
         CREATE TABLE favorites (
             track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
             added_at INTEGER NOT NULL
         );
         CREATE INDEX favorites_added ON favorites(added_at DESC);
         CREATE TABLE listen_events (
             id INTEGER PRIMARY KEY,
             track_id INTEGER REFERENCES tracks(id) ON DELETE SET NULL,
             path TEXT NOT NULL,
             title TEXT NOT NULL COLLATE NOCASE,
             artist TEXT NOT NULL COLLATE NOCASE,
             album TEXT NOT NULL COLLATE NOCASE,
             genre TEXT NOT NULL COLLATE NOCASE,
             duration_ms INTEGER,
             started_at INTEGER NOT NULL,
             ended_at INTEGER NOT NULL,
             listened_ms INTEGER NOT NULL,
             completed INTEGER NOT NULL DEFAULT 0,
             skipped INTEGER NOT NULL DEFAULT 0,
             source TEXT NOT NULL DEFAULT 'local',
             uid TEXT
         );
         CREATE INDEX listen_events_started ON listen_events(started_at DESC);
         CREATE INDEX listen_events_artist ON listen_events(artist, started_at);
         CREATE INDEX listen_events_track ON listen_events(track_id);
         CREATE INDEX listen_events_path ON listen_events(path);
         CREATE UNIQUE INDEX listen_events_uid ON listen_events(uid);
         CREATE TABLE track_artists (
             track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
             artist TEXT NOT NULL COLLATE NOCASE,
             position INTEGER NOT NULL,
             PRIMARY KEY (track_id, artist)
         );
         CREATE TABLE artists_meta (
             name_key TEXT PRIMARY KEY COLLATE NOCASE,
             display TEXT NOT NULL, image TEXT, bio TEXT, fetched_at INTEGER NOT NULL
         );
         INSERT INTO folders(id, path) VALUES (1, '/m');
         INSERT INTO albums(id, title, album_artist) VALUES (1, 'Gold', 'Artist');
         INSERT INTO tracks(id, folder_id, path, mtime, size, title, artist, album_id, added_at)
         VALUES (10, 1, '/m/a.flac', 1, 1, 'A', 'Artist', 1, 1),
                (11, 1, '/m/b.flac', 1, 1, 'B', 'Artist', 1, 2),
                (12, 1, '/m/c.flac', 1, 1, 'C', 'Artist', 1, 3);
         INSERT INTO favorites(track_id, added_at) VALUES (10, 100), (12, 300);
         INSERT INTO playlists(id, name, created_at, cover) VALUES (1, 'Mix', 5, 'preset:blue');
         INSERT INTO playlist_tracks(playlist_id, position, track_id, added_at)
         VALUES (1, 0, 10, 6), (1, 1, 11, 7);
         INSERT INTO listen_events(track_id, path, title, artist, album, genre, duration_ms,
                                   started_at, ended_at, listened_ms, completed, uid)
         VALUES (10, '/m/a.flac', 'A', 'Artist', 'Gold', '', 1000, 50, 60, 1000, 1, 'u1'),
                (NULL, '/gone.mp3', 'Z', 'Zed', '', '', NULL, 70, 80, 20000, 0, 'u2');
         PRAGMA user_version = 13;",
    )
    .unwrap();
}

#[test]
fn migrating_a_v13_database_puts_everything_in_profile_1_and_keeps_a_copy() {
    let tmp = TempDir::new().unwrap();
    let db_path = tmp.path().join("data/library.sqlite3");
    std::fs::create_dir_all(db_path.parent().unwrap()).unwrap();
    write_v13_database(&db_path);

    let lib = Library::open_with_first_profile_name(
        &db_path,
        &tmp.path().join("covers"),
        Hooks::none(),
        "  Alice ",
    )
    .unwrap();

    let profiles = lib.profiles().unwrap();
    assert_eq!(profiles.len(), 1);
    assert_eq!(profiles[0].id, ProfileId::FIRST);
    assert_eq!(profiles[0].name, "  Alice "); // the caller's name, stored as given
    assert_eq!(profiles[0].color, PROFILE_COLORS[0]);
    assert_eq!(lib.active_profile(), ProfileId::FIRST);

    // Data is intact and visible through the active (first) profile.
    let favs: Vec<i64> = lib
        .favorites()
        .unwrap()
        .iter()
        .map(|f| f.track_id)
        .collect();
    assert_eq!(favs, vec![12, 10], "newest first");
    let lists = lib.playlists().unwrap();
    assert_eq!(lists.len(), 1);
    assert_eq!(lists[0].track_count, 2);
    assert_eq!(lists[0].cover.as_deref(), Some("preset:blue"));
    let stats = lib.listening_stats(None, None).unwrap();
    assert_eq!(stats.summary.raw_event_count, 2);
    assert_eq!(stats.summary.play_count, 2);

    let c = lib.conn();
    let count = |sql: &str| -> i64 { c.query_row(sql, [], |r| r.get(0)).unwrap() };
    assert_eq!(
        count("SELECT COUNT(*) FROM favorites WHERE profile_id = 1"),
        2
    );
    assert_eq!(
        count("SELECT COUNT(*) FROM playlists WHERE profile_id = 1"),
        1
    );
    assert_eq!(
        count("SELECT COUNT(*) FROM listen_events WHERE profile_id = 1"),
        2
    );
    assert_eq!(count("PRAGMA user_version"), 16);
    assert_eq!(
        count("SELECT COUNT(*) FROM pragma_foreign_key_list('favorites')"),
        2
    );
    assert_eq!(count("PRAGMA foreign_keys"), 1);
    assert_eq!(count("SELECT COUNT(*) FROM pragma_foreign_key_check"), 0);
    // The old per-listen indexes were replaced by profile-leading ones.
    for gone in [
        "listen_events_started",
        "listen_events_track",
        "listen_events_path",
    ] {
        assert_eq!(
            count(&format!(
                "SELECT COUNT(*) FROM sqlite_master WHERE name = '{gone}'"
            )),
            0,
            "{gone}"
        );
    }
    drop(c);

    // The copy was written before the rebuild and still has the old shape.
    let backup = tmp.path().join("data").join(BEFORE_PROFILES_BACKUP);
    assert!(backup.is_file());
    let copy = Connection::open(&backup).unwrap();
    let v: i64 = copy
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(v, 13);
    let has_profile_col: bool = copy
        .query_row(
            "SELECT COUNT(*) > 0 FROM pragma_table_info('favorites') WHERE name = 'profile_id'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(!has_profile_col);
    let n: i64 = copy
        .query_row("SELECT COUNT(*) FROM favorites", [], |r| r.get(0))
        .unwrap();
    assert_eq!(n, 2);
}

#[test]
fn an_existing_backup_is_kept_and_reopening_changes_nothing() {
    let tmp = TempDir::new().unwrap();
    let db_path = tmp.path().join("library.sqlite3");
    write_v13_database(&db_path);
    let backup = tmp.path().join(BEFORE_PROFILES_BACKUP);
    std::fs::write(&backup, b"precious").unwrap();
    {
        let lib = Library::open(&db_path, &tmp.path().join("c"), Hooks::none()).unwrap();
        assert_eq!(lib.profiles().unwrap().len(), 1);
    }
    assert_eq!(std::fs::read(&backup).unwrap(), b"precious");
    // Reopening a v14 database is a no-op.
    let lib = Library::open(&db_path, &tmp.path().join("c"), Hooks::none()).unwrap();
    assert_eq!(lib.profiles().unwrap().len(), 1);
    assert_eq!(lib.favorites().unwrap().len(), 2);
}

#[test]
fn a_fresh_database_gets_profile_1_and_no_copy() {
    let tmp = TempDir::new().unwrap();
    let db_path = tmp.path().join("library.sqlite3");
    let lib = Library::open(&db_path, &tmp.path().join("c"), Hooks::none()).unwrap();
    let profiles = lib.profiles().unwrap();
    assert_eq!(profiles.len(), 1);
    assert_eq!(profiles[0].id, ProfileId::FIRST);
    assert!(!profiles[0].name.trim().is_empty());
    assert!(!tmp.path().join(BEFORE_PROFILES_BACKUP).exists());
}

// -------------------------------------------------------------------- rules

fn empty_lib() -> (TempDir, Library) {
    let tmp = TempDir::new().unwrap();
    let lib = Library::open_with_first_profile_name(
        &tmp.path().join("library.sqlite3"),
        &tmp.path().join("covers"),
        Hooks::none(),
        "Alice",
    )
    .unwrap();
    (tmp, lib)
}

#[test]
fn profile_names_are_trimmed_limited_and_unique_ignoring_case() {
    let (_t, lib) = empty_lib();
    let bob = lib.create_profile("  Bob  ").unwrap();
    assert_eq!(bob.name, "Bob");
    assert_eq!(bob.id, ProfileId(2));
    assert!(lib.create_profile("   ").is_err());
    assert!(lib.create_profile(&"x".repeat(41)).is_err());
    assert!(lib.create_profile(&"x".repeat(40)).is_ok());
    assert!(lib.create_profile("BOB").is_err());
    assert!(lib.create_profile("alice").is_err());
    // Renaming: own name in another case is fine, someone else's is not.
    lib.rename_profile(bob.id, "bOB").unwrap();
    assert!(lib.rename_profile(bob.id, "ALICE").is_err());
    assert!(lib.rename_profile(bob.id, "").is_err());
    assert!(lib.rename_profile(ProfileId(99), "Nobody").is_err());
    let names: Vec<String> = lib
        .profiles()
        .unwrap()
        .into_iter()
        .map(|p| p.name)
        .collect();
    assert_eq!(names[..2], ["Alice".to_owned(), "bOB".to_owned()]);
}

#[test]
fn at_most_eight_profiles_with_distinct_palette_colours() {
    let (_t, lib) = empty_lib();
    for i in 2..=MAX_PROFILES {
        lib.create_profile(&format!("P{i}")).unwrap();
    }
    assert!(lib.create_profile("One too many").is_err());
    let profiles = lib.profiles().unwrap();
    assert_eq!(profiles.len(), MAX_PROFILES);
    let colors: BTreeSet<&str> = profiles.iter().map(|p| p.color.as_str()).collect();
    assert_eq!(
        colors.len(),
        MAX_PROFILES,
        "every profile has its own colour"
    );
    assert!(
        profiles
            .iter()
            .all(|p| PROFILE_COLORS.contains(&p.color.as_str()))
    );
    // Deleting frees a slot, and the new profile takes the freed colour.
    let freed = profiles[3].clone();
    lib.delete_profile(freed.id).unwrap();
    let again = lib.create_profile("Again").unwrap();
    assert_eq!(again.color, freed.color);
    assert_ne!(again.id, freed.id, "ids are never reused");
}

#[test]
fn colours_must_come_from_the_palette() {
    let (_t, lib) = empty_lib();
    assert!(lib.set_profile_color(ProfileId::FIRST, "#123456").is_err());
    assert!(lib.set_profile_color(ProfileId::FIRST, "red").is_err());
    assert!(
        lib.set_profile_color(ProfileId(9), PROFILE_COLORS[1])
            .is_err()
    );
    lib.set_profile_color(ProfileId::FIRST, &PROFILE_COLORS[5].to_uppercase())
        .unwrap();
    assert_eq!(lib.profiles().unwrap()[0].color, PROFILE_COLORS[5]);
}

#[test]
fn the_last_and_the_active_profile_cannot_be_deleted() {
    let (_t, lib) = empty_lib();
    assert!(lib.delete_profile(ProfileId::FIRST).is_err(), "last one");
    let bob = lib.create_profile("Bob").unwrap();
    assert!(lib.delete_profile(ProfileId::FIRST).is_err(), "active one");
    assert!(lib.delete_profile(ProfileId(77)).is_err(), "unknown");
    lib.set_active_profile(bob.id).unwrap();
    assert_eq!(lib.active_profile(), bob.id);
    assert!(lib.delete_profile(bob.id).is_err(), "now bob is active");
    lib.delete_profile(ProfileId::FIRST).unwrap();
    assert_eq!(lib.profiles().unwrap().len(), 1);
    assert!(lib.set_active_profile(ProfileId::FIRST).is_err(), "deleted");
    assert_eq!(
        lib.active_profile(),
        bob.id,
        "a refused switch changes nothing"
    );
}

#[test]
fn switching_profiles_notifies_the_host() {
    let (_t, lib) = empty_lib();
    let bob = lib.create_profile("Bob").unwrap();
    let before = lib.version();
    lib.set_active_profile(bob.id).unwrap();
    assert!(lib.version() > before);
}

// ---------------------------------------------------------------- isolation

struct Fx {
    tmp: TempDir,
    lib: Library,
    ids: Vec<i64>,
    paths: Vec<String>,
}

const ALICE: ProfileId = ProfileId::FIRST;
const BOB: ProfileId = ProfileId(2);

/// 12 songs: even ones by Alpha, odd by Beta; 0..6 Rock, 6..12 Jazz; three
/// songs per album. Two profiles, Alice (1, active) and Bob (2).
fn fixture() -> Fx {
    let (tmp, lib) = empty_lib();
    let bob = lib.create_profile("Bob").unwrap();
    assert_eq!(bob.id, BOB);
    let mut ids = Vec::new();
    let mut paths = Vec::new();
    {
        let conn = lib.conn();
        conn.execute("INSERT INTO folders(id, path) VALUES (1, '/m')", [])
            .unwrap();
        for a in 0..4 {
            conn.execute(
                "INSERT INTO albums(id, title, album_artist) VALUES (?1, ?2, 'Various')",
                rusqlite::params![a + 1, format!("Album {a}")],
            )
            .unwrap();
        }
        for i in 0..12i64 {
            let artist = if i % 2 == 0 { "Alpha" } else { "Beta" };
            let genre = if i < 6 { "Rock" } else { "Jazz" };
            let path = format!("/m/{i}.flac");
            conn.execute(
                "INSERT INTO tracks(folder_id, path, mtime, size, title, artist, album_id,
                                    track_no, genre, duration_ms, added_at)
                 VALUES (1, ?1, 1, 1, ?2, ?3, ?4, ?5, ?6, 200000, ?7)",
                rusqlite::params![
                    path,
                    format!("Song {i}"),
                    artist,
                    i / 3 + 1,
                    i % 3 + 1,
                    genre,
                    i
                ],
            )
            .unwrap();
            let id = conn.last_insert_rowid();
            db::sync_track_artists(&conn, id, artist).unwrap();
            ids.push(id);
            paths.push(path);
        }
    }
    Fx {
        tmp,
        lib,
        ids,
        paths,
    }
}

impl Fx {
    fn listen(&self, idx: usize, times: usize) {
        for k in 0..times {
            let started = now() - 1_000 - (idx as i64) * 100 - (k as i64) * 7_000;
            self.lib
                .record_listen_event(NewListenEvent {
                    path: self.paths[idx].clone(),
                    title: format!("Song {idx}"),
                    artist: if idx.is_multiple_of(2) {
                        "Alpha"
                    } else {
                        "Beta"
                    }
                    .into(),
                    duration_ms: Some(200_000),
                    started_at: started,
                    ended_at: started + 200,
                    listened_ms: 200_000,
                    completed: true,
                    skipped: false,
                })
                .unwrap();
        }
    }

    fn fav_ids(&self) -> BTreeSet<i64> {
        self.lib
            .favorites()
            .unwrap()
            .iter()
            .map(|f| f.track_id)
            .collect()
    }

    fn ids_of(&self, idxs: &[usize]) -> BTreeSet<i64> {
        idxs.iter().map(|&i| self.ids[i]).collect()
    }

    fn playlist_named(&self, name: &str) -> i64 {
        self.lib
            .playlists()
            .unwrap()
            .into_iter()
            .find(|p| p.name == name)
            .unwrap_or_else(|| panic!("no playlist {name}"))
            .id
    }

    /// Alice: favourites 0-3, playlists "Road" [0,1,2] and "Chill" [4],
    /// 13 plays. Bob: favourites 8,9, playlist "Road" [8,9,10,11], 11 plays.
    fn populate(&self) {
        self.lib.set_active_profile(ALICE).unwrap();
        self.lib
            .set_favorites(
                &self.ids_of(&[0, 1, 2, 3]).into_iter().collect::<Vec<_>>(),
                true,
            )
            .unwrap();
        self.lib.create_playlist("Road", &self.ids[0..3]).unwrap();
        self.lib.create_playlist("Chill", &self.ids[4..5]).unwrap();
        for (idx, n) in [(0, 4), (1, 3), (2, 3), (3, 1), (4, 2)] {
            self.listen(idx, n);
        }
        self.lib.set_active_profile(BOB).unwrap();
        self.lib
            .set_favorites(&[self.ids[8], self.ids[9]], true)
            .unwrap();
        self.lib.create_playlist("Road", &self.ids[8..12]).unwrap();
        for (idx, n) in [(8, 3), (9, 3), (10, 2), (11, 2), (7, 1)] {
            self.listen(idx, n);
        }
    }
}

/// Everything the active profile can read, as JSON text per label.
fn snapshot(fx: &Fx) -> Vec<(String, String)> {
    let lib = &fx.lib;
    let n = now();
    let mut out: Vec<(String, String)> = Vec::new();
    let mut add = |label: &str, v: serde_json::Value| out.push((label.to_owned(), v.to_string()));
    add(
        "favorites",
        j(&lib
            .favorites()
            .unwrap()
            .iter()
            .map(|f| (f.track_id, f.path.clone()))
            .collect::<Vec<_>>()),
    );
    add("favorites_page", j(&lib.favorites_page(0, 100).unwrap()));
    add("favorites_page_2", j(&lib.favorites_page(1, 1).unwrap()));
    add(
        "favorites_queue",
        j(&lib
            .favorites_queue_tracks()
            .unwrap()
            .iter()
            .map(|t| t.path.clone())
            .collect::<Vec<_>>()),
    );
    let lists = lib.playlists().unwrap();
    add("playlists", j(&lists));
    for p in &lists {
        add(
            &format!("playlist {} tracks", p.id),
            j(&lib.playlist_tracks(p.id, 0, 100).unwrap()),
        );
        add(
            &format!("playlist {} queue", p.id),
            j(&lib
                .playlist_queue_tracks(p.id)
                .unwrap()
                .iter()
                .map(|t| t.path.clone())
                .collect::<Vec<_>>()),
        );
        add(
            &format!("playlist {} m3u", p.id),
            serde_json::json!(lib.export_m3u(p.id).unwrap()),
        );
    }
    for i in [0usize, 4, 8, 11] {
        add(
            &format!("playlists_with {i}"),
            j(&lib.playlists_with_track(fx.ids[i]).unwrap()),
        );
    }
    for (label, from, to) in [
        ("all", None, None),
        ("two days", Some(n - 2 * 86_400), Some(n + 100)),
        ("last hour", Some(n - 3_600), Some(n + 100)),
        ("long ago", Some(n - 400 * 86_400), Some(n - 300 * 86_400)),
    ] {
        add(
            &format!("stats {label}"),
            j(&lib.listening_stats(from, to).unwrap()),
        );
    }
    add("home", j(&lib.home_feed().unwrap()));
    for mix in ["weekly-favorites", "on-repeat", "rediscover", "focus-mix"] {
        add(&format!("mix {mix}"), j(&lib.home_mix_detail(mix).unwrap()));
        add(
            &format!("mix {mix} queue"),
            j(&lib
                .home_mix_queue_tracks(mix)
                .unwrap()
                .iter()
                .map(|t| t.path.clone())
                .collect::<Vec<_>>()),
        );
    }
    add("artists", j(&lib.search_artists_page(0, 50, "").unwrap()));
    add("artist Alpha", j(&lib.artist_profile("Alpha").unwrap()));
    add("artist Beta", j(&lib.artist_profile("Beta").unwrap()));
    add(
        "songs",
        j(&lib.tracks_page(0, 100, SortOrder::Title).unwrap()),
    );
    add(
        "songs search",
        j(&lib
            .search_tracks_page(0, 100, SortOrder::Title, "song 1")
            .unwrap()),
    );
    add("rock", j(&lib.genre_tracks_page("Rock", 0, 100).unwrap()));
    add("album 1", j(&lib.album(1).unwrap()));
    add("track 0", j(&lib.track_by_id(fx.ids[0]).unwrap()));
    add(
        "track 8 by path",
        j(&lib.track_row_by_path(&fx.paths[8]).unwrap()),
    );
    add(
        "autoplay stats",
        serde_json::json!(
            autoplay::profile_stats(&lib.conn(), lib.active_profile())
                .unwrap()
                .into_iter()
                .collect::<std::collections::BTreeMap<_, _>>()
        ),
    );
    out
}

fn j<T: serde::Serialize>(v: &T) -> serde_json::Value {
    serde_json::to_value(v).unwrap()
}

fn diff(a: &[(String, String)], b: &[(String, String)]) -> Vec<String> {
    assert_eq!(a.len(), b.len());
    a.iter()
        .zip(b)
        .filter(|(x, y)| x != y)
        .map(|(x, _)| x.0.clone())
        .collect()
}

fn titles(rows: &[super::TrackRow]) -> Vec<String> {
    rows.iter().map(|t| t.title.clone()).collect()
}

#[test]
fn every_read_returns_only_the_active_profiles_data() {
    let fx = fixture();
    fx.populate();
    let lib = &fx.lib;

    // --- Alice
    lib.set_active_profile(ALICE).unwrap();
    assert_eq!(fx.fav_ids(), fx.ids_of(&[0, 1, 2, 3]));
    assert_eq!(lib.favorites_page(0, 100).unwrap().total, 4);
    assert_eq!(lib.favorites_queue_tracks().unwrap().len(), 4);
    let names: Vec<String> = lib
        .playlists()
        .unwrap()
        .into_iter()
        .map(|p| p.name)
        .collect();
    assert_eq!(names, ["Chill", "Road"]);
    let road_a = fx.playlist_named("Road");
    assert_eq!(
        titles(&lib.playlist_tracks(road_a, 0, 100).unwrap()),
        ["Song 0", "Song 1", "Song 2"]
    );
    assert_eq!(lib.playlists_with_track(fx.ids[0]).unwrap(), vec![road_a]);
    assert!(lib.playlists_with_track(fx.ids[8]).unwrap().is_empty());
    let stats = lib.listening_stats(None, None).unwrap();
    assert_eq!(stats.summary.play_count, 13);
    assert_eq!(stats.summary.raw_event_count, 13);
    assert_eq!(stats.summary.unique_tracks, 5);
    assert_eq!(stats.top_tracks_by_plays[0].title, "Song 0");
    assert_eq!(stats.top_tracks_by_plays[0].play_count, 4);
    assert!(stats.recent.iter().all(|r| ["Song 0", "Song 1", "Song 2", "Song 3", "Song 4"].contains(&r.title.as_str())));
    let songs = lib.tracks_page(0, 100, SortOrder::Title).unwrap();
    let plays = |title: &str| songs.iter().find(|t| t.title == title).unwrap().plays;
    assert_eq!(
        (plays("Song 0"), plays("Song 8"), plays("Song 7")),
        (4, 0, 0)
    );
    let artists = lib.search_artists_page(0, 50, "").unwrap();
    let a = |n: &str| {
        artists
            .items
            .iter()
            .find(|r| r.name == n)
            .unwrap()
            .play_count
    };
    assert_eq!((a("Alpha"), a("Beta")), (9, 4));
    assert_eq!(lib.artist_profile("Alpha").unwrap().play_count, 9);
    let pop = lib.artist_profile("Beta").unwrap().popular_tracks;
    assert_eq!(pop[0].track.title, "Song 1");
    assert_eq!(pop[0].play_count, 3);
    let repeat = lib.home_mix_detail("on-repeat").unwrap().unwrap();
    assert_eq!(titles(&repeat.tracks).len(), 4);
    assert!(repeat.tracks.iter().all(|t| fx.ids[..5].contains(&t.id)));
    let feed = lib.home_feed().unwrap();
    assert_eq!(feed.favorite_count, 4);
    assert!(feed.has_history);
    assert!(
        feed.recently_played_tracks
            .iter()
            .all(|r| r.track.id != fx.ids[8])
    );
    let rock = lib.genre_tracks_page("Rock", 0, 100).unwrap();
    assert_eq!(rock.items.iter().map(|t| t.plays).sum::<u32>(), 13);
    assert_eq!(lib.track_by_id(fx.ids[0]).unwrap().unwrap().plays, 4);
    let st = autoplay::profile_stats(&lib.conn(), ALICE).unwrap();
    assert_eq!(st[&fx.paths[0]].0, 4);
    assert!(st[&fx.paths[0]].1);
    assert_eq!(st[&fx.paths[8]], (0, false, None));
    assert_eq!(
        lib.autoplay_picks(&[fx.paths[0].clone()], &Default::default(), 3)
            .unwrap()
            .len(),
        3
    );

    // --- Bob
    lib.set_active_profile(BOB).unwrap();
    assert_eq!(fx.fav_ids(), fx.ids_of(&[8, 9]));
    assert_eq!(lib.favorites_page(0, 100).unwrap().total, 2);
    let lists = lib.playlists().unwrap();
    assert_eq!(lists.len(), 1);
    assert_eq!(lists[0].track_count, 4);
    let road_b = lists[0].id;
    assert_ne!(road_a, road_b);
    assert_eq!(lib.playlist_queue_tracks(road_b).unwrap().len(), 4);
    assert!(lib.playlists_with_track(fx.ids[0]).unwrap().is_empty());
    assert_eq!(lib.playlists_with_track(fx.ids[8]).unwrap(), vec![road_b]);
    let stats = lib.listening_stats(None, None).unwrap();
    assert_eq!(stats.summary.play_count, 11);
    assert_eq!(stats.summary.unique_tracks, 5);
    assert_eq!(stats.top_tracks_by_plays[0].play_count, 3);
    assert!(
        lib.listening_stats(Some(now() - 400 * 86_400), Some(now() - 300 * 86_400))
            .unwrap()
            .recent
            .is_empty()
    );
    let songs = lib.tracks_page(0, 100, SortOrder::Title).unwrap();
    let plays = |title: &str| songs.iter().find(|t| t.title == title).unwrap().plays;
    assert_eq!(
        (plays("Song 0"), plays("Song 8"), plays("Song 7")),
        (0, 3, 1)
    );
    let artists = lib.search_artists_page(0, 50, "").unwrap();
    let a = |n: &str| {
        artists
            .items
            .iter()
            .find(|r| r.name == n)
            .unwrap()
            .play_count
    };
    assert_eq!((a("Alpha"), a("Beta")), (5, 6));
    assert_eq!(lib.artist_profile("Beta").unwrap().play_count, 6);
    let repeat = lib.home_mix_detail("on-repeat").unwrap().unwrap();
    assert!(repeat.tracks.iter().all(|t| fx.ids[8..].contains(&t.id)));
    assert_eq!(lib.home_feed().unwrap().favorite_count, 2);
    assert_eq!(lib.track_by_id(fx.ids[0]).unwrap().unwrap().plays, 0);
    assert_eq!(
        lib.genre_tracks_page("Rock", 0, 100)
            .unwrap()
            .items
            .iter()
            .map(|t| t.plays)
            .sum::<u32>(),
        0
    );
    let st = autoplay::profile_stats(&lib.conn(), BOB).unwrap();
    assert_eq!(st[&fx.paths[0]], (0, false, None));
    assert_eq!(st[&fx.paths[8]].0, 3);
    assert!(st[&fx.paths[8]].1);

    // The two views really differ everywhere user data shows.
    lib.set_active_profile(ALICE).unwrap();
    let sa = snapshot(&fx);
    lib.set_active_profile(BOB).unwrap();
    let sb = snapshot(&fx);
    for label in [
        "favorites",
        "favorites_page",
        "playlists",
        "stats all",
        "home",
        "artists",
        "songs",
        "autoplay stats",
        "track 0",
    ] {
        let get = |s: &[(String, String)]| s.iter().find(|(l, _)| l == label).unwrap().1.clone();
        assert_ne!(get(&sa), get(&sb), "{label} must differ between profiles");
    }
}

#[test]
fn a_new_profile_starts_empty() {
    let fx = fixture();
    fx.populate();
    let carol = fx.lib.create_profile("Carol").unwrap();
    fx.lib.set_active_profile(carol.id).unwrap();
    assert!(fx.lib.favorites().unwrap().is_empty());
    assert!(fx.lib.playlists().unwrap().is_empty());
    let stats = fx.lib.listening_stats(None, None).unwrap();
    assert_eq!(stats.summary.raw_event_count, 0);
    assert!(stats.available_years.is_empty());
    let feed = fx.lib.home_feed().unwrap();
    assert!(!feed.has_history && feed.favorite_count == 0 && feed.mixes.is_empty());
    assert_eq!(
        fx.lib
            .tracks_page(0, 100, SortOrder::Title)
            .unwrap()
            .iter()
            .map(|t| t.plays)
            .sum::<u32>(),
        0
    );
    // The library itself (songs, albums, artists) is shared.
    assert_eq!(
        fx.lib.tracks_page(0, 100, SortOrder::Title).unwrap().len(),
        12
    );
    assert_eq!(fx.lib.search_artists_page(0, 50, "").unwrap().total, 2);
}

#[test]
fn writes_in_one_profile_never_change_the_other() {
    let fx = fixture();
    fx.populate();
    let lib = &fx.lib;
    lib.set_active_profile(ALICE).unwrap();
    let alice_before = snapshot(&fx);

    // Bob changes everything he can.
    lib.set_active_profile(BOB).unwrap();
    let road_a = {
        lib.set_active_profile(ALICE).unwrap();
        let id = fx.playlist_named("Road");
        lib.set_active_profile(BOB).unwrap();
        id
    };
    let road_b = fx.playlist_named("Road");
    assert!(lib.toggle_favorite(fx.ids[0]).unwrap()); // Bob stars Alice's favourite
    assert!(!lib.toggle_favorite(fx.ids[8]).unwrap());
    lib.set_favorites(&[fx.ids[1], fx.ids[2], fx.ids[3]], true)
        .unwrap();
    lib.set_favorites(&[fx.ids[1]], false).unwrap();
    assert!(lib.toggle_favorite_by_path(&fx.paths[5]).unwrap());
    let made = lib.create_playlist("Bob only", &fx.ids[0..2]).unwrap();
    lib.rename_playlist(road_b, "Renamed").unwrap();
    lib.playlist_add_tracks(road_b, &[fx.ids[0]]).unwrap();
    lib.playlist_add_album(road_b, 1).unwrap();
    lib.playlist_move(road_b, 0, 3).unwrap();
    lib.playlist_remove(road_b, &[0]).unwrap();
    lib.playlist_remove_track(road_b, fx.ids[9]).unwrap();
    lib.set_playlist_cover_preset(road_b, "preset:green")
        .unwrap();
    lib.delete_playlist(made.id).unwrap();
    let imported = lib
        .import_m3u(
            "From m3u",
            "#EXTM3U\n/m/1.flac\n/m/2.flac\n/nope.flac\n",
            None,
        )
        .unwrap();
    assert_eq!((imported.matched, imported.missing), (2, 1));
    let saved = lib
        .playlist_from_paths("Queue", &[fx.paths[3].clone(), fx.paths[4].clone()])
        .unwrap();
    assert_eq!(saved.skipped, 0);
    fx.listen(0, 5);
    fx.listen(6, 2);
    lib.save_mix_as_playlist("on-repeat", "Mix").unwrap();

    // Bob cannot reach Alice's playlist by id.
    assert!(lib.playlist_tracks(road_a, 0, 10).is_err());
    assert!(lib.playlist_queue_tracks(road_a).is_err());
    assert!(lib.export_m3u(road_a).is_err());
    assert!(lib.rename_playlist(road_a, "Hacked").is_err());
    assert!(lib.delete_playlist(road_a).is_err());
    assert!(lib.playlist_add_tracks(road_a, &[fx.ids[5]]).is_err());
    assert!(lib.playlist_add_album(road_a, 2).is_err());
    assert!(lib.playlist_remove(road_a, &[0]).is_err());
    assert!(lib.playlist_remove_track(road_a, fx.ids[0]).is_err());
    assert!(lib.playlist_move(road_a, 0, 1).is_err());
    assert!(lib.set_playlist_cover_preset(road_a, "preset:red").is_err());
    assert!(lib.clear_playlist_cover(road_a).is_err());

    let bob_after_writes = snapshot(&fx);
    assert_eq!(lib.clear_listen_history().unwrap(), 11 + 7);

    // Alice is exactly as she was.
    lib.set_active_profile(ALICE).unwrap();
    let alice_now = snapshot(&fx);
    assert_eq!(diff(&alice_before, &alice_now), Vec::<String>::new());

    // Now Alice changes things (and clears her history); Bob keeps his.
    lib.set_active_profile(BOB).unwrap();
    let bob_after_clear = snapshot(&fx);
    let changed = diff(&bob_after_writes, &bob_after_clear);
    assert!(
        changed.iter().any(|l| l.starts_with("stats")),
        "Bob's own clear shows"
    );
    lib.set_active_profile(ALICE).unwrap();
    lib.toggle_favorite(fx.ids[0]).unwrap();
    lib.create_playlist("Alice new", &fx.ids[5..7]).unwrap();
    let chill = fx.playlist_named("Chill");
    lib.delete_playlist(chill).unwrap();
    fx.listen(11, 4);
    assert_eq!(lib.clear_listen_history().unwrap(), 13 + 4);
    lib.set_active_profile(BOB).unwrap();
    assert_eq!(diff(&bob_after_clear, &snapshot(&fx)), Vec::<String>::new());
}

#[test]
fn listen_events_are_recorded_for_the_active_profile() {
    let fx = fixture();
    fx.lib.set_active_profile(BOB).unwrap();
    fx.listen(2, 1);
    fx.lib.set_active_profile(ALICE).unwrap();
    fx.listen(3, 2);
    let c = fx.lib.conn();
    let n = |p: i64| -> i64 {
        c.query_row(
            "SELECT COUNT(*) FROM listen_events WHERE profile_id = ?1",
            [p],
            |r| r.get(0),
        )
        .unwrap()
    };
    assert_eq!((n(1), n(2)), (2, 1));
}

#[test]
fn deleting_a_profile_removes_its_data_and_playlist_cover_files() {
    let fx = fixture();
    fx.populate();
    let lib = &fx.lib;
    // An image cover on one of Bob's playlists.
    lib.set_active_profile(BOB).unwrap();
    let road_b = fx.playlist_named("Road");
    let dir = lib.user_images_dir().join("playlists");
    std::fs::create_dir_all(&dir).unwrap();
    let cover: PathBuf = dir.join("bob.jpg");
    std::fs::write(&cover, b"jpg").unwrap();
    lib.conn()
        .execute(
            "UPDATE playlists SET cover = ?2 WHERE id = ?1",
            rusqlite::params![road_b, cover.to_string_lossy()],
        )
        .unwrap();
    let summary = lib.profile_summary(BOB).unwrap();
    assert_eq!(
        (summary.favorites, summary.playlists, summary.listens),
        (2, 1, 11)
    );
    assert_eq!(lib.profile_summary(ALICE).unwrap().listens, 13);

    lib.set_active_profile(ALICE).unwrap();
    let alice_before = snapshot(&fx);
    lib.delete_profile(BOB).unwrap();
    assert!(!cover.exists(), "cover file removed with the profile");
    assert_eq!(diff(&alice_before, &snapshot(&fx)), Vec::<String>::new());
    let c = lib.conn();
    for table in ["favorites", "playlists", "listen_events"] {
        let n: i64 = c
            .query_row(
                &format!("SELECT COUNT(*) FROM {table} WHERE profile_id = 2"),
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 0, "{table}");
    }
    let orphans: i64 = c
        .query_row(
            "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id NOT IN (SELECT id FROM playlists)",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(orphans, 0);
    // Alice's rows are untouched.
    let n: i64 = c
        .query_row("SELECT COUNT(*) FROM playlists", [], |r| r.get(0))
        .unwrap();
    assert_eq!(n, 2);
    drop(c);
    assert!(lib.profile_summary(BOB).is_err());
    let _ = &fx.tmp;
}

#[test]
fn a_profile_pin_is_needed_and_wrong_guesses_pause() {
    let tmp = tempfile::TempDir::new().unwrap();
    let lib = Library::open(
        &tmp.path().join("lib.sqlite3"),
        &tmp.path().join("c"),
        Hooks::none(),
    )
    .unwrap();
    let two = lib.create_profile("Zeynep").unwrap().id;
    // No PIN: anything (even nothing) opens it.
    lib.check_profile_pin(two, None).unwrap();
    assert!(lib.set_profile_pin(two, Some("12")).is_err(), "too short");
    lib.set_profile_pin(two, Some("4826")).unwrap();
    assert!(lib.profile_has_pin(two).unwrap());
    assert!(
        lib.profiles()
            .unwrap()
            .iter()
            .any(|p| p.id == two && p.has_pin)
    );
    assert!(lib.check_profile_pin(two, None).is_err());
    lib.check_profile_pin(two, Some("4826")).unwrap();
    // Five wrong guesses: even the right PIN is refused for a while.
    for _ in 0..5 {
        assert!(lib.check_profile_pin(two, Some("0000")).is_err());
    }
    let err = lib
        .check_profile_pin(two, Some("4826"))
        .unwrap_err()
        .to_string();
    assert!(err.contains("wait"), "{err}");
    // Another profile is not affected.
    lib.check_profile_pin(ProfileId::FIRST, None).unwrap();
    // Removing the PIN.
    lib.set_profile_pin(two, None).unwrap();
    assert!(!lib.profile_has_pin(two).unwrap());
}

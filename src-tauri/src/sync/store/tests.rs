//! Store tests. Every device is an in-memory database created through the
//! real `db::init`, edited through the app's own `db` functions, and synced
//! through the public store API exactly as the service will do it.

use super::hlc::{Clock, Hlc};
use super::key::Resolver;
use super::rows::{self, ENTRY_COLS};
use super::*;
use crate::library::{NewListenEvent, ProfileId, db};
use rusqlite::Connection;
use std::collections::{BTreeMap, BTreeSet};

// --- test devices -----------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Song {
    artist: &'static str,
    album: &'static str,
    title: &'static str,
    duration_ms: i64,
}

const fn song(artist: &'static str, album: &'static str, title: &'static str) -> Song {
    Song {
        artist,
        album,
        title,
        duration_ms: 200_000,
    }
}

const SONGS: [Song; 10] = [
    song("Nina Simone", "Pastel Blues", "Sinnerman"),
    song("Nina Simone", "Pastel Blues", "Be My Husband"),
    song("Miles Davis", "Kind of Blue", "So What"),
    song("Miles Davis", "Kind of Blue", "Blue in Green"),
    song("Björk", "Homogenic", "Jóga"),
    song("Björk", "Homogenic", "Bachelorette"),
    song("Radiohead", "OK Computer", "Airbag"),
    song("Radiohead", "OK Computer", "Lucky"),
    song("Daft Punk", "Discovery", "One More Time"),
    song("Daft Punk", "Discovery", "Digital Love"),
];

struct Device {
    conn: Connection,
    id: String,
    name: String,
    /// Unix milliseconds; tests move it forward explicitly.
    now: i64,
}

impl Device {
    fn new(name: &str) -> Self {
        let conn = Connection::open_in_memory().unwrap();
        db::init(&conn).unwrap();
        conn.execute("INSERT INTO folders(id, path) VALUES (1, '/m')", [])
            .unwrap();
        set_device_name(&conn, name).unwrap();
        let id = device_id(&conn).unwrap();
        Self {
            conn,
            id,
            name: name.to_owned(),
            now: 1_700_000_000_000,
        }
    }

    fn tick(&mut self, ms: i64) {
        self.now += ms;
    }

    fn secs(&self) -> i64 {
        self.now / 1000
    }

    fn path(s: &Song) -> String {
        format!("/m/{}/{}/{}.flac", s.artist, s.album, s.title)
    }

    fn add(&self, s: &Song) -> i64 {
        self.conn
            .execute(
                "INSERT OR IGNORE INTO albums(title, album_artist) VALUES (?1, ?2)",
                [s.album, s.artist],
            )
            .unwrap();
        let album: i64 = self
            .conn
            .query_row(
                "SELECT id FROM albums WHERE title = ?1 AND album_artist = ?2",
                [s.album, s.artist],
                |r| r.get(0),
            )
            .unwrap();
        self.conn
            .execute(
                "INSERT INTO tracks(folder_id, path, mtime, size, title, artist, album_id,
                                    duration_ms, added_at)
                 VALUES (1, ?1, 1, 1, ?2, ?3, ?4, ?5, 1)",
                rusqlite::params![Self::path(s), s.title, s.artist, album, s.duration_ms],
            )
            .unwrap();
        self.conn.last_insert_rowid()
    }

    fn add_all(&self, songs: &[Song]) -> Vec<i64> {
        songs.iter().map(|s| self.add(s)).collect()
    }

    /// Removes the file from the library the way a folder removal or a
    /// rescan does (rows cascade out of favourites and playlists).
    fn remove(&self, s: &Song) {
        self.conn
            .execute("DELETE FROM tracks WHERE path = ?1", [Self::path(s)])
            .unwrap();
    }

    fn track(&self, s: &Song) -> Option<i64> {
        db::track_id_by_path(&self.conn, &Self::path(s)).unwrap()
    }

    fn id_of(&self, s: &Song) -> i64 {
        self.track(s).unwrap()
    }

    fn toggle(&self, s: &Song) -> bool {
        db::toggle_favorite(&self.conn, ProfileId::FIRST, self.id_of(s), self.secs()).unwrap()
    }

    fn create(&mut self, name: &str, songs: &[Song]) -> i64 {
        let ids: Vec<i64> = songs.iter().map(|s| self.id_of(s)).collect();
        let now = self.secs();
        db::create_playlist(&mut self.conn, ProfileId::FIRST, name, &ids, now)
            .unwrap()
            .id
    }

    fn listen(&self, s: &Song, at: i64) {
        db::record_listen_event(
            &self.conn,
            ProfileId::FIRST,
            &NewListenEvent {
                path: Self::path(s),
                title: s.title.into(),
                artist: s.artist.into(),
                duration_ms: Some(200_000),
                started_at: at,
                ended_at: at + 200,
                listened_ms: 200_000,
                completed: true,
                skipped: false,
            },
        )
        .unwrap();
    }

    fn capture(&self) -> CaptureReport {
        capture(&self.conn, self.now, &[ProfileId::FIRST]).unwrap()
    }

    /// Favourite songs as track keys.
    fn favorite_keys(&self) -> BTreeSet<String> {
        let res = Resolver::load(&self.conn).unwrap();
        db::favorites(&self.conn, ProfileId::FIRST)
            .unwrap()
            .iter()
            .map(|f| res.track(f.track_id).unwrap().key.clone())
            .collect()
    }

    /// Local playlists: name -> song keys in order (names must be unique).
    fn playlists(&self) -> BTreeMap<String, Vec<String>> {
        let res = Resolver::load(&self.conn).unwrap();
        db::playlists(&self.conn, ProfileId::FIRST)
            .unwrap()
            .into_iter()
            .map(|p| {
                let keys = super::local::entries(&self.conn, p.id)
                    .unwrap()
                    .iter()
                    .map(|(t, _)| res.track(*t).unwrap().key.clone())
                    .collect();
                (p.name, keys)
            })
            .collect()
    }

    fn playlist_id(&self, name: &str) -> i64 {
        db::playlists(&self.conn, ProfileId::FIRST)
            .unwrap()
            .into_iter()
            .find(|p| p.name == name)
            .unwrap()
            .id
    }
}

fn key_of(s: &Song) -> String {
    track_key(s.artist, s.album, s.title)
}

fn keys(songs: &[Song]) -> Vec<String> {
    songs.iter().map(key_of).collect()
}

fn pair(a: &Device, b: &Device) {
    upsert_peer(&a.conn, &b.id, &b.name, b"secret-ab", ProfileId::FIRST).unwrap();
    upsert_peer(&b.conn, &a.id, &a.name, b"secret-ab", ProfileId::FIRST).unwrap();
}

/// Options for a batch from no particular peer, into the first profile.
fn default_opts() -> ApplyOptions {
    ApplyOptions {
        profile: ProfileId::FIRST,
        peer_id: None,
        peer_name: String::new(),
        allow_mass_delete: false,
        backup_dir: None,
        now_ms: 0,
    }
}

fn opts(to: &Device, from: &Device) -> ApplyOptions {
    ApplyOptions {
        profile: peer(&to.conn, &from.id).unwrap().unwrap().profile,
        peer_id: Some(from.id.clone()),
        peer_name: from.name.clone(),
        allow_mass_delete: false,
        backup_dir: None,
        now_ms: to.now,
    }
}

/// `to` pulls every change of `from`, page by page, acknowledging each.
fn pull_with(to: &Device, from: &Device, limit: usize, allow: bool) -> Result<()> {
    capture(&from.conn, from.now, &bound_profiles(&from.conn)?)?;
    let sent_profile = peer(&from.conn, &to.id)?.unwrap().profile;
    loop {
        let after = peer(&to.conn, &from.id)?.unwrap().last_seq_received;
        let batch = changes_since(&from.conn, sent_profile, after, limit)?;
        // Over the wire as JSON, like the link layer will send it.
        let bytes = serde_json::to_vec(&batch).unwrap();
        let batch = Batch::from_json(&bytes)?;
        let mut o = opts(to, from);
        o.allow_mass_delete = allow;
        apply(&to.conn, &batch, &o)?;
        ack_sent(&from.conn, &to.id, batch.upto_seq)?;
        if !batch.more {
            return Ok(());
        }
    }
}

fn pull(to: &Device, from: &Device) {
    pull_with(to, from, 1000, false).unwrap();
}

fn sync(a: &Device, b: &Device) {
    pull(a, b);
    pull(b, a);
}

// --- replicated state -------------------------------------------------------

#[derive(Debug, PartialEq, Eq)]
struct Replicated {
    favorites: Vec<FavoriteRecord>,
    playlists: Vec<PlaylistRecord>,
    entries: Vec<EntryRecord>,
    listens: Vec<ListenRecord>,
}

fn replicated(conn: &Connection) -> Replicated {
    let entries = {
        let mut st = conn
            .prepare(&format!(
                "SELECT {ENTRY_COLS} FROM sync_playlist_entries ORDER BY uuid"
            ))
            .unwrap();
        st.query_map([], rows::entry)
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap()
    };
    let listens = {
        let mut st = conn
            .prepare(&format!(
                "SELECT {} FROM sync_listens ORDER BY uid",
                rows::LISTEN_COLS
            ))
            .unwrap();
        st.query_map([], rows::listen)
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap()
    };
    Replicated {
        favorites: rows::all_favorites(conn, ProfileId::FIRST).unwrap(),
        playlists: rows::all_playlists(conn, ProfileId::FIRST)
            .unwrap()
            .into_iter()
            .map(|r| r.rec)
            .collect(),
        entries,
        listens,
    }
}

/// Every row of every table, for "nothing changed" checks.
fn dump(conn: &Connection) -> Vec<String> {
    let tables: Vec<String> = {
        let mut st = conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            .unwrap();
        st.query_map([], |r| r.get(0))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap()
    };
    let mut out = Vec::new();
    for t in tables {
        let mut st = conn.prepare(&format!("SELECT * FROM \"{t}\"")).unwrap();
        let n = st.column_count();
        let rows = st
            .query_map([], |r| {
                let vals: Vec<String> = (0..n)
                    .map(|i| format!("{:?}", r.get_ref(i).unwrap()))
                    .collect();
                Ok(vals.join("|"))
            })
            .unwrap();
        let mut lines: Vec<String> = rows.map(|r| format!("{t}: {}", r.unwrap())).collect();
        lines.sort();
        out.extend(lines);
    }
    out
}

/// Local tables equal the view of the sync tables (materialised state).
fn assert_materialized(d: &Device) {
    let res = Resolver::load(&d.conn).unwrap();
    let want_favs: BTreeSet<String> = rows::all_favorites(&d.conn, ProfileId::FIRST)
        .unwrap()
        .into_iter()
        .filter(|f| f.on)
        .filter_map(|f| res.resolve(&f.key, f.duration_ms))
        .map(|id| res.track(id).unwrap().key.clone())
        .collect();
    assert_eq!(d.favorite_keys(), want_favs, "{} favourites", d.name);

    let map = rows::playlist_map(&d.conn, ProfileId::FIRST).unwrap();
    let mut want: BTreeMap<String, (String, Vec<String>)> = BTreeMap::new();
    for row in rows::all_playlists(&d.conn, ProfileId::FIRST).unwrap() {
        assert!(row.reconciled, "{} has unreconciled playlists", d.name);
        if row.rec.deleted {
            continue;
        }
        let songs = rows::live_entries(&d.conn, &row.rec.uuid)
            .unwrap()
            .iter()
            .filter_map(|e| res.resolve(&e.key, e.duration_ms))
            .map(|id| res.track(id).unwrap().key.clone())
            .collect();
        want.insert(row.rec.uuid.clone(), (row.rec.name.clone(), songs));
    }
    let mut have: BTreeMap<String, (String, Vec<String>)> = BTreeMap::new();
    for p in db::playlists(&d.conn, ProfileId::FIRST).unwrap() {
        let uuid = map.get(&p.id).expect("every playlist is mapped").clone();
        let songs = super::local::entries(&d.conn, p.id)
            .unwrap()
            .iter()
            .map(|(t, _)| res.track(*t).unwrap().key.clone())
            .collect();
        have.insert(uuid, (p.name, songs));
    }
    assert_eq!(have, want, "{} playlists", d.name);
}

// --- clock and keys -----------------------------------------------------------

#[test]
fn hlc_string_order_is_clock_order() {
    let dev = "0".repeat(32);
    let a = Hlc {
        wall_ms: 9,
        counter: 5,
        device: dev.clone(),
    };
    let b = Hlc {
        wall_ms: 10,
        counter: 0,
        device: dev.clone(),
    };
    assert!(a < b && a.encode() < b.encode());
    assert_eq!(Hlc::parse(&a.encode()), Some(a));
    assert!(Hlc::parse("123").is_none());
    assert!(Hlc::parse(&format!("0000000000010-000000-{}", "G".repeat(32))).is_none());
}

#[test]
fn clock_ticks_monotonically_and_clamps_skew() {
    let mut c = Clock {
        wall_ms: 0,
        counter: 0,
        device: "a".repeat(32),
    };
    let s1 = c.tick(1000);
    let s2 = c.tick(1000);
    let s3 = c.tick(900);
    assert!(s1 < s2 && s2 < s3);
    // A peer two days ahead: our clock moves only 24 h ahead.
    let future = Hlc {
        wall_ms: 1000 + 2 * 86_400_000,
        counter: 7,
        device: "b".repeat(32),
    };
    c.observe(&future, 1000);
    assert_eq!(c.wall_ms, 1000 + 86_400_000);
    assert!(c.tick(1000) > s3);
    // A received stamp within range is passed.
    let near = Hlc {
        wall_ms: 1000 + 86_400_000,
        counter: 50,
        device: "b".repeat(32),
    };
    c.observe(&near, 1000);
    assert!(c.tick(1000) > near);
}

#[test]
fn track_keys_are_normalised() {
    assert_eq!(
        track_key("  Björk ", "HOMOGENIC", "Jóga\t (Live)"),
        track_key("björk", "homogenic", "jóga (live)")
    );
    assert_eq!(norm("A\u{1f}B"), "a b");
    let long = "x".repeat(5000);
    assert!(track_key(&long, &long, &long).len() <= MAX_STR_BYTES);
}

#[test]
fn resolution_falls_back_to_artist_title_and_duration() {
    let d = Device::new("A");
    let original = song("Nina Simone", "Pastel Blues", "Sinnerman");
    let wanted = key_of(&original);
    // Same song on another album (a compilation), 1.5 s longer.
    let mut compilation = song("NINA  simone", "Best Of", "Sinnerman");
    compilation.duration_ms = 201_500;
    let mut live = song("Nina Simone", "Live", "Sinnerman");
    live.duration_ms = 600_000;
    let live_id = d.add(&live);
    let res = Resolver::load(&d.conn).unwrap();
    assert_eq!(res.resolve(&wanted, Some(200_000)), None, "10 min apart");
    assert_eq!(
        res.resolve(&wanted, None),
        Some(live_id),
        "unknown duration"
    );
    let comp_id = d.add(&compilation);
    let res = Resolver::load(&d.conn).unwrap();
    assert_eq!(res.resolve(&wanted, Some(200_000)), Some(comp_id));
    // Exact keys always win.
    let exact = d.add(&original);
    let res = Resolver::load(&d.conn).unwrap();
    assert_eq!(res.resolve(&wanted, Some(200_000)), Some(exact));
}

#[test]
fn duplicates_resolve_to_the_smallest_id() {
    let d = Device::new("A");
    let s = SONGS[0];
    let first = d.add(&s);
    d.conn
        .execute(
            "INSERT INTO tracks(folder_id, path, mtime, size, title, artist, album_id, added_at)
             SELECT folder_id, path || '.copy', 1, 1, title, artist, album_id, 1
             FROM tracks WHERE id = ?1",
            [first],
        )
        .unwrap();
    let second = d.conn.last_insert_rowid();
    let res = Resolver::load(&d.conn).unwrap();
    assert_eq!(res.resolve(&key_of(&s), None), Some(first));
    assert_eq!(res.canon(second), Some(first));
    // Two fallback candidates: the smaller id wins too.
    let other = key_of(&song("Nina Simone", "Unknown", "Sinnerman"));
    assert_eq!(res.resolve(&other, None), Some(first));
}

// --- capture ------------------------------------------------------------------

#[test]
fn capture_twice_is_a_noop() {
    let mut a = Device::new("A");
    a.add_all(&SONGS);
    a.toggle(&SONGS[0]);
    a.create("Mix", &SONGS[1..4]);
    a.listen(&SONGS[2], 100);
    let first = a.capture();
    assert!(first.stamped > 0);
    let seq = max_seq(&a.conn).unwrap();
    let before = dump(&a.conn);
    a.tick(1000);
    let second = a.capture();
    assert_eq!(second, CaptureReport::default());
    assert_eq!(max_seq(&a.conn).unwrap(), seq);
    assert_eq!(dump(&a.conn), before);
}

#[test]
fn capture_after_materialise_is_a_noop() {
    let mut a = Device::new("A");
    let mut b = Device::new("B");
    pair(&a, &b);
    a.add_all(&SONGS);
    b.add_all(&SONGS);
    a.toggle(&SONGS[0]);
    a.toggle(&SONGS[5]);
    a.create("Mix", &[SONGS[1], SONGS[2], SONGS[1]]);
    a.listen(&SONGS[2], 100);
    b.create("Other", &SONGS[6..9]);
    a.tick(10);
    b.tick(10);
    sync(&a, &b);
    for d in [&a, &b] {
        let seq = max_seq(&d.conn).unwrap();
        assert_eq!(d.capture(), CaptureReport::default(), "{}", d.name);
        assert_eq!(max_seq(&d.conn).unwrap(), seq);
        assert_materialized(d);
    }
    assert_eq!(
        b.favorite_keys(),
        keys(&[SONGS[0], SONGS[5]]).into_iter().collect()
    );
    assert_eq!(b.playlists()["Mix"], keys(&[SONGS[1], SONGS[2], SONGS[1]]));
    assert_eq!(a.playlists()["Other"], keys(&SONGS[6..9]));
    let listened: i64 = b
        .conn
        .query_row(
            "SELECT COUNT(*) FROM listen_events WHERE source = 'sync'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(listened, 1);
}

#[test]
fn listen_events_get_uids_and_history_is_a_union() {
    let mut a = Device::new("A");
    let mut b = Device::new("B");
    pair(&a, &b);
    a.add_all(&SONGS);
    b.add_all(&SONGS[..5]);
    a.listen(&SONGS[0], 10);
    a.listen(&SONGS[7], 20);
    b.listen(&SONGS[1], 30);
    a.tick(5);
    b.tick(5);
    sync(&a, &b);
    let null_uids: i64 = a
        .conn
        .query_row(
            "SELECT COUNT(*) FROM listen_events WHERE uid IS NULL",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(null_uids, 0);
    for d in [&a, &b] {
        let n: i64 = d
            .conn
            .query_row("SELECT COUNT(*) FROM listen_events", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 3, "{}", d.name);
    }
    // On B the song B lacks keeps the sender's path and no track id.
    let (track, path): (Option<i64>, String) = b
        .conn
        .query_row(
            "SELECT track_id, path FROM listen_events WHERE title = ?1",
            [SONGS[7].title],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(track, None);
    assert_eq!(path, Device::path(&SONGS[7]));
    // Clearing local history is not undone by the next sync.
    db::clear_listen_history(&b.conn, ProfileId::FIRST).unwrap();
    b.tick(5);
    sync(&a, &b);
    let n: i64 = b
        .conn
        .query_row("SELECT COUNT(*) FROM listen_events", [], |r| r.get(0))
        .unwrap();
    assert_eq!(n, 0);
}

// --- missing songs ----------------------------------------------------------------

#[test]
fn missing_track_is_not_an_unfavourite() {
    let mut a = Device::new("A");
    let mut b = Device::new("B");
    pair(&a, &b);
    a.add_all(&SONGS);
    b.add_all(&SONGS);
    a.toggle(&SONGS[0]);
    a.toggle(&SONGS[1]);
    let pl = a.create("Mix", &SONGS[0..3]);
    sync(&a, &b);

    // The folder holding SONGS[0] disappears on A: the rows cascade away.
    a.tick(1000);
    a.remove(&SONGS[0]);
    a.capture();
    let rec = rows::get_favorite(&a.conn, ProfileId::FIRST, &key_of(&SONGS[0]))
        .unwrap()
        .unwrap();
    assert!(rec.on, "a missing song is not an unfavourite");
    assert_eq!(
        rows::live_entries(
            &a.conn,
            &rows::playlist_map(&a.conn, ProfileId::FIRST).unwrap()[&pl]
        )
        .unwrap()
        .len(),
        3
    );
    b.tick(1000);
    sync(&a, &b);
    assert!(b.favorite_keys().contains(&key_of(&SONGS[0])));
    assert_eq!(b.playlists()["Mix"], keys(&SONGS[0..3]));

    // The song comes back (new track id): favourite and playlist place too.
    a.tick(1000);
    let new_id = a.add(&SONGS[0]);
    let report = a.capture();
    assert!(report.local_changed);
    assert!(
        db::favorites(&a.conn, ProfileId::FIRST)
            .unwrap()
            .iter()
            .any(|f| f.track_id == new_id)
    );
    assert_eq!(a.playlists()["Mix"], keys(&SONGS[0..3]));
    assert_eq!(a.capture(), CaptureReport::default());
    a.tick(1000);
    sync(&a, &b);
    assert!(b.favorite_keys().contains(&key_of(&SONGS[0])));
    assert_materialized(&a);
    assert_materialized(&b);
}

#[test]
fn song_reappearing_during_apply_is_restored_too() {
    // Same as above, but the next thing after the re-scan is a sync (the
    // capture inside `apply` must restore, not unfavourite).
    let mut a = Device::new("A");
    let mut b = Device::new("B");
    pair(&a, &b);
    a.add_all(&SONGS);
    b.add_all(&SONGS);
    a.toggle(&SONGS[3]);
    a.capture();
    a.remove(&SONGS[3]);
    a.capture();
    a.add(&SONGS[3]);
    a.tick(10);
    b.tick(10);
    pull(&a, &b);
    assert!(a.favorite_keys().contains(&key_of(&SONGS[3])));
    pull(&b, &a);
    assert!(b.favorite_keys().contains(&key_of(&SONGS[3])));
}

#[test]
fn unresolved_keys_survive_and_resolve_later() {
    let mut a = Device::new("A");
    let mut b = Device::new("B");
    pair(&a, &b);
    a.add_all(&SONGS);
    b.add_all(&SONGS[..5]);
    a.toggle(&SONGS[8]);
    a.create("Mix", &[SONGS[0], SONGS[8], SONGS[1]]);
    sync(&a, &b);
    // B does not have SONGS[8]: not shown, but kept.
    assert!(b.favorite_keys().is_empty());
    assert_eq!(b.playlists()["Mix"], keys(&[SONGS[0], SONGS[1]]));
    // B edits the playlist meanwhile: the unknown song is left alone.
    b.tick(1000);
    let id = b.playlist_id("Mix");
    let s2 = b.id_of(&SONGS[2]);
    db::playlist_add_tracks(&mut b.conn, ProfileId::FIRST, id, &[s2]).unwrap();
    db::playlist_move(&mut b.conn, ProfileId::FIRST, id, 2, 0).unwrap();
    b.tick(1000);
    sync(&a, &b);
    assert_eq!(
        a.playlists()["Mix"],
        keys(&[SONGS[2], SONGS[0], SONGS[8], SONGS[1]])
    );
    assert!(a.favorite_keys().contains(&key_of(&SONGS[8])));
    // B gets the song later: it shows up in place.
    b.tick(1000);
    b.add(&SONGS[8]);
    b.capture();
    assert!(b.favorite_keys().contains(&key_of(&SONGS[8])));
    assert_eq!(
        b.playlists()["Mix"],
        keys(&[SONGS[2], SONGS[0], SONGS[8], SONGS[1]])
    );
    b.tick(1000);
    sync(&a, &b);
    assert_eq!(replicated(&a.conn), replicated(&b.conn));
    assert_materialized(&a);
    assert_materialized(&b);
}

#[test]
fn fallback_resolution_works_across_devices() {
    let mut a = Device::new("A");
    let mut b = Device::new("B");
    pair(&a, &b);
    let original = SONGS[0];
    let mut on_b = song("Nina Simone", "The Very Best Of", "Sinnerman");
    on_b.duration_ms = 202_000;
    a.add(&original);
    b.add(&on_b);
    a.toggle(&original);
    a.create("Mix", &[original]);
    sync(&a, &b);
    assert_eq!(b.favorite_keys(), [key_of(&on_b)].into_iter().collect());
    assert_eq!(b.playlists()["Mix"], vec![key_of(&on_b)]);
    // B's capture does not mint a second record for its own key.
    assert_eq!(b.capture(), CaptureReport::default());
    // Unfavouriting on B turns off A's record.
    b.tick(1000);
    b.toggle(&on_b);
    sync(&a, &b);
    assert!(a.favorite_keys().is_empty());
}

// --- playlists ------------------------------------------------------------------

#[test]
fn playlist_operations_replicate() {
    let mut a = Device::new("A");
    let b = Device::new("B");
    pair(&a, &b);
    a.add_all(&SONGS);
    b.add_all(&SONGS);
    let id = a.create("Mix", &SONGS[0..3]);
    sync(&a, &b);
    assert_eq!(b.playlists()["Mix"], keys(&SONGS[0..3]));

    a.tick(1000);
    db::rename_playlist(&a.conn, ProfileId::FIRST, id, "Evening").unwrap();
    db::set_playlist_cover(&a.conn, ProfileId::FIRST, id, Some("preset:sunset")).unwrap();
    sync(&a, &b);
    let info = &db::playlists(&b.conn, ProfileId::FIRST).unwrap()[0];
    assert_eq!(info.name, "Evening");
    assert_eq!(info.cover.as_deref(), Some("preset:sunset"));

    a.tick(1000);
    let extra = a.id_of(&SONGS[5]);
    db::playlist_add_tracks(&mut a.conn, ProfileId::FIRST, id, &[extra]).unwrap();
    db::playlist_move(&mut a.conn, ProfileId::FIRST, id, 3, 0).unwrap();
    db::playlist_remove(&mut a.conn, ProfileId::FIRST, id, &[2]).unwrap();
    sync(&a, &b);
    assert_eq!(
        b.playlists()["Evening"],
        keys(&[SONGS[5], SONGS[0], SONGS[2]])
    );

    a.tick(1000);
    db::delete_playlist(&a.conn, ProfileId::FIRST, id).unwrap();
    sync(&a, &b);
    assert!(b.playlists().is_empty());
    assert_materialized(&a);
    assert_materialized(&b);
}

#[test]
fn image_covers_stay_local() {
    let mut a = Device::new("A");
    let mut b = Device::new("B");
    pair(&a, &b);
    a.add_all(&SONGS);
    b.add_all(&SONGS);
    let id = a.create("Mix", &SONGS[0..2]);
    sync(&a, &b);
    a.tick(1000);
    db::set_playlist_cover(&a.conn, ProfileId::FIRST, id, Some("/user/covers/mine.jpg")).unwrap();
    assert_eq!(a.capture(), CaptureReport::default());
    b.tick(1000);
    let bid = b.playlist_id("Mix");
    db::set_playlist_cover(&b.conn, ProfileId::FIRST, bid, Some("preset:ocean")).unwrap();
    sync(&a, &b);
    let cover: Option<String> = a
        .conn
        .query_row("SELECT cover FROM playlists WHERE id = ?1", [id], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(cover.as_deref(), Some("/user/covers/mine.jpg"));
    // Deleting it elsewhere reports the orphaned image instead of deleting it.
    b.tick(1000);
    db::delete_playlist(&b.conn, ProfileId::FIRST, bid).unwrap();
    capture(&b.conn, b.now, &[ProfileId::FIRST]).unwrap();
    let batch = changes_since(&b.conn, ProfileId::FIRST, 0, 1000).unwrap();
    let report = apply(&a.conn, &batch, &opts(&a, &b)).unwrap();
    assert_eq!(
        report.orphan_covers,
        vec!["/user/covers/mine.jpg".to_owned()]
    );
    assert!(report.local_changed);
}

#[test]
fn concurrent_playlist_edits_merge() {
    let mut a = Device::new("A");
    let mut b = Device::new("B");
    pair(&a, &b);
    a.add_all(&SONGS);
    b.add_all(&SONGS);
    let ida = a.create("Mix", &SONGS[0..4]);
    sync(&a, &b);
    let idb = b.playlist_id("Mix");

    // Both add a song; A moves the first song to the end, B removes one.
    a.tick(1000);
    b.tick(1000);
    let s5 = a.id_of(&SONGS[5]);
    db::playlist_add_tracks(&mut a.conn, ProfileId::FIRST, ida, &[s5]).unwrap();
    db::playlist_move(&mut a.conn, ProfileId::FIRST, ida, 0, 4).unwrap();
    let s6 = b.id_of(&SONGS[6]);
    db::playlist_add_tracks(&mut b.conn, ProfileId::FIRST, idb, &[s6]).unwrap();
    db::playlist_remove(&mut b.conn, ProfileId::FIRST, idb, &[2]).unwrap();
    sync(&a, &b);
    sync(&a, &b);
    let pa = a.playlists()["Mix"].clone();
    assert_eq!(pa, b.playlists()["Mix"]);
    let set: BTreeSet<String> = pa.iter().cloned().collect();
    let want: BTreeSet<String> = keys(&[SONGS[0], SONGS[1], SONGS[3], SONGS[5], SONGS[6]])
        .into_iter()
        .collect();
    assert_eq!(set, want, "both additions kept, the removal applied");
    assert_eq!(pa.last(), Some(&key_of(&SONGS[0])), "A's move applied");
    assert_eq!(pa[0], key_of(&SONGS[1]), "A's move applied");

    // Delete (earlier) vs rename (later): the playlist survives.
    a.tick(1000);
    db::delete_playlist(&a.conn, ProfileId::FIRST, ida).unwrap();
    a.capture();
    b.tick(5000);
    db::rename_playlist(&b.conn, ProfileId::FIRST, idb, "Renamed").unwrap();
    b.capture();
    sync(&a, &b);
    assert!(a.playlists().contains_key("Renamed"));
    assert!(b.playlists().contains_key("Renamed"));

    // Rename (earlier) vs delete (later): the playlist is gone.
    let ida = a.playlist_id("Renamed");
    let idb = b.playlist_id("Renamed");
    a.tick(10_000);
    db::rename_playlist(&a.conn, ProfileId::FIRST, ida, "Again").unwrap();
    a.capture();
    b.tick(20_000);
    db::delete_playlist(&b.conn, ProfileId::FIRST, idb).unwrap();
    b.capture();
    sync(&a, &b);
    assert!(a.playlists().is_empty());
    assert!(b.playlists().is_empty());
    assert_eq!(replicated(&a.conn), replicated(&b.conn));
}

#[test]
fn concurrent_reorders_converge() {
    let mut a = Device::new("A");
    let mut b = Device::new("B");
    pair(&a, &b);
    a.add_all(&SONGS);
    b.add_all(&SONGS);
    let ida = a.create("Mix", &SONGS[0..6]);
    sync(&a, &b);
    let idb = b.playlist_id("Mix");
    a.tick(1000);
    b.tick(2000);
    db::playlist_move(&mut a.conn, ProfileId::FIRST, ida, 5, 0).unwrap();
    db::playlist_move(&mut b.conn, ProfileId::FIRST, idb, 0, 5).unwrap();
    db::playlist_move(&mut b.conn, ProfileId::FIRST, idb, 2, 1).unwrap();
    sync(&a, &b);
    sync(&a, &b);
    assert_eq!(a.playlists(), b.playlists());
    assert_eq!(a.playlists()["Mix"].len(), 6);
    assert_materialized(&a);
    assert_materialized(&b);
}

#[test]
fn added_at_is_preserved_across_devices() {
    let mut a = Device::new("A");
    let mut b = Device::new("B");
    pair(&a, &b);
    a.add_all(&SONGS);
    b.add_all(&SONGS);
    let id = a.create("Mix", &SONGS[0..3]);
    a.conn
        .execute(
            "UPDATE playlist_tracks SET added_at = 1000 + position WHERE playlist_id = ?1",
            [id],
        )
        .unwrap();
    sync(&a, &b);
    let bid = b.playlist_id("Mix");
    let added: Vec<Option<i64>> = super::local::entries(&b.conn, bid)
        .unwrap()
        .into_iter()
        .map(|(_, a)| a)
        .collect();
    assert_eq!(added, vec![Some(1000), Some(1001), Some(1002)]);
    // Still true after B reorders.
    b.tick(1000);
    db::playlist_move(&mut b.conn, ProfileId::FIRST, bid, 0, 2).unwrap();
    sync(&a, &b);
    let added: Vec<Option<i64>> = super::local::entries(&a.conn, id)
        .unwrap()
        .into_iter()
        .map(|(_, a)| a)
        .collect();
    assert_eq!(added, vec![Some(1001), Some(1002), Some(1000)]);
}

// --- first sync -------------------------------------------------------------------

#[test]
fn first_sync_unifies_identical_playlists() {
    let mut a = Device::new("A");
    let mut b = Device::new("B");
    pair(&a, &b);
    a.add_all(&SONGS);
    b.add_all(&SONGS);
    a.create("Road Trip", &SONGS[0..3]);
    b.create("road trip", &SONGS[0..3]);
    a.toggle(&SONGS[0]);
    b.toggle(&SONGS[1]);
    a.listen(&SONGS[0], 1);
    b.listen(&SONGS[1], 2);
    sync(&a, &b);
    sync(&a, &b);
    for d in [&a, &b] {
        let lists = d.playlists();
        assert_eq!(lists.len(), 1, "{}: {lists:?}", d.name);
        assert_eq!(lists.values().next().unwrap(), &keys(&SONGS[0..3]));
        assert_eq!(d.favorite_keys().len(), 2, "favourites are a union");
        assert_materialized(d);
    }
    assert_eq!(replicated(&a.conn), replicated(&b.conn));
    assert_eq!(replicated(&a.conn).listens.len(), 2);
}

#[test]
fn first_sync_keeps_both_when_songs_differ() {
    let mut a = Device::new("A");
    let mut b = Device::new("Phone");
    pair(&a, &b);
    a.add_all(&SONGS);
    b.add_all(&SONGS);
    a.create("Road Trip", &SONGS[0..3]);
    b.create("Road Trip", &SONGS[3..5]);
    // The phone starts the sync: it pulls first.
    pull(&b, &a);
    pull(&a, &b);
    sync(&a, &b);
    for d in [&a, &b] {
        let lists = d.playlists();
        assert_eq!(lists.len(), 2, "{}: {lists:?}", d.name);
        assert_eq!(lists["Road Trip"], keys(&SONGS[3..5]));
        assert_eq!(lists["Road Trip (A)"], keys(&SONGS[0..3]));
        assert_materialized(d);
    }
    assert_eq!(replicated(&a.conn), replicated(&b.conn));
}

#[test]
fn first_sync_never_unifies_with_unknown_songs() {
    let mut a = Device::new("A");
    let mut b = Device::new("B");
    pair(&a, &b);
    a.add_all(&SONGS);
    b.add_all(&SONGS[..3]);
    a.create("Mix", &[SONGS[0], SONGS[9]]);
    b.create("Mix", &[SONGS[0]]);
    // B pulls first: on B both lists resolve to [SONGS[0]], but A's has a
    // song B cannot see, so they must not be merged into one.
    pull(&b, &a);
    sync(&a, &b);
    assert_eq!(a.playlists().len(), 2);
    assert_eq!(b.playlists().len(), 2);
}

#[test]
fn reconciliation_waits_for_the_last_page() {
    let mut a = Device::new("A");
    let mut b = Device::new("B");
    pair(&a, &b);
    a.add_all(&SONGS);
    b.add_all(&SONGS);
    a.create("Mix", &SONGS);
    b.create("Mix", &SONGS);
    a.tick(1);
    b.tick(1);
    // Tiny pages split the playlist from its entries.
    pull_with(&b, &a, 3, false).unwrap();
    pull_with(&a, &b, 3, false).unwrap();
    pull_with(&b, &a, 3, false).unwrap();
    assert_eq!(a.playlists().len(), 1);
    assert_eq!(b.playlists().len(), 1);
    assert_eq!(replicated(&a.conn), replicated(&b.conn));
}

// --- merge properties ---------------------------------------------------------------

#[test]
fn apply_is_idempotent_and_order_independent() {
    let mut a = Device::new("A");
    let mut c = Device::new("C");
    a.add_all(&SONGS);
    c.add_all(&SONGS);
    a.toggle(&SONGS[0]);
    a.create("From A", &SONGS[0..3]);
    a.listen(&SONGS[1], 5);
    c.tick(500);
    c.toggle(&SONGS[1]);
    c.create("From C", &SONGS[4..7]);
    a.capture();
    c.capture();
    let from_a = changes_since(&a.conn, ProfileId::FIRST, 0, 1000).unwrap();
    let from_c = changes_since(&c.conn, ProfileId::FIRST, 0, 1000).unwrap();

    let b1 = Device::new("B1");
    let b2 = Device::new("B2");
    for d in [&b1, &b2] {
        d.add_all(&SONGS);
    }
    let o = |d: &Device| ApplyOptions {
        now_ms: d.now,
        ..default_opts()
    };
    apply(&b1.conn, &from_a, &o(&b1)).unwrap();
    apply(&b1.conn, &from_c, &o(&b1)).unwrap();
    let once = replicated(&b1.conn);
    let local_once = dump_local(&b1.conn);
    apply(&b1.conn, &from_a, &o(&b1)).unwrap();
    apply(&b1.conn, &from_c, &o(&b1)).unwrap();
    assert_eq!(replicated(&b1.conn), once, "idempotent");
    assert_eq!(dump_local(&b1.conn), local_once);

    apply(&b2.conn, &from_c, &o(&b2)).unwrap();
    apply(&b2.conn, &from_a, &o(&b2)).unwrap();
    assert_eq!(replicated(&b2.conn), once, "order independent");
    assert_eq!(b1.playlists(), b2.playlists());
    assert_eq!(b1.favorite_keys(), b2.favorite_keys());
}

/// The app's own tables, ignoring row ids that differ between devices.
fn dump_local(conn: &Connection) -> Vec<String> {
    dump(conn)
        .into_iter()
        .filter(|l| {
            [
                "favorites:",
                "playlists:",
                "playlist_tracks:",
                "listen_events:",
            ]
            .iter()
            .any(|p| l.starts_with(p))
        })
        .collect()
}

// --- randomised convergence -----------------------------------------------------------

/// splitmix64, like `library/autoplay.rs`.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }
}

fn present(d: &Device) -> Vec<Song> {
    SONGS
        .iter()
        .copied()
        .filter(|s| d.track(s).is_some())
        .collect()
}

fn random_op(d: &mut Device, rng: &mut Rng) {
    d.tick(1 + rng.below(3000) as i64);
    let here = present(d);
    let lists = db::playlists(&d.conn, ProfileId::FIRST).unwrap();
    let pick_list = |rng: &mut Rng| lists.get(rng.below(lists.len())).map(|p| p.id);
    match rng.below(12) {
        0 | 1 if !here.is_empty() => {
            d.toggle(&here[rng.below(here.len())]);
        }
        2 => {
            let names = ["Mix", "Chill", "Road Trip"];
            let n = rng.below(4);
            let songs: Vec<Song> = (0..n)
                .filter_map(|_| here.get(rng.below(here.len())).copied())
                .collect();
            d.create(names[rng.below(names.len())], &songs);
        }
        3 => {
            if let Some(id) = pick_list(rng) {
                let names = ["Mix", "Party", "Focus"];
                db::rename_playlist(&d.conn, ProfileId::FIRST, id, names[rng.below(3)]).unwrap();
            }
        }
        4 if rng.below(3) == 0 => {
            if let Some(id) = pick_list(rng) {
                db::delete_playlist(&d.conn, ProfileId::FIRST, id).unwrap();
            }
        }
        5 | 6 => {
            if let (Some(id), false) = (pick_list(rng), here.is_empty()) {
                let t = d.id_of(&here[rng.below(here.len())]);
                db::playlist_add_tracks(&mut d.conn, ProfileId::FIRST, id, &[t]).unwrap();
            }
        }
        7 => {
            if let Some(p) = lists.get(rng.below(lists.len()))
                && p.track_count > 0
            {
                let i = rng.below(p.track_count as usize);
                db::playlist_remove(&mut d.conn, ProfileId::FIRST, p.id, &[i]).unwrap();
            }
        }
        8 => {
            if let Some(p) = lists.get(rng.below(lists.len()))
                && p.track_count > 1
            {
                let n = p.track_count as usize;
                db::playlist_move(
                    &mut d.conn,
                    ProfileId::FIRST,
                    p.id,
                    rng.below(n),
                    rng.below(n),
                )
                .unwrap();
            }
        }
        9 => {
            if let Some(id) = pick_list(rng) {
                let covers = [Some("preset:a"), Some("preset:b"), None];
                db::set_playlist_cover(&d.conn, ProfileId::FIRST, id, covers[rng.below(3)])
                    .unwrap();
            }
        }
        10 if !here.is_empty() => {
            let at = d.secs();
            d.listen(&here[rng.below(here.len())], at);
        }
        11 => {
            // A song leaves or comes back (folder removed, drive plugged in).
            let s = SONGS[rng.below(SONGS.len())];
            if d.track(&s).is_some() {
                if here.len() > 3 {
                    d.remove(&s);
                }
            } else {
                d.add(&s);
            }
        }
        _ => {}
    }
}

fn converge(devices: &[Device]) {
    for _ in 0..12 {
        let before: Vec<i64> = devices.iter().map(|d| max_seq(&d.conn).unwrap()).collect();
        for i in 0..devices.len() {
            for j in i + 1..devices.len() {
                sync(&devices[i], &devices[j]);
            }
        }
        let after: Vec<i64> = devices.iter().map(|d| max_seq(&d.conn).unwrap()).collect();
        if before == after {
            return;
        }
    }
    panic!("devices did not reach a fixed point");
}

fn run_convergence(n_devices: usize, seed: u64, steps: usize) {
    let mut rng = Rng(seed);
    let names = ["PC", "Phone", "Tablet"];
    let mut devices: Vec<Device> = (0..n_devices).map(|i| Device::new(names[i])).collect();
    for i in 0..n_devices {
        for j in i + 1..n_devices {
            pair(&devices[i], &devices[j]);
        }
        // Different clocks, and different libraries.
        devices[i].now += (rng.below(5000) as i64) - 2500;
        for s in &SONGS {
            if rng.below(4) != 0 {
                devices[i].add(s);
            }
        }
    }
    for _ in 0..steps {
        if rng.below(5) == 0 {
            let i = rng.below(n_devices);
            let j = (i + 1 + rng.below(n_devices - 1)) % n_devices;
            let limit = 2 + rng.below(20);
            for d in devices.iter_mut() {
                d.tick(1);
            }
            pull_with(&devices[i], &devices[j], limit, true).unwrap();
            pull_with(&devices[j], &devices[i], limit, true).unwrap();
        } else {
            let i = rng.below(n_devices);
            random_op(&mut devices[i], &mut rng);
        }
    }
    converge(&devices);

    let first = replicated(&devices[0].conn);
    for d in &devices {
        assert_eq!(
            replicated(&d.conn),
            first,
            "seed {seed}: {} differs",
            d.name
        );
        assert_materialized(d);
        let seq = max_seq(&d.conn).unwrap();
        assert_eq!(d.capture(), CaptureReport::default(), "seed {seed}");
        assert_eq!(max_seq(&d.conn).unwrap(), seq);
        let local: i64 = d
            .conn
            .query_row("SELECT COUNT(*) FROM listen_events", [], |r| r.get(0))
            .unwrap();
        assert_eq!(local as usize, first.listens.len(), "seed {seed}: history");
    }
    // Songs every device has: identical favourites and playlists.
    let common: BTreeSet<String> = SONGS
        .iter()
        .filter(|s| devices.iter().all(|d| d.track(s).is_some()))
        .map(key_of)
        .collect();
    let view = |d: &Device| {
        let favs: BTreeSet<String> = d.favorite_keys().intersection(&common).cloned().collect();
        let map = rows::playlist_map(&d.conn, ProfileId::FIRST).unwrap();
        let res = Resolver::load(&d.conn).unwrap();
        let lists: BTreeMap<String, (String, Vec<String>)> =
            db::playlists(&d.conn, ProfileId::FIRST)
                .unwrap()
                .into_iter()
                .map(|p| {
                    let songs = super::local::entries(&d.conn, p.id)
                        .unwrap()
                        .iter()
                        .map(|(t, _)| res.track(*t).unwrap().key.clone())
                        .filter(|k| common.contains(k))
                        .collect();
                    (map[&p.id].clone(), (p.name, songs))
                })
                .collect();
        (favs, lists)
    };
    let expected = view(&devices[0]);
    for d in &devices[1..] {
        assert_eq!(view(d), expected, "seed {seed}: {} materialised", d.name);
    }
}

#[test]
fn randomised_convergence_two_devices() {
    for seed in 0..40 {
        run_convergence(2, seed, 80);
    }
}

#[test]
fn randomised_convergence_three_devices() {
    for seed in 100..130 {
        run_convergence(3, seed, 120);
    }
}

// --- data health ------------------------------------------------------------------------

fn sample_batch() -> (Device, Batch) {
    let mut a = Device::new("A");
    a.add_all(&SONGS);
    a.toggle(&SONGS[0]);
    a.create("Mix", &SONGS[0..2]);
    a.listen(&SONGS[0], 1);
    a.tick(1);
    a.capture();
    let batch = changes_since(&a.conn, ProfileId::FIRST, 0, 1000).unwrap();
    (a, batch)
}

#[test]
fn validation_rejects_bad_batches_and_applies_nothing() {
    let (_a, good) = sample_batch();
    check_batch(&good).unwrap();
    let mut bad: Vec<(&str, Batch)> = Vec::new();
    let mut add = |what: &'static str, f: &dyn Fn(&mut Batch)| {
        let mut b = good.clone();
        f(&mut b);
        bad.push((what, b));
    };
    add("sender", &|b| b.from_device = "nope".into());
    add("hlc", &|b| b.favorites[0].hlc = "2024".into());
    add("key", &|b| b.favorites[0].key = "Not Normalised".into());
    add("long title", &|b| b.favorites[0].title = "x".repeat(2000));
    add("name", &|b| b.playlists[0].name = "n".repeat(201));
    add("empty name", &|b| b.playlists[0].name = "  ".into());
    add("uuid", &|b| b.playlists[0].uuid = "ABC".into());
    add("cover", &|b| {
        b.playlists[0].cover_preset = Some("/etc/passwd".into())
    });
    add("pos", &|b| b.entries[0].pos = "a0".into());
    add("pos chars", &|b| b.entries[0].pos = "A!".into());
    add("duplicate", &|b| {
        let dup = b.entries[0].clone();
        b.entries.push(dup);
    });
    add("listen", &|b| b.listens[0].listened_ms = -1);
    add("seq", &|b| b.upto_seq = -5);
    add("too many", &|b| {
        let l = b.listens[0].clone();
        b.listens = (0..MAX_RECORDS + 1)
            .map(|i| ListenRecord {
                uid: format!("{i:032x}"),
                ..l.clone()
            })
            .collect();
    });

    let b = Device::new("B");
    b.add_all(&SONGS);
    let before = dump(&b.conn);
    for (what, batch) in &bad {
        let err = apply(
            &b.conn,
            batch,
            &ApplyOptions {
                now_ms: b.now,
                ..default_opts()
            },
        );
        assert!(matches!(err, Err(SyncError::Invalid(_))), "{what}: {err:?}");
    }
    assert_eq!(dump(&b.conn), before);

    // Unknown fields are rejected while parsing.
    let mut json: serde_json::Value = serde_json::to_value(&good).unwrap();
    json["favorites"][0]["extra"] = serde_json::json!(1);
    let bytes = serde_json::to_vec(&json).unwrap();
    assert!(matches!(Batch::from_json(&bytes), Err(SyncError::Json(_))));
    // A batch from ourselves or claiming another sender is refused.
    let (a, own) = sample_batch();
    assert!(matches!(
        apply(&a.conn, &own, &default_opts()),
        Err(SyncError::Invalid(_))
    ));
}

#[test]
fn mass_delete_guard_stops_and_allow_applies() {
    let mut a = Device::new("A");
    let mut b = Device::new("B");
    pair(&a, &b);
    let many: Vec<Song> = (0..40)
        .map(|i| {
            let title: &'static str = Box::leak(format!("Track {i}").into_boxed_str());
            song("Band", "Album", title)
        })
        .collect();
    a.add_all(&many);
    b.add_all(&many);
    for s in &many[..20] {
        a.toggle(s);
    }
    a.create("Big", &many[..20]);
    a.create("One", &many[..1]);
    a.create("Two", &many[..1]);
    a.create("Three", &many[..1]);
    sync(&a, &b);
    assert_eq!(b.favorite_keys().len(), 20);

    // 12 of 20 favourites off (> 25 %, >= 10).
    a.tick(1000);
    for s in &many[..12] {
        a.toggle(s);
    }
    b.tick(1000);
    let before = dump(&b.conn);
    let err = pull_with(&b, &a, 1000, false);
    match err {
        Err(SyncError::MassDelete(plan)) => {
            assert!(matches!(
                plan.guard,
                Some(GuardTrip::Favorites { off: 12, total: 20 })
            ));
        }
        other => panic!("expected the guard, got {other:?}"),
    }
    assert_eq!(
        dump(&b.conn),
        before,
        "nothing applied, watermark unchanged"
    );
    // `plan` reports the same without writing.
    let batch = changes_since(
        &a.conn,
        ProfileId::FIRST,
        peer(&b.conn, &a.id).unwrap().unwrap().last_seq_received,
        1000,
    )
    .unwrap();
    let p = plan(&b.conn, ProfileId::FIRST, &batch, b.now).unwrap();
    assert!(p.guard.is_some() && p.changes_anything());
    assert_eq!(dump(&b.conn), before);
    pull_with(&b, &a, 1000, true).unwrap();
    assert_eq!(b.favorite_keys().len(), 8);

    // Removing 11 of 20 songs from one playlist.
    a.tick(1000);
    let big = a.playlist_id("Big");
    db::playlist_remove(
        &mut a.conn,
        ProfileId::FIRST,
        big,
        &(0..11).collect::<Vec<_>>(),
    )
    .unwrap();
    assert!(matches!(
        pull_with(&b, &a, 1000, false),
        Err(SyncError::MassDelete(p)) if matches!(p.guard, Some(GuardTrip::Songs { .. }))
    ));
    pull_with(&b, &a, 1000, true).unwrap();
    assert_eq!(b.playlists()["Big"].len(), 9);

    // Deleting three playlists.
    a.tick(1000);
    for name in ["One", "Two", "Three"] {
        let id = a.playlist_id(name);
        db::delete_playlist(&a.conn, ProfileId::FIRST, id).unwrap();
    }
    assert!(matches!(
        pull_with(&b, &a, 1000, false),
        Err(SyncError::MassDelete(p)) if matches!(p.guard, Some(GuardTrip::Playlists { .. }))
    ));
    pull_with(&b, &a, 1000, true).unwrap();
    assert_eq!(b.playlists().len(), 1);

    // Small changes pass without asking.
    a.tick(1000);
    a.toggle(&many[15]);
    pull(&b, &a);
}

#[test]
fn apply_is_atomic() {
    let (a, batch) = sample_batch();
    let mut b = Device::new("B");
    b.add_all(&SONGS);
    b.toggle(&SONGS[4]);
    b.tick(10);
    pair(&a, &b);
    // Fail late: materialise writing the history row.
    b.conn
        .execute_batch(
            "CREATE TRIGGER fail_sync BEFORE INSERT ON listen_events
             WHEN NEW.source = 'sync'
             BEGIN SELECT RAISE(ABORT, 'injected failure'); END;",
        )
        .unwrap();
    let before = dump(&b.conn);
    let err = apply(&b.conn, &batch, &opts(&b, &a));
    assert!(matches!(err, Err(SyncError::Db(_))), "{err:?}");
    assert_eq!(dump(&b.conn), before, "nothing changed, not even capture");
    b.conn.execute_batch("DROP TRIGGER fail_sync").unwrap();
    apply(&b.conn, &batch, &opts(&b, &a)).unwrap();
    assert_eq!(
        peer(&b.conn, &a.id).unwrap().unwrap().last_seq_received,
        batch.upto_seq
    );
    assert!(b.favorite_keys().contains(&key_of(&SONGS[0])));
}

#[test]
fn changes_are_paged_in_seq_order() {
    let (a, all) = sample_batch();
    let total = all.len();
    let mut after = 0;
    let mut seen = 0;
    let mut pages = 0;
    loop {
        let page = changes_since(&a.conn, ProfileId::FIRST, after, 2).unwrap();
        assert!(page.len() <= 2);
        seen += page.len();
        pages += 1;
        assert!(page.upto_seq >= after);
        after = page.upto_seq;
        if !page.more {
            break;
        }
    }
    assert_eq!(seen, total);
    assert!(pages >= total / 2);
    assert!(
        changes_since(&a.conn, ProfileId::FIRST, after, 10)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn peers_store_watermarks_and_hide_secrets() {
    let d = Device::new("A");
    let other = "b".repeat(32);
    upsert_peer(&d.conn, &other, "Phone", b"top-secret", ProfileId::FIRST).unwrap();
    ack_sent(&d.conn, &other, 10).unwrap();
    ack_sent(&d.conn, &other, 4).unwrap();
    let p = peer(&d.conn, &other).unwrap().unwrap();
    assert_eq!(p.last_seq_sent, 10, "watermarks never move back");
    assert_eq!(p.secret, b"top-secret");
    assert!(!format!("{p:?}").contains("top-secret"));
    assert_eq!(peers(&d.conn).unwrap().len(), 1);
    assert!(remove_peer(&d.conn, &other).unwrap());
    assert!(ack_sent(&d.conn, &other, 1).is_err());
    assert!(upsert_peer(&d.conn, "bad", "x", b"", ProfileId::FIRST).is_err());
}

#[test]
fn backups_are_rate_limited_and_rotated() {
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("library.sqlite3");
    let conn = Connection::open(&db_path).unwrap();
    db::init(&conn).unwrap();
    let dir = tmp.path().join("sync-backups");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("notes.txt"), "keep me").unwrap();
    let hour = 3_600_000;
    let t0 = 1_794_746_096_000;
    let first = backup_if_due(&conn, &dir, t0).unwrap().unwrap();
    assert!(first.ends_with("library-20261115T123456Z.sqlite3"));
    // The copy is a valid database with the same schema.
    let copy = Connection::open(&first).unwrap();
    let v: i64 = copy
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(v, 15);
    // Close it: Windows cannot delete a file that is still open, and the
    // rotation below removes this oldest backup.
    drop(copy);
    assert!(backup_if_due(&conn, &dir, t0 + 5 * hour).unwrap().is_none());
    for i in 1..=7 {
        assert!(
            backup_if_due(&conn, &dir, t0 + i * 6 * hour)
                .unwrap()
                .is_some()
        );
    }
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    assert_eq!(names.len(), BACKUPS_KEPT + 1);
    assert!(names.contains(&"notes.txt".to_owned()));
    // The newest five are kept.
    assert_eq!(
        names[0],
        format!(
            "library-{}.sqlite3",
            super::backup::utc_stamp(t0 + 3 * 6 * hour)
        )
    );
}

#[test]
fn apply_backs_up_before_the_first_change() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, batch) = sample_batch();
    let b = Device::new("B");
    b.add_all(&SONGS);
    pair(&a, &b);
    let dir = tmp.path().join("sync-backups");
    let mut o = opts(&b, &a);
    o.backup_dir = Some(dir.clone());
    // Nothing to change: no backup.
    let empty = Batch {
        from_device: a.id.clone(),
        ..Batch::default()
    };
    apply(&b.conn, &empty, &o).unwrap();
    assert!(!dir.exists() || std::fs::read_dir(&dir).unwrap().next().is_none());
    apply(&b.conn, &batch, &o).unwrap();
    assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);
    // The backup holds the state before the sync.
    let file = std::fs::read_dir(&dir)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let copy = Connection::open(file).unwrap();
    let favs: i64 = copy
        .query_row("SELECT COUNT(*) FROM favorites", [], |r| r.get(0))
        .unwrap();
    assert_eq!(favs, 0);
    assert_eq!(b.favorite_keys().len(), 1);
}

#[test]
fn migration_backfills_listen_uids() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("old.sqlite3");
    {
        let conn = Connection::open(&path).unwrap();
        db::init(&conn).unwrap();
        // Pretend to be a v12 database with history but no uid column.
        conn.execute_batch(
            "DROP INDEX listen_events_uid;
             ALTER TABLE listen_events DROP COLUMN uid;
             DROP TABLE sync_meta;
             INSERT INTO listen_events(path, title, artist, album, genre, started_at,
                                       ended_at, listened_ms)
             VALUES ('/a', 'A', 'B', '', '', 1, 2, 3), ('/b', 'C', 'D', '', '', 4, 5, 6);
             PRAGMA user_version = 12;",
        )
        .unwrap();
    }
    for _ in 0..2 {
        let conn = Connection::open(&path).unwrap();
        db::init(&conn).unwrap();
        let (n, distinct): (i64, i64) = conn
            .query_row(
                "SELECT COUNT(uid), COUNT(DISTINCT uid) FROM listen_events",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!((n, distinct), (2, 2));
        let v: i64 = conn
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(v, 15);
    }
}

// --- per-profile sync (K24) ---------------------------------------------------

impl Device {
    fn add_profile(&self, name: &str) -> ProfileId {
        crate::library::profiles::create_profile(&self.conn, name, 1)
            .unwrap()
            .id
    }

    fn pfavorite(&self, p: ProfileId, s: &Song) {
        let id = self.id_of(s);
        db::toggle_favorite(&self.conn, p, id, self.secs()).unwrap();
    }

    fn pcreate(&mut self, p: ProfileId, name: &str, songs: &[Song]) -> i64 {
        let ids: Vec<i64> = songs.iter().map(|s| self.id_of(s)).collect();
        let now = self.secs();
        db::create_playlist(&mut self.conn, p, name, &ids, now)
            .unwrap()
            .id
    }

    fn plisten(&self, p: ProfileId, s: &Song, at: i64) {
        db::record_listen_event(
            &self.conn,
            p,
            &NewListenEvent {
                path: Self::path(s),
                title: s.title.into(),
                artist: s.artist.into(),
                duration_ms: Some(200_000),
                started_at: at,
                ended_at: at + 200,
                listened_ms: 200_000,
                completed: true,
                skipped: false,
            },
        )
        .unwrap();
    }

    /// A profile's favourites as track keys.
    fn pfavorite_keys(&self, p: ProfileId) -> BTreeSet<String> {
        let res = Resolver::load(&self.conn).unwrap();
        db::favorites(&self.conn, p)
            .unwrap()
            .iter()
            .map(|f| res.track(f.track_id).unwrap().key.clone())
            .collect()
    }

    /// A profile's playlists: name -> song keys in order.
    fn pplaylists(&self, p: ProfileId) -> BTreeMap<String, Vec<String>> {
        let res = Resolver::load(&self.conn).unwrap();
        db::playlists(&self.conn, p)
            .unwrap()
            .into_iter()
            .map(|pl| {
                let keys = super::local::entries(&self.conn, pl.id)
                    .unwrap()
                    .iter()
                    .map(|(t, _)| res.track(*t).unwrap().key.clone())
                    .collect();
                (pl.name, keys)
            })
            .collect()
    }

    /// A profile's local listens: titles, sorted.
    fn plistens(&self, p: ProfileId) -> Vec<String> {
        let mut st = self
            .conn
            .prepare("SELECT title FROM listen_events WHERE profile_id = ?1 ORDER BY title")
            .unwrap();
        st.query_map([p.0], |r| r.get(0))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap()
    }

    fn count(&self, sql: &str, p: ProfileId) -> i64 {
        self.conn.query_row(sql, [p.0], |r| r.get(0)).unwrap()
    }
}

/// `a` has two profiles and pairs `b` with its profile `bound`; `b` (one
/// profile) is bound to its own profile 1.
fn pair_bound(a: &Device, b: &Device, bound: ProfileId) {
    upsert_peer(&a.conn, &b.id, &b.name, b"secret-ab", bound).unwrap();
    upsert_peer(&b.conn, &a.id, &a.name, b"secret-ab", ProfileId::FIRST).unwrap();
}

#[test]
fn a_pairing_syncs_only_its_bound_profile() {
    let mut a = Device::new("A");
    let mut b = Device::new("B");
    a.add_all(&SONGS);
    b.add_all(&SONGS);
    let (p1, p2) = (ProfileId::FIRST, a.add_profile("Second"));
    // Profile 1 of A has its own taste; profile 2 is the one B syncs with.
    a.pfavorite(p1, &SONGS[0]);
    a.pcreate(p1, "Private mix", &[SONGS[0], SONGS[1]]);
    a.plisten(p1, &SONGS[0], 1_000);
    a.pfavorite(p2, &SONGS[1]);
    a.pcreate(p2, "Shared mix", &[SONGS[2], SONGS[3]]);
    a.plisten(p2, &SONGS[2], 2_000);
    b.toggle(&SONGS[4]);
    b.create("From B", &[SONGS[5]]);
    b.listen(&SONGS[5], 3_000);
    pair_bound(&a, &b, p2);

    // Nothing of profile 1 is in any batch A sends.
    a.tick(1000);
    capture(&a.conn, a.now, &bound_profiles(&a.conn).unwrap()).unwrap();
    assert_eq!(bound_profiles(&a.conn).unwrap(), vec![p2]);
    let out = changes_since(&a.conn, p2, 0, 1000).unwrap();
    let wire = serde_json::to_string(&out).unwrap();
    for leaked in [
        "Private mix",
        &key_of(&SONGS[0]),
        &key_of(&SONGS[1]),
        "Sinnerman",
    ] {
        assert!(!wire.contains(leaked), "leaked {leaked}");
    }
    assert_eq!(out.listens.len(), 1);
    assert_eq!(out.listens[0].title, SONGS[2].title);
    assert!(
        changes_since(&a.conn, p1, 0, 1000).unwrap().is_empty(),
        "profile 1 was never captured for sync"
    );

    sync(&a, &b);
    a.tick(1000);
    sync(&a, &b);

    // Profile 2 and B converge.
    let want_favs: BTreeSet<String> = [key_of(&SONGS[1]), key_of(&SONGS[4])].into();
    assert_eq!(a.pfavorite_keys(p2), want_favs);
    assert_eq!(b.favorite_keys(), want_favs);
    assert_eq!(
        a.pplaylists(p2).keys().collect::<Vec<_>>(),
        vec!["From B", "Shared mix"]
    );
    assert_eq!(a.pplaylists(p2), b.playlists());
    let both = vec![SONGS[5].title.to_owned(), SONGS[2].title.to_owned()];
    assert_eq!(a.plistens(p2), both);
    assert_eq!(b.plistens(ProfileId::FIRST), both);

    // Profile 1 is exactly as it was.
    assert_eq!(
        a.pfavorite_keys(p1),
        [key_of(&SONGS[0])].into_iter().collect()
    );
    assert_eq!(
        a.pplaylists(p1).keys().collect::<Vec<_>>(),
        vec!["Private mix"]
    );
    assert_eq!(a.plistens(p1), vec![SONGS[0].title.to_owned()]);
    for table in [
        "sync_favorites",
        "sync_playlists",
        "sync_playlist_entries",
        "sync_listens",
    ] {
        assert_eq!(
            a.count(
                &format!("SELECT COUNT(*) FROM {table} WHERE profile_id = ?1"),
                p1
            ),
            0,
            "{table} has profile 1 rows"
        );
    }

    // Later edits on both sides keep converging, and still never touch
    // profile 1.
    a.tick(1000);
    a.pfavorite(p2, &SONGS[1]); // un-favourite
    a.pfavorite(p1, &SONGS[6]);
    b.tick(1000);
    b.toggle(&SONGS[7]);
    sync(&a, &b);
    a.tick(1000);
    sync(&a, &b);
    assert_eq!(a.pfavorite_keys(p2), b.favorite_keys());
    assert!(!a.pfavorite_keys(p2).contains(&key_of(&SONGS[1])));
    assert_eq!(
        a.pfavorite_keys(p1),
        [key_of(&SONGS[0]), key_of(&SONGS[6])].into_iter().collect()
    );
}

#[test]
fn every_bound_profile_is_captured_when_a_song_reappears() {
    let mut a = Device::new("A");
    let (b, c) = (Device::new("B"), Device::new("C"));
    a.add_all(&SONGS);
    let (p1, p2) = (ProfileId::FIRST, a.add_profile("Second"));
    // B is bound to profile 1, C to profile 2.
    upsert_peer(&a.conn, &b.id, &b.name, b"s1", p1).unwrap();
    upsert_peer(&b.conn, &a.id, &a.name, b"s1", p1).unwrap();
    upsert_peer(&a.conn, &c.id, &c.name, b"s2", p2).unwrap();
    upsert_peer(&c.conn, &a.id, &a.name, b"s2", p1).unwrap();
    a.pfavorite(p1, &SONGS[0]);
    a.pfavorite(p2, &SONGS[0]);
    a.pcreate(p2, "List", &[SONGS[0], SONGS[1]]);
    let bound = bound_profiles(&a.conn).unwrap();
    assert_eq!(bound, vec![p1, p2]);
    capture(&a.conn, a.now, &bound).unwrap();

    // The song disappears (an unplugged drive): its rows cascade out of
    // both profiles and capture, which sees it absent, keeps the sync state.
    a.remove(&SONGS[0]);
    a.tick(1000);
    capture(&a.conn, a.now, &bound).unwrap();
    assert!(a.pfavorite_keys(p1).is_empty() && a.pfavorite_keys(p2).is_empty());
    // It comes back. The sync with B captures *all* bound profiles, so
    // profile 2 is restored as well, not read as an unfavourite.
    a.add(&SONGS[0]);
    b.add_all(&SONGS);
    a.tick(1000);
    pull(&a, &b);
    let want: BTreeSet<String> = [key_of(&SONGS[0])].into();
    assert_eq!(a.pfavorite_keys(p1), want);
    assert_eq!(a.pfavorite_keys(p2), want);
    assert_eq!(a.pplaylists(p2)["List"], keys(&[SONGS[0], SONGS[1]]));
    // And nothing was stamped as removed for either profile.
    assert_eq!(
        a.count(
            "SELECT COUNT(*) FROM sync_favorites WHERE profile_id = ?1 AND is_on = 0",
            p2
        ),
        0
    );
    a.tick(1000);
    assert_eq!(
        capture(&a.conn, a.now, &bound).unwrap(),
        CaptureReport::default()
    );
}

#[test]
fn deleting_a_bound_profile_removes_its_pairing_and_sync_rows() {
    let mut a = Device::new("A");
    let (b, c) = (Device::new("B"), Device::new("C"));
    a.add_all(&SONGS);
    b.add_all(&SONGS);
    c.add_all(&SONGS);
    let (p1, p2) = (ProfileId::FIRST, a.add_profile("Second"));
    upsert_peer(&a.conn, &b.id, &b.name, b"s1", p1).unwrap();
    upsert_peer(&b.conn, &a.id, &a.name, b"s1", p1).unwrap();
    upsert_peer(&a.conn, &c.id, &c.name, b"s2", p2).unwrap();
    upsert_peer(&c.conn, &a.id, &a.name, b"s2", p1).unwrap();
    set_peer_address(&a.conn, &c.id, "127.0.0.1:1").unwrap();
    a.pfavorite(p1, &SONGS[0]);
    a.pfavorite(p2, &SONGS[1]);
    a.pcreate(p2, "Two", &[SONGS[2]]);
    a.plisten(p2, &SONGS[2], 5_000);
    pull(&c, &a);
    pull(&b, &a);
    assert_eq!(peers(&a.conn).unwrap().len(), 2);

    crate::library::profiles::delete_profile(&mut a.conn, p2, p1).unwrap();

    let left: Vec<String> = peers(&a.conn)
        .unwrap()
        .into_iter()
        .map(|p| p.device_id)
        .collect();
    assert_eq!(left, vec![b.id.clone()]);
    for table in [
        "sync_favorites",
        "sync_playlists",
        "sync_playlist_entries",
        "sync_listens",
    ] {
        assert_eq!(
            a.count(
                &format!("SELECT COUNT(*) FROM {table} WHERE profile_id = ?1"),
                p2
            ),
            0,
            "{table}"
        );
    }
    // Profile 1's pairing and rows are untouched.
    assert_eq!(bound_profiles(&a.conn).unwrap(), vec![p1]);
    assert_eq!(
        a.count(
            "SELECT COUNT(*) FROM sync_favorites WHERE profile_id = ?1",
            p1
        ),
        1
    );
    // Capture still works afterwards (stale playlist-map rows are ignored).
    a.tick(1000);
    capture(&a.conn, a.now, &[p1]).unwrap();
    assert_eq!(a.pfavorite_keys(p1), [key_of(&SONGS[0])].into());
}

#[test]
fn migration_v14_to_v15_keeps_sync_rows_in_profile_one() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("v14.sqlite3");
    {
        let conn = Connection::open(&path).unwrap();
        db::init(&conn).unwrap();
        // Rebuild the sync tables as v14 had them (no profile columns) and
        // fill them.
        conn.execute_batch(
            "DROP TABLE sync_favorites; DROP TABLE sync_playlists;
             DROP TABLE sync_playlist_entries; DROP TABLE sync_listens;
             DROP TABLE sync_playlist_map; DROP TABLE sync_peers; DROP TABLE sync_present;
             DROP TABLE sync_meta;",
        )
        .unwrap();
        conn.execute_batch(db::SCHEMA_V13).unwrap();
        conn.execute_batch(
            "INSERT INTO sync_favorites VALUES ('k1','T','A','B',1,1,'h1',1), ('k2','T','A','B',1,0,'h2',2);
             INSERT INTO sync_playlists VALUES ('u1','N','h','preset:x','h',0,'h',1,1,3);
             INSERT INTO sync_playlist_entries VALUES
                 ('e1','u1','k1','T','A','B',1,1,'m','h',0,'h',4);
             INSERT INTO sync_listens VALUES
                 ('l1','k1','T','A','B','',1,'/p',1,2,3,1,0,5);
             INSERT INTO sync_peers(device_id, name, secret, last_seq_sent, last_seq_received)
                 VALUES ('0f1e2d3c4b5a69788796a5b4c3d2e1f0', 'Phone', x'01', 4, 7);
             PRAGMA user_version = 14;",
        )
        .unwrap();
    }
    for _ in 0..2 {
        let conn = Connection::open(&path).unwrap();
        db::init(&conn).unwrap();
        let count = |sql: &str| -> i64 { conn.query_row(sql, [], |r| r.get(0)).unwrap() };
        for table in [
            "sync_favorites",
            "sync_playlists",
            "sync_playlist_entries",
            "sync_listens",
            "sync_peers",
        ] {
            let total = count(&format!("SELECT COUNT(*) FROM {table}"));
            let first = count(&format!(
                "SELECT COUNT(*) FROM {table} WHERE profile_id = 1"
            ));
            assert!(total > 0 && total == first, "{table}: {first}/{total}");
        }
        assert_eq!(count("SELECT COUNT(*) FROM sync_favorites"), 2);
        let p = peers(&conn).unwrap();
        assert_eq!(p[0].profile, ProfileId::FIRST);
        assert_eq!((p[0].last_seq_sent, p[0].last_seq_received), (4, 7));
        let batch = changes_since(&conn, ProfileId::FIRST, 0, 100).unwrap();
        assert_eq!(batch.len(), 5);
        assert!(
            changes_since(&conn, ProfileId(2), 0, 100)
                .unwrap()
                .is_empty()
        );
        // (profile_id, key) is the favourites key now.
        let pk: i64 =
            count("SELECT COUNT(*) FROM pragma_table_info('sync_favorites') WHERE pk > 0");
        assert_eq!(pk, 2);
        assert_eq!(count("PRAGMA user_version"), 15);
        assert_eq!(count("SELECT COUNT(*) FROM pragma_foreign_key_check"), 0);
    }
}

//! End-to-end tests of the sync service over loopback TCP: two libraries in
//! temp dirs, a computer (server) and a phone (client) service, a player
//! with a silent engine. No sound card, no network beyond 127.0.0.1.

use super::link;
use super::protocol::{ErrorCode, Msg, SYNC_VERSION};
use super::remote::{RemoteCmd, RemoteFeed, RemoteStatus};
use super::service::{EventSink, PeerStatus, SyncConfig, SyncService};
use super::store;
use crate::library::{Hooks, Library, ProfileId, db};
use crate::player::bulk_tests::Silent;
use crate::player::{Player, Status};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tempfile::TempDir;

const SONGS: usize = 14;

#[derive(Default)]
struct Events(Mutex<Vec<(String, serde_json::Value)>>);

impl EventSink for Events {
    fn emit(&self, event: &str, payload: serde_json::Value) {
        self.0.lock().unwrap().push((event.to_owned(), payload));
    }
}

impl Events {
    fn named(&self, name: &str) -> Vec<serde_json::Value> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .filter(|(n, _)| n == name)
            .map(|(_, v)| v.clone())
            .collect()
    }
}

struct Dev {
    _dir: TempDir,
    lib: Arc<Library>,
    svc: SyncService,
    events: Arc<Events>,
    player: Arc<Player>,
}

fn title(i: usize) -> String {
    format!("Song {i}")
}

fn path(i: usize) -> String {
    format!("/m/{i}.flac")
}

/// A device whose library holds songs 0..SONGS (same tags on every device,
/// so they resolve to the same keys).
async fn device(name: &str, server: bool) -> Dev {
    let dir = TempDir::new().unwrap();
    let lib = Arc::new(
        Library::open(
            &dir.path().join("library.sqlite3"),
            &dir.path().join("covers"),
            Hooks::none(),
        )
        .unwrap(),
    );
    {
        let conn = lib.conn();
        conn.execute("INSERT INTO folders(id, path) VALUES (1, '/m')", [])
            .unwrap();
        for i in 0..SONGS {
            conn.execute(
                "INSERT INTO albums(title, album_artist, cover) VALUES (?1, 'Artist', ?2)",
                rusqlite::params![format!("Album {i}"), format!("/covers/{name}/{i}.jpg")],
            )
            .unwrap();
            let album = conn.last_insert_rowid();
            conn.execute(
                "INSERT INTO tracks(folder_id, path, mtime, size, title, artist, album_id,
                                    duration_ms, added_at)
                 VALUES (1, ?1, 1, 1, ?2, 'Artist', ?3, 200000, 1)",
                rusqlite::params![path(i), title(i), album],
            )
            .unwrap();
        }
        store::set_device_name(&conn, name).unwrap();
    }
    let feed = RemoteFeed::new();
    let observer = feed.clone();
    let player = Arc::new(Player::new(
        Box::new(Silent),
        Box::new(move |ev| observer.on_player_event(&ev)),
    ));
    let events = Arc::new(Events::default());
    let svc = SyncService::new(
        Arc::clone(&lib),
        Some(Arc::clone(&player)),
        feed,
        events.clone(),
        SyncConfig {
            port: 0,
            server,
            default_name: name.into(),
            backup_dir: dir.path().join("sync-backups"),
        },
    );
    svc.start(false).await;
    Dev {
        _dir: dir,
        lib,
        svc,
        events,
        player,
    }
}

fn rt<F: std::future::Future>(f: F) -> F::Output {
    tauri::async_runtime::block_on(f)
}

macro_rules! wait_for {
    ($what:expr, $cond:expr) => {{
        let deadline = std::time::Instant::now() + Duration::from_secs(15);
        loop {
            if $cond {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "timed out waiting for {}",
                $what
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }};
}

impl Dev {
    fn id_of(&self, i: usize) -> i64 {
        db::track_id_by_path(&self.lib.conn(), &path(i))
            .unwrap()
            .unwrap()
    }

    fn favorite(&self, songs: &[usize], on: bool) {
        let ids: Vec<i64> = songs.iter().map(|&i| self.id_of(i)).collect();
        db::set_favorites(
            &mut self.lib.conn(),
            ProfileId::FIRST,
            &ids,
            on,
            1_700_000_000,
        )
        .unwrap();
    }

    fn create(&self, name: &str, songs: &[usize]) -> i64 {
        let ids: Vec<i64> = songs.iter().map(|&i| self.id_of(i)).collect();
        db::create_playlist(
            &mut self.lib.conn(),
            ProfileId::FIRST,
            name,
            &ids,
            1_700_000_000,
        )
        .unwrap()
        .id
    }

    fn favorites(&self) -> BTreeSet<String> {
        let conn = self.lib.conn();
        let mut st = conn
            .prepare("SELECT t.title FROM favorites f JOIN tracks t ON t.id = f.track_id")
            .unwrap();
        st.query_map([], |r| r.get(0))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap()
    }

    fn playlists(&self) -> BTreeMap<String, Vec<String>> {
        let conn = self.lib.conn();
        let mut st = conn
            .prepare(
                "SELECT p.name, t.title FROM playlists p
                 JOIN playlist_tracks pt ON pt.playlist_id = p.id
                 JOIN tracks t ON t.id = pt.track_id
                 ORDER BY p.name, pt.position",
            )
            .unwrap();
        let mut out: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for row in st
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
            .unwrap()
        {
            let (name, title) = row.unwrap();
            out.entry(name).or_default().push(title);
        }
        out
    }

    async fn id(&self) -> String {
        self.svc.status().await.unwrap().device_id
    }

    async fn peer(&self, id: &str) -> Option<PeerStatus> {
        self.svc
            .status()
            .await
            .unwrap()
            .peers
            .into_iter()
            .find(|p| p.id == id)
    }

    async fn rounds(&self, id: &str) -> u64 {
        self.peer(id).await.map_or(0, |p| p.rounds)
    }

    async fn connected(&self, id: &str) -> bool {
        self.peer(id).await.is_some_and(|p| p.connected)
    }
}

fn titles(v: &[usize]) -> Vec<String> {
    v.iter().map(|&i| title(i)).collect()
}

fn title_set(v: &[usize]) -> BTreeSet<String> {
    v.iter().map(|&i| title(i)).collect()
}

struct Pair {
    pc: Dev,
    phone: Dev,
    pc_id: String,
    phone_id: String,
    port: u16,
}

/// A computer with phone connections on, and a phone paired with it that
/// finished its first sync.
async fn paired(setup: impl FnOnce(&Dev, &Dev)) -> Pair {
    let pc = device("Desk PC", true).await;
    let phone = device("Pixel", false).await;
    setup(&pc, &phone);
    let port = pc
        .svc
        .set_allow_phone_connections(true)
        .await
        .unwrap()
        .listening
        .unwrap()
        .port;
    let open = pc.svc.pair_open().await.unwrap();
    phone
        .svc
        .connect_pair(&format!("127.0.0.1:{port}"), &open.code)
        .await
        .unwrap();
    let (pc_id, phone_id) = (pc.id().await, phone.id().await);
    wait_for!("the first sync", phone.rounds(&pc_id).await >= 1);
    Pair {
        pc,
        phone,
        pc_id,
        phone_id,
        port,
    }
}

impl Pair {
    async fn shutdown(self) {
        self.phone.svc.shutdown().await;
        self.pc.svc.shutdown().await;
    }

    /// The phone runs one more sync round.
    async fn sync(&self) {
        let before = self.phone.rounds(&self.pc_id).await;
        self.phone.svc.sync_now().await.unwrap();
        wait_for!(
            "a sync round",
            self.phone.rounds(&self.pc_id).await > before
        );
    }
}

#[test]
fn pairing_needs_the_right_code() {
    rt(async {
        let pc = device("Desk PC", true).await;
        let phone = device("Pixel", false).await;
        // Off by default: no listener, no pairing.
        let st = pc.svc.status().await.unwrap();
        assert!(!st.allow_phone_connections && st.listening.is_none());
        assert!(pc.svc.pair_open().await.is_err());
        // The phone role cannot listen.
        assert!(phone.svc.set_allow_phone_connections(true).await.is_err());

        let port = pc
            .svc
            .set_allow_phone_connections(true)
            .await
            .unwrap()
            .listening
            .unwrap()
            .port;
        let open = pc.svc.pair_open().await.unwrap();
        assert_eq!(open.port, port);
        assert_eq!(
            pc.svc.status().await.unwrap().pairing.code.as_deref(),
            Some(open.code.as_str())
        );
        let wrong = if open.code == "123456" {
            "654321"
        } else {
            "123456"
        };
        let addr = format!("127.0.0.1:{port}");
        let err = phone.svc.connect_pair(&addr, wrong).await.unwrap_err();
        assert!(err.contains("wrong pairing code"), "{err}");
        assert!(pc.svc.status().await.unwrap().peers.is_empty());
        assert!(phone.svc.status().await.unwrap().peers.is_empty());
        // Not a LAN address: refused before dialling.
        assert!(phone.svc.connect_pair("8.8.8.8", &open.code).await.is_err());

        phone.svc.connect_pair(&addr, &open.code).await.unwrap();
        let (pc_id, phone_id) = (pc.id().await, phone.id().await);
        let computer = phone.peer(&pc_id).await.unwrap();
        assert_eq!(
            (computer.kind, computer.name.as_str()),
            ("computer", "Desk PC")
        );
        assert_eq!(computer.address.as_deref(), Some(addr.as_str()));
        let p = pc.peer(&phone_id).await.unwrap();
        assert_eq!((p.kind, p.name.as_str()), ("phone", "Pixel"));
        // The code is used up; the phone connects and syncs on its own.
        assert_eq!(pc.svc.status().await.unwrap().pairing.state, "closed");
        wait_for!("the session", pc.connected(&phone_id).await);
        wait_for!("the first sync", phone.rounds(&pc_id).await >= 1);
        assert!(!pc.events.named("sync://status").is_empty());
        phone.svc.shutdown().await;
        pc.svc.shutdown().await;
    });
}

#[test]
fn favourites_and_playlists_converge_both_ways() {
    rt(async {
        let p = paired(|pc, phone| {
            pc.favorite(&[0, 1], true);
            pc.create("Road", &[0, 2]);
            phone.favorite(&[2], true);
            phone.create("Gym", &[3, 4]);
        })
        .await;
        for dev in [&p.pc, &p.phone] {
            assert_eq!(dev.favorites(), title_set(&[0, 1, 2]));
            let lists = dev.playlists();
            assert_eq!(lists["Road"], titles(&[0, 2]));
            assert_eq!(lists["Gym"], titles(&[3, 4]));
        }
        let first = p.phone.peer(&p.pc_id).await.unwrap();
        assert!(first.last_result.unwrap().error.is_none());
        assert!(first.last_sync_at.is_some());

        // Edits on both sides, then one more round.
        p.pc.favorite(&[0], false);
        let road = p.pc.playlists().len();
        assert_eq!(road, 2);
        let road_id = db::playlists(&p.pc.lib.conn(), ProfileId::FIRST)
            .unwrap()
            .into_iter()
            .find(|l| l.name == "Road")
            .unwrap()
            .id;
        let five = p.pc.id_of(5);
        db::playlist_add_tracks(&mut p.pc.lib.conn(), ProfileId::FIRST, road_id, &[five]).unwrap();
        p.phone.favorite(&[3], true);
        p.phone.create("Chill", &[6]);
        p.sync().await;

        let want: BTreeMap<String, Vec<String>> = [
            ("Chill".to_owned(), titles(&[6])),
            ("Gym".to_owned(), titles(&[3, 4])),
            ("Road".to_owned(), titles(&[0, 2, 5])),
        ]
        .into();
        for dev in [&p.pc, &p.phone] {
            assert_eq!(dev.favorites(), title_set(&[1, 2, 3]));
            assert_eq!(dev.playlists(), want);
        }
        let result = p.phone.svc.status().await.unwrap().last_result.unwrap();
        assert!(result.sent > 0 && result.received > 0, "{result:?}");
        p.shutdown().await;
    });
}

#[test]
fn the_mass_delete_guard_waits_for_the_user() {
    rt(async {
        let all: Vec<usize> = (0..12).collect();
        let p = paired(|_, phone| phone.favorite(&all, true)).await;
        assert_eq!(p.pc.favorites().len(), 12);

        // The phone drops every favourite: the computer stops and asks.
        p.phone.favorite(&all, false);
        p.sync().await;
        let pending = p.pc.peer(&p.phone_id).await.unwrap().pending_guard;
        let summary = pending.expect("the guard should have tripped");
        assert_eq!(summary.favorites_turned_off, 12);
        assert_eq!(p.pc.favorites().len(), 12, "nothing applied");
        assert!(
            p.phone.peer(&p.pc_id).await.unwrap().last_error.is_some(),
            "the phone shows that the computer is waiting"
        );

        // Skip: the local data stays, and the next sync asks again.
        p.pc.svc.guard_decide(&p.phone_id, false).await.unwrap();
        assert!(
            p.pc.peer(&p.phone_id)
                .await
                .unwrap()
                .pending_guard
                .is_none()
        );
        assert!(p.pc.svc.guard_decide(&p.phone_id, false).await.is_err());
        p.sync().await;
        assert!(
            p.pc.peer(&p.phone_id)
                .await
                .unwrap()
                .pending_guard
                .is_some()
        );
        assert_eq!(p.pc.favorites().len(), 12);

        // Apply: the computer asks the phone for a sync that goes through.
        p.pc.svc.guard_decide(&p.phone_id, true).await.unwrap();
        wait_for!("the approved sync", p.pc.favorites().is_empty());
        wait_for!(
            "the decision to be used up",
            p.pc.peer(&p.phone_id)
                .await
                .unwrap()
                .pending_guard
                .is_none()
        );
        // A backup was taken before the first apply that changed data.
        let backups = std::fs::read_dir(p.pc._dir.path().join("sync-backups"))
            .unwrap()
            .count();
        assert!(backups >= 1);
        p.shutdown().await;
    });
}

#[test]
fn remote_commands_reach_the_computers_player() {
    rt(async {
        let p = paired(|_, _| {}).await;
        let queue: Vec<PathBuf> = [0, 1, 2].iter().map(|&i| PathBuf::from(path(i))).collect();
        p.pc.player.replace_queue(queue, 0).unwrap();
        assert_eq!(p.pc.player.snapshot().status, Status::Playing);
        wait_for!(
            "the playing state on the phone",
            p.phone
                .svc
                .remote_state()
                .is_some_and(|s| s.status == RemoteStatus::Playing && s.queue_length == 3)
        );
        let state = p.phone.svc.remote_state().unwrap();
        let current = state.current.unwrap();
        assert_eq!(current.title, title(0));
        assert_eq!(current.album, "Album 0");
        assert_eq!(
            current.key,
            store::track_key("Artist", "Album 0", &title(0))
        );
        // The phone shows its own cover for the same song.
        assert_eq!(
            p.phone.svc.cover_for_key(&current.key).await.unwrap(),
            Some("/covers/Pixel/0.jpg".into())
        );
        assert_eq!(p.phone.svc.cover_for_key("nope").await.unwrap(), None);

        p.phone
            .svc
            .remote_send(RemoteCmd::TogglePause {})
            .await
            .unwrap();
        assert_eq!(p.pc.player.snapshot().status, Status::Paused);
        wait_for!(
            "the paused state on the phone",
            p.phone
                .svc
                .remote_state()
                .is_some_and(|s| s.status == RemoteStatus::Paused)
        );
        assert!(!p.phone.events.named("remote://state").is_empty());

        p.phone
            .svc
            .remote_send(RemoteCmd::SetVolume { percent: 40.0 })
            .await
            .unwrap();
        assert_eq!(p.pc.player.snapshot().volume, 40.0);
        // Out-of-range values never leave the phone.
        assert!(
            p.phone
                .svc
                .remote_send(RemoteCmd::SetVolume { percent: 400.0 })
                .await
                .is_err()
        );

        // "Next up": the songs after the current one, `offset` counted from
        // the next song; entries keep their queue index.
        let page = p.phone.svc.remote_queue_page(0, 10).await.unwrap();
        assert_eq!((page.offset, page.total, page.entries.len()), (0, 2, 2));
        assert_eq!(page.entries[0].index, 1);
        assert_eq!(page.entries[0].title, title(1));
        let second = p.phone.svc.remote_queue_page(1, 10).await.unwrap();
        assert_eq!((second.offset, second.entries.len()), (1, 1));
        assert_eq!(second.entries[0].index, 2);
        assert!(p.phone.svc.remote_queue_page(0, 101).await.is_err());

        // With shuffle on, the list is the order the computer will play.
        p.phone
            .svc
            .remote_send(RemoteCmd::SetShuffle { on: true })
            .await
            .unwrap();
        let shuffled = p.phone.svc.remote_queue_page(0, 10).await.unwrap();
        let (_, expected) = p.pc.player.up_next_page(0, 10);
        assert_eq!(
            shuffled.entries.iter().map(|e| e.index).collect::<Vec<_>>(),
            expected.iter().map(|(i, _)| *i).collect::<Vec<_>>()
        );
        p.phone
            .svc
            .remote_send(RemoteCmd::SetShuffle { on: false })
            .await
            .unwrap();

        // A stale queue version is refused; the current one works.
        let stale = RemoteCmd::PlayIndex {
            index: 2,
            queue_version: page.queue_version + 1,
        };
        let err = p.phone.svc.remote_send(stale).await.unwrap_err();
        assert!(err.contains("queue changed"), "{err}");
        assert_eq!(p.pc.player.snapshot().current_index, Some(0));
        p.phone
            .svc
            .remote_send(RemoteCmd::PlayIndex {
                index: 2,
                queue_version: page.queue_version,
            })
            .await
            .unwrap();
        assert_eq!(p.pc.player.snapshot().current_index, Some(2));
        p.shutdown().await;
    });
}

#[test]
fn remote_commands_are_rate_limited() {
    rt(async {
        let p = paired(|_, _| {}).await;
        let mut tasks = Vec::new();
        for i in 0..60 {
            let svc = p.phone.svc.clone();
            tasks.push(tauri::async_runtime::spawn(async move {
                svc.remote_send(RemoteCmd::SetVolume {
                    percent: f64::from(i % 100),
                })
                .await
            }));
        }
        let mut refused = 0;
        for t in tasks {
            if let Err(e) = t.await.unwrap() {
                assert!(e.contains("too many"), "{e}");
                refused += 1;
            }
        }
        assert!(refused >= 10, "only {refused} of 60 refused");
        p.shutdown().await;
    });
}

#[test]
fn turning_phone_connections_off_closes_sessions_and_the_port() {
    rt(async {
        let p = paired(|_, _| {}).await;
        wait_for!("the session", p.pc.connected(&p.phone_id).await);
        let st = p.pc.svc.set_allow_phone_connections(false).await.unwrap();
        assert!(!st.allow_phone_connections && st.listening.is_none());
        wait_for!("the phone to notice", !p.phone.connected(&p.pc_id).await);
        assert!(!p.pc.connected(&p.phone_id).await);
        let addr = format!("127.0.0.1:{}", p.port).parse().unwrap();
        assert!(link::dial(addr, Duration::from_secs(2)).await.is_err());
        p.shutdown().await;
    });
}

#[test]
fn removing_a_phone_closes_its_session_and_locks_it_out() {
    rt(async {
        let p = paired(|_, _| {}).await;
        wait_for!("the session", p.pc.connected(&p.phone_id).await);
        p.pc.svc.remove_peer(&p.phone_id).await.unwrap();
        assert!(p.pc.peer(&p.phone_id).await.is_none());
        wait_for!(
            "the phone to be dropped",
            !p.phone.connected(&p.pc_id).await
        );
        // It keeps trying, but the computer no longer knows it.
        p.phone.svc.sync_now().await.unwrap();
        wait_for!(
            "the reconnect to fail",
            p.phone
                .peer(&p.pc_id)
                .await
                .is_some_and(|s| s.last_error.is_some() && !s.connected)
        );
        // The phone forgets the computer.
        p.phone.svc.forget().await.unwrap();
        assert!(p.phone.svc.status().await.unwrap().peers.is_empty());
        assert!(p.phone.svc.forget().await.is_err());
        p.shutdown().await;
    });
}

#[test]
fn a_different_sync_version_is_refused() {
    rt(async {
        let p = paired(|_, _| {}).await;
        let secret = {
            let conn = p.phone.lib.conn();
            store::peer(&conn, &p.pc_id).unwrap().unwrap().secret
        };
        let secret: [u8; 32] = secret.try_into().unwrap();
        let addr = format!("127.0.0.1:{}", p.port).parse().unwrap();
        let mut session = link::connect(addr, &p.phone_id, &secret).await.unwrap();
        let hello = Msg::Hello {
            sync_version: SYNC_VERSION + 1,
            app_version: "9.9.9".into(),
            device_name: "Future phone".into(),
        };
        session.send(&hello.to_bytes()).await.unwrap();
        let reply = Msg::parse(&session.recv().await.unwrap()).unwrap();
        assert!(
            matches!(
                reply,
                Msg::Error {
                    code: ErrorCode::Version,
                    ..
                }
            ),
            "{reply:?}"
        );
        // ...and the computer closes the connection.
        assert!(session.recv().await.is_err());
        p.shutdown().await;
    });
}

#[test]
fn a_page_shrinks_until_it_fits_the_size_limit() {
    rt(async {
        let pc = device("Desk PC", true).await;
        pc.favorite(&(0..SONGS).collect::<Vec<_>>(), true);
        let conn = pc.lib.conn();
        store::upsert_peer(
            &conn,
            "0f1e2d3c4b5a69788796a5b4c3d2e1f0",
            "Pixel",
            &[1; 32],
            ProfileId::FIRST,
        )
        .unwrap();
        store::capture(&conn, 1_700_000_000_000, &[ProfileId::FIRST]).unwrap();
        let whole =
            super::conn::build_page(&conn, "0f1e2d3c4b5a69788796a5b4c3d2e1f0", 2000, 1 << 20)
                .unwrap();
        assert_eq!((whole.len, whole.more), (SONGS, false));
        let small =
            super::conn::build_page(&conn, "0f1e2d3c4b5a69788796a5b4c3d2e1f0", 2000, 1500).unwrap();
        assert!(small.bytes.len() <= 1500, "{}", small.bytes.len());
        assert!(small.more && small.len < SONGS && small.len > 0);
        assert_eq!(small.limit, small.len);
        // The page is a valid message.
        assert!(matches!(
            Msg::parse(&small.bytes).unwrap(),
            Msg::SyncBatch { .. }
        ));
    });
}

#[test]
fn messages_are_a_closed_list() {
    let ok = br#"{"type":"remote","id":1,"cmd":{"kind":"seek","seconds":3.5}}"#;
    assert_eq!(
        Msg::parse(ok).unwrap(),
        Msg::Remote {
            id: 1,
            cmd: RemoteCmd::Seek { seconds: 3.5 }
        }
    );
    let page = br#"{"type":"remote","id":2,"cmd":{"kind":"playIndex","index":3,"queueVersion":7}}"#;
    assert!(Msg::parse(page).is_ok());
    for bad in [
        // Unknown type, unknown field, unknown command, extra command field.
        &br#"{"type":"shell","cmd":"rm"}"#[..],
        br#"{"type":"ping","x":1}"#,
        br#"{"type":"remote","id":1,"cmd":{"kind":"openFile","path":"/etc"}}"#,
        br#"{"type":"remote","id":1,"cmd":{"kind":"next","path":"/etc"}}"#,
        // Out of range.
        br#"{"type":"remote","id":1,"cmd":{"kind":"queuePage","offset":0,"limit":101}}"#,
        br#"{"type":"remote","id":1,"cmd":{"kind":"seek","seconds":-1}}"#,
        br#"{"type":"remote","id":1,"cmd":{"kind":"setVolume","percent":101}}"#,
        br#"{"type":"hello","syncVersion":1,"appVersion":"1","deviceName":"bad\nname"}"#,
    ] {
        assert!(
            Msg::parse(bad).is_err(),
            "accepted {}",
            String::from_utf8_lossy(bad)
        );
    }
    let json = String::from_utf8(Msg::SyncAck { upto_seq: 5 }.to_bytes()).unwrap();
    assert_eq!(json, r#"{"type":"syncAck","uptoSeq":5}"#);
    let err = String::from_utf8(Msg::error(ErrorCode::MassDelete, "x").to_bytes()).unwrap();
    assert!(err.contains(r#""code":"mass_delete""#), "{err}");
}

#[test]
fn the_phone_pairs_from_the_qr_code() {
    rt(async {
        let pc = device("Desk PC", true).await;
        let phone = device("Pixel", false).await;
        let port = pc
            .svc
            .set_allow_phone_connections(true)
            .await
            .unwrap()
            .listening
            .unwrap()
            .port;
        let open = pc.svc.pair_open().await.unwrap();
        let qr = open.qr.as_ref().expect("a QR code with the pairing code");
        assert!(qr.link.contains(&format!("c={}", open.code)));
        assert_eq!(qr.modules.len(), qr.size * qr.size);

        // The first address in the code does not answer (another adapter);
        // the phone moves on to the next one.
        // Port 1 has no listener here: the connection is refused at once.
        let closed: std::net::SocketAddr = "127.0.0.1:1".parse().unwrap();
        let good: std::net::SocketAddr = format!("127.0.0.1:{port}").parse().unwrap();
        let link = crate::sync::pair_link::build_link(&open.code, &[closed, good]);
        phone.svc.connect_pair_link(&link).await.unwrap();
        let pc_id = pc.id().await;
        wait_for!("the first sync", phone.rounds(&pc_id).await >= 1);

        // Something else in front of the camera is refused at once.
        assert!(
            phone
                .svc
                .connect_pair_link("https://example.com")
                .await
                .is_err()
        );
        phone.svc.shutdown().await;
        pc.svc.shutdown().await;
    });
}

/// Titles of the favourites of one profile on a device.
fn profile_favorites(dev: &Dev, profile: ProfileId) -> BTreeSet<String> {
    let conn = dev.lib.conn();
    let mut st = conn
        .prepare(
            "SELECT t.title FROM favorites f JOIN tracks t ON t.id = f.track_id
             WHERE f.profile_id = ?1",
        )
        .unwrap();
    st.query_map([profile.0], |r| r.get(0))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap()
}

fn favorite_in(dev: &Dev, profile: ProfileId, songs: &[usize]) {
    let ids: Vec<i64> = songs.iter().map(|&i| dev.id_of(i)).collect();
    db::set_favorites(&mut dev.lib.conn(), profile, &ids, true, 1_700_000_000).unwrap();
}

/// Pairs `phone` with `pc` while `profile` is the computer's active one.
async fn pair_with_profile(pc: &Dev, phone: &Dev, port: u16, profile: ProfileId) {
    pc.lib.set_active_profile(profile).unwrap();
    let open = pc.svc.pair_open().await.unwrap();
    assert_eq!(
        open.profile_name,
        pc.lib
            .profiles()
            .unwrap()
            .into_iter()
            .find(|p| p.id == profile)
            .unwrap()
            .name
    );
    phone
        .svc
        .connect_pair(&format!("127.0.0.1:{port}"), &open.code)
        .await
        .unwrap();
    let pc_id = pc.id().await;
    wait_for!("the first sync", phone.rounds(&pc_id).await >= 1);
    pc.svc.pair_close();
}

#[test]
fn two_phones_sync_two_different_computer_profiles() {
    rt(async {
        let pc = device("Desk PC", true).await;
        let (one, two) = (device("Pixel", false).await, device("Galaxy", false).await);
        let second = pc.lib.create_profile("Second").unwrap().id;
        let first = ProfileId::FIRST;
        favorite_in(&pc, first, &[0, 1]);
        favorite_in(&pc, second, &[5]);
        favorite_in(&one, first, &[2]);
        favorite_in(&two, first, &[6]);
        let port = pc
            .svc
            .set_allow_phone_connections(true)
            .await
            .unwrap()
            .listening
            .unwrap()
            .port;
        pair_with_profile(&pc, &one, port, first).await;
        pair_with_profile(&pc, &two, port, second).await;
        let (one_id, two_id) = (one.id().await, two.id().await);

        // Each phone sees only its profile's favourites.
        assert_eq!(one.favorites(), title_set(&[0, 1, 2]));
        assert_eq!(two.favorites(), title_set(&[5, 6]));
        assert_eq!(profile_favorites(&pc, first), title_set(&[0, 1, 2]));
        assert_eq!(profile_favorites(&pc, second), title_set(&[5, 6]));

        // The binding is shown by name.
        let names: BTreeMap<String, String> = pc
            .svc
            .status()
            .await
            .unwrap()
            .peers
            .into_iter()
            .map(|p| (p.id, p.profile_name))
            .collect();
        assert_eq!(names[&two_id], "Second");
        assert_ne!(names[&one_id], "Second");

        // Later edits stay in their own profile.
        favorite_in(&one, first, &[3]);
        let before = one.rounds(&pc.id().await).await;
        one.svc.sync_now().await.unwrap();
        wait_for!("a round", one.rounds(&pc.id().await).await > before);
        assert_eq!(profile_favorites(&pc, first), title_set(&[0, 1, 2, 3]));
        assert_eq!(profile_favorites(&pc, second), title_set(&[5, 6]));
        assert_eq!(two.favorites(), title_set(&[5, 6]));

        // Deleting the bound profile drops its pairing and closes the session.
        pc.lib.set_active_profile(first).unwrap();
        pc.lib.delete_profile(second).unwrap();
        pc.svc.profile_deleted(second).await.unwrap();
        assert!(pc.peer(&two_id).await.is_none());
        assert!(pc.peer(&one_id).await.is_some());
        wait_for!(
            "the phone to be dropped",
            !two.connected(&pc.id().await).await
        );
        pc.svc.shutdown().await;
        one.svc.shutdown().await;
        two.svc.shutdown().await;
    });
}

//! End-to-end tests of the local Jam (docs/JAM.md) over loopback TCP: a
//! computer hosting, a phone (or a hand-made guest) joining. A silent
//! engine plays; no sound card, no network beyond 127.0.0.1.

use super::jam::host::{GuestLimits, JamLimits};
use super::jam::{JamCmd, JamErrorCode, JamMsg, guest_name};
use super::link::{self, LinkError, LocalDevice, Paired, Session};
use super::protocol::Msg;
use super::remote::RemoteCmd;
use super::service_tests::{Dev, device, path, rt, title};
use super::store;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

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

fn addr(port: u16) -> SocketAddr {
    SocketAddr::from(([127, 0, 0, 1], port))
}

/// A computer with the Jam switch on and a Jam running: (device, port, code).
async fn host() -> (Dev, u16, String) {
    let pc = device("Desk PC", true).await;
    pc.svc.jam_set_enabled(true).await.unwrap();
    let st = pc.svc.jam_start().await.unwrap();
    assert!(st.enabled && st.running);
    let port = pc.svc.sh.listening_port().expect("the Jam listens");
    (pc, port, st.code.expect("a Jam code"))
}

async fn phone_guest() -> Dev {
    let phone = device("Pixel", false).await;
    assert!(phone.svc.jam_guest_set_enabled(true).enabled);
    phone
}

fn queue(dev: &Dev) -> Vec<String> {
    dev.player
        .queue_page(0, 1000)
        .into_iter()
        .map(|t| t.path)
        .collect()
}

fn play(dev: &Dev, songs: &[usize]) {
    let paths: Vec<PathBuf> = songs.iter().map(|&i| PathBuf::from(path(i))).collect();
    dev.player.replace_queue(paths, 0).unwrap();
}

fn active_connections(dev: &Dev) -> usize {
    let mut n = 0;
    dev.svc.with_server(|h| n = h.active_connections());
    n
}

fn session_limit(dev: &Dev) -> usize {
    let mut n = 0;
    dev.svc.with_server(|h| n = h.session_limit());
    n
}

fn no_peer_rows(dev: &Dev) -> bool {
    store::peers(&dev.lib.conn()).unwrap().is_empty()
}

static NEXT_GUEST: AtomicU32 = AtomicU32::new(1);

/// A hand-made guest with a fresh id.
fn raw_guest() -> LocalDevice {
    LocalDevice {
        id: format!("jam-{:032x}", NEXT_GUEST.fetch_add(1, Ordering::SeqCst)),
        name: "Tester".into(),
    }
}

/// Joins at the link level. Retries while the host still finishes an
/// earlier connection from this address (2 per address) or exchange.
async fn raw_join(port: u16, local: &LocalDevice, code: &str) -> link::LinkResult<Paired> {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        match link::jam_join(addr(port), local, code).await {
            Err(LinkError::Closed | LinkError::Io(_) | LinkError::PairingBusy)
                if Instant::now() < deadline =>
            {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            other => return other,
        }
    }
}

/// Opens a guest session once the host has no other connection open (so
/// the per-address limit cannot refuse it).
async fn raw_session(dev: &Dev, port: u16, id: &str, key: &[u8; 32]) -> link::LinkResult<Session> {
    wait_for!("earlier connections to end", active_connections(dev) == 0);
    link::connect(addr(port), id, key).await
}

async fn next_msg(s: &mut Session) -> Result<JamMsg, String> {
    let bytes = tokio::time::timeout(Duration::from_secs(10), s.recv())
        .await
        .map_err(|_| "no message".to_owned())?
        .map_err(|e| e.to_string())?;
    JamMsg::parse(&bytes)
}

/// Reads until the host closes the connection; returns the last message.
async fn until_closed(s: &mut Session) -> Option<JamMsg> {
    let mut last = None;
    while let Ok(m) = next_msg(s).await {
        last = Some(m);
    }
    last
}

fn last_state(dev: &Dev) -> Option<serde_json::Value> {
    dev.events
        .named("jam://state")
        .into_iter()
        .rev()
        .find(|v| !v.is_null())
}

#[test]
fn a_guest_searches_and_adds_to_the_end_of_the_host_queue() {
    rt(async {
        let (pc, port, code) = host().await;
        play(&pc, &[0, 1]);
        let phone = phone_guest().await;
        let st = phone
            .svc
            .jam_join(Some(&format!("127.0.0.1:{port}")), &code)
            .await
            .unwrap();
        assert!(st.joined && !st.connecting && st.error.is_none());
        assert_eq!(st.host_name.as_deref(), Some("Desk PC"));

        // The host pushes what it plays.
        wait_for!("the host's state", last_state(&phone).is_some());
        let state = last_state(&phone).unwrap();
        assert_eq!(state["hostName"], "Desk PC");
        assert_eq!(state["nowPlaying"]["title"], title(0));
        assert_eq!(state["nowPlaying"]["durationMs"], 200_000);
        assert_eq!(state["upNext"][0]["title"], title(1));
        assert!(state["upNext"][0]["addedBy"].is_null());

        // Search: ids, titles and durations only; no path, no cover.
        let page = phone.svc.jam_search("Song 5", 0, 10).await.unwrap();
        let five = page
            .items
            .iter()
            .find(|t| t.title == title(5))
            .expect("song 5 found")
            .clone();
        assert_eq!(five.track_id, pc.id_of(5));
        assert_eq!(five.duration_ms, Some(200_000));
        let json = serde_json::to_string(&page).unwrap();
        assert!(!json.contains("/m/") && !json.contains("cover") && !json.contains("path"));
        assert!(phone.svc.jam_search("x", 0, 31).await.is_err());

        // Add: it lands at the end of the host's queue, exactly once.
        phone.svc.jam_add(five.track_id).await.unwrap();
        assert_eq!(queue(&pc), [path(0), path(1), path(5)]);
        // A second song within 5 s is refused.
        let err = phone.svc.jam_add(pc.id_of(6)).await.unwrap_err();
        assert_eq!(err, JamErrorCode::RateLimited.message());
        assert_eq!(queue(&pc), [path(0), path(1), path(5)]);

        // The host sees who added what, and so do the guests.
        let st = pc.svc.jam_status().await.unwrap();
        assert_eq!(st.guests.len(), 1);
        assert_eq!(
            (st.guests[0].name.as_str(), st.guests[0].added),
            ("Pixel", 1)
        );
        assert!(st.guests[0].connected);
        assert_eq!(st.recent[0].title, title(5));
        assert_eq!(st.recent[0].added_by, "Pixel");
        wait_for!(
            "the guest's name in up next",
            last_state(&phone).is_some_and(|s| s["upNext"][1]["addedBy"] == "Pixel")
        );
        wait_for!(
            "the panel's event",
            pc.events
                .named("jam://status")
                .iter()
                .any(|s| s["recent"][0]["addedBy"] == "Pixel")
        );

        // Guests are never written to either database.
        assert!(no_peer_rows(&pc) && no_peer_rows(&phone));
        phone.svc.jam_leave();
        let st = phone.svc.jam_guest_status();
        assert!(!st.joined && st.host_name.is_none());
        wait_for!(
            "the host to see the guest leave",
            !pc.svc.jam_status().await.unwrap().guests[0].connected
        );
        assert!(no_peer_rows(&pc) && no_peer_rows(&phone));
        phone.svc.shutdown().await;
        pc.svc.shutdown().await;
    });
}

#[test]
fn a_guest_session_takes_only_jam_messages() {
    rt(async {
        let (pc, port, code) = host().await;
        play(&pc, &[0, 1, 2]);
        let g = raw_guest();
        let key = raw_join(port, &g, &code).await.unwrap().secret;
        let mut s = raw_session(&pc, port, &g.id, &key).await.unwrap();
        match next_msg(&mut s).await.unwrap() {
            JamMsg::JamState { id: None, state } => assert_eq!(state.host_name, "Desk PC"),
            other => panic!("expected the state first, got {other:?}"),
        }
        s.send(&JamCmd::JamState { id: 7 }.to_bytes())
            .await
            .unwrap();
        loop {
            if let JamMsg::JamState { id: Some(id), .. } = next_msg(&mut s).await.unwrap() {
                assert_eq!(id, 7);
                break;
            }
        }
        drop(s);

        let before = pc.player.snapshot();
        let bad: Vec<Vec<u8>> = vec![
            Msg::Remote {
                id: 1,
                cmd: RemoteCmd::Next {},
            }
            .to_bytes(),
            Msg::Remote {
                id: 2,
                cmd: RemoteCmd::Pause {},
            }
            .to_bytes(),
            Msg::SyncOffer {}.to_bytes(),
            Msg::Ping {}.to_bytes(),
            br#"{"type":"shell","cmd":"rm"}"#.to_vec(),
            br#"{"type":"jamAdd","id":1,"trackId":3,"path":"/etc/passwd"}"#.to_vec(),
            br#"{"type":"jamSearch","id":1,"query":"x","offset":0,"limit":31}"#.to_vec(),
            vec![b' '; 5000],
        ];
        for msg in bad {
            let mut s = raw_session(&pc, port, &g.id, &key).await.unwrap();
            s.send(&msg).await.unwrap();
            // Nothing but state pushes, then the host hangs up.
            if let Some(last) = until_closed(&mut s).await {
                assert!(
                    matches!(last, JamMsg::JamState { id: None, .. }),
                    "{last:?}"
                );
            }
        }
        let after = pc.player.snapshot();
        assert_eq!(
            (after.status, after.current_index, after.queue_version),
            (before.status, before.current_index, before.queue_version)
        );
        assert_eq!(queue(&pc), [path(0), path(1), path(2)]);
        assert!(no_peer_rows(&pc));
        pc.svc.shutdown().await;
    });
}

#[test]
fn with_the_switch_off_jam_joins_and_sessions_are_refused() {
    rt(async {
        let pc = device("Desk PC", true).await;
        let phone = phone_guest().await;
        // Off by default: no Jam can start.
        let st = pc.svc.jam_status().await.unwrap();
        assert!(!st.enabled && !st.running && st.code.is_none());
        assert!(pc.svc.jam_start().await.is_err());
        let port = pc
            .svc
            .set_allow_phone_connections(true)
            .await
            .unwrap()
            .listening
            .unwrap()
            .port;
        let refused = raw_join(port, &raw_guest(), "123456").await;
        assert!(
            matches!(refused, Err(LinkError::PairingNotOpen)),
            "{refused:?}"
        );
        let err = phone
            .svc
            .jam_join(Some(&format!("127.0.0.1:{port}")), "123456")
            .await
            .unwrap_err();
        assert!(err.contains("No Jam"), "{err}");

        // On: a guest joins. Off again: the Jam ends, the key stops working.
        pc.svc.jam_set_enabled(true).await.unwrap();
        let code = pc.svc.jam_start().await.unwrap().code.unwrap();
        let g = raw_guest();
        let key = raw_join(port, &g, &code).await.unwrap().secret;
        let mut s = raw_session(&pc, port, &g.id, &key).await.unwrap();
        assert!(next_msg(&mut s).await.is_ok());
        let st = pc.svc.jam_set_enabled(false).await.unwrap();
        assert!(!st.enabled && !st.running && st.code.is_none() && st.guests.is_empty());
        assert_eq!(
            until_closed(&mut s).await,
            Some(JamMsg::JamEnded { removed: false })
        );
        let again = raw_session(&pc, port, &g.id, &key).await;
        assert!(
            matches!(again, Err(LinkError::HandshakeFailed)),
            "{again:?}"
        );
        let refused = raw_join(port, &raw_guest(), &code).await;
        assert!(
            matches!(refused, Err(LinkError::PairingNotOpen)),
            "{refused:?}"
        );
        // The listener stays for the phones.
        assert!(pc.svc.status().await.unwrap().listening.is_some());

        // The guest's own switch: off refuses joining.
        pc.svc.jam_set_enabled(true).await.unwrap();
        let code = pc.svc.jam_start().await.unwrap().code.unwrap();
        phone.svc.jam_guest_set_enabled(false);
        let err = phone
            .svc
            .jam_join(Some(&format!("127.0.0.1:{port}")), &code)
            .await
            .unwrap_err();
        assert!(err.contains("turn on Jam"), "{err}");
        // A phone does not host, a computer does not join.
        assert!(phone.svc.jam_set_enabled(true).await.is_err());
        pc.svc.jam_guest_set_enabled(true);
        assert!(pc.svc.jam_join(Some("127.0.0.1"), &code).await.is_err());
        phone.svc.shutdown().await;
        pc.svc.shutdown().await;
    });
}

#[test]
fn removing_a_guest_or_ending_the_jam_closes_the_session_and_drops_the_key() {
    rt(async {
        // Phone connections are off: the listener runs for the Jam only.
        let (pc, port, code) = host().await;
        assert!(pc.svc.status().await.unwrap().listening.is_none());
        assert_eq!(
            session_limit(&pc),
            link::MAX_SESSIONS + link::MAX_JAM_GUESTS
        );
        let phone = phone_guest().await;
        phone
            .svc
            .jam_join(Some(&format!("127.0.0.1:{port}")), &code)
            .await
            .unwrap();
        wait_for!(
            "the guest's session",
            pc.svc
                .jam_status()
                .await
                .unwrap()
                .guests
                .first()
                .is_some_and(|g| g.connected)
        );
        let id = pc.svc.jam_status().await.unwrap().guests[0].id.clone();
        let st = pc.svc.jam_remove_guest(&id).await.unwrap();
        assert!(st.guests.is_empty());
        assert!(pc.svc.jam_host().key(&id).is_none());
        wait_for!("the phone to be told", {
            let st = phone.svc.jam_guest_status();
            !st.joined && st.error.as_deref() == Some("The host removed you from the Jam")
        });
        assert!(
            phone
                .events
                .named("jam://guest")
                .iter()
                .any(|s| s["error"] == "The host removed you from the Jam")
        );

        // A hand-made guest: ending the Jam closes it and its key is gone.
        let g = raw_guest();
        let key = raw_join(port, &g, &code).await.unwrap().secret;
        let mut s = raw_session(&pc, port, &g.id, &key).await.unwrap();
        assert!(next_msg(&mut s).await.is_ok());
        let st = pc.svc.jam_end().await.unwrap();
        assert!(st.enabled && !st.running && st.guests.is_empty() && st.code.is_none());
        assert_eq!(
            until_closed(&mut s).await,
            Some(JamMsg::JamEnded { removed: false })
        );
        // The listener ran for the Jam alone: it is closed.
        wait_for!("the listener to close", !pc.svc.server_running());
        assert!(
            link::dial(addr(port), Duration::from_secs(2))
                .await
                .is_err()
        );
        assert!(pc.svc.jam_host().key(&g.id).is_none());

        // With phone connections on, the listener outlives the Jam, and its
        // session limit goes back to the phones' own.
        let port = pc
            .svc
            .set_allow_phone_connections(true)
            .await
            .unwrap()
            .listening
            .unwrap()
            .port;
        assert_eq!(session_limit(&pc), link::MAX_SESSIONS);
        let code = pc.svc.jam_start().await.unwrap().code.unwrap();
        assert_eq!(
            session_limit(&pc),
            link::MAX_SESSIONS + link::MAX_JAM_GUESTS
        );
        let g = raw_guest();
        let key = raw_join(port, &g, &code).await.unwrap().secret;
        pc.svc.jam_end().await.unwrap();
        assert!(pc.svc.server_running());
        assert_eq!(session_limit(&pc), link::MAX_SESSIONS);
        let again = raw_session(&pc, port, &g.id, &key).await;
        assert!(
            matches!(again, Err(LinkError::HandshakeFailed)),
            "{again:?}"
        );
        assert!(no_peer_rows(&pc) && no_peer_rows(&phone));
        phone.svc.shutdown().await;
        pc.svc.shutdown().await;
    });
}

#[test]
fn adds_are_rate_limited_and_guests_fill_at_most_part_of_the_queue() {
    rt(async {
        let (pc, port, code) = host().await;
        play(&pc, &[0]);
        let limits = JamLimits {
            add_every: Duration::ZERO,
            adds_per_window: 3,
            add_window: Duration::from_secs(600),
            guest_songs_ahead: 2,
            search_every: Duration::from_secs(3600),
        };
        pc.svc.jam_host().set_limits(limits);
        let phone = phone_guest().await;
        phone
            .svc
            .jam_join(Some(&format!("127.0.0.1:{port}")), &code)
            .await
            .unwrap();
        let add = |i: i64| phone.svc.jam_add(i);
        assert_eq!(
            add(999_999).await.unwrap_err(),
            JamErrorCode::NotFound.message()
        );
        add(pc.id_of(1)).await.unwrap();
        add(pc.id_of(2)).await.unwrap();
        // Two guest songs wait already: the queue is full for guests.
        assert_eq!(
            add(pc.id_of(3)).await.unwrap_err(),
            JamErrorCode::QueueFull.message()
        );
        pc.svc.jam_host().set_limits(JamLimits {
            guest_songs_ahead: 50,
            ..limits
        });
        add(pc.id_of(3)).await.unwrap();
        // Three adds per window.
        assert_eq!(
            add(pc.id_of(4)).await.unwrap_err(),
            JamErrorCode::RateLimited.message()
        );
        assert_eq!(queue(&pc), [path(0), path(1), path(2), path(3)]);
        assert_eq!(pc.svc.jam_status().await.unwrap().guests[0].added, 3);

        // One search per interval.
        assert!(phone.svc.jam_search("Song", 0, 5).await.is_ok());
        assert_eq!(
            phone.svc.jam_search("Song", 0, 5).await.unwrap_err(),
            JamErrorCode::RateLimited.message()
        );
        phone.svc.shutdown().await;
        pc.svc.shutdown().await;
    });
}

#[test]
fn guest_limits_follow_the_spec() {
    let l = JamLimits::default();
    let t0 = Instant::now();
    let at = |ms: u64| t0 + Duration::from_millis(ms);
    let mut g = GuestLimits::default();
    // One add per 5 s.
    assert!(g.allow_add(at(0), &l));
    g.record_add(at(0));
    assert!(!g.allow_add(at(4_999), &l));
    assert!(g.allow_add(at(5_000), &l));
    // 20 per 10 minutes.
    for i in 1..20 {
        g.record_add(at(i * 5_000));
    }
    assert!(!g.allow_add(at(20 * 5_000), &l));
    assert!(!g.allow_add(at(599_999), &l));
    assert!(g.allow_add(at(600_000), &l));
    // One search per 300 ms.
    assert!(g.try_search(at(0), &l));
    assert!(!g.try_search(at(299), &l));
    assert!(g.try_search(at(300), &l));
}

#[test]
fn ten_wrong_codes_replace_the_jam_code() {
    rt(async {
        let (pc, port, code) = host().await;
        let wrong = format!("{:06}", (code.parse::<u32>().unwrap() + 1) % 1_000_000);
        for i in 1..=link::JAM_MAX_WRONG {
            let r = raw_join(port, &raw_guest(), &wrong).await;
            if i < link::JAM_MAX_WRONG {
                assert!(matches!(r, Err(LinkError::WrongCode)), "{i}: {r:?}");
            } else {
                assert!(matches!(r, Err(LinkError::TooManyAttempts)), "{r:?}");
            }
        }
        let new = pc.svc.jam_status().await.unwrap().code.unwrap();
        assert_ne!(new, code);
        wait_for!(
            "the new code on the panel",
            pc.events
                .named("jam://status")
                .iter()
                .any(|s| s["code"] == new.as_str())
        );
        assert!(raw_join(port, &raw_guest(), &code).await.is_err());
        assert!(raw_join(port, &raw_guest(), &new).await.is_ok());
        // A new code on request; the old one stops working.
        let newer = pc.svc.jam_new_code().await.unwrap().code.unwrap();
        if newer != new {
            assert!(raw_join(port, &raw_guest(), &new).await.is_err());
        }
        assert!(raw_join(port, &raw_guest(), &newer).await.is_ok());
        pc.svc.shutdown().await;
    });
}

#[test]
fn a_jam_has_at_most_eight_guests() {
    rt(async {
        let (pc, port, code) = host().await;
        for _ in 0..link::MAX_JAM_GUESTS {
            raw_join(port, &raw_guest(), &code).await.unwrap();
        }
        let full = raw_join(port, &raw_guest(), &code).await;
        assert!(matches!(full, Err(LinkError::JamFull)), "{full:?}");
        let st = pc.svc.jam_status().await.unwrap();
        assert_eq!(st.guests.len(), link::MAX_JAM_GUESTS);
        pc.svc.jam_remove_guest(&st.guests[0].id).await.unwrap();
        assert!(raw_join(port, &raw_guest(), &code).await.is_ok());
        assert!(no_peer_rows(&pc));
        pc.svc.shutdown().await;
    });
}

#[test]
fn jam_joins_stay_on_the_local_network() {
    rt(async {
        let phone = phone_guest().await;
        assert!(phone.svc.jam_join(Some("8.8.8.8"), "123456").await.is_err());
        assert!(
            phone
                .svc
                .jam_join(Some("100.64.0.1:47321"), "123456")
                .await
                .is_err()
        );
        assert!(
            phone
                .svc
                .jam_join_link("neomodern://jam?v=1&c=123456&a=8.8.8.8:47321")
                .await
                .is_err()
        );
        // A pairing QR is not a Jam QR.
        assert!(
            phone
                .svc
                .jam_join_link("neomodern://pair?v=1&c=123456&a=192.168.1.2:47321")
                .await
                .is_err()
        );
        let public: SocketAddr = "8.8.8.8:47321".parse().unwrap();
        let r = link::jam_join(public, &raw_guest(), "123456").await;
        assert!(matches!(r, Err(LinkError::NotLocalAddress)), "{r:?}");
        phone.svc.shutdown().await;
    });
}

#[test]
fn jam_messages_are_a_closed_list() {
    let ok = br#"{"type":"jamAdd","id":1,"trackId":5}"#;
    assert_eq!(
        JamCmd::parse(ok).unwrap(),
        JamCmd::JamAdd { id: 1, track_id: 5 }
    );
    assert!(JamCmd::parse(br#"{"type":"jamState","id":2}"#).is_ok());
    assert!(
        JamCmd::parse(br#"{"type":"jamSearch","id":3,"query":"abba","offset":0,"limit":30}"#)
            .is_ok()
    );
    let long = format!(
        r#"{{"type":"jamSearch","id":3,"query":"{}","offset":0,"limit":5}}"#,
        "a".repeat(101)
    );
    for bad in [
        &br#"{"type":"remote","id":1,"cmd":{"kind":"next"}}"#[..],
        br#"{"type":"syncOffer"}"#,
        br#"{"type":"jamState","id":1,"x":1}"#,
        br#"{"type":"jamAdd","id":1,"trackId":0}"#,
        br#"{"type":"jamAdd","id":1,"trackId":5,"path":"/etc"}"#,
        br#"{"type":"jamSearch","id":1,"query":"a","offset":0,"limit":0}"#,
        br#"{"type":"jamSearch","id":1,"query":"a\n","offset":0,"limit":5}"#,
        br#"{"type":"jamPlay","id":1}"#,
        long.as_bytes(),
    ] {
        assert!(
            JamCmd::parse(bad).is_err(),
            "accepted {}",
            String::from_utf8_lossy(bad)
        );
    }
    let done = JamMsg::JamDone {
        id: 4,
        error: Some(super::jam::JamFailure {
            code: JamErrorCode::QueueFull,
        }),
    };
    assert_eq!(
        String::from_utf8(done.to_bytes()).unwrap(),
        r#"{"type":"jamDone","id":4,"error":{"code":"queueFull"}}"#
    );
    // Guest names: trimmed, at most 40 characters, never empty.
    assert_eq!(guest_name("  Pixel · Zeynep  "), "Pixel · Zeynep");
    assert_eq!(guest_name(&"x".repeat(80)).chars().count(), 40);
    assert_eq!(guest_name(" \t "), "Guest");
}

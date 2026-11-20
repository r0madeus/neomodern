//! Link tests: everything over in-memory pipes or loopback TCP, no real
//! network, all fast.

use super::pair::test_support::client_opening;
use super::pair::{from_hex, random_code, to_hex};
use super::*;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::Instant;
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream, duplex};

const PC_SECRET: [u8; 32] = [7; 32];
const PHONE_ID: &str = "0f1e2d3c4b5a69788796a5b4c3d2e1f0";

fn pc() -> LocalDevice {
    LocalDevice {
        id: "a1b2c3d4e5f60718293a4b5c6d7e8f90".into(),
        name: "Desk PC".into(),
    }
}

fn phone() -> LocalDevice {
    LocalDevice {
        id: PHONE_ID.into(),
        name: "Pixel 8".into(),
    }
}

fn pipe() -> (DuplexStream, DuplexStream) {
    duplex(256 * 1024)
}

fn known_phone(id: &str) -> Option<[u8; 32]> {
    (id == phone().id).then_some(PC_SECRET)
}

type Lookup = fn(&str) -> Option<[u8; 32]>;

fn responder(window: Arc<PairingWindow>) -> Responder<Lookup> {
    Responder::new(pc(), window, known_phone as Lookup)
}

fn other_code(code: &str) -> String {
    let n: u32 = code.parse().unwrap();
    format!("{:06}", (n + 1) % 1_000_000)
}

/// Runs one pairing exchange; returns (client result, server result).
async fn run_pairing(
    window: &Arc<PairingWindow>,
    code: &str,
) -> (LinkResult<Paired>, LinkResult<Accepted>) {
    let (mut c, s) = pipe();
    let r = responder(Arc::clone(window));
    let local = phone();
    tokio::join!(pair(&mut c, &local, code), accept(s, &r))
}

async fn session_pair() -> (Session, Session) {
    let (c, s) = pipe();
    let r = responder(Arc::new(PairingWindow::new()));
    let (client, server) = tokio::join!(handshake(c, PHONE_ID, &PC_SECRET), accept(s, &r));
    let Ok(Accepted::Session(server)) = server else {
        panic!("server handshake failed: {server:?}");
    };
    (client.expect("client handshake"), server)
}

// ---------------------------------------------------------------------------
// Framing
// ---------------------------------------------------------------------------

#[tokio::test]
async fn frames_round_trip_and_enforce_limits() {
    let t = Duration::from_secs(1);
    let (mut a, mut b) = pipe();
    write_frame(&mut a, b"hello", 16, t).await.unwrap();
    assert_eq!(read_frame(&mut b, 16, t).await.unwrap(), b"hello");

    // The writer refuses empty and oversized frames.
    assert!(matches!(
        write_frame(&mut a, b"", 16, t).await,
        Err(LinkError::EmptyFrame)
    ));
    assert!(matches!(
        write_frame(&mut a, &[0; 17], 16, t).await,
        Err(LinkError::FrameTooLarge { len: 17, max: 16 })
    ));

    // The reader refuses a zero length...
    a.write_all(&0u32.to_be_bytes()).await.unwrap();
    assert!(matches!(
        read_frame(&mut b, 16, t).await,
        Err(LinkError::EmptyFrame)
    ));
    // ...and a huge announced length right after the header, without
    // waiting for (or allocating) the body.
    let (mut a, mut b) = pipe();
    a.write_all(&u32::MAX.to_be_bytes()).await.unwrap();
    let started = Instant::now();
    assert!(matches!(
        read_frame(&mut b, MAX_MESSAGE, t).await,
        Err(LinkError::FrameTooLarge { .. })
    ));
    assert!(started.elapsed() < Duration::from_millis(500));

    // A frame that starts but never finishes times out.
    let (mut a, mut b) = pipe();
    a.write_all(&[0, 0]).await.unwrap();
    assert!(matches!(
        read_frame(&mut b, 16, Duration::from_millis(50)).await,
        Err(LinkError::Timeout)
    ));
    // A peer hanging up between frames is "closed".
    let (a, mut b) = pipe();
    drop(a);
    assert!(matches!(
        read_frame(&mut b, 16, t).await,
        Err(LinkError::Closed)
    ));
}

// ---------------------------------------------------------------------------
// Pairing
// ---------------------------------------------------------------------------

#[test]
fn codes_are_six_random_digits_and_hex_round_trips() {
    let codes: Vec<String> = (0..20).map(|_| random_code().unwrap()).collect();
    for c in &codes {
        assert_eq!(c.len(), 6);
        assert!(c.bytes().all(|b| b.is_ascii_digit()));
    }
    // 20 draws from a million: a repeat would mean a broken RNG.
    let mut unique = codes.clone();
    unique.sort();
    unique.dedup();
    assert!(unique.len() >= 19);

    let bytes = [0u8, 1, 0x7f, 0x80, 0xff];
    assert_eq!(to_hex(&bytes), "00017f80ff");
    assert_eq!(from_hex("00017F80ff").unwrap(), bytes);
    assert!(from_hex("abc").is_none());
    assert!(from_hex("zz").is_none());
}

#[tokio::test]
async fn pairing_gives_both_sides_the_same_secret() {
    let window = Arc::new(PairingWindow::new());
    let code = window.open().unwrap();
    assert!(matches!(window.status(), PairingStatus::Open { .. }));

    let (client, server) = run_pairing(&window, &code).await;
    let client = client.expect("client pairs");
    let Ok(Accepted::Paired(server)) = server else {
        panic!("server did not pair: {server:?}");
    };
    assert_eq!(client.peer_id, pc().id);
    assert_eq!(client.peer_name, "Desk PC");
    assert_eq!(server.peer_id, phone().id);
    assert_eq!(server.peer_name, "Pixel 8");
    assert_eq!(client.secret, server.secret);
    assert_ne!(client.secret, [0; 32]);

    // The code is single-use.
    assert_eq!(window.status(), PairingStatus::Closed);
    let (client, _) = run_pairing(&window, &code).await;
    assert!(matches!(client, Err(LinkError::PairingNotOpen)));

    // A second pairing with a new code gives a different secret (fresh
    // SPAKE2 randomness), so re-pairing replaces the old key.
    let code = window.open().unwrap();
    let (again, _) = run_pairing(&window, &code).await;
    assert_ne!(again.unwrap().secret, server.secret);
}

#[tokio::test]
async fn wrong_codes_are_counted_and_the_third_invalidates_the_code() {
    let window = Arc::new(PairingWindow::new());
    let code = window.open().unwrap();
    let wrong = other_code(&code);

    for _ in 0..2 {
        let (client, server) = run_pairing(&window, &wrong).await;
        assert!(matches!(client, Err(LinkError::WrongCode)), "{client:?}");
        assert!(matches!(server, Err(LinkError::WrongCode)), "{server:?}");
        // Still open: two wrong attempts are allowed.
        assert!(matches!(window.status(), PairingStatus::Open { .. }));
    }
    let (client, server) = run_pairing(&window, &wrong).await;
    assert!(
        matches!(client, Err(LinkError::TooManyAttempts)),
        "{client:?}"
    );
    assert!(matches!(server, Err(LinkError::TooManyAttempts)));
    assert_eq!(window.status(), PairingStatus::TooManyAttempts);

    // Even the right code no longer works.
    let (client, _) = run_pairing(&window, &code).await;
    assert!(matches!(client, Err(LinkError::TooManyAttempts)));

    // A fresh code works again.
    let code = window.open().unwrap();
    let (client, _) = run_pairing(&window, &code).await;
    assert!(client.is_ok());
}

#[tokio::test]
async fn expired_codes_are_refused() {
    let window = Arc::new(PairingWindow::with_ttl(Duration::from_millis(40)));
    let code = window.open().unwrap();
    tokio::time::sleep(Duration::from_millis(80)).await;
    assert_eq!(window.status(), PairingStatus::Expired);
    let (client, server) = run_pairing(&window, &code).await;
    assert!(
        matches!(client, Err(LinkError::PairingExpired)),
        "{client:?}"
    );
    assert!(matches!(server, Err(LinkError::PairingExpired)));
}

#[tokio::test]
async fn a_second_pairing_is_refused_while_one_is_in_progress() {
    let window = Arc::new(PairingWindow::new());
    let code = window.open().unwrap();
    let r = Arc::new(responder(Arc::clone(&window)));

    // A slow client: sends its request, reads the reply, then stalls.
    let (mut slow, slow_server) = pipe();
    let r1 = Arc::clone(&r);
    let first = tokio::spawn(async move { accept(slow_server, &r1).await.map(|_| ()) });
    write_frame(
        &mut slow,
        &client_opening(&phone(), &code),
        4096,
        Duration::from_secs(1),
    )
    .await
    .unwrap();
    let reply = read_frame(&mut slow, 4096, Duration::from_secs(1))
        .await
        .unwrap();
    assert!(reply.starts_with(b"{\"reply\""));

    // Meanwhile another device tries the right code: busy.
    let (client, server) = run_pairing(&window, &code).await;
    assert!(matches!(client, Err(LinkError::PairingBusy)), "{client:?}");
    assert!(matches!(server, Err(LinkError::PairingBusy)));

    // The slow client gives up without a proof: slot freed, not counted.
    drop(slow);
    assert!(matches!(first.await.unwrap(), Err(LinkError::Closed)));
    let (client, _) = run_pairing(&window, &code).await;
    assert!(client.is_ok(), "{client:?}");
}

#[tokio::test]
async fn closing_the_window_stops_pairing() {
    let window = Arc::new(PairingWindow::new());
    let code = window.open().unwrap();
    window.close();
    let (client, _) = run_pairing(&window, &code).await;
    assert!(matches!(client, Err(LinkError::PairingNotOpen)));
    // Malformed codes never reach the network.
    let (mut c, _s) = pipe();
    assert!(matches!(
        pair(&mut c, &phone(), "12a456").await,
        Err(LinkError::InvalidCode)
    ));
}

#[test]
fn debug_output_never_shows_secrets_or_codes() {
    let p = Paired {
        peer_id: "x".into(),
        peer_name: "y".into(),
        secret: [0xab; 32],
    };
    let s = format!("{p:?}");
    assert!(!s.contains("171") && !s.contains("ab, ") && s.contains("redacted"));
    let window = PairingWindow::new();
    let code = window.open().unwrap();
    assert!(!format!("{:?}", window.status()).contains(&code));
    assert!(!format!("{window:?}").contains(&code));
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

#[tokio::test]
async fn sessions_work_both_ways_and_know_the_peer() {
    let (mut client, mut server) = session_pair().await;
    assert_eq!(client.peer_id(), pc().id);
    assert_eq!(server.peer_id(), phone().id);

    client.send(b"ping").await.unwrap();
    assert_eq!(server.recv().await.unwrap(), b"ping");
    server.send(b"pong").await.unwrap();
    assert_eq!(client.recv().await.unwrap(), b"pong");
    client.send(b"").await.unwrap();
    assert_eq!(server.recv().await.unwrap(), b"");

    // Split halves: one task writes while another reads.
    let (mut sr, mut sw) = server.into_split();
    let (mut cr, mut cw) = client.into_split();
    let writer = tokio::spawn(async move {
        for i in 0..50u32 {
            cw.send(&i.to_be_bytes()).await.unwrap();
        }
    });
    let echo = tokio::spawn(async move {
        for _ in 0..50 {
            let m = sr.recv().await.unwrap();
            sw.send(&m).await.unwrap();
        }
    });
    for i in 0..50u32 {
        assert_eq!(cr.recv().await.unwrap(), i.to_be_bytes());
    }
    writer.await.unwrap();
    echo.await.unwrap();
}

#[tokio::test]
async fn large_messages_are_chunked_and_reassembled() {
    let (mut client, mut server) = session_pair().await;
    let big: Vec<u8> = (0..900 * 1024).map(|i| (i * 31 % 251) as u8).collect();
    let max: Vec<u8> = vec![0x5a; MAX_MESSAGE];
    let (sent, got) = tokio::join!(
        async {
            client.send(&big).await.unwrap();
            client.send(&max).await.unwrap();
        },
        async { (server.recv().await.unwrap(), server.recv().await.unwrap()) }
    );
    let () = sent;
    assert_eq!(got.0, big);
    assert_eq!(got.1.len(), MAX_MESSAGE);

    assert!(matches!(
        client.send(&vec![0; MAX_MESSAGE + 1]).await,
        Err(LinkError::MessageTooLarge { .. })
    ));
}

#[tokio::test]
async fn the_reader_rejects_oversized_or_disordered_chunks() {
    let (client, server) = session_pair().await;
    let (_cr, mut cw) = client.into_split();
    let (mut sr, _sw) = server.into_split();
    cw.send_chunk_for_test(2 * MAX_MESSAGE as u32, 0, b"x")
        .await
        .unwrap();
    assert!(matches!(
        sr.recv().await,
        Err(LinkError::MessageTooLarge { .. })
    ));

    let (client, server) = session_pair().await;
    let (_cr, mut cw) = client.into_split();
    let (mut sr, _sw) = server.into_split();
    cw.send_chunk_for_test(10, 0, b"abc").await.unwrap();
    cw.send_chunk_for_test(10, 2, b"def").await.unwrap();
    assert!(matches!(sr.recv().await, Err(LinkError::Protocol(_))));
}

#[tokio::test]
async fn a_wrong_psk_fails_the_handshake_on_both_sides() {
    let (c, s) = pipe();
    let r = responder(Arc::new(PairingWindow::new()));
    let (client, server) = tokio::join!(handshake(c, PHONE_ID, &[8; 32]), accept(s, &r));
    assert!(
        matches!(client, Err(LinkError::HandshakeFailed)),
        "{client:?}"
    );
    assert!(
        matches!(server, Err(LinkError::HandshakeFailed)),
        "{server:?}"
    );
}

#[tokio::test]
async fn unknown_devices_are_closed_without_a_reply() {
    let (mut c, s) = pipe();
    let r = responder(Arc::new(PairingWindow::new()));
    let stranger = "ffffffffffffffffffffffffffffffff";
    let mut hello = b"NMLINK".to_vec();
    hello.extend_from_slice(&PROTOCOL_VERSION.to_be_bytes());
    hello.push(1);
    hello.extend_from_slice(stranger.as_bytes());
    let t = Duration::from_secs(1);
    write_frame(&mut c, &hello, 4096, t).await.unwrap();
    assert!(matches!(accept(s, &r).await, Err(LinkError::UnknownDevice)));
    // Nothing was written back: the pipe is simply closed.
    let mut rest = Vec::new();
    c.read_to_end(&mut rest).await.unwrap();
    assert!(rest.is_empty());

    // And through the client API it is just a failed handshake.
    let (c, s) = pipe();
    let (client, server) = tokio::join!(handshake(c, stranger, &PC_SECRET), accept(s, &r));
    assert!(matches!(client, Err(LinkError::HandshakeFailed)));
    assert!(matches!(server, Err(LinkError::UnknownDevice)));
}

#[tokio::test]
async fn tampered_ciphertext_is_detected() {
    // client <-> relay <-> server; the relay flips one bit in the first
    // frame after the handshake (frames: opening, noise msg 1, data).
    let (c, mut relay_c) = pipe();
    let (mut relay_s, s) = pipe();
    let relay = tokio::spawn(async move {
        let t = Duration::from_secs(2);
        for n in 0..3 {
            let mut f = read_frame(&mut relay_c, 70_000, t).await.unwrap();
            if n == 2 {
                let last = f.len() - 1;
                f[last] ^= 1;
            }
            write_frame(&mut relay_s, &f, 70_000, t).await.unwrap();
            if n == 1 {
                // Pass the server's handshake reply back.
                let f = read_frame(&mut relay_s, 70_000, t).await.unwrap();
                write_frame(&mut relay_c, &f, 70_000, t).await.unwrap();
            }
        }
        (relay_c, relay_s)
    });
    let r = responder(Arc::new(PairingWindow::new()));
    let (client, server) = tokio::join!(handshake(c, PHONE_ID, &PC_SECRET), accept(s, &r));
    let mut client = client.unwrap();
    let Ok(Accepted::Session(mut server)) = server else {
        panic!("handshake failed");
    };
    client.send(b"play").await.unwrap();
    assert!(matches!(server.recv().await, Err(LinkError::Decrypt)));
    drop(relay.await.unwrap());
}

#[tokio::test]
async fn a_rewritten_hello_breaks_the_handshake() {
    // The opening frame is the Noise prologue: a relay that swaps the
    // device id for another one (even one with the same key) cannot get a
    // session through.
    let lookup = |id: &str| (id == phone().id || id == "other").then_some(PC_SECRET);
    let r = Responder::new(pc(), Arc::new(PairingWindow::new()), lookup);
    let (c, mut relay_c) = pipe();
    let (mut relay_s, s) = pipe();
    let relay = tokio::spawn(async move {
        let t = Duration::from_secs(2);
        let f = read_frame(&mut relay_c, 4096, t).await.unwrap();
        let mut swapped = f[..9].to_vec();
        swapped.extend_from_slice(b"other");
        write_frame(&mut relay_s, &swapped, 4096, t).await.unwrap();
        let f = read_frame(&mut relay_c, 4096, t).await.unwrap();
        write_frame(&mut relay_s, &f, 4096, t).await.unwrap();
        // The server hangs up; so does the relay (both pipes dropped).
        let _ = read_frame(&mut relay_s, 4096, t).await;
    });
    let (client, server) = tokio::join!(handshake(c, PHONE_ID, &PC_SECRET), accept(s, &r));
    assert!(
        matches!(server, Err(LinkError::HandshakeFailed)),
        "{server:?}"
    );
    assert!(
        matches!(client, Err(LinkError::HandshakeFailed)),
        "{client:?}"
    );
    relay.await.unwrap();
}

#[tokio::test]
async fn a_silent_client_hits_the_handshake_timeout() {
    let mut r = responder(Arc::new(PairingWindow::new()));
    r.handshake_timeout = Duration::from_millis(100);
    let started = Instant::now();
    let (_c, s) = pipe();
    assert!(matches!(accept(s, &r).await, Err(LinkError::Timeout)));

    // Opening frame sent, Noise message never comes.
    let (mut c, s) = pipe();
    let mut hello = b"NMLINK".to_vec();
    hello.extend_from_slice(&PROTOCOL_VERSION.to_be_bytes());
    hello.push(1);
    hello.extend_from_slice(phone().id.as_bytes());
    write_frame(&mut c, &hello, 4096, Duration::from_secs(1))
        .await
        .unwrap();
    assert!(matches!(accept(s, &r).await, Err(LinkError::Timeout)));
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[tokio::test]
async fn garbage_and_wrong_versions_are_refused() {
    let r = responder(Arc::new(PairingWindow::new()));
    let t = Duration::from_secs(1);
    let (mut c, s) = pipe();
    write_frame(&mut c, b"GET / HTTP/1.1\r\n", 4096, t)
        .await
        .unwrap();
    assert!(matches!(accept(s, &r).await, Err(LinkError::Protocol(_))));

    let (mut c, s) = pipe();
    let mut hello = b"NMLINK".to_vec();
    hello.extend_from_slice(&99u16.to_be_bytes());
    hello.push(1);
    hello.extend_from_slice(phone().id.as_bytes());
    write_frame(&mut c, &hello, 4096, t).await.unwrap();
    assert!(matches!(
        accept(s, &r).await,
        Err(LinkError::VersionMismatch)
    ));
}

// ---------------------------------------------------------------------------
// Listener, address filter, limits
// ---------------------------------------------------------------------------

#[test]
fn only_local_network_sources_are_accepted() {
    let yes = [
        "10.0.0.1",
        "10.255.255.255",
        "172.16.0.1",
        "172.31.255.254",
        "192.168.1.20",
        "169.254.3.4",
        "127.0.0.1",
        "127.8.9.10",
        "::1",
        "fc00::1",
        "fd12:3456::1",
        "fe80::1",
        "febf::1",
        "::ffff:192.168.1.2",
    ];
    let no = [
        "100.64.0.1",
        "100.127.255.255",
        "172.15.255.255",
        "172.32.0.1",
        "192.169.0.1",
        "8.8.8.8",
        "1.1.1.1",
        "0.0.0.0",
        "255.255.255.255",
        "224.0.0.1",
        "::",
        "2001:db8::1",
        "2a00:1450::1",
        "fec0::1",
        "ff02::1",
        "::ffff:8.8.8.8",
        "::ffff:100.64.0.1",
    ];
    for ip in yes {
        assert!(
            is_lan_address(ip.parse().unwrap()),
            "{ip} should be allowed"
        );
    }
    for ip in no {
        assert!(
            !is_lan_address(ip.parse().unwrap()),
            "{ip} should be refused"
        );
    }
}

#[tokio::test]
async fn the_dialer_refuses_internet_addresses() {
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 1);
    assert!(matches!(
        dial(addr, Duration::from_millis(100)).await,
        Err(LinkError::NotLocalAddress)
    ));
    let addr = SocketAddr::new(
        IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1)),
        1,
    );
    assert!(matches!(
        connect(addr, &phone().id, &PC_SECRET).await,
        Err(LinkError::NotLocalAddress)
    ));
}

#[test]
fn lan_addresses_are_private_and_not_loopback() {
    for ip in lan_ipv4_addresses() {
        assert!(is_lan_address(IpAddr::V4(ip)) && !ip.is_loopback(), "{ip}");
    }
}

#[test]
fn the_rate_limiter_allows_20_commands_per_second() {
    let mut r = RateLimiter::remote_commands();
    let t0 = Instant::now();
    assert_eq!((0..25).filter(|_| r.try_acquire_at(t0)).count(), 20);
    // 50 ms later one more token has been earned.
    let t1 = t0 + Duration::from_millis(50);
    assert!(r.try_acquire_at(t1));
    assert!(!r.try_acquire_at(t1));
    // Long idle: refilled to the burst, not beyond.
    let t2 = t1 + Duration::from_secs(10);
    assert_eq!((0..25).filter(|_| r.try_acquire_at(t2)).count(), 20);
    // A clock that goes backwards does not mint tokens.
    assert!(!r.try_acquire_at(t0));
}

async fn wait_until(mut done: impl FnMut() -> bool) {
    for _ in 0..200 {
        if done() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("condition not reached");
}

#[tokio::test]
async fn the_server_caps_sessions_and_stop_closes_everything() {
    let listener = bind(0).await.unwrap();
    let port = listener.port();
    assert!(port > 0);
    let r = Arc::new(responder(Arc::new(PairingWindow::new())));
    let server = listener.serve(MAX_SESSIONS, move |stream, peer, _stop| {
        let r = Arc::clone(&r);
        async move {
            assert!(peer.ip().is_loopback());
            if let Ok(Accepted::Session(mut s)) = accept(stream, &r).await {
                while let Ok(m) = s.recv().await {
                    if s.send(&m).await.is_err() {
                        break;
                    }
                }
            }
        }
    });
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port);

    let mut sessions = Vec::new();
    for i in 0..MAX_SESSIONS {
        let mut s = connect(addr, &phone().id, &PC_SECRET).await.unwrap();
        s.send(&[i as u8]).await.unwrap();
        assert_eq!(s.recv().await.unwrap(), [i as u8]);
        sessions.push(s);
    }
    assert_eq!(server.active_connections(), MAX_SESSIONS);

    // The fifth connection is closed at once.
    let mut extra = dial(addr, Duration::from_secs(1)).await.unwrap();
    let mut buf = [0u8; 1];
    let n = tokio::time::timeout(Duration::from_secs(2), extra.read(&mut buf))
        .await
        .expect("closed promptly")
        .unwrap_or(0);
    assert_eq!(n, 0);

    // A slot frees up when a session ends.
    drop(sessions.pop());
    wait_until(|| server.active_connections() < MAX_SESSIONS).await;
    let mut s = connect(addr, &phone().id, &PC_SECRET).await.unwrap();
    s.send(b"again").await.unwrap();
    assert_eq!(s.recv().await.unwrap(), b"again");
    sessions.push(s);

    // Stop: every session is closed and nothing listens any more.
    server.shutdown().await;
    for mut s in sessions {
        assert!(s.recv().await.is_err());
    }
    let refused = tokio::net::TcpStream::connect(addr).await;
    assert!(refused.is_err());
}

#[tokio::test]
async fn one_address_cannot_take_every_slot() {
    let listener = bind(0).await.unwrap().with_per_address_limit(2);
    let port = listener.port();
    let r = Arc::new(responder(Arc::new(PairingWindow::new())));
    let server = listener.serve(MAX_SESSIONS, move |stream, _peer, _stop| {
        let r = Arc::clone(&r);
        async move {
            if let Ok(Accepted::Session(mut s)) = accept(stream, &r).await {
                while let Ok(m) = s.recv().await {
                    if s.send(&m).await.is_err() {
                        break;
                    }
                }
            }
        }
    });
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port);

    // Two silent connections (no handshake) from the same address...
    let _a = dial(addr, Duration::from_secs(1)).await.unwrap();
    let _b = dial(addr, Duration::from_secs(1)).await.unwrap();
    wait_until(|| server.active_connections() == 2).await;
    // ...and a third from it is closed at once, although slots are free.
    let mut extra = dial(addr, Duration::from_secs(1)).await.unwrap();
    let mut buf = [0u8; 1];
    let n = tokio::time::timeout(Duration::from_secs(2), extra.read(&mut buf))
        .await
        .expect("closed promptly")
        .unwrap_or(0);
    assert_eq!(n, 0);
    assert_eq!(server.active_connections(), 2);

    // When one ends, the address may connect again.
    drop(_a);
    wait_until(|| server.active_connections() < 2).await;
    let mut s = connect(addr, &phone().id, &PC_SECRET).await.unwrap();
    s.send(b"ok").await.unwrap();
    assert_eq!(s.recv().await.unwrap(), b"ok");
    server.shutdown().await;
}

// ---------------------------------------------------------------------------
// LAN discovery
// ---------------------------------------------------------------------------

const PC_ID: &str = "a1b2c3d4e5f60718293a4b5c6d7e8f90";

async fn responder_on_loopback(name: &str) -> (DiscoveryResponder, SocketAddr) {
    let r = DiscoveryResponder::start(0, 47_321, PC_ID.into(), name.into())
        .await
        .unwrap();
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), r.port());
    (r, addr)
}

/// Sends `datagram` to `to` from a fresh socket and returns the answer, if
/// one comes within a short time.
async fn ask(to: SocketAddr, datagram: &[u8]) -> Option<Vec<u8>> {
    let socket = tokio::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0))
        .await
        .unwrap();
    socket.send_to(datagram, to).await.unwrap();
    let mut buf = [0u8; 1024];
    match tokio::time::timeout(Duration::from_millis(300), socket.recv_from(&mut buf)).await {
        Ok(Ok((n, _))) => Some(buf[..n].to_vec()),
        _ => None,
    }
}

#[tokio::test]
async fn discovery_answers_a_valid_probe_from_a_lan_address() {
    let (r, addr) = responder_on_loopback("Desk PC").await;
    let answer = ask(addr, &discovery::probe()).await.expect("an answer");
    assert!(answer.len() < 512);
    let found = discovery::parse_reply(&answer).unwrap();
    assert_eq!(found.device_id, PC_ID);
    assert_eq!(found.name, "Desk PC");
    assert_eq!(found.port, 47_321);
    // A rename shows up in later answers.
    r.set_name("Living room");
    let again = discovery::parse_reply(&ask(addr, &discovery::probe()).await.unwrap()).unwrap();
    assert_eq!(again.name, "Living room");
    r.shutdown().await;
}

#[tokio::test]
async fn discovery_ignores_garbage_and_inexact_probes() {
    let (r, addr) = responder_on_loopback("Desk PC").await;
    let good = discovery::probe();
    let mut longer = good.clone();
    longer.push(0);
    let mut other_version = good.clone();
    // The version sits right after the 10-byte magic.
    other_version[11] ^= 0x7f;
    let mut bad_padding = good.clone();
    *bad_padding.last_mut().unwrap() = 1;
    for bad in [
        &b""[..],
        b"hello",
        b"NMDISCOVER",
        &good[..good.len() - 1],
        &longer,
        &other_version,
        &bad_padding,
        &[0u8; 2000],
    ] {
        assert!(ask(addr, bad).await.is_none(), "answered {bad:?}");
    }
    // No amplification: the longest possible reply is not bigger than the
    // probe that asks for it.
    let longest = discovery::reply(&"a".repeat(64), &"名".repeat(200), 47_321).unwrap();
    assert!(
        longest.len() <= good.len(),
        "{} > {}",
        longest.len(),
        good.len()
    );
    // Still answers a good one afterwards.
    assert!(ask(addr, &good).await.is_some());
    r.shutdown().await;
}

#[test]
fn discovery_never_answers_non_lan_sources() {
    let probe = discovery::probe();
    for ip in ["8.8.8.8", "100.64.0.1", "2001:db8::1", "::ffff:8.8.8.8"] {
        assert!(
            !discovery::should_answer(ip.parse().unwrap(), &probe),
            "{ip}"
        );
    }
    for ip in [
        "192.168.1.7",
        "10.0.0.2",
        "172.16.5.5",
        "169.254.1.1",
        "127.0.0.1",
        "fe80::1",
    ] {
        assert!(
            discovery::should_answer(ip.parse().unwrap(), &probe),
            "{ip}"
        );
    }
}

#[tokio::test]
async fn discovery_replies_are_rate_limited_per_source() {
    let (r, addr) = responder_on_loopback("Desk PC").await;
    let socket = tokio::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0))
        .await
        .unwrap();
    for _ in 0..10 {
        socket.send_to(&discovery::probe(), addr).await.unwrap();
    }
    let mut answers = 0;
    let mut buf = [0u8; 1024];
    while tokio::time::timeout(Duration::from_millis(300), socket.recv_from(&mut buf))
        .await
        .is_ok()
    {
        answers += 1;
    }
    assert!(
        (1..=discovery::MAX_REPLIES_PER_SOURCE).contains(&answers),
        "{answers} answers to 10 probes"
    );
    r.shutdown().await;
}

#[test]
fn the_reply_limiter_caps_total_and_per_source_and_recovers() {
    let t0 = Instant::now();
    let mut l = discovery::ReplyLimiter::new(t0);
    let a: IpAddr = "192.168.1.2".parse().unwrap();
    assert!(l.allow(a, t0));
    assert!(l.allow(a, t0));
    assert!(!l.allow(a, t0));
    // The IPv4-mapped form is the same source.
    assert!(!l.allow("::ffff:192.168.1.2".parse().unwrap(), t0));
    // Many sources: stops at the overall cap.
    let mut granted = 2;
    for i in 3..200u8 {
        if l.allow(IpAddr::V4(Ipv4Addr::new(192, 168, 1, i)), t0) {
            granted += 1;
        }
    }
    assert_eq!(granted, discovery::MAX_REPLIES_PER_SEC);
    // A second later everything is allowed again.
    assert!(l.allow(a, t0 + Duration::from_millis(1100)));
}

#[test]
fn replies_are_small_and_strictly_parsed() {
    let long = "é".repeat(200);
    let reply = discovery::reply(PC_ID, &long, 47_321).unwrap();
    assert!(reply.len() <= discovery::MAX_REPLY);
    let found = discovery::parse_reply(&reply).unwrap();
    assert!(found.name.chars().count() <= 200);
    assert!(long.starts_with(&found.name));

    let good = discovery::reply(PC_ID, "Desk PC", 47_321).unwrap();
    assert!(discovery::parse_reply(&good).is_some());
    // Wrong magic, version, port 0, short, bad id, control characters.
    let mut bad = good.clone();
    bad[0] = b'X';
    assert!(discovery::parse_reply(&bad).is_none());
    let mut bad = good.clone();
    bad[8] ^= 1;
    assert!(discovery::parse_reply(&bad).is_none());
    let mut bad = good.clone();
    bad[9] = 0;
    bad[10] = 0;
    assert!(discovery::parse_reply(&bad).is_none());
    assert!(discovery::parse_reply(&good[..9]).is_none());
    assert!(discovery::parse_reply(&[]).is_none());
    let mut bad = good.clone();
    bad[12] = b'!';
    assert!(discovery::parse_reply(&bad).is_none());
    let mut bad = good.clone();
    bad.push(7);
    assert!(discovery::parse_reply(&bad).is_none());
    // A bad id is never announced.
    assert!(discovery::reply("not an id", "x", 1).is_none());
}

#[tokio::test]
async fn discover_finds_a_responder_end_to_end_on_loopback() {
    let (r, addr) = responder_on_loopback("Desk PC").await;
    let found = discover(&[addr], Duration::from_millis(400)).await.unwrap();
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].device_id, PC_ID);
    assert_eq!(found[0].name, "Desk PC");
    // The TCP port comes from the reply, the address from the source.
    assert_eq!(
        found[0].address,
        SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 47_321)
    );
    // Nothing there: an empty list after the timeout, no error.
    r.shutdown().await;
    assert!(
        discover(&[addr], Duration::from_millis(300))
            .await
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn discover_validates_and_dedups_replies() {
    // A fake network: two sockets that answer every probe, one of them
    // twice, one with garbage first.
    let id_a = PC_ID;
    let id_b = "00112233445566778899aabbccddeeff";
    let mut targets = Vec::new();
    for (id, name, times) in [(id_a, "A", 2), (id_a, "A again", 1), (id_b, "B", 1)] {
        let s = tokio::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0))
            .await
            .unwrap();
        targets.push(s.local_addr().unwrap());
        let reply = discovery::reply(id, name, 47_321).unwrap();
        tokio::spawn(async move {
            let mut buf = [0u8; 64];
            if let Ok((_, from)) = s.recv_from(&mut buf).await {
                let _ = s.send_to(b"garbage", from).await;
                for _ in 0..times {
                    let _ = s.send_to(&reply, from).await;
                }
            }
        });
    }
    let found = discover(&targets, Duration::from_millis(500))
        .await
        .unwrap();
    let mut ids: Vec<_> = found.iter().map(|f| f.device_id.as_str()).collect();
    ids.sort_unstable();
    let mut want = vec![id_a, id_b];
    want.sort_unstable();
    assert_eq!(ids, want);
    assert_eq!(found.len(), 2);
}

#[test]
fn discovery_targets_start_with_the_limited_broadcast() {
    let t = discovery_targets(47_321);
    assert_eq!(
        t[0],
        SocketAddr::new(IpAddr::V4(Ipv4Addr::BROADCAST), 47_321)
    );
    assert!(t.iter().all(|a| a.port() == 47_321));
}

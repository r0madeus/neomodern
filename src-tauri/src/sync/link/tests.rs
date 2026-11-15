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

fn responder(window: Arc<PairingWindow>) -> Responder<fn(&str) -> Option<[u8; 32]>> {
    Responder::new(pc(), window, known_phone as fn(&str) -> Option<[u8; 32]>)
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

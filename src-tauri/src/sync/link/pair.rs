//! One-time pairing of a phone with the PC (docs/SYNC.md, "Security").
//!
//! The PC shows a 6-digit code; the user types it on the phone. Both run
//! SPAKE2 (Ed25519 group) with the code as the password. SPAKE2 is a
//! balanced PAKE: an active attacker gets exactly one guess per protocol
//! run and a passive one learns nothing, so a short code is enough as long
//! as the number of runs is limited (3 wrong attempts, 2 minutes).
//!
//! Exchange (each line one frame, JSON after the opening frame):
//!
//! ```text
//! C -> S  opening(kind=pair) + {device_id, device_name, spake2}
//! S -> C  {"reply": {device_id, device_name, spake2}}   or {"error": code}
//! C -> S  {"confirm": {mac}}          client key confirmation
//! S -> C  {"confirm": {mac}}          or {"error": "wrong_code" | ...}
//! C -> S  "done"                      client accepted the server's proof
//! ```
//!
//! Key schedule. `K` = SPAKE2 output (identities are the fixed role names
//! below; the device ids are not known to the client up front, so they are
//! bound through the transcript instead). `TH` = SHA-256 over every field
//! both sides sent (length-prefixed). Then HKDF-SHA256(salt = TH, ikm = K):
//!
//! - `"neomodern pair v1 confirm client"` -> client MAC key
//! - `"neomodern pair v1 confirm server"` -> server MAC key
//! - `"neomodern pair v1 device secret" 0x00 client_id 0x00 server_id`
//!   -> the 32-byte per-device secret (Noise PSK for later sessions)
//!
//! MACs are HMAC-SHA256(key, TH), checked in constant time. Separate keys
//! per direction stop a MAC from being reflected back.
//!
//! **Order: the client proves first.** The server is the side that counts
//! guesses, so it must not reveal anything derived from `K` before it has
//! judged the client's proof: a wrong proof is answered with a plain
//! "wrong code" and counted. Only then does the server prove itself, which
//! protects the phone from a fake PC (that fake also gets one guess per
//! attempt the user makes). A client that disconnects before sending its
//! proof has learnt nothing it could test a guess with, so that is not
//! counted (it only frees the slot). The final "done" makes the PC store
//! the secret only after the phone has accepted the PC's proof.

use super::error::{LinkError, LinkResult};
use super::frame::{read_frame, write_frame};
use super::{KIND_PAIR, LocalDevice, PROTOCOL_VERSION, opening_frame};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use spake2::{Ed25519Group, Identity, Password, Spake2};
use std::net::SocketAddr;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncWrite};

/// How long a pairing code is valid.
pub const CODE_TTL: Duration = Duration::from_secs(120);
/// Wrong codes allowed before the code is thrown away.
pub const MAX_WRONG_ATTEMPTS: u8 = 3;

const ID_CLIENT: &[u8] = b"neomodern sync client";
const ID_SERVER: &[u8] = b"neomodern sync server";
const TRANSCRIPT_LABEL: &[u8] = b"neomodern pair v1 transcript";
const INFO_CONFIRM_CLIENT: &[u8] = b"neomodern pair v1 confirm client";
const INFO_CONFIRM_SERVER: &[u8] = b"neomodern pair v1 confirm server";
const INFO_SECRET: &[u8] = b"neomodern pair v1 device secret";
/// Pairing messages are small JSON objects.
const MAX_PAIR_FRAME: usize = 4096;
const IO_TIMEOUT: Duration = Duration::from_secs(10);

type HmacSha256 = Hmac<Sha256>;

/// The result of a successful pairing, on both sides.
#[derive(Clone, PartialEq, Eq)]
pub struct Paired {
    pub peer_id: String,
    pub peer_name: String,
    /// The per-device secret: store it, use it as the session PSK.
    pub secret: [u8; 32],
}

impl std::fmt::Debug for Paired {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Paired")
            .field("peer_id", &self.peer_id)
            .field("peer_name", &self.peer_name)
            .field("secret", &"<redacted>")
            .finish()
    }
}

// ---------------------------------------------------------------------------
// Server side: the pairing window
// ---------------------------------------------------------------------------

/// What the desktop's "Pair a phone" panel shows.
#[derive(Clone, PartialEq, Eq)]
pub enum PairingStatus {
    /// No code (never opened, closed, or used up by a successful pairing).
    Closed,
    Open {
        code: String,
        remaining: Duration,
    },
    Expired,
    /// Three wrong codes: this code is dead; open a new one.
    TooManyAttempts,
}

impl std::fmt::Debug for PairingStatus {
    // The code is shown on screen, but it does not belong in logs.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Closed => f.write_str("Closed"),
            Self::Open { remaining, .. } => f
                .debug_struct("Open")
                .field("code", &"<redacted>")
                .field("remaining", remaining)
                .finish(),
            Self::Expired => f.write_str("Expired"),
            Self::TooManyAttempts => f.write_str("TooManyAttempts"),
        }
    }
}

/// The desktop's pairing state: at most one code, valid for 2 minutes,
/// one pairing exchange at a time, dead after 3 wrong attempts or one
/// success.
pub struct PairingWindow {
    ttl: Duration,
    state: Mutex<WindowState>,
}

#[derive(Default)]
struct WindowState {
    /// Bumped on every `open`/`close`, so an exchange that started under
    /// an older code cannot affect (or complete against) a newer one.
    generation: u64,
    active: Option<ActiveCode>,
    /// Why the last code ended, for `status`.
    ended: Option<PairingStatus>,
    /// Generation of the exchange in progress, if any.
    busy: Option<u64>,
}

struct ActiveCode {
    code: String,
    opened: Instant,
    wrong: u8,
}

impl Default for PairingWindow {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Debug for PairingWindow {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PairingWindow")
            .field("status", &self.status())
            .finish()
    }
}

impl PairingWindow {
    pub fn new() -> Self {
        Self::with_ttl(CODE_TTL)
    }

    /// A window whose codes live for `ttl` (tests use a short one).
    pub fn with_ttl(ttl: Duration) -> Self {
        Self {
            ttl,
            state: Mutex::new(WindowState::default()),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, WindowState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Starts pairing with a fresh code (replacing any previous one) and
    /// returns it for display.
    pub fn open(&self) -> LinkResult<String> {
        let code = random_code()?;
        let mut s = self.lock();
        s.generation += 1;
        s.busy = None;
        s.ended = None;
        s.active = Some(ActiveCode {
            code: code.clone(),
            opened: Instant::now(),
            wrong: 0,
        });
        Ok(code)
    }

    /// Stops pairing; the code stops working at once.
    pub fn close(&self) {
        let mut s = self.lock();
        s.generation += 1;
        s.busy = None;
        s.active = None;
        s.ended = None;
    }

    pub fn status(&self) -> PairingStatus {
        let mut s = self.lock();
        self.expire(&mut s);
        match (&s.active, &s.ended) {
            (Some(a), _) => PairingStatus::Open {
                code: a.code.clone(),
                remaining: self.ttl.saturating_sub(a.opened.elapsed()),
            },
            (None, Some(ended)) => ended.clone(),
            (None, None) => PairingStatus::Closed,
        }
    }

    fn expire(&self, s: &mut WindowState) {
        if s.active
            .as_ref()
            .is_some_and(|a| a.opened.elapsed() >= self.ttl)
        {
            s.active = None;
            s.ended = Some(PairingStatus::Expired);
        }
    }

    /// Claims the single pairing slot for one exchange.
    fn begin(&self) -> LinkResult<Ticket<'_>> {
        let mut s = self.lock();
        self.expire(&mut s);
        let Some(active) = &s.active else {
            return Err(match s.ended {
                Some(PairingStatus::Expired) => LinkError::PairingExpired,
                Some(PairingStatus::TooManyAttempts) => LinkError::TooManyAttempts,
                _ => LinkError::PairingNotOpen,
            });
        };
        if s.busy.is_some() {
            return Err(LinkError::PairingBusy);
        }
        let code = active.code.clone();
        let generation = s.generation;
        s.busy = Some(generation);
        Ok(Ticket {
            window: self,
            generation,
            code,
        })
    }
}

/// One claimed pairing exchange. Dropping it without an outcome frees the
/// slot without counting an attempt.
struct Ticket<'a> {
    window: &'a PairingWindow,
    generation: u64,
    code: String,
}

impl Ticket<'_> {
    /// Counts a wrong code. Returns true when this was the last allowed
    /// attempt (the code is now invalid).
    fn wrong_code(self) -> bool {
        let mut s = self.window.lock();
        if s.generation != self.generation {
            return false;
        }
        let Some(active) = s.active.as_mut() else {
            return false;
        };
        active.wrong += 1;
        if active.wrong >= MAX_WRONG_ATTEMPTS {
            s.active = None;
            s.ended = Some(PairingStatus::TooManyAttempts);
            return true;
        }
        false
    }

    /// The code worked: it is used up. Fails when the window was closed or
    /// re-opened meanwhile (the user cancelled; do not pair).
    fn succeeded(self) -> LinkResult<()> {
        let mut s = self.window.lock();
        if s.generation != self.generation || s.active.is_none() {
            return Err(LinkError::PairingNotOpen);
        }
        s.generation += 1;
        s.active = None;
        s.ended = None;
        Ok(())
    }
}

impl Drop for Ticket<'_> {
    fn drop(&mut self) {
        let mut s = self.window.lock();
        if s.busy == Some(self.generation) {
            s.busy = None;
        }
    }
}

/// Six uniformly random digits from the OS RNG. Rejection sampling avoids
/// the modulo bias of `u32 % 1_000_000`.
pub(super) fn random_code() -> LinkResult<String> {
    const LIMIT: u32 = u32::MAX - (u32::MAX % 1_000_000);
    loop {
        let mut b = [0u8; 4];
        getrandom::fill(&mut b).map_err(|_| LinkError::Random)?;
        let n = u32::from_be_bytes(b);
        if n < LIMIT {
            return Ok(format!("{:06}", n % 1_000_000));
        }
    }
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Hello {
    device_id: String,
    device_name: String,
    /// Hex of the SPAKE2 message.
    spake2: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Proof {
    /// Hex of the HMAC.
    mac: String,
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "snake_case")]
enum ErrorCode {
    NotOpen,
    Expired,
    Busy,
    Version,
    BadRequest,
    WrongCode,
    TooManyAttempts,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
enum ServerMsg {
    Reply(Hello),
    Confirm(Proof),
    Error(ErrorCode),
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
enum ClientMsg {
    Confirm(Proof),
    Done,
}

impl From<ErrorCode> for LinkError {
    fn from(c: ErrorCode) -> Self {
        match c {
            ErrorCode::NotOpen => LinkError::PairingNotOpen,
            ErrorCode::Expired => LinkError::PairingExpired,
            ErrorCode::Busy => LinkError::PairingBusy,
            ErrorCode::Version => LinkError::VersionMismatch,
            ErrorCode::BadRequest => LinkError::Protocol("the computer refused the request"),
            ErrorCode::WrongCode => LinkError::WrongCode,
            ErrorCode::TooManyAttempts => LinkError::TooManyAttempts,
        }
    }
}

fn error_code(e: &LinkError) -> Option<ErrorCode> {
    Some(match e {
        LinkError::PairingNotOpen => ErrorCode::NotOpen,
        LinkError::PairingExpired => ErrorCode::Expired,
        LinkError::PairingBusy => ErrorCode::Busy,
        LinkError::TooManyAttempts => ErrorCode::TooManyAttempts,
        _ => return None,
    })
}

async fn send_json<W, T>(w: &mut W, msg: &T) -> LinkResult<()>
where
    W: AsyncWrite + Unpin,
    T: Serialize,
{
    let bytes = serde_json::to_vec(msg).map_err(|_| LinkError::Protocol("encoding failed"))?;
    write_frame(w, &bytes, MAX_PAIR_FRAME, IO_TIMEOUT).await
}

async fn recv_json<R, T>(r: &mut R) -> LinkResult<T>
where
    R: AsyncRead + Unpin,
    T: for<'de> Deserialize<'de>,
{
    let bytes = read_frame(r, MAX_PAIR_FRAME, IO_TIMEOUT).await?;
    serde_json::from_slice(&bytes).map_err(|_| LinkError::Protocol("malformed pairing message"))
}

// ---------------------------------------------------------------------------
// Key schedule
// ---------------------------------------------------------------------------

struct Keys {
    th: [u8; 32],
    client_mac_key: [u8; 32],
    server_mac_key: [u8; 32],
    secret: [u8; 32],
}

/// Everything both sides sent, in a fixed order, each field length-prefixed
/// so no two different transcripts hash the same input.
fn transcript(client: &Hello, client_msg: &[u8], server: &Hello, server_msg: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    for field in [
        TRANSCRIPT_LABEL,
        &PROTOCOL_VERSION.to_be_bytes(),
        client.device_id.as_bytes(),
        client.device_name.as_bytes(),
        client_msg,
        server.device_id.as_bytes(),
        server.device_name.as_bytes(),
        server_msg,
    ] {
        h.update((field.len() as u32).to_be_bytes());
        h.update(field);
    }
    h.finalize().into()
}

fn derive_keys(k: &[u8], th: [u8; 32], client_id: &str, server_id: &str) -> LinkResult<Keys> {
    let hk = Hkdf::<Sha256>::new(Some(&th), k);
    let expand = |info: &[&[u8]]| -> LinkResult<[u8; 32]> {
        let mut out = [0u8; 32];
        hk.expand_multi_info(info, &mut out)
            .map_err(|_| LinkError::Protocol("key derivation failed"))?;
        Ok(out)
    };
    Ok(Keys {
        th,
        client_mac_key: expand(&[INFO_CONFIRM_CLIENT])?,
        server_mac_key: expand(&[INFO_CONFIRM_SERVER])?,
        // Device ids cannot contain 0x00 (see `valid_device_id`), so the
        // separators make the info string unambiguous.
        secret: expand(&[
            INFO_SECRET,
            &[0],
            client_id.as_bytes(),
            &[0],
            server_id.as_bytes(),
        ])?,
    })
}

fn mac(key: &[u8; 32], th: &[u8; 32]) -> LinkResult<Vec<u8>> {
    let mut m = <HmacSha256 as Mac>::new_from_slice(key)
        .map_err(|_| LinkError::Protocol("key derivation failed"))?;
    m.update(th);
    Ok(m.finalize().into_bytes().to_vec())
}

/// Constant-time check of a received MAC (hex).
fn verify_mac(key: &[u8; 32], th: &[u8; 32], received_hex: &str) -> bool {
    let Some(received) = from_hex(received_hex) else {
        return false;
    };
    let Ok(mut m) = <HmacSha256 as Mac>::new_from_slice(key) else {
        return false;
    };
    m.update(th);
    m.verify_slice(&received).is_ok()
}

fn spake_start(code: &str, client: bool) -> (Spake2<Ed25519Group>, Vec<u8>) {
    let pw = Password::new(code.as_bytes());
    let (a, b) = (Identity::new(ID_CLIENT), Identity::new(ID_SERVER));
    if client {
        Spake2::<Ed25519Group>::start_a(&pw, &a, &b)
    } else {
        Spake2::<Ed25519Group>::start_b(&pw, &a, &b)
    }
}

fn check_hello(h: &Hello) -> bool {
    super::valid_device_id(&h.device_id) && super::valid_device_name(&h.device_name)
}

// ---------------------------------------------------------------------------
// Server side
// ---------------------------------------------------------------------------

/// Runs the server half after the opening frame (`body` = its JSON).
pub(super) async fn respond<S>(
    stream: &mut S,
    version: u16,
    body: &[u8],
    local: &LocalDevice,
    window: &PairingWindow,
) -> LinkResult<Paired>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    if version != PROTOCOL_VERSION {
        send_json(stream, &ServerMsg::Error(ErrorCode::Version)).await?;
        return Err(LinkError::VersionMismatch);
    }
    let parsed: Option<(Hello, Vec<u8>)> = serde_json::from_slice::<Hello>(body)
        .ok()
        .filter(check_hello)
        .and_then(|h| from_hex(&h.spake2).map(|m| (h, m)));
    let Some((client, client_msg)) = parsed else {
        send_json(stream, &ServerMsg::Error(ErrorCode::BadRequest)).await?;
        return Err(LinkError::Protocol("malformed pairing request"));
    };

    let ticket = match window.begin() {
        Ok(t) => t,
        Err(e) => {
            if let Some(code) = error_code(&e) {
                send_json(stream, &ServerMsg::Error(code)).await?;
            }
            return Err(e);
        }
    };

    let (spake, server_msg) = spake_start(&ticket.code, false);
    // A malformed SPAKE2 element is a broken client, not a guess: refuse
    // without counting (the ticket is released on drop).
    let Ok(k) = spake.finish(&client_msg) else {
        send_json(stream, &ServerMsg::Error(ErrorCode::BadRequest)).await?;
        return Err(LinkError::Protocol("malformed pairing request"));
    };
    let server = Hello {
        device_id: local.id.clone(),
        device_name: local.name.clone(),
        spake2: to_hex(&server_msg),
    };
    let th = transcript(&client, &client_msg, &server, &server_msg);
    let keys = derive_keys(&k, th, &client.device_id, &server.device_id)?;
    send_json(stream, &ServerMsg::Reply(server)).await?;

    let ClientMsg::Confirm(proof) = recv_json::<_, ClientMsg>(stream).await? else {
        return Err(LinkError::Protocol("expected key confirmation"));
    };
    if !verify_mac(&keys.client_mac_key, &keys.th, &proof.mac) {
        let (code, err) = if ticket.wrong_code() {
            (ErrorCode::TooManyAttempts, LinkError::TooManyAttempts)
        } else {
            (ErrorCode::WrongCode, LinkError::WrongCode)
        };
        // Best effort: the attempt is already counted.
        let _ = send_json(stream, &ServerMsg::Error(code)).await;
        return Err(err);
    }

    let proof = Proof {
        mac: to_hex(&mac(&keys.server_mac_key, &keys.th)?),
    };
    send_json(stream, &ServerMsg::Confirm(proof)).await?;
    match recv_json::<_, ClientMsg>(stream).await? {
        ClientMsg::Done => {}
        ClientMsg::Confirm(_) => return Err(LinkError::Protocol("expected done")),
    }
    ticket.succeeded()?;
    Ok(Paired {
        peer_id: client.device_id,
        peer_name: client.device_name,
        secret: keys.secret,
    })
}

// ---------------------------------------------------------------------------
// Client side
// ---------------------------------------------------------------------------

/// Pairs with the PC at `addr` using the code the user typed.
pub async fn pair_connect(addr: SocketAddr, local: &LocalDevice, code: &str) -> LinkResult<Paired> {
    check_code(code)?;
    let mut stream = super::server::dial(addr, IO_TIMEOUT).await?;
    pair(&mut stream, local, code).await
}

/// Client half of pairing over an already connected stream.
pub async fn pair<S>(stream: &mut S, local: &LocalDevice, code: &str) -> LinkResult<Paired>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    check_code(code)?;
    if !super::valid_device_id(&local.id) || !super::valid_device_name(&local.name) {
        return Err(LinkError::InvalidIdentity);
    }
    let (spake, client_msg) = spake_start(code, true);
    let client = Hello {
        device_id: local.id.clone(),
        device_name: local.name.clone(),
        spake2: to_hex(&client_msg),
    };
    let body = serde_json::to_vec(&client).map_err(|_| LinkError::Protocol("encoding failed"))?;
    write_frame(
        stream,
        &opening_frame(KIND_PAIR, &body),
        MAX_PAIR_FRAME,
        IO_TIMEOUT,
    )
    .await?;

    let server = match recv_json::<_, ServerMsg>(stream).await? {
        ServerMsg::Reply(h) => h,
        ServerMsg::Error(c) => return Err(c.into()),
        ServerMsg::Confirm(_) => return Err(LinkError::Protocol("unexpected confirmation")),
    };
    if !check_hello(&server) {
        return Err(LinkError::InvalidIdentity);
    }
    let server_msg = from_hex(&server.spake2).ok_or(LinkError::Protocol("malformed reply"))?;
    let k = spake
        .finish(&server_msg)
        .map_err(|_| LinkError::PairingFailed)?;
    let th = transcript(&client, &client_msg, &server, &server_msg);
    let keys = derive_keys(&k, th, &client.device_id, &server.device_id)?;

    let proof = Proof {
        mac: to_hex(&mac(&keys.client_mac_key, &keys.th)?),
    };
    send_json(stream, &ClientMsg::Confirm(proof)).await?;
    let proof = match recv_json::<_, ServerMsg>(stream).await? {
        ServerMsg::Confirm(p) => p,
        ServerMsg::Error(c) => return Err(c.into()),
        ServerMsg::Reply(_) => return Err(LinkError::Protocol("unexpected reply")),
    };
    if !verify_mac(&keys.server_mac_key, &keys.th, &proof.mac) {
        return Err(LinkError::PairingFailed);
    }
    send_json(stream, &ClientMsg::Done).await?;
    Ok(Paired {
        peer_id: server.device_id,
        peer_name: server.device_name,
        secret: keys.secret,
    })
}

fn check_code(code: &str) -> LinkResult<()> {
    if code.len() == 6 && code.bytes().all(|b| b.is_ascii_digit()) {
        Ok(())
    } else {
        Err(LinkError::InvalidCode)
    }
}

// ---------------------------------------------------------------------------
// Hex (tiny; not worth a crate)
// ---------------------------------------------------------------------------

pub(super) fn to_hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(DIGITS[(b >> 4) as usize] as char);
        s.push(DIGITS[(b & 0xf) as usize] as char);
    }
    s
}

pub(super) fn from_hex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    s.as_bytes()
        .chunks(2)
        .map(|pair| {
            let hi = (pair[0] as char).to_digit(16)?;
            let lo = (pair[1] as char).to_digit(16)?;
            Some((hi * 16 + lo) as u8)
        })
        .collect()
}

#[cfg(test)]
pub(super) mod test_support {
    use super::*;

    /// The opening frame a client sends, for tests that stall mid-pairing.
    pub fn client_opening(local: &LocalDevice, code: &str) -> Vec<u8> {
        let (_, msg) = spake_start(code, true);
        let hello = Hello {
            device_id: local.id.clone(),
            device_name: local.name.clone(),
            spake2: to_hex(&msg),
        };
        let body = serde_json::to_vec(&hello).expect("serialisable");
        opening_frame(KIND_PAIR, &body)
    }
}

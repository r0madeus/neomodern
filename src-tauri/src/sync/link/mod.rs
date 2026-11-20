//! The network link between the PC and the phone: pairing, encrypted
//! sessions and framing (docs/SYNC.md, "Security" and "Wire protocol").
//! No SQLite and no app logic here; the sync service builds on this.
//!
//! Every connection starts with one clear *opening* frame:
//!
//! ```text
//! magic "NMLINK" (6) | protocol version u16 BE | kind u8 | body
//! kind 1 = session: body = the client's device id (UTF-8)
//! kind 2 = pairing: body = JSON pairing request (see `pair`)
//! ```
//!
//! For sessions the whole opening frame is the Noise prologue on both
//! sides, so an attacker who rewrites the device id or version in transit
//! makes the handshake fail.
//!
//! Sockets are only opened in `server.rs` (see the guard test in `net.rs`).

mod discovery;
mod error;
mod frame;
mod pair;
mod rate;
mod server;
mod session;

#[cfg(test)]
mod tests;

pub use error::{LinkError, LinkResult};
pub use frame::{read_frame, read_frame_idle, write_frame};
pub use pair::{CODE_TTL, Paired, PairingStatus, PairingWindow, pair, pair_connect};
pub use rate::RateLimiter;
pub use server::{
    DiscoveryResponder, FoundComputer, Listener, ServerHandle, StopSignal, bind, dial, discover,
    discovery_targets, is_lan_address, lan_ipv4_addresses,
};
pub use session::{Session, SessionReader, SessionWriter, connect, handshake};

use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite};

/// Version of the link protocol (opening frame, pairing, Noise framing).
/// The sync payload has its own version inside the session.
pub const PROTOCOL_VERSION: u16 = 1;
/// The TCP port the desktop listens on unless the service picks another.
pub const DEFAULT_PORT: u16 = 47_321;
/// Most simultaneous connections the desktop serves (docs/SYNC.md).
pub const MAX_SESSIONS: usize = 4;
/// Most simultaneous connections from one address: a phone needs at most two
/// (a new session while the old one times out, or pairing next to a
/// session), and one device cannot fill every slot.
pub const MAX_PER_ADDRESS: usize = 2;
/// The opening frame and the Noise handshake must finish within this.
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
/// The whole pairing exchange (after the opening frame) must finish within
/// this. The user types the code *before* the phone connects, so the
/// exchange itself is machine-speed; a short limit stops a slow peer from
/// holding the single pairing slot.
pub const PAIRING_TIMEOUT: Duration = Duration::from_secs(10);
/// Largest logical message a session carries (big sync batches are paged).
pub const MAX_MESSAGE: usize = 1024 * 1024;

const MAGIC: &[u8; 6] = b"NMLINK";
const KIND_SESSION: u8 = 1;
const KIND_PAIR: u8 = 2;
const OPENING_HEADER: usize = MAGIC.len() + 2 + 1;
/// The opening frame is tiny; anything bigger is not one of ours.
const MAX_OPENING_FRAME: usize = 4096;
/// Device names are shown in lists; longer ones are refused.
const MAX_NAME_CHARS: usize = 200;
const MAX_ID_LEN: usize = 64;

/// This device as the other side sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalDevice {
    pub id: String,
    pub name: String,
}

/// A device id is 1–64 ASCII letters, digits, `-` or `_` (the app uses
/// 32 lowercase hex digits). The restricted alphabet keeps ids safe to use
/// as HKDF/prologue input (no separator bytes) and in logs.
pub fn valid_device_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_ID_LEN
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// A display name: at most 200 characters, no control characters.
pub fn valid_device_name(name: &str) -> bool {
    name.chars().count() <= MAX_NAME_CHARS && !name.chars().any(char::is_control)
}

fn opening_frame(kind: u8, body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(OPENING_HEADER + body.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&PROTOCOL_VERSION.to_be_bytes());
    out.push(kind);
    out.extend_from_slice(body);
    out
}

/// What the server does with an incoming connection: the desktop's
/// identity, its pairing window and how to find a paired device's secret.
pub struct Responder<F> {
    pub local: LocalDevice,
    pub window: Arc<PairingWindow>,
    /// Device id -> per-device secret; `None` for unknown (or removed)
    /// devices, whose connections are closed without a reply.
    pub lookup: F,
    pub handshake_timeout: Duration,
    pub pairing_timeout: Duration,
}

impl<F> Responder<F>
where
    F: Fn(&str) -> Option<[u8; 32]>,
{
    pub fn new(local: LocalDevice, window: Arc<PairingWindow>, lookup: F) -> Self {
        Self {
            local,
            window,
            lookup,
            handshake_timeout: HANDSHAKE_TIMEOUT,
            pairing_timeout: PAIRING_TIMEOUT,
        }
    }
}

/// An accepted connection: either a finished pairing (store the secret;
/// the connection is done) or an authenticated, encrypted session.
#[derive(Debug)]
pub enum Accepted {
    Paired(Paired),
    Session(Session),
}

/// Server side of one connection: reads the opening frame and runs either
/// the pairing exchange or the Noise handshake.
///
/// On `Err` the caller just drops the stream; nothing more is sent (for
/// sessions nothing at all is sent to an unknown or wrong-key device).
pub async fn accept<S, F>(mut stream: S, responder: &Responder<F>) -> LinkResult<Accepted>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    F: Fn(&str) -> Option<[u8; 32]>,
{
    let deadline = tokio::time::Instant::now() + responder.handshake_timeout;
    let opening = read_frame(&mut stream, MAX_OPENING_FRAME, responder.handshake_timeout).await?;
    if opening.len() < OPENING_HEADER || &opening[..MAGIC.len()] != MAGIC {
        return Err(LinkError::Protocol("not a NeoModern connection"));
    }
    let version = u16::from_be_bytes([opening[6], opening[7]]);
    let kind = opening[8];
    match kind {
        KIND_SESSION => {
            if version != PROTOCOL_VERSION {
                // No reply: the session protocol says nothing before the
                // peer has proven it holds the secret.
                return Err(LinkError::VersionMismatch);
            }
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            tokio::time::timeout(
                remaining,
                session::respond(stream, opening, &responder.local.id, &responder.lookup),
            )
            .await
            .map_err(|_| LinkError::Timeout)?
            .map(Accepted::Session)
        }
        KIND_PAIR => tokio::time::timeout(
            responder.pairing_timeout,
            pair::respond(
                &mut stream,
                version,
                &opening[OPENING_HEADER..],
                &responder.local,
                &responder.window,
            ),
        )
        .await
        .map_err(|_| LinkError::Timeout)?
        .map(Accepted::Paired),
        _ => Err(LinkError::Protocol("unknown connection kind")),
    }
}

//! Encrypted sessions between paired devices (docs/SYNC.md, "Security").
//!
//! Noise `NNpsk0_25519_ChaChaPoly_BLAKE2s` with the per-device secret from
//! pairing as the PSK:
//!
//! - Only the two paired devices know the PSK, so the handshake succeeds
//!   only between them (mutual authentication without certificates). With
//!   `psk0` the PSK is mixed in before the first message, so the responder
//!   can reject a wrong key on the very first message and never answers.
//! - Fresh ephemeral X25519 keys per session give forward secrecy: a
//!   leaked PSK does not decrypt recorded sessions.
//! - ChaChaPoly is fast without AES hardware (older phones); BLAKE2s is
//!   the matching small-state hash. All pure Rust.
//!
//! Before the handshake the client sends the clear opening frame with its
//! device id (the server needs it to pick the PSK). That frame is the Noise
//! prologue on both sides, so tampering with it breaks the handshake.
//!
//! Transport framing: each frame carries one Noise message (≤ 65 535 bytes
//! including the 16-byte tag). A logical message is split into chunks whose
//! plaintext starts with a 6-byte header `total_len u32 BE | index u16 BE`;
//! the receiver reassembles them in order, total ≤ 1 MiB. Noise nonces are
//! implicit counters, so dropped, reordered or replayed frames fail to
//! decrypt.

use super::error::{LinkError, LinkResult};
use super::frame::{read_frame, read_frame_idle, write_frame};
use super::{KIND_SESSION, MAX_MESSAGE, OPENING_HEADER, opening_frame};
use snow::StatelessTransportState;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite, ReadHalf, WriteHalf};

const NOISE_PARAMS: &str = "Noise_NNpsk0_25519_ChaChaPoly_BLAKE2s";
/// Noise's own limit for one message, tag included.
const MAX_NOISE_MSG: usize = 65_535;
const TAG_LEN: usize = 16;
const CHUNK_HEADER: usize = 6;
/// Plaintext bytes of the logical message per chunk.
const CHUNK_PAYLOAD: usize = MAX_NOISE_MSG - TAG_LEN - CHUNK_HEADER;
/// Once a frame (or a later chunk) has started it must arrive within this.
const BODY_TIMEOUT: Duration = Duration::from_secs(15);
/// Time allowed to write one whole logical message.
const SEND_TIMEOUT: Duration = Duration::from_secs(30);

trait Io: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Io for T {}
type BoxIo = Box<dyn Io>;

/// An authenticated, encrypted connection to a paired device.
pub struct Session {
    reader: SessionReader,
    writer: SessionWriter,
}

impl std::fmt::Debug for Session {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Session")
            .field("peer_id", &self.reader.peer_id)
            .finish_non_exhaustive()
    }
}

/// The receiving half. `recv` is cancel-safe only while it waits for the
/// first byte of a message; once a message has started, dropping the
/// future leaves the stream unusable (drop the session then).
pub struct SessionReader {
    io: ReadHalf<BoxIo>,
    transport: Arc<StatelessTransportState>,
    nonce: u64,
    peer_id: Arc<str>,
    idle_timeout: Option<Duration>,
}

/// The sending half.
pub struct SessionWriter {
    io: WriteHalf<BoxIo>,
    transport: Arc<StatelessTransportState>,
    nonce: u64,
    peer_id: Arc<str>,
}

impl std::fmt::Debug for SessionReader {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SessionReader")
            .field("peer_id", &self.peer_id)
            .finish_non_exhaustive()
    }
}

impl std::fmt::Debug for SessionWriter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SessionWriter")
            .field("peer_id", &self.peer_id)
            .finish_non_exhaustive()
    }
}

impl Session {
    fn new(io: BoxIo, transport: StatelessTransportState, peer_id: &str) -> Self {
        // The stateless transport takes explicit nonces and `&self`, so
        // both halves can share it; each half owns its own counter. Since
        // TCP delivers in order, the counters stay in step with the peer.
        let transport = Arc::new(transport);
        let peer_id: Arc<str> = Arc::from(peer_id);
        let (r, w) = tokio::io::split(io);
        Self {
            reader: SessionReader {
                io: r,
                transport: Arc::clone(&transport),
                nonce: 0,
                peer_id: Arc::clone(&peer_id),
                idle_timeout: None,
            },
            writer: SessionWriter {
                io: w,
                transport,
                nonce: 0,
                peer_id,
            },
        }
    }

    /// The other device's id (authenticated by the handshake).
    pub fn peer_id(&self) -> &str {
        &self.reader.peer_id
    }

    pub async fn send(&mut self, msg: &[u8]) -> LinkResult<()> {
        self.writer.send(msg).await
    }

    pub async fn recv(&mut self) -> LinkResult<Vec<u8>> {
        self.reader.recv().await
    }

    /// How long `recv` waits for a new message (`None`: forever, the
    /// default; the service runs its own keep-alive).
    pub fn set_idle_timeout(&mut self, t: Option<Duration>) {
        self.reader.idle_timeout = t;
    }

    /// Splits into halves so one task can read while another writes.
    pub fn into_split(self) -> (SessionReader, SessionWriter) {
        (self.reader, self.writer)
    }
}

impl SessionWriter {
    pub fn peer_id(&self) -> &str {
        &self.peer_id
    }

    /// Sends one logical message (≤ 1 MiB), split into chunks as needed.
    pub async fn send(&mut self, msg: &[u8]) -> LinkResult<()> {
        if msg.len() > MAX_MESSAGE {
            return Err(LinkError::MessageTooLarge {
                len: msg.len(),
                max: MAX_MESSAGE,
            });
        }
        let total = (msg.len() as u32).to_be_bytes();
        let mut wire = Vec::with_capacity(msg.len() + msg.len() / CHUNK_PAYLOAD * 32 + 32);
        let mut plain = Vec::with_capacity(CHUNK_HEADER + CHUNK_PAYLOAD.min(msg.len()));
        let mut cipher = vec![0u8; MAX_NOISE_MSG];
        // An empty message still goes out as one (header-only) chunk.
        let chunks: Vec<&[u8]> = if msg.is_empty() {
            vec![&[]]
        } else {
            msg.chunks(CHUNK_PAYLOAD).collect()
        };
        for (index, part) in chunks.into_iter().enumerate() {
            plain.clear();
            plain.extend_from_slice(&total);
            plain.extend_from_slice(&(index as u16).to_be_bytes());
            plain.extend_from_slice(part);
            let n = self
                .transport
                .write_message(self.nonce, &plain, &mut cipher)
                .map_err(|_| LinkError::Protocol("encryption failed"))?;
            self.nonce += 1;
            wire.extend_from_slice(&(n as u32).to_be_bytes());
            wire.extend_from_slice(&cipher[..n]);
        }
        // All chunks in one write: fewer syscalls, and a timeout covers the
        // whole message.
        let write = async {
            use tokio::io::AsyncWriteExt;
            self.io.write_all(&wire).await?;
            self.io.flush().await
        };
        tokio::time::timeout(SEND_TIMEOUT, write)
            .await
            .map_err(|_| LinkError::Timeout)?
            .map_err(LinkError::from)
    }
}

#[cfg(test)]
impl SessionWriter {
    /// Sends one hand-made chunk, to test how the reader treats a peer
    /// that breaks the chunking rules.
    pub(super) async fn send_chunk_for_test(
        &mut self,
        total: u32,
        index: u16,
        part: &[u8],
    ) -> LinkResult<()> {
        let mut plain = total.to_be_bytes().to_vec();
        plain.extend_from_slice(&index.to_be_bytes());
        plain.extend_from_slice(part);
        let mut cipher = vec![0u8; MAX_NOISE_MSG];
        let n = self
            .transport
            .write_message(self.nonce, &plain, &mut cipher)
            .map_err(|_| LinkError::Protocol("encryption failed"))?;
        self.nonce += 1;
        write_frame(&mut self.io, &cipher[..n], MAX_NOISE_MSG, SEND_TIMEOUT).await
    }
}

impl SessionReader {
    pub fn peer_id(&self) -> &str {
        &self.peer_id
    }

    pub fn set_idle_timeout(&mut self, t: Option<Duration>) {
        self.idle_timeout = t;
    }

    fn decrypt(&mut self, frame: &[u8]) -> LinkResult<Vec<u8>> {
        let mut out = vec![0u8; frame.len()];
        let n = self
            .transport
            .read_message(self.nonce, frame, &mut out)
            .map_err(|_| LinkError::Decrypt)?;
        self.nonce += 1;
        out.truncate(n);
        if out.len() < CHUNK_HEADER {
            return Err(LinkError::Protocol("short chunk"));
        }
        Ok(out)
    }

    /// Receives one logical message.
    pub async fn recv(&mut self) -> LinkResult<Vec<u8>> {
        let frame =
            read_frame_idle(&mut self.io, MAX_NOISE_MSG, self.idle_timeout, BODY_TIMEOUT).await?;
        let first = self.decrypt(&frame)?;
        let (total, index) = chunk_header(&first);
        if index != 0 {
            return Err(LinkError::Protocol("chunk out of order"));
        }
        if total > MAX_MESSAGE {
            return Err(LinkError::MessageTooLarge {
                len: total,
                max: MAX_MESSAGE,
            });
        }
        let part = &first[CHUNK_HEADER..];
        if part.len() > total || (part.is_empty() && total > 0) {
            return Err(LinkError::Protocol("bad chunk length"));
        }
        // `total` is bounded above, so this allocation is too.
        let mut msg = Vec::with_capacity(total);
        msg.extend_from_slice(part);
        let mut expected: u16 = 1;
        while msg.len() < total {
            let frame = read_frame(&mut self.io, MAX_NOISE_MSG, BODY_TIMEOUT).await?;
            let chunk = self.decrypt(&frame)?;
            let (t, i) = chunk_header(&chunk);
            let part = &chunk[CHUNK_HEADER..];
            if t != total || i != expected {
                return Err(LinkError::Protocol("chunk out of order"));
            }
            if part.is_empty() || msg.len() + part.len() > total {
                return Err(LinkError::Protocol("bad chunk length"));
            }
            msg.extend_from_slice(part);
            expected = expected
                .checked_add(1)
                .ok_or(LinkError::Protocol("too many chunks"))?;
        }
        Ok(msg)
    }
}

fn chunk_header(plain: &[u8]) -> (usize, u16) {
    let total = u32::from_be_bytes([plain[0], plain[1], plain[2], plain[3]]) as usize;
    let index = u16::from_be_bytes([plain[4], plain[5]]);
    (total, index)
}

fn noise_builder<'a>() -> LinkResult<snow::Builder<'a>> {
    let params = NOISE_PARAMS
        .parse()
        .map_err(|_| LinkError::Protocol("unsupported noise parameters"))?;
    Ok(snow::Builder::new(params))
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// Connects to the PC at `addr` and runs the handshake.
pub async fn connect(addr: SocketAddr, local_id: &str, psk: &[u8; 32]) -> LinkResult<Session> {
    let stream = super::server::dial(addr, super::HANDSHAKE_TIMEOUT).await?;
    handshake(stream, local_id, psk).await
}

/// Client handshake over an already connected stream (5 s limit).
pub async fn handshake<S>(stream: S, local_id: &str, psk: &[u8; 32]) -> LinkResult<Session>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    tokio::time::timeout(
        super::HANDSHAKE_TIMEOUT,
        initiate(Box::new(stream), local_id, psk),
    )
    .await
    .map_err(|_| LinkError::Timeout)?
}

async fn initiate(mut io: BoxIo, local_id: &str, psk: &[u8; 32]) -> LinkResult<Session> {
    if !super::valid_device_id(local_id) {
        return Err(LinkError::InvalidIdentity);
    }
    let hello = opening_frame(KIND_SESSION, local_id.as_bytes());
    let mut hs = noise_builder()?
        .psk(0, psk)
        .and_then(|b| b.prologue(&hello))
        .and_then(snow::Builder::build_initiator)
        .map_err(|_| LinkError::HandshakeFailed)?;
    write_frame(
        &mut io,
        &hello,
        super::MAX_OPENING_FRAME,
        super::HANDSHAKE_TIMEOUT,
    )
    .await?;

    // -> psk, e
    let mut buf = vec![0u8; MAX_NOISE_MSG];
    let n = hs
        .write_message(&[], &mut buf)
        .map_err(|_| LinkError::HandshakeFailed)?;
    write_frame(&mut io, &buf[..n], MAX_NOISE_MSG, super::HANDSHAKE_TIMEOUT).await?;

    // <- e, ee. An unknown id or a wrong PSK makes the server hang up
    // without a word, which shows up here as "closed".
    let reply = match read_frame(&mut io, MAX_NOISE_MSG, super::HANDSHAKE_TIMEOUT).await {
        Err(LinkError::Closed) => return Err(LinkError::HandshakeFailed),
        other => other?,
    };
    let n = hs
        .read_message(&reply, &mut buf)
        .map_err(|_| LinkError::HandshakeFailed)?;
    // The payload is the server's device id, encrypted and authenticated
    // under keys that depend on the PSK.
    let peer_id = std::str::from_utf8(&buf[..n])
        .ok()
        .filter(|id| super::valid_device_id(id))
        .ok_or(LinkError::Protocol("bad device id"))?
        .to_owned();
    let transport = hs
        .into_stateless_transport_mode()
        .map_err(|_| LinkError::HandshakeFailed)?;
    Ok(Session::new(io, transport, &peer_id))
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

/// Server handshake after the opening frame (`hello`) has been read.
pub(super) async fn respond<S, F>(
    stream: S,
    hello: Vec<u8>,
    local_id: &str,
    lookup: &F,
) -> LinkResult<Session>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    F: Fn(&str) -> Option<[u8; 32]>,
{
    let mut io: BoxIo = Box::new(stream);
    let peer_id = std::str::from_utf8(&hello[OPENING_HEADER..])
        .ok()
        .filter(|id| super::valid_device_id(id))
        .ok_or(LinkError::Protocol("bad device id"))?
        .to_owned();
    let psk = lookup(&peer_id).ok_or(LinkError::UnknownDevice)?;
    let mut hs = noise_builder()?
        .psk(0, &psk)
        .and_then(|b| b.prologue(&hello))
        .and_then(snow::Builder::build_responder)
        .map_err(|_| LinkError::HandshakeFailed)?;

    let first = read_frame(&mut io, MAX_NOISE_MSG, super::HANDSHAKE_TIMEOUT).await?;
    let mut buf = vec![0u8; MAX_NOISE_MSG];
    // A wrong PSK (or a rewritten prologue) fails here; we hang up silently.
    hs.read_message(&first, &mut buf)
        .map_err(|_| LinkError::HandshakeFailed)?;
    let n = hs
        .write_message(local_id.as_bytes(), &mut buf)
        .map_err(|_| LinkError::HandshakeFailed)?;
    write_frame(&mut io, &buf[..n], MAX_NOISE_MSG, super::HANDSHAKE_TIMEOUT).await?;
    let transport = hs
        .into_stateless_transport_mode()
        .map_err(|_| LinkError::HandshakeFailed)?;
    Ok(Session::new(io, transport, &peer_id))
}

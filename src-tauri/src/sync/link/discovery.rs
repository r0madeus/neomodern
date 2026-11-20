//! LAN discovery wire format and rate limiting (no sockets: those live in
//! `server.rs`). docs/SYNC.md, "Finding the computer".
//!
//! ```text
//! probe (phone -> broadcast / computer), 12 bytes:
//!   "NMDISCOVER" | protocol version u16 BE
//! reply (computer -> the probing phone, unicast), < 512 bytes:
//!   "NMFOUND" | protocol version u16 BE | TCP port u16 BE
//!           | id length u8 | device id (ASCII) | device name (UTF-8, rest)
//! ```
//!
//! A reply reveals only what the pairing screen already shows next to the
//! code: the computer's name, its random device id and the sync port. No
//! secrets, nothing about paired phones or profiles.

use super::{PROTOCOL_VERSION, valid_device_id, valid_device_name};
use std::collections::HashMap;
use std::net::IpAddr;
use std::time::{Duration, Instant};

const PROBE_MAGIC: &[u8] = b"NMDISCOVER";
const REPLY_MAGIC: &[u8] = b"NMFOUND";
/// A reply never exceeds this.
pub(super) const MAX_REPLY: usize = 400;
/// The probe is padded with zeros to this size, at least as large as any
/// reply, so a spoofed probe can never be turned into a bigger answer
/// (no amplification, even before the rate limits).
pub(super) const PROBE_LEN: usize = MAX_REPLY;
/// Replies per second over all sources, and per source address.
pub(super) const MAX_REPLIES_PER_SEC: u32 = 20;
pub(super) const MAX_REPLIES_PER_SOURCE: u32 = 2;
/// Source addresses remembered within one second (a flood from many
/// spoofed addresses cannot grow the table).
const MAX_TRACKED_SOURCES: usize = 256;

/// The probe datagram.
pub(super) fn probe() -> Vec<u8> {
    let mut out = PROBE_MAGIC.to_vec();
    out.extend_from_slice(&PROTOCOL_VERSION.to_be_bytes());
    out.resize(PROBE_LEN, 0);
    out
}

/// Is `data` exactly our probe (this protocol version)?
pub(super) fn is_probe(data: &[u8]) -> bool {
    data == probe().as_slice()
}

/// The reply to a probe. The name is cut (at a character boundary) so the
/// datagram stays below [`MAX_REPLY`].
pub(super) fn reply(id: &str, name: &str, port: u16) -> Option<Vec<u8>> {
    if !valid_device_id(id) {
        return None;
    }
    let mut out = REPLY_MAGIC.to_vec();
    out.extend_from_slice(&PROTOCOL_VERSION.to_be_bytes());
    out.extend_from_slice(&port.to_be_bytes());
    out.push(u8::try_from(id.len()).ok()?);
    out.extend_from_slice(id.as_bytes());
    let room = MAX_REPLY - out.len();
    let mut name: String = name
        .chars()
        .filter(|c| !c.is_control())
        .take(super::MAX_NAME_CHARS)
        .collect();
    while name.len() > room {
        name.pop();
    }
    out.extend_from_slice(name.as_bytes());
    Some(out)
}

/// Whether a datagram from `from` deserves an answer at all: the source is
/// on the local network and the datagram is exactly the probe.
pub(super) fn should_answer(from: IpAddr, data: &[u8]) -> bool {
    super::is_lan_address(from) && is_probe(data)
}

/// A computer that answered a probe.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Found {
    pub device_id: String,
    pub name: String,
    pub port: u16,
}

/// Validates one reply datagram; `None` for anything that is not exactly
/// ours (wrong magic or version, bad id or name, port 0, trailing junk).
pub(super) fn parse_reply(data: &[u8]) -> Option<Found> {
    let rest = data.strip_prefix(REPLY_MAGIC)?;
    if data.len() > MAX_REPLY || rest.len() < 5 {
        return None;
    }
    let version = u16::from_be_bytes([rest[0], rest[1]]);
    let port = u16::from_be_bytes([rest[2], rest[3]]);
    let id_len = usize::from(rest[4]);
    let body = &rest[5..];
    if version != PROTOCOL_VERSION || port == 0 || body.len() < id_len {
        return None;
    }
    let (id, name) = body.split_at(id_len);
    let id = std::str::from_utf8(id)
        .ok()
        .filter(|i| valid_device_id(i))?;
    let name = std::str::from_utf8(name)
        .ok()
        .filter(|n| valid_device_name(n))?;
    Some(Found {
        device_id: id.to_owned(),
        name: name.trim().to_owned(),
        port,
    })
}

/// Fixed one-second windows: at most [`MAX_REPLIES_PER_SEC`] replies in
/// total and [`MAX_REPLIES_PER_SOURCE`] per source address.
#[derive(Debug)]
pub(super) struct ReplyLimiter {
    window_start: Instant,
    total: u32,
    per_source: HashMap<IpAddr, u32>,
}

impl ReplyLimiter {
    pub fn new(now: Instant) -> Self {
        Self {
            window_start: now,
            total: 0,
            per_source: HashMap::new(),
        }
    }

    /// Whether a reply to `source` may be sent at `now` (and counts it).
    pub fn allow(&mut self, source: IpAddr, now: Instant) -> bool {
        if now.saturating_duration_since(self.window_start) >= Duration::from_secs(1) {
            self.window_start = now;
            self.total = 0;
            self.per_source.clear();
        }
        let source = source.to_canonical();
        if self.total >= MAX_REPLIES_PER_SEC {
            return false;
        }
        if !self.per_source.contains_key(&source) && self.per_source.len() >= MAX_TRACKED_SOURCES {
            return false;
        }
        let n = self.per_source.entry(source).or_insert(0);
        if *n >= MAX_REPLIES_PER_SOURCE {
            return false;
        }
        *n += 1;
        self.total += 1;
        true
    }
}

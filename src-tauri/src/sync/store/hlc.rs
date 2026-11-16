//! Hybrid logical clock: `(wall_ms, counter, device_id)`.
//!
//! Stamps are compared as strings, so the encoding is fixed width
//! (`"{wall_ms:013}-{counter:06}-{device}"`): string order equals clock
//! order, and two devices can never produce the same stamp because the
//! device id is part of it.

/// Hex characters in a device id or a record uuid (128 bits).
pub const ID_LEN: usize = 32;
/// Largest wall time that still fits 13 digits (year 2286).
const MAX_WALL: u64 = 9_999_999_999_999;
const MAX_COUNTER: u32 = 999_999;
/// A peer clock further ahead than this does not advance ours: a phone with
/// a wrong clock must not drag the PC's stamps into the future.
const MAX_SKEW_MS: u64 = 24 * 60 * 60 * 1000;
const ENCODED_LEN: usize = 13 + 1 + 6 + 1 + ID_LEN;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Hlc {
    pub wall_ms: u64,
    pub counter: u32,
    pub device: String,
}

impl Hlc {
    pub fn encode(&self) -> String {
        format!("{:013}-{:06}-{}", self.wall_ms, self.counter, self.device)
    }

    /// Parses a well-formed stamp; anything else is `None`.
    pub fn parse(s: &str) -> Option<Self> {
        if s.len() != ENCODED_LEN || !s.is_ascii() {
            return None;
        }
        let (wall, rest) = s.split_at(13);
        let rest = rest.strip_prefix('-')?;
        let (counter, rest) = rest.split_at(6);
        let device = rest.strip_prefix('-')?;
        if !all_digits(wall) || !all_digits(counter) || !is_id(device) {
            return None;
        }
        Some(Self {
            wall_ms: wall.parse().ok()?,
            counter: counter.parse().ok()?,
            device: device.to_owned(),
        })
    }
}

fn all_digits(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

/// A device id or record uuid: 32 lower-case hex characters.
pub fn is_id(s: &str) -> bool {
    s.len() == ID_LEN && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// The local clock state (persisted in `sync_meta` by the caller).
#[derive(Debug, Clone)]
pub struct Clock {
    pub wall_ms: u64,
    pub counter: u32,
    pub device: String,
}

impl Clock {
    /// A new stamp, strictly greater than every stamp issued or observed
    /// (observations beyond the skew limit are clamped, see [`Clock::observe`]).
    pub fn tick(&mut self, now_ms: i64) -> Hlc {
        let now = u64::try_from(now_ms).unwrap_or(0).min(MAX_WALL);
        if now > self.wall_ms {
            self.wall_ms = now;
            self.counter = 0;
        } else if self.counter >= MAX_COUNTER {
            self.wall_ms = (self.wall_ms + 1).min(MAX_WALL);
            self.counter = 0;
        } else {
            self.counter += 1;
        }
        self.current()
    }

    /// Advances the clock past a received stamp. Stamps more than 24 h ahead
    /// of local time are clamped to that limit (they keep their value on the
    /// record; only our clock ignores the excess).
    pub fn observe(&mut self, stamp: &Hlc, now_ms: i64) {
        let limit = u64::try_from(now_ms)
            .unwrap_or(0)
            .saturating_add(MAX_SKEW_MS)
            .min(MAX_WALL);
        let seen = if stamp.wall_ms > limit {
            (limit, 0)
        } else {
            (stamp.wall_ms, stamp.counter)
        };
        if seen > (self.wall_ms, self.counter) {
            self.wall_ms = seen.0;
            self.counter = seen.1;
        }
    }

    fn current(&self) -> Hlc {
        Hlc {
            wall_ms: self.wall_ms,
            counter: self.counter,
            device: self.device.clone(),
        }
    }
}

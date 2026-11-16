//! Token bucket for incoming remote commands (20 per second per session,
//! docs/SYNC.md "Exposure limits"). A flood from a buggy or hostile phone
//! is dropped instead of hammering the player.

use std::time::Instant;

#[derive(Debug, Clone)]
pub struct RateLimiter {
    capacity: f64,
    per_sec: f64,
    tokens: f64,
    last: Instant,
}

impl RateLimiter {
    /// `per_sec` tokens are added each second, up to `burst` saved up.
    pub fn new(per_sec: u32, burst: u32) -> Self {
        Self {
            capacity: f64::from(burst.max(1)),
            per_sec: f64::from(per_sec.max(1)),
            tokens: f64::from(burst.max(1)),
            last: Instant::now(),
        }
    }

    /// The limit for remote-control commands: 20/s, bursts of 20.
    pub fn remote_commands() -> Self {
        Self::new(20, 20)
    }

    /// Takes one token if available.
    pub fn try_acquire(&mut self) -> bool {
        self.try_acquire_at(Instant::now())
    }

    /// `try_acquire` with an explicit clock (for tests).
    pub fn try_acquire_at(&mut self, now: Instant) -> bool {
        let elapsed = now.saturating_duration_since(self.last);
        self.last = self.last.max(now);
        self.tokens = (self.tokens + elapsed.as_secs_f64() * self.per_sec).min(self.capacity);
        if self.tokens >= 1.0 {
            self.tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

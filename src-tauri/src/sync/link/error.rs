//! The one error type of the link layer.
//!
//! Messages are shown to the user and may end up in logs, so they never
//! contain key material, pairing codes, MACs or plaintext.

/// Everything that can go wrong while pairing, handshaking or exchanging
/// messages.
#[derive(Debug, thiserror::Error)]
pub enum LinkError {
    #[error("network error: {0}")]
    Io(#[from] std::io::Error),
    #[error("not a local network address")]
    NotLocalAddress,
    #[error("the connection timed out")]
    Timeout,
    #[error("the other device closed the connection")]
    Closed,
    #[error("received an empty frame")]
    EmptyFrame,
    #[error("frame of {len} bytes exceeds the limit of {max} bytes")]
    FrameTooLarge { len: usize, max: usize },
    #[error("message of {len} bytes exceeds the limit of {max} bytes")]
    MessageTooLarge { len: usize, max: usize },
    #[error("protocol error: {0}")]
    Protocol(&'static str),
    #[error("protocol version mismatch: update the app on the other device")]
    VersionMismatch,
    #[error("invalid device id or name")]
    InvalidIdentity,
    #[error("the pairing code must be 6 digits")]
    InvalidCode,
    #[error("pairing is not open on the computer")]
    PairingNotOpen,
    #[error("the pairing code has expired")]
    PairingExpired,
    #[error("another device is pairing right now, try again in a moment")]
    PairingBusy,
    #[error("wrong pairing code")]
    WrongCode,
    #[error("wrong pairing code; too many attempts, a new code is needed")]
    TooManyAttempts,
    #[error("pairing failed: the other device could not prove it knows the code")]
    PairingFailed,
    #[error("unknown device")]
    UnknownDevice,
    #[error("secure handshake failed (the devices may need to be paired again)")]
    HandshakeFailed,
    #[error("a message failed authentication (corrupted or tampered with)")]
    Decrypt,
    #[error("the operating system's random number generator failed")]
    Random,
}

pub type LinkResult<T> = Result<T, LinkError>;

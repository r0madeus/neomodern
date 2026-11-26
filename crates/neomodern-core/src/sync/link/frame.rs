//! Length-prefixed framing: `u32` big-endian length, then the payload.
//!
//! The length is checked against the caller's limit *before* anything is
//! allocated, so a peer cannot make us reserve memory by announcing a huge
//! frame. Every read has a deadline so a stalled peer cannot hold a
//! connection (and a session slot) forever.

use super::error::{LinkError, LinkResult};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Writes one frame. Header and payload go out in a single write so small
/// frames are not split into two TCP segments.
pub async fn write_frame<W: AsyncWrite + Unpin + ?Sized>(
    w: &mut W,
    payload: &[u8],
    max_len: usize,
    timeout: Duration,
) -> LinkResult<()> {
    if payload.is_empty() {
        return Err(LinkError::EmptyFrame);
    }
    if payload.len() > max_len {
        return Err(LinkError::FrameTooLarge {
            len: payload.len(),
            max: max_len,
        });
    }
    let len = u32::try_from(payload.len()).map_err(|_| LinkError::FrameTooLarge {
        len: payload.len(),
        max: max_len,
    })?;
    let mut buf = Vec::with_capacity(4 + payload.len());
    buf.extend_from_slice(&len.to_be_bytes());
    buf.extend_from_slice(payload);
    let write = async {
        w.write_all(&buf).await?;
        w.flush().await
    };
    tokio::time::timeout(timeout, write)
        .await
        .map_err(|_| LinkError::Timeout)?
        .map_err(io_error)
}

/// Reads one frame of at most `max_len` bytes within `timeout`.
pub async fn read_frame<R: AsyncRead + Unpin + ?Sized>(
    r: &mut R,
    max_len: usize,
    timeout: Duration,
) -> LinkResult<Vec<u8>> {
    read_frame_idle(r, max_len, Some(timeout), timeout).await
}

/// Reads one frame, waiting up to `idle` (forever when `None`) for its
/// first byte and then at most `body` for the rest of it. A session waits
/// a long time for the next message, but once a frame has started it must
/// arrive promptly (no slow-loris).
pub async fn read_frame_idle<R: AsyncRead + Unpin + ?Sized>(
    r: &mut R,
    max_len: usize,
    idle: Option<Duration>,
    body: Duration,
) -> LinkResult<Vec<u8>> {
    let mut header = [0u8; 4];
    let first = r.read(&mut header[..1]);
    let n = match idle {
        Some(t) => tokio::time::timeout(t, first)
            .await
            .map_err(|_| LinkError::Timeout)?,
        None => first.await,
    }
    .map_err(io_error)?;
    if n == 0 {
        return Err(LinkError::Closed);
    }
    let rest = async {
        r.read_exact(&mut header[1..]).await.map_err(io_error)?;
        let len = u32::from_be_bytes(header) as usize;
        if len == 0 {
            return Err(LinkError::EmptyFrame);
        }
        if len > max_len {
            return Err(LinkError::FrameTooLarge { len, max: max_len });
        }
        let mut buf = vec![0u8; len];
        r.read_exact(&mut buf).await.map_err(io_error)?;
        Ok(buf)
    };
    tokio::time::timeout(body, rest)
        .await
        .map_err(|_| LinkError::Timeout)?
}

/// A peer that hangs up mid-frame is "closed", not a generic I/O error.
fn io_error(e: std::io::Error) -> LinkError {
    match e.kind() {
        std::io::ErrorKind::UnexpectedEof
        | std::io::ErrorKind::ConnectionReset
        | std::io::ErrorKind::ConnectionAborted
        | std::io::ErrorKind::BrokenPipe => LinkError::Closed,
        _ => LinkError::Io(e),
    }
}

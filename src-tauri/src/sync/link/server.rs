//! Sockets: the desktop's listener, the phone's dialer and LAN address
//! helpers. This is the only file in the app that opens TCP/UDP sockets
//! (guarded by the test in `net.rs`).
//!
//! The listener is LAN-only by construction: connections from addresses
//! that are not private, link-local or loopback are dropped before a byte
//! is read, and the dialer refuses such targets too. Carrier-grade NAT
//! (100.64/10) is excluded on purpose: on mobile networks it is shared
//! with strangers.

use super::error::{LinkError, LinkResult};
use std::future::Future;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Semaphore, watch};
use tokio::task::JoinHandle;

/// Is `ip` an address of the local network (or this machine)?
///
/// IPv4: 10/8, 172.16/12, 192.168/16 (RFC 1918), 169.254/16 (link-local),
/// 127/8. IPv6: ::1, fc00::/7 (unique local), fe80::/10 (link-local), and
/// IPv4-mapped forms of the IPv4 ranges (a dual-stack socket reports IPv4
/// peers that way). Everything else, including 100.64/10, is refused.
pub fn is_lan_address(ip: IpAddr) -> bool {
    fn v4(ip: Ipv4Addr) -> bool {
        ip.is_private() || ip.is_link_local() || ip.is_loopback()
    }
    match ip {
        IpAddr::V4(ip) => v4(ip),
        IpAddr::V6(ip) => {
            if let Some(mapped) = ip.to_ipv4_mapped() {
                return v4(mapped);
            }
            let first = ip.segments()[0];
            ip.is_loopback() || (first & 0xfe00) == 0xfc00 || (first & 0xffc0) == 0xfe80
        }
    }
}

/// This machine's LAN IPv4 addresses, for showing next to the pairing
/// code. Best effort: asks the OS which local address it would use to
/// reach a few targets. A UDP `connect` only selects a route; it sends no
/// packet, so this works offline and contacts nobody.
pub fn lan_ipv4_addresses() -> Vec<Ipv4Addr> {
    let Ok(socket) = std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)) else {
        return Vec::new();
    };
    let probes = [
        // The default route: usually the Wi-Fi / Ethernet adapter.
        Ipv4Addr::new(1, 1, 1, 1),
        Ipv4Addr::new(192, 168, 255, 254),
        Ipv4Addr::new(10, 255, 255, 254),
        Ipv4Addr::new(172, 31, 255, 254),
    ];
    let mut out = Vec::new();
    for target in probes {
        if socket.connect((target, 9)).is_err() {
            continue;
        }
        if let Ok(SocketAddr::V4(local)) = socket.local_addr() {
            let ip = *local.ip();
            if is_lan_address(IpAddr::V4(ip)) && !ip.is_loopback() && !out.contains(&ip) {
                out.push(ip);
            }
        }
    }
    out
}

/// Opens a TCP connection to a LAN address (the phone dialling the PC).
pub async fn dial(addr: SocketAddr, timeout: Duration) -> LinkResult<TcpStream> {
    if !is_lan_address(addr.ip()) {
        return Err(LinkError::NotLocalAddress);
    }
    let stream = tokio::time::timeout(timeout, TcpStream::connect(addr))
        .await
        .map_err(|_| LinkError::Timeout)??;
    // Remote commands are tiny; do not let Nagle delay them.
    let _ = stream.set_nodelay(true);
    Ok(stream)
}

/// The desktop's listening sockets (not yet accepting).
#[derive(Debug)]
pub struct Listener {
    listeners: Vec<TcpListener>,
    port: u16,
}

/// Listens on `port` (0 = any free port) on all IPv4 interfaces and,
/// best effort, on IPv6. Where the OS makes `[::]` dual-stack (Linux,
/// Android) the second bind fails and IPv4 alone is used, which is what
/// the UI shows anyway.
pub async fn bind(port: u16) -> LinkResult<Listener> {
    let v4 = TcpListener::bind((Ipv4Addr::UNSPECIFIED, port)).await?;
    let port = v4.local_addr()?.port();
    let mut listeners = vec![v4];
    match TcpListener::bind((Ipv6Addr::UNSPECIFIED, port)).await {
        Ok(v6) => listeners.push(v6),
        Err(e) => log::debug!("sync: no separate IPv6 listener ({e})"),
    }
    Ok(Listener { listeners, port })
}

impl Listener {
    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn local_addrs(&self) -> Vec<SocketAddr> {
        self.listeners
            .iter()
            .filter_map(|l| l.local_addr().ok())
            .collect()
    }

    /// Accepts connections until stopped. Each LAN connection gets one of
    /// `max_sessions` slots and runs `handler` in its own task; when the
    /// slots are full, new connections are closed at once. On stop the
    /// listeners close and every handler is dropped (closing its socket),
    /// whether or not it watches its `StopSignal`.
    ///
    /// Must be called inside a tokio runtime.
    pub fn serve<H, Fut>(self, max_sessions: usize, handler: H) -> ServerHandle
    where
        H: Fn(TcpStream, SocketAddr, StopSignal) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        let (stop_tx, stop_rx) = watch::channel(false);
        let sessions = Arc::new(Semaphore::new(max_sessions));
        let handler = Arc::new(handler);
        let tasks = self
            .listeners
            .into_iter()
            .map(|listener| {
                let stop = StopSignal(stop_rx.clone());
                let sessions = Arc::clone(&sessions);
                let handler = Arc::clone(&handler);
                tokio::spawn(accept_loop(listener, stop, sessions, handler))
            })
            .collect();
        ServerHandle {
            stop: stop_tx,
            tasks,
            sessions,
            max_sessions,
            port: self.port,
        }
    }
}

async fn accept_loop<H, Fut>(
    listener: TcpListener,
    mut stop: StopSignal,
    sessions: Arc<Semaphore>,
    handler: Arc<H>,
) where
    H: Fn(TcpStream, SocketAddr, StopSignal) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = ()> + Send + 'static,
{
    loop {
        let accepted = tokio::select! {
            biased;
            _ = stop.stopped() => break,
            r = listener.accept() => r,
        };
        let (stream, peer) = match accepted {
            Ok(a) => a,
            Err(e) => {
                // E.g. out of file descriptors: back off instead of spinning.
                log::warn!("sync: accept failed: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        if !is_lan_address(peer.ip()) {
            log::debug!("sync: dropped connection from non-local address {peer}");
            continue;
        }
        let Ok(permit) = Arc::clone(&sessions).try_acquire_owned() else {
            log::debug!("sync: session limit reached, dropped {peer}");
            continue;
        };
        let _ = stream.set_nodelay(true);
        let work = handler(stream, peer, stop.clone());
        let mut task_stop = stop.clone();
        tokio::spawn(async move {
            let _permit = permit;
            tokio::select! {
                _ = work => {}
                _ = task_stop.stopped() => {}
            }
        });
    }
}

/// Resolves once the server is told to stop.
#[derive(Debug, Clone)]
pub struct StopSignal(watch::Receiver<bool>);

impl StopSignal {
    pub fn is_stopped(&self) -> bool {
        *self.0.borrow()
    }

    /// Waits until stopped (also when the server handle is gone).
    pub async fn stopped(&mut self) {
        let _ = self.0.wait_for(|stopped| *stopped).await;
    }
}

/// A running server. Dropping it stops the server too.
#[derive(Debug)]
pub struct ServerHandle {
    stop: watch::Sender<bool>,
    tasks: Vec<JoinHandle<()>>,
    sessions: Arc<Semaphore>,
    max_sessions: usize,
    port: u16,
}

impl ServerHandle {
    pub fn port(&self) -> u16 {
        self.port
    }

    /// Connections being served right now (handshaking or in session).
    pub fn active_connections(&self) -> usize {
        self.max_sessions
            .saturating_sub(self.sessions.available_permits())
    }

    pub fn stop_signal(&self) -> StopSignal {
        StopSignal(self.stop.subscribe())
    }

    /// Closes the listeners and every connection (does not wait).
    pub fn stop(&self) {
        self.stop.send_replace(true);
    }

    /// Stops and waits until the listeners are closed and every connection
    /// task has ended.
    pub async fn shutdown(mut self) {
        self.stop();
        for task in std::mem::take(&mut self.tasks) {
            let _ = task.await;
        }
        let all = u32::try_from(self.max_sessions).unwrap_or(u32::MAX);
        let _ = self.sessions.acquire_many(all).await;
    }
}

impl Drop for ServerHandle {
    fn drop(&mut self) {
        self.stop.send_replace(true);
    }
}

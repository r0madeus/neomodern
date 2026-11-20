//! Sockets: the desktop's listener, the phone's dialer and LAN address
//! helpers. This is the only file in the app that opens TCP/UDP sockets
//! (guarded by the test in `net.rs`).
//!
//! The listener is LAN-only by construction: connections from addresses
//! that are not private, link-local or loopback are dropped before a byte
//! is read, and the dialer refuses such targets too. Carrier-grade NAT
//! (100.64/10) is excluded on purpose: on mobile networks it is shared
//! with strangers.

use super::discovery::{self, Found, ReplyLimiter};
use super::error::{LinkError, LinkResult};
use std::collections::HashMap;
use std::future::Future;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::net::{TcpListener, TcpStream, UdpSocket};
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
    per_address: Option<usize>,
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
    Ok(Listener {
        listeners,
        port,
        per_address: None,
    })
}

impl Listener {
    pub fn port(&self) -> u16 {
        self.port
    }

    /// At most `n` simultaneous connections from one address, so a single
    /// device on the network cannot take every slot (unauthenticated
    /// connections hold one until the handshake times out).
    pub fn with_per_address_limit(mut self, n: usize) -> Self {
        self.per_address = Some(n.max(1));
        self
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
        let per_address = PerAddress::new(self.per_address);
        let tasks = self
            .listeners
            .into_iter()
            .map(|listener| {
                let stop = StopSignal(stop_rx.clone());
                let sessions = Arc::clone(&sessions);
                let handler = Arc::clone(&handler);
                let per_address = per_address.clone();
                tokio::spawn(accept_loop(listener, stop, sessions, per_address, handler))
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
    per_address: PerAddress,
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
        let Some(address_slot) = per_address.try_take(peer.ip()) else {
            log::debug!("sync: too many connections from {}, dropped", peer.ip());
            continue;
        };
        let Ok(permit) = Arc::clone(&sessions).try_acquire_owned() else {
            log::debug!("sync: session limit reached, dropped {peer}");
            continue;
        };
        let _ = stream.set_nodelay(true);
        let work = handler(stream, peer, stop.clone());
        let mut task_stop = stop.clone();
        tokio::spawn(async move {
            let _permit = permit;
            let _address_slot = address_slot;
            tokio::select! {
                _ = work => {}
                _ = task_stop.stopped() => {}
            }
        });
    }
}

/// Counts open connections per peer address (IPv4-mapped IPv6 counts as
/// the IPv4 address). Without a limit every connection is allowed.
#[derive(Debug, Clone)]
struct PerAddress {
    limit: Option<usize>,
    open: Arc<Mutex<HashMap<IpAddr, usize>>>,
}

/// One connection's share; frees it on drop.
struct AddressSlot {
    ip: IpAddr,
    open: Option<Arc<Mutex<HashMap<IpAddr, usize>>>>,
}

impl PerAddress {
    fn new(limit: Option<usize>) -> Self {
        Self {
            limit,
            open: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn try_take(&self, ip: IpAddr) -> Option<AddressSlot> {
        let ip = ip.to_canonical();
        let Some(limit) = self.limit else {
            return Some(AddressSlot { ip, open: None });
        };
        let mut open = self.open.lock().unwrap_or_else(|e| e.into_inner());
        let n = open.entry(ip).or_insert(0);
        if *n >= limit {
            return None;
        }
        *n += 1;
        Some(AddressSlot {
            ip,
            open: Some(Arc::clone(&self.open)),
        })
    }
}

impl Drop for AddressSlot {
    fn drop(&mut self) {
        let Some(open) = &self.open else { return };
        let mut open = open.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(n) = open.get_mut(&self.ip) {
            *n = n.saturating_sub(1);
            if *n == 0 {
                open.remove(&self.ip);
            }
        }
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

// ---------------------------------------------------------------------------
// LAN discovery (docs/SYNC.md, "Finding the computer")
// ---------------------------------------------------------------------------

/// The desktop's answer to "who is there?" probes. Lives exactly as long as
/// the TCP listener ("Allow phone connections" on). Dropping it closes the
/// socket.
#[derive(Debug)]
pub struct DiscoveryResponder {
    task: Option<JoinHandle<()>>,
    port: u16,
    name: Arc<Mutex<String>>,
}

impl DiscoveryResponder {
    /// Answers probes on UDP `udp_port` (0 = any free port) with this
    /// computer's `id`, its name and the TCP `tcp_port`. Probes from
    /// non-LAN addresses, anything but the exact probe datagram and
    /// anything over the rate limits (20/s overall, 2/s per source) get no
    /// answer at all.
    pub async fn start(udp_port: u16, tcp_port: u16, id: String, name: String) -> LinkResult<Self> {
        if !super::valid_device_id(&id) {
            return Err(LinkError::InvalidIdentity);
        }
        let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, udp_port)).await?;
        let port = socket.local_addr()?.port();
        let name = Arc::new(Mutex::new(name));
        let task = tokio::spawn(respond_loop(socket, tcp_port, id, Arc::clone(&name)));
        Ok(Self {
            task: Some(task),
            port,
            name,
        })
    }

    /// The UDP port probes are answered on.
    pub fn port(&self) -> u16 {
        self.port
    }

    /// The device was renamed: later answers carry the new name.
    pub fn set_name(&self, name: &str) {
        *self.name.lock().unwrap_or_else(|e| e.into_inner()) = name.to_owned();
    }

    /// Stops answering and waits until the socket is closed.
    pub async fn shutdown(mut self) {
        if let Some(task) = self.task.take() {
            task.abort();
            let _ = task.await;
        }
    }
}

impl Drop for DiscoveryResponder {
    fn drop(&mut self) {
        if let Some(task) = &self.task {
            task.abort();
        }
    }
}

async fn respond_loop(socket: UdpSocket, tcp_port: u16, id: String, name: Arc<Mutex<String>>) {
    let mut limiter = ReplyLimiter::new(std::time::Instant::now());
    // Much longer than the probe: a longer datagram is cut, so it is not the
    // exact probe any more.
    let mut buf = [0u8; discovery::PROBE_LEN + 64];
    loop {
        let (n, from) = match socket.recv_from(&mut buf).await {
            Ok(r) => r,
            Err(e) => {
                // E.g. an ICMP "unreachable" for an earlier reply (Windows
                // reports it on the next receive): keep going.
                log::debug!("sync: discovery receive: {e}");
                tokio::time::sleep(Duration::from_millis(50)).await;
                continue;
            }
        };
        if !discovery::should_answer(from.ip(), &buf[..n]) {
            continue;
        }
        if !limiter.allow(from.ip(), std::time::Instant::now()) {
            continue;
        }
        let name = name.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some(reply) = discovery::reply(&id, &name, tcp_port) {
            let _ = socket.send_to(&reply, from).await;
        }
    }
}

/// A computer found on the local network.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FoundComputer {
    pub device_id: String,
    pub name: String,
    /// `ip:port` to pair with.
    pub address: SocketAddr,
}

/// Where the phone sends its probe: the limited broadcast address and, for
/// each of its LAN IPv4 addresses, the directed broadcast of the /24 around
/// it (a guess that is right on almost every home network).
pub fn discovery_targets(port: u16) -> Vec<SocketAddr> {
    let mut out = vec![SocketAddr::new(IpAddr::V4(Ipv4Addr::BROADCAST), port)];
    for ip in lan_ipv4_addresses() {
        let [a, b, c, _] = ip.octets();
        let target = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(a, b, c, 255)), port);
        if !out.contains(&target) {
            out.push(target);
        }
    }
    out
}

/// Sends the probe to every `targets` address and collects answers for
/// `timeout`. Only well-formed answers from LAN addresses count; one entry
/// per device id (the first answer wins). The targets are not checked
/// here: the real ones are broadcast addresses, tests use loopback.
pub async fn discover(targets: &[SocketAddr], timeout: Duration) -> LinkResult<Vec<FoundComputer>> {
    /// A hostile network cannot make the list grow without bound.
    const MAX_FOUND: usize = 32;
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).await?;
    socket.set_broadcast(true)?;
    let probe = discovery::probe();
    for target in targets {
        // A target that cannot be reached (no route, no such interface) is
        // just skipped.
        if let Err(e) = socket.send_to(&probe, target).await {
            log::debug!("sync: discovery probe to {target}: {e}");
        }
    }
    let deadline = tokio::time::Instant::now() + timeout;
    let mut found: Vec<FoundComputer> = Vec::new();
    let mut buf = [0u8; 1024];
    while found.len() < MAX_FOUND {
        let received = tokio::time::timeout_at(deadline, socket.recv_from(&mut buf)).await;
        let Ok(received) = received else { break };
        let Ok((n, from)) = received else { continue };
        if !is_lan_address(from.ip()) {
            continue;
        }
        let Some(Found {
            device_id,
            name,
            port,
        }) = discovery::parse_reply(&buf[..n])
        else {
            continue;
        };
        if found.iter().any(|f| f.device_id == device_id) {
            continue;
        }
        found.push(FoundComputer {
            device_id,
            name,
            address: SocketAddr::new(from.ip().to_canonical(), port),
        });
    }
    Ok(found)
}

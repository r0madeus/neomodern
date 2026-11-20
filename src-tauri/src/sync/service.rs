//! The sync service (docs/SYNC.md): the desktop's listener for paired
//! phones (server role), the phone's connection to its paired computer
//! (client role), pairing, status and remote control.
//!
//! Everything runs on the Tauri async runtime; every SQLite call goes
//! through `spawn_blocking` and the library mutex is never held across an
//! `.await`. Events go through an [`EventSink`], so the service runs in
//! tests without a Tauri app.

use super::conn::{self, Ctl, Role};
use super::link::{self, Accepted, LocalDevice, PairingStatus, PairingWindow, Responder};
use super::protocol::GuardSummary;
use super::remote::{QueuePage, RemoteCmd, RemoteFeed, RemoteState};
use super::store;
use crate::library::Library;
use crate::player::Player;
use rusqlite::Connection;
use serde::Serialize;
use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, RwLock};
use std::time::Duration;
use tokio::sync::{Notify, mpsc, oneshot, watch};

/// Reconnect backoff of the phone: 2 s doubling to 60 s.
const BACKOFF_MIN: Duration = Duration::from_secs(2);
const BACKOFF_MAX: Duration = Duration::from_secs(60);
/// Local changes are captured this long after the library last changed.
const CAPTURE_DEBOUNCE: Duration = Duration::from_secs(5);
/// How long `remote_send` waits for the computer's answer.
const REMOTE_TIMEOUT: Duration = Duration::from_secs(5);
/// Longest track key accepted from the UI.
const MAX_KEY_BYTES: usize = 4096;

/// Where the service's events go (Tauri events in the app, a list in tests).
pub trait EventSink: Send + Sync {
    fn emit(&self, event: &str, payload: serde_json::Value);
}

/// Sends events to the app's windows.
pub struct TauriSink(pub tauri::AppHandle);

impl EventSink for TauriSink {
    fn emit(&self, event: &str, payload: serde_json::Value) {
        use tauri::{Emitter, Manager};
        // High-rate events wait while the page is hidden (see `crate::ui`).
        if let Some(ui) = self.0.try_state::<Arc<crate::ui::UiVisibility>>()
            && !ui.wants(event)
        {
            return;
        }
        if let Err(e) = self.0.emit(event, payload) {
            log::warn!("failed to emit {event}: {e}");
        }
    }
}

pub struct SyncConfig {
    /// The port the desktop listens on (`link::DEFAULT_PORT`; 0 in tests).
    pub port: u16,
    /// This build may run the server role (desktop).
    pub server: bool,
    /// The device name used until the user sets one.
    pub default_name: String,
    /// `<app data>/sync-backups`.
    pub backup_dir: PathBuf,
}

/// The result of one finished sync round with a peer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncResult {
    pub peer_id: String,
    pub peer_name: String,
    /// Unix milliseconds.
    pub finished_at: i64,
    /// Records sent and received.
    pub sent: usize,
    pub received: usize,
    /// Records the received pages changed here.
    pub changed: usize,
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Listening {
    pub port: u16,
    pub addresses: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingInfo {
    /// `closed`, `open`, `expired` or `tooManyAttempts`.
    pub state: &'static str,
    pub code: Option<String>,
    pub remaining_secs: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerStatus {
    pub id: String,
    pub name: String,
    /// `computer` (this device dials it) or `phone` (it dials us).
    pub kind: &'static str,
    pub address: Option<String>,
    pub connected: bool,
    pub syncing: bool,
    /// Unix milliseconds of the last applied page from this peer.
    pub last_sync_at: Option<i64>,
    pub last_error: Option<String>,
    /// The mass-delete guard stopped a sync from this peer: ask
    /// "Apply / Skip" (`sync_guard_decide`).
    pub pending_guard: Option<GuardSummary>,
    pub last_result: Option<SyncResult>,
    /// Sync rounds finished with this peer since the app started.
    pub rounds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncStatus {
    /// `desktop` (can accept phones) or `phone`.
    pub role: &'static str,
    pub device_id: String,
    pub device_name: String,
    pub allow_phone_connections: bool,
    pub listening: Option<Listening>,
    pub pairing: PairingInfo,
    pub peers: Vec<PeerStatus>,
    pub last_result: Option<SyncResult>,
}

/// Returned by `sync_pair_open`: what the "Pair a phone" panel shows.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingOpen {
    pub code: String,
    pub addresses: Vec<String>,
    pub port: u16,
    pub remaining_secs: u64,
}

/// Runtime state of one peer (not persisted).
#[derive(Default)]
struct PeerRt {
    syncing: bool,
    last_error: Option<String>,
    pending_guard: Option<GuardSummary>,
    /// The user chose "Apply": the next stopped page goes through.
    allow_once: bool,
    /// `quick_check` failed after a sync with this peer: no more syncing
    /// with it until the app restarts.
    integrity_failed: bool,
    last_result: Option<SyncResult>,
    rounds: u64,
}

struct SessionRt {
    id: u64,
    ctl: mpsc::Sender<Ctl>,
}

struct ServerRt {
    handle: link::ServerHandle,
    port: u16,
}

struct ClientRt {
    peer_id: String,
    stop: watch::Sender<bool>,
    wake: Arc<Notify>,
}

#[derive(Default)]
struct State {
    started: bool,
    enabled: bool,
    server: Option<ServerRt>,
    sessions: HashMap<String, SessionRt>,
    peers: HashMap<String, PeerRt>,
    client: Option<ClientRt>,
    remote: Option<RemoteState>,
    last_result: Option<SyncResult>,
    next_session: u64,
}

pub(super) struct Shared {
    pub lib: Arc<Library>,
    /// The player remote commands drive (the desktop's).
    pub player: Option<Arc<Player>>,
    pub feed: RemoteFeed,
    pub backup_dir: PathBuf,
    sink: Arc<dyn EventSink>,
    port: u16,
    server_capable: bool,
    default_name: String,
    window: Arc<PairingWindow>,
    /// Device id -> pairing secret of paired phones, for the responder
    /// (it must not touch SQLite on the async runtime).
    secrets: Arc<RwLock<HashMap<String, [u8; 32]>>>,
    st: Mutex<State>,
    status_dirty: Notify,
    library_dirty: Notify,
    closed: AtomicBool,
}

/// Runs blocking work (player calls, library reads) off the async runtime.
pub(super) async fn run_blocking<T: Send + 'static>(
    f: impl FnOnce() -> T + Send + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(f)
        .await
        .map_err(|e| format!("background task failed: {e}"))
}

/// Runs `f` with the library's database connection, off the async runtime.
pub(super) async fn db<T: Send + 'static>(
    sh: &Shared,
    f: impl FnOnce(&Connection) -> store::Result<T> + Send + 'static,
) -> Result<T, String> {
    let lib = Arc::clone(&sh.lib);
    run_blocking(move || {
        let conn = lib.conn();
        f(&conn)
    })
    .await?
    .map_err(|e| e.to_string())
}

pub(super) fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

/// `192.168.1.5`, `192.168.1.5:47321` or `[fe80::1]:47321`; without a port
/// the default one is used. Only LAN addresses (the dialer refuses others).
pub fn parse_address(s: &str) -> Result<SocketAddr, String> {
    let s = s.trim();
    let addr = s
        .parse::<SocketAddr>()
        .or_else(|_| {
            s.parse::<IpAddr>()
                .map(|ip| SocketAddr::new(ip, link::DEFAULT_PORT))
        })
        .map_err(|_| "enter the computer's address, e.g. 192.168.1.20".to_owned())?;
    if !link::is_lan_address(addr.ip()) {
        return Err("only addresses on the local network can be used".into());
    }
    Ok(addr)
}

/// A name for this device until the user picks one.
pub fn default_device_name() -> String {
    let raw = if cfg!(target_os = "android") {
        "Android phone".to_owned()
    } else {
        std::env::var("COMPUTERNAME")
            .ok()
            .or_else(|| std::fs::read_to_string("/etc/hostname").ok())
            .unwrap_or_default()
    };
    let name: String = raw
        .chars()
        .filter(|c| !c.is_control())
        .take(64)
        .collect::<String>()
        .trim()
        .to_owned();
    if name.is_empty() {
        "NeoModern".into()
    } else {
        name
    }
}

/// Removes a session from the registry when its connection ends.
pub(super) struct SessionGuard {
    sh: Arc<Shared>,
    peer_id: String,
    id: u64,
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        {
            let mut st = self.sh.state();
            if st
                .sessions
                .get(&self.peer_id)
                .is_some_and(|s| s.id == self.id)
            {
                st.sessions.remove(&self.peer_id);
            }
            if let Some(rt) = st.peers.get_mut(&self.peer_id) {
                rt.syncing = false;
            }
        }
        self.sh.dirty();
    }
}

impl Shared {
    fn state(&self) -> MutexGuard<'_, State> {
        self.st.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Something in the status changed; the status task emits it.
    pub(super) fn dirty(&self) {
        self.status_dirty.notify_one();
    }

    pub(super) fn emit<T: Serialize>(&self, event: &str, payload: &T) {
        match serde_json::to_value(payload) {
            Ok(v) => self.sink.emit(event, v),
            Err(e) => log::warn!("failed to serialise {event}: {e}"),
        }
    }

    pub(super) async fn local_device(&self) -> Result<LocalDevice, String> {
        let default = self.default_name.clone();
        db(self, move |c| {
            let id = store::device_id(c)?;
            let name = match store::device_name(c)? {
                Some(n) if link::valid_device_name(&n) && !n.trim().is_empty() => n,
                _ => {
                    store::set_device_name(c, &default)?;
                    default
                }
            };
            Ok(LocalDevice { id, name })
        })
        .await
    }

    pub(super) fn register_session(
        self: &Arc<Self>,
        peer_id: &str,
        ctl: mpsc::Sender<Ctl>,
    ) -> SessionGuard {
        let id = {
            let mut st = self.state();
            st.next_session += 1;
            let id = st.next_session;
            // A phone that reconnects replaces its old session (dropping
            // the old control channel ends that session).
            st.sessions
                .insert(peer_id.to_owned(), SessionRt { id, ctl });
            let rt = st.peers.entry(peer_id.to_owned()).or_default();
            if !rt.integrity_failed {
                rt.last_error = None;
            }
            id
        };
        self.dirty();
        SessionGuard {
            sh: Arc::clone(self),
            peer_id: peer_id.to_owned(),
            id,
        }
    }

    fn with_peer<R>(&self, peer_id: &str, f: impl FnOnce(&mut PeerRt) -> R) -> R {
        let r = f(self.state().peers.entry(peer_id.to_owned()).or_default());
        self.dirty();
        r
    }

    pub(super) fn set_syncing(&self, peer_id: &str, on: bool) {
        self.with_peer(peer_id, |p| p.syncing = on);
    }

    pub(super) fn set_peer_error(&self, peer_id: &str, error: Option<String>) {
        self.with_peer(peer_id, |p| {
            if !p.integrity_failed {
                p.last_error = error;
            }
        });
    }

    pub(super) fn set_remote_state(&self, state: Option<RemoteState>) {
        self.state().remote = state;
    }

    pub(super) fn integrity_failed(&self, peer_id: &str) -> bool {
        self.state()
            .peers
            .get(peer_id)
            .is_some_and(|p| p.integrity_failed)
    }

    pub(super) fn set_integrity_failed(&self, peer_id: &str, message: String) {
        self.with_peer(peer_id, |p| {
            p.integrity_failed = true;
            p.last_error = Some(message);
        });
    }

    pub(super) fn allow_once(&self, peer_id: &str) -> bool {
        self.state()
            .peers
            .get(peer_id)
            .is_some_and(|p| p.allow_once)
    }

    pub(super) fn set_pending_guard(&self, peer_id: &str, summary: GuardSummary) {
        self.with_peer(peer_id, |p| {
            p.pending_guard = Some(summary);
            p.allow_once = false;
        });
    }

    /// All pages of the peer's direction were applied: an "Apply" decision
    /// is used up.
    pub(super) fn direction_applied(&self, peer_id: &str) {
        self.with_peer(peer_id, |p| {
            p.allow_once = false;
            p.pending_guard = None;
        });
    }

    pub(super) fn round_finished(&self, peer_id: &str, result: SyncResult) {
        {
            let mut st = self.state();
            let rt = st.peers.entry(peer_id.to_owned()).or_default();
            rt.syncing = false;
            rt.rounds += 1;
            if !rt.integrity_failed {
                rt.last_error = result.error.clone();
            }
            rt.last_result = Some(result.clone());
            st.last_result = Some(result);
        }
        self.dirty();
    }
}

/// The sync service. Cheap to clone; managed by Tauri.
#[derive(Clone)]
pub struct SyncService {
    sh: Arc<Shared>,
}

impl SyncService {
    pub fn new(
        lib: Arc<Library>,
        player: Option<Arc<Player>>,
        feed: RemoteFeed,
        sink: Arc<dyn EventSink>,
        config: SyncConfig,
    ) -> Self {
        Self {
            sh: Arc::new(Shared {
                lib,
                player,
                feed,
                backup_dir: config.backup_dir,
                sink,
                port: config.port,
                server_capable: config.server,
                default_name: config.default_name,
                window: Arc::new(PairingWindow::new()),
                secrets: Arc::new(RwLock::new(HashMap::new())),
                st: Mutex::new(State::default()),
                status_dirty: Notify::new(),
                library_dirty: Notify::new(),
                closed: AtomicBool::new(false),
            }),
        }
    }

    /// Starts the background tasks, the connection to a paired computer
    /// and (with `allow_phone_connections`) the listener. Must run on the
    /// async runtime; calling it again does nothing.
    pub async fn start(&self, allow_phone_connections: bool) {
        {
            let mut st = self.sh.state();
            if st.started {
                return;
            }
            st.started = true;
        }
        tauri::async_runtime::spawn(status_task(Arc::clone(&self.sh)));
        tauri::async_runtime::spawn(capture_task(Arc::clone(&self.sh)));
        if let Err(e) = self.sh.local_device().await {
            log::warn!("sync: no device identity: {e}");
        }
        match db(&self.sh, |c| {
            for p in store::peers(c)? {
                if store::peer_address(c, &p.device_id)?.is_some() {
                    return Ok(Some(p.device_id));
                }
            }
            Ok(None)
        })
        .await
        {
            Ok(Some(computer)) => self.start_client(computer),
            Ok(None) => {}
            Err(e) => log::warn!("sync: could not read paired devices: {e}"),
        }
        if allow_phone_connections && let Err(e) = self.set_allow_phone_connections(true).await {
            log::warn!("sync: could not listen for phones: {e}");
        }
        self.sh.dirty();
    }

    /// Stops everything (tests; the app just exits).
    pub async fn shutdown(&self) {
        self.sh.closed.store(true, Ordering::SeqCst);
        self.stop_client();
        let _ = self.set_allow_phone_connections(false).await;
        self.sh.state().sessions.clear();
        self.sh.status_dirty.notify_one();
        self.sh.library_dirty.notify_one();
    }

    /// The library changed (its `on_changed` hook): local changes are
    /// captured a few seconds later.
    pub fn library_changed(&self) {
        self.sh.library_dirty.notify_one();
    }

    // --- status ---------------------------------------------------------

    pub async fn status(&self) -> Result<SyncStatus, String> {
        build_status(&self.sh).await
    }

    pub fn remote_state(&self) -> Option<RemoteState> {
        self.sh.state().remote.clone()
    }

    pub async fn set_device_name(&self, name: &str) -> Result<SyncStatus, String> {
        let name = name.trim().to_owned();
        if !link::valid_device_name(&name) {
            return Err("invalid device name".into());
        }
        db(&self.sh, move |c| store::set_device_name(c, &name)).await?;
        self.sh.dirty();
        self.status().await
    }

    // --- server role (desktop) -------------------------------------------

    /// "Allow phone connections": on listens on the sync port, off closes
    /// the listener, the pairing window and every phone's session.
    pub async fn set_allow_phone_connections(&self, on: bool) -> Result<SyncStatus, String> {
        if on && !self.sh.server_capable {
            return Err("this device cannot accept connections".into());
        }
        if on {
            let running = self.sh.state().server.is_some();
            if !running {
                self.start_server().await?;
            }
            self.sh.state().enabled = true;
        } else {
            let server = {
                let mut st = self.sh.state();
                st.enabled = false;
                // Phones' sessions: drop their control channels.
                let client = st.client.as_ref().map(|c| c.peer_id.clone());
                st.sessions.retain(|id, _| Some(id) == client.as_ref());
                st.server.take()
            };
            self.sh.window.close();
            if let Some(server) = server {
                server.handle.shutdown().await;
            }
        }
        self.sh.dirty();
        self.status().await
    }

    async fn start_server(&self) -> Result<(), String> {
        let local = self.sh.local_device().await?;
        let secrets: HashMap<String, [u8; 32]> = db(&self.sh, |c| {
            Ok(store::peers(c)?
                .into_iter()
                .filter_map(|p| Some((p.device_id, <[u8; 32]>::try_from(p.secret).ok()?)))
                .collect())
        })
        .await?;
        *self.sh.secrets.write().unwrap_or_else(|e| e.into_inner()) = secrets;
        let listener = link::bind(self.sh.port)
            .await
            .map_err(|e| format!("could not listen on port {}: {e}", self.sh.port))?;
        let port = listener.port();
        let lookup = Arc::clone(&self.sh.secrets);
        let responder = Arc::new(Responder::new(
            local,
            Arc::clone(&self.sh.window),
            move |id: &str| {
                lookup
                    .read()
                    .unwrap_or_else(|e| e.into_inner())
                    .get(id)
                    .copied()
            },
        ));
        let sh = Arc::clone(&self.sh);
        let handle = listener.serve(link::MAX_SESSIONS, move |stream, _addr, _stop| {
            let sh = Arc::clone(&sh);
            let responder = Arc::clone(&responder);
            async move {
                match link::accept(stream, &responder).await {
                    Ok(Accepted::Paired(p)) => on_paired(&sh, p).await,
                    Ok(Accepted::Session(session)) => {
                        let peer = session.peer_id().to_owned();
                        let ended = conn::run(Arc::clone(&sh), session, Role::Server).await;
                        if let Err(e) = ended.result {
                            log::info!("sync: session with a phone ended: {e}");
                            sh.set_peer_error(&peer, Some(e));
                        }
                    }
                    Err(e) => {
                        log::debug!("sync: connection refused: {e}");
                        // A wrong pairing code changes the pairing state.
                        sh.dirty();
                    }
                }
            }
        });
        self.sh.state().server = Some(ServerRt { handle, port });
        Ok(())
    }

    /// Opens the pairing window (needs phone connections on).
    pub async fn pair_open(&self) -> Result<PairingOpen, String> {
        let port = self
            .sh
            .state()
            .server
            .as_ref()
            .map(|s| s.port)
            .ok_or("turn on \"Allow phone connections\" first")?;
        let code = self.sh.window.open().map_err(|e| e.to_string())?;
        let addresses = run_blocking(lan_addresses).await?;
        self.sh.dirty();
        // Tell the UI when the code runs out.
        let sh = Arc::clone(&self.sh);
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(link::CODE_TTL + Duration::from_millis(200)).await;
            sh.dirty();
        });
        Ok(PairingOpen {
            code,
            addresses,
            port,
            remaining_secs: link::CODE_TTL.as_secs(),
        })
    }

    pub fn pair_close(&self) {
        self.sh.window.close();
        self.sh.dirty();
    }

    /// Unpairs a device: deletes its secret and closes its session.
    pub async fn remove_peer(&self, peer_id: &str) -> Result<SyncStatus, String> {
        let id = peer_id.to_owned();
        let removed = db(&self.sh, move |c| store::remove_peer(c, &id)).await?;
        if !removed {
            return Err("no such device".into());
        }
        self.forget_runtime(peer_id);
        self.sh.dirty();
        self.status().await
    }

    fn forget_runtime(&self, peer_id: &str) {
        self.sh
            .secrets
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .remove(peer_id);
        let is_client = {
            let mut st = self.sh.state();
            st.sessions.remove(peer_id);
            st.peers.remove(peer_id);
            st.client.as_ref().is_some_and(|c| c.peer_id == peer_id)
        };
        if is_client {
            self.stop_client();
            self.sh.set_remote_state(None);
        }
    }

    // --- client role (phone) ---------------------------------------------

    /// Pairs with the computer at `address` using the code it shows, then
    /// stays connected to it. A previously paired computer is forgotten.
    pub async fn connect_pair(&self, address: &str, code: &str) -> Result<SyncStatus, String> {
        let addr = parse_address(address)?;
        let local = self.sh.local_device().await?;
        let paired = link::pair_connect(addr, &local, code.trim())
            .await
            .map_err(|e| e.to_string())?;
        let peer_id = paired.peer_id.clone();
        let old: Vec<String> = db(&self.sh, move |c| {
            let mut old = Vec::new();
            for p in store::peers(c)? {
                if p.device_id != paired.peer_id && store::peer_address(c, &p.device_id)?.is_some()
                {
                    store::remove_peer(c, &p.device_id)?;
                    old.push(p.device_id);
                }
            }
            store::upsert_peer(c, &paired.peer_id, &paired.peer_name, &paired.secret)?;
            store::set_peer_address(c, &paired.peer_id, &addr.to_string())?;
            Ok(old)
        })
        .await?;
        for id in old {
            self.forget_runtime(&id);
        }
        self.stop_client();
        self.sh
            .state()
            .peers
            .insert(peer_id.clone(), PeerRt::default());
        self.start_client(peer_id);
        self.sh.dirty();
        self.status().await
    }

    fn start_client(&self, peer_id: String) {
        let (stop, stop_rx) = watch::channel(false);
        let wake = Arc::new(Notify::new());
        let old = self.sh.state().client.replace(ClientRt {
            peer_id: peer_id.clone(),
            stop,
            wake: Arc::clone(&wake),
        });
        if let Some(old) = old {
            old.stop.send_replace(true);
        }
        tauri::async_runtime::spawn(client_loop(Arc::clone(&self.sh), peer_id, stop_rx, wake));
    }

    fn stop_client(&self) {
        let old = {
            let mut st = self.sh.state();
            let old = st.client.take();
            if let Some(c) = &old {
                st.sessions.remove(&c.peer_id);
            }
            old
        };
        if let Some(c) = old {
            c.stop.send_replace(true);
        }
        self.sh.dirty();
    }

    /// Forgets the paired computer (phone: "Forget this computer").
    pub async fn forget(&self) -> Result<SyncStatus, String> {
        let peer = self.sh.state().client.as_ref().map(|c| c.peer_id.clone());
        let peer = match peer {
            Some(p) => p,
            None => db(&self.sh, |c| {
                for p in store::peers(c)? {
                    if store::peer_address(c, &p.device_id)?.is_some() {
                        return Ok(Some(p.device_id));
                    }
                }
                Ok(None)
            })
            .await?
            .ok_or("no computer is paired")?,
        };
        self.remove_peer(&peer).await
    }

    /// Syncs now: the phone starts a round with its computer (connecting
    /// first if needed); the desktop asks its connected phones to.
    pub async fn sync_now(&self) -> Result<SyncStatus, String> {
        let (ctls, wake) = {
            let st = self.sh.state();
            let ctls: Vec<_> = st.sessions.values().map(|s| s.ctl.clone()).collect();
            let wake = st
                .client
                .as_ref()
                .and_then(|c| (!st.sessions.contains_key(&c.peer_id)).then(|| Arc::clone(&c.wake)));
            (ctls, wake)
        };
        if ctls.is_empty() && wake.is_none() {
            return Err("no device is connected".into());
        }
        for ctl in ctls {
            let _ = ctl.send(Ctl::Sync).await;
        }
        if let Some(wake) = wake {
            wake.notify_one();
        }
        self.status().await
    }

    /// The answer to the mass-delete question for `peer_id`: apply lets
    /// the stopped changes through once (a sync is started), skip keeps
    /// the local data (the next sync asks again).
    pub async fn guard_decide(&self, peer_id: &str, apply: bool) -> Result<SyncStatus, String> {
        let (ctl, wake) = {
            let mut st = self.sh.state();
            let rt = st
                .peers
                .get_mut(peer_id)
                .filter(|p| p.pending_guard.is_some())
                .ok_or("nothing to decide for this device")?;
            rt.pending_guard = None;
            rt.allow_once = apply;
            let ctl = st.sessions.get(peer_id).map(|s| s.ctl.clone());
            let wake = st
                .client
                .as_ref()
                .filter(|c| c.peer_id == peer_id)
                .map(|c| Arc::clone(&c.wake));
            (ctl, wake)
        };
        self.sh.dirty();
        if apply {
            if let Some(ctl) = ctl {
                let _ = ctl.send(Ctl::Sync).await;
            } else if let Some(wake) = wake {
                wake.notify_one();
            }
        }
        self.status().await
    }

    // --- remote control (phone side) --------------------------------------

    async fn remote_request(&self, cmd: RemoteCmd) -> Result<Option<QueuePage>, String> {
        cmd.validate()?;
        let ctl = {
            let st = self.sh.state();
            st.client
                .as_ref()
                .and_then(|c| st.sessions.get(&c.peer_id))
                .map(|s| s.ctl.clone())
        }
        .ok_or("not connected to the computer")?;
        let (reply, answer) = oneshot::channel();
        ctl.send(Ctl::Remote { cmd, reply })
            .await
            .map_err(|_| "not connected to the computer")?;
        tokio::time::timeout(REMOTE_TIMEOUT, answer)
            .await
            .map_err(|_| "the computer did not answer".to_owned())?
            .map_err(|_| "the connection closed".to_owned())?
    }

    /// Sends one remote command to the computer and waits for its answer.
    pub async fn remote_send(&self, cmd: RemoteCmd) -> Result<(), String> {
        if matches!(cmd, RemoteCmd::QueuePage { .. }) {
            return self.remote_queue_page_cmd(cmd).await.map(|_| ());
        }
        self.remote_request(cmd).await.map(|_| ())
    }

    pub async fn remote_queue_page(
        &self,
        offset: usize,
        limit: usize,
    ) -> Result<QueuePage, String> {
        self.remote_queue_page_cmd(RemoteCmd::QueuePage { offset, limit })
            .await
    }

    async fn remote_queue_page_cmd(&self, cmd: RemoteCmd) -> Result<QueuePage, String> {
        self.remote_request(cmd)
            .await?
            .ok_or_else(|| "the computer sent no queue".to_owned())
    }

    /// The cover of this device's own copy of a song (by track key), for
    /// the remote's now-playing view.
    pub async fn cover_for_key(&self, key: &str) -> Result<Option<String>, String> {
        if key.is_empty() || key.len() > MAX_KEY_BYTES {
            return Ok(None);
        }
        let key = key.to_owned();
        db(&self.sh, move |c| {
            let Some(id) = store::resolve_key(c, &key, None)? else {
                return Ok(None);
            };
            use rusqlite::OptionalExtension;
            Ok(c.query_row(
                "SELECT a.cover FROM tracks t JOIN albums a ON a.id = t.album_id WHERE t.id = ?1",
                [id],
                |r| r.get::<_, Option<String>>(0),
            )
            .optional()?
            .flatten())
        })
        .await
    }
}

fn lan_addresses() -> Vec<String> {
    link::lan_ipv4_addresses()
        .into_iter()
        .map(|ip| ip.to_string())
        .collect()
}

async fn on_paired(sh: &Arc<Shared>, p: link::Paired) {
    let (id, name, secret) = (p.peer_id.clone(), p.peer_name.clone(), p.secret);
    match db(sh, move |c| store::upsert_peer(c, &id, &name, &secret)).await {
        Ok(()) => {
            sh.secrets
                .write()
                .unwrap_or_else(|e| e.into_inner())
                .insert(p.peer_id.clone(), p.secret);
            sh.state().peers.entry(p.peer_id.clone()).or_default();
            log::info!("sync: paired with a new phone");
        }
        Err(e) => log::warn!("sync: could not store the pairing: {e}"),
    }
    sh.dirty();
}

/// Keeps the phone connected to its computer: connect, run the session,
/// back off (2 s → 60 s) after errors, until stopped.
async fn client_loop(
    sh: Arc<Shared>,
    peer_id: String,
    mut stop: watch::Receiver<bool>,
    wake: Arc<Notify>,
) {
    let mut backoff = BACKOFF_MIN;
    loop {
        if *stop.borrow() || sh.closed.load(Ordering::SeqCst) {
            return;
        }
        let id = peer_id.clone();
        let target = db(&sh, move |c| {
            Ok((
                store::peer(c, &id)?,
                store::peer_address(c, &id)?,
                store::device_id(c)?,
            ))
        })
        .await;
        let (secret, addr, local_id) = match target {
            Ok((Some(p), Some(a), local)) => {
                match (<[u8; 32]>::try_from(p.secret), parse_address(&a)) {
                    (Ok(s), Ok(a)) => (s, a, local),
                    _ => {
                        sh.set_peer_error(
                            &peer_id,
                            Some("stored pairing is invalid; pair again".into()),
                        );
                        return;
                    }
                }
            }
            Ok(_) => return,
            Err(e) => {
                sh.set_peer_error(&peer_id, Some(e));
                return;
            }
        };
        let attempt = {
            let sh = Arc::clone(&sh);
            async move {
                match link::connect(addr, &local_id, &secret).await {
                    Ok(session) => conn::run(sh, session, Role::Client).await,
                    Err(e) => conn::Ended {
                        welcomed: false,
                        result: Err(e.to_string()),
                    },
                }
            }
        };
        let ended = tokio::select! {
            ended = attempt => ended,
            _ = stop.changed() => return,
        };
        if ended.welcomed {
            // The remote screen shows "not connected".
            sh.set_remote_state(None);
            sh.emit("remote://state", &Option::<RemoteState>::None);
        }
        if ended.welcomed {
            backoff = BACKOFF_MIN;
        }
        match ended.result {
            Ok(()) => {}
            Err(e) => {
                log::info!("sync: connection to the computer: {e}");
                sh.set_peer_error(&peer_id, Some(e));
            }
        }
        sh.dirty();
        tokio::select! {
            _ = tokio::time::sleep(backoff) => {}
            _ = wake.notified() => {}
            _ = stop.changed() => return,
        }
        backoff = (backoff * 2).min(BACKOFF_MAX);
    }
}

/// Emits `sync://status` whenever something changed (coalesced).
async fn status_task(sh: Arc<Shared>) {
    loop {
        sh.status_dirty.notified().await;
        if sh.closed.load(Ordering::SeqCst) {
            return;
        }
        match build_status(&sh).await {
            Ok(status) => sh.emit("sync://status", &status),
            Err(e) => log::warn!("sync: status unavailable: {e}"),
        }
    }
}

/// Captures local changes into the sync tables a few seconds after the
/// library last changed, so they get timely clock stamps. Only with paired
/// devices and not during a scan (the scan's last change triggers it).
async fn capture_task(sh: Arc<Shared>) {
    loop {
        sh.library_dirty.notified().await;
        loop {
            tokio::select! {
                _ = tokio::time::sleep(CAPTURE_DEBOUNCE) => break,
                _ = sh.library_dirty.notified() => {}
            }
        }
        if sh.closed.load(Ordering::SeqCst) {
            return;
        }
        if sh.lib.is_scanning() {
            continue;
        }
        let res = db(&sh, |c| {
            if store::peers(c)?.is_empty() {
                return Ok(false);
            }
            Ok(store::capture(c, now_ms())?.local_changed)
        })
        .await;
        match res {
            Ok(true) => {
                sh.lib.bump();
            }
            Ok(false) => {}
            Err(e) => log::warn!("sync: capturing local changes failed: {e}"),
        }
    }
}

async fn build_status(sh: &Arc<Shared>) -> Result<SyncStatus, String> {
    let local = sh.local_device().await?;
    let listening_port = sh.state().server.as_ref().map(|s| s.port);
    let (peers, addresses) = db(sh, move |c| {
        let mut out = Vec::new();
        for p in store::peers(c)? {
            let addr = store::peer_address(c, &p.device_id)?;
            out.push((p.device_id, p.name, p.last_sync_at, addr));
        }
        let addresses = if listening_port.is_some() {
            lan_addresses()
        } else {
            Vec::new()
        };
        Ok((out, addresses))
    })
    .await?;
    let pairing = match sh.window.status() {
        PairingStatus::Closed => PairingInfo {
            state: "closed",
            code: None,
            remaining_secs: None,
        },
        PairingStatus::Open { code, remaining } => PairingInfo {
            state: "open",
            code: Some(code),
            remaining_secs: Some(remaining.as_secs()),
        },
        PairingStatus::Expired => PairingInfo {
            state: "expired",
            code: None,
            remaining_secs: None,
        },
        PairingStatus::TooManyAttempts => PairingInfo {
            state: "tooManyAttempts",
            code: None,
            remaining_secs: None,
        },
    };
    let st = sh.state();
    let peers = peers
        .into_iter()
        .map(|(id, name, last_sync_at, address)| {
            let rt = st.peers.get(&id);
            PeerStatus {
                kind: if address.is_some() {
                    "computer"
                } else {
                    "phone"
                },
                connected: st.sessions.contains_key(&id),
                syncing: rt.is_some_and(|r| r.syncing),
                last_sync_at,
                last_error: rt.and_then(|r| r.last_error.clone()),
                pending_guard: rt.and_then(|r| r.pending_guard.clone()),
                last_result: rt.and_then(|r| r.last_result.clone()),
                rounds: rt.map_or(0, |r| r.rounds),
                id,
                name,
                address,
            }
        })
        .collect();
    Ok(SyncStatus {
        role: if sh.server_capable {
            "desktop"
        } else {
            "phone"
        },
        device_id: local.id,
        device_name: local.name,
        allow_phone_connections: st.enabled,
        listening: listening_port.map(|port| Listening { port, addresses }),
        pairing,
        peers,
        last_result: st.last_result.clone(),
    })
}

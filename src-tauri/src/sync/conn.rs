//! One encrypted session between two paired devices, on either side: the
//! handshake (`Hello` / `Welcome`), the sync rounds in both directions,
//! remote control and keep-alive. Each side runs one event loop; a reader
//! task feeds it received messages (the link's `recv` must not be
//! cancelled mid-message).
//!
//! A sync round (docs/SYNC.md "Wire protocol"):
//!
//! ```text
//! phone                         computer
//! SyncOffer          ─────────▶
//! SyncBatch (page 1) ─────────▶ apply
//!                    ◀───────── SyncAck / Error
//! …more pages…
//! SyncDone           ─────────▶ capture, then its own pages
//!                    ◀───────── SyncBatch
//! apply, SyncAck     ─────────▶
//!                    ◀───────── SyncDone   (round over)
//! ```

use super::link::{RateLimiter, Session, SessionWriter};
use super::protocol::{ErrorCode, GuardSummary, Msg, SEND_LIMIT, SYNC_VERSION};
use super::remote::{self, QueuePage, RemoteCmd, RemoteErrorCode, RemoteFailure};
use super::service::{Shared, SyncResult, db, now_ms, run_blocking};
use super::store::{self, ApplyOptions, SyncError};
use rusqlite::Connection;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
use tokio::time::Instant;

/// Records per sync page before the size check shrinks it.
pub(super) const PAGE_RECORDS: usize = 2000;
/// The first message must arrive within this.
const HELLO_TIMEOUT: Duration = Duration::from_secs(10);
/// Keep-alive: a ping this often, and the link drops a silent peer after
/// `IDLE_TIMEOUT`.
const PING_EVERY: Duration = Duration::from_secs(20);
const IDLE_TIMEOUT: Duration = Duration::from_secs(60);
/// The phone syncs on connect and then this often.
pub(super) const SYNC_EVERY: Duration = Duration::from_secs(10 * 60);
/// At most 4 position updates per second (docs/SYNC.md).
pub(super) const POSITION_INTERVAL: Duration = Duration::from_millis(250);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Role {
    /// The computer: answers syncs, takes remote commands.
    Server,
    /// The phone: starts syncs, sends remote commands.
    Client,
}

/// What the service asks a live session to do.
pub(super) enum Ctl {
    /// Client: start a sync round now. Server: ask the phone to start one.
    Sync,
    /// Client: send a remote command and hand back the answer.
    Remote {
        cmd: RemoteCmd,
        reply: oneshot::Sender<Result<Option<QueuePage>, String>>,
    },
}

/// How a session ended.
pub(super) struct Ended {
    /// The handshake had completed (the reconnect backoff starts over).
    pub welcomed: bool,
    pub result: Result<(), String>,
}

/// A spawned task that is aborted when this is dropped.
struct AbortOnDrop<T>(tauri::async_runtime::JoinHandle<T>);

impl<T> Drop for AbortOnDrop<T> {
    fn drop(&mut self) {
        self.0.abort();
    }
}

#[derive(Default)]
struct Round {
    sent: usize,
    received: usize,
    changed: usize,
    error: Option<String>,
}

/// Our page in flight: waiting for the peer's `SyncAck`.
struct Outgoing {
    upto: i64,
    more: bool,
    len: usize,
}

struct Conn {
    sh: Arc<Shared>,
    role: Role,
    peer_id: String,
    peer_name: String,
    writer: SessionWriter,
    round: Option<Round>,
    /// A sync was asked for during a round: run another one after it.
    again: bool,
    out: Option<Outgoing>,
    page_size: usize,
    limiter: RateLimiter,
    next_request: u32,
    pending: HashMap<u32, oneshot::Sender<Result<Option<QueuePage>, String>>>,
    last_position_emit: Option<Instant>,
}

/// Runs one session until it ends (network error, the peer closes, or the
/// service drops the session's control channel).
pub(super) async fn run(sh: Arc<Shared>, session: Session, role: Role) -> Ended {
    let peer_id = session.peer_id().to_owned();
    let (mut reader, writer) = session.into_split();
    reader.set_idle_timeout(Some(IDLE_TIMEOUT));
    let (in_tx, mut inbox) = mpsc::channel::<Result<Msg, String>>(16);
    let _reader = AbortOnDrop(tauri::async_runtime::spawn(async move {
        loop {
            let item = match reader.recv().await {
                Ok(bytes) => Msg::parse(&bytes),
                Err(e) => Err(e.to_string()),
            };
            let stop = item.is_err();
            if in_tx.send(item).await.is_err() || stop {
                break;
            }
        }
    }));

    let id = peer_id.clone();
    let peer_name = match db(&sh, move |c| store::peer(c, &id)).await {
        Ok(Some(p)) => p.name,
        Ok(None) => {
            return Ended {
                welcomed: false,
                result: Err("unknown device".into()),
            };
        }
        Err(e) => {
            return Ended {
                welcomed: false,
                result: Err(e),
            };
        }
    };
    let mut conn = Conn {
        sh: Arc::clone(&sh),
        role,
        peer_id,
        peer_name,
        writer,
        round: None,
        again: false,
        out: None,
        page_size: PAGE_RECORDS,
        limiter: RateLimiter::remote_commands(),
        next_request: 1,
        pending: HashMap::new(),
        last_position_emit: None,
    };
    if let Err(e) = conn.handshake(&mut inbox).await {
        return Ended {
            welcomed: false,
            result: Err(e),
        };
    }
    let (ctl_tx, ctl_rx) = mpsc::channel(64);
    let _registered = sh.register_session(&conn.peer_id, ctl_tx);
    let result = conn.serve(inbox, ctl_rx).await;
    Ended {
        welcomed: true,
        result,
    }
}

impl Conn {
    async fn send(&mut self, msg: &Msg) -> Result<(), String> {
        self.send_bytes(&msg.to_bytes()).await
    }

    async fn send_bytes(&mut self, bytes: &[u8]) -> Result<(), String> {
        self.writer.send(bytes).await.map_err(|e| e.to_string())
    }

    async fn handshake(
        &mut self,
        inbox: &mut mpsc::Receiver<Result<Msg, String>>,
    ) -> Result<(), String> {
        let local = self.sh.local_device().await?;
        let app_version = env!("CARGO_PKG_VERSION").to_owned();
        if self.role == Role::Client {
            self.send(&Msg::Hello {
                sync_version: SYNC_VERSION,
                app_version: app_version.clone(),
                device_name: local.name.clone(),
            })
            .await?;
        }
        let first = tokio::time::timeout(HELLO_TIMEOUT, inbox.recv())
            .await
            .map_err(|_| "the other device did not answer".to_owned())?
            .ok_or("the connection closed")??;
        let version_error =
            "The other device runs a different sync version: update the app on both devices.";
        match (self.role, first) {
            (Role::Server, Msg::Hello { sync_version, .. })
            | (Role::Client, Msg::Welcome { sync_version, .. }) => {
                if sync_version != SYNC_VERSION {
                    let _ = self
                        .send(&Msg::error(ErrorCode::Version, version_error))
                        .await;
                    return Err(version_error.into());
                }
            }
            (
                _,
                Msg::Error {
                    code: ErrorCode::Version,
                    ..
                },
            ) => return Err(version_error.into()),
            (_, Msg::Error { message, .. }) => return Err(message),
            _ => {
                let _ = self
                    .send(&Msg::error(ErrorCode::Invalid, "expected a greeting"))
                    .await;
                return Err("protocol error: expected a greeting".into());
            }
        }
        if self.role == Role::Server {
            self.send(&Msg::Welcome {
                sync_version: SYNC_VERSION,
                app_version,
                device_name: local.name,
            })
            .await?;
        }
        Ok(())
    }

    async fn serve(
        &mut self,
        mut inbox: mpsc::Receiver<Result<Msg, String>>,
        mut ctl: mpsc::Receiver<Ctl>,
    ) -> Result<(), String> {
        let server = self.role == Role::Server;
        let mut ping = tokio::time::interval_at(Instant::now() + PING_EVERY, PING_EVERY);
        let mut sync_timer = tokio::time::interval_at(Instant::now() + SYNC_EVERY, SYNC_EVERY);
        let mut state_rx = self.sh.feed.subscribe_state();
        let mut position_rx = self.sh.feed.subscribe_position();
        let mut feed_alive = server && self.sh.player.is_some();
        let mut position_pending = false;
        let mut next_position = Instant::now();

        if feed_alive {
            state_rx.mark_unchanged();
            position_rx.mark_unchanged();
            let player = self.sh.player.clone();
            let snap = run_blocking(move || player.map(|p| p.snapshot())).await?;
            if let Some(snap) = snap {
                self.push_state(Arc::new(snap)).await?;
            }
        }
        if self.role == Role::Client {
            self.start_round().await?;
        }

        loop {
            // A sync asked for during the last round runs now.
            if self.again && self.round.is_none() && self.role == Role::Client {
                self.again = false;
                self.start_round().await?;
            }
            tokio::select! {
                item = inbox.recv() => match item {
                    Some(Ok(msg)) => self.handle(msg).await?,
                    Some(Err(e)) => return Err(e),
                    None => return Err("the connection closed".into()),
                },
                c = ctl.recv() => match c {
                    Some(c) => self.handle_ctl(c).await?,
                    // The service dropped this session (peer removed,
                    // phone connections turned off, app closing).
                    None => return Ok(()),
                },
                _ = ping.tick() => self.send(&Msg::Ping {}).await?,
                _ = sync_timer.tick(), if !server => self.start_round().await?,
                r = state_rx.changed(), if feed_alive => match r {
                    Ok(()) => {
                        let snap = state_rx.borrow_and_update().clone();
                        if let Some(snap) = snap {
                            self.push_state(snap).await?;
                        }
                    }
                    Err(_) => feed_alive = false,
                },
                r = position_rx.changed(), if feed_alive && !position_pending => match r {
                    Ok(()) => position_pending = true,
                    Err(_) => feed_alive = false,
                },
                _ = tokio::time::sleep_until(next_position), if position_pending => {
                    let (seconds, duration) = *position_rx.borrow_and_update();
                    position_pending = false;
                    next_position = Instant::now() + POSITION_INTERVAL;
                    if seconds.is_finite() {
                        let duration = duration.filter(|d| d.is_finite());
                        self.send(&Msg::Position { seconds, duration }).await?;
                    }
                }
            }
        }
    }

    async fn handle_ctl(&mut self, c: Ctl) -> Result<(), String> {
        match (c, self.role) {
            (Ctl::Sync, Role::Client) => self.start_round().await,
            (Ctl::Sync, Role::Server) => self.send(&Msg::SyncOffer {}).await,
            (Ctl::Remote { cmd, reply }, Role::Client) => {
                let id = self.next_request;
                self.next_request = self.next_request.wrapping_add(1).max(1);
                self.pending.retain(|_, r| !r.is_closed());
                self.pending.insert(id, reply);
                self.send(&Msg::Remote { id, cmd }).await
            }
            (Ctl::Remote { reply, .. }, Role::Server) => {
                let _ = reply.send(Err("this device is not a remote".into()));
                Ok(())
            }
        }
    }

    async fn handle(&mut self, msg: Msg) -> Result<(), String> {
        match msg {
            Msg::Hello { .. } | Msg::Welcome { .. } => {
                Err("protocol error: unexpected greeting".into())
            }
            Msg::SyncOffer {} => match self.role {
                Role::Server => {
                    self.round = Some(Round::default());
                    self.out = None;
                    self.sh.set_syncing(&self.peer_id, true);
                    Ok(())
                }
                Role::Client => self.start_round().await,
            },
            Msg::SyncBatch { batch } => self.receive(batch).await,
            Msg::SyncAck { upto_seq } => self.on_ack(upto_seq).await,
            Msg::SyncDone {} => match self.role {
                Role::Server => self.begin_sending().await,
                Role::Client => {
                    self.finish_round().await?;
                    Ok(())
                }
            },
            Msg::Remote { id, cmd } => self.remote(id, cmd).await,
            Msg::RemoteDone { id, error } => {
                if let Some(reply) = self.pending.remove(&id) {
                    let _ = reply.send(match error {
                        None => Ok(None),
                        Some(f) => Err(f.message),
                    });
                }
                Ok(())
            }
            Msg::Queue { id, page } => {
                if self.role == Role::Client {
                    self.sh.emit("remote://queue", &page);
                    if let Some(reply) = self.pending.remove(&id) {
                        let _ = reply.send(Ok(Some(page)));
                    }
                }
                Ok(())
            }
            Msg::State { state } => {
                if self.role == Role::Client {
                    self.sh.emit("remote://state", &state);
                    self.sh.set_remote_state(Some(state));
                }
                Ok(())
            }
            Msg::Position { seconds, duration } => {
                let now = Instant::now();
                let due = self
                    .last_position_emit
                    .is_none_or(|t| now.duration_since(t) >= POSITION_INTERVAL);
                if self.role == Role::Client && due {
                    self.last_position_emit = Some(now);
                    self.sh.emit(
                        "remote://position",
                        &serde_json::json!({ "seconds": seconds, "duration": duration }),
                    );
                }
                Ok(())
            }
            Msg::Ping {} => self.send(&Msg::Pong {}).await,
            Msg::Pong {} => Ok(()),
            Msg::Error {
                code,
                message,
                summary,
            } => self.on_peer_error(code, message, summary).await,
        }
    }

    // --- sync ---------------------------------------------------------

    /// Client: start a round (or queue one behind the running round).
    async fn start_round(&mut self) -> Result<(), String> {
        if self.round.is_some() {
            self.again = true;
            return Ok(());
        }
        self.round = Some(Round::default());
        self.sh.set_syncing(&self.peer_id, true);
        self.send(&Msg::SyncOffer {}).await?;
        self.begin_sending().await
    }

    /// Our direction of the round: capture, then the first page.
    async fn begin_sending(&mut self) -> Result<(), String> {
        if self.round.is_none() {
            // A `SyncDone` without `SyncOffer`: treat it as a round.
            self.round = Some(Round::default());
            self.sh.set_syncing(&self.peer_id, true);
        }
        if self.sh.integrity_failed(&self.peer_id) {
            return self.finish_sending().await;
        }
        self.send_page(true).await
    }

    async fn send_page(&mut self, capture: bool) -> Result<(), String> {
        let peer = self.peer_id.clone();
        let limit = self.page_size;
        let lib = Arc::clone(&self.sh.lib);
        let page = db(&self.sh, move |conn| {
            let mut changed = false;
            if capture {
                changed = store::capture(conn, now_ms())?.local_changed;
            }
            let page = build_page(conn, &peer, limit, SEND_LIMIT)?;
            Ok((page, changed))
        })
        .await;
        let (page, changed) = page?;
        if changed {
            lib.bump();
        }
        self.page_size = page.limit;
        self.out = Some(Outgoing {
            upto: page.upto,
            more: page.more,
            len: page.len,
        });
        self.send_bytes(&page.bytes).await
    }

    async fn on_ack(&mut self, upto: i64) -> Result<(), String> {
        let Some(out) = self.out.take() else {
            return Err("protocol error: unexpected acknowledgement".into());
        };
        if out.upto != upto {
            return Err("protocol error: acknowledgement does not match".into());
        }
        let peer = self.peer_id.clone();
        db(&self.sh, move |c| store::ack_sent(c, &peer, upto)).await?;
        if let Some(r) = self.round.as_mut() {
            r.sent += out.len;
        }
        if out.more {
            self.send_page(false).await
        } else {
            self.finish_sending().await
        }
    }

    async fn finish_sending(&mut self) -> Result<(), String> {
        self.out = None;
        self.send(&Msg::SyncDone {}).await?;
        if self.role == Role::Server {
            self.finish_round().await?;
        }
        Ok(())
    }

    async fn finish_round(&mut self) -> Result<(), String> {
        let round = self.round.take().unwrap_or_default();
        self.out = None;
        self.sh.round_finished(
            &self.peer_id,
            SyncResult {
                peer_id: self.peer_id.clone(),
                peer_name: self.peer_name.clone(),
                finished_at: now_ms(),
                sent: round.sent,
                received: round.received,
                changed: round.changed,
                error: round.error,
            },
        );
        Ok(())
    }

    /// The other side refused our page (or the session).
    async fn on_peer_error(
        &mut self,
        code: ErrorCode,
        message: String,
        _summary: Option<GuardSummary>,
    ) -> Result<(), String> {
        let text = match code {
            ErrorCode::Version => return Err(message),
            ErrorCode::MassDelete => {
                format!(
                    "{} would remove a lot of data; waiting for a decision on that device",
                    self.peer_name
                )
            }
            ErrorCode::Integrity => format!(
                "{}: database check failed; syncing stopped until the app restarts",
                self.peer_name
            ),
            ErrorCode::Invalid | ErrorCode::Failed => {
                format!("{} refused the sync: {message}", self.peer_name)
            }
        };
        log::warn!("sync: {text}");
        if let Some(r) = self.round.as_mut() {
            r.error = Some(text.clone());
        }
        self.sh.set_peer_error(&self.peer_id, Some(text));
        if self.out.is_some() {
            self.finish_sending().await?;
        }
        Ok(())
    }

    /// Applies one page from the peer and answers it.
    async fn receive(&mut self, batch: store::Batch) -> Result<(), String> {
        if self.round.is_none() {
            self.round = Some(Round::default());
            self.sh.set_syncing(&self.peer_id, true);
        }
        let upto = batch.upto_seq;
        let more = batch.more;
        let len = batch.len();
        if self.sh.integrity_failed(&self.peer_id) {
            return self
                .send(&Msg::error(
                    ErrorCode::Integrity,
                    "database check failed on this device",
                ))
                .await;
        }
        let allow = self.sh.allow_once(&self.peer_id);
        let opts = ApplyOptions {
            peer_id: Some(self.peer_id.clone()),
            peer_name: self.peer_name.clone(),
            allow_mass_delete: allow,
            backup_dir: Some(self.sh.backup_dir.clone()),
            now_ms: now_ms(),
        };
        let result = db(&self.sh, move |c| Ok(store::apply(c, &batch, &opts))).await?;
        match result {
            Ok(report) => {
                if report.local_changed {
                    self.sh.lib.bump();
                }
                for cover in report.orphan_covers {
                    self.sh.lib.remove_playlist_cover_if_cached(Some(cover));
                }
                if let Some(r) = self.round.as_mut() {
                    r.received += len;
                    let m = &report.merged;
                    r.changed += m.favorites + m.playlists + m.entries + m.listens;
                }
                if !more {
                    self.sh.direction_applied(&self.peer_id);
                }
                self.send(&Msg::SyncAck { upto_seq: upto }).await
            }
            Err(SyncError::MassDelete(plan)) => {
                let summary = GuardSummary::from_plan(&plan);
                self.sh.set_pending_guard(&self.peer_id, summary.clone());
                if let Some(r) = self.round.as_mut() {
                    r.error = Some("stopped: the other device would remove a lot of data".into());
                }
                self.send(&Msg::Error {
                    code: ErrorCode::MassDelete,
                    message: "the changes would remove a lot of data; waiting for the user".into(),
                    summary: Some(summary),
                })
                .await
            }
            Err(SyncError::Integrity(detail)) => {
                // The data was committed; the UI may need to refresh.
                self.sh.lib.bump();
                log::error!("sync: database integrity check failed: {detail}");
                let text = "The database check failed after a sync. Syncing is stopped until the app restarts; a backup is in the sync-backups folder.".to_owned();
                self.sh.set_integrity_failed(&self.peer_id, text.clone());
                if let Some(r) = self.round.as_mut() {
                    r.error = Some(text);
                }
                self.send(&Msg::error(
                    ErrorCode::Integrity,
                    "database check failed on this device",
                ))
                .await
            }
            Err(e @ (SyncError::Invalid(_) | SyncError::Json(_))) => {
                let text = e.to_string();
                if let Some(r) = self.round.as_mut() {
                    r.error = Some(text.clone());
                }
                self.send(&Msg::error(ErrorCode::Invalid, text)).await
            }
            Err(e) => {
                log::warn!("sync: applying a page failed: {e}");
                let text = e.to_string();
                if let Some(r) = self.round.as_mut() {
                    r.error = Some(text.clone());
                }
                self.send(&Msg::error(ErrorCode::Failed, text)).await
            }
        }
    }

    // --- remote control ---------------------------------------------------

    async fn push_state(&mut self, snap: Arc<crate::player::PlayerSnapshot>) -> Result<(), String> {
        let lib = Arc::clone(&self.sh.lib);
        let state = run_blocking(move || remote::derive_state(&lib, &snap)).await?;
        self.send(&Msg::State { state }).await
    }

    async fn remote(&mut self, id: u32, cmd: RemoteCmd) -> Result<(), String> {
        let refuse = |code, message: &str| Msg::RemoteDone {
            id,
            error: Some(RemoteFailure::new(code, message)),
        };
        if self.role != Role::Server {
            return self
                .send(&refuse(RemoteErrorCode::Unsupported, "not a remote target"))
                .await;
        }
        if !self.limiter.try_acquire() {
            return self
                .send(&refuse(RemoteErrorCode::RateLimited, "too many commands"))
                .await;
        }
        let Some(player) = self.sh.player.clone() else {
            return self
                .send(&refuse(RemoteErrorCode::Unsupported, "no player"))
                .await;
        };
        let lib = Arc::clone(&self.sh.lib);
        let result = run_blocking(move || remote::execute(&player, &lib, &cmd)).await?;
        let reply = match result {
            Ok(Some(page)) => Msg::Queue { id, page },
            Ok(None) => Msg::RemoteDone { id, error: None },
            Err(f) => Msg::RemoteDone { id, error: Some(f) },
        };
        self.send(&reply).await
    }
}

/// One serialised `SyncBatch` page that fits the size limit.
pub(super) struct Page {
    pub bytes: Vec<u8>,
    pub upto: i64,
    pub more: bool,
    pub len: usize,
    /// The record limit that fitted (the next page starts from it).
    pub limit: usize,
}

/// Our changes after the peer's watermark, as one message of at most
/// `max_bytes`: the record limit halves until it fits.
pub(super) fn build_page(
    conn: &Connection,
    peer_id: &str,
    limit: usize,
    max_bytes: usize,
) -> store::Result<Page> {
    let after = store::peer(conn, peer_id)?
        .ok_or_else(|| SyncError::Other("unknown peer".into()))?
        .last_seq_sent;
    let mut limit = limit.max(1);
    loop {
        let batch = store::changes_since(conn, after, limit)?;
        let (upto, more, len) = (batch.upto_seq, batch.more, batch.len());
        let bytes = Msg::SyncBatch { batch }.to_bytes();
        if bytes.len() <= max_bytes || limit == 1 {
            return Ok(Page {
                bytes,
                upto,
                more,
                len,
                limit,
            });
        }
        limit = (limit / 2).max(1);
    }
}

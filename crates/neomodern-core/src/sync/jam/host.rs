//! The computer's side of a Jam: the code, the guests (memory only, never
//! the database), the guest-mode session and the songs guests add.
//!
//! A guest session runs here instead of `conn::run`: it only understands
//! `JamCmd`; anything else closes it. Adding goes through `Player::append`,
//! the method behind the desktop's "add to the end of the queue", so there
//! is still one queue only.

use super::{
    JamCmd, JamErrorCode, JamFailure, JamMsg, JamNowPlaying, JamState, JamTrack, JamUpNext,
    MAX_UP_NEXT, guest_name,
};
use crate::library::Library;
use crate::library::db::SortOrder;
use crate::player::{Player, Status};
use crate::sync::conn::AbortOnDrop;
use crate::sync::link::{
    self, JamGate, Paired, PairingStatus, PairingWindow, RateLimiter, Session,
};
use crate::sync::pair_link::{self, PairQr};
use crate::sync::service::{Shared, SyncService, lan_addresses, run_blocking};
use serde::Serialize;
use std::collections::{HashMap, HashSet, VecDeque};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};
use tokio::sync::{Notify, mpsc, oneshot, watch};

/// The guest's keep-alive comes every 20 s; a silent guest is dropped.
const IDLE_TIMEOUT: Duration = Duration::from_secs(60);
/// The host pushes its state at most 2 times per second.
const PUSH_INTERVAL: Duration = Duration::from_millis(500);
/// Recent adds the host's panel lists.
const MAX_RECENT: usize = 10;
/// Titles and names are clipped to this many characters on the wire.
const MAX_TEXT_CHARS: usize = 200;
/// How long ending a Jam waits for the guest sessions to say goodbye
/// before the listener may close.
const GOODBYE_TIMEOUT: Duration = Duration::from_secs(2);

/// The Jam's limits (docs/JAM.md, "Limits"). Tests shorten them.
#[derive(Debug, Clone, Copy)]
pub(in crate::sync) struct JamLimits {
    /// At most one add per this, per guest.
    pub add_every: Duration,
    /// At most this many adds per `add_window`, per guest.
    pub adds_per_window: usize,
    pub add_window: Duration,
    /// At most this many of the songs after the current one from guests.
    pub guest_songs_ahead: usize,
    /// At least this between two searches of one guest.
    pub search_every: Duration,
}

impl Default for JamLimits {
    fn default() -> Self {
        Self {
            add_every: Duration::from_secs(5),
            adds_per_window: 20,
            add_window: Duration::from_secs(10 * 60),
            guest_songs_ahead: 50,
            search_every: Duration::from_millis(300),
        }
    }
}

/// One guest's add and search history (kept across its reconnects).
#[derive(Debug, Default)]
pub(in crate::sync) struct GuestLimits {
    last_add: Option<Instant>,
    adds: VecDeque<Instant>,
    last_search: Option<Instant>,
}

impl GuestLimits {
    /// May the guest add a song at `now`? Records nothing.
    pub fn allow_add(&mut self, now: Instant, l: &JamLimits) -> bool {
        while self
            .adds
            .front()
            .is_some_and(|t| now.saturating_duration_since(*t) >= l.add_window)
        {
            self.adds.pop_front();
        }
        self.last_add
            .is_none_or(|t| now.saturating_duration_since(t) >= l.add_every)
            && self.adds.len() < l.adds_per_window
    }

    pub fn record_add(&mut self, now: Instant) {
        self.last_add = Some(now);
        self.adds.push_back(now);
    }

    /// Takes a search at `now` if the last one was long enough ago.
    pub fn try_search(&mut self, now: Instant, l: &JamLimits) -> bool {
        if self
            .last_search
            .is_some_and(|t| now.saturating_duration_since(t) < l.search_every)
        {
            return false;
        }
        self.last_search = Some(now);
        true
    }
}

/// What the desktop's Jam panel shows (`jam_status`, `jam://status`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JamStatus {
    pub enabled: bool,
    pub running: bool,
    pub code: Option<String>,
    /// `neomodern://jam?v=1&c=<code>&a=<ip:port,...>`.
    pub link: Option<String>,
    /// The link as a QR code to draw.
    pub qr: Option<PairQr>,
    /// `ip:port` of this computer on the local network, while a Jam runs.
    pub addresses: Vec<String>,
    pub guests: Vec<JamGuestInfo>,
    /// The latest songs guests added, newest first.
    pub recent: Vec<JamRecent>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JamGuestInfo {
    pub id: String,
    pub name: String,
    /// Songs this guest added.
    pub added: u32,
    /// Its phone is connected right now.
    pub connected: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JamRecent {
    pub title: String,
    pub artist: String,
    pub added_by: String,
}

struct Guest {
    id: String,
    name: String,
    key: [u8; 32],
    added: u32,
    limits: GuestLimits,
    /// The live session: its number and the way to end it (`true`: the
    /// guest was removed). Dropping the sender ends it silently.
    session: Option<(u64, oneshot::Sender<bool>)>,
}

#[derive(Default)]
struct HostState {
    /// The Settings switch.
    enabled: bool,
    running: bool,
    host_name: String,
    guests: Vec<Guest>,
    /// Queue entry id -> name of the guest who added it.
    added_by: HashMap<u64, String>,
    recent: VecDeque<JamRecent>,
    next_session: u64,
}

/// The Jam host's state. Lives in the sync service; everything is memory.
pub(in crate::sync) struct JamHost {
    window: PairingWindow,
    st: Mutex<HostState>,
    /// The panel's status changed (`jam://status`).
    dirty: Notify,
    /// The guests' view changed (added songs): sessions push their state.
    changed: watch::Sender<u64>,
    /// Guest sessions running right now.
    live: watch::Sender<usize>,
    /// Adds run one at a time, so two guests cannot both pass the queue cap.
    add_lock: Mutex<()>,
    limits: Mutex<JamLimits>,
}

impl Default for JamHost {
    fn default() -> Self {
        Self {
            window: PairingWindow::jam(),
            st: Mutex::new(HostState::default()),
            dirty: Notify::new(),
            changed: watch::Sender::new(0),
            live: watch::Sender::new(0),
            add_lock: Mutex::new(()),
            limits: Mutex::new(JamLimits::default()),
        }
    }
}

impl JamGate for JamHost {
    fn window(&self) -> &PairingWindow {
        &self.window
    }

    fn has_room(&self) -> bool {
        let st = self.state();
        st.enabled && st.running && st.guests.len() < link::MAX_JAM_GUESTS
    }

    fn admit(&self, guest: &Paired) -> bool {
        {
            let mut st = self.state();
            if !(st.enabled && st.running)
                || st.guests.len() >= link::MAX_JAM_GUESTS
                || st.guests.iter().any(|g| g.id == guest.peer_id)
            {
                return false;
            }
            st.guests.push(Guest {
                id: guest.peer_id.clone(),
                name: guest_name(&guest.peer_name),
                key: guest.secret,
                added: 0,
                limits: GuestLimits::default(),
                session: None,
            });
        }
        log::info!("jam: a guest joined");
        self.dirty();
        true
    }
}

impl JamHost {
    fn state(&self) -> MutexGuard<'_, HostState> {
        self.st.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn limits(&self) -> JamLimits {
        *self.limits.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[cfg(test)]
    pub fn set_limits(&self, limits: JamLimits) {
        *self.limits.lock().unwrap_or_else(|e| e.into_inner()) = limits;
    }

    pub fn dirty(&self) {
        self.dirty.notify_one();
    }

    pub async fn wait_dirty(&self) {
        self.dirty.notified().await;
    }

    fn bump(&self) {
        self.changed.send_modify(|v| *v = v.wrapping_add(1));
    }

    pub fn running(&self) -> bool {
        self.state().running
    }

    /// The session key of a guest of the running Jam.
    pub fn key(&self, guest_id: &str) -> Option<[u8; 32]> {
        let st = self.state();
        if !st.running {
            return None;
        }
        st.guests.iter().find(|g| g.id == guest_id).map(|g| g.key)
    }

    /// Registers a guest's new session (a reconnect replaces the old one).
    fn attach(&self, guest_id: &str) -> Option<(u64, oneshot::Receiver<bool>)> {
        let attached = {
            let mut st = self.state();
            st.next_session += 1;
            let no = st.next_session;
            let running = st.running;
            st.guests
                .iter_mut()
                .find(|g| g.id == guest_id && running)
                .map(|g| {
                    let (tx, rx) = oneshot::channel();
                    g.session = Some((no, tx));
                    (no, rx)
                })
        };
        self.dirty();
        attached
    }

    fn detach(&self, guest_id: &str, no: u64) {
        {
            let mut st = self.state();
            if let Some(g) = st.guests.iter_mut().find(|g| g.id == guest_id)
                && g.session.as_ref().is_some_and(|(n, _)| *n == no)
            {
                g.session = None;
            }
        }
        self.dirty();
    }

    fn try_search(&self, guest_id: &str) -> Result<(), JamErrorCode> {
        let limits = self.limits();
        let mut st = self.state();
        if !st.running {
            return Err(JamErrorCode::JamEnded);
        }
        let g = st
            .guests
            .iter_mut()
            .find(|g| g.id == guest_id)
            .ok_or(JamErrorCode::JamEnded)?;
        if g.limits.try_search(Instant::now(), &limits) {
            Ok(())
        } else {
            Err(JamErrorCode::RateLimited)
        }
    }

    /// Appends `track_id` to the end of the queue for `guest_id` (blocking:
    /// reads the library and calls the player).
    fn add_blocking(
        &self,
        lib: &Library,
        player: &Player,
        guest_id: &str,
        track_id: i64,
    ) -> Result<(), JamErrorCode> {
        let _one_at_a_time = self.add_lock.lock().unwrap_or_else(|e| e.into_inner());
        let limits = self.limits();
        let now = Instant::now();
        let name = {
            let mut st = self.state();
            if !st.running {
                return Err(JamErrorCode::JamEnded);
            }
            let g = st
                .guests
                .iter_mut()
                .find(|g| g.id == guest_id)
                .ok_or(JamErrorCode::JamEnded)?;
            if !g.limits.allow_add(now, &limits) {
                return Err(JamErrorCode::RateLimited);
            }
            g.name.clone()
        };
        let row = lib
            .track_by_id(track_id)
            .ok()
            .flatten()
            .ok_or(JamErrorCode::NotFound)?;
        let (_, ahead) = player.up_next_page(0, usize::MAX);
        {
            let st = self.state();
            let from_guests = ahead
                .iter()
                .filter(|(_, t)| st.added_by.contains_key(&t.id.value()))
                .count();
            if from_guests >= limits.guest_songs_ahead {
                return Err(JamErrorCode::QueueFull);
            }
        }
        let track = crate::queue::Track {
            path: PathBuf::from(&row.path),
            title: Some(row.title.clone()),
            artist: Some(row.artist.clone()),
        };
        let snap = player.append(vec![track]).map_err(|e| {
            log::warn!("jam: adding a song failed: {e}");
            JamErrorCode::NotFound
        })?;
        // The new entry is the last one (unless something else was appended
        // in between; "added by" is then simply not shown).
        let entry = snap
            .queue_length
            .checked_sub(1)
            .and_then(|last| player.queue_page(last, 1).into_iter().next())
            .filter(|t| t.path == row.path)
            .map(|t| t.id.value());
        let live: HashSet<u64> = player
            .queue_page(0, usize::MAX)
            .into_iter()
            .map(|t| t.id.value())
            .collect();
        {
            let mut st = self.state();
            if let Some(g) = st.guests.iter_mut().find(|g| g.id == guest_id) {
                g.limits.record_add(now);
                g.added += 1;
            }
            st.added_by.retain(|id, _| live.contains(id));
            if let Some(id) = entry {
                st.added_by.insert(id, name.clone());
            }
            st.recent.push_front(JamRecent {
                title: clip(&row.title),
                artist: clip(&row.artist),
                added_by: name,
            });
            st.recent.truncate(MAX_RECENT);
        }
        self.dirty();
        self.bump();
        Ok(())
    }

    /// Ends the Jam: every guest key is dropped and their sessions close.
    fn end(&self) {
        let guests = {
            let mut st = self.state();
            st.running = false;
            st.added_by.clear();
            st.recent.clear();
            std::mem::take(&mut st.guests)
        };
        self.window.close();
        for g in guests {
            if let Some((_, close)) = g.session {
                let _ = close.send(false);
            }
        }
        self.dirty();
        self.bump();
    }
}

fn clip(s: &str) -> String {
    s.chars().take(MAX_TEXT_CHARS).collect()
}

/// The guests' view of the player (blocking: reads the library).
fn build_state(
    lib: &Library,
    player: &Player,
    host_name: String,
    added_by: &HashMap<u64, String>,
) -> JamState {
    let describe = |path: &str, title: &str, artist: &str| match lib.track_meta(path).ok().flatten()
    {
        Some(m) => (clip(&m.title), clip(&m.artist), m.duration_ms),
        None => (clip(title), clip(artist), None),
    };
    let snap = player.snapshot();
    let now_playing = snap.current.as_ref().map(|t| {
        let (title, artist, duration_ms) = describe(&t.path, &t.title, &t.artist);
        let playing_for = snap
            .duration_seconds
            .filter(|d| d.is_finite() && *d >= 0.0)
            .map(|d| (d * 1000.0) as u64);
        JamNowPlaying {
            title,
            artist,
            duration_ms: duration_ms.or(playing_for),
        }
    });
    let (_, rows) = player.up_next_page(0, MAX_UP_NEXT);
    let up_next = rows
        .into_iter()
        .map(|(_, t)| {
            let (title, artist, duration_ms) = describe(&t.path, &t.title, &t.artist);
            JamUpNext {
                title,
                artist,
                duration_ms,
                added_by: added_by.get(&t.id.value()).cloned(),
            }
        })
        .collect();
    JamState {
        host_name: clip(&host_name),
        now_playing,
        playing: snap.status == Status::Playing,
        up_next,
    }
}

// ---------------------------------------------------------------------------
// The guest-mode session
// ---------------------------------------------------------------------------

/// Clears the guest's session slot when the connection ends.
struct Detach {
    sh: Arc<Shared>,
    guest_id: String,
    no: u64,
}

impl Drop for Detach {
    fn drop(&mut self) {
        self.sh.jam.detach(&self.guest_id, self.no);
        self.sh.jam.live.send_modify(|n| *n = n.saturating_sub(1));
    }
}

/// Runs one guest's session until it ends: the guest leaves, its
/// connection fails, it sends anything but a `JamCmd`, the host removes it
/// or the Jam ends.
pub(in crate::sync) async fn serve(sh: Arc<Shared>, session: Session) {
    let guest_id = session.peer_id().to_owned();
    let Some((no, mut close)) = sh.jam.attach(&guest_id) else {
        return;
    };
    sh.jam.live.send_modify(|n| *n += 1);
    let _detach = Detach {
        sh: Arc::clone(&sh),
        guest_id: guest_id.clone(),
        no,
    };
    let (mut reader, writer) = session.into_split();
    reader.set_idle_timeout(Some(IDLE_TIMEOUT));
    let (in_tx, mut inbox) = mpsc::channel::<Result<JamCmd, String>>(8);
    let _reader = AbortOnDrop(tokio::spawn(async move {
        loop {
            let item = match reader.recv().await {
                Ok(bytes) => JamCmd::parse(&bytes),
                Err(e) => Err(e.to_string()),
            };
            let stop = item.is_err();
            if in_tx.send(item).await.is_err() || stop {
                break;
            }
        }
    }));
    let mut s = GuestSession {
        sh,
        guest_id,
        writer,
        limiter: RateLimiter::remote_commands(),
    };
    if let Err(e) = s.run(&mut inbox, &mut close).await {
        log::debug!("jam: a guest session ended: {e}");
    }
}

struct GuestSession {
    sh: Arc<Shared>,
    guest_id: String,
    writer: link::SessionWriter,
    limiter: RateLimiter,
}

impl GuestSession {
    async fn send(&mut self, msg: &JamMsg) -> Result<(), String> {
        self.writer
            .send(&msg.to_bytes())
            .await
            .map_err(|e| e.to_string())
    }

    async fn run(
        &mut self,
        inbox: &mut mpsc::Receiver<Result<JamCmd, String>>,
        close: &mut oneshot::Receiver<bool>,
    ) -> Result<(), String> {
        let mut state_rx = self.sh.feed.subscribe_state();
        let mut jam_rx = self.sh.jam.changed.subscribe();
        state_rx.mark_unchanged();
        jam_rx.mark_unchanged();
        let mut feed_alive = true;
        let mut pending = false;
        self.push_state(None).await?;
        let mut next_push = tokio::time::Instant::now() + PUSH_INTERVAL;
        loop {
            tokio::select! {
                item = inbox.recv() => match item {
                    Some(Ok(cmd)) => self.handle(cmd).await?,
                    Some(Err(e)) => return Err(e),
                    None => return Err("the connection closed".into()),
                },
                r = &mut *close => {
                    // Removed or the Jam ended: say so, then hang up. A
                    // dropped sender (a newer session took over) just ends.
                    if let Ok(removed) = r {
                        let _ = self.send(&JamMsg::JamEnded { removed }).await;
                    }
                    return Ok(());
                }
                r = state_rx.changed(), if feed_alive => match r {
                    Ok(()) => pending = true,
                    Err(_) => feed_alive = false,
                },
                _ = jam_rx.changed() => pending = true,
                _ = tokio::time::sleep_until(next_push), if pending => {
                    pending = false;
                    self.push_state(None).await?;
                    next_push = tokio::time::Instant::now() + PUSH_INTERVAL;
                }
            }
        }
    }

    async fn push_state(&mut self, id: Option<u32>) -> Result<(), String> {
        let Some(player) = self.sh.player.clone() else {
            return Err("no player".into());
        };
        let (host_name, added_by) = {
            let st = self.sh.jam.state();
            (st.host_name.clone(), st.added_by.clone())
        };
        let lib = Arc::clone(&self.sh.lib);
        let state = run_blocking(move || build_state(&lib, &player, host_name, &added_by)).await?;
        self.send(&JamMsg::JamState { id, state }).await
    }

    async fn handle(&mut self, cmd: JamCmd) -> Result<(), String> {
        let id = cmd.id();
        let refuse = |code| JamMsg::JamDone {
            id,
            error: Some(JamFailure { code }),
        };
        if !self.limiter.try_acquire() {
            return self.send(&refuse(JamErrorCode::RateLimited)).await;
        }
        match cmd {
            JamCmd::JamState { id } => self.push_state(Some(id)).await,
            JamCmd::JamSearch {
                id,
                query,
                offset,
                limit,
            } => {
                if let Err(code) = self.sh.jam.try_search(&self.guest_id) {
                    return self.send(&refuse(code)).await;
                }
                let lib = Arc::clone(&self.sh.lib);
                let page = run_blocking(move || {
                    lib.search_tracks_page(offset as u64, limit as u64, SortOrder::Artist, &query)
                })
                .await?;
                let reply = match page {
                    Ok(page) => JamMsg::JamResults {
                        id,
                        total: page.total,
                        items: page
                            .items
                            .into_iter()
                            .map(|t| JamTrack {
                                track_id: t.id,
                                title: clip(&t.title),
                                artist: clip(&t.artist),
                                album: clip(&t.album),
                                duration_ms: t.duration_ms,
                            })
                            .collect(),
                    },
                    Err(e) => {
                        log::warn!("jam: search failed: {e}");
                        JamMsg::JamResults {
                            id,
                            total: 0,
                            items: Vec::new(),
                        }
                    }
                };
                self.send(&reply).await
            }
            JamCmd::JamAdd { id, track_id } => {
                let result = match self.sh.player.clone() {
                    None => Err(JamErrorCode::JamEnded),
                    Some(player) => {
                        let (jam, lib) = (Arc::clone(&self.sh.jam), Arc::clone(&self.sh.lib));
                        let guest = self.guest_id.clone();
                        run_blocking(move || jam.add_blocking(&lib, &player, &guest, track_id))
                            .await?
                    }
                };
                self.send(&JamMsg::JamDone {
                    id,
                    error: result.err().map(|code| JamFailure { code }),
                })
                .await
            }
        }
    }
}

// ---------------------------------------------------------------------------
// The service's Jam commands (desktop)
// ---------------------------------------------------------------------------

impl SyncService {
    pub async fn jam_status(&self) -> Result<JamStatus, String> {
        jam_status(&self.sh).await
    }

    /// Settings › Experimental › Jam (host). Off ends a running Jam and
    /// refuses every Jam join and guest session.
    pub async fn jam_set_enabled(&self, on: bool) -> Result<JamStatus, String> {
        if on && !self.sh.server_capable {
            return Err("only a computer hosts a Jam".into());
        }
        // Off first, so no guest is admitted while the Jam ends.
        self.sh.jam.state().enabled = on;
        if !on {
            self.jam_end_inner().await;
        }
        self.sh.jam.dirty();
        self.jam_status().await
    }

    /// Starts a Jam with a fresh code. The listener starts if "Allow phone
    /// connections" is off, for the Jam's lifetime only.
    pub async fn jam_start(&self) -> Result<JamStatus, String> {
        if !self.sh.server_capable || self.sh.player.is_none() {
            return Err("only a computer hosts a Jam".into());
        }
        let (enabled, running) = {
            let st = self.sh.jam.state();
            (st.enabled, st.running)
        };
        if !enabled {
            return Err("turn on Jam in Settings first".into());
        }
        if running {
            return self.jam_status().await;
        }
        let host_name = self.sh.local_device().await?.name;
        if !self.server_running() {
            self.start_server().await?;
        }
        let started = {
            let mut st = self.sh.jam.state();
            if st.enabled && !st.running {
                self.sh.jam.window.open().map_err(|e| e.to_string())?;
                st.running = true;
                st.host_name = host_name;
                st.added_by.clear();
                st.recent.clear();
            }
            st.running
        };
        self.set_session_limit();
        if !started {
            // Switched off meanwhile.
            self.stop_server_if_unused().await;
            return Err("turn on Jam in Settings first".into());
        }
        log::info!("jam: started");
        self.sh.jam.dirty();
        self.sh.dirty();
        self.jam_status().await
    }

    pub async fn jam_end(&self) -> Result<JamStatus, String> {
        self.jam_end_inner().await;
        self.jam_status().await
    }

    pub(in crate::sync) async fn jam_end_inner(&self) {
        if !self.sh.jam.running() {
            return;
        }
        self.sh.jam.end();
        log::info!("jam: ended");
        // Let the guests hear "the Jam ended" before the listener may close.
        let mut live = self.sh.jam.live.subscribe();
        let _ = tokio::time::timeout(GOODBYE_TIMEOUT, live.wait_for(|n| *n == 0)).await;
        self.set_session_limit();
        self.stop_server_if_unused().await;
        self.sh.dirty();
    }

    /// A new code; the old one stops working at once (joined guests stay).
    pub async fn jam_new_code(&self) -> Result<JamStatus, String> {
        if !self.sh.jam.running() {
            return Err("no Jam is running".into());
        }
        self.sh.jam.window.open().map_err(|e| e.to_string())?;
        self.sh.jam.dirty();
        self.jam_status().await
    }

    /// Removes a guest: its key is dropped and its session closes.
    pub async fn jam_remove_guest(&self, id: &str) -> Result<JamStatus, String> {
        let guest = {
            let mut st = self.sh.jam.state();
            let i = st
                .guests
                .iter()
                .position(|g| g.id == id)
                .ok_or("no such guest")?;
            st.guests.remove(i)
        };
        if let Some((_, close)) = guest.session {
            let _ = close.send(true);
        }
        self.sh.jam.dirty();
        self.jam_status().await
    }

    /// The listener takes the Jam's guests on top of the phones while a
    /// Jam runs.
    fn set_session_limit(&self) {
        let extra = if self.sh.jam.running() {
            link::MAX_JAM_GUESTS
        } else {
            0
        };
        self.with_server(|h| h.set_session_limit(link::MAX_SESSIONS + extra));
    }

    #[cfg(test)]
    pub(in crate::sync) fn jam_host(&self) -> &JamHost {
        &self.sh.jam
    }
}

async fn jam_status(sh: &Arc<Shared>) -> Result<JamStatus, String> {
    let port = sh.listening_port();
    let (enabled, running, guests, recent) = {
        let st = sh.jam.state();
        (
            st.enabled,
            st.running,
            st.guests
                .iter()
                .map(|g| JamGuestInfo {
                    id: g.id.clone(),
                    name: g.name.clone(),
                    added: g.added,
                    connected: g.session.is_some(),
                })
                .collect(),
            st.recent.iter().cloned().collect(),
        )
    };
    let code = match sh.jam.window.status() {
        PairingStatus::Open { code, .. } if running => Some(code),
        _ => None,
    };
    let sockets: Vec<SocketAddr> = match (running, port) {
        (true, Some(port)) => run_blocking(lan_addresses)
            .await?
            .iter()
            .filter_map(|a| a.parse::<std::net::IpAddr>().ok())
            .map(|ip| SocketAddr::new(ip, port))
            .collect(),
        _ => Vec::new(),
    };
    let link = code
        .as_deref()
        .map(|c| pair_link::build_jam_link(c, &sockets));
    Ok(JamStatus {
        enabled,
        running,
        qr: link.as_deref().and_then(pair_link::qr),
        link,
        code,
        addresses: sockets.iter().map(SocketAddr::to_string).collect(),
        guests,
        recent,
    })
}

/// Emits `jam://status` whenever the host's Jam changed (coalesced).
pub(in crate::sync) async fn status_task(sh: Arc<Shared>) {
    loop {
        sh.jam.wait_dirty().await;
        if sh.is_closed() {
            return;
        }
        match jam_status(&sh).await {
            Ok(status) => sh.emit("jam://status", &status),
            Err(e) => log::warn!("jam: status unavailable: {e}"),
        }
    }
}

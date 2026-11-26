//! The phone's side of a Jam: join with the code, keep the guest session,
//! search the host's library and add songs. Separate from the sync client:
//! it has its own connection and never touches the phone's pairing or the
//! database (the guest key lives in memory until the guest leaves).

use super::{
    JamCmd, JamErrorCode, JamMsg, JamSearchPage, JamState, MAX_GUEST_NAME_CHARS, guest_name,
};
use crate::sync::conn::AbortOnDrop;
use crate::sync::link::{self, LinkError, LocalDevice, Session};
use crate::sync::service::{Shared, SyncService, pairing_display_name, parse_address};
use serde::Serialize;
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot, watch};

/// The guest's keep-alive (a `jamState` request).
const PING_EVERY: Duration = Duration::from_secs(20);
/// The host drops a silent guest after 60 s; so does the guest.
const IDLE_TIMEOUT: Duration = Duration::from_secs(60);
/// How long a search or add waits for the host's answer.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);
/// Reconnect tries after the connection dropped (Wi-Fi blip), 1 s doubling.
const RECONNECT_TRIES: u32 = 5;

/// What the phone's Jam screen shows (`jam_guest_status`, `jam://guest`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JamGuestStatus {
    pub enabled: bool,
    pub joined: bool,
    pub host_name: Option<String>,
    pub connecting: bool,
    pub error: Option<String>,
}

enum GuestCtl {
    Request {
        cmd: JamCmd,
        reply: oneshot::Sender<JamMsg>,
    },
}

struct Joined {
    host_name: String,
    ctl: mpsc::Sender<GuestCtl>,
    stop: watch::Sender<bool>,
}

#[derive(Default)]
struct GuestState {
    /// The Settings switch.
    enabled: bool,
    connecting: bool,
    joined: Option<Joined>,
    error: Option<String>,
    /// Bumped on every join and leave: an older join's task does not touch
    /// a newer one's state.
    generation: u64,
}

/// The phone's Jam state (memory only).
#[derive(Default)]
pub(in crate::sync) struct GuestRt {
    st: Mutex<GuestState>,
}

impl GuestRt {
    fn state(&self) -> MutexGuard<'_, GuestState> {
        self.st.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn status(&self) -> JamGuestStatus {
        let st = self.state();
        JamGuestStatus {
            enabled: st.enabled,
            joined: st.joined.is_some(),
            host_name: st.joined.as_ref().map(|j| j.host_name.clone()),
            connecting: st.connecting,
            error: st.error.clone(),
        }
    }
}

fn emit_status(sh: &Shared) {
    sh.emit("jam://guest", &sh.guest.status());
}

/// A fresh random guest id: `jam-` and 32 hex digits.
fn random_guest_id() -> Result<String, String> {
    let mut b = [0u8; 16];
    getrandom::fill(&mut b).map_err(|_| "no random numbers".to_owned())?;
    Ok(format!(
        "jam-{}",
        b.iter().map(|x| format!("{x:02x}")).collect::<String>()
    ))
}

/// What the user sees when a join fails.
fn join_error(e: &LinkError) -> String {
    match e {
        LinkError::PairingNotOpen => "No Jam is running on that computer".into(),
        LinkError::WrongCode => "Wrong Jam code".into(),
        LinkError::TooManyAttempts => "Wrong Jam code; the Jam has a new code now".into(),
        LinkError::JamFull => "The Jam is full".into(),
        LinkError::InvalidCode => "The Jam code has 6 digits".into(),
        other => other.to_string(),
    }
}

/// Worth trying the next address (another network adapter of the host).
fn unreachable(e: &LinkError) -> bool {
    matches!(
        e,
        LinkError::Io(_) | LinkError::Timeout | LinkError::Closed | LinkError::NotLocalAddress
    )
}

impl SyncService {
    pub fn jam_guest_status(&self) -> JamGuestStatus {
        self.sh.guest.status()
    }

    /// Settings › Experimental › Jam (guest). Off leaves a joined Jam.
    pub fn jam_guest_set_enabled(&self, on: bool) -> JamGuestStatus {
        if !on {
            self.jam_leave();
        }
        self.sh.guest.state().enabled = on;
        emit_status(&self.sh);
        self.jam_guest_status()
    }

    /// Joins the Jam at `address` (or, without one, at the computers the
    /// discovery finds) with its code.
    pub async fn jam_join(
        &self,
        address: Option<&str>,
        code: &str,
    ) -> Result<JamGuestStatus, String> {
        self.check_guest()?;
        let code = code.trim();
        let addrs = match address.map(str::trim).filter(|a| !a.is_empty()) {
            Some(a) => vec![parse_address(a)?],
            None => {
                let found = self.discover().await?;
                if found.is_empty() {
                    return Err("no computer found: type its address".into());
                }
                found
                    .iter()
                    .filter_map(|f| f.address.parse().ok())
                    .collect()
            }
        };
        self.join_any(addrs, code).await
    }

    /// Joins from a scanned Jam QR code.
    pub async fn jam_join_link(&self, link_text: &str) -> Result<JamGuestStatus, String> {
        self.check_guest()?;
        let parsed = crate::sync::pair_link::parse_jam_link(link_text)?;
        self.join_any(parsed.addresses, &parsed.code).await
    }

    /// Leaves the Jam (the host keeps the guest listed until it ends the
    /// Jam or removes it; the key stays only in the host's memory).
    pub fn jam_leave(&self) {
        let joined = {
            let mut st = self.sh.guest.state();
            st.generation += 1;
            st.connecting = false;
            st.error = None;
            st.joined.take()
        };
        if let Some(j) = joined {
            j.stop.send_replace(true);
            self.sh.emit("jam://state", &Option::<JamState>::None);
        }
        emit_status(&self.sh);
    }

    pub async fn jam_search(
        &self,
        query: &str,
        offset: usize,
        limit: usize,
    ) -> Result<JamSearchPage, String> {
        let cmd = JamCmd::JamSearch {
            id: 0,
            query: query.trim().to_owned(),
            offset,
            limit,
        };
        cmd.validate()?;
        match self.jam_request(cmd).await? {
            JamMsg::JamResults { total, items, .. } => Ok(JamSearchPage { total, items }),
            JamMsg::JamDone { error: Some(f), .. } => Err(f.code.message().into()),
            _ => Err("unexpected answer from the host".into()),
        }
    }

    /// Adds a song to the end of the host's queue.
    pub async fn jam_add(&self, track_id: i64) -> Result<(), String> {
        let cmd = JamCmd::JamAdd { id: 0, track_id };
        cmd.validate()?;
        match self.jam_request(cmd).await? {
            JamMsg::JamDone { error: None, .. } => Ok(()),
            JamMsg::JamDone { error: Some(f), .. } => Err(f.code.message().into()),
            _ => Err("unexpected answer from the host".into()),
        }
    }

    fn check_guest(&self) -> Result<(), String> {
        if self.sh.server_capable {
            return Err("only a phone joins a Jam".into());
        }
        if !self.sh.guest.state().enabled {
            return Err("turn on Jam in Settings first".into());
        }
        Ok(())
    }

    async fn jam_request(&self, cmd: JamCmd) -> Result<JamMsg, String> {
        let ctl = self
            .sh
            .guest
            .state()
            .joined
            .as_ref()
            .map(|j| j.ctl.clone())
            .ok_or("not in a Jam")?;
        let (reply, answer) = oneshot::channel();
        ctl.send(GuestCtl::Request { cmd, reply })
            .await
            .map_err(|_| "not connected to the Jam")?;
        tokio::time::timeout(REQUEST_TIMEOUT, answer)
            .await
            .map_err(|_| "the host did not answer".to_owned())?
            .map_err(|_| "the connection to the Jam closed".to_owned())
    }

    /// This phone as the host lists it: "Device · Profile" when the phone
    /// has several profiles.
    async fn guest_display_name(&self) -> Result<String, String> {
        let device = self.sh.local_device().await?.name;
        let profiles = self.sh.lib.profiles().map_err(|e| e.to_string())?;
        let active = self.sh.lib.active_profile();
        let name = match profiles.iter().find(|p| p.id == active) {
            Some(p) => pairing_display_name(&device, &p.name, profiles.len()),
            None => device,
        };
        // The host cuts it to 40 characters; keep the profile in view.
        if name.chars().count() > MAX_GUEST_NAME_CHARS {
            let profile = profiles
                .iter()
                .find(|p| p.id == active)
                .map(|p| p.name.clone())
                .unwrap_or_default();
            let room = MAX_GUEST_NAME_CHARS.saturating_sub(profile.chars().count() + 3);
            if profiles.len() > 1 && room >= 8 {
                let device: String = name.chars().take(room).collect();
                return Ok(guest_name(&format!(
                    "{} \u{b7} {profile}",
                    device.trim_end()
                )));
            }
        }
        Ok(guest_name(&name))
    }

    async fn join_any(&self, addrs: Vec<SocketAddr>, code: &str) -> Result<JamGuestStatus, String> {
        self.jam_leave();
        let generation = {
            let mut st = self.sh.guest.state();
            st.connecting = true;
            st.generation
        };
        emit_status(&self.sh);
        let result = self.try_join(&addrs, code, generation).await;
        if let Err(e) = &result {
            let mut st = self.sh.guest.state();
            if st.generation == generation {
                st.connecting = false;
                st.error = Some(e.clone());
            }
        }
        emit_status(&self.sh);
        result.map(|()| self.jam_guest_status())
    }

    async fn try_join(
        &self,
        addrs: &[SocketAddr],
        code: &str,
        generation: u64,
    ) -> Result<(), String> {
        let local = LocalDevice {
            id: random_guest_id()?,
            name: self.guest_display_name().await?,
        };
        let mut last = "the computer did not answer".to_owned();
        for &addr in addrs {
            let paired = match link::jam_join(addr, &local, code).await {
                Ok(p) => p,
                Err(e) if unreachable(&e) => {
                    last = e.to_string();
                    continue;
                }
                // Discovery may list a computer without a Jam: try the next.
                Err(e @ LinkError::PairingNotOpen) if addrs.len() > 1 => {
                    last = join_error(&e);
                    continue;
                }
                Err(e) => return Err(join_error(&e)),
            };
            let session = link::connect(addr, &local.id, &paired.secret)
                .await
                .map_err(|e| join_error(&e))?;
            let (ctl, ctl_rx) = mpsc::channel(16);
            let (stop, stop_rx) = watch::channel(false);
            {
                let mut st = self.sh.guest.state();
                if st.generation != generation {
                    // Left (or joined again) meanwhile.
                    return Err("cancelled".into());
                }
                st.connecting = false;
                st.error = None;
                st.joined = Some(Joined {
                    host_name: paired.peer_name.clone(),
                    ctl,
                    stop,
                });
            }
            log::info!("jam: joined");
            let link = Reconnect {
                addr,
                id: local.id.clone(),
                key: paired.secret,
            };
            tokio::spawn(guest_loop(
                Arc::clone(&self.sh),
                generation,
                session,
                link,
                ctl_rx,
                stop_rx,
            ));
            return Ok(());
        }
        Err(last)
    }
}

/// How to open the guest session again after a drop.
struct Reconnect {
    addr: SocketAddr,
    id: String,
    key: [u8; 32],
}

/// How one guest session ended.
enum End {
    /// The user left (or joined another Jam).
    Left,
    /// The host ended the Jam or removed this guest.
    ByHost { removed: bool },
    /// The connection failed.
    Failed(String),
}

/// Keeps the guest session: runs it, reconnects a few times after a drop,
/// and reports the end.
async fn guest_loop(
    sh: Arc<Shared>,
    generation: u64,
    mut session: Session,
    link: Reconnect,
    mut ctl: mpsc::Receiver<GuestCtl>,
    mut stop: watch::Receiver<bool>,
) {
    let end = loop {
        let end = run_session(&sh, session, &mut ctl, &mut stop).await;
        let End::Failed(e) = end else { break end };
        log::info!("jam: connection to the host dropped: {e}");
        set_connecting(&sh, generation, true);
        let mut wait = Duration::from_secs(1);
        let mut again = None;
        let mut last = e;
        for _ in 0..RECONNECT_TRIES {
            tokio::select! {
                _ = tokio::time::sleep(wait) => {}
                _ = stop.changed() => break,
            }
            if *stop.borrow() {
                break;
            }
            match link::connect(link.addr, &link.id, &link.key).await {
                Ok(s) => {
                    again = Some(s);
                    break;
                }
                // The host no longer knows the key: the Jam ended.
                Err(LinkError::HandshakeFailed) => {
                    last = JamErrorCode::JamEnded.message().into();
                    break;
                }
                Err(e) => last = e.to_string(),
            }
            wait *= 2;
        }
        if *stop.borrow() {
            break End::Left;
        }
        match again {
            Some(s) => {
                set_connecting(&sh, generation, false);
                session = s;
            }
            None => break End::Failed(last),
        }
    };
    let error = match end {
        End::Left => return,
        End::ByHost { removed: true } => "The host removed you from the Jam".to_owned(),
        End::ByHost { removed: false } => JamErrorCode::JamEnded.message().to_owned(),
        End::Failed(e) => e,
    };
    {
        let mut st = sh.guest.state();
        if st.generation != generation {
            return;
        }
        st.generation += 1;
        st.joined = None;
        st.connecting = false;
        st.error = Some(error);
    }
    sh.emit("jam://state", &Option::<JamState>::None);
    emit_status(&sh);
}

fn set_connecting(sh: &Shared, generation: u64, on: bool) {
    {
        let mut st = sh.guest.state();
        if st.generation != generation {
            return;
        }
        st.connecting = on;
    }
    emit_status(sh);
}

async fn run_session(
    sh: &Shared,
    session: Session,
    ctl: &mut mpsc::Receiver<GuestCtl>,
    stop: &mut watch::Receiver<bool>,
) -> End {
    let (mut reader, mut writer) = session.into_split();
    reader.set_idle_timeout(Some(IDLE_TIMEOUT));
    let (in_tx, mut inbox) = mpsc::channel::<Result<JamMsg, String>>(16);
    let _reader = AbortOnDrop(tokio::spawn(async move {
        loop {
            let item = match reader.recv().await {
                Ok(bytes) => JamMsg::parse(&bytes),
                Err(e) => Err(e.to_string()),
            };
            let end = item.is_err();
            if in_tx.send(item).await.is_err() || end {
                break;
            }
        }
    }));
    let mut pending: HashMap<u32, oneshot::Sender<JamMsg>> = HashMap::new();
    let mut next_id: u32 = 1;
    let mut take_id = || {
        let id = next_id;
        next_id = next_id.wrapping_add(1).max(1);
        id
    };
    let mut ping = tokio::time::interval_at(tokio::time::Instant::now() + PING_EVERY, PING_EVERY);
    loop {
        let out = tokio::select! {
            item = inbox.recv() => match item {
                Some(Ok(JamMsg::JamEnded { removed })) => return End::ByHost { removed },
                Some(Ok(msg)) => {
                    let id = match &msg {
                        JamMsg::JamState { id, state } => {
                            sh.emit("jam://state", state);
                            *id
                        }
                        JamMsg::JamResults { id, .. } | JamMsg::JamDone { id, .. } => Some(*id),
                        JamMsg::JamEnded { .. } => None,
                    };
                    if let Some(reply) = id.and_then(|id| pending.remove(&id)) {
                        let _ = reply.send(msg);
                    }
                    continue;
                }
                Some(Err(e)) => return End::Failed(e),
                None => return End::Failed("the connection closed".into()),
            },
            c = ctl.recv() => match c {
                Some(GuestCtl::Request { cmd, reply }) => {
                    let id = take_id();
                    pending.retain(|_, r| !r.is_closed());
                    pending.insert(id, reply);
                    cmd.with_id(id)
                }
                None => return End::Left,
            },
            _ = ping.tick() => JamCmd::JamState { id: take_id() },
            _ = stop.changed() => return End::Left,
        };
        if let Err(e) = writer.send(&out.to_bytes()).await {
            return End::Failed(e.to_string());
        }
    }
}

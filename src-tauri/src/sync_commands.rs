//! Tauri commands and event sink for PC <-> phone sync and the remote
//! (docs/SYNC.md). Thin wrappers around [`SyncService`]; small payloads only.

use crate::player::Player;
use crate::session::SessionStore;
use neomodern_core::sync::EventSink;
use neomodern_core::sync::jam::JamSearchPage;
use neomodern_core::sync::jam::guest::JamGuestStatus;
use neomodern_core::sync::jam::host::JamStatus;
use neomodern_core::sync::remote::{QueuePage, RemoteCmd, RemoteState};
use neomodern_core::sync::service::{FoundComputerInfo, PairingOpen, SyncService, SyncStatus};
use std::sync::Arc;
use tauri::State;

/// Sends sync service events to the app's windows.
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

type Res<T> = Result<T, String>;

#[tauri::command]
pub async fn sync_status(sync: State<'_, SyncService>) -> Res<SyncStatus> {
    sync.status().await
}

/// Desktop: "Allow phone connections" (persisted; off by default).
#[tauri::command]
pub async fn sync_set_allow_phone_connections(
    sync: State<'_, SyncService>,
    store: State<'_, Arc<SessionStore>>,
    player: State<'_, Arc<Player>>,
    enabled: bool,
) -> Res<SyncStatus> {
    let status = sync.set_allow_phone_connections(enabled).await?;
    store.set_allow_phone_connections(enabled);
    store.save_now(&player.export_session());
    Ok(status)
}

#[tauri::command]
pub async fn sync_set_device_name(sync: State<'_, SyncService>, name: String) -> Res<SyncStatus> {
    sync.set_device_name(&name).await
}

/// Desktop: shows a pairing code (valid 2 minutes).
#[tauri::command]
pub async fn sync_pair_open(sync: State<'_, SyncService>) -> Res<PairingOpen> {
    sync.pair_open().await
}

#[tauri::command]
pub async fn sync_pair_close(sync: State<'_, SyncService>) -> Res<SyncStatus> {
    sync.pair_close();
    sync.status().await
}

/// Unpairs a device and closes its session.
#[tauri::command]
pub async fn sync_remove_peer(sync: State<'_, SyncService>, peer_id: String) -> Res<SyncStatus> {
    sync.remove_peer(&peer_id).await
}

/// Phone: pairs with the computer at `address` (`ip` or `ip:port`).
#[tauri::command]
pub async fn sync_connect_pair(
    sync: State<'_, SyncService>,
    address: String,
    code: String,
) -> Res<SyncStatus> {
    sync.connect_pair(&address, &code).await
}

/// Phone: pairs with the computer from its scanned QR code (K23).
#[tauri::command]
pub async fn sync_connect_pair_link(sync: State<'_, SyncService>, link: String) -> Res<SyncStatus> {
    sync.connect_pair_link(&link).await
}

/// Phone: computers on the local network that allow phone connections
/// (takes about 1.5 s; an empty list when none answered).
#[tauri::command]
pub async fn sync_discover(sync: State<'_, SyncService>) -> Res<Vec<FoundComputerInfo>> {
    sync.discover().await
}

#[tauri::command]
pub async fn sync_now(sync: State<'_, SyncService>) -> Res<SyncStatus> {
    sync.sync_now().await
}

/// Phone: forgets the paired computer.
#[tauri::command]
pub async fn sync_forget(sync: State<'_, SyncService>) -> Res<SyncStatus> {
    sync.forget().await
}

/// The answer to "Apply / Skip" after the mass-delete guard stopped a sync.
#[tauri::command]
pub async fn sync_guard_decide(
    sync: State<'_, SyncService>,
    peer_id: String,
    apply: bool,
) -> Res<SyncStatus> {
    sync.guard_decide(&peer_id, apply).await
}

/// Phone: one remote-control command to the computer.
#[tauri::command]
pub async fn remote_send(sync: State<'_, SyncService>, cmd: RemoteCmd) -> Res<()> {
    sync.remote_send(cmd).await
}

#[tauri::command]
pub async fn remote_queue_page(
    sync: State<'_, SyncService>,
    offset: usize,
    limit: usize,
) -> Res<QueuePage> {
    sync.remote_queue_page(offset, limit).await
}

/// Phone: the computer's last known player state (`None` when not
/// connected).
#[tauri::command]
pub async fn remote_state(sync: State<'_, SyncService>) -> Res<Option<RemoteState>> {
    Ok(sync.remote_state())
}

/// This device's cover for a song key (load it with `convertFileSrc`).
#[tauri::command]
pub async fn sync_cover_for_key(sync: State<'_, SyncService>, key: String) -> Res<Option<String>> {
    sync.cover_for_key(&key).await
}

// --- Local Jam (K27, docs/JAM.md) -------------------------------------------

/// Desktop: the Jam panel's status.
#[tauri::command]
pub async fn jam_status(sync: State<'_, SyncService>) -> Res<JamStatus> {
    sync.jam_status().await
}

/// Desktop: Settings › Experimental › Jam (persisted; off by default). Off
/// ends a running Jam.
#[tauri::command]
pub async fn jam_set_enabled(
    sync: State<'_, SyncService>,
    store: State<'_, Arc<SessionStore>>,
    player: State<'_, Arc<Player>>,
    enabled: bool,
) -> Res<JamStatus> {
    let status = sync.jam_set_enabled(enabled).await?;
    store.set_jam_enabled(enabled);
    store.save_now(&player.export_session());
    Ok(status)
}

#[tauri::command]
pub async fn jam_start(sync: State<'_, SyncService>) -> Res<JamStatus> {
    sync.jam_start().await
}

#[tauri::command]
pub async fn jam_end(sync: State<'_, SyncService>) -> Res<JamStatus> {
    sync.jam_end().await
}

#[tauri::command]
pub async fn jam_new_code(sync: State<'_, SyncService>) -> Res<JamStatus> {
    sync.jam_new_code().await
}

#[tauri::command]
pub async fn jam_remove_guest(sync: State<'_, SyncService>, id: String) -> Res<JamStatus> {
    sync.jam_remove_guest(&id).await
}

/// Phone: the guest screen's status.
#[tauri::command]
pub async fn jam_guest_status(sync: State<'_, SyncService>) -> Res<JamGuestStatus> {
    Ok(sync.jam_guest_status())
}

/// Phone: Settings › Experimental › Jam (persisted; off by default). Off
/// leaves a joined Jam.
#[tauri::command]
pub async fn jam_guest_set_enabled(
    sync: State<'_, SyncService>,
    store: State<'_, Arc<SessionStore>>,
    player: State<'_, Arc<Player>>,
    enabled: bool,
) -> Res<JamGuestStatus> {
    let status = sync.jam_guest_set_enabled(enabled);
    store.set_jam_guest_enabled(enabled);
    store.save_now(&player.export_session());
    Ok(status)
}

/// Phone: joins with the typed code; without an address, at the computers
/// the discovery finds.
#[tauri::command]
pub async fn jam_join(
    sync: State<'_, SyncService>,
    address: Option<String>,
    code: String,
) -> Res<JamGuestStatus> {
    sync.jam_join(address.as_deref(), &code).await
}

/// Phone: joins from a scanned Jam QR code.
#[tauri::command]
pub async fn jam_join_link(sync: State<'_, SyncService>, link: String) -> Res<JamGuestStatus> {
    sync.jam_join_link(&link).await
}

#[tauri::command]
pub async fn jam_leave(sync: State<'_, SyncService>) -> Res<()> {
    sync.jam_leave();
    Ok(())
}

/// Phone: searches the host's library (at most 30 per page).
#[tauri::command]
pub async fn jam_search(
    sync: State<'_, SyncService>,
    query: String,
    offset: usize,
    limit: usize,
) -> Res<JamSearchPage> {
    sync.jam_search(&query, offset, limit).await
}

/// Phone: adds a song to the end of the host's queue; the error is the text
/// to show.
#[tauri::command]
pub async fn jam_add(sync: State<'_, SyncService>, track_id: i64) -> Res<()> {
    sync.jam_add(track_id).await
}

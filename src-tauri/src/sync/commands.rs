//! Tauri commands of PC <-> phone sync and the remote (docs/SYNC.md).
//! Thin wrappers around [`SyncService`]; small payloads only.

use super::remote::{QueuePage, RemoteCmd, RemoteState};
use super::service::{PairingOpen, SyncService, SyncStatus};
use crate::player::Player;
use crate::session::SessionStore;
use std::sync::Arc;
use tauri::State;

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

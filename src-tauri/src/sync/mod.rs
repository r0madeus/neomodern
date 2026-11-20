//! PC <-> phone sync and remote control (decision K21, `docs/SYNC.md`).
//!
//! - `store/` – the replicated data model (pure SQLite);
//! - `link/` – pairing, encrypted sessions, sockets;
//! - `pair_link` – the pairing QR code (K23);
//! - `protocol` – the messages inside a session;
//! - `conn` – one session's event loop (sync rounds, remote, keep-alive);
//! - `remote` – remote-control commands and the player state the phone sees;
//! - `service` – the service the app manages; `commands` – its Tauri
//!   commands.

pub mod commands;
mod conn;
pub mod link;
pub mod pair_link;
pub mod protocol;
pub mod remote;
pub mod service;
pub mod store;

#[cfg(test)]
mod service_tests;

pub use remote::RemoteFeed;
pub use service::{SyncConfig, SyncService, TauriSink, default_device_name};

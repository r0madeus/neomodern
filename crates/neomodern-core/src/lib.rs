pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub mod audio;
pub mod autoplay;
pub mod backup;
pub mod diagnostics;
pub mod library;
pub mod lyrics;
#[cfg(not(target_os = "android"))]
pub mod media_keys;
pub mod metadata;
pub mod net;
#[cfg(feature = "legacy-online")]
pub mod online;
pub mod player;
pub mod queue;
pub mod session;
pub mod source_provider;
// PC <-> phone sync and remote control (docs/SYNC.md).
pub mod sync;
pub mod update;

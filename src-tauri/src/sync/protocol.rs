//! The messages two paired devices exchange inside an encrypted session
//! (docs/SYNC.md, "Wire protocol"). Each message is one JSON object with a
//! `type` tag; unknown types and unknown fields are refused, so the remote
//! surface is exactly this closed list.

use super::remote::{QueuePage, RemoteCmd, RemoteFailure, RemoteState};
use super::store::{self, Batch, Plan};
use serde::{Deserialize, Serialize};

/// Version of the sync payload (these messages and the batch format). Both
/// sides must use the same one; a mismatch stops with "update the app".
pub const SYNC_VERSION: u32 = 1;

/// Largest serialised message this side sends. The link carries up to
/// 1 MiB; the margin covers the JSON envelope.
pub const SEND_LIMIT: usize = 960 * 1024;

/// Longest app version string accepted in `Hello` / `Welcome`.
const MAX_VERSION_CHARS: usize = 64;
/// Longest free-text message accepted in `Error`.
const MAX_MESSAGE_CHARS: usize = 500;
/// Playlist names listed in a guard summary (the counts are always exact).
const MAX_SUMMARY_NAMES: usize = 20;

// Variants without data are written `{}`: serde ignores unknown fields
// next to the tag of a unit variant, even with `deny_unknown_fields`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum Msg {
    /// Client → server, first message of every session.
    Hello {
        sync_version: u32,
        app_version: String,
        device_name: String,
    },
    /// Server → client, the answer to `Hello`.
    Welcome {
        sync_version: u32,
        app_version: String,
        device_name: String,
    },
    /// Client → server: a sync round starts (the client's pages follow).
    /// Server → client: please start a round (e.g. after the user approved
    /// a stopped sync on the computer).
    SyncOffer {},
    /// One page of changes; the receiver answers `SyncAck` or `Error`.
    SyncBatch {
        batch: Batch,
    },
    /// The page up to `upto_seq` is applied: the sender moves its watermark.
    SyncAck {
        upto_seq: i64,
    },
    /// The sender has no more pages for this round: the other direction
    /// starts (client → server), or the round is over (server → client).
    SyncDone {},
    /// Phone → computer remote-control command; answered by `RemoteDone`
    /// (or `Queue` for `queuePage`) with the same id.
    Remote {
        id: u32,
        cmd: RemoteCmd,
    },
    RemoteDone {
        id: u32,
        error: Option<RemoteFailure>,
    },
    Queue {
        id: u32,
        page: QueuePage,
    },
    /// Computer → phone: what is playing (on connect and on every change).
    State {
        state: RemoteState,
    },
    /// Computer → phone: playback position, at most 4 per second.
    Position {
        seconds: f64,
        duration: Option<f64>,
    },
    Ping {},
    Pong {},
    Error {
        code: ErrorCode,
        message: String,
        /// For `mass_delete`: what the batch would have removed.
        summary: Option<GuardSummary>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    /// Different `sync_version`: update the app on one device.
    Version,
    /// The mass-delete guard stopped the page; the user decides on the
    /// receiving device. Nothing was applied.
    MassDelete,
    /// The page (or message) failed validation. Nothing was applied.
    Invalid,
    /// The receiver's database failed its integrity check; it stops
    /// syncing with this peer until the app restarts.
    Integrity,
    /// Anything else (e.g. a database error); nothing was applied.
    Failed,
}

/// What a page stopped by the mass-delete guard would have removed, for
/// the "Apply / Skip" question. Small: names are capped.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GuardSummary {
    pub favorites_turned_off: usize,
    pub local_favorites: usize,
    pub playlists_deleted: usize,
    pub playlist_names: Vec<String>,
    /// Playlists losing many songs: (name, removed, total).
    pub songs_removed: Vec<SongLoss>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SongLoss {
    pub name: String,
    pub removed: usize,
    pub total: usize,
}

impl GuardSummary {
    pub fn from_plan(plan: &Plan) -> Self {
        Self {
            favorites_turned_off: plan.favorites_turned_off,
            local_favorites: plan.local_favorites,
            playlists_deleted: plan.playlists_deleted.len(),
            playlist_names: plan
                .playlists_deleted
                .iter()
                .take(MAX_SUMMARY_NAMES)
                .cloned()
                .collect(),
            songs_removed: plan
                .songs_removed
                .iter()
                .take(MAX_SUMMARY_NAMES)
                .map(|l| SongLoss {
                    name: l.name.clone(),
                    removed: l.removed,
                    total: l.total,
                })
                .collect(),
        }
    }

    fn valid(&self) -> bool {
        self.playlist_names.len() <= MAX_SUMMARY_NAMES
            && self.songs_removed.len() <= MAX_SUMMARY_NAMES
            && self
                .playlist_names
                .iter()
                .chain(self.songs_removed.iter().map(|l| &l.name))
                .all(|n| n.chars().count() <= store::MAX_NAME_CHARS)
    }
}

impl Msg {
    /// Parses and validates one received message.
    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        let msg: Self = serde_json::from_slice(bytes).map_err(|e| format!("bad message: {e}"))?;
        msg.validate()?;
        Ok(msg)
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        // Serialising these types cannot fail (no maps with non-string
        // keys, no custom serialisers).
        serde_json::to_vec(self).unwrap_or_default()
    }

    fn validate(&self) -> Result<(), String> {
        match self {
            Self::Hello {
                app_version,
                device_name,
                ..
            }
            | Self::Welcome {
                app_version,
                device_name,
                ..
            } => {
                if app_version.chars().count() > MAX_VERSION_CHARS
                    || !super::link::valid_device_name(device_name)
                {
                    return Err("bad hello".into());
                }
            }
            Self::SyncBatch { batch } => {
                store::check_batch(batch).map_err(|e| e.to_string())?;
            }
            Self::Remote { cmd, .. } => cmd.validate().map_err(str::to_owned)?,
            Self::RemoteDone {
                error: Some(failure),
                ..
            } => {
                if failure.message.chars().count() > MAX_MESSAGE_CHARS {
                    return Err("message too long".into());
                }
            }
            Self::Queue { page, .. } => page.validate().map_err(str::to_owned)?,
            Self::State { state } => state.validate().map_err(str::to_owned)?,
            Self::Position { seconds, duration } => {
                if !seconds.is_finite() || duration.is_some_and(|d| !d.is_finite()) {
                    return Err("bad position".into());
                }
            }
            Self::Error {
                message, summary, ..
            } => {
                if message.chars().count() > MAX_MESSAGE_CHARS
                    || summary.as_ref().is_some_and(|s| !s.valid())
                {
                    return Err("bad error message".into());
                }
            }
            Self::SyncOffer {}
            | Self::SyncAck { .. }
            | Self::SyncDone {}
            | Self::RemoteDone { error: None, .. }
            | Self::Ping {}
            | Self::Pong {} => {}
        }
        Ok(())
    }

    pub fn error(code: ErrorCode, message: impl Into<String>) -> Self {
        let message: String = message.into();
        Self::Error {
            code,
            message: message.chars().take(MAX_MESSAGE_CHARS).collect(),
            summary: None,
        }
    }
}

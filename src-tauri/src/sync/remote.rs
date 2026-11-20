//! Remote control: the phone shows what the computer plays and controls it
//! (docs/SYNC.md, goal 2).
//!
//! The command set is a closed enum; every command calls the same
//! [`Player`] method the computer's own Tauri command uses, so behaviour
//! matches and there is still one queue only. Queue entries are addressed
//! by index plus the queue version; a stale version is refused.

use super::store::track_key;
use crate::library::Library;
use crate::player::{Player, PlayerEvent, PlayerSnapshot, Status};
use crate::queue::RepeatMode;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::watch;

/// Most queue entries one `queuePage` returns.
pub const MAX_QUEUE_PAGE: usize = 100;
/// Positions beyond this (seconds) are not real tracks.
const MAX_SECONDS: f64 = 1.0e7;
/// Queue indexes/offsets beyond this are refused outright.
const MAX_INDEX: usize = 10_000_000;
const MAX_TEXT_BYTES: usize = 1024;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum RemoteCmd {
    // `{}`: see `protocol::Msg` (unknown fields must be refused).
    TogglePause {},
    Play {},
    Pause {},
    Next {},
    Previous {},
    Seek {
        seconds: f64,
    },
    SetVolume {
        percent: f64,
    },
    SetShuffle {
        on: bool,
    },
    SetRepeat {
        mode: RepeatMode,
    },
    PlayIndex {
        index: usize,
        queue_version: u64,
    },
    QueuePage {
        offset: usize,
        limit: usize,
    },
    /// The songs after the current one in play order (shuffle applied):
    /// `offset` counts from the next song; entries keep their queue index.
    UpNextPage {
        offset: usize,
        limit: usize,
    },
}

impl RemoteCmd {
    pub fn validate(&self) -> Result<(), &'static str> {
        match *self {
            Self::Seek { seconds }
                if !(seconds.is_finite() && (0.0..=MAX_SECONDS).contains(&seconds)) =>
            {
                Err("seek position out of range")
            }
            Self::SetVolume { percent }
                if !(percent.is_finite() && (0.0..=100.0).contains(&percent)) =>
            {
                Err("volume out of range")
            }
            Self::PlayIndex { index, .. } if index > MAX_INDEX => Err("index out of range"),
            Self::QueuePage { offset, limit } | Self::UpNextPage { offset, limit }
                if offset > MAX_INDEX || limit == 0 || limit > MAX_QUEUE_PAGE =>
            {
                Err("queue page out of range")
            }
            _ => Ok(()),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RemoteErrorCode {
    /// More than 20 commands per second.
    RateLimited,
    /// `playIndex` with an old queue version: reload the queue.
    StaleQueue,
    Invalid,
    /// The player refused (e.g. index out of range).
    Failed,
    /// This device does not take remote commands.
    Unsupported,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RemoteFailure {
    pub code: RemoteErrorCode,
    pub message: String,
}

impl RemoteFailure {
    pub fn new(code: RemoteErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RemoteStatus {
    Playing,
    Paused,
    Stopped,
}

/// The computer's current song, as the phone shows it. `key` lets the
/// phone find its own copy (and cover) of the same song.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RemoteTrack {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration: Option<f64>,
    pub key: String,
}

/// A small summary of the computer's player (derived from
/// [`PlayerSnapshot`]).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RemoteState {
    pub status: RemoteStatus,
    pub current: Option<RemoteTrack>,
    pub current_index: Option<usize>,
    pub queue_length: usize,
    pub queue_version: u64,
    pub volume: f64,
    pub shuffle: bool,
    pub repeat: RepeatMode,
    pub position: f64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct QueueEntry {
    pub index: usize,
    pub title: String,
    pub artist: String,
    pub key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct QueuePage {
    pub offset: usize,
    /// The whole queue's length.
    pub total: usize,
    /// Use this with `playIndex`.
    pub queue_version: u64,
    pub entries: Vec<QueueEntry>,
}

fn text_ok(s: &str) -> bool {
    s.len() <= MAX_TEXT_BYTES
}

impl RemoteState {
    pub fn validate(&self) -> Result<(), &'static str> {
        let floats_ok = self.volume.is_finite()
            && self.position.is_finite()
            && self
                .current
                .as_ref()
                .is_none_or(|c| c.duration.is_none_or(f64::is_finite));
        let text = self.current.as_ref().is_none_or(|c| {
            text_ok(&c.title)
                && text_ok(&c.artist)
                && text_ok(&c.album)
                && c.key.len() <= 4 * MAX_TEXT_BYTES
        });
        if floats_ok && text {
            Ok(())
        } else {
            Err("bad remote state")
        }
    }
}

impl QueuePage {
    pub fn validate(&self) -> Result<(), &'static str> {
        let ok = self.entries.len() <= MAX_QUEUE_PAGE
            && self.entries.iter().all(|e| {
                text_ok(&e.title) && text_ok(&e.artist) && e.key.len() <= 4 * MAX_TEXT_BYTES
            });
        if ok { Ok(()) } else { Err("bad queue page") }
    }
}

/// Title, artist, album and key of the song at `path`: the library's tags
/// when the file is in the library (so the key matches what the phone
/// computes), else what the queue knows.
fn describe(
    lib: &Library,
    path: &str,
    title: &str,
    artist: &str,
) -> (String, String, String, String) {
    let (title, artist, album) = match lib.track_meta(path).ok().flatten() {
        Some(m) => (m.title, m.artist, m.album),
        None => (title.to_owned(), artist.to_owned(), String::new()),
    };
    let key = track_key(&artist, &album, &title);
    (title, artist, album, key)
}

/// Builds the remote state (blocking: reads the library).
pub fn derive_state(lib: &Library, snap: &PlayerSnapshot) -> RemoteState {
    let current = snap.current.as_ref().map(|t| {
        let (title, artist, album, key) = describe(lib, &t.path, &t.title, &t.artist);
        RemoteTrack {
            title,
            artist,
            album,
            duration: snap.duration_seconds.filter(|d| d.is_finite()),
            key,
        }
    });
    RemoteState {
        status: match snap.status {
            Status::Playing => RemoteStatus::Playing,
            Status::Paused => RemoteStatus::Paused,
            Status::Stopped => RemoteStatus::Stopped,
        },
        current,
        current_index: snap.current_index,
        queue_length: snap.queue_length,
        queue_version: snap.queue_version,
        volume: if snap.volume.is_finite() {
            snap.volume
        } else {
            100.0
        },
        shuffle: snap.shuffle,
        repeat: snap.repeat,
        position: if snap.position_seconds.is_finite() {
            snap.position_seconds
        } else {
            0.0
        },
    }
}

/// Runs one validated command on the computer's player (blocking). Returns
/// the page for `queuePage`.
pub fn execute(
    player: &Player,
    lib: &Library,
    cmd: &RemoteCmd,
) -> Result<Option<QueuePage>, RemoteFailure> {
    cmd.validate()
        .map_err(|m| RemoteFailure::new(RemoteErrorCode::Invalid, m))?;
    let failed =
        |e: crate::player::PlayerError| RemoteFailure::new(RemoteErrorCode::Failed, e.to_string());
    match *cmd {
        RemoteCmd::TogglePause {} => player.toggle_pause().map_err(failed)?,
        RemoteCmd::Play {} => player.play().map_err(failed)?,
        RemoteCmd::Pause {} => player.pause().map_err(failed)?,
        RemoteCmd::Next {} => player.next().map_err(failed)?,
        RemoteCmd::Previous {} => player.previous().map_err(failed)?,
        RemoteCmd::Seek { seconds } => player.seek(seconds).map_err(failed)?,
        RemoteCmd::SetVolume { percent } => player.set_volume(percent).map_err(failed)?,
        RemoteCmd::SetShuffle { on } => player.set_shuffle(on).map_err(failed)?,
        RemoteCmd::SetRepeat { mode } => player.set_repeat(mode).map_err(failed)?,
        RemoteCmd::PlayIndex {
            index,
            queue_version,
        } => {
            // The check and the jump are two player calls; a queue change
            // in between is as harmless as a click on the computer.
            let (current_version, _, _) = player.progress_state();
            if current_version != queue_version {
                return Err(RemoteFailure::new(
                    RemoteErrorCode::StaleQueue,
                    "the queue changed; reload it",
                ));
            }
            player.play_index(index).map_err(failed)?
        }
        RemoteCmd::UpNextPage { offset, limit } => {
            let (queue_version, _, _) = player.progress_state();
            let (total, rows) = player.up_next_page(offset, limit.min(MAX_QUEUE_PAGE));
            let entries = rows
                .into_iter()
                .map(|(index, t)| {
                    let (title, artist, _, key) = describe(lib, &t.path, &t.title, &t.artist);
                    QueueEntry {
                        index,
                        title,
                        artist,
                        key,
                    }
                })
                .collect();
            return Ok(Some(QueuePage {
                offset,
                total,
                queue_version,
                entries,
            }));
        }
        RemoteCmd::QueuePage { offset, limit } => {
            // Version first: if the queue changes before the page is read,
            // the phone holds an old version and `playIndex` is refused.
            let (queue_version, _, _) = player.progress_state();
            let total = player.snapshot().queue_length;
            let entries = player
                .queue_page(offset, limit.min(MAX_QUEUE_PAGE))
                .into_iter()
                .enumerate()
                .map(|(i, t)| {
                    let (title, artist, _, key) = describe(lib, &t.path, &t.title, &t.artist);
                    QueueEntry {
                        index: offset + i,
                        title,
                        artist,
                        key,
                    }
                })
                .collect();
            return Ok(Some(QueuePage {
                offset,
                total,
                queue_version,
                entries,
            }));
        }
    };
    Ok(None)
}

/// The player's latest state and position for the remote sessions. The
/// player observer feeds it (cheap, never blocks); each session watches it.
#[derive(Clone)]
pub struct RemoteFeed {
    state: Arc<watch::Sender<Option<Arc<PlayerSnapshot>>>>,
    position: Arc<watch::Sender<(f64, Option<f64>)>>,
}

impl Default for RemoteFeed {
    fn default() -> Self {
        Self::new()
    }
}

impl RemoteFeed {
    pub fn new() -> Self {
        Self {
            state: Arc::new(watch::Sender::new(None)),
            position: Arc::new(watch::Sender::new((0.0, None))),
        }
    }

    /// Call from the player observer with every event.
    pub fn on_player_event(&self, event: &PlayerEvent) {
        match event {
            PlayerEvent::State(snap) => {
                self.state.send_replace(Some(Arc::new(snap.clone())));
            }
            PlayerEvent::Position { seconds, duration } => {
                self.position.send_replace((*seconds, *duration));
            }
            PlayerEvent::Listen(_) | PlayerEvent::Error(_) => {}
        }
    }

    pub(super) fn subscribe_state(&self) -> watch::Receiver<Option<Arc<PlayerSnapshot>>> {
        self.state.subscribe()
    }

    pub(super) fn subscribe_position(&self) -> watch::Receiver<(f64, Option<f64>)> {
        self.position.subscribe()
    }
}

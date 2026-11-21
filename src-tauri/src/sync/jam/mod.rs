//! Local Jam (decision K27, `docs/JAM.md`): friends on the same Wi-Fi add
//! songs from their phones to what the computer plays.
//!
//! - `host` – the computer's side: the Jam's code, its guests (in memory
//!   only) and the guest-mode session loop;
//! - `guest` – the phone's side: joining, the guest session, search and add.
//!
//! This file holds the messages inside a guest session. They are a closed
//! list separate from `protocol::Msg`: a guest that sends anything else
//! (a remote command, a sync message, an unknown type) is disconnected.

pub mod guest;
pub mod host;

use serde::{Deserialize, Serialize};

/// Largest message a guest may send (its commands are tiny).
pub const MAX_GUEST_MESSAGE: usize = 4096;
/// Longest search query, in characters.
pub const MAX_QUERY_CHARS: usize = 100;
/// Most search results per page.
pub const MAX_SEARCH_PAGE: usize = 30;
/// Most "up next" entries in a Jam state.
pub const MAX_UP_NEXT: usize = 30;
/// Longest guest name shown, in characters.
pub const MAX_GUEST_NAME_CHARS: usize = 40;
/// Search offsets beyond this are refused.
const MAX_OFFSET: usize = 10_000_000;
/// Longest title / artist / album / name the guest accepts, in bytes.
const MAX_TEXT_BYTES: usize = 1024;

/// Guest → host. Every command carries an `id`; the answer has the same one.
// `deny_unknown_fields` on every variant: an extra field is refused.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum JamCmd {
    /// Answered with `jamState`. The guest also sends it as its keep-alive.
    JamState { id: u32 },
    /// Answered with `jamResults` (or `jamDone` with an error).
    JamSearch {
        id: u32,
        query: String,
        offset: usize,
        limit: usize,
    },
    /// Answered with `jamDone`.
    JamAdd { id: u32, track_id: i64 },
}

impl JamCmd {
    /// Parses and validates one received guest message.
    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > MAX_GUEST_MESSAGE {
            return Err("guest message too large".into());
        }
        let cmd: Self = serde_json::from_slice(bytes).map_err(|e| format!("bad message: {e}"))?;
        cmd.validate()?;
        Ok(cmd)
    }

    pub fn validate(&self) -> Result<(), &'static str> {
        match self {
            Self::JamState { .. } => Ok(()),
            Self::JamSearch {
                query,
                offset,
                limit,
                ..
            } => {
                if query.chars().count() > MAX_QUERY_CHARS || query.chars().any(char::is_control) {
                    Err("bad search query")
                } else if *offset > MAX_OFFSET || *limit == 0 || *limit > MAX_SEARCH_PAGE {
                    Err("search page out of range")
                } else {
                    Ok(())
                }
            }
            Self::JamAdd { track_id, .. } if *track_id <= 0 => Err("bad track id"),
            Self::JamAdd { .. } => Ok(()),
        }
    }

    pub fn id(&self) -> u32 {
        match *self {
            Self::JamState { id } | Self::JamSearch { id, .. } | Self::JamAdd { id, .. } => id,
        }
    }

    /// The same command with request id `id`.
    pub fn with_id(self, id: u32) -> Self {
        match self {
            Self::JamState { .. } => Self::JamState { id },
            Self::JamSearch {
                query,
                offset,
                limit,
                ..
            } => Self::JamSearch {
                id,
                query,
                offset,
                limit,
            },
            Self::JamAdd { track_id, .. } => Self::JamAdd { id, track_id },
        }
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }
}

/// Host → guest.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum JamMsg {
    /// The answer to `jamState` (`id` set), or pushed on a change (`id`
    /// `null`), at most 2 per second.
    JamState { id: Option<u32>, state: JamState },
    JamResults {
        id: u32,
        total: u64,
        items: Vec<JamTrack>,
    },
    /// The answer to `jamAdd` (and to a refused search): no error = done.
    JamDone { id: u32, error: Option<JamFailure> },
    /// The Jam ended (`removed` false) or the host removed this guest; the
    /// host closes the connection next.
    JamEnded { removed: bool },
}

impl JamMsg {
    /// Parses and validates one message from the host.
    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        let msg: Self = serde_json::from_slice(bytes).map_err(|e| format!("bad message: {e}"))?;
        let ok = match &msg {
            Self::JamState { state, .. } => state.valid(),
            Self::JamResults { items, .. } => {
                items.len() <= MAX_SEARCH_PAGE && items.iter().all(JamTrack::valid)
            }
            Self::JamDone { .. } | Self::JamEnded { .. } => true,
        };
        if ok {
            Ok(msg)
        } else {
            Err("bad message from the host".into())
        }
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum JamErrorCode {
    /// Too many adds (1 per 5 s, 20 per 10 minutes) or searches (one per
    /// 300 ms), or too many messages.
    RateLimited,
    /// 50 of the songs after the current one already come from guests.
    QueueFull,
    /// No such song in the host's library.
    NotFound,
    JamEnded,
}

impl JamErrorCode {
    /// What the guest's UI shows.
    pub fn message(self) -> &'static str {
        match self {
            Self::RateLimited => "Not so fast: try again in a few seconds",
            Self::QueueFull => "The queue is full, try later",
            Self::NotFound => "This song is not in the library any more",
            Self::JamEnded => "The Jam has ended",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct JamFailure {
    pub code: JamErrorCode,
}

/// What a guest sees of the host's player (the `jamState` answer and the
/// `jam://state` event).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct JamState {
    pub host_name: String,
    pub now_playing: Option<JamNowPlaying>,
    pub playing: bool,
    pub up_next: Vec<JamUpNext>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct JamNowPlaying {
    pub title: String,
    pub artist: String,
    pub duration_ms: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct JamUpNext {
    pub title: String,
    pub artist: String,
    pub duration_ms: Option<u64>,
    /// The guest who added it; `None` for the host's own songs.
    pub added_by: Option<String>,
}

/// One search result: no path, no cover.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct JamTrack {
    pub track_id: i64,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: Option<u64>,
}

/// The answer of `jam_search`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JamSearchPage {
    pub total: u64,
    pub items: Vec<JamTrack>,
}

fn text_ok(s: &str) -> bool {
    s.len() <= MAX_TEXT_BYTES
}

impl JamState {
    fn valid(&self) -> bool {
        text_ok(&self.host_name)
            && self
                .now_playing
                .as_ref()
                .is_none_or(|n| text_ok(&n.title) && text_ok(&n.artist))
            && self.up_next.len() <= MAX_UP_NEXT
            && self.up_next.iter().all(|u| {
                text_ok(&u.title) && text_ok(&u.artist) && u.added_by.as_deref().is_none_or(text_ok)
            })
    }
}

impl JamTrack {
    fn valid(&self) -> bool {
        text_ok(&self.title) && text_ok(&self.artist) && text_ok(&self.album)
    }
}

/// A guest's display name as the host keeps it: trimmed, control
/// characters dropped, at most 40 characters; "Guest" when empty.
pub fn guest_name(raw: &str) -> String {
    let name: String = raw
        .chars()
        .filter(|c| !c.is_control())
        .collect::<String>()
        .trim()
        .chars()
        .take(MAX_GUEST_NAME_CHARS)
        .collect::<String>()
        .trim_end()
        .to_owned();
    if name.is_empty() {
        "Guest".into()
    } else {
        name
    }
}

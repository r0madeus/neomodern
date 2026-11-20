//! MusicBrainz web service (ws/2) and Cover Art Archive client.
//!
//! All structs are parsed tolerantly: every field has a default and unknown
//! fields are ignored, so a missing or new key never fails a whole lookup.

use super::MetadataError;
use crate::net::{BodyError, Feature, NetPolicy, read_text_limited};
use reqwest::{Client, StatusCode};
use serde::Deserialize;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const MB_BASE_URL: &str = "https://musicbrainz.org/ws/2";
pub const CAA_BASE_URL: &str = "https://coverartarchive.org";
const USER_AGENT: &str = concat!(
    "NeoModern/",
    env!("CARGO_PKG_VERSION"),
    " ( https://github.com/r0madeus/neomodern )"
);
/// MusicBrainz allows about one request per second per IP.
const DEFAULT_MIN_INTERVAL: Duration = Duration::from_millis(1100);
const DEFAULT_RETRY_DELAY: Duration = Duration::from_secs(2);
const MAX_COVER_DOWNLOAD_BYTES: usize = 15 * 1024 * 1024;
/// Largest MusicBrainz JSON answer we accept.
const MAX_JSON_BYTES: usize = 4 * 1024 * 1024;

impl From<BodyError> for MetadataError {
    fn from(e: BodyError) -> Self {
        match e {
            BodyError::Http(e) => Self::Http(e),
            BodyError::Json(e) => Self::Json(e),
            e @ BodyError::TooLarge { .. } => Self::Invalid(e.to_string()),
        }
    }
}

#[derive(Debug, Clone)]
pub struct MbConfig {
    pub mb_base_url: String,
    pub caa_base_url: String,
    /// Minimum time between two MusicBrainz requests.
    pub min_interval: Duration,
    /// Wait before the single retry after an HTTP 503.
    pub retry_delay: Duration,
}

impl Default for MbConfig {
    fn default() -> Self {
        Self {
            mb_base_url: MB_BASE_URL.into(),
            caa_base_url: CAA_BASE_URL.into(),
            min_interval: DEFAULT_MIN_INTERVAL,
            retry_delay: DEFAULT_RETRY_DELAY,
        }
    }
}

// ---------------------------------------------------------------------
// JSON shapes
// ---------------------------------------------------------------------

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct MbArtist {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct MbArtistCredit {
    pub name: String,
    pub joinphrase: String,
    pub artist: MbArtist,
}

/// `name + joinphrase` of every credit, concatenated.
pub fn credit_string(credits: &[MbArtistCredit]) -> String {
    credits
        .iter()
        .map(|c| {
            let name = if c.name.is_empty() {
                c.artist.name.as_str()
            } else {
                c.name.as_str()
            };
            format!("{name}{}", c.joinphrase)
        })
        .collect::<String>()
        .trim()
        .to_owned()
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default, rename_all = "kebab-case")]
pub struct MbReleaseGroup {
    pub id: String,
    pub primary_type: Option<String>,
    pub secondary_types: Vec<String>,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default, rename_all = "kebab-case")]
pub struct MbTrack {
    pub id: String,
    pub number: String,
    pub position: Option<u32>,
    pub title: String,
    pub length: Option<u64>,
    pub artist_credit: Vec<MbArtistCredit>,
    pub recording: Option<MbRecordingRef>,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default, rename_all = "kebab-case")]
pub struct MbRecordingRef {
    pub id: String,
    pub title: String,
    pub length: Option<u64>,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default, rename_all = "kebab-case")]
pub struct MbMedium {
    pub position: Option<u32>,
    pub format: Option<String>,
    pub track_count: Option<u32>,
    /// Release search / lookup: the tracks. Absent in search results.
    pub tracks: Vec<MbTrack>,
    /// Recording search: the (single) track of this recording on the medium.
    pub track: Vec<MbTrack>,
    pub track_offset: Option<u32>,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default, rename_all = "kebab-case")]
pub struct MbRelease {
    pub id: String,
    pub score: Option<u32>,
    pub title: String,
    pub status: Option<String>,
    pub date: Option<String>,
    pub country: Option<String>,
    pub track_count: Option<u32>,
    pub media: Vec<MbMedium>,
    pub release_group: Option<MbReleaseGroup>,
    pub artist_credit: Vec<MbArtistCredit>,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default, rename_all = "kebab-case")]
pub struct MbRecording {
    pub id: String,
    pub score: Option<u32>,
    pub title: String,
    pub length: Option<u64>,
    pub artist_credit: Vec<MbArtistCredit>,
    pub releases: Vec<MbRelease>,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct ReleaseSearch {
    pub releases: Vec<MbRelease>,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct RecordingSearch {
    pub recordings: Vec<MbRecording>,
}

// ---------------------------------------------------------------------
// Lucene
// ---------------------------------------------------------------------

/// Escapes the Lucene special characters of a value that is put inside a
/// quoted phrase (`"..."`): `+ - && || ! ( ) { } [ ] ^ " ~ * ? : \ /`.
pub fn lucene_escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 8);
    for c in value.chars() {
        match c {
            '+' | '-' | '!' | '(' | ')' | '{' | '}' | '[' | ']' | '^' | '"' | '~' | '*' | '?'
            | ':' | '\\' | '/' | '&' | '|' => {
                out.push('\\');
                out.push(c);
            }
            _ => out.push(c),
        }
    }
    out
}

pub fn release_query(album: &str, artist: &str, tracks: Option<usize>) -> String {
    let mut q = format!(
        "release:\"{}\" AND artist:\"{}\"",
        lucene_escape(album),
        lucene_escape(artist)
    );
    if let Some(n) = tracks.filter(|n| *n > 0) {
        q.push_str(&format!(" AND tracks:{n}"));
    }
    q
}

pub fn recording_query(title: &str, artist: &str) -> String {
    format!(
        "recording:\"{}\" AND artist:\"{}\"",
        lucene_escape(title),
        lucene_escape(artist)
    )
}

// ---------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------

/// Validates a MusicBrainz identifier (UUID or short test fixture ID) so it
/// cannot inject path segments, query parameters, or fragments into URLs.
pub fn is_valid_mbid(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

#[derive(Debug)]
pub struct MbClient {
    http: Client,
    policy: Arc<NetPolicy>,
    cfg: MbConfig,
    /// When the next MusicBrainz request may start.
    next_slot: Mutex<Option<Instant>>,
}

impl MbClient {
    pub fn new(cfg: MbConfig) -> Result<Self, MetadataError> {
        let http = crate::net::client_builder()
            .user_agent(USER_AGENT)
            .timeout(Duration::from_secs(15))
            .build()?;
        Ok(Self {
            http,
            policy: Arc::new(NetPolicy::default()),
            cfg,
            next_slot: Mutex::new(None),
        })
    }

    /// Makes every request ask `policy` first.
    pub fn with_policy(mut self, policy: Arc<NetPolicy>) -> Self {
        self.policy = policy;
        self
    }

    /// The HTTP client; every request goes through here, so the metadata
    /// switch in Settings cannot be bypassed.
    fn http(&self) -> Result<&Client, MetadataError> {
        self.policy
            .require(Feature::Metadata)
            .map_err(|_| MetadataError::Disabled)?;
        Ok(&self.http)
    }

    /// Waits until at least `min_interval` has passed since the previous
    /// MusicBrainz request. The slot is reserved before sleeping, so
    /// concurrent callers queue up instead of bursting.
    async fn wait_for_slot(&self) {
        let wait = {
            let mut next = self.next_slot.lock().unwrap_or_else(|p| p.into_inner());
            let now = Instant::now();
            let start = next.map_or(now, |t| t.max(now));
            *next = Some(start + self.cfg.min_interval);
            start.saturating_duration_since(now)
        };
        if !wait.is_zero() {
            tokio::time::sleep(wait).await;
        }
    }

    async fn mb_get(&self, path: &str, query: &[(&str, String)]) -> Result<String, MetadataError> {
        let url = format!("{}{path}", self.cfg.mb_base_url.trim_end_matches('/'));
        let mut retried = false;
        loop {
            self.http()?;
            self.wait_for_slot().await;
            let res = self
                .http()?
                .get(&url)
                .query(query)
                .query(&[("fmt", "json")])
                .send()
                .await?;
            match res.status() {
                StatusCode::OK => return Ok(read_text_limited(res, MAX_JSON_BYTES).await?),
                StatusCode::SERVICE_UNAVAILABLE if !retried => {
                    retried = true;
                    tokio::time::sleep(self.cfg.retry_delay).await;
                }
                status => return Err(MetadataError::Status(status.as_u16())),
            }
        }
    }

    pub async fn search_releases(
        &self,
        album: &str,
        artist: &str,
        tracks: Option<usize>,
    ) -> Result<(Vec<MbRelease>, usize), MetadataError> {
        let run = |q: String| async move {
            let body = self
                .mb_get("/release/", &[("query", q), ("limit", "8".into())])
                .await?;
            Ok::<_, MetadataError>(serde_json::from_str::<ReleaseSearch>(&body)?.releases)
        };
        let found = run(release_query(album, artist, tracks)).await?;
        if found.is_empty() && tracks.is_some() {
            return Ok((run(release_query(album, artist, None)).await?, 2));
        }
        Ok((found, 1))
    }

    pub async fn lookup_release(&self, id: &str) -> Result<MbRelease, MetadataError> {
        if !is_valid_mbid(id) {
            return Err(MetadataError::Invalid(
                "invalid MusicBrainz release ID".into(),
            ));
        }
        let body = self
            .mb_get(
                &format!("/release/{id}"),
                &[(
                    "inc",
                    "recordings+artist-credits+media+release-groups".into(),
                )],
            )
            .await?;
        Ok(serde_json::from_str(&body)?)
    }

    pub async fn search_recordings(
        &self,
        title: &str,
        artist: &str,
    ) -> Result<Vec<MbRecording>, MetadataError> {
        let body = self
            .mb_get(
                "/recording/",
                &[
                    ("query", recording_query(title, artist)),
                    ("limit", "10".into()),
                ],
            )
            .await?;
        Ok(serde_json::from_str::<RecordingSearch>(&body)?.recordings)
    }

    /// Front cover of a release group at the given size (250 or 500).
    /// `Ok(None)` when the archive has none (404).
    pub async fn front_cover(
        &self,
        release_group_id: &str,
        size: u32,
    ) -> Result<Option<Vec<u8>>, MetadataError> {
        if !is_valid_mbid(release_group_id) {
            return Err(MetadataError::Invalid(
                "invalid MusicBrainz release group ID".into(),
            ));
        }
        let url = format!(
            "{}/release-group/{release_group_id}/front-{size}",
            self.cfg.caa_base_url.trim_end_matches('/')
        );
        let mut res = self.http()?.get(url).send().await?;
        match res.status() {
            StatusCode::OK => {
                if res
                    .content_length()
                    .is_some_and(|len| len > MAX_COVER_DOWNLOAD_BYTES as u64)
                {
                    return Err(MetadataError::Invalid("cover image is too large".into()));
                }
                let mut bytes = Vec::new();
                while let Some(chunk) = res.chunk().await? {
                    if bytes.len().saturating_add(chunk.len()) > MAX_COVER_DOWNLOAD_BYTES {
                        return Err(MetadataError::Invalid("cover image is too large".into()));
                    }
                    bytes.extend_from_slice(&chunk);
                }
                Ok(Some(bytes))
            }
            StatusCode::NOT_FOUND => Ok(None),
            status => Err(MetadataError::Status(status.as_u16())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_valid_mbid_accepts_uuids_and_fixtures_and_rejects_traversal() {
        assert!(is_valid_mbid("bbbbbbbb-0000-4000-8000-000000000001"));
        assert!(is_valid_mbid("rg-1"));
        assert!(is_valid_mbid("rel-1"));

        assert!(!is_valid_mbid(""));
        assert!(!is_valid_mbid("../secret"));
        assert!(!is_valid_mbid("a/b"));
        assert!(!is_valid_mbid(r"a\b"));
        assert!(!is_valid_mbid("id?foo=bar"));
        assert!(!is_valid_mbid("id#frag"));
        assert!(!is_valid_mbid(&"a".repeat(65)));
    }

    #[test]
    fn front_cover_rejects_oversized_content_length() {
        use std::io::{Read, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 512];
                let _ = stream.read(&mut buf);
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    MAX_COVER_DOWNLOAD_BYTES + 1
                );
                let _ = stream.write_all(resp.as_bytes());
            }
        });

        let client = MbClient::new(MbConfig {
            caa_base_url: format!("http://{addr}"),
            ..MbConfig::default()
        })
        .unwrap();
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let err = rt.block_on(client.front_cover("rg-1", 250)).unwrap_err();
        assert!(matches!(err, MetadataError::Invalid(_)));
        let _ = server.join();
    }
}

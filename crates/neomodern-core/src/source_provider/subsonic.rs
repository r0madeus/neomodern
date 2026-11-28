//! OpenSubsonic / Subsonic / Navidrome external source provider (K29).
//!
//! Connects to user-configured Subsonic-compatible servers (Navidrome, Gonic,
//! Airsonic, Jellyfin Subsonic plugin, etc.) using the standard REST API
//! (`search3.view`, `getSong.view`, `stream.view`, `getCoverArt.view`) gated
//! by [`NetPolicy`].

use super::{
    BoxFuture, ExternalTrack, ProviderConfig, ProviderKind, ResolvedStream, SourceProvider,
    SourceProviderError,
};
use crate::net::{BodyError, Feature, NetPolicy, client_builder, read_json_limited};
use reqwest::{Client, Url};
use serde::Deserialize;
use std::sync::Arc;
use std::time::Duration;

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(10);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_JSON_BYTES: usize = 4 * 1024 * 1024;
const SUBSONIC_API_VERSION: &str = "1.16.1";
const SUBSONIC_CLIENT_NAME: &str = "NeoModern";
const USER_AGENT: &str = concat!(
    "NeoModern/",
    env!("CARGO_PKG_VERSION"),
    " (https://github.com/r0madeus/neomodern)"
);

/// Parses a `subsonic://user:pass@host[:port][/path]` or `subsonics://...` URL
/// into `(http_base_url, username, password)`.
pub fn parse_subsonic_endpoint(raw: &str) -> Result<(String, String, String), SourceProviderError> {
    let trimmed = raw.trim();
    let (http_scheme, rest) = if let Some(r) = trimmed.strip_prefix("subsonics://") {
        ("https://", r)
    } else if let Some(r) = trimmed.strip_prefix("subsonic://") {
        ("http://", r)
    } else {
        return Err(SourceProviderError::InvalidConfig(
            "Subsonic endpoint must start with 'subsonic://' or 'subsonics://'".to_owned(),
        ));
    };

    let parsed = Url::parse(&format!("{http_scheme}{rest}")).map_err(|e| {
        SourceProviderError::InvalidConfig(format!("invalid Subsonic endpoint URL: {e}"))
    })?;
    if parsed.host_str().is_none_or(str::is_empty) || parsed.cannot_be_a_base() {
        return Err(SourceProviderError::InvalidConfig(
            "Subsonic endpoint must include a valid host".to_owned(),
        ));
    }
    let username = percent_decode(parsed.username());
    if username.trim().is_empty() {
        return Err(SourceProviderError::InvalidConfig(
            "Subsonic endpoint must include a username (subsonic://user:pass@host)".to_owned(),
        ));
    }
    let password = percent_decode(parsed.password().unwrap_or(""));
    if password.is_empty() {
        return Err(SourceProviderError::InvalidConfig(
            "Subsonic endpoint must include a password (subsonic://user:pass@host)".to_owned(),
        ));
    }

    let mut clean = parsed.clone();
    let _ = clean.set_username("");
    let _ = clean.set_password(None);
    clean.set_query(None);
    clean.set_fragment(None);
    let base_url = clean.as_str().trim_end_matches('/').to_owned();
    Ok((base_url, username, password))
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let (Some(hi), Some(lo)) = (hex_val(bytes[i + 1]), hex_val(bytes[i + 2]))
        {
            out.push((hi << 4) | lo);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn map_body_error(err: BodyError) -> SourceProviderError {
    match err {
        BodyError::Http(e) => SourceProviderError::Request(e.to_string()),
        BodyError::TooLarge { limit } => {
            SourceProviderError::Request(format!("Subsonic response exceeded {limit} bytes"))
        }
        BodyError::Json(e) => {
            SourceProviderError::Request(format!("invalid Subsonic JSON response: {e}"))
        }
    }
}

#[derive(Debug, Deserialize)]
struct SubsonicEnvelope {
    #[serde(rename = "subsonic-response")]
    response: SubsonicResponse,
}

#[derive(Debug, Deserialize)]
struct SubsonicResponse {
    status: String,
    #[serde(default)]
    error: Option<SubsonicApiError>,
    #[serde(rename = "searchResult3", default)]
    search_result3: Option<SearchResult3>,
    #[serde(default)]
    song: Option<SubsonicSong>,
}

#[derive(Debug, Deserialize)]
struct SubsonicApiError {
    #[serde(default)]
    code: i32,
    #[serde(default)]
    message: String,
}

#[derive(Debug, Deserialize)]
struct SearchResult3 {
    #[serde(default)]
    song: Vec<SubsonicSong>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SubsonicSong {
    id: String,
    title: String,
    #[serde(default)]
    artist: Option<String>,
    #[serde(default)]
    album: Option<String>,
    #[serde(default)]
    duration: Option<u64>,
    #[serde(default)]
    cover_art: Option<String>,
    #[serde(default)]
    content_type: Option<String>,
}

/// OpenSubsonic / Navidrome [`SourceProvider`] backed by `reqwest` and [`NetPolicy`].
#[derive(Debug, Clone)]
pub struct SubsonicProvider {
    id: String,
    base_url: String,
    username: String,
    password: String,
    http: Client,
    net_policy: Arc<NetPolicy>,
}

impl SubsonicProvider {
    /// Creates a new OpenSubsonic / Navidrome provider.
    pub fn new(
        id: impl Into<String>,
        base_url: impl Into<String>,
        username: impl Into<String>,
        password: impl Into<String>,
        net_policy: Arc<NetPolicy>,
    ) -> Result<Self, SourceProviderError> {
        let id = id.into();
        if id.trim().is_empty() {
            return Err(SourceProviderError::InvalidConfig(
                "provider id must not be empty".to_owned(),
            ));
        }
        let base_url = super::validate_base_url(&base_url.into())?;
        let username = username.into();
        let password = password.into();
        if username.trim().is_empty() || password.is_empty() {
            return Err(SourceProviderError::InvalidConfig(
                "Subsonic username and password must not be empty".to_owned(),
            ));
        }
        let http = client_builder()
            .user_agent(USER_AGENT)
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(DEFAULT_TIMEOUT)
            .build()
            .map_err(|e| {
                SourceProviderError::Request(format!("failed to build HTTP client: {e}"))
            })?;

        Ok(Self {
            id,
            base_url,
            username,
            password,
            http,
            net_policy,
        })
    }

    /// Constructs a [`SubsonicProvider`] from a [`ProviderConfig`].
    pub fn from_config(
        config: &ProviderConfig,
        net_policy: Arc<NetPolicy>,
    ) -> Result<Self, SourceProviderError> {
        match &config.kind {
            ProviderKind::Subsonic {
                base_url,
                username,
                password,
            } => Self::new(
                config.id.clone(),
                base_url.clone(),
                username.clone(),
                password.clone(),
                net_policy,
            ),
            _ => Err(SourceProviderError::InvalidConfig(
                "expected Subsonic provider config".to_owned(),
            )),
        }
    }

    fn build_rest_url(
        &self,
        endpoint: &str,
        extra_params: &[(&str, &str)],
    ) -> Result<Url, SourceProviderError> {
        let mut url = Url::parse(&format!("{}/rest/{endpoint}", self.base_url)).map_err(|e| {
            SourceProviderError::InvalidConfig(format!("invalid Subsonic URL: {e}"))
        })?;
        {
            let mut pairs = url.query_pairs_mut();
            pairs.append_pair("u", &self.username);
            pairs.append_pair("p", &self.password);
            pairs.append_pair("v", SUBSONIC_API_VERSION);
            pairs.append_pair("c", SUBSONIC_CLIENT_NAME);
            pairs.append_pair("f", "json");
            for (k, v) in extra_params {
                pairs.append_pair(k, v);
            }
        }
        Ok(url)
    }

    fn cover_art_url(&self, cover_id: &str) -> Option<String> {
        self.build_rest_url("getCoverArt.view", &[("id", cover_id), ("size", "500")])
            .ok()
            .map(String::from)
    }

    fn map_song(&self, song: SubsonicSong) -> ExternalTrack {
        let cover_url = song
            .cover_art
            .as_deref()
            .filter(|c| !c.trim().is_empty())
            .and_then(|c| self.cover_art_url(c));
        ExternalTrack {
            provider_id: self.id.clone(),
            external_id: song.id,
            title: song.title,
            artist: song.artist.unwrap_or_default(),
            album: song.album,
            duration_ms: song.duration.map(|s| s.saturating_mul(1000)),
            cover_url,
        }
    }

    fn ensure_network_allowed(&self) -> Result<(), SourceProviderError> {
        self.net_policy
            .require(Feature::Online)
            .map_err(|_| SourceProviderError::Disabled)
    }

    async fn get_subsonic(
        &self,
        endpoint: &str,
        extra_params: &[(&str, &str)],
    ) -> Result<SubsonicResponse, SourceProviderError> {
        self.ensure_network_allowed()?;
        let url = self.build_rest_url(endpoint, extra_params)?;
        let resp = self
            .http
            .get(url)
            .send()
            .await
            .map_err(|e| SourceProviderError::Request(e.to_string()))?;
        if !resp.status().is_success() {
            return Err(SourceProviderError::Request(format!(
                "Subsonic server returned HTTP {}",
                resp.status().as_u16()
            )));
        }
        let env: SubsonicEnvelope = read_json_limited(resp, MAX_JSON_BYTES)
            .await
            .map_err(map_body_error)?;
        if env.response.status != "ok" {
            let err = env.response.error;
            let code = err.as_ref().map(|e| e.code).unwrap_or(0);
            let msg = err
                .map(|e| e.message)
                .filter(|m| !m.is_empty())
                .unwrap_or_else(|| "Subsonic API error".to_owned());
            if code == 70 {
                return Err(SourceProviderError::NotFound(msg));
            }
            return Err(SourceProviderError::Request(format!(
                "Subsonic error {code}: {msg}"
            )));
        }
        Ok(env.response)
    }
}

impl SourceProvider for SubsonicProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn search(
        &self,
        query: &str,
        limit: usize,
    ) -> BoxFuture<'_, Result<Vec<ExternalTrack>, SourceProviderError>> {
        let query = query.trim().to_owned();
        Box::pin(async move {
            if query.is_empty() || limit == 0 {
                return Ok(Vec::new());
            }
            let count = limit.min(100).to_string();
            let resp = self
                .get_subsonic(
                    "search3.view",
                    &[
                        ("query", &query),
                        ("songCount", &count),
                        ("albumCount", "0"),
                        ("artistCount", "0"),
                    ],
                )
                .await?;
            let songs = resp.search_result3.map(|r| r.song).unwrap_or_default();
            Ok(songs
                .into_iter()
                .take(limit)
                .map(|s| self.map_song(s))
                .collect())
        })
    }

    fn resolve_stream(
        &self,
        external_id: &str,
    ) -> BoxFuture<'_, Result<ResolvedStream, SourceProviderError>> {
        let external_id = external_id.trim().to_owned();
        Box::pin(async move {
            self.ensure_network_allowed()?;
            if external_id.is_empty() {
                return Err(SourceProviderError::InvalidConfig(
                    "external track id must not be empty".to_owned(),
                ));
            }
            let stream_url = self.build_rest_url("stream.view", &[("id", &external_id)])?;
            let mime_type = self
                .get_subsonic("getSong.view", &[("id", &external_id)])
                .await
                .ok()
                .and_then(|r| r.song)
                .and_then(|s| s.content_type);
            Ok(ResolvedStream {
                url: stream_url.into(),
                mime_type,
                expires_at_ms: None,
            })
        })
    }

    fn fetch_metadata(
        &self,
        external_id: &str,
    ) -> BoxFuture<'_, Result<ExternalTrack, SourceProviderError>> {
        let external_id = external_id.trim().to_owned();
        Box::pin(async move {
            if external_id.is_empty() {
                return Err(SourceProviderError::InvalidConfig(
                    "external track id must not be empty".to_owned(),
                ));
            }
            let resp = self
                .get_subsonic("getSong.view", &[("id", &external_id)])
                .await?;
            let song = resp
                .song
                .ok_or(SourceProviderError::NotFound(external_id))?;
            Ok(self.map_song(song))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_subsonic_endpoint_handles_http_https_and_errors() {
        let (base, user, pass) =
            parse_subsonic_endpoint("subsonics://melih:s3cret@music.example.com:4533/navidrome/")
                .expect("valid subsonics");
        assert_eq!(base, "https://music.example.com:4533/navidrome");
        assert_eq!(user, "melih");
        assert_eq!(pass, "s3cret");

        let (base2, user2, pass2) =
            parse_subsonic_endpoint("subsonic://alice:p%40ss@192.168.1.10:4533")
                .expect("valid subsonic");
        assert_eq!(base2, "http://192.168.1.10:4533");
        assert_eq!(user2, "alice");
        assert_eq!(pass2, "p@ss");

        assert!(parse_subsonic_endpoint("https://music.example.com").is_err());
        assert!(parse_subsonic_endpoint("subsonic://music.example.com").is_err());
        assert!(parse_subsonic_endpoint("subsonic://user@music.example.com").is_err());
    }

    #[test]
    fn subsonic_provider_builds_rest_and_stream_urls() {
        let policy = Arc::new(NetPolicy::default());
        let provider = SubsonicProvider::new(
            "navidrome",
            "https://music.example.com",
            "alice",
            "secret",
            policy,
        )
        .expect("provider");
        let url = provider
            .build_rest_url("stream.view", &[("id", "song-42")])
            .expect("stream url");
        let s = url.as_str();
        assert!(s.starts_with("https://music.example.com/rest/stream.view?"));
        assert!(s.contains("u=alice"));
        assert!(s.contains("p=secret"));
        assert!(s.contains("id=song-42"));
        assert!(s.contains("f=json"));
    }
}

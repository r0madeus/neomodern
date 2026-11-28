//! Neutral HTTP/JSON external source provider (K29).
//!
//! Communicates with user-configured HTTP/JSON catalog/stream services over a
//! neutral REST-like contract:
//! - `GET {base_url}/search?q={query}&limit={limit}` -> `Vec<ExternalTrack>` or `{ "tracks": [...] }`
//! - `GET {base_url}/stream/{external_id}` -> `ResolvedStream`
//! - `GET {base_url}/track/{external_id}` -> `ExternalTrack`

use super::{
    BoxFuture, ExternalTrack, ProviderConfig, ProviderKind, ResolvedStream, SourceProvider,
    SourceProviderError,
};
use crate::library::scan::write_atomic;
use crate::net::{BodyError, Feature, NetPolicy, client_builder, read_json_limited};
use reqwest::{Client, StatusCode, Url};
use serde::Deserialize;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(10);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_JSON_BYTES: usize = 4 * 1024 * 1024;
const USER_AGENT: &str = concat!(
    "NeoModern/",
    env!("CARGO_PKG_VERSION"),
    " (https://github.com/r0madeus/neomodern)"
);

fn map_body_error(err: BodyError) -> SourceProviderError {
    match err {
        BodyError::Http(e) => SourceProviderError::Request(e.to_string()),
        BodyError::TooLarge { limit } => {
            SourceProviderError::Request(format!("response exceeded {limit} bytes"))
        }
        BodyError::Json(e) => SourceProviderError::Request(format!("invalid JSON response: {e}")),
    }
}

/// Validates and normalizes an HTTP or HTTPS base URL.
///
/// Rejects non-HTTP(S) schemes, missing hosts, queries, fragments, and
/// embedded credentials. Trailing slashes are trimmed.
pub fn validate_base_url(raw: &str) -> Result<String, SourceProviderError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(SourceProviderError::InvalidConfig(
            "base URL must not be empty".to_owned(),
        ));
    }
    let url = Url::parse(trimmed)
        .map_err(|e| SourceProviderError::InvalidConfig(format!("invalid URL: {e}")))?;
    match url.scheme() {
        "http" | "https" => {}
        other => {
            return Err(SourceProviderError::InvalidConfig(format!(
                "unsupported URL scheme '{other}'; only http and https are allowed"
            )));
        }
    }
    if url.host_str().is_none_or(str::is_empty) || url.cannot_be_a_base() {
        return Err(SourceProviderError::InvalidConfig(
            "base URL must include a valid host".to_owned(),
        ));
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(SourceProviderError::InvalidConfig(
            "base URL must not include embedded credentials".to_owned(),
        ));
    }
    if url.query().is_some() || url.fragment().is_some() {
        return Err(SourceProviderError::InvalidConfig(
            "base URL must not include query parameters or fragments".to_owned(),
        ));
    }
    Ok(url.as_str().trim_end_matches('/').to_owned())
}

/// Validates a resolved media stream URL (`http://` or `https://` only).
fn validate_stream_url(raw: &str) -> Result<String, SourceProviderError> {
    let trimmed = raw.trim();
    let url = Url::parse(trimmed).map_err(|e| {
        SourceProviderError::Request(format!("provider returned invalid stream URL: {e}"))
    })?;
    match url.scheme() {
        "http" | "https" if url.host_str().is_some_and(|h| !h.is_empty()) => Ok(url.into()),
        _ => Err(SourceProviderError::Request(
            "provider returned unsupported stream URL scheme".to_owned(),
        )),
    }
}

/// Percent-encodes an `external_id` as a single safe path segment.
fn encode_path_segment(segment: &str) -> Result<String, SourceProviderError> {
    if segment.is_empty() || segment == "." || segment == ".." {
        return Err(SourceProviderError::InvalidConfig(
            "external track id must not be empty or relative".to_owned(),
        ));
    }
    let mut out = String::with_capacity(segment.len());
    for byte in segment.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char);
            }
            _ => {
                out.push_str(&format!("%{byte:02X}"));
            }
        }
    }
    Ok(out)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireExternalTrack {
    #[serde(default)]
    provider_id: Option<String>,
    external_id: String,
    title: String,
    artist: String,
    #[serde(default)]
    album: Option<String>,
    #[serde(default)]
    duration_ms: Option<u64>,
    #[serde(default)]
    cover_url: Option<String>,
}

impl WireExternalTrack {
    fn into_external_track(self, fallback_provider_id: &str) -> ExternalTrack {
        let provider_id = self
            .provider_id
            .filter(|id| !id.trim().is_empty())
            .unwrap_or_else(|| fallback_provider_id.to_owned());
        ExternalTrack {
            provider_id,
            external_id: self.external_id,
            title: self.title,
            artist: self.artist,
            album: self.album,
            duration_ms: self.duration_ms,
            cover_url: self.cover_url,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum SearchResponse {
    Array(Vec<WireExternalTrack>),
    Object { tracks: Vec<WireExternalTrack> },
}

/// Neutral HTTP/JSON [`SourceProvider`] backed by `reqwest` and gated by [`NetPolicy`].
#[derive(Debug, Clone)]
pub struct HttpJsonProvider {
    id: String,
    base_url: String,
    http: Client,
    policy: Arc<NetPolicy>,
}

impl HttpJsonProvider {
    /// Creates a new [`HttpJsonProvider`] after validating `base_url`.
    pub fn new(
        id: impl Into<String>,
        base_url: impl AsRef<str>,
        policy: Arc<NetPolicy>,
    ) -> Result<Self, SourceProviderError> {
        let id = id.into();
        if id.trim().is_empty() {
            return Err(SourceProviderError::InvalidConfig(
                "provider id must not be empty".to_owned(),
            ));
        }
        let base_url = validate_base_url(base_url.as_ref())?;
        let http = client_builder()
            .user_agent(USER_AGENT)
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(DEFAULT_TIMEOUT)
            .build()
            .map_err(|e| SourceProviderError::InvalidConfig(e.to_string()))?;
        Ok(Self {
            id,
            base_url,
            http,
            policy,
        })
    }

    /// Builds an [`HttpJsonProvider`] from a [`ProviderConfig`].
    pub fn from_config(
        config: &ProviderConfig,
        policy: Arc<NetPolicy>,
    ) -> Result<Self, SourceProviderError> {
        if !config.enabled {
            return Err(SourceProviderError::Disabled);
        }
        match &config.kind {
            ProviderKind::HttpJson { base_url } => Self::new(config.id.clone(), base_url, policy),
            _ => Err(SourceProviderError::Unsupported(
                "non-HTTP/JSON provider cannot be constructed as HttpJsonProvider".to_owned(),
            )),
        }
    }

    /// Returns the normalized base URL for this provider.
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// Single gate for every outbound HTTP request so offline mode and
    /// `Feature::Online` in Settings cannot be bypassed.
    fn http(&self) -> Result<&Client, SourceProviderError> {
        self.policy
            .require(Feature::Online)
            .map_err(|_| SourceProviderError::Disabled)?;
        Ok(&self.http)
    }
}

impl SourceProvider for HttpJsonProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn search(
        &self,
        query: &str,
        limit: usize,
    ) -> BoxFuture<'_, Result<Vec<ExternalTrack>, SourceProviderError>> {
        let query = query.to_owned();
        let limit = limit.clamp(1, 100);
        Box::pin(async move {
            let client = self.http()?;
            let url = format!("{}/search", self.base_url);
            let resp = client
                .get(&url)
                .query(&[("q", query), ("limit", limit.to_string())])
                .send()
                .await
                .map_err(|e| SourceProviderError::Request(e.to_string()))?;

            match resp.status() {
                StatusCode::OK => {
                    let parsed: SearchResponse = read_json_limited(resp, MAX_JSON_BYTES)
                        .await
                        .map_err(map_body_error)?;
                    let items = match parsed {
                        SearchResponse::Array(v) => v,
                        SearchResponse::Object { tracks } => tracks,
                    };
                    Ok(items
                        .into_iter()
                        .take(limit)
                        .map(|t| t.into_external_track(&self.id))
                        .collect())
                }
                status => Err(SourceProviderError::Request(format!(
                    "search returned HTTP {}",
                    status.as_u16()
                ))),
            }
        })
    }

    fn resolve_stream(
        &self,
        external_id: &str,
    ) -> BoxFuture<'_, Result<ResolvedStream, SourceProviderError>> {
        let external_id = external_id.to_owned();
        Box::pin(async move {
            let client = self.http()?;
            let encoded = encode_path_segment(&external_id)?;
            let url = format!("{}/stream/{encoded}", self.base_url);
            let resp = client
                .get(&url)
                .send()
                .await
                .map_err(|e| SourceProviderError::Request(e.to_string()))?;

            match resp.status() {
                StatusCode::OK => {
                    let mut stream: ResolvedStream = read_json_limited(resp, MAX_JSON_BYTES)
                        .await
                        .map_err(map_body_error)?;
                    stream.url = validate_stream_url(&stream.url)?;
                    Ok(stream)
                }
                StatusCode::NOT_FOUND => Err(SourceProviderError::NotFound(external_id)),
                status => Err(SourceProviderError::Request(format!(
                    "resolve_stream returned HTTP {}",
                    status.as_u16()
                ))),
            }
        })
    }

    fn fetch_metadata(
        &self,
        external_id: &str,
    ) -> BoxFuture<'_, Result<ExternalTrack, SourceProviderError>> {
        let external_id = external_id.to_owned();
        Box::pin(async move {
            let client = self.http()?;
            let encoded = encode_path_segment(&external_id)?;
            let url = format!("{}/track/{encoded}", self.base_url);
            let resp = client
                .get(&url)
                .send()
                .await
                .map_err(|e| SourceProviderError::Request(e.to_string()))?;

            match resp.status() {
                StatusCode::OK => {
                    let track: WireExternalTrack = read_json_limited(resp, MAX_JSON_BYTES)
                        .await
                        .map_err(map_body_error)?;
                    Ok(track.into_external_track(&self.id))
                }
                StatusCode::NOT_FOUND => Err(SourceProviderError::NotFound(external_id)),
                status => Err(SourceProviderError::Request(format!(
                    "fetch_metadata returned HTTP {}",
                    status.as_u16()
                ))),
            }
        })
    }
}

/// Loads saved external source provider configs from `path`.
///
/// Defaults to an empty `Vec` when the file does not exist or cannot be parsed.
pub fn load_provider_configs(path: &Path) -> Vec<ProviderConfig> {
    let Ok(bytes) = std::fs::read(path) else {
        return Vec::new();
    };
    serde_json::from_slice::<Vec<ProviderConfig>>(&bytes).unwrap_or_else(|e| {
        log::warn!(
            "could not parse source provider configs at {}: {e}",
            path.display()
        );
        Vec::new()
    })
}

/// Atomically persists external source provider configs to `path`.
pub fn save_provider_configs(
    path: &Path,
    configs: &[ProviderConfig],
) -> Result<(), SourceProviderError> {
    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent)
            .map_err(|e| SourceProviderError::InvalidConfig(e.to_string()))?;
    }
    let json = serde_json::to_vec_pretty(configs)
        .map_err(|e| SourceProviderError::InvalidConfig(e.to_string()))?;
    write_atomic(path, &json).map_err(|e| SourceProviderError::InvalidConfig(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use tempfile::TempDir;

    fn serve_once(status: &str, body: &str) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let status = status.to_owned();
        let body = body.to_owned();
        std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 2048];
                let _ = stream.read(&mut buf);
                let raw = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(raw.as_bytes());
            }
        });
        format!("http://{addr}")
    }

    #[test]
    fn url_validation_accepts_only_clean_http_and_https() {
        assert_eq!(
            validate_base_url("https://bridge.example.invalid/api/").unwrap(),
            "https://bridge.example.invalid/api"
        );
        assert_eq!(
            validate_base_url("  http://127.0.0.1:8787  ").unwrap(),
            "http://127.0.0.1:8787"
        );

        for bad in [
            "",
            "   ",
            "ftp://example.invalid/api",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "https://user:pass@example.invalid/api",
            "https://example.invalid/api?foo=bar",
            "https://example.invalid/api#frag",
            "not a url",
        ] {
            assert!(
                matches!(
                    validate_base_url(bad),
                    Err(SourceProviderError::InvalidConfig(_))
                ),
                "expected InvalidConfig for {bad:?}"
            );
        }
    }

    #[test]
    fn missing_config_file_defaults_to_empty() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("source_providers.json");
        assert!(load_provider_configs(&path).is_empty());
    }

    #[test]
    fn config_persistence_roundtrip() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("nested").join("source_providers.json");
        let configs = vec![
            ProviderConfig {
                id: "local-bridge".to_owned(),
                name: "Local Bridge".to_owned(),
                kind: ProviderKind::HttpJson {
                    base_url: "http://127.0.0.1:8787".to_owned(),
                },
                enabled: true,
            },
            ProviderConfig {
                id: "archive-api".to_owned(),
                name: "Archive API".to_owned(),
                kind: ProviderKind::HttpJson {
                    base_url: "https://catalog.example.invalid/v1".to_owned(),
                },
                enabled: false,
            },
        ];
        save_provider_configs(&path, &configs).unwrap();
        let loaded = load_provider_configs(&path);
        assert_eq!(loaded, configs);
    }

    #[tokio::test]
    async fn net_policy_blocks_requests_when_offline_or_online_disabled() {
        let policy = Arc::new(NetPolicy::default());
        let provider =
            HttpJsonProvider::new("bridge", "http://127.0.0.1:1", Arc::clone(&policy)).unwrap();

        policy.set_offline(true);
        assert_eq!(
            provider.search("signal", 10).await.unwrap_err(),
            SourceProviderError::Disabled
        );
        assert_eq!(
            provider.resolve_stream("trk-1").await.unwrap_err(),
            SourceProviderError::Disabled
        );
        assert_eq!(
            provider.fetch_metadata("trk-1").await.unwrap_err(),
            SourceProviderError::Disabled
        );

        policy.set_offline(false);
        policy.set_feature(Feature::Online, false);
        assert_eq!(
            provider.search("signal", 10).await.unwrap_err(),
            SourceProviderError::Disabled
        );
    }

    #[tokio::test]
    async fn search_stream_and_metadata_roundtrip_over_http_json() {
        let policy = Arc::new(NetPolicy::default());

        let search_url = serve_once(
            "200 OK",
            r#"{"tracks":[{"externalId":"trk-1","title":"Midnight Signal","artist":"Aurora Ensemble","album":"Telemetry","durationMs":245000}]}"#,
        );
        let search_provider =
            HttpJsonProvider::new("bridge", &search_url, Arc::clone(&policy)).unwrap();
        let tracks = search_provider.search("midnight", 5).await.unwrap();
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].provider_id, "bridge");
        assert_eq!(tracks[0].external_id, "trk-1");
        assert_eq!(tracks[0].title, "Midnight Signal");

        let stream_url = serve_once(
            "200 OK",
            r#"{"url":"https://cdn.example.invalid/audio/trk-1.flac","mimeType":"audio/flac","expiresAtMs":1800000000000}"#,
        );
        let stream_provider =
            HttpJsonProvider::new("bridge", &stream_url, Arc::clone(&policy)).unwrap();
        let resolved = stream_provider.resolve_stream("trk-1").await.unwrap();
        assert_eq!(resolved.url, "https://cdn.example.invalid/audio/trk-1.flac");
        assert_eq!(resolved.mime_type.as_deref(), Some("audio/flac"));

        let missing_url = serve_once("404 Not Found", r#"{"error":"not found"}"#);
        let missing_provider = HttpJsonProvider::new("bridge", &missing_url, policy).unwrap();
        assert_eq!(
            missing_provider
                .fetch_metadata("missing")
                .await
                .unwrap_err(),
            SourceProviderError::NotFound("missing".to_owned())
        );
    }
}

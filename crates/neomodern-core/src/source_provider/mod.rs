//! Neutral external source provider abstraction (K29).
//!
//! Defines generic interfaces and data types for user-configured external audio
//! catalog and stream providers. No built-in providers are registered by default.

use crate::net::NetPolicy;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, RwLock};

#[cfg(not(target_os = "android"))]
pub mod cli;
pub mod http_json;
pub mod subsonic;

#[cfg(not(target_os = "android"))]
pub use cli::{CliJsonProvider, parse_cli_endpoint};
pub use http_json::{
    HttpJsonProvider, load_provider_configs, save_provider_configs, validate_base_url,
};
pub use subsonic::{SubsonicProvider, parse_subsonic_endpoint};

/// Heap-allocated future used by [`SourceProvider`] trait methods so the trait
/// remains dyn-compatible without external macro crates.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Transport kind used by a configured external source provider.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum ProviderKind {
    /// HTTP JSON endpoint serving search, metadata, and stream resolution.
    HttpJson { base_url: String },
    /// OpenSubsonic / Subsonic / Navidrome REST API endpoint.
    Subsonic {
        base_url: String,
        username: String,
        password: String,
    },
    /// Local command-line adapter (desktop platforms only).
    #[cfg(not(target_os = "android"))]
    Cli { command: String, args: Vec<String> },
}

impl ProviderKind {
    /// Returns a human-readable, credential-redacted endpoint label for UI display.
    pub fn display_endpoint(&self) -> String {
        match self {
            ProviderKind::HttpJson { base_url } => base_url.clone(),
            ProviderKind::Subsonic {
                base_url, username, ..
            } => format!(
                "subsonic://{username}@{}",
                base_url
                    .trim_start_matches("https://")
                    .trim_start_matches("http://")
            ),
            #[cfg(not(target_os = "android"))]
            ProviderKind::Cli { command, args } => {
                if args.is_empty() {
                    format!("cli:{command}")
                } else {
                    format!("cli:{command} {}", args.join(" "))
                }
            }
        }
    }

    /// Short kind tag for UI badges (`httpJson`, `subsonic`, `cli`).
    pub fn kind_tag(&self) -> &'static str {
        match self {
            ProviderKind::HttpJson { .. } => "httpJson",
            ProviderKind::Subsonic { .. } => "subsonic",
            #[cfg(not(target_os = "android"))]
            ProviderKind::Cli { .. } => "cli",
        }
    }
}

/// Parses a user-entered endpoint string into a [`ProviderKind`]:
/// - `http://...` or `https://...` -> [`ProviderKind::HttpJson`]
/// - `subsonic://user:pass@host...` or `subsonics://...` -> [`ProviderKind::Subsonic`]
/// - `cli:<command> [args...]` (desktop only) -> [`ProviderKind::Cli`]
pub fn parse_provider_kind(raw: &str) -> Result<ProviderKind, SourceProviderError> {
    let trimmed = raw.trim();
    if trimmed.starts_with("subsonic://") || trimmed.starts_with("subsonics://") {
        let (base_url, username, password) = parse_subsonic_endpoint(trimmed)?;
        return Ok(ProviderKind::Subsonic {
            base_url,
            username,
            password,
        });
    }
    if trimmed.starts_with("cli:") {
        #[cfg(not(target_os = "android"))]
        {
            let (command, args) = parse_cli_endpoint(trimmed)?;
            return Ok(ProviderKind::Cli { command, args });
        }
        #[cfg(target_os = "android")]
        {
            return Err(SourceProviderError::Unsupported(
                "local CLI source providers are only supported on desktop".to_owned(),
            ));
        }
    }
    let normalized_url = validate_base_url(trimmed)?;
    Ok(ProviderKind::HttpJson {
        base_url: normalized_url,
    })
}

/// Constructs a concrete [`SourceProvider`] instance from any [`ProviderConfig`].
pub fn build_provider(
    config: &ProviderConfig,
    net_policy: Arc<NetPolicy>,
) -> Result<Arc<dyn SourceProvider>, SourceProviderError> {
    match &config.kind {
        ProviderKind::HttpJson { .. } => {
            Ok(Arc::new(HttpJsonProvider::from_config(config, net_policy)?))
        }
        ProviderKind::Subsonic { .. } => {
            Ok(Arc::new(SubsonicProvider::from_config(config, net_policy)?))
        }
        #[cfg(not(target_os = "android"))]
        ProviderKind::Cli { .. } => Ok(Arc::new(CliJsonProvider::from_config(config)?)),
    }
}

/// Configuration for a single external source provider entry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderConfig {
    pub id: String,
    pub name: String,
    pub kind: ProviderKind,
    pub enabled: bool,
}

/// Track metadata returned by an external source provider.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExternalTrack {
    pub provider_id: String,
    pub external_id: String,
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub duration_ms: Option<u64>,
    pub cover_url: Option<String>,
}

/// Playable audio stream URL and metadata resolved for an external track.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedStream {
    pub url: String,
    pub mime_type: Option<String>,
    pub expires_at_ms: Option<i64>,
}

/// Errors produced by external source providers or the provider registry.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SourceProviderError {
    #[error("source provider is disabled")]
    Disabled,
    #[error("external item not found: {0}")]
    NotFound(String),
    #[error("invalid provider configuration: {0}")]
    InvalidConfig(String),
    #[error("provider request failed: {0}")]
    Request(String),
    #[error("unsupported provider operation: {0}")]
    Unsupported(String),
}

/// Asynchronous interface implemented by an external audio source adapter.
pub trait SourceProvider: Send + Sync {
    /// Unique identifier for this provider instance.
    fn id(&self) -> &str;

    /// Search for tracks matching `query`, returning at most `limit` results.
    fn search(
        &self,
        query: &str,
        limit: usize,
    ) -> BoxFuture<'_, Result<Vec<ExternalTrack>, SourceProviderError>>;

    /// Resolve a playable stream URL for `external_id`.
    fn resolve_stream(
        &self,
        external_id: &str,
    ) -> BoxFuture<'_, Result<ResolvedStream, SourceProviderError>>;

    /// Fetch full metadata for `external_id`.
    fn fetch_metadata(
        &self,
        external_id: &str,
    ) -> BoxFuture<'_, Result<ExternalTrack, SourceProviderError>>;
}

/// Thread-safe registry of configured [`SourceProvider`] instances.
///
/// Starts completely empty by default.
#[derive(Default)]
pub struct ProviderRegistry {
    providers: RwLock<BTreeMap<String, Arc<dyn SourceProvider>>>,
}

impl ProviderRegistry {
    /// Creates an empty provider registry.
    pub fn new() -> Self {
        Self::default()
    }

    /// Registers a provider under its `id()`, returning any previously
    /// registered provider with the same id.
    pub fn register(&self, provider: Arc<dyn SourceProvider>) -> Option<Arc<dyn SourceProvider>> {
        let id = provider.id().to_owned();
        let mut guard = self
            .providers
            .write()
            .unwrap_or_else(|poison| poison.into_inner());
        guard.insert(id, provider)
    }

    /// Removes and returns the provider with `id`, if present.
    pub fn remove(&self, id: &str) -> Option<Arc<dyn SourceProvider>> {
        let mut guard = self
            .providers
            .write()
            .unwrap_or_else(|poison| poison.into_inner());
        guard.remove(id)
    }

    /// Returns all registered provider identifiers in sorted order.
    pub fn list_ids(&self) -> Vec<String> {
        let guard = self
            .providers
            .read()
            .unwrap_or_else(|poison| poison.into_inner());
        guard.keys().cloned().collect()
    }

    /// Looks up a registered provider by `id`.
    pub fn get(&self, id: &str) -> Option<Arc<dyn SourceProvider>> {
        let guard = self
            .providers
            .read()
            .unwrap_or_else(|poison| poison.into_inner());
        guard.get(id).cloned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct MockProvider {
        id: String,
        tracks: Vec<ExternalTrack>,
    }

    impl SourceProvider for MockProvider {
        fn id(&self) -> &str {
            &self.id
        }

        fn search(
            &self,
            query: &str,
            limit: usize,
        ) -> BoxFuture<'_, Result<Vec<ExternalTrack>, SourceProviderError>> {
            let needle = query.to_ascii_lowercase();
            let items: Vec<ExternalTrack> = self
                .tracks
                .iter()
                .filter(|t| {
                    t.title.to_ascii_lowercase().contains(&needle)
                        || t.artist.to_ascii_lowercase().contains(&needle)
                })
                .take(limit)
                .cloned()
                .collect();
            Box::pin(async move { Ok(items) })
        }

        fn resolve_stream(
            &self,
            external_id: &str,
        ) -> BoxFuture<'_, Result<ResolvedStream, SourceProviderError>> {
            let found = self.tracks.iter().any(|t| t.external_id == external_id);
            let id = external_id.to_owned();
            Box::pin(async move {
                if found {
                    Ok(ResolvedStream {
                        url: format!("https://stream.example.invalid/audio/{id}"),
                        mime_type: Some("audio/flac".to_owned()),
                        expires_at_ms: Some(1_800_000_000_000),
                    })
                } else {
                    Err(SourceProviderError::NotFound(id))
                }
            })
        }

        fn fetch_metadata(
            &self,
            external_id: &str,
        ) -> BoxFuture<'_, Result<ExternalTrack, SourceProviderError>> {
            let track = self
                .tracks
                .iter()
                .find(|t| t.external_id == external_id)
                .cloned();
            let id = external_id.to_owned();
            Box::pin(async move { track.ok_or(SourceProviderError::NotFound(id)) })
        }
    }

    fn sample_provider(id: &str) -> Arc<dyn SourceProvider> {
        Arc::new(MockProvider {
            id: id.to_owned(),
            tracks: vec![
                ExternalTrack {
                    provider_id: id.to_owned(),
                    external_id: "trk-1".to_owned(),
                    title: "Midnight Signal".to_owned(),
                    artist: "Aurora Ensemble".to_owned(),
                    album: Some("Telemetry".to_owned()),
                    duration_ms: Some(245_000),
                    cover_url: Some("https://cdn.example.invalid/cover/1.jpg".to_owned()),
                },
                ExternalTrack {
                    provider_id: id.to_owned(),
                    external_id: "trk-2".to_owned(),
                    title: "Solar Drift".to_owned(),
                    artist: "Aurora Ensemble".to_owned(),
                    album: None,
                    duration_ms: None,
                    cover_url: None,
                },
            ],
        })
    }

    #[test]
    fn registry_starts_empty_by_default() {
        let reg = ProviderRegistry::new();
        assert!(reg.list_ids().is_empty());
        assert!(reg.get("anything").is_none());

        let def = ProviderRegistry::default();
        assert!(def.list_ids().is_empty());
    }

    #[tokio::test]
    async fn registry_registers_queries_and_removes_mock_provider() {
        let reg = ProviderRegistry::new();
        assert!(reg.register(sample_provider("mock-a")).is_none());
        assert_eq!(reg.list_ids(), vec!["mock-a".to_owned()]);

        let provider = reg.get("mock-a").expect("registered provider exists");
        assert_eq!(provider.id(), "mock-a");

        let hits = provider.search("midnight", 10).await.unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].external_id, "trk-1");

        let limited = provider.search("aurora", 1).await.unwrap();
        assert_eq!(limited.len(), 1);

        let stream = provider.resolve_stream("trk-1").await.unwrap();
        assert_eq!(stream.url, "https://stream.example.invalid/audio/trk-1");
        assert_eq!(stream.mime_type.as_deref(), Some("audio/flac"));

        let meta = provider.fetch_metadata("trk-2").await.unwrap();
        assert_eq!(meta.title, "Solar Drift");

        assert_eq!(
            provider.resolve_stream("missing").await.unwrap_err(),
            SourceProviderError::NotFound("missing".to_owned())
        );

        let removed = reg.remove("mock-a");
        assert!(removed.is_some());
        assert!(reg.list_ids().is_empty());
        assert!(reg.get("mock-a").is_none());
        assert!(reg.remove("mock-a").is_none());
    }

    #[test]
    fn config_serializes_cleanly() {
        let cfg = ProviderConfig {
            id: "catalog-1".to_owned(),
            name: "Custom Catalog".to_owned(),
            kind: ProviderKind::HttpJson {
                base_url: "https://catalog.example.invalid/api".to_owned(),
            },
            enabled: true,
        };
        let json = serde_json::to_string(&cfg).unwrap();
        let roundtrip: ProviderConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(roundtrip, cfg);
    }
}

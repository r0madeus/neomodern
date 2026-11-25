//! Shared HTTP client setup.

/// A reqwest builder with the platform's TLS set up.
///
/// Android: rustls (ring) with the Mozilla root store. reqwest's default
/// rustls setup uses the platform verifier, which needs JNI setup on
/// Android, and native-tls would mean cross-compiling OpenSSL. Desktop
/// uses the system TLS (native-tls).
pub fn client_builder() -> reqwest::ClientBuilder {
    let builder = reqwest::Client::builder();
    #[cfg(target_os = "android")]
    let builder = builder.tls_backend_preconfigured(android_tls());
    builder
}

#[cfg(target_os = "android")]
fn android_tls() -> rustls::ClientConfig {
    let roots = rustls::RootCertStore {
        roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
    };
    rustls::ClientConfig::builder_with_provider(std::sync::Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .expect("ring supports the default TLS versions")
    .with_root_certificates(roots)
    .with_no_client_auth()
}

/// Why a size-limited body read failed.
#[derive(Debug, thiserror::Error)]
pub enum BodyError {
    #[error("http error: {0}")]
    Http(#[from] reqwest::Error),
    #[error("response is larger than {limit} bytes")]
    TooLarge { limit: usize },
    #[error("unexpected response: {0}")]
    Json(#[from] serde_json::Error),
}

/// Reads a response body into memory, refusing anything over `limit` bytes.
///
/// A declared `Content-Length` over the limit is refused before any byte is
/// read; otherwise the body is read chunk by chunk and abandoned as soon as
/// the total would exceed the limit (chunked or lying servers).
pub async fn read_body_limited(
    mut resp: reqwest::Response,
    limit: usize,
) -> Result<Vec<u8>, BodyError> {
    if resp.content_length().is_some_and(|n| n > limit as u64) {
        return Err(BodyError::TooLarge { limit });
    }
    let mut out = Vec::new();
    while let Some(chunk) = resp.chunk().await? {
        if out.len() + chunk.len() > limit {
            return Err(BodyError::TooLarge { limit });
        }
        out.extend_from_slice(&chunk);
    }
    Ok(out)
}

/// [`read_body_limited`] decoded as UTF-8 (invalid bytes are replaced).
pub async fn read_text_limited(resp: reqwest::Response, limit: usize) -> Result<String, BodyError> {
    let bytes = read_body_limited(resp, limit).await?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// [`read_body_limited`] parsed as JSON.
pub async fn read_json_limited<T: serde::de::DeserializeOwned>(
    resp: reqwest::Response,
    limit: usize,
) -> Result<T, BodyError> {
    let bytes = read_body_limited(resp, limit).await?;
    Ok(serde_json::from_slice(&bytes)?)
}

/// The internet-related features the user can switch off in Settings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Feature {
    /// Lyrics from LRCLIB / NetEase and "Share on LRCLIB".
    Lyrics,
    /// Online search, streaming and downloads (yt-dlp, iTunes).
    Online,
    /// Artist portrait, bio and missing albums.
    ArtistInfo,
    /// "Find info" (MusicBrainz, Cover Art Archive).
    Metadata,
    /// New-version check.
    Updates,
}

impl Feature {
    pub const ALL: [Feature; 5] = [
        Feature::Lyrics,
        Feature::Online,
        Feature::ArtistInfo,
        Feature::Metadata,
        Feature::Updates,
    ];

    fn index(self) -> usize {
        self as usize
    }
}

/// The message every refused network call returns.
pub const DISABLED_MESSAGE: &str = "disabled in Settings";

/// Whether the app may contact the internet. Shared by the session store
/// (which persists it) and every service that makes requests; this is the
/// single place that decides. Offline mode wins over the per-feature
/// switches.
#[derive(Debug)]
pub struct NetPolicy {
    offline: std::sync::atomic::AtomicBool,
    features: [std::sync::atomic::AtomicBool; 5],
}

impl Default for NetPolicy {
    fn default() -> Self {
        use std::sync::atomic::AtomicBool;
        Self {
            offline: AtomicBool::new(false),
            features: std::array::from_fn(|_| AtomicBool::new(true)),
        }
    }
}

impl NetPolicy {
    /// May `feature` make network requests right now?
    pub fn allowed(&self, feature: Feature) -> bool {
        use std::sync::atomic::Ordering::SeqCst;
        !self.offline.load(SeqCst) && self.features[feature.index()].load(SeqCst)
    }

    /// `Err("disabled in Settings")` when `feature` is not allowed.
    pub fn require(&self, feature: Feature) -> Result<(), &'static str> {
        if self.allowed(feature) {
            Ok(())
        } else {
            Err(DISABLED_MESSAGE)
        }
    }

    pub fn offline(&self) -> bool {
        self.offline.load(std::sync::atomic::Ordering::SeqCst)
    }

    pub fn set_offline(&self, on: bool) {
        self.offline.store(on, std::sync::atomic::Ordering::SeqCst);
    }

    /// The user's own switch for `feature`, ignoring offline mode.
    pub fn feature_enabled(&self, feature: Feature) -> bool {
        self.features[feature.index()].load(std::sync::atomic::Ordering::SeqCst)
    }

    pub fn set_feature(&self, feature: Feature, on: bool) {
        self.features[feature.index()].store(on, std::sync::atomic::Ordering::SeqCst);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::{AudioEngine, EngineResult, NetGuardedEngine, ReplayGain};
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, Mutex};

    #[test]
    fn offline_mode_wins_over_every_feature_switch() {
        let p = NetPolicy::default();
        for f in Feature::ALL {
            assert!(p.allowed(f));
            assert_eq!(p.require(f), Ok(()));
        }
        p.set_feature(Feature::Metadata, false);
        assert!(!p.allowed(Feature::Metadata));
        assert_eq!(p.require(Feature::Metadata), Err("disabled in Settings"));
        assert!(p.allowed(Feature::Lyrics));
        p.set_offline(true);
        for f in Feature::ALL {
            assert!(!p.allowed(f), "{f:?}");
        }
        // The user's own switches are kept for when offline mode ends.
        assert!(p.feature_enabled(Feature::Lyrics));
        p.set_offline(false);
        assert!(p.allowed(Feature::Lyrics));
        assert!(!p.allowed(Feature::Metadata));
    }

    #[test]
    fn feature_names_match_the_ui() {
        let names: Vec<String> = Feature::ALL
            .iter()
            .map(|f| serde_json::to_string(f).unwrap())
            .collect();
        assert_eq!(
            names,
            [
                "\"lyrics\"",
                "\"online\"",
                "\"artistInfo\"",
                "\"metadata\"",
                "\"updates\""
            ]
        );
    }

    #[derive(Default, Clone)]
    struct Recorder(Arc<Mutex<Vec<String>>>);

    impl AudioEngine for Recorder {
        fn load(&self, p: &Path) -> EngineResult<()> {
            self.0.lock().unwrap().push(format!("load {}", p.display()));
            Ok(())
        }
        fn set_next(&self, p: Option<&Path>) -> EngineResult<()> {
            let what = p.map_or("none".into(), |p| p.display().to_string());
            self.0.lock().unwrap().push(format!("next {what}"));
            Ok(())
        }
        fn play(&self) -> EngineResult<()> {
            Ok(())
        }
        fn pause(&self) -> EngineResult<()> {
            Ok(())
        }
        fn stop(&self) -> EngineResult<()> {
            Ok(())
        }
        fn seek(&self, _: f64) -> EngineResult<()> {
            Ok(())
        }
        fn set_volume(&self, _: f64) -> EngineResult<()> {
            Ok(())
        }
        fn set_replaygain(&self, _: ReplayGain) -> EngineResult<()> {
            Ok(())
        }
        fn set_gapless(&self, _: bool) -> EngineResult<()> {
            Ok(())
        }
        fn set_wasapi_exclusive(&self, _: bool) -> EngineResult<()> {
            Ok(())
        }
    }

    #[test]
    fn streams_are_not_handed_to_the_engine_when_online_is_off() {
        let rec = Recorder::default();
        let policy = Arc::new(NetPolicy::default());
        let engine = NetGuardedEngine::new(Box::new(rec.clone()), Arc::clone(&policy));
        let stream = PathBuf::from("https://cdn.example/a?x=1");
        let file = PathBuf::from("/music/a.flac");

        engine.load(&stream).unwrap();
        policy.set_offline(true);
        assert!(engine.load(&stream).is_err());
        engine.load(&file).unwrap();
        engine.set_next(Some(&stream)).unwrap();
        engine.set_next(Some(&file)).unwrap();
        policy.set_offline(false);
        policy.set_feature(Feature::Online, false);
        assert!(engine.load(&stream).is_err());
        // Only the online switch matters for streams.
        policy.set_feature(Feature::Online, true);
        policy.set_feature(Feature::Lyrics, false);
        engine.load(&stream).unwrap();

        assert_eq!(
            *rec.0.lock().unwrap(),
            [
                "load https://cdn.example/a?x=1",
                "load /music/a.flac",
                "next none",
                "next /music/a.flac",
                "load https://cdn.example/a?x=1",
            ]
        );
    }

    fn rust_sources(dir: &Path, out: &mut Vec<PathBuf>) {
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                rust_sources(&path, out);
            } else if path.extension().is_some_and(|e| e == "rs")
                && path.file_name().is_some_and(|n| n != "tests.rs")
            {
                out.push(path);
            }
        }
    }

    /// Guard: every place that builds an HTTP client, opens a socket or
    /// starts an external program must be a known, gated one. When this fails after adding a
    /// network feature, route it through `NetPolicy` (see the other tests),
    /// then add it here.
    #[test]
    fn every_network_entry_point_is_known_and_gated() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut files = Vec::new();
        rust_sources(&root, &mut files);
        let count = |text: &str, needle: &str| text.matches(needle).count();

        // (file, needle, expected count): how each is gated.
        let allowed: &[(&str, &str, usize)] = &[
            // LRCLIB: every request via LrclibClient::http() (lyrics switch).
            ("lyrics/lrclib.rs", "client_builder()", 1),
            // NetEase: via NeteaseClient::http() (lyrics switch).
            ("lyrics/netease.rs", "client_builder()", 1),
            // MusicBrainz and Cover Art Archive: via MbClient::http().
            ("metadata/musicbrainz.rs", "client_builder()", 1),
            // Online search, streaming, downloads and artist info: via OnlineService::http().
            ("online/mod.rs", "client_builder()", 1),
            ("online/mod.rs", "reqwest::Client::new()", 1),
            ("online/mod.rs", "Command::new(", 3),
            ("online/tools.rs", "client_builder()", 1),
            // Update check: update::check_at() requires Feature::Updates.
            ("update.rs", "client_builder()", 1),
            // External SourceProvider HTTP/JSON: gated by Feature::Online via HttpJsonProvider::http().
            ("source_provider/http_json.rs", "client_builder()", 1),
            // PC <-> phone sync (docs/SYNC.md): LAN only, never the
            // internet. The listener (IPv4 + best-effort IPv6) drops
            // non-private sources and is off by default: the sync service
            // binds only while the user's "Allow phone connections" switch
            // is on. The dialer refuses non-private targets and is only
            // used for an explicit pairing or for a PC paired before.
            ("sync/link/server.rs", "TcpListener::bind(", 2),
            ("sync/link/server.rs", "TcpStream::connect(", 1),
            // UDP sockets, three, all LAN-only: (1) local route lookup for
            // showing the PC's LAN address (a UDP connect sends no packet);
            // (2) the desktop's discovery responder, bound only while "Allow
            // phone connections" is on, answering exact probes from LAN
            // addresses with a small rate-limited unicast reply; (3) the
            // phone's discovery probe (broadcast, sent only when the user
            // opens the "Find computers" list or taps search).
            ("sync/link/server.rs", "UdpSocket::bind(", 3),
        ];
        let mut seen = std::collections::HashMap::new();
        for f in &files {
            let rel = f
                .strip_prefix(&root)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/");
            if rel == "net.rs" {
                continue;
            }
            // Strip the unit-test module of the file, if inline.
            // Windows checkouts may have CRLF line endings; normalise so the
            // test-module split below also works there.
            let text = std::fs::read_to_string(f).unwrap().replace("\r\n", "\n");
            let text = text.split("#[cfg(test)]\nmod tests {").next().unwrap();
            for needle in [
                "client_builder()",
                "reqwest::Client::new()",
                "reqwest::Client::builder()",
                "reqwest::get(",
                "Command::new(",
                "Command::new (",
                "TcpListener::bind(",
                "TcpStream::connect(",
                "UdpSocket::bind(",
                "TcpSocket::new",
            ] {
                let n = count(text, needle);
                if n > 0 {
                    seen.insert((rel.clone(), needle), n);
                }
            }
        }
        let want: std::collections::HashMap<_, _> = allowed
            .iter()
            .map(|(f, n, c)| ((f.to_string(), *n), *c))
            .collect();
        assert_eq!(
            seen, want,
            "a new HTTP client, socket or external program appeared: gate it \
             (NetPolicy, or the sync switch for LAN sockets) and list it here"
        );

        // Each gated client is only reachable through its gate method: the
        // raw field may be touched exactly once, inside that method.
        for (file, field) in [
            ("lyrics/lrclib.rs", "self.http"),
            ("lyrics/netease.rs", "self.http"),
            ("metadata/musicbrainz.rs", "self.http"),
            ("online/mod.rs", "self.client"),
        ] {
            let text = std::fs::read_to_string(root.join(file)).unwrap();
            let text = text.split("#[cfg(test)]").next().unwrap();
            let raw = text
                .match_indices(field)
                .filter(|(i, _)| !text[i + field.len()..].starts_with("()"))
                .count();
            assert_eq!(raw, 1, "{file}: `{field}` used outside its gate method");
        }
    }
}

#[cfg(test)]
mod body_tests {
    use super::*;
    use std::io::{Read, Write};

    /// Serves one canned raw HTTP response, returns the URL.
    fn serve(raw: Vec<u8>) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/", listener.local_addr().unwrap());
        std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 2048];
                let _ = stream.read(&mut buf);
                let _ = stream.write_all(&raw);
            }
        });
        url
    }

    fn with_length(body: &str) -> Vec<u8> {
        format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
        .into_bytes()
    }

    fn chunked(body: &str) -> Vec<u8> {
        format!(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{:x}\r\n{body}\r\n0\r\n\r\n",
            body.len()
        )
        .into_bytes()
    }

    async fn get(url: &str) -> reqwest::Response {
        reqwest::Client::new().get(url).send().await.unwrap()
    }

    #[tokio::test]
    async fn body_under_the_limit_is_read() {
        let url = serve(with_length("{\"a\":1}"));
        let value: serde_json::Value = read_json_limited(get(&url).await, 64).await.unwrap();
        assert_eq!(value["a"], 1);
    }

    #[tokio::test]
    async fn text_is_decoded_lossily() {
        let mut raw = b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\n".to_vec();
        raw.extend_from_slice(&[b'a', 0xff, b'b']);
        let url = serve(raw);
        let text = read_text_limited(get(&url).await, 16).await.unwrap();
        assert_eq!(text, "a\u{fffd}b");
    }

    #[tokio::test]
    async fn declared_length_over_the_limit_is_refused() {
        let url = serve(with_length(&"x".repeat(100)));
        let err = read_body_limited(get(&url).await, 10).await.unwrap_err();
        assert!(matches!(err, BodyError::TooLarge { limit: 10 }));
    }

    #[tokio::test]
    async fn chunked_body_over_the_limit_is_refused() {
        let url = serve(chunked(&"x".repeat(100)));
        let resp = get(&url).await;
        assert!(resp.content_length().is_none());
        let err = read_body_limited(resp, 10).await.unwrap_err();
        assert!(matches!(err, BodyError::TooLarge { limit: 10 }));
    }

    #[tokio::test]
    async fn invalid_json_is_a_json_error() {
        let url = serve(with_length("nope"));
        let err = read_json_limited::<serde_json::Value>(get(&url).await, 64)
            .await
            .unwrap_err();
        assert!(matches!(err, BodyError::Json(_)));
    }
}

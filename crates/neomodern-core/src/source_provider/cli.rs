//! Neutral local CLI/JSON external source provider (K29, desktop only).
//!
//! Invokes a user-configured local executable with a JSON request on stdin and
//! reads a JSON response from stdout, enforcing a strict timeout and output cap:
//! - Request:
//!   - `{"op":"search","query":"...","limit":20}`
//!   - `{"op":"resolveStream","externalId":"..."}`
//!   - `{"op":"fetchMetadata","externalId":"..."}`
//! - Response:
//!   - `search`: `Vec<ExternalTrack>` or `{"tracks":[...]}`
//!   - `resolveStream`: `ResolvedStream`
//!   - `fetchMetadata`: `ExternalTrack`

use super::{
    BoxFuture, ExternalTrack, ProviderConfig, ProviderKind, ResolvedStream, SourceProvider,
    SourceProviderError,
};
use reqwest::Url;
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const CLI_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_STDOUT_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, Serialize)]
#[serde(tag = "op", rename_all = "camelCase")]
enum CliRequest<'a> {
    Search {
        query: &'a str,
        limit: usize,
    },
    #[serde(rename_all = "camelCase")]
    ResolveStream {
        external_id: &'a str,
    },
    #[serde(rename_all = "camelCase")]
    FetchMetadata {
        external_id: &'a str,
    },
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

/// Validates and parses a `cli:<command> [args...]` specification string.
pub fn parse_cli_endpoint(raw: &str) -> Result<(String, Vec<String>), SourceProviderError> {
    let trimmed = raw.trim();
    let rest = trimmed
        .strip_prefix("cli:")
        .ok_or_else(|| {
            SourceProviderError::InvalidConfig("CLI endpoint must start with 'cli:'".to_owned())
        })?
        .trim();
    if rest.is_empty() {
        return Err(SourceProviderError::InvalidConfig(
            "CLI command must not be empty".to_owned(),
        ));
    }
    let tokens = split_args(rest)?;
    let (command, args) = tokens.split_first().ok_or_else(|| {
        SourceProviderError::InvalidConfig("CLI command must not be empty".into())
    })?;
    if command.trim().is_empty() {
        return Err(SourceProviderError::InvalidConfig(
            "CLI command must not be empty".to_owned(),
        ));
    }
    Ok((command.clone(), args.to_vec()))
}

fn split_args(input: &str) -> Result<Vec<String>, SourceProviderError> {
    let mut out = Vec::new();
    let mut current = String::new();
    let mut in_single = false;
    let mut in_double = false;
    let mut escape = false;

    for ch in input.chars() {
        if escape {
            current.push(ch);
            escape = false;
            continue;
        }
        if ch == '\\' && !in_single {
            escape = true;
            continue;
        }
        if ch == '\'' && !in_double {
            in_single = !in_single;
            continue;
        }
        if ch == '"' && !in_single {
            in_double = !in_double;
            continue;
        }
        if ch.is_whitespace() && !in_single && !in_double {
            if !current.is_empty() {
                out.push(std::mem::take(&mut current));
            }
            continue;
        }
        current.push(ch);
    }

    if in_single || in_double {
        return Err(SourceProviderError::InvalidConfig(
            "unterminated quote in CLI provider command".to_owned(),
        ));
    }
    if !current.is_empty() {
        out.push(current);
    }
    Ok(out)
}

fn validate_stream_url(raw: &str) -> Result<String, SourceProviderError> {
    let trimmed = raw.trim();
    let url = Url::parse(trimmed).map_err(|e| {
        SourceProviderError::Request(format!("CLI provider returned invalid stream URL: {e}"))
    })?;
    match url.scheme() {
        "http" | "https" if url.host_str().is_some_and(|h| !h.is_empty()) => Ok(url.into()),
        _ => Err(SourceProviderError::Request(
            "CLI provider returned unsupported stream URL scheme".to_owned(),
        )),
    }
}

/// Local CLI/JSON [`SourceProvider`] executing a user-configured desktop binary.
#[derive(Debug, Clone)]
pub struct CliJsonProvider {
    id: String,
    command: String,
    args: Vec<String>,
    timeout: Duration,
}

impl CliJsonProvider {
    /// Creates a new local CLI provider after validating the command string.
    pub fn new(
        id: impl Into<String>,
        command: impl Into<String>,
        args: Vec<String>,
    ) -> Result<Self, SourceProviderError> {
        let id = id.into();
        if id.trim().is_empty() {
            return Err(SourceProviderError::InvalidConfig(
                "provider id must not be empty".to_owned(),
            ));
        }
        let command = command.into().trim().to_owned();
        if command.is_empty() {
            return Err(SourceProviderError::InvalidConfig(
                "CLI command must not be empty".to_owned(),
            ));
        }
        Ok(Self {
            id,
            command,
            args,
            timeout: CLI_TIMEOUT,
        })
    }

    /// Constructs a [`CliJsonProvider`] from a [`ProviderConfig`].
    pub fn from_config(config: &ProviderConfig) -> Result<Self, SourceProviderError> {
        match &config.kind {
            ProviderKind::Cli { command, args } => {
                Self::new(config.id.clone(), command.clone(), args.clone())
            }
            _ => Err(SourceProviderError::InvalidConfig(
                "expected CLI provider config".to_owned(),
            )),
        }
    }

    fn run_blocking(
        command: &str,
        args: &[String],
        payload: &[u8],
        timeout: Duration,
    ) -> Result<Vec<u8>, SourceProviderError> {
        let mut child = Command::new(command)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| {
                SourceProviderError::Request(format!("failed to spawn '{command}': {e}"))
            })?;

        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(payload);
            let _ = stdin.write_all(b"\n");
        }

        let mut stdout = child.stdout.take().ok_or_else(|| {
            SourceProviderError::Request("CLI provider stdout unavailable".into())
        })?;
        let mut stderr = child.stderr.take();

        let stdout_handle = std::thread::spawn(move || {
            let mut buf = Vec::new();
            let mut limited = (&mut stdout).take((MAX_STDOUT_BYTES + 1) as u64);
            let res = limited.read_to_end(&mut buf);
            (buf, res)
        });

        let deadline = Instant::now() + timeout;
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break status,
                Ok(None) => {
                    if Instant::now() >= deadline {
                        let _ = child.kill();
                        let _ = child.wait();
                        return Err(SourceProviderError::Request(format!(
                            "CLI provider timed out after {}s",
                            timeout.as_secs()
                        )));
                    }
                    std::thread::sleep(Duration::from_millis(15));
                }
                Err(e) => {
                    let _ = child.kill();
                    return Err(SourceProviderError::Request(format!(
                        "failed while waiting for CLI provider: {e}"
                    )));
                }
            }
        };

        let (buf, read_res) = stdout_handle.join().map_err(|_| {
            SourceProviderError::Request("CLI stdout reader thread panicked".into())
        })?;
        read_res
            .map_err(|e| SourceProviderError::Request(format!("failed reading CLI stdout: {e}")))?;

        if !status.success() {
            let mut err_text = String::new();
            if let Some(s) = stderr.take() {
                let _ = s.take(2048).read_to_string(&mut err_text);
            }
            let detail = err_text.trim();
            return Err(SourceProviderError::Request(if detail.is_empty() {
                format!("CLI provider exited with status {status}")
            } else {
                format!("CLI provider exited with status {status}: {detail}")
            }));
        }

        if buf.len() > MAX_STDOUT_BYTES {
            return Err(SourceProviderError::Request(format!(
                "CLI provider output exceeded {MAX_STDOUT_BYTES} bytes"
            )));
        }

        Ok(buf)
    }

    async fn invoke(&self, req: &CliRequest<'_>) -> Result<Vec<u8>, SourceProviderError> {
        let payload = serde_json::to_vec(req)
            .map_err(|e| SourceProviderError::Request(format!("failed to encode request: {e}")))?;
        let command = self.command.clone();
        let args = self.args.clone();
        let timeout = self.timeout;
        tokio::task::spawn_blocking(move || Self::run_blocking(&command, &args, &payload, timeout))
            .await
            .map_err(|e| SourceProviderError::Request(format!("CLI task join error: {e}")))?
    }
}

impl SourceProvider for CliJsonProvider {
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
            let raw = self
                .invoke(&CliRequest::Search {
                    query: &query,
                    limit,
                })
                .await?;
            let parsed: SearchResponse = serde_json::from_slice(&raw).map_err(|e| {
                SourceProviderError::Request(format!("invalid CLI JSON search response: {e}"))
            })?;
            let tracks = match parsed {
                SearchResponse::Array(v) => v,
                SearchResponse::Object { tracks } => tracks,
            };
            Ok(tracks
                .into_iter()
                .take(limit)
                .map(|t| t.into_external_track(&self.id))
                .collect())
        })
    }

    fn resolve_stream(
        &self,
        external_id: &str,
    ) -> BoxFuture<'_, Result<ResolvedStream, SourceProviderError>> {
        let external_id = external_id.trim().to_owned();
        Box::pin(async move {
            if external_id.is_empty() {
                return Err(SourceProviderError::InvalidConfig(
                    "external track id must not be empty".to_owned(),
                ));
            }
            let raw = self
                .invoke(&CliRequest::ResolveStream {
                    external_id: &external_id,
                })
                .await?;
            let mut stream: ResolvedStream = serde_json::from_slice(&raw).map_err(|e| {
                SourceProviderError::Request(format!("invalid CLI JSON stream response: {e}"))
            })?;
            stream.url = validate_stream_url(&stream.url)?;
            Ok(stream)
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
            let raw = self
                .invoke(&CliRequest::FetchMetadata {
                    external_id: &external_id,
                })
                .await?;
            let wire: WireExternalTrack = serde_json::from_slice(&raw).map_err(|e| {
                SourceProviderError::Request(format!("invalid CLI JSON metadata response: {e}"))
            })?;
            Ok(wire.into_external_track(&self.id))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cli_endpoint_handles_quotes_and_args() {
        let (cmd, args) = parse_cli_endpoint("cli:/usr/local/bin/adapter --mode \"fast json\" -v")
            .expect("valid cli endpoint");
        assert_eq!(cmd, "/usr/local/bin/adapter");
        assert_eq!(args, vec!["--mode", "fast json", "-v"]);

        assert!(parse_cli_endpoint("https://example.com").is_err());
        assert!(parse_cli_endpoint("cli:   ").is_err());
        assert!(parse_cli_endpoint("cli:foo \"unterminated").is_err());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn cli_provider_executes_search_and_resolve_stream() {
        let script = r#"
import json, sys
req = json.loads(sys.stdin.readline())
op = req["op"]
if op == "search":
    print(json.dumps({"tracks": [{"externalId": "c1", "title": req["query"], "artist": "CLI Artist", "durationMs": 123000}]}))
elif op == "resolveStream":
    print(json.dumps({"url": "https://cdn.example.invalid/audio/" + req["externalId"] + ".flac", "mimeType": "audio/flac"}))
elif op == "fetchMetadata":
    print(json.dumps({"externalId": req["externalId"], "title": "Meta Title", "artist": "CLI Artist"}))
"#;
        let provider =
            CliJsonProvider::new("local-cli", "python3", vec!["-c".into(), script.into()])
                .expect("provider");

        let found = provider.search("Sunson", 5).await.expect("search");
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].provider_id, "local-cli");
        assert_eq!(found[0].external_id, "c1");
        assert_eq!(found[0].title, "Sunson");

        let stream = provider.resolve_stream("c1").await.expect("stream");
        assert_eq!(stream.url, "https://cdn.example.invalid/audio/c1.flac");
        assert_eq!(stream.mime_type.as_deref(), Some("audio/flac"));

        let meta = provider.fetch_metadata("c1").await.expect("meta");
        assert_eq!(meta.title, "Meta Title");
    }
}

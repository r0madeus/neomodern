//! "A new version is available" check against the project's GitHub
//! releases. On Android (arm64) the release APK can also be downloaded,
//! checked against the release's SHA-256 list and handed to the system
//! installer; on desktop the user downloads the installer from the page.

use crate::net::{Feature, NetPolicy};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::time::Duration;

const LATEST_URL: &str = "https://api.github.com/repos/r0madeus/neomodern/releases/latest";
/// Only release pages of this project may be opened from the app.
pub const RELEASES_PREFIX: &str = "https://github.com/r0madeus/neomodern/releases/";
/// Release files are only downloaded from here.
const DOWNLOAD_PREFIX: &str = "https://github.com/r0madeus/neomodern/releases/download/";
/// The checksum list the release workflow uploads next to the APK.
const APK_SUMS: &str = "SHA256SUMS-android.txt";

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateInfo {
    /// Version of the latest release, without the leading `v`.
    pub version: String,
    /// Release page.
    pub url: String,
    /// This device can install it from inside the app (Android arm64 and
    /// the release has a signed APK).
    pub installable: bool,
}

/// Progress of an in-app update download.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DownloadProgress {
    pub received: u64,
    pub total: Option<u64>,
}

#[derive(Deserialize)]
struct Release {
    tag_name: String,
    html_url: String,
    #[serde(default)]
    draft: bool,
    #[serde(default)]
    prerelease: bool,
    #[serde(default)]
    assets: Vec<Asset>,
}

#[derive(Deserialize, Clone)]
struct Asset {
    name: String,
    browser_download_url: String,
}

/// The release APK for arm64 phones and its checksum list. A `-testkey`
/// APK is skipped: it is signed with a throwaway key and cannot be
/// installed over the installed app.
fn pick_apk(assets: &[Asset]) -> Option<(Asset, Asset)> {
    let ok = |a: &&Asset| a.browser_download_url.starts_with(DOWNLOAD_PREFIX);
    let apk = assets
        .iter()
        .filter(ok)
        .find(|a| a.name.starts_with("NeoModern-") && a.name.ends_with("-android-arm64.apk"))?;
    let sums = assets.iter().filter(ok).find(|a| a.name == APK_SUMS)?;
    Some((apk.clone(), sums.clone()))
}

/// The SHA-256 listed for `name` in a `sha256sum` list.
fn checksum_for(list: &str, name: &str) -> Option<String> {
    list.lines().find_map(|line| {
        let mut parts = line.split_whitespace();
        let hash = parts.next()?;
        let file = parts.next()?.trim_start_matches('*');
        (file == name && hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit()))
            .then(|| hash.to_ascii_lowercase())
    })
}

/// In-app install is offered on arm64 Android only (the release APK is
/// built for arm64).
fn device_can_install() -> bool {
    cfg!(target_os = "android") && std::env::consts::ARCH == "aarch64"
}

fn client(timeout: Duration) -> Result<reqwest::Client, reqwest::Error> {
    crate::net::client_builder()
        .user_agent(concat!("NeoModern/", env!("CARGO_PKG_VERSION")))
        .connect_timeout(Duration::from_secs(10))
        .read_timeout(Duration::from_secs(60))
        .timeout(timeout)
        .build()
}

/// `x.y.z` (a leading `v`, missing parts and a `-suffix` are allowed) as
/// numbers; `None` if it is not a version.
fn parse(version: &str) -> Option<[u64; 3]> {
    let core = version.trim().trim_start_matches('v');
    let core = core.split(['-', '+']).next()?;
    let mut out = [0u64; 3];
    let mut parts = core.split('.');
    for slot in out.iter_mut() {
        match parts.next() {
            Some(p) => *slot = p.parse().ok()?,
            None => break,
        }
    }
    if parts.next().is_some() {
        return None;
    }
    Some(out)
}

/// Whether `latest` is a newer version than `current`.
pub fn is_newer(latest: &str, current: &str) -> bool {
    match (parse(latest), parse(current)) {
        (Some(l), Some(c)) => l > c,
        _ => false,
    }
}

/// The latest release if it is newer than `current`.
pub async fn check(current: &str, policy: &NetPolicy) -> Result<Option<UpdateInfo>, String> {
    check_at(LATEST_URL, current, policy).await
}

/// [`check`] against another address (tests).
async fn check_at(
    url: &str,
    current: &str,
    policy: &NetPolicy,
) -> Result<Option<UpdateInfo>, String> {
    policy.require(Feature::Updates).map_err(str::to_owned)?;
    fetch_release(url, current).await.map_err(|e| e.to_string())
}

async fn fetch_release(url: &str, current: &str) -> Result<Option<UpdateInfo>, reqwest::Error> {
    Ok(newer_release(url, current).await?.map(|r| UpdateInfo {
        version: r.tag_name.trim_start_matches('v').to_string(),
        installable: device_can_install() && pick_apk(&r.assets).is_some(),
        url: r.html_url,
    }))
}

/// The latest release when it is newer than `current`.
async fn newer_release(url: &str, current: &str) -> Result<Option<Release>, reqwest::Error> {
    let release: Release = client(Duration::from_secs(10))?
        .get(url)
        .header("Accept", "application/vnd.github+json")
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    if release.draft
        || release.prerelease
        || !release.html_url.starts_with(RELEASES_PREFIX)
        || !is_newer(&release.tag_name, current)
    {
        return Ok(None);
    }
    Ok(Some(release))
}

/// Downloads the APK of the newer release into `dir`, checks it against the
/// release's SHA-256 list and returns its path. Needs the updates switch;
/// turning it off stops the download.
pub async fn download_apk(
    current: &str,
    policy: &NetPolicy,
    dir: &Path,
    progress: &(dyn Fn(DownloadProgress) + Sync),
) -> Result<PathBuf, String> {
    download_apk_at(LATEST_URL, current, policy, dir, progress).await
}

async fn download_apk_at(
    url: &str,
    current: &str,
    policy: &NetPolicy,
    dir: &Path,
    progress: &(dyn Fn(DownloadProgress) + Sync),
) -> Result<PathBuf, String> {
    let gate = || policy.require(Feature::Updates).map_err(str::to_owned);
    gate()?;
    let release = newer_release(url, current)
        .await
        .map_err(|e| e.to_string())?
        .ok_or("NeoModern is up to date.")?;
    let (apk, sums) = pick_apk(&release.assets).ok_or("This release has no APK for this phone.")?;
    let http = client(Duration::from_secs(15 * 60)).map_err(|e| e.to_string())?;

    gate()?;
    let list = http
        .get(&sums.browser_download_url)
        .send()
        .await
        .and_then(reqwest::Response::error_for_status)
        .map_err(|e| e.to_string())?
        .text()
        .await
        .map_err(|e| e.to_string())?;
    let expected = checksum_for(&list, &apk.name)
        .ok_or_else(|| format!("{} is not in {APK_SUMS}", apk.name))?;

    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let target = dir.join("NeoModern-update.apk");
    let partial = dir.join("NeoModern-update.apk.part");
    let result = async {
        gate()?;
        let mut resp = http
            .get(&apk.browser_download_url)
            .send()
            .await
            .and_then(reqwest::Response::error_for_status)
            .map_err(|e| e.to_string())?;
        let total = resp.content_length();
        let mut file = std::fs::File::create(&partial).map_err(|e| e.to_string())?;
        let mut hasher = Sha256::new();
        let mut received = 0u64;
        let mut last = std::time::Instant::now();
        while let Some(chunk) = resp.chunk().await.map_err(|e| e.to_string())? {
            gate()?;
            std::io::Write::write_all(&mut file, &chunk).map_err(|e| e.to_string())?;
            hasher.update(&chunk);
            received += chunk.len() as u64;
            if last.elapsed() >= Duration::from_millis(250) {
                last = std::time::Instant::now();
                progress(DownloadProgress { received, total });
            }
        }
        progress(DownloadProgress { received, total });
        drop(file);
        let actual: String = hasher
            .finalize()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        if actual != expected {
            return Err("The download is damaged (checksum mismatch). Try again.".to_owned());
        }
        std::fs::rename(&partial, &target).map_err(|e| e.to_string())?;
        Ok(target.clone())
    }
    .await;
    if result.is_err() {
        let _ = std::fs::remove_file(&partial);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compares_versions() {
        assert!(is_newer("v0.4", "0.3.0"));
        assert!(is_newer("v0.3.1", "0.3.0"));
        assert!(is_newer("1.0.0", "0.9.9"));
        assert!(is_newer("v0.10.0", "0.9.0"));
        assert!(!is_newer("v0.3", "0.3.0"));
        assert!(!is_newer("v0.2.9", "0.3.0"));
        assert!(!is_newer("v0.4.0-beta", "0.4.0"));
    }

    #[test]
    fn rejects_non_versions() {
        assert!(!is_newer("nightly", "0.3.0"));
        assert!(!is_newer("v1.2.3.4", "0.3.0"));
        assert!(!is_newer("v1.0", "dev"));
    }

    /// A one-shot HTTP server that counts the requests it receives.
    fn serve(body: &'static str) -> (String, std::sync::Arc<std::sync::atomic::AtomicUsize>) {
        use std::io::{Read, Write};
        use std::sync::atomic::{AtomicUsize, Ordering};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/latest", listener.local_addr().unwrap());
        let count = std::sync::Arc::new(AtomicUsize::new(0));
        let seen = std::sync::Arc::clone(&count);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { break };
                let mut buf = [0u8; 2048];
                let _ = stream.read(&mut buf);
                seen.fetch_add(1, Ordering::SeqCst);
                let reply = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(reply.as_bytes());
            }
        });
        (url, count)
    }

    #[test]
    fn update_check_is_refused_without_a_request_when_off() {
        use std::sync::atomic::Ordering;
        let (url, count) = serve(
            r#"{"tag_name":"v99.0.0","html_url":"https://github.com/r0madeus/neomodern/releases/tag/v99.0.0"}"#,
        );
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let policy = NetPolicy::default();

        // Offline mode, and the updates switch alone: error, no request.
        policy.set_offline(true);
        let err = rt.block_on(check_at(&url, "0.1.0", &policy)).unwrap_err();
        assert_eq!(err, "disabled in Settings");
        policy.set_offline(false);
        policy.set_feature(Feature::Updates, false);
        let err = rt.block_on(check_at(&url, "0.1.0", &policy)).unwrap_err();
        assert_eq!(err, "disabled in Settings");
        assert_eq!(count.load(Ordering::SeqCst), 0);

        // Other switches off does not stop updates.
        policy.set_feature(Feature::Updates, true);
        for f in [Feature::Lyrics, Feature::Online, Feature::Metadata] {
            policy.set_feature(f, false);
        }
        let found = rt
            .block_on(check_at(&url, "0.1.0", &policy))
            .unwrap()
            .expect("newer release");
        assert_eq!(found.version, "99.0.0");
        assert_eq!(count.load(Ordering::SeqCst), 1);
    }

    fn asset(name: &str, url: &str) -> Asset {
        Asset {
            name: name.into(),
            browser_download_url: url.into(),
        }
    }

    #[test]
    fn picks_the_signed_arm64_apk() {
        let base = "https://github.com/r0madeus/neomodern/releases/download/v1.0.0/";
        let assets = vec![
            asset("NeoModern_1.0.0_x64-setup.exe", &format!("{base}a.exe")),
            asset(
                "NeoModern-v1.0.0-android-arm64-testkey.apk",
                &format!("{base}t.apk"),
            ),
            asset(
                "NeoModern-v1.0.0-android-arm64.apk",
                &format!("{base}r.apk"),
            ),
            asset("SHA256SUMS-android.txt", &format!("{base}sums")),
        ];
        let (apk, sums) = pick_apk(&assets).unwrap();
        assert_eq!(apk.name, "NeoModern-v1.0.0-android-arm64.apk");
        assert_eq!(sums.name, "SHA256SUMS-android.txt");

        // Only a test-key APK, no checksum list, or a file from elsewhere:
        // nothing to install.
        assert!(pick_apk(&assets[..2]).is_none());
        assert!(pick_apk(&assets[..3]).is_none());
        let foreign = vec![
            asset(
                "NeoModern-v1.0.0-android-arm64.apk",
                "https://example.com/r.apk",
            ),
            assets[3].clone(),
        ];
        assert!(pick_apk(&foreign).is_none());
    }

    #[test]
    fn reads_the_apk_checksum() {
        let list = "767BA9DCE7052AA196F8B12652F433D76DE128BA168966FA84B6394D5E6C6795  NeoModern-v1.0.0-android-arm64.apk\n";
        assert_eq!(
            checksum_for(list, "NeoModern-v1.0.0-android-arm64.apk").as_deref(),
            Some("767ba9dce7052aa196f8b12652f433d76de128ba168966fa84b6394d5e6c6795")
        );
        assert!(checksum_for(list, "other.apk").is_none());
    }

    #[test]
    fn apk_download_is_refused_without_a_request_when_off() {
        use std::sync::atomic::Ordering;
        let (url, count) = serve(r#"{"tag_name":"v99.0.0","html_url":"x"}"#);
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let policy = NetPolicy::default();
        policy.set_feature(Feature::Updates, false);
        let dir = tempfile::tempdir().unwrap();
        let err = rt
            .block_on(download_apk_at(&url, "0.1.0", &policy, dir.path(), &|_| {}))
            .unwrap_err();
        assert_eq!(err, "disabled in Settings");
        assert_eq!(count.load(Ordering::SeqCst), 0);
    }

    /// Hits the real GitHub API: `cargo test -- --ignored live_latest_release`.
    #[test]
    #[ignore]
    fn live_latest_release() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let found = rt
            .block_on(check("0.0.1", &NetPolicy::default()))
            .unwrap()
            .expect("a release newer than 0.0.1");
        assert!(found.url.starts_with(RELEASES_PREFIX), "{found:?}");
        assert_eq!(
            rt.block_on(check("999.0.0", &NetPolicy::default()))
                .unwrap(),
            None
        );
    }
}

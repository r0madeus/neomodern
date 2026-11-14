//! App-managed copies of yt-dlp and ffmpeg.
//!
//! An ordinary user should not have to install command-line tools by hand.
//! On Windows and Linux (x86-64 and ARM64) the app can download the
//! official standalone builds into its own data folder: yt-dlp from the
//! yt-dlp releases, ffmpeg from the yt-dlp FFmpeg-Builds releases. Every
//! file is checked against the SHA-256 list published with it before it is
//! put in place. A tool the user already has on PATH, or a yt-dlp path set
//! in Settings, keeps working; the managed copy is only the fallback.

use super::{OnlineError, no_window_cmd};
#[cfg(any(windows, test))]
#[cfg(any(windows, test))]
use crate::library::scan::display_path;
use crate::net::client_builder;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const YTDLP_BASE: &str = "https://github.com/yt-dlp/yt-dlp/releases/latest/download";
const YTDLP_SUMS: &str = "SHA2-256SUMS";
const FFMPEG_BASE: &str = "https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest";
const FFMPEG_SUMS: &str = "checksums.sha256";

/// Limits for the external `tar` that unpacks ffmpeg and for version probes.
const EXTRACT_TIMEOUT: Duration = Duration::from_secs(180);
pub(super) const PROBE_TIMEOUT: Duration = Duration::from_secs(15);
/// A stalled download is abandoned after this long without data.
const READ_TIMEOUT: Duration = Duration::from_secs(60);
/// The whole ffmpeg archive (~100-200 MB) must arrive within this time.
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(30 * 60);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Tool {
    Ytdlp,
    Ffmpeg,
}

impl Tool {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "ytdlp" | "yt-dlp" => Some(Tool::Ytdlp),
            "ffmpeg" => Some(Tool::Ffmpeg),
            _ => None,
        }
    }
}

/// Progress of one install, sent to the UI.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallProgress {
    pub tool: Tool,
    /// "download", "verify", "extract" or "done".
    pub stage: &'static str,
    pub received: u64,
    pub total: Option<u64>,
}

/// Release file names for the machine the app runs on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Assets {
    pub ytdlp: &'static str,
    pub ffmpeg: &'static str,
}

/// The builds for `os`/`arch` (as in `std::env::consts`), if there are any.
pub fn assets_for(os: &str, arch: &str) -> Option<Assets> {
    match (os, arch) {
        ("windows", "x86_64") => Some(Assets {
            ytdlp: "yt-dlp.exe",
            ffmpeg: "ffmpeg-master-latest-win64-gpl.zip",
        }),
        ("windows", "aarch64") => Some(Assets {
            ytdlp: "yt-dlp_arm64.exe",
            ffmpeg: "ffmpeg-master-latest-winarm64-gpl.zip",
        }),
        ("linux", "x86_64") => Some(Assets {
            ytdlp: "yt-dlp_linux",
            ffmpeg: "ffmpeg-master-latest-linux64-gpl.tar.xz",
        }),
        ("linux", "aarch64") => Some(Assets {
            ytdlp: "yt-dlp_linux_aarch64",
            ffmpeg: "ffmpeg-master-latest-linuxarm64-gpl.tar.xz",
        }),
        _ => None,
    }
}

pub fn current_assets() -> Option<Assets> {
    assets_for(std::env::consts::OS, std::env::consts::ARCH)
}

/// The hash listed for `name` in a `sha256sum`-style list.
pub fn find_checksum(list: &str, name: &str) -> Option<String> {
    list.lines().find_map(|line| {
        let mut parts = line.split_whitespace();
        let hash = parts.next()?;
        let file = parts.next()?.trim_start_matches('*');
        (file == name && hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit()))
            .then(|| hash.to_ascii_lowercase())
    })
}

fn exe(name: &str) -> String {
    if cfg!(windows) {
        format!("{name}.exe")
    } else {
        name.to_owned()
    }
}

/// The folder that holds the managed copies.
#[derive(Debug, Clone)]
pub struct ToolsDir {
    dir: PathBuf,
}

impl ToolsDir {
    pub fn new(dir: PathBuf) -> Self {
        Self { dir }
    }

    pub fn ytdlp(&self) -> PathBuf {
        self.dir.join(exe("yt-dlp"))
    }

    pub fn ffmpeg(&self) -> PathBuf {
        self.dir.join(exe("ffmpeg"))
    }

    /// The managed yt-dlp, if it has been installed.
    pub fn installed_ytdlp(&self) -> Option<PathBuf> {
        let p = self.ytdlp();
        p.is_file().then_some(p)
    }

    /// The managed ffmpeg, if it has been installed.
    pub fn installed_ffmpeg(&self) -> Option<PathBuf> {
        let p = self.ffmpeg();
        p.is_file().then_some(p)
    }

    /// Downloads, verifies and installs `tool`. `allowed` is checked
    /// between chunks so turning online features off stops the download.
    pub async fn install(
        &self,
        tool: Tool,
        allowed: &(dyn Fn() -> bool + Sync),
        progress: &(dyn Fn(InstallProgress) + Sync),
    ) -> Result<PathBuf, OnlineError> {
        let assets = current_assets().ok_or_else(|| {
            OnlineError::Message(format!(
                "automatic setup is not available for {} {}",
                std::env::consts::OS,
                std::env::consts::ARCH
            ))
        })?;
        std::fs::create_dir_all(&self.dir)?;
        let client = client_builder()
            .connect_timeout(Duration::from_secs(20))
            .read_timeout(READ_TIMEOUT)
            .timeout(DOWNLOAD_TIMEOUT)
            .user_agent(super::USER_AGENT)
            .build()?;

        let (base, sums, asset) = match tool {
            Tool::Ytdlp => (YTDLP_BASE, YTDLP_SUMS, assets.ytdlp),
            Tool::Ffmpeg => (FFMPEG_BASE, FFMPEG_SUMS, assets.ffmpeg),
        };
        let list = fetch_text(&client, &format!("{base}/{sums}"), allowed).await?;
        let expected = find_checksum(&list, asset)
            .ok_or_else(|| OnlineError::Message(format!("{asset} is not in {sums}")))?;

        let partial = self.dir.join(format!("{asset}.part"));
        let result = async {
            let actual = download_to(
                &client,
                &format!("{base}/{asset}"),
                &partial,
                tool,
                allowed,
                progress,
            )
            .await?;
            progress(InstallProgress {
                tool,
                stage: "verify",
                received: 0,
                total: None,
            });
            if actual != expected {
                return Err(OnlineError::Message(format!(
                    "checksum mismatch for {asset}: the download is damaged"
                )));
            }
            match tool {
                Tool::Ytdlp => {
                    let target = self.ytdlp();
                    replace_file(&partial, &target)?;
                    make_executable(&target)?;
                    Ok(target)
                }
                Tool::Ffmpeg => {
                    progress(InstallProgress {
                        tool,
                        stage: "extract",
                        received: 0,
                        total: None,
                    });
                    self.unpack_ffmpeg(&partial, asset)
                }
            }
        }
        .await;
        let _ = std::fs::remove_file(&partial);
        let path = result?;
        progress(InstallProgress {
            tool,
            stage: "done",
            received: 0,
            total: None,
        });
        Ok(path)
    }

    /// Unpacks the archive with the system `tar` (bsdtar on Windows 10+,
    /// which also reads zip files) and keeps only ffmpeg and ffprobe.
    fn unpack_ffmpeg(&self, archive: &Path, asset: &str) -> Result<PathBuf, OnlineError> {
        let staging = self.dir.join("ffmpeg-unpack");
        let _ = std::fs::remove_dir_all(&staging);
        std::fs::create_dir_all(&staging)?;
        let result = (|| {
            let mut cmd = tar_command();
            if asset.ends_with(".tar.xz") {
                cmd.arg("-xJf");
            } else {
                cmd.arg("-xf");
            }
            cmd.arg(archive).arg("-C").arg(&staging);
            run_with_timeout(cmd, EXTRACT_TIMEOUT, "tar")?;

            let ffmpeg_name = exe("ffmpeg");
            let found = walkdir::WalkDir::new(&staging)
                .into_iter()
                .filter_map(Result::ok)
                .find(|e| {
                    e.file_type().is_file()
                        && e.file_name() == ffmpeg_name.as_str()
                        && e.path().parent().and_then(Path::file_name) == Some("bin".as_ref())
                })
                .map(|e| e.into_path())
                .ok_or_else(|| {
                    OnlineError::Message("ffmpeg was not found in the archive".into())
                })?;
            let bin_dir = found.parent().unwrap_or(&staging).to_path_buf();
            for name in ["ffmpeg", "ffprobe"] {
                let from = bin_dir.join(exe(name));
                if from.is_file() {
                    let to = self.dir.join(exe(name));
                    replace_file(&from, &to)?;
                    make_executable(&to)?;
                }
            }
            Ok(self.ffmpeg())
        })();
        let _ = std::fs::remove_dir_all(&staging);
        result
    }
}

fn tar_command() -> Command {
    #[cfg(windows)]
    {
        // The tar.exe that ships with Windows reads zip archives; a GNU tar
        // from Git or MSYS earlier on PATH would not.
        let system = std::env::var_os("SystemRoot")
            .map(|r| PathBuf::from(r).join("System32").join("tar.exe"))
            .filter(|p| p.is_file());
        match system {
            Some(p) => no_window_cmd(&display_path(&p)),
            None => no_window_cmd("tar"),
        }
    }
    #[cfg(not(windows))]
    {
        no_window_cmd("tar")
    }
}

/// Runs `cmd` to completion or kills it after `timeout`.
fn run_with_timeout(mut cmd: Command, timeout: Duration, what: &str) -> Result<(), OnlineError> {
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| OnlineError::Message(format!("could not start {what}: {e}")))?;
    let stderr = child.stderr.take();
    let drain = std::thread::spawn(move || {
        let mut buf = String::new();
        if let Some(mut s) = stderr {
            use std::io::Read;
            let _ = s.read_to_string(&mut buf);
        }
        buf
    });
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            let err = drain.join().unwrap_or_default();
            return if status.success() {
                Ok(())
            } else {
                Err(OnlineError::Message(format!(
                    "{what} failed ({status}): {}",
                    err.trim()
                )))
            };
        }
        if started.elapsed() >= timeout {
            let _ = child.kill();
            let _ = child.wait();
            return Err(OnlineError::Message(format!(
                "{what} timed out after {} s",
                timeout.as_secs()
            )));
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// First non-empty stdout line of `bin args`, or `None` when it cannot be
/// run, fails or takes longer than `timeout`.
pub(super) fn probe_first_line(bin: &str, args: &[&str], timeout: Duration) -> Option<String> {
    let mut child = no_window_cmd(bin)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let stdout = child.stdout.take();
    let drain = std::thread::spawn(move || {
        let mut buf = String::new();
        if let Some(mut s) = stdout {
            use std::io::Read;
            let _ = s.read_to_string(&mut buf);
        }
        buf
    });
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if started.elapsed() < timeout => {
                std::thread::sleep(Duration::from_millis(50));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    };
    let out = drain.join().unwrap_or_default();
    if !status.success() {
        return None;
    }
    out.lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .map(str::to_owned)
}

async fn fetch_text(
    client: &reqwest::Client,
    url: &str,
    allowed: &(dyn Fn() -> bool + Sync),
) -> Result<String, OnlineError> {
    if !allowed() {
        return Err(OnlineError::Disabled);
    }
    let resp = client.get(url).send().await?.error_for_status()?;
    Ok(resp.text().await?)
}

/// Streams `url` into `path` and returns the SHA-256 of what was written.
async fn download_to(
    client: &reqwest::Client,
    url: &str,
    path: &Path,
    tool: Tool,
    allowed: &(dyn Fn() -> bool + Sync),
    progress: &(dyn Fn(InstallProgress) + Sync),
) -> Result<String, OnlineError> {
    if !allowed() {
        return Err(OnlineError::Disabled);
    }
    let mut resp = client.get(url).send().await?.error_for_status()?;
    let total = resp.content_length();
    let mut file = std::io::BufWriter::new(std::fs::File::create(path)?);
    let mut hasher = Sha256::new();
    let mut received = 0u64;
    let mut last_report = Instant::now();
    while let Some(chunk) = resp.chunk().await? {
        if !allowed() {
            return Err(OnlineError::Disabled);
        }
        file.write_all(&chunk)?;
        hasher.update(&chunk);
        received += chunk.len() as u64;
        if last_report.elapsed() >= Duration::from_millis(250) {
            last_report = Instant::now();
            progress(InstallProgress {
                tool,
                stage: "download",
                received,
                total,
            });
        }
    }
    file.flush()?;
    drop(file);
    if let Some(total) = total
        && received != total
    {
        return Err(OnlineError::Message(format!(
            "download ended early ({received} of {total} bytes)"
        )));
    }
    progress(InstallProgress {
        tool,
        stage: "download",
        received,
        total,
    });
    Ok(hex(&hasher.finalize()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Moves `from` over `to`. A running old copy on Windows cannot be
/// replaced, so it is renamed out of the way first.
fn replace_file(from: &Path, to: &Path) -> std::io::Result<()> {
    if to.exists() {
        let old = to.with_extension("old");
        let _ = std::fs::remove_file(&old);
        if std::fs::rename(to, &old).is_err() {
            std::fs::remove_file(to)?;
        }
    }
    if std::fs::rename(from, to).is_err() {
        std::fs::copy(from, to)?;
        let _ = std::fs::remove_file(from);
    }
    Ok(())
}

fn make_executable(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(path)?.permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(path, perms)?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_builds_for_supported_machines() {
        assert_eq!(assets_for("windows", "x86_64").unwrap().ytdlp, "yt-dlp.exe");
        assert_eq!(
            assets_for("linux", "aarch64").unwrap().ffmpeg,
            "ffmpeg-master-latest-linuxarm64-gpl.tar.xz"
        );
        assert!(assets_for("macos", "aarch64").is_none());
        assert!(assets_for("linux", "riscv64").is_none());
    }

    #[test]
    fn reads_checksum_lists() {
        let list = "\
e51e69e89489f199530f13d32a4342da3ddb2cf34842f364603a066db05afbf3  yt-dlp
767BA9DCE7052AA196F8B12652F433D76DE128BA168966FA84B6394D5E6C6795 *yt-dlp_linux
nothex  yt-dlp.exe
";
        assert_eq!(
            find_checksum(list, "yt-dlp_linux").as_deref(),
            Some("767ba9dce7052aa196f8b12652f433d76de128ba168966fa84b6394d5e6c6795")
        );
        assert!(find_checksum(list, "yt-dlp.exe").is_none());
        assert!(find_checksum(list, "yt-dlp_linux.zip").is_none());
    }

    #[test]
    fn probe_gives_up_on_a_hung_program() {
        #[cfg(unix)]
        {
            let started = Instant::now();
            assert!(probe_first_line("sleep", &["5"], Duration::from_millis(200)).is_none());
            assert!(started.elapsed() < Duration::from_secs(3));
            assert_eq!(
                probe_first_line("echo", &["hi"], PROBE_TIMEOUT).as_deref(),
                Some("hi")
            );
        }
    }

    /// Real download from GitHub; run with `cargo test -- --ignored tools`.
    #[test]
    #[ignore]
    fn installs_real_tools() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let dir = std::env::temp_dir().join(format!("neomodern-tools-{}", std::process::id()));
        let tools = ToolsDir::new(dir.clone());
        for tool in [Tool::Ytdlp, Tool::Ffmpeg] {
            let path = rt.block_on(tools.install(tool, &|| true, &|_| {})).unwrap();
            let arg = if tool == Tool::Ytdlp {
                "--version"
            } else {
                "-version"
            };
            assert!(
                probe_first_line(&display_path(&path), &[arg], Duration::from_secs(60)).is_some()
            );
        }
        let _ = std::fs::remove_dir_all(dir);
    }
}

//! A plain-text problem report: app and system details, the settings and
//! the end of the log, with the user's home folder replaced by `~` so the
//! report can be pasted into a public issue.

use std::path::{Path, PathBuf};

/// How much of the log goes into a report.
pub const LOG_TAIL_LINES: usize = 400;

/// Where new problem reports are filed.
pub const ISSUE_URL: &str = "https://github.com/r0madeus/neomodern/issues/new";

/// Everything a report shows besides the log.
pub struct ReportInfo<'a> {
    pub version: &'a str,
    pub webview: Option<String>,
    pub tracks: Option<u64>,
    pub albums: Option<u64>,
    pub settings_json: Option<String>,
}

/// Replaces every spelling of `home` (`\` or `/` separators, any case on
/// Windows) with `~`.
pub fn redact_home(text: &str, home: Option<&Path>) -> String {
    let Some(home) = home.map(|h| h.to_string_lossy().into_owned()) else {
        return text.to_owned();
    };
    let home = home.trim_end_matches(['/', '\\']);
    if home.len() < 3 {
        // "/" or "C:" would blank out every path.
        return text.to_owned();
    }
    let mut variants = vec![
        home.to_owned(),
        home.replace('\\', "/"),
        home.replace('/', "\\"),
    ];
    variants.sort();
    variants.dedup();
    // Longest first, so a variant never cuts into another.
    variants.sort_by_key(|v| std::cmp::Reverse(v.len()));
    let mut out = text.to_owned();
    for v in &variants {
        out = replace_ignore_ascii_case(&out, v, "~", cfg!(windows));
    }
    out
}

fn replace_ignore_ascii_case(text: &str, from: &str, to: &str, ignore_case: bool) -> String {
    if !ignore_case {
        return text.replace(from, to);
    }
    let hay = text.to_ascii_lowercase();
    let needle = from.to_ascii_lowercase();
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    for (i, _) in hay.match_indices(&needle) {
        if i < last {
            continue;
        }
        out.push_str(&text[last..i]);
        out.push_str(to);
        last = i + from.len();
    }
    out.push_str(&text[last..]);
    out
}

/// The log files in `dir`, oldest first.
pub fn log_files(dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut files: Vec<(std::time::SystemTime, PathBuf)> = entries
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "log") && p.is_file())
        .map(|p| {
            let modified = std::fs::metadata(&p)
                .and_then(|m| m.modified())
                .unwrap_or(std::time::UNIX_EPOCH);
            (modified, p)
        })
        .collect();
    files.sort();
    files.into_iter().map(|(_, p)| p).collect()
}

/// The last `max` lines over all log files in `dir`.
pub fn log_tail(dir: &Path, max: usize) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    for file in log_files(dir).iter().rev() {
        let Ok(bytes) = std::fs::read(file) else {
            continue;
        };
        let text = String::from_utf8_lossy(&bytes);
        let mut chunk: Vec<String> = text.lines().map(str::to_owned).collect();
        chunk.append(&mut lines);
        lines = chunk;
        if lines.len() >= max {
            break;
        }
    }
    let skip = lines.len().saturating_sub(max);
    lines.split_off(skip)
}

/// The whole report.
pub fn build_report(info: &ReportInfo<'_>, log_dir: Option<&Path>, home: Option<&Path>) -> String {
    let mut out = String::new();
    out.push_str("NeoModern problem report\n========================\n");
    out.push_str(&format!("Version:  {}\n", info.version));
    out.push_str(&format!(
        "System:   {} {} ({})\n",
        std::env::consts::OS,
        os_version().unwrap_or_default(),
        std::env::consts::ARCH
    ));
    if let Some(w) = &info.webview {
        out.push_str(&format!("WebView:  {w}\n"));
    }
    if let (Some(t), Some(a)) = (info.tracks, info.albums) {
        out.push_str(&format!("Library:  {t} tracks, {a} albums\n"));
    }
    if let Some(s) = &info.settings_json {
        out.push_str("\nSettings\n--------\n");
        out.push_str(s);
        out.push('\n');
    }
    out.push_str("\nLog (most recent last)\n----------------------\n");
    match log_dir {
        Some(dir) => {
            let tail = log_tail(dir, LOG_TAIL_LINES);
            if tail.is_empty() {
                out.push_str("(no log lines)\n");
            }
            for line in tail {
                out.push_str(&line);
                out.push('\n');
            }
        }
        None => out.push_str("(log folder unknown)\n"),
    }
    redact_home(&out, home)
}

/// A short OS release name where one is easy to read.
fn os_version() -> Option<String> {
    #[cfg(target_os = "linux")]
    {
        let text = std::fs::read_to_string("/etc/os-release").ok()?;
        text.lines()
            .find_map(|l| l.strip_prefix("PRETTY_NAME="))
            .map(|v| v.trim_matches('"').to_owned())
    }
    #[cfg(not(target_os = "linux"))]
    {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hides_the_home_folder_in_both_spellings() {
        let home = Path::new(if cfg!(windows) {
            r"C:\Users\Melih"
        } else {
            "/home/melih"
        });
        let text = if cfg!(windows) {
            r"scan C:\Users\Melih\Music and c:/users/melih/Music/x.flac".to_owned()
        } else {
            "scan /home/melih/Music and /home/melih/.cache/x".to_owned()
        };
        let out = redact_home(&text, Some(home));
        assert!(!out.to_ascii_lowercase().contains("melih"), "{out}");
        assert!(out.contains("~"));
        // A root "home" must not blank out every path.
        assert_eq!(redact_home("/a/b", Some(Path::new("/"))), "/a/b");
    }

    #[test]
    fn tail_reads_across_rotated_files() {
        let dir = tempfile::tempdir().unwrap();
        let old = dir.path().join("NeoModern_2026-01-01.log");
        let new = dir.path().join("NeoModern.log");
        std::fs::write(&old, "a\nb\nc\n").unwrap();
        // Make sure the current file is newer.
        std::thread::sleep(std::time::Duration::from_millis(20));
        std::fs::write(&new, "d\ne\n").unwrap();
        std::fs::write(dir.path().join("notes.txt"), "x\n").unwrap();
        assert_eq!(log_tail(dir.path(), 3), ["c", "d", "e"]);
        assert_eq!(log_tail(dir.path(), 10), ["a", "b", "c", "d", "e"]);
    }

    #[test]
    fn report_has_details_and_no_home() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().to_path_buf();
        std::fs::write(
            dir.path().join("NeoModern.log"),
            format!("[INFO] scanning {}\n", home.join("Music").display()),
        )
        .unwrap();
        let info = ReportInfo {
            version: "1.2.3",
            webview: Some("120".into()),
            tracks: Some(5),
            albums: Some(1),
            settings_json: Some("{\"offlineMode\": false}".into()),
        };
        let report = build_report(&info, Some(dir.path()), Some(&home));
        assert!(report.contains("Version:  1.2.3"));
        assert!(report.contains("5 tracks, 1 albums"));
        assert!(report.contains("offlineMode"));
        assert!(report.contains("scanning ~"));
        assert!(!report.contains(&home.display().to_string()));
    }
}

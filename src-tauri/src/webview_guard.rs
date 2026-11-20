//! Keeps the window usable when the webview's own processes fail.
//!
//! The UI is a page in the system webview; playback, the queue and all state
//! live in Rust (AGENTS.md), so a reload loses nothing. Wry does not react to
//! WebView2 process failures, which leaves a blank or frozen window that only
//! a restart fixes. On Windows we listen for `ProcessFailed` and reload the
//! page when its renderer exited or stopped responding.
//!
//! On Linux, WebKitGTK's DMA-BUF renderer shows a blank window with the
//! proprietary NVIDIA driver; it is turned off there unless the user set the
//! variable themselves.

#[cfg(any(windows, test))]
use std::time::{Duration, Instant};

#[cfg(any(windows, test))]
/// At most one automatic reload in this window, so a page that fails right
/// away again does not reload in a loop.
const RELOAD_COOLDOWN: Duration = Duration::from_secs(30);

#[cfg(any(windows, test))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// The page's renderer is gone or hung: reload it.
    Reload,
    /// Only logged: WebView2 recovers by itself (GPU, helpers, iframes).
    Log,
    /// The whole webview is gone; nothing in the page can fix it.
    Fatal,
}

#[cfg(any(windows, test))]
/// What to do for a `COREWEBVIEW2_PROCESS_FAILED_KIND` value.
pub fn action_for(kind: i32) -> Action {
    match kind {
        // BROWSER_PROCESS_EXITED
        0 => Action::Fatal,
        // RENDER_PROCESS_EXITED, RENDER_PROCESS_UNRESPONSIVE
        1 | 2 => Action::Reload,
        // Frame renderer, sandbox helper, GPU, PPAPI, unknown.
        _ => Action::Log,
    }
}

#[cfg(any(windows, test))]
/// Allows a reload unless one happened within the cooldown.
#[derive(Debug, Default)]
pub struct ReloadGate {
    last: Option<Instant>,
}

#[cfg(any(windows, test))]
impl ReloadGate {
    pub fn try_reload(&mut self, now: Instant) -> bool {
        if self
            .last
            .is_some_and(|t| now.saturating_duration_since(t) < RELOAD_COOLDOWN)
        {
            return false;
        }
        self.last = Some(now);
        true
    }
}

/// Registers the process-failure handler on `window`'s WebView2.
#[cfg(windows)]
pub fn install(window: &tauri::WebviewWindow) {
    use std::sync::Mutex;
    use webview2_com::Microsoft::Web::WebView2::Win32::COREWEBVIEW2_PROCESS_FAILED_KIND;
    use webview2_com::ProcessFailedEventHandler;

    let result = window.with_webview(|wv| {
        let gate = Mutex::new(ReloadGate::default());
        // SAFETY: plain WebView2 COM calls on the webview's own (UI) thread,
        // which is where `with_webview` runs this closure.
        unsafe {
            let core = match wv.controller().CoreWebView2() {
                Ok(c) => c,
                Err(e) => {
                    log::warn!("webview guard not installed: {e}");
                    return;
                }
            };
            let handler = ProcessFailedEventHandler::create(Box::new(move |webview, args| {
                let Some(args) = args else { return Ok(()) };
                let mut kind = COREWEBVIEW2_PROCESS_FAILED_KIND::default();
                args.ProcessFailedKind(&mut kind)?;
                match action_for(kind.0) {
                    Action::Reload => {
                        let allowed = gate
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .try_reload(Instant::now());
                        if allowed && let Some(webview) = webview {
                            log::error!(
                                "webview renderer failed (kind {}); reloading the page",
                                kind.0
                            );
                            webview.Reload()?;
                        } else {
                            log::error!(
                                "webview renderer failed again (kind {}); not reloading",
                                kind.0
                            );
                        }
                    }
                    Action::Log => log::warn!("a webview helper process exited (kind {})", kind.0),
                    Action::Fatal => {
                        log::error!(
                            "the webview browser process exited; the window needs a restart"
                        )
                    }
                }
                Ok(())
            }));
            let mut token = 0i64;
            if let Err(e) = core.add_ProcessFailed(&handler, &mut token) {
                log::warn!("webview guard not installed: {e}");
            }
        }
    });
    if let Err(e) = result {
        log::warn!("webview guard not installed: {e}");
    }
}

/// Turns WebKitGTK's DMA-BUF renderer off with the proprietary NVIDIA
/// driver. Must run before any thread is started and before the webview is
/// created (first thing in `run`).
#[cfg(target_os = "linux")]
pub fn linux_renderer_workaround() {
    const VAR: &str = "WEBKIT_DISABLE_DMABUF_RENDERER";
    if std::env::var_os(VAR).is_none()
        && std::path::Path::new("/proc/driver/nvidia/version").exists()
    {
        // SAFETY: called at the start of `run`, before the app starts any
        // thread, so nothing else reads the environment concurrently.
        unsafe { std::env::set_var(VAR, "1") };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reloads_only_for_the_page_renderer() {
        assert_eq!(action_for(1), Action::Reload);
        assert_eq!(action_for(2), Action::Reload);
        assert_eq!(action_for(0), Action::Fatal);
        for other in [3, 5, 6, 7, 8, 9, 42] {
            assert_eq!(action_for(other), Action::Log, "{other}");
        }
    }

    #[test]
    fn reloads_at_most_once_per_cooldown() {
        let mut gate = ReloadGate::default();
        let t0 = Instant::now();
        assert!(gate.try_reload(t0));
        assert!(!gate.try_reload(t0 + Duration::from_secs(5)));
        assert!(gate.try_reload(t0 + RELOAD_COOLDOWN));
    }
}

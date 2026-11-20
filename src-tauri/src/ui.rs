//! Whether the app's page is on screen.
//!
//! When the window is minimised, hidden in the tray or fully covered, the
//! webview (WebView2 on Windows) throttles and after a few minutes freezes
//! the page; Tauri cannot turn that off on Windows, Linux or Android. Every
//! event emitted meanwhile is queued as a script run, and they all run at
//! once when the window comes back. At four position updates a second that
//! is ~14 000 an hour, enough to hang the app on return. The page reports
//! its visibility here, and high-rate events are not sent while it is hidden;
//! the page extrapolates the position itself when it becomes visible again,
//! and the next update corrects it.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::State;

/// Events sent several times a second; skipped while the page is hidden.
const HIGH_RATE_EVENTS: [&str; 2] = ["player://position", "remote://position"];

#[derive(Debug)]
pub struct UiVisibility(AtomicBool);

impl Default for UiVisibility {
    fn default() -> Self {
        Self(AtomicBool::new(true))
    }
}

impl UiVisibility {
    pub fn visible(&self) -> bool {
        self.0.load(Ordering::Relaxed)
    }

    pub fn set(&self, visible: bool) {
        self.0.store(visible, Ordering::Relaxed);
    }

    /// Should `event` be sent to the page now?
    pub fn wants(&self, event: &str) -> bool {
        self.visible() || !HIGH_RATE_EVENTS.contains(&event)
    }
}

/// The page tells the backend it became visible or hidden.
#[tauri::command]
pub fn app_set_visible(ui: State<'_, Arc<UiVisibility>>, visible: bool) {
    ui.set(visible);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hidden_page_gets_only_low_rate_events() {
        let ui = UiVisibility::default();
        assert!(ui.wants("player://position"));
        ui.set(false);
        assert!(!ui.wants("player://position"));
        assert!(!ui.wants("remote://position"));
        assert!(ui.wants("player://state"));
        assert!(ui.wants("sync://status"));
        ui.set(true);
        assert!(ui.wants("remote://position"));
    }
}

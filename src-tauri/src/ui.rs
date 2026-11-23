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
//!
//! While the page is visible it also sends a heartbeat every few seconds.
//! A watchdog logs when the heartbeat stops (and when it comes back), so a
//! report of a frozen window can be matched with the log.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::State;

/// No heartbeat for this long from a visible page counts as a stall.
const STALL_AFTER: Duration = Duration::from_secs(20);
/// How often the watchdog looks.
pub const WATCH_EVERY: Duration = Duration::from_secs(5);

/// Events sent several times a second; skipped while the page is hidden.
const HIGH_RATE_EVENTS: [&str; 2] = ["player://position", "remote://position"];

/// Coalesced changes that happened while the window was hidden.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HiddenChanges {
    pub state: bool,
    pub history: bool,
    pub library: bool,
}

#[derive(Debug)]
pub struct UiVisibility {
    visible: AtomicBool,
    dirty_state: AtomicBool,
    dirty_history: AtomicBool,
    dirty_library: AtomicBool,
    watch: Mutex<Watch>,
}

#[derive(Debug, Default)]
struct Watch {
    /// Last heartbeat (or the moment the page became visible).
    last: Option<Instant>,
    /// When the current stall started being reported.
    stalled_since: Option<Instant>,
}

/// What the watchdog found.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum WatchEvent {
    /// No heartbeat from a visible page for this long.
    Stalled(Duration),
    /// The heartbeat came back after a stall of this long.
    Recovered(Duration),
}

impl Default for UiVisibility {
    fn default() -> Self {
        Self {
            visible: AtomicBool::new(true),
            dirty_state: AtomicBool::new(false),
            dirty_history: AtomicBool::new(false),
            dirty_library: AtomicBool::new(false),
            watch: Mutex::new(Watch::default()),
        }
    }
}

impl UiVisibility {
    pub fn visible(&self) -> bool {
        self.visible.load(Ordering::Acquire)
    }

    pub fn mark_dirty_state(&self) {
        self.dirty_state.store(true, Ordering::Release);
    }

    pub fn mark_dirty_history(&self) {
        self.dirty_history.store(true, Ordering::Release);
    }

    pub fn mark_dirty_library(&self) {
        self.dirty_library.store(true, Ordering::Release);
    }

    pub fn set(&self, visible: bool) -> HiddenChanges {
        self.set_at(visible, Instant::now())
    }

    fn set_at(&self, visible: bool, now: Instant) -> HiddenChanges {
        self.visible.store(visible, Ordering::Release);
        let changes = if visible {
            HiddenChanges {
                state: self.dirty_state.swap(false, Ordering::AcqRel),
                history: self.dirty_history.swap(false, Ordering::AcqRel),
                library: self.dirty_library.swap(false, Ordering::AcqRel),
            }
        } else {
            HiddenChanges::default()
        };
        // Hidden pages are frozen on purpose; start counting afresh.
        let mut w = self.lock();
        w.last = visible.then_some(now);
        w.stalled_since = None;
        changes
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Watch> {
        self.watch.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// A heartbeat from the page. Returns `Recovered` after a stall.
    pub fn beat(&self, now: Instant) -> Option<WatchEvent> {
        let mut w = self.lock();
        w.last = Some(now);
        w.stalled_since
            .take()
            .map(|since| WatchEvent::Recovered(now.saturating_duration_since(since) + STALL_AFTER))
    }

    /// The watchdog's periodic look. Reports a stall once.
    pub fn check(&self, now: Instant) -> Option<WatchEvent> {
        if !self.visible() {
            return None;
        }
        let mut w = self.lock();
        let last = w.last?;
        let silent = now.saturating_duration_since(last);
        if silent < STALL_AFTER || w.stalled_since.is_some() {
            return None;
        }
        w.stalled_since = Some(now);
        Some(WatchEvent::Stalled(silent))
    }

    /// Should `event` be sent to the page now?
    pub fn wants(&self, event: &str) -> bool {
        self.visible() || !HIGH_RATE_EVENTS.contains(&event)
    }
}

/// Logs UI stalls until the app exits (runs on its own thread).
pub fn spawn_watchdog(ui: Arc<UiVisibility>) {
    let started = std::thread::Builder::new()
        .name("ui-watchdog".into())
        .spawn(move || {
            loop {
                std::thread::sleep(WATCH_EVERY);
                if let Some(WatchEvent::Stalled(d)) = ui.check(Instant::now()) {
                    log::warn!(
                        "ui: the window has not responded for {} s (page frozen or main thread blocked)",
                        d.as_secs()
                    );
                }
            }
        });
    if let Err(e) = started {
        log::warn!("ui watchdog not started: {e}");
    }
}

/// Heartbeat from the visible page. Deliberately a blocking command: it runs
/// on the main thread, so a blocked main thread shows up as a stall too.
#[tauri::command]
pub fn app_heartbeat(ui: State<'_, Arc<UiVisibility>>) {
    if let Some(WatchEvent::Recovered(d)) = ui.beat(Instant::now()) {
        log::warn!(
            "ui: the window responds again after about {} s",
            d.as_secs()
        );
    }
}

/// The page tells the backend it became visible or hidden.
#[tauri::command]
pub fn app_set_visible(ui: State<'_, Arc<UiVisibility>>, visible: bool) -> HiddenChanges {
    ui.set(visible)
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

    #[test]
    fn watchdog_reports_a_stall_once_and_the_recovery() {
        let ui = UiVisibility::default();
        let t0 = Instant::now();
        ui.set_at(true, t0);
        assert_eq!(ui.check(t0 + Duration::from_secs(10)), None);
        assert_eq!(ui.beat(t0 + Duration::from_secs(10)), None);
        let t1 = t0 + Duration::from_secs(10) + STALL_AFTER;
        assert_eq!(ui.check(t1), Some(WatchEvent::Stalled(STALL_AFTER)));
        assert_eq!(ui.check(t1 + WATCH_EVERY), None, "reported once");
        assert_eq!(
            ui.beat(t1 + Duration::from_secs(40)),
            Some(WatchEvent::Recovered(Duration::from_secs(40) + STALL_AFTER))
        );
        assert_eq!(ui.check(t1 + Duration::from_secs(45)), None);
    }

    #[test]
    fn hidden_page_is_not_watched() {
        let ui = UiVisibility::default();
        let t0 = Instant::now();
        ui.set_at(false, t0);
        assert_eq!(ui.check(t0 + Duration::from_secs(600)), None);
        // Coming back starts a fresh count, not a stall of ten minutes.
        ui.set_at(true, t0 + Duration::from_secs(600));
        assert_eq!(ui.check(t0 + Duration::from_secs(605)), None);
    }

    #[test]
    fn hidden_changes_are_coalesced_and_cleared_on_visible() {
        let ui = UiVisibility::default();
        assert_eq!(ui.set(false), HiddenChanges::default());

        ui.mark_dirty_state();
        ui.mark_dirty_state();
        ui.mark_dirty_history();
        // Still hidden: transitioning to hidden again must not leak or clear flags.
        assert_eq!(ui.set(false), HiddenChanges::default());

        ui.mark_dirty_library();

        assert_eq!(
            ui.set(true),
            HiddenChanges {
                state: true,
                history: true,
                library: true,
            }
        );
        // Flags were cleared when becoming visible.
        assert_eq!(ui.set(true), HiddenChanges::default());
        assert_eq!(ui.set(false), HiddenChanges::default());
        assert_eq!(ui.set(true), HiddenChanges::default());
    }

    #[test]
    fn hidden_changes_track_each_flag_independently() {
        let ui = UiVisibility::default();
        ui.set(false);
        ui.mark_dirty_history();
        assert_eq!(
            ui.set(true),
            HiddenChanges {
                state: false,
                history: true,
                library: false,
            }
        );
        assert_eq!(ui.set(true), HiddenChanges::default());

        ui.set(false);
        ui.mark_dirty_state();
        ui.mark_dirty_library();
        assert_eq!(
            ui.set(true),
            HiddenChanges {
                state: true,
                history: false,
                library: true,
            }
        );
    }
}

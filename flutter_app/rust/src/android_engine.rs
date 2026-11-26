//! Android audio bridge between `neomodern_core::audio::AudioEngine` and the
//! Flutter platform channel driving Media3/ExoPlayer in Kotlin.
//!
//! Command and event types (`UiAndroidAudioCmd`, `UiAndroidAudioEvent`) plus
//! event translation helpers are compiled on all targets so FRB codegen and
//! `cargo test --workspace` cover them on desktop and CI hosts too.

use neomodern_core::audio::{EndReason, EngineEvent, RemoteCommand};
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};

#[cfg(any(target_os = "android", test))]
use neomodern_core::audio::{
    AudioEngine, EngineError, EngineResult, Equalizer, ReplayGain, replaygain,
};
#[cfg(any(target_os = "android", test))]
use std::path::Path;
#[cfg(any(target_os = "android", test))]
use std::sync::mpsc::{self, Sender};

const MAX_BACKLOG: usize = 256;

/// Commands sent from Rust `AudioEngine` to Kotlin ExoPlayer via Dart.
#[derive(Debug, Clone, PartialEq)]
pub enum UiAndroidAudioCmd {
    Load {
        path: String,
        gain: f64,
    },
    SetNext {
        path: String,
        gain: f64,
    },
    ClearNext,
    Play,
    Pause,
    Stop,
    Seek {
        seconds: f64,
    },
    SetVolume {
        percent: f64,
    },
    SetReplayGain {
        path: String,
        gain: f64,
    },
    SetGapless {
        enabled: bool,
    },
    SetEqualizer {
        enabled: bool,
        preamp_db: f64,
        gains_db: Vec<f64>,
    },
    SetCrossfade {
        seconds: f64,
    },
}

/// Events sent from Kotlin ExoPlayer / MediaSession to Rust via Dart.
#[derive(Debug, Clone, PartialEq)]
pub enum UiAndroidAudioEvent {
    Position { seconds: f64, duration: Option<f64> },
    TrackEnded { path: String, reason: String },
    TrackStarted { path: String, auto_advanced: bool },
    Paused { paused: bool },
    Idle,
    Error(String),
    MediaPlay,
    MediaPause,
    MediaToggle,
    MediaNext,
    MediaPrevious,
}

/// Shared current/next track slots used to recompute ReplayGain on mode changes.
pub type SharedSlots = Arc<Mutex<(Option<PathBuf>, Option<PathBuf>)>>;

/// Result of translating a `UiAndroidAudioEvent` into core player actions.
#[derive(Debug, Clone, PartialEq)]
pub enum BridgeAction {
    Engine(Vec<EngineEvent>),
    MediaPlay,
    MediaPause,
    MediaToggle,
}

pub fn parse_end_reason(reason: &str) -> EndReason {
    match reason {
        "eof" => EndReason::Eof,
        "error" => EndReason::Error,
        _ => EndReason::Stopped,
    }
}

pub fn translate_event(event: UiAndroidAudioEvent) -> BridgeAction {
    match event {
        UiAndroidAudioEvent::Position { seconds, duration } => {
            // Emit Position before Duration so a Duration-triggered
            // `pending_load_seek` in `Player` is not overwritten by Position(0).
            let mut events = vec![EngineEvent::Position { seconds }];
            if let Some(d) = duration {
                events.push(EngineEvent::Duration { seconds: d });
            }
            BridgeAction::Engine(events)
        }
        UiAndroidAudioEvent::TrackStarted {
            path,
            auto_advanced,
        } => BridgeAction::Engine(vec![EngineEvent::TrackStarted {
            path: PathBuf::from(path),
            auto_advanced,
        }]),
        UiAndroidAudioEvent::TrackEnded { path, reason } => {
            BridgeAction::Engine(vec![EngineEvent::TrackEnded {
                path: PathBuf::from(path),
                reason: parse_end_reason(&reason),
            }])
        }
        UiAndroidAudioEvent::Paused { paused } => {
            BridgeAction::Engine(vec![EngineEvent::Paused(paused)])
        }
        UiAndroidAudioEvent::Idle => BridgeAction::Engine(vec![EngineEvent::Idle]),
        UiAndroidAudioEvent::Error(message) => {
            BridgeAction::Engine(vec![EngineEvent::Error(message)])
        }
        UiAndroidAudioEvent::MediaPlay => BridgeAction::MediaPlay,
        UiAndroidAudioEvent::MediaPause => BridgeAction::MediaPause,
        UiAndroidAudioEvent::MediaToggle => BridgeAction::MediaToggle,
        UiAndroidAudioEvent::MediaNext => {
            BridgeAction::Engine(vec![EngineEvent::Remote(RemoteCommand::Next)])
        }
        UiAndroidAudioEvent::MediaPrevious => {
            BridgeAction::Engine(vec![EngineEvent::Remote(RemoteCommand::Previous)])
        }
    }
}

#[derive(Default)]
struct CmdBusInner {
    active_id: u64,
    next_id: u64,
    tx: Option<UnboundedSender<UiAndroidAudioCmd>>,
    backlog: VecDeque<UiAndroidAudioCmd>,
}

struct AndroidCmdBus {
    inner: Mutex<CmdBusInner>,
}

impl AndroidCmdBus {
    fn new() -> Self {
        Self {
            inner: Mutex::new(CmdBusInner::default()),
        }
    }

    fn emit(&self, cmd: UiAndroidAudioCmd) {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(tx) = &inner.tx
            && tx.send(cmd.clone()).is_ok()
        {
            return;
        }
        inner.tx = None;
        if inner.backlog.len() >= MAX_BACKLOG {
            inner.backlog.pop_front();
        }
        inner.backlog.push_back(cmd);
    }

    fn subscribe(&self) -> (u64, UnboundedReceiver<UiAndroidAudioCmd>) {
        let (tx, rx) = unbounded_channel();
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        while let Some(cmd) = inner.backlog.pop_front() {
            let _ = tx.send(cmd);
        }
        inner.next_id = inner.next_id.saturating_add(1);
        let id = inner.next_id;
        inner.active_id = id;
        inner.tx = Some(tx);
        (id, rx)
    }

    fn unsubscribe(&self, id: u64) {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if inner.active_id == id {
            inner.tx = None;
        }
    }
}

static CMD_BUS: OnceLock<AndroidCmdBus> = OnceLock::new();

fn cmd_bus() -> &'static AndroidCmdBus {
    CMD_BUS.get_or_init(AndroidCmdBus::new)
}

pub fn emit_cmd(cmd: UiAndroidAudioCmd) {
    cmd_bus().emit(cmd);
}

pub fn subscribe_cmds() -> (u64, UnboundedReceiver<UiAndroidAudioCmd>) {
    cmd_bus().subscribe()
}

pub fn unsubscribe_cmds(id: u64) {
    cmd_bus().unsubscribe(id);
}

#[cfg(any(target_os = "android", test))]
enum Job {
    Load { path: PathBuf },
    SetNext { path: PathBuf },
    SetGain { path: PathBuf },
    Direct(UiAndroidAudioCmd),
}

#[cfg(any(target_os = "android", test))]
pub struct AndroidBridgeEngine {
    jobs: Mutex<Sender<Job>>,
    mode: Arc<Mutex<ReplayGain>>,
    slots: SharedSlots,
}

#[cfg(any(target_os = "android", test))]
impl AndroidBridgeEngine {
    pub fn new() -> EngineResult<Self> {
        Self::with_emitter(Box::new(emit_cmd))
    }

    pub fn with_emitter(
        emitter: Box<dyn Fn(UiAndroidAudioCmd) + Send + Sync>,
    ) -> EngineResult<Self> {
        let (jobs_tx, jobs_rx) = mpsc::channel::<Job>();
        let mode = Arc::new(Mutex::new(ReplayGain::default()));
        let worker_mode = Arc::clone(&mode);
        let slots: SharedSlots = Arc::new(Mutex::new((None, None)));

        std::thread::Builder::new()
            .name("android-audio-bridge".into())
            .spawn(move || {
                while let Ok(job) = jobs_rx.recv() {
                    let cmd = match job {
                        Job::Load { path } => {
                            let gain = compute_gain(&path, &worker_mode);
                            match path.to_str() {
                                Some(s) => UiAndroidAudioCmd::Load {
                                    path: s.to_owned(),
                                    gain,
                                },
                                None => continue,
                            }
                        }
                        Job::SetNext { path } => {
                            let gain = compute_gain(&path, &worker_mode);
                            match path.to_str() {
                                Some(s) => UiAndroidAudioCmd::SetNext {
                                    path: s.to_owned(),
                                    gain,
                                },
                                None => continue,
                            }
                        }
                        Job::SetGain { path } => {
                            let gain = compute_gain(&path, &worker_mode);
                            match path.to_str() {
                                Some(s) => UiAndroidAudioCmd::SetReplayGain {
                                    path: s.to_owned(),
                                    gain,
                                },
                                None => continue,
                            }
                        }
                        Job::Direct(cmd) => cmd,
                    };
                    emitter(cmd);
                }
            })
            .map_err(|e| EngineError::Init(e.to_string()))?;

        Ok(Self {
            jobs: Mutex::new(jobs_tx),
            mode,
            slots,
        })
    }

    pub fn slots_handle(&self) -> SharedSlots {
        Arc::clone(&self.slots)
    }

    fn enqueue(&self, job: Job) -> EngineResult<()> {
        self.jobs
            .lock()
            .map_err(|_| EngineError::Command("android audio bridge queue poisoned".into()))?
            .send(job)
            .map_err(|_| EngineError::Command("android audio bridge worker stopped".into()))
    }

    fn send_cmd(&self, cmd: UiAndroidAudioCmd) -> EngineResult<()> {
        self.enqueue(Job::Direct(cmd))
    }

    fn lock_slots(&self) -> std::sync::MutexGuard<'_, (Option<PathBuf>, Option<PathBuf>)> {
        self.slots.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[cfg(any(target_os = "android", test))]
fn compute_gain(path: &Path, mode: &Arc<Mutex<ReplayGain>>) -> f64 {
    let is_stream = path
        .to_str()
        .is_some_and(|s| s.starts_with("http://") || s.starts_with("https://"));
    if is_stream {
        return 1.0;
    }
    let current_mode = mode.lock().map(|m| *m).unwrap_or_default();
    replaygain::factor(replaygain::read(path), current_mode)
}

#[cfg(any(target_os = "android", test))]
fn validate_utf8(path: &Path) -> EngineResult<()> {
    path.to_str()
        .map(|_| ())
        .ok_or_else(|| EngineError::Command(format!("path is not UTF-8: {}", path.display())))
}

#[cfg(any(target_os = "android", test))]
impl AudioEngine for AndroidBridgeEngine {
    fn load(&self, path: &Path) -> EngineResult<()> {
        validate_utf8(path)?;
        *self.lock_slots() = (Some(path.to_path_buf()), None);
        self.enqueue(Job::Load {
            path: path.to_path_buf(),
        })
    }

    fn set_next(&self, path: Option<&Path>) -> EngineResult<()> {
        if let Some(p) = path {
            validate_utf8(p)?;
            self.lock_slots().1 = Some(p.to_path_buf());
            self.enqueue(Job::SetNext {
                path: p.to_path_buf(),
            })
        } else {
            self.lock_slots().1 = None;
            self.send_cmd(UiAndroidAudioCmd::ClearNext)
        }
    }

    fn play(&self) -> EngineResult<()> {
        self.send_cmd(UiAndroidAudioCmd::Play)
    }

    fn pause(&self) -> EngineResult<()> {
        self.send_cmd(UiAndroidAudioCmd::Pause)
    }

    fn stop(&self) -> EngineResult<()> {
        *self.lock_slots() = (None, None);
        self.send_cmd(UiAndroidAudioCmd::Stop)
    }

    fn seek(&self, seconds: f64) -> EngineResult<()> {
        self.send_cmd(UiAndroidAudioCmd::Seek { seconds })
    }

    fn set_volume(&self, percent: f64) -> EngineResult<()> {
        self.send_cmd(UiAndroidAudioCmd::SetVolume { percent })
    }

    fn set_replaygain(&self, mode: ReplayGain) -> EngineResult<()> {
        *self.mode.lock().unwrap_or_else(|e| e.into_inner()) = mode;
        let (current, next) = self.lock_slots().clone();
        for path in [current, next].into_iter().flatten() {
            self.enqueue(Job::SetGain { path })?;
        }
        Ok(())
    }

    fn set_gapless(&self, enabled: bool) -> EngineResult<()> {
        self.send_cmd(UiAndroidAudioCmd::SetGapless { enabled })
    }

    fn set_wasapi_exclusive(&self, _enabled: bool) -> EngineResult<()> {
        Ok(())
    }

    fn set_equalizer(&self, eq: &Equalizer) -> EngineResult<()> {
        let clamped = eq.clamped();
        self.send_cmd(UiAndroidAudioCmd::SetEqualizer {
            enabled: clamped.enabled,
            preamp_db: clamped.preamp_db,
            gains_db: clamped.gains_db.to_vec(),
        })
    }

    fn begin_crossfade(&self, seconds: f64) -> EngineResult<bool> {
        if !seconds.is_finite() || seconds <= 0.0 || self.lock_slots().0.is_none() {
            return Ok(false);
        }
        self.send_cmd(UiAndroidAudioCmd::SetCrossfade { seconds })?;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn translates_every_android_event_variant() {
        assert_eq!(
            translate_event(UiAndroidAudioEvent::Position {
                seconds: 12.5,
                duration: None,
            }),
            BridgeAction::Engine(vec![EngineEvent::Position { seconds: 12.5 }])
        );

        assert_eq!(
            translate_event(UiAndroidAudioEvent::Position {
                seconds: 0.0,
                duration: Some(180.0),
            }),
            BridgeAction::Engine(vec![
                EngineEvent::Position { seconds: 0.0 },
                EngineEvent::Duration { seconds: 180.0 },
            ])
        );

        assert_eq!(
            translate_event(UiAndroidAudioEvent::TrackStarted {
                path: "/music/a.flac".into(),
                auto_advanced: true,
            }),
            BridgeAction::Engine(vec![EngineEvent::TrackStarted {
                path: PathBuf::from("/music/a.flac"),
                auto_advanced: true,
            }])
        );

        assert_eq!(
            translate_event(UiAndroidAudioEvent::TrackEnded {
                path: "/music/a.flac".into(),
                reason: "eof".into(),
            }),
            BridgeAction::Engine(vec![EngineEvent::TrackEnded {
                path: PathBuf::from("/music/a.flac"),
                reason: EndReason::Eof,
            }])
        );

        assert_eq!(
            translate_event(UiAndroidAudioEvent::TrackEnded {
                path: "/music/a.flac".into(),
                reason: "error".into(),
            }),
            BridgeAction::Engine(vec![EngineEvent::TrackEnded {
                path: PathBuf::from("/music/a.flac"),
                reason: EndReason::Error,
            }])
        );

        assert_eq!(
            translate_event(UiAndroidAudioEvent::TrackEnded {
                path: "/music/a.flac".into(),
                reason: "stopped".into(),
            }),
            BridgeAction::Engine(vec![EngineEvent::TrackEnded {
                path: PathBuf::from("/music/a.flac"),
                reason: EndReason::Stopped,
            }])
        );

        assert_eq!(
            translate_event(UiAndroidAudioEvent::Paused { paused: true }),
            BridgeAction::Engine(vec![EngineEvent::Paused(true)])
        );
        assert_eq!(
            translate_event(UiAndroidAudioEvent::Idle),
            BridgeAction::Engine(vec![EngineEvent::Idle])
        );
        assert_eq!(
            translate_event(UiAndroidAudioEvent::Error("codec failure".into())),
            BridgeAction::Engine(vec![EngineEvent::Error("codec failure".into())])
        );
        assert_eq!(
            translate_event(UiAndroidAudioEvent::MediaPlay),
            BridgeAction::MediaPlay
        );
        assert_eq!(
            translate_event(UiAndroidAudioEvent::MediaPause),
            BridgeAction::MediaPause
        );
        assert_eq!(
            translate_event(UiAndroidAudioEvent::MediaToggle),
            BridgeAction::MediaToggle
        );
        assert_eq!(
            translate_event(UiAndroidAudioEvent::MediaNext),
            BridgeAction::Engine(vec![EngineEvent::Remote(RemoteCommand::Next)])
        );
        assert_eq!(
            translate_event(UiAndroidAudioEvent::MediaPrevious),
            BridgeAction::Engine(vec![EngineEvent::Remote(RemoteCommand::Previous)])
        );
    }

    #[test]
    fn cmd_bus_buffers_until_subscriber_attaches() {
        let bus = AndroidCmdBus::new();
        bus.emit(UiAndroidAudioCmd::SetVolume { percent: 80.0 });
        bus.emit(UiAndroidAudioCmd::Play);

        let (id, mut rx) = bus.subscribe();
        assert_eq!(
            rx.try_recv().unwrap(),
            UiAndroidAudioCmd::SetVolume { percent: 80.0 }
        );
        assert_eq!(rx.try_recv().unwrap(), UiAndroidAudioCmd::Play);

        bus.emit(UiAndroidAudioCmd::Pause);
        assert_eq!(rx.try_recv().unwrap(), UiAndroidAudioCmd::Pause);

        bus.unsubscribe(id);
    }

    #[test]
    fn android_bridge_engine_emits_all_commands_in_order() {
        let (tx, rx) = mpsc::channel();
        let engine = AndroidBridgeEngine::with_emitter(Box::new(move |cmd| {
            let _ = tx.send(cmd);
        }))
        .unwrap();

        assert!(!engine.begin_crossfade(3.0).unwrap());

        engine
            .load(Path::new("https://example.com/stream.mp3"))
            .unwrap();
        engine
            .set_next(Some(Path::new("https://example.com/next.mp3")))
            .unwrap();
        engine.play().unwrap();
        engine.pause().unwrap();
        engine.seek(42.5).unwrap();
        engine.set_volume(75.0).unwrap();
        engine.set_gapless(false).unwrap();
        engine
            .set_equalizer(&Equalizer {
                enabled: true,
                preamp_db: -20.0,
                gains_db: [2.0; 10],
            })
            .unwrap();
        engine.set_replaygain(ReplayGain::Track).unwrap();
        assert!(engine.begin_crossfade(4.0).unwrap());
        engine.set_next(None).unwrap();
        engine.stop().unwrap();

        let mut received = Vec::new();
        for _ in 0..13 {
            received.push(rx.recv_timeout(Duration::from_secs(2)).unwrap());
        }

        assert_eq!(
            received,
            vec![
                UiAndroidAudioCmd::Load {
                    path: "https://example.com/stream.mp3".into(),
                    gain: 1.0,
                },
                UiAndroidAudioCmd::SetNext {
                    path: "https://example.com/next.mp3".into(),
                    gain: 1.0,
                },
                UiAndroidAudioCmd::Play,
                UiAndroidAudioCmd::Pause,
                UiAndroidAudioCmd::Seek { seconds: 42.5 },
                UiAndroidAudioCmd::SetVolume { percent: 75.0 },
                UiAndroidAudioCmd::SetGapless { enabled: false },
                UiAndroidAudioCmd::SetEqualizer {
                    enabled: true,
                    preamp_db: -12.0,
                    gains_db: vec![2.0; 10],
                },
                UiAndroidAudioCmd::SetReplayGain {
                    path: "https://example.com/stream.mp3".into(),
                    gain: 1.0,
                },
                UiAndroidAudioCmd::SetReplayGain {
                    path: "https://example.com/next.mp3".into(),
                    gain: 1.0,
                },
                UiAndroidAudioCmd::SetCrossfade { seconds: 4.0 },
                UiAndroidAudioCmd::ClearNext,
                UiAndroidAudioCmd::Stop,
            ]
        );
    }
}

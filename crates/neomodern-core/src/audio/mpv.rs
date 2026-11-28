//! libmpv backend. This is the only file that talks to libmpv.
//!
//! mpv's playlist is used as a two-slot buffer only: `[current, next]`
//! (plus, briefly, the finished previous entry until the engine removes it
//! on the following `StartFile`). The real queue lives in `crate::queue`.
//!
//! Entries are tracked by mpv's stable playlist entry ids (`playlist/N/id`),
//! not by `playlist-pos`: right after `loadfile`, and around track changes,
//! `playlist-pos` is transitional and can not be trusted. The engine
//! remembers the id of the entry it appended as "next"; `set_next` only ever
//! removes that entry, and a `StartFile` for that id is an auto-advance.
//!
//! Threading: one background thread owns `wait_event` and turns mpv events
//! into [`EngineEvent`]s. Commands may be called from any thread; all
//! playlist edits (commands and the event thread) hold the `slots` mutex.
//!
//! `Idle` is only emitted after something has started playing, so the
//! initial idle state at startup produces no event.

use super::{
    AudioEngine, EQ_BANDS, EndReason, EngineError, EngineEvent, EngineResult, Equalizer, ReplayGain,
};
use libmpv2::events::{Event, PropertyData};
use libmpv2::{Format, Mpv};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

const POSITION_INTERVAL: Duration = Duration::from_millis(250);
/// Volume steps of a fade.
const FADE_STEP: Duration = Duration::from_millis(40);
const OBS_PAUSE: u64 = 1;
const OBS_DURATION: u64 = 2;
const OBS_TIME_POS: u64 = 3;
const OBS_IDLE: u64 = 4;

// mpv_end_file_reason values.
const END_EOF: u32 = 0;
const END_ERROR: u32 = 4;
const END_REDIRECT: u32 = 5;

#[derive(Debug, Clone, Default)]
pub struct MpvOptions {
    /// Audio output driver (`ao`), e.g. `"null"` in tests. `None` = mpv default.
    pub audio_output: Option<String>,
    /// `ao-null-untimed`: the null output plays as fast as possible.
    pub untimed: bool,
}

/// An mpv playlist entry we created: its stable entry id and our path.
#[derive(Debug, Clone)]
struct Slot {
    id: i64,
    path: PathBuf,
}

/// The two slots of the engine.
#[derive(Debug, Default)]
struct Slots {
    /// Entry created by the last `load` (or promoted from `next`).
    current: Option<Slot>,
    /// Entry appended by `set_next`, if any.
    next: Option<Slot>,
}

/// Settings a crossfade's tail player copies from the main one.
#[derive(Debug, Clone)]
struct Shared {
    /// Target volume (the user's volume; a fade-in ramps towards it).
    volume: f64,
    replaygain: ReplayGain,
    /// Current `af` value (equalizer), empty when off.
    af: String,
    exclusive: bool,
    /// Fade-in length for the next `load` (armed by `begin_crossfade`).
    fade_in: Option<f64>,
}

impl Default for Shared {
    fn default() -> Self {
        Self {
            volume: 100.0,
            replaygain: ReplayGain::default(),
            af: String::new(),
            exclusive: false,
            fade_in: None,
        }
    }
}

pub struct MpvEngine {
    mpv: Arc<Mpv>,
    slots: Arc<Mutex<Slots>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
    #[cfg_attr(not(target_os = "windows"), allow(dead_code))]
    custom_ao: bool,
    options: MpvOptions,
    shared: Arc<Mutex<Shared>>,
    /// Second instance that plays the end of the previous track during a
    /// crossfade. Created on first use; holds one file at most.
    tail: Mutex<Option<Arc<Mpv>>>,
    /// Bumped to cancel a running fade (main and tail separately).
    main_fade: Arc<AtomicU64>,
    tail_fade: Arc<AtomicU64>,
}

/// mpv `af` value for `eq`: one peaking filter per octave band plus the
/// preamp, in a labelled lavfi graph. Empty when it changes nothing.
pub fn equalizer_af(eq: &Equalizer) -> String {
    let eq = eq.clamped();
    if eq.is_flat() {
        return String::new();
    }
    let mut chain: Vec<String> = EQ_BANDS
        .iter()
        .zip(eq.gains_db)
        .filter(|(_, g)| *g != 0.0)
        .map(|(f, g)| format!("equalizer=f={f}:t=o:w=1:g={g:.1}"))
        .collect();
    if eq.preamp_db != 0.0 {
        chain.push(format!("volume={:.1}dB", eq.preamp_db));
    }
    format!("@neoeq:lavfi=[{}]", chain.join(","))
}

fn shared_lock(shared: &Mutex<Shared>) -> MutexGuard<'_, Shared> {
    shared.lock().unwrap_or_else(|e| e.into_inner())
}

/// Moves `mpv`'s volume from `from` to the value `to()` returns, over
/// `seconds`, unless `token` changes (a newer fade or a stop). Calls
/// `done` when it finished without being cancelled.
fn spawn_fade(
    mpv: Arc<Mpv>,
    token: Arc<AtomicU64>,
    from: f64,
    to: impl Fn() -> f64 + Send + 'static,
    seconds: f64,
    done: impl FnOnce(&Mpv) + Send + 'static,
) {
    let mine = token.fetch_add(1, Ordering::SeqCst) + 1;
    let spawned = std::thread::Builder::new()
        .name("mpv-fade".into())
        .spawn(move || {
            let total = Duration::from_secs_f64(seconds.max(0.1));
            let started = Instant::now();
            loop {
                if token.load(Ordering::SeqCst) != mine {
                    return;
                }
                let k = (started.elapsed().as_secs_f64() / total.as_secs_f64()).min(1.0);
                let target = to();
                let v = from + (target - from) * k;
                let _ = mpv.set_property("volume", v.clamp(0.0, 100.0));
                if k >= 1.0 {
                    break;
                }
                std::thread::sleep(FADE_STEP);
            }
            if token.load(Ordering::SeqCst) == mine {
                done(&mpv);
            }
        });
    if let Err(e) = spawned {
        log::warn!("could not start a fade: {e}");
    }
}

fn cmd_err(name: &str, e: impl std::fmt::Debug) -> EngineError {
    EngineError::Command(format!("{name}: {e:?}"))
}

/// Human-readable text for the libmpv errors a user can run into.
/// Codes are mpv's stable `mpv_error` values from `client.h`.
fn describe(e: &libmpv2::Error) -> String {
    match e {
        libmpv2::Error::Raw(code) => match *code {
            -13 => "the file could not be loaded".into(),
            -14 => "the audio output could not be opened".into(),
            -16 => "there is nothing to play in this file".into(),
            -17 => "the file format is not recognised".into(),
            -18 => "the file uses an unsupported format".into(),
            other => format!("mpv error {other}"),
        },
        other => format!("{other:?}"),
    }
}

fn lock_slots(slots: &Mutex<Slots>) -> MutexGuard<'_, Slots> {
    slots.lock().unwrap_or_else(|e| e.into_inner())
}

fn get_i64(mpv: &Mpv, name: &str) -> EngineResult<i64> {
    mpv.get_property::<i64>(name).map_err(|e| cmd_err(name, e))
}

/// Id of the last playlist entry (the one `loadfile` just added).
fn last_entry_id(mpv: &Mpv) -> EngineResult<Option<i64>> {
    let count = get_i64(mpv, "playlist-count")?;
    if count == 0 {
        return Ok(None);
    }
    get_i64(mpv, &format!("playlist/{}/id", count - 1)).map(Some)
}

/// Index of the playlist entry with mpv entry id `id`.
fn index_of_entry(mpv: &Mpv, id: i64) -> EngineResult<Option<i64>> {
    let count = get_i64(mpv, "playlist-count")?;
    for i in 0..count {
        if get_i64(mpv, &format!("playlist/{i}/id"))? == id {
            return Ok(Some(i));
        }
    }
    Ok(None)
}

fn path_str(path: &Path) -> EngineResult<&str> {
    path.to_str()
        .ok_or_else(|| EngineError::Command(format!("path is not valid UTF-8: {}", path.display())))
}

#[cfg(target_os = "linux")]
fn system_ca_bundle() -> Option<&'static str> {
    const CANDIDATES: &[&str] = &[
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/pki/tls/certs/ca-bundle.crt",
        "/etc/ssl/ca-bundle.pem",
        "/etc/ssl/cert.pem",
    ];
    CANDIDATES.iter().copied().find(|p| Path::new(p).is_file())
}

fn request_log_messages(mpv: &Mpv, min_level: &str) -> EngineResult<()> {
    let level = std::ffi::CString::new(min_level)
        .map_err(|e| EngineError::Init(format!("log level {min_level}: {e}")))?;
    // SAFETY: `mpv.ctx` is a valid, initialized `mpv_handle` owned by `mpv`,
    // and `level` is a NUL-terminated C string valid for the call.
    let rc = unsafe { libmpv2_sys::mpv_request_log_messages(mpv.ctx.as_ptr(), level.as_ptr()) };
    if rc < 0 {
        return Err(EngineError::Init(format!(
            "request_log_messages({min_level}): mpv error {rc}"
        )));
    }
    Ok(())
}

/// Short, query-free display name for error messages so signed stream URLs
/// never leak long query tokens into the UI.
pub(crate) fn display_target_name(path: &Path) -> String {
    let raw = path.to_string_lossy();
    if raw.starts_with("http://") || raw.starts_with("https://") {
        let without_query = raw
            .split(['?', '#'])
            .next()
            .unwrap_or(&raw)
            .trim_end_matches('/');
        if without_query.is_empty() {
            return "stream".into();
        }
        if without_query.chars().count() <= 80 {
            return without_query.to_owned();
        }
        if let Some((scheme, rest)) = without_query.split_once("://") {
            let host = rest.split('/').next().unwrap_or("");
            if !host.is_empty() {
                return format!("{scheme}://{host}");
            }
        }
        return "stream".into();
    }
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| raw.into_owned())
}

fn strip_url_queries(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    loop {
        let next = match (rest.find("http://"), rest.find("https://")) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (Some(a), None) | (None, Some(a)) => Some(a),
            (None, None) => None,
        };
        let Some(pos) = next else {
            out.push_str(rest);
            return out;
        };
        out.push_str(&rest[..pos]);
        let after_scheme = &rest[pos..];
        let end = after_scheme
            .find(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | '>' | ')'))
            .unwrap_or(after_scheme.len());
        let url = &after_scheme[..end];
        let clean_url = url.split(['?', '#']).next().unwrap_or(url);
        out.push_str(clean_url);
        rest = &after_scheme[end..];
    }
}

fn is_generic_mpv_error(prefix: &str, msg: &str) -> bool {
    (prefix == "cplayer" && msg.eq_ignore_ascii_case("Opening failed."))
        || msg.starts_with("Failed to open ")
}

fn sanitize_mpv_log(prefix: &str, msg: &str) -> String {
    let collapsed: String = strip_url_queries(msg)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    let full = if prefix.is_empty() {
        collapsed
    } else {
        format!("{prefix}: {collapsed}")
    };
    const MAX_LEN: usize = 140;
    if full.chars().count() <= MAX_LEN {
        return full;
    }
    let truncated: String = full.chars().take(MAX_LEN - 1).collect();
    format!("{}…", truncated.trim_end())
}

fn format_playback_error(path: Option<&Path>, reason: &str, detail: Option<&str>) -> String {
    let base = match path {
        Some(p) => format!("Could not play {}: {reason}", display_target_name(p)),
        None => format!("Playback failed: {reason}"),
    };
    match detail.map(str::trim).filter(|d| !d.is_empty()) {
        Some(d) => format!("{base} ({d})"),
        None => base,
    }
}

impl MpvEngine {
    pub fn new(options: MpvOptions, events: Sender<EngineEvent>) -> EngineResult<MpvEngine> {
        let custom_ao = options.audio_output.is_some();
        let mpv = Self::create(&options, true)?;
        let _ = mpv.set_property("access-references", "no");
        if let Err(e) = request_log_messages(&mpv, "warn") {
            log::warn!("{e}");
        }

        for (name, format, id) in [
            ("pause", Format::Flag, OBS_PAUSE),
            ("duration", Format::Double, OBS_DURATION),
            ("time-pos", Format::Double, OBS_TIME_POS),
            ("idle-active", Format::Flag, OBS_IDLE),
        ] {
            mpv.observe_property(name, format, id)
                .map_err(|e| EngineError::Init(format!("observe {name}: {e}")))?;
        }

        let mpv = Arc::new(mpv);
        let slots = Arc::new(Mutex::new(Slots::default()));
        let stop = Arc::new(AtomicBool::new(false));
        let worker = EventLoop {
            mpv: mpv.clone(),
            slots: slots.clone(),
            stop: stop.clone(),
            tx: events,
            current_path: None,
            started_any: false,
            last_position: None,
            last_error: None,
            last_error_generic: false,
        };
        let thread = std::thread::Builder::new()
            .name("mpv-events".into())
            .spawn(move || worker.run())
            .map_err(|e| EngineError::Init(e.to_string()))?;

        Ok(MpvEngine {
            mpv,
            slots,
            stop,
            thread: Some(thread),
            custom_ao,
            options,
            shared: Arc::new(Mutex::new(Shared::default())),
            tail: Mutex::new(None),
            main_fade: Arc::new(AtomicU64::new(0)),
            tail_fade: Arc::new(AtomicU64::new(0)),
        })
    }

    /// A configured mpv instance. `main` is the queue player; the other one
    /// only plays a crossfade's tail and needs no prefetching.
    fn create(options: &MpvOptions, main: bool) -> EngineResult<Mpv> {
        #[cfg(target_os = "windows")]
        let custom_ao = options.audio_output.is_some();
        Mpv::with_initializer(|i| {
            i.set_property("vid", "no")?;
            i.set_property("audio-display", "no")?;
            i.set_property("idle", "yes")?;
            i.set_property("keep-open", "no")?;
            if main {
                i.set_property("prefetch-playlist", "yes")?;
            }
            i.set_property("gapless-audio", "weak")?;
            #[cfg(target_os = "windows")]
            if !custom_ao {
                i.set_property("audio-exclusive", "no")?;
            }
            i.set_property("replaygain", "album")?;
            i.set_property("config", "no")?;
            i.set_property("load-scripts", "no")?;
            i.set_property("input-default-bindings", "no")?;
            i.set_property("terminal", "no")?;
            i.set_property("ytdl", "no")?;
            #[cfg(feature = "legacy-online")]
            i.set_property("user-agent", crate::online::STREAM_USER_AGENT)?;
            #[cfg(not(feature = "legacy-online"))]
            i.set_property(
                "user-agent",
                concat!("NeoModern/", env!("CARGO_PKG_VERSION")),
            )?;
            #[cfg(target_os = "linux")]
            if let Some(ca_bundle) = system_ca_bundle()
                && let Err(e) = i.set_property("tls-ca-file", ca_bundle)
            {
                log::warn!("could not set tls-ca-file={ca_bundle}: {e}");
            }
            if let Some(ao) = &options.audio_output {
                i.set_property("ao", ao.as_str())?;
            }
            if options.untimed {
                i.set_property("ao-null-untimed", "yes")?;
            }
            Ok(())
        })
        .map_err(|e| EngineError::Init(e.to_string()))
    }

    /// The tail player, created on first use with the current settings.
    fn tail(&self) -> EngineResult<Arc<Mpv>> {
        let mut tail = self.tail.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(t) = tail.as_ref() {
            return Ok(Arc::clone(t));
        }
        let created = Arc::new(Self::create(&self.options, false)?);
        let _ = created.set_property("access-references", "no");
        *tail = Some(Arc::clone(&created));
        Ok(created)
    }

    /// Stops a crossfade tail, if one is playing.
    fn stop_tail(&self) {
        self.tail_fade.fetch_add(1, Ordering::SeqCst);
        let tail = self.tail.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some(t) = tail {
            let _ = t.command("stop", &[]);
        }
    }

    fn lock(&self) -> MutexGuard<'_, Slots> {
        lock_slots(&self.slots)
    }

    fn command(&self, name: &str, args: &[&str]) -> EngineResult<()> {
        self.mpv.command(name, args).map_err(|e| cmd_err(name, e))
    }
}

impl Drop for MpvEngine {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl AudioEngine for MpvEngine {
    fn load(&self, path: &Path) -> EngineResult<()> {
        let mut slots = self.lock();
        let fade_in = shared_lock(&self.shared).fade_in.take();
        if fade_in.is_some() {
            self.main_fade.fetch_add(1, Ordering::SeqCst);
            let _ = self.mpv.set_property("volume", 0.0);
        }
        self.command("loadfile", &[path_str(path)?, "replace"])?;
        if let Some(seconds) = fade_in {
            let shared = Arc::clone(&self.shared);
            spawn_fade(
                Arc::clone(&self.mpv),
                Arc::clone(&self.main_fade),
                0.0,
                move || shared_lock(&shared).volume,
                seconds,
                |_| {},
            );
        }
        slots.next = None;
        slots.current = last_entry_id(&self.mpv)?.map(|id| Slot {
            id,
            path: path.to_path_buf(),
        });
        Ok(())
    }

    fn set_next(&self, path: Option<&Path>) -> EngineResult<()> {
        let mut slots = self.lock();
        if let Some(Slot { id, .. }) = slots.next.take() {
            // The old next entry may already be playing (mpv advanced, but
            // the event thread has not handled StartFile yet): keep it then.
            let playing = get_i64(&self.mpv, "playlist-playing-pos").unwrap_or(-1);
            if let Some(index) = index_of_entry(&self.mpv, id)?
                && index != playing
            {
                self.command("playlist-remove", &[&index.to_string()])?;
            }
        }
        let Some(path) = path else { return Ok(()) };
        if slots.current.is_none() {
            // Nothing loaded, so there is nothing to play after it.
            return Ok(());
        }
        self.command("loadfile", &[path_str(path)?, "append"])?;
        slots.next = last_entry_id(&self.mpv)?.map(|id| Slot {
            id,
            path: path.to_path_buf(),
        });
        Ok(())
    }

    fn play(&self) -> EngineResult<()> {
        self.mpv
            .set_property("pause", false)
            .map_err(|e| cmd_err("pause", e))
    }

    fn pause(&self) -> EngineResult<()> {
        // A paused player should be silent: drop a crossfade tail too.
        self.stop_tail();
        self.mpv
            .set_property("pause", true)
            .map_err(|e| cmd_err("pause", e))
    }

    fn stop(&self) -> EngineResult<()> {
        self.stop_tail();
        let mut slots = self.lock();
        *slots = Slots::default();
        self.command("stop", &[])
    }

    fn seek(&self, seconds: f64) -> EngineResult<()> {
        self.command("seek", &[&seconds.max(0.0).to_string(), "absolute"])
    }

    fn set_volume(&self, percent: f64) -> EngineResult<()> {
        let percent = percent.clamp(0.0, 100.0);
        shared_lock(&self.shared).volume = percent;
        // A running fade-in ends at the new volume; otherwise set it now.
        self.main_fade.fetch_add(1, Ordering::SeqCst);
        self.mpv
            .set_property("volume", percent)
            .map_err(|e| cmd_err("volume", e))
    }

    fn set_replaygain(&self, mode: ReplayGain) -> EngineResult<()> {
        shared_lock(&self.shared).replaygain = mode;
        self.mpv
            .set_property("replaygain", mode.mpv_value())
            .map_err(|e| cmd_err("replaygain", e))
    }

    fn set_gapless(&self, enabled: bool) -> EngineResult<()> {
        let value = if enabled { "weak" } else { "no" };
        self.mpv
            .set_property("gapless-audio", value)
            .map_err(|e| cmd_err("gapless-audio", e))
    }

    fn set_wasapi_exclusive(&self, enabled: bool) -> EngineResult<()> {
        shared_lock(&self.shared).exclusive = enabled;
        #[cfg(target_os = "windows")]
        if !self.custom_ao {
            let value = if enabled { "yes" } else { "no" };
            self.mpv
                .set_property("audio-exclusive", value)
                .map_err(|e| cmd_err("audio-exclusive", e))?;
            // Reload the audio output immediately when actively playing so the
            // user hears the switch without waiting for the next track; while
            // idle or paused the updated option applies on the next open.
            let idle = self.mpv.get_property::<bool>("idle-active").unwrap_or(true);
            let paused = self.mpv.get_property::<bool>("pause").unwrap_or(true);
            if !idle
                && !paused
                && let Err(e) = self.command("ao-reload", &[])
            {
                log::warn!("ao-reload after audio-exclusive={value} failed: {e}");
            }
        }
        #[cfg(not(target_os = "windows"))]
        let _ = enabled;
        Ok(())
    }

    fn set_equalizer(&self, eq: &Equalizer) -> EngineResult<()> {
        let af = equalizer_af(eq);
        shared_lock(&self.shared).af = af.clone();
        self.mpv
            .set_property("af", af.as_str())
            .map_err(|e| cmd_err("af", e))
    }

    fn begin_crossfade(&self, seconds: f64) -> EngineResult<bool> {
        let settings = shared_lock(&self.shared).clone();
        // Exclusive output allows one stream only.
        if settings.exclusive || seconds.is_nan() || seconds <= 0.0 {
            return Ok(false);
        }
        let Some(path) = self.lock().current.as_ref().map(|s| s.path.clone()) else {
            return Ok(false);
        };
        let Ok(position) = self.mpv.get_property::<f64>("time-pos") else {
            return Ok(false);
        };
        let tail = self.tail()?;
        self.tail_fade.fetch_add(1, Ordering::SeqCst);
        let volume = self
            .mpv
            .get_property::<f64>("volume")
            .unwrap_or(settings.volume);
        let set =
            |name: &str, value: &str| tail.set_property(name, value).map_err(|e| cmd_err(name, e));
        tail.set_property("volume", volume)
            .map_err(|e| cmd_err("volume", e))?;
        set("replaygain", settings.replaygain.mpv_value())?;
        set("af", settings.af.as_str())?;
        set("start", &format!("{position:.3}"))?;
        set("pause", "no")?;
        tail.command("loadfile", &[path_str(&path)?, "replace"])
            .map_err(|e| cmd_err("loadfile", e))?;
        let _ = tail.set_property("start", "none");
        spawn_fade(
            Arc::clone(&tail),
            Arc::clone(&self.tail_fade),
            volume,
            || 0.0,
            seconds,
            |mpv| {
                let _ = mpv.command("stop", &[]);
            },
        );
        shared_lock(&self.shared).fade_in = Some(seconds);
        Ok(true)
    }
}

struct EventLoop {
    mpv: Arc<Mpv>,
    slots: Arc<Mutex<Slots>>,
    stop: Arc<AtomicBool>,
    tx: Sender<EngineEvent>,
    current_path: Option<PathBuf>,
    started_any: bool,
    last_position: Option<Instant>,
    last_error: Option<String>,
    last_error_generic: bool,
}

impl EventLoop {
    fn send(&self, ev: EngineEvent) {
        // The receiver going away just means nobody listens any more.
        let _ = self.tx.send(ev);
    }

    fn run(mut self) {
        while !self.stop.load(Ordering::SeqCst) {
            match self.mpv.clone().wait_event(0.2) {
                None => {}
                Some(Err(e)) => {
                    // Also covers EndFile with an error code: libmpv2 reports
                    // those as Err without the reason, so the player learns
                    // about it through `Error` (and the following Idle or
                    // TrackStarted).
                    let reason = describe(&e);
                    let detail = self.last_error.take();
                    self.last_error_generic = false;
                    let what = format_playback_error(
                        self.current_path.as_deref(),
                        &reason,
                        detail.as_deref(),
                    );
                    self.send(EngineEvent::Error(what));
                }
                Some(Ok(ev)) => self.handle(ev),
            }
        }
    }

    fn handle(&mut self, ev: Event<'_>) {
        match ev {
            Event::StartFile => self.on_start_file(),
            Event::EndFile(reason) => {
                if reason == END_REDIRECT {
                    return;
                }
                let reason = match reason {
                    END_EOF => EndReason::Eof,
                    END_ERROR => EndReason::Error,
                    _ => EndReason::Stopped,
                };
                if let Some(path) = self.current_path.clone() {
                    self.send(EngineEvent::TrackEnded { path, reason });
                }
            }
            Event::FileLoaded => {
                self.last_error = None;
                self.last_error_generic = false;
                // Observed `duration` only reports changes: two tracks of the
                // same length in a row would produce no event, so read it.
                if let Ok(seconds) = self.mpv.get_property::<f64>("duration") {
                    self.send(EngineEvent::Duration { seconds });
                }
            }
            Event::LogMessage {
                prefix,
                level: _,
                text,
                log_level,
            } => self.on_log_message(prefix, text, log_level),
            Event::Seek | Event::PlaybackRestart => {
                if let Ok(seconds) = self.mpv.get_property::<f64>("time-pos") {
                    self.last_position = Some(Instant::now());
                    self.send(EngineEvent::Position { seconds });
                }
            }
            Event::PropertyChange {
                name,
                change,
                reply_userdata,
            } => self.on_property(reply_userdata, name, change),
            _ => {}
        }
    }

    fn on_log_message(&mut self, prefix: &str, text: &str, log_level: libmpv2::LogLevel) {
        let msg = text.trim();
        if msg.is_empty() {
            return;
        }
        match log_level {
            libmpv2::mpv_log_level::Fatal | libmpv2::mpv_log_level::Error => {
                let sanitized = sanitize_mpv_log(prefix, msg);
                log::error!("mpv {sanitized}");
                let generic = is_generic_mpv_error(prefix, msg);
                if self.last_error.is_none() || (self.last_error_generic && !generic) {
                    self.last_error = Some(sanitized);
                    self.last_error_generic = generic;
                }
            }
            libmpv2::mpv_log_level::Warn => {
                log::warn!("mpv {}: {}", prefix, strip_url_queries(msg));
            }
            _ => {}
        }
    }

    fn on_start_file(&mut self) {
        self.started_any = true;
        self.last_position = None;
        self.last_error = None;
        self.last_error_generic = false;
        let started = {
            let mut slots = lock_slots(&self.slots);
            self.started_entry(&mut slots)
        };
        match started {
            Ok((path, auto_advanced)) => {
                self.current_path = Some(path.clone());
                self.send(EngineEvent::TrackStarted {
                    path,
                    auto_advanced,
                });
            }
            Err(e) => self.send(EngineEvent::Error(format!("start-file: {e}"))),
        }
    }

    /// Identify the entry that just started and drop the finished entries
    /// before it, so the playlist is back to `[current, next?]`.
    ///
    /// Events are handled asynchronously, so by now the entry may already
    /// have finished (`playlist-playing-pos` is -1). Then it can only be one
    /// of our slots: the next entry if we have one, else the loaded entry.
    fn started_entry(&self, slots: &mut Slots) -> EngineResult<(PathBuf, bool)> {
        let pos = get_i64(&self.mpv, "playlist-playing-pos")?;
        let started = if pos >= 0 {
            let id = get_i64(&self.mpv, &format!("playlist/{pos}/id"))?;
            [&slots.next, &slots.current]
                .into_iter()
                .flatten()
                .find(|s| s.id == id)
                .cloned()
                .unwrap_or_else(|| {
                    let path = self
                        .mpv
                        .get_property::<String>(&format!("playlist/{pos}/filename"))
                        .unwrap_or_default();
                    log::warn!("mpv started an entry the engine did not queue: {path}");
                    Slot {
                        id,
                        path: PathBuf::from(path),
                    }
                })
        } else {
            slots
                .next
                .clone()
                .or_else(|| slots.current.clone())
                .ok_or_else(|| EngineError::Command("no playing entry".into()))?
        };
        let auto_advanced = slots.next.as_ref().is_some_and(|s| s.id == started.id);
        if auto_advanced {
            slots.next = None;
        }
        slots.current = Some(started.clone());
        if let Some(index) = index_of_entry(&self.mpv, started.id)? {
            for _ in 0..index {
                self.mpv
                    .command("playlist-remove", &["0"])
                    .map_err(|e| cmd_err("playlist-remove", e))?;
            }
        }
        Ok((started.path, auto_advanced))
    }

    fn on_property(&mut self, id: u64, name: &str, change: PropertyData<'_>) {
        match (id, change) {
            (OBS_PAUSE, PropertyData::Flag(b)) => self.send(EngineEvent::Paused(b)),
            (OBS_DURATION, PropertyData::Double(seconds)) => {
                self.send(EngineEvent::Duration { seconds })
            }
            (OBS_TIME_POS, PropertyData::Double(seconds)) => {
                let due = self
                    .last_position
                    .is_none_or(|t| t.elapsed() >= POSITION_INTERVAL);
                if due {
                    self.last_position = Some(Instant::now());
                    self.send(EngineEvent::Position { seconds });
                }
            }
            (OBS_IDLE, PropertyData::Flag(true)) => {
                if self.started_any {
                    self.current_path = None;
                    self.send(EngineEvent::Idle);
                }
            }
            _ => {
                let _ = name;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_target_name_strips_query_and_fragment_from_urls() {
        let stream = Path::new(
            "https://rr1---sn-4g5e6n7d.googlevideo.com/videoplayback?expire=1764000000&ei=abc&ip=1.2.3.4&sig=xyz#frag",
        );
        assert_eq!(
            display_target_name(stream),
            "https://rr1---sn-4g5e6n7d.googlevideo.com/videoplayback"
        );

        let http_stream = Path::new("http://stream.example.com/live/audio.aac?token=secret");
        assert_eq!(
            display_target_name(http_stream),
            "http://stream.example.com/live/audio.aac"
        );

        let long_path = Path::new(
            "https://cdn.example.com/very/long/signed/path/segment/that/exceeds/eighty/characters/audio.m4a?sig=1",
        );
        assert_eq!(display_target_name(long_path), "https://cdn.example.com");

        assert_eq!(
            display_target_name(Path::new("/home/user/Music/01 - Track.flac")),
            "01 - Track.flac"
        );
        assert_eq!(display_target_name(Path::new("song.mp3")), "song.mp3");
    }

    #[test]
    fn sanitize_mpv_log_and_format_error_hide_url_queries_and_keep_reason() {
        let log_line = "Failed to open https://rr1.googlevideo.com/videoplayback?expire=123&sig=abc: HTTP error 403 Forbidden\n";
        let sanitized = sanitize_mpv_log("ffmpeg", log_line.trim());
        assert!(!sanitized.contains("expire="));
        assert!(!sanitized.contains("sig="));
        assert!(sanitized.contains("HTTP error 403 Forbidden"));

        let err = format_playback_error(
            Some(Path::new(
                "https://rr1.googlevideo.com/videoplayback?expire=123&sig=abc",
            )),
            "the file could not be loaded",
            Some("ffmpeg: https: HTTP error 403 Forbidden"),
        );
        assert_eq!(
            err,
            "Could not play https://rr1.googlevideo.com/videoplayback: the file could not be loaded (ffmpeg: https: HTTP error 403 Forbidden)"
        );
        assert!(!err.contains("expire="));
    }
}

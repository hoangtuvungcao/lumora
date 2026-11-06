//! Input injection back-ends and dispatch.

use std::sync::{Arc, OnceLock};

use parking_lot::RwLock;
use serde::{Deserialize, Serialize};

use crate::{DisplayInfo, InputInjector};

#[cfg(target_os = "linux")]
mod portal;
#[cfg(target_os = "linux")]
mod uinput;
#[cfg(target_os = "linux")]
mod xtest;

#[cfg(windows)]
mod windows;

#[cfg(target_os = "macos")]
mod macos;

#[cfg(target_os = "android")]
pub(crate) mod android;

/// Which injection backend to use.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum InjectorBackend {
    /// Pick the best available backend for this session.
    #[default]
    Auto,
    /// xdg-desktop-portal RemoteDesktop (GNOME, KDE). Linux/Wayland.
    Portal,
    /// /dev/uinput virtual devices. Linux (any session, incl. COSMIC/wlroots).
    Uinput,
    /// XTest extension. Linux/X11.
    Xtest,
    /// Native OS API (Windows SendInput / macOS CGEvent).
    Native,
}

/// Options for [`open_injector_with`].
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct InjectorOptions {
    pub backend: InjectorBackend,
    /// RemoteDesktop portal restore token from a previous run.
    pub restore_token: Option<String>,
}

/// Callback that puts `text` on the system clipboard so the injector can then
/// send Ctrl+V. Used by `text()` for characters the backend cannot type
/// directly (non-ASCII on uinput, e.g. Vietnamese).
pub type ClipboardPasteHook = Arc<dyn Fn(&str) -> anyhow::Result<()> + Send + Sync>;

fn hook_slot() -> &'static RwLock<Option<ClipboardPasteHook>> {
    static H: OnceLock<RwLock<Option<ClipboardPasteHook>>> = OnceLock::new();
    H.get_or_init(|| RwLock::new(None))
}

/// Install (or clear) the clipboard hook used for non-ASCII `text()` on
/// backends that can only press physical keys. Without a hook, Lumora tries
/// `wl-copy` (Wayland) / `xclip` / `xsel` (X11) if they are installed.
pub fn set_clipboard_paste_hook(hook: Option<ClipboardPasteHook>) {
    *hook_slot().write() = hook;
}

#[allow(dead_code)]
pub(crate) fn clipboard_set(text: &str) -> anyhow::Result<()> {
    if let Some(h) = hook_slot().read().clone() {
        return h(text);
    }
    #[cfg(target_os = "linux")]
    {
        use std::io::Write;
        use std::process::{Command, Stdio};
        let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some();
        let candidates: &[(&str, &[&str])] = if wayland {
            &[("wl-copy", &[]), ("xclip", &["-selection", "clipboard"]), ("xsel", &["-ib"])]
        } else {
            &[("xclip", &["-selection", "clipboard"]), ("xsel", &["-ib"]), ("wl-copy", &[])]
        };
        for (bin, args) in candidates {
            let child = Command::new(bin).args(*args).stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
            let Ok(mut child) = child else { continue };
            if let Some(mut stdin) = child.stdin.take() {
                let _ = stdin.write_all(text.as_bytes());
            }
            // wl-copy forks to serve the selection; the parent exits quickly.
            match child.wait() {
                Ok(s) if s.success() => return Ok(()),
                _ => continue,
            }
        }
        anyhow::bail!(
            "cannot type non-ASCII text with this input backend: no clipboard helper available \
             (install `wl-clipboard` or `xclip`, or register a clipboard hook)"
        )
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = text;
        anyhow::bail!("no clipboard hook registered for non-ASCII text")
    }
}

/// Open an input injector for `display` with automatic backend selection.
///
/// Linux/Wayland: RemoteDesktop portal if the desktop provides it (GNOME,
/// KDE), otherwise uinput (COSMIC, wlroots…). Linux/X11: XTest, then uinput.
pub fn open_injector(display: &DisplayInfo) -> anyhow::Result<Box<dyn InputInjector>> {
    open_injector_with(display, InjectorOptions::default()).map(|(i, _)| i)
}

/// Like [`open_injector`] with explicit options; also returns a new portal
/// restore token when the RemoteDesktop portal was used.
pub fn open_injector_with(
    display: &DisplayInfo,
    opts: InjectorOptions,
) -> anyhow::Result<(Box<dyn InputInjector>, Option<String>)> {
    #[cfg(target_os = "linux")]
    {
        let env_backend = match std::env::var("LUMORA_INPUT").unwrap_or_default().as_str() {
            "portal" => Some(InjectorBackend::Portal),
            "uinput" => Some(InjectorBackend::Uinput),
            "xtest" => Some(InjectorBackend::Xtest),
            _ => None,
        };
        let backend = env_backend.unwrap_or(opts.backend);
        let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some()
            || std::env::var("XDG_SESSION_TYPE").map(|s| s == "wayland").unwrap_or(false);
        match backend {
            InjectorBackend::Portal => {
                let (p, tok) = portal::PortalInjector::open(display, opts.restore_token.as_deref())?;
                return Ok((Box::new(p), tok));
            }
            InjectorBackend::Uinput => return Ok((Box::new(uinput::UinputInjector::open(display)?), None)),
            InjectorBackend::Xtest => return Ok((Box::new(xtest::XtestInjector::open(display)?), None)),
            InjectorBackend::Native => anyhow::bail!("the native injector backend is only available on Windows/macOS"),
            InjectorBackend::Auto => {}
        }
        let mut errors: Vec<String> = Vec::new();
        if wayland {
            if crate::diag::portal_interface_version("org.freedesktop.portal.RemoteDesktop").is_some() {
                match portal::PortalInjector::open(display, opts.restore_token.as_deref()) {
                    Ok((p, tok)) => return Ok((Box::new(p), tok)),
                    Err(e) => errors.push(format!("RemoteDesktop portal: {e:#}")),
                }
            } else {
                errors.push("RemoteDesktop portal: not provided by this desktop".into());
            }
            match uinput::UinputInjector::open(display) {
                Ok(u) => return Ok((Box::new(u), None)),
                Err(e) => errors.push(format!("uinput: {e:#}")),
            }
        } else {
            match xtest::XtestInjector::open(display) {
                Ok(x) => return Ok((Box::new(x), None)),
                Err(e) => errors.push(format!("XTest: {e:#}")),
            }
            match uinput::UinputInjector::open(display) {
                Ok(u) => return Ok((Box::new(u), None)),
                Err(e) => errors.push(format!("uinput: {e:#}")),
            }
        }
        anyhow::bail!(
            "no input injection backend is usable: {}. Run Lumora diagnostics for step-by-step fixes",
            errors.join("; ")
        )
    }
    #[cfg(windows)]
    {
        let _ = opts;
        Ok((Box::new(windows::SendInputInjector::open(display)?), None))
    }
    #[cfg(target_os = "macos")]
    {
        let _ = opts;
        Ok((Box::new(macos::CgEventInjector::open(display)?), None))
    }
    #[cfg(target_os = "android")]
    {
        // Events are queued for the app's AccessibilityService (see android.rs).
        let _ = opts;
        Ok((Box::new(android::AndroidInjector::open(display)?), None))
    }
    #[cfg(target_os = "ios")]
    {
        // iOS has no API that lets an app press keys or touch the screen for
        // the user (no AccessibilityService equivalent, no CGEvent/IOHID
        // injection outside the app's own views). An iPhone/iPad can share
        // its screen (ReplayKit) and control other computers, but cannot be
        // controlled.
        let _ = (display, opts);
        anyhow::bail!(
            "remote control is not supported on this device: iOS does not allow apps to control \
             the screen. This iPhone/iPad can share its screen and control other computers, \
             but it cannot be controlled"
        )
    }
    #[cfg(not(any(target_os = "linux", windows, target_os = "macos", target_os = "android", target_os = "ios")))]
    {
        let _ = (display, opts);
        anyhow::bail!(
            "input injection is not available on this platform from Rust \
             (Android requires an AccessibilityService on the app side)"
        )
    }
}

// ------------------------------------------------------------------ injector thread

/// One input event for [`InjectorWorker`].
#[derive(Debug, Clone, PartialEq)]
pub enum InputEvent {
    Move { x: f64, y: f64 },
    Button { button: crate::MouseButton, down: bool },
    Wheel { dx: i32, dy: i32 },
    Key { code: String, down: bool },
    Text(String),
}

impl InputEvent {
    fn apply(&self, inj: &mut dyn InputInjector) -> anyhow::Result<()> {
        match self {
            InputEvent::Move { x, y } => inj.mouse_move_abs(*x, *y),
            InputEvent::Button { button, down } => inj.button(*button, *down),
            InputEvent::Wheel { dx, dy } => inj.wheel(*dx, *dy),
            InputEvent::Key { code, down } => inj.key(code, *down),
            InputEvent::Text(s) => inj.text(s),
        }
    }
}

/// What happened to the injector of an [`InjectorWorker`].
#[derive(Debug, Clone, PartialEq)]
pub enum InjectorStatus {
    /// Opened: events are injected.
    Ready { backend: &'static str },
    /// Opening failed (no permission, dialog cancelled…): events are dropped and
    /// the next attempt waits `retry_in` — never one attempt (or one permission
    /// dialog) per event.
    Unavailable { error: String, retry_in: std::time::Duration },
}

type OpenFn = Box<dyn FnMut() -> anyhow::Result<Box<dyn InputInjector>> + Send>;

/// Injects input on a dedicated thread, so nothing that blocks (a portal
/// permission dialog waits up to a minute, uinput/XTest sleep between key
/// events, clipboard helpers run as processes) ever runs on the caller's
/// (async runtime) thread. Events go through a bounded queue — a full queue
/// drops the event — and consecutive pointer moves are coalesced. The injector
/// is opened on the first event; after a failure the next attempt backs off
/// (30 s, ×4, at most 10 min). Dropping the worker ends the thread and closes
/// the injector.
pub struct InjectorWorker {
    tx: std::sync::mpsc::SyncSender<(std::time::Instant, InputEvent)>,
}

impl InjectorWorker {
    pub const QUEUE: usize = 256;
    pub const FIRST_BACKOFF: std::time::Duration = std::time::Duration::from_secs(30);
    pub const MAX_BACKOFF: std::time::Duration = std::time::Duration::from_secs(600);
    /// Events that waited longer than this (e.g. behind a permission dialog) are dropped.
    pub const STALE: std::time::Duration = std::time::Duration::from_secs(2);

    /// Worker that opens the injector for `display` (see [`open_injector`]).
    pub fn for_display(display: DisplayInfo, on_status: impl Fn(InjectorStatus) + Send + 'static) -> anyhow::Result<Self> {
        Self::spawn(Box::new(move || open_injector(&display)), on_status)
    }

    /// Worker with a custom `open` (tests, other backends).
    pub fn spawn(mut open: OpenFn, on_status: impl Fn(InjectorStatus) + Send + 'static) -> anyhow::Result<Self> {
        use std::sync::mpsc::TryRecvError;
        use std::time::Instant;
        let (tx, rx) = std::sync::mpsc::sync_channel::<(Instant, InputEvent)>(Self::QUEUE);
        std::thread::Builder::new().name("lumora-input".into()).spawn(move || {
            let mut inj: Option<Box<dyn InputInjector>> = None;
            let mut next_try: Option<Instant> = None;
            let mut backoff = Self::FIRST_BACKOFF;
            let mut batch: Vec<(Instant, InputEvent)> = Vec::new();
            while let Ok(first) = rx.recv() {
                batch.clear();
                batch.push(first);
                loop {
                    match rx.try_recv() {
                        Ok(ev) => batch.push(ev),
                        Err(TryRecvError::Empty) => break,
                        Err(TryRecvError::Disconnected) => return,
                    }
                    if batch.len() >= Self::QUEUE {
                        break;
                    }
                }
                if inj.is_none() {
                    if next_try.is_some_and(|t| Instant::now() < t) {
                        continue; // backing off: drop
                    }
                    match open() {
                        Ok(i) => {
                            on_status(InjectorStatus::Ready { backend: i.backend() });
                            inj = Some(i);
                            backoff = Self::FIRST_BACKOFF;
                            next_try = None;
                        }
                        Err(e) => {
                            on_status(InjectorStatus::Unavailable { error: format!("{e:#}"), retry_in: backoff });
                            next_try = Some(Instant::now() + backoff);
                            backoff = (backoff * 4).min(Self::MAX_BACKOFF);
                            continue;
                        }
                    }
                }
                let Some(i) = inj.as_mut() else { continue };
                let now = Instant::now();
                for (k, (at, ev)) in batch.iter().enumerate() {
                    if now.duration_since(*at) > Self::STALE {
                        continue;
                    }
                    // only the last of consecutive pointer moves matters
                    if matches!(ev, InputEvent::Move { .. }) && matches!(batch.get(k + 1), Some((_, InputEvent::Move { .. }))) {
                        continue;
                    }
                    if let Err(e) = ev.apply(i.as_mut()) {
                        tracing::debug!("input injection: {e:#}");
                    }
                }
            }
        })?;
        Ok(Self { tx })
    }

    /// Queue one event; `false` if it was dropped (queue full / worker gone).
    pub fn send(&self, ev: InputEvent) -> bool {
        self.tx.try_send((std::time::Instant::now(), ev)).is_ok()
    }
}

/// Map a display-relative normalised position to global desktop coordinates.
#[allow(dead_code)]
pub(crate) fn to_global(display: &DisplayInfo, x: f64, y: f64) -> (f64, f64) {
    let x = if x.is_finite() { x.clamp(0.0, 1.0) } else { 0.0 };
    let y = if y.is_finite() { y.clamp(0.0, 1.0) } else { 0.0 };
    let w = display.width.max(1) as f64;
    let h = display.height.max(1) as f64;
    (display.x as f64 + x * (w - 1.0).max(0.0), display.y as f64 + y * (h - 1.0).max(0.0))
}

/// Bounding box (x, y, w, h) of the whole desktop including `display`.
#[allow(dead_code)]
pub(crate) fn desktop_bounds(display: &DisplayInfo, all: &[DisplayInfo]) -> (i32, i32, u32, u32) {
    let mut x0 = display.x;
    let mut y0 = display.y;
    let mut x1 = display.x + display.width as i32;
    let mut y1 = display.y + display.height as i32;
    for d in all {
        x0 = x0.min(d.x);
        y0 = y0.min(d.y);
        x1 = x1.max(d.x + d.width as i32);
        y1 = y1.max(d.y + d.height as i32);
    }
    (x0, y0, (x1 - x0).max(1) as u32, (y1 - y0).max(1) as u32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    struct Fake(Arc<Mutex<Vec<String>>>, Duration);

    impl InputInjector for Fake {
        fn mouse_move_abs(&mut self, x: f64, y: f64) -> anyhow::Result<()> {
            std::thread::sleep(self.1);
            self.0.lock().unwrap().push(format!("move {x} {y}"));
            Ok(())
        }
        fn button(&mut self, b: crate::MouseButton, down: bool) -> anyhow::Result<()> {
            self.0.lock().unwrap().push(format!("button {b:?} {down}"));
            Ok(())
        }
        fn wheel(&mut self, _: i32, _: i32) -> anyhow::Result<()> {
            Ok(())
        }
        fn key(&mut self, code: &str, down: bool) -> anyhow::Result<()> {
            std::thread::sleep(self.1);
            self.0.lock().unwrap().push(format!("key {code} {down}"));
            Ok(())
        }
        fn text(&mut self, s: &str) -> anyhow::Result<()> {
            self.0.lock().unwrap().push(format!("text {s}"));
            Ok(())
        }
    }

    /// Review finding: injection blocked async workers and a failed open was retried
    /// (a new permission dialog) on every event. Now: `send` never blocks, events are
    /// injected in order on the worker thread, a failed open is reported once and
    /// not retried before the backoff.
    #[test]
    fn injector_worker_never_blocks_and_backs_off() {
        let log = Arc::new(Mutex::new(Vec::new()));
        let statuses = Arc::new(Mutex::new(Vec::new()));
        let opens = Arc::new(std::sync::atomic::AtomicU32::new(0));
        let (l, o, st) = (log.clone(), opens.clone(), statuses.clone());
        let w = InjectorWorker::spawn(
            Box::new(move || {
                o.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                std::thread::sleep(Duration::from_millis(200)); // a slow permission prompt
                Ok(Box::new(Fake(l.clone(), Duration::from_millis(5))) as Box<dyn InputInjector>)
            }),
            move |s| st.lock().unwrap().push(s),
        )
        .unwrap();
        let t = Instant::now();
        for i in 0..100 {
            w.send(InputEvent::Move { x: i as f64 / 100.0, y: 0.5 });
        }
        w.send(InputEvent::Key { code: "KeyA".into(), down: true });
        w.send(InputEvent::Key { code: "KeyA".into(), down: false });
        assert!(t.elapsed() < Duration::from_millis(50), "send must not block: {:?}", t.elapsed());
        let until = Instant::now() + Duration::from_secs(5);
        while log.lock().unwrap().len() < 3 && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(10));
        }
        let got = log.lock().unwrap().clone();
        assert!(got.len() < 20, "moves are coalesced: {got:?}");
        assert_eq!(&got[got.len() - 2..], &["key KeyA true".to_string(), "key KeyA false".to_string()]);
        assert!(got.iter().any(|e| e == "move 0.99 0.5"), "the last move survives: {got:?}");
        assert_eq!(opens.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert!(matches!(statuses.lock().unwrap()[..], [InjectorStatus::Ready { .. }]));

        // failing open: one attempt + one status for a burst of events, no retry storm
        let fails = Arc::new(std::sync::atomic::AtomicU32::new(0));
        let st2 = Arc::new(Mutex::new(Vec::new()));
        let (f, s2) = (fails.clone(), st2.clone());
        let w = InjectorWorker::spawn(
            Box::new(move || {
                f.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                anyhow::bail!("permission denied")
            }),
            move |s| s2.lock().unwrap().push(s),
        )
        .unwrap();
        for i in 0..50 {
            w.send(InputEvent::Move { x: 0.1, y: 0.1 });
            if i % 10 == 0 {
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(fails.load(std::sync::atomic::Ordering::SeqCst), 1, "no reopen per event");
        let s = st2.lock().unwrap().clone();
        assert!(matches!(&s[..], [InjectorStatus::Unavailable { retry_in, .. }] if *retry_in == InjectorWorker::FIRST_BACKOFF), "{s:?}");
    }

    #[test]
    fn global_mapping() {
        let d = DisplayInfo { width: 1920, height: 1080, x: 1920, y: 0, ..Default::default() };
        assert_eq!(to_global(&d, 0.0, 0.0), (1920.0, 0.0));
        assert_eq!(to_global(&d, 1.0, 1.0), (3839.0, 1079.0));
        assert_eq!(to_global(&d, f64::NAN, 2.0), (1920.0, 1079.0));
        let other = DisplayInfo { width: 1920, height: 1200, x: 0, y: 0, ..Default::default() };
        assert_eq!(desktop_bounds(&d, &[other]), (0, 0, 3840, 1200));
    }
}

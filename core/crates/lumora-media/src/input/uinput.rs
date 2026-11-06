//! Input injection through `/dev/uinput` virtual devices.
//!
//! Works under every Linux compositor (COSMIC, wlroots, GNOME, KDE, X11)
//! because the kernel device is picked up by libinput like real hardware. It
//! needs write access to `/dev/uinput` (see `diag` for the udev rule).
//!
//! Two devices are created:
//! * an absolute pointer (`ABS_X`/`ABS_Y` 0..65535, `INPUT_PROP_POINTER`,
//!   mouse buttons, wheels) — libinput treats it like a VM "tablet" mouse;
//! * a keyboard with every key in [`crate::keymap`].
//!
//! The absolute range spans the bounding box of all monitors (that is how
//! most compositors map absolute pointer devices); set
//! `LUMORA_UINPUT_ABS_SPACE=output` to map the range onto the target display only.

use std::collections::HashSet;
use std::time::Duration;

use anyhow::anyhow;
use evdev::uinput::VirtualDevice;
use evdev::{
    AbsInfo, AbsoluteAxisCode, AttributeSet, BusType, EventType, InputEvent, InputId, KeyCode, PropType,
    RelativeAxisCode, UinputAbsSetup,
};

use super::{desktop_bounds, to_global};
use crate::{keymap, DisplayInfo, InputInjector, MouseButton};

const ABS_MAX: i32 = 65535;
const KEY_LEFTSHIFT: u16 = 42;
const KEY_LEFTCTRL: u16 = 29;
const KEY_V: u16 = 47;

pub struct UinputInjector {
    pointer: VirtualDevice,
    keyboard: VirtualDevice,
    display: DisplayInfo,
    bounds: (i32, i32, u32, u32),
    pressed_keys: HashSet<u16>,
    pressed_buttons: HashSet<u16>,
}

fn explain_open_error(e: std::io::Error) -> anyhow::Error {
    use std::io::ErrorKind;
    match e.kind() {
        ErrorKind::PermissionDenied => anyhow!(
            "permission denied opening /dev/uinput: the current user cannot create virtual input devices. \
             Add a udev rule (KERNEL==\"uinput\", GROUP=\"input\", MODE=\"0660\"), add the user to the \
             'input' group and log in again — run Lumora diagnostics for the exact commands"
        ),
        ErrorKind::NotFound => anyhow!(
            "/dev/uinput does not exist: load the kernel module with `sudo modprobe uinput` \
             (and add `uinput` to /etc/modules-load.d/uinput.conf to make it permanent)"
        ),
        _ => anyhow!("cannot create uinput virtual device: {e}"),
    }
}

impl UinputInjector {
    pub fn open(display: &DisplayInfo) -> anyhow::Result<Self> {
        let id = InputId::new(BusType::BUS_VIRTUAL, 0x4C55, 0x4D41, 1); // "LU" "MA"

        let mut buttons = AttributeSet::<KeyCode>::new();
        for b in [KeyCode::BTN_LEFT, KeyCode::BTN_RIGHT, KeyCode::BTN_MIDDLE, KeyCode::BTN_SIDE, KeyCode::BTN_EXTRA] {
            buttons.insert(b);
        }
        let mut rel = AttributeSet::<RelativeAxisCode>::new();
        for r in [
            RelativeAxisCode::REL_WHEEL,
            RelativeAxisCode::REL_HWHEEL,
            RelativeAxisCode::REL_WHEEL_HI_RES,
            RelativeAxisCode::REL_HWHEEL_HI_RES,
        ] {
            rel.insert(r);
        }
        let mut props = AttributeSet::<PropType>::new();
        props.insert(PropType::POINTER);
        let abs = AbsInfo::new(0, 0, ABS_MAX, 0, 0, 0);
        let pointer = VirtualDevice::builder()
            .map_err(explain_open_error)?
            .name("Lumora virtual pointer")
            .input_id(id)
            .with_properties(&props)
            .map_err(explain_open_error)?
            .with_keys(&buttons)
            .map_err(explain_open_error)?
            .with_relative_axes(&rel)
            .map_err(explain_open_error)?
            .with_absolute_axis(&UinputAbsSetup::new(AbsoluteAxisCode::ABS_X, abs))
            .map_err(explain_open_error)?
            .with_absolute_axis(&UinputAbsSetup::new(AbsoluteAxisCode::ABS_Y, abs))
            .map_err(explain_open_error)?
            .build()
            .map_err(explain_open_error)?;

        let mut keys = AttributeSet::<KeyCode>::new();
        for c in keymap::all_evdev_codes() {
            keys.insert(KeyCode::new(c));
        }
        let keyboard = VirtualDevice::builder()
            .map_err(explain_open_error)?
            .name("Lumora virtual keyboard")
            .input_id(InputId::new(BusType::BUS_VIRTUAL, 0x4C55, 0x4D42, 1))
            .with_keys(&keys)
            .map_err(explain_open_error)?
            .build()
            .map_err(explain_open_error)?;

        // Give udev/libinput time to announce the new devices to the
        // compositor; events written before that are silently lost.
        std::thread::sleep(Duration::from_millis(300));

        let all = if std::env::var("LUMORA_UINPUT_ABS_SPACE").as_deref() == Ok("output") {
            Vec::new()
        } else {
            crate::list_displays()
        };
        let bounds = desktop_bounds(display, &all);
        Ok(Self {
            pointer,
            keyboard,
            display: display.clone(),
            bounds,
            pressed_keys: HashSet::new(),
            pressed_buttons: HashSet::new(),
        })
    }

    fn emit_key(&mut self, code: u16, down: bool) -> anyhow::Result<()> {
        self.keyboard
            .emit(&[InputEvent::new(EventType::KEY.0, code, down as i32)])
            .map_err(|e| anyhow!("uinput key write failed: {e}"))?;
        if down {
            self.pressed_keys.insert(code);
        } else {
            self.pressed_keys.remove(&code);
        }
        Ok(())
    }

    fn tap(&mut self, code: u16, shift: bool) -> anyhow::Result<()> {
        if shift {
            self.emit_key(KEY_LEFTSHIFT, true)?;
        }
        self.emit_key(code, true)?;
        self.emit_key(code, false)?;
        if shift {
            self.emit_key(KEY_LEFTSHIFT, false)?;
        }
        Ok(())
    }

    /// Put `s` on the clipboard (through `clip`) and press Ctrl+V.
    fn paste(&mut self, clip: &mut Option<clip::Session>, s: &str) -> anyhow::Result<()> {
        let session = match clip {
            Some(c) => c,
            None => clip.insert(clip::Session::begin()?),
        };
        session.set(s)?;
        std::thread::sleep(Duration::from_millis(40));
        self.emit_key(KEY_LEFTCTRL, true)?;
        self.tap(KEY_V, false)?;
        self.emit_key(KEY_LEFTCTRL, false)?;
        // let the focused app fetch this run before the clipboard changes again
        std::thread::sleep(Duration::from_millis(50));
        Ok(())
    }

    fn type_text(&mut self, clip: &mut Option<clip::Session>, s: &str) -> anyhow::Result<()> {
        // Type ASCII with key combos (assumes a US-compatible layout on this
        // machine); paste runs of other characters via the clipboard.
        let mut pending = String::new();
        for c in s.chars() {
            match keymap::ascii_to_code(c) {
                Some((code, shift)) => {
                    if !pending.is_empty() {
                        let run = std::mem::take(&mut pending);
                        self.paste(clip, &run)?;
                    }
                    let ev = keymap::lookup(code).map(|e| e.evdev).ok_or_else(|| anyhow!("unmapped key {code}"))?;
                    self.tap(ev, shift)?;
                }
                None => pending.push(c),
            }
        }
        if !pending.is_empty() {
            self.paste(clip, &pending)?;
        }
        Ok(())
    }
}

impl Drop for UinputInjector {
    fn drop(&mut self) {
        // Never leave keys or buttons stuck down.
        let keys: Vec<u16> = self.pressed_keys.drain().collect();
        for k in keys {
            let _ = self.keyboard.emit(&[InputEvent::new(EventType::KEY.0, k, 0)]);
        }
        let btns: Vec<u16> = self.pressed_buttons.drain().collect();
        for b in btns {
            let _ = self.pointer.emit(&[InputEvent::new(EventType::KEY.0, b, 0)]);
        }
    }
}

impl InputInjector for UinputInjector {
    fn mouse_move_abs(&mut self, x: f64, y: f64) -> anyhow::Result<()> {
        let (gx, gy) = to_global(&self.display, x, y);
        let (bx, by, bw, bh) = self.bounds;
        let ax = (((gx - bx as f64) / (bw.max(2) - 1) as f64) * ABS_MAX as f64).round().clamp(0.0, ABS_MAX as f64) as i32;
        let ay = (((gy - by as f64) / (bh.max(2) - 1) as f64) * ABS_MAX as f64).round().clamp(0.0, ABS_MAX as f64) as i32;
        self.pointer
            .emit(&[
                InputEvent::new(EventType::ABSOLUTE.0, AbsoluteAxisCode::ABS_X.0, ax),
                InputEvent::new(EventType::ABSOLUTE.0, AbsoluteAxisCode::ABS_Y.0, ay),
            ])
            .map_err(|e| anyhow!("uinput pointer write failed: {e}"))
    }

    fn button(&mut self, b: MouseButton, down: bool) -> anyhow::Result<()> {
        let code = match b {
            MouseButton::Left => KeyCode::BTN_LEFT,
            MouseButton::Right => KeyCode::BTN_RIGHT,
            MouseButton::Middle => KeyCode::BTN_MIDDLE,
            MouseButton::Back => KeyCode::BTN_SIDE,
            MouseButton::Forward => KeyCode::BTN_EXTRA,
        }
        .0;
        self.pointer
            .emit(&[InputEvent::new(EventType::KEY.0, code, down as i32)])
            .map_err(|e| anyhow!("uinput button write failed: {e}"))?;
        if down {
            self.pressed_buttons.insert(code);
        } else {
            self.pressed_buttons.remove(&code);
        }
        Ok(())
    }

    fn wheel(&mut self, dx: i32, dy: i32) -> anyhow::Result<()> {
        let dx = dx.clamp(-100, 100);
        let dy = dy.clamp(-100, 100);
        let mut ev = Vec::with_capacity(4);
        if dy != 0 {
            // evdev: positive REL_WHEEL scrolls up; our API: positive dy scrolls down.
            ev.push(InputEvent::new(EventType::RELATIVE.0, RelativeAxisCode::REL_WHEEL.0, -dy));
            ev.push(InputEvent::new(EventType::RELATIVE.0, RelativeAxisCode::REL_WHEEL_HI_RES.0, -dy * 120));
        }
        if dx != 0 {
            ev.push(InputEvent::new(EventType::RELATIVE.0, RelativeAxisCode::REL_HWHEEL.0, dx));
            ev.push(InputEvent::new(EventType::RELATIVE.0, RelativeAxisCode::REL_HWHEEL_HI_RES.0, dx * 120));
        }
        if ev.is_empty() {
            return Ok(());
        }
        self.pointer.emit(&ev).map_err(|e| anyhow!("uinput wheel write failed: {e}"))
    }

    fn key(&mut self, code: &str, down: bool) -> anyhow::Result<()> {
        let e = keymap::lookup(code).ok_or_else(|| anyhow!("unknown key code {code:?}"))?;
        if e.evdev == keymap::NONE {
            anyhow::bail!("key {code:?} has no Linux equivalent");
        }
        self.emit_key(e.evdev, down)
    }

    fn text(&mut self, s: &str) -> anyhow::Result<()> {
        // Characters without a key are pasted; the user's clipboard is saved before
        // the first paste and put back afterwards, so the remote viewer's text
        // doesn't stay on this machine's clipboard.
        let mut clip = None;
        let r = self.type_text(&mut clip, s);
        if let Some(c) = clip {
            c.restore();
        }
        r
    }

    fn backend(&self) -> &'static str {
        "uinput"
    }
}

/// Clipboard round trip for pasting text that has no key: save what the user had,
/// set ours, then put theirs back (or clear ours). External helpers (`wl-copy` /
/// `wl-paste`, `xclip`, `xsel`) always run with a deadline, so a hung helper (e.g.
/// `xclip -o` waiting on an unresponsive selection owner) can't stall input.
mod clip {
    use std::io::{Read, Seek, Write};
    use std::os::fd::{FromRawFd, OwnedFd};
    use std::process::{Command, Stdio};
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    /// Deadline for reading the clipboard (one helper call).
    const READ_TIMEOUT: Duration = Duration::from_millis(250);
    /// Deadline for setting it (the helper waits for the compositor / X server to
    /// confirm the selection, which can take longer on a loaded machine).
    const WRITE_TIMEOUT: Duration = Duration::from_millis(400);
    /// Wait after the last Ctrl+V before restoring, so the app pastes our text
    /// (it fetches the selection asynchronously). The paste itself already waited 50 ms.
    const RESTORE_DELAY: Duration = Duration::from_millis(100);
    /// Larger clipboard contents are not saved (they are cleared instead).
    const MAX_SAVE: usize = 16 << 20;

    #[derive(Clone, Copy, Debug, PartialEq)]
    enum Tool {
        /// `set_clipboard_paste_hook`: the app owns the clipboard round trip.
        Hook,
        Wayland,
        Xclip,
        Xsel,
    }

    /// What was on the clipboard before we pasted.
    enum Saved {
        /// Nothing (or nothing we can read back): clear our text afterwards.
        Nothing,
        Data { mime: Option<String>, bytes: Vec<u8> },
    }

    pub(super) struct Session {
        tool: Tool,
        saved: Saved,
    }

    impl Session {
        /// Pick a clipboard helper and save the current contents.
        pub(super) fn begin() -> anyhow::Result<Self> {
            if super::super::hook_slot().read().is_some() {
                return Ok(Self { tool: Tool::Hook, saved: Saved::Nothing });
            }
            let order: &[Tool] = if std::env::var_os("WAYLAND_DISPLAY").is_some() {
                &[Tool::Wayland, Tool::Xclip, Tool::Xsel]
            } else {
                &[Tool::Xclip, Tool::Xsel, Tool::Wayland]
            };
            for &tool in order {
                // a helper that can't even be started is not installed: try the next one
                if let Ok(saved) = save(tool) {
                    return Ok(Self { tool, saved });
                }
            }
            anyhow::bail!(
                "cannot type non-ASCII text with this input backend: no clipboard helper available \
                 (install `wl-clipboard` or `xclip`, or register a clipboard hook)"
            )
        }

        pub(super) fn set(&self, text: &str) -> anyhow::Result<()> {
            if self.tool == Tool::Hook {
                return super::super::clipboard_set(text);
            }
            match set(self.tool, None, text.as_bytes()) {
                Ok(true) => Ok(()),
                _ => anyhow::bail!("could not put the text on the clipboard ({:?} helper failed)", self.tool),
            }
        }

        /// Put the user's clipboard back (best effort, bounded by the helper deadline).
        pub(super) fn restore(self) {
            if self.tool == Tool::Hook {
                return;
            }
            std::thread::sleep(RESTORE_DELAY);
            let ok = match &self.saved {
                Saved::Data { mime, bytes } => set(self.tool, mime.as_deref(), bytes),
                Saved::Nothing => clear(self.tool),
            };
            if !matches!(ok, Ok(true)) {
                tracing::debug!("could not restore the clipboard after pasting ({:?})", self.tool);
            }
        }
    }

    /// Err: the helper could not be started (not installed).
    fn save(tool: Tool) -> std::io::Result<Saved> {
        let (list_types, get): (&[&str], &[&str]) = match tool {
            Tool::Hook => return Ok(Saved::Nothing),
            Tool::Wayland => (&["wl-paste", "--list-types"], &["wl-paste", "--no-newline", "--type"]),
            Tool::Xclip => (&["xclip", "-selection", "clipboard", "-o", "-t", "TARGETS"], &["xclip", "-selection", "clipboard", "-o", "-t"]),
            Tool::Xsel => {
                // text only
                return Ok(match run(&["xsel", "-ob"], None, true, READ_TIMEOUT)? {
                    Some((true, bytes)) if !bytes.is_empty() && bytes.len() <= MAX_SAVE => Saved::Data { mime: None, bytes },
                    _ => Saved::Nothing,
                });
            }
        };
        let Some((true, list)) = run(list_types, None, true, READ_TIMEOUT)? else { return Ok(Saved::Nothing) };
        let list = String::from_utf8_lossy(&list);
        let Some(mime) = pick_type(list.lines()) else { return Ok(Saved::Nothing) };
        Ok(match run(&[get, &[mime]].concat(), None, true, READ_TIMEOUT)? {
            Some((true, bytes)) if bytes.len() <= MAX_SAVE => Saved::Data { mime: Some(mime.to_string()), bytes },
            _ => Saved::Nothing,
        })
    }

    /// The type to save: text first, else the first real MIME type (an image…).
    fn pick_type<'a>(types: impl Iterator<Item = &'a str>) -> Option<&'a str> {
        let types: Vec<&str> = types.map(str::trim).filter(|t| !t.is_empty()).collect();
        for want in ["text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING"] {
            if let Some(t) = types.iter().find(|t| t.eq_ignore_ascii_case(want)) {
                return Some(t);
            }
        }
        types.into_iter().find(|t| t.contains('/'))
    }

    fn set(tool: Tool, mime: Option<&str>, bytes: &[u8]) -> std::io::Result<bool> {
        let mut args: Vec<&str> = match tool {
            Tool::Hook => return Ok(false),
            Tool::Wayland => vec!["wl-copy"],
            Tool::Xclip => vec!["xclip", "-selection", "clipboard"],
            Tool::Xsel => vec!["xsel", "-ib"],
        };
        if let (Some(m), Tool::Wayland | Tool::Xclip) = (mime, tool) {
            args.extend(["-t", m]);
        }
        // the helpers fork a process that serves the selection; the one we started exits
        Ok(matches!(run(&args, Some(bytes), false, WRITE_TIMEOUT)?, Some((true, _))))
    }

    fn clear(tool: Tool) -> std::io::Result<bool> {
        let r = match tool {
            Tool::Hook => return Ok(false),
            Tool::Wayland => run(&["wl-copy", "--clear"], None, false, WRITE_TIMEOUT)?,
            Tool::Xsel => run(&["xsel", "-cb"], None, false, WRITE_TIMEOUT)?,
            Tool::Xclip => return set(tool, None, b""),
        };
        Ok(matches!(r, Some((true, _))))
    }

    /// stdin for a helper: an in-memory file (no pipe, so a helper that exits
    /// without reading can't block us or raise SIGPIPE).
    fn memfile(bytes: &[u8]) -> std::io::Result<std::fs::File> {
        // SAFETY: plain syscall with a NUL-terminated name; the fd is checked and then owned.
        let fd = unsafe { libc::memfd_create(c"lumora-clip".as_ptr(), libc::MFD_CLOEXEC) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        let mut f = std::fs::File::from(unsafe { OwnedFd::from_raw_fd(fd) });
        f.write_all(bytes)?;
        f.rewind()?;
        Ok(f)
    }

    /// Run `argv` with `input` on stdin, killing it after `timeout`.
    /// Err: not started. Ok(None): timed out. Ok(Some((success, stdout))).
    pub(super) fn run(argv: &[&str], input: Option<&[u8]>, capture: bool, timeout: Duration) -> std::io::Result<Option<(bool, Vec<u8>)>> {
        let stdin = match input {
            Some(b) => Stdio::from(memfile(b)?),
            None => Stdio::null(),
        };
        let mut child = Command::new(argv[0])
            .args(&argv[1..])
            .stdin(stdin)
            .stdout(if capture { Stdio::piped() } else { Stdio::null() })
            .stderr(Stdio::null())
            .spawn()?;
        // read stdout on the side so a large clipboard can't fill the pipe and stall the helper
        let out = child.stdout.take().map(|mut o| {
            let (tx, rx) = mpsc::channel();
            std::thread::spawn(move || {
                let mut buf = Vec::new();
                let _ = (&mut o).take(MAX_SAVE as u64 + 1).read_to_end(&mut buf);
                let _ = tx.send(buf);
            });
            rx
        });
        let deadline = Instant::now() + timeout;
        let status = loop {
            match child.try_wait() {
                Ok(Some(s)) => break Some(s),
                Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(2)),
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    break None;
                }
            }
        };
        let Some(status) = status else { return Ok(None) };
        let bytes = match out {
            Some(rx) => match rx.recv_timeout(deadline.saturating_duration_since(Instant::now()).max(Duration::from_millis(20))) {
                Ok(b) => b,
                // a grandchild still holds stdout: treat as a failure
                Err(_) => return Ok(Some((false, Vec::new()))),
            },
            None => Vec::new(),
        };
        Ok(Some((status.success(), bytes)))
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn picks_text_then_mime_types() {
            assert_eq!(pick_type(["TARGETS", "TIMESTAMP", "UTF8_STRING", "STRING"].into_iter()), Some("UTF8_STRING"));
            assert_eq!(pick_type(["image/png", "text/plain;charset=utf-8", "text/plain"].into_iter()), Some("text/plain;charset=utf-8"));
            assert_eq!(pick_type(["TARGETS", "TIMESTAMP", "image/png"].into_iter()), Some("image/png"));
            assert_eq!(pick_type(["TARGETS", "MULTIPLE", ""].into_iter()), None);
        }

        #[test]
        fn helpers_run_with_input_and_a_deadline() {
            let r = run(&["cat"], Some("xin chào".as_bytes()), true, Duration::from_secs(5)).unwrap();
            assert_eq!(r, Some((true, "xin chào".as_bytes().to_vec())));
            assert_eq!(run(&["false"], None, false, Duration::from_secs(5)).unwrap(), Some((false, Vec::new())));
            // a hung helper is killed at the deadline
            let t = Instant::now();
            assert_eq!(run(&["sleep", "5"], None, true, Duration::from_millis(100)).unwrap(), None);
            assert!(t.elapsed() < Duration::from_secs(1), "{:?}", t.elapsed());
            assert!(run(&["lumora-no-such-helper"], None, false, WRITE_TIMEOUT).is_err());
        }

        /// Touches the real clipboard (and puts it back): needs a Wayland session with
        /// wl-clipboard. `cargo test -p lumora-media clipboard_round_trip -- --ignored`
        #[test]
        #[ignore]
        fn clipboard_round_trip_restores_the_users_text() {
            let text = || run(&["wl-paste", "--no-newline", "--type", "text/plain;charset=utf-8"], None, true, Duration::from_secs(2)).unwrap().unwrap().1;
            let before = text();
            let t = Instant::now();
            let s = Session::begin().unwrap();
            assert_eq!(s.tool, Tool::Wayland);
            s.set("lumora clipboard test ✓").unwrap();
            assert_eq!(text(), "lumora clipboard test ✓".as_bytes());
            s.restore();
            let took = t.elapsed();
            assert_eq!(text(), before);
            eprintln!("save + set + restore took {took:?}");
            assert!(took < Duration::from_millis(300), "{took:?}");
        }
    }
}

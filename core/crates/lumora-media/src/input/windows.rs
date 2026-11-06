//! Windows input injection with `SendInput`.
//!
//! W3C `code` names a *physical* key, so each key is resolved through its set-1
//! scan code: the scan code is translated with the keyboard layout of the
//! foreground window (`MapVirtualKeyExW(MAPVK_VSC_TO_VK_EX)`) and sent as
//! virtual key + scan code (+ `KEYEVENTF_EXTENDEDKEY` for E0 keys). Physical
//! `KeyQ` therefore types `a` on an AZERTY host, exactly like a local keyboard,
//! while apps that look at either the VK or the scan code see consistent values.
//! (Pure `KEYEVENTF_SCANCODE` injection would do the same on Windows, but Wine
//! ignores it.) Keys without a stable scan code (media keys, Pause, NumLock,
//! IME keys) use the virtual-key code from [`keymap`]. `text()` uses `KEYEVENTF_UNICODE` (VK_PACKET), which types
//! any UTF-16 character (Vietnamese, emoji) regardless of the keyboard layout
//! or IME; line breaks and tabs are sent as real Enter/Tab presses because
//! many apps ignore a VK_PACKET carriage return.
//!
//! Limitations: input cannot reach windows of elevated processes unless
//! Lumora itself runs elevated (UIPI), and nothing can be injected while the
//! secure desktop (UAC prompt, Ctrl+Alt+Del, lock screen) is active.

use anyhow::anyhow;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetKeyboardLayout, MapVirtualKeyExW, MapVirtualKeyW, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYBD_EVENT_FLAGS,
    KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE, KEYEVENTF_UNICODE, MAPVK_VK_TO_VSC, MAPVK_VSC_TO_VK_EX, MOUSEEVENTF_ABSOLUTE,
    MOUSEEVENTF_HWHEEL, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP,
    MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_VIRTUALDESK, MOUSEEVENTF_WHEEL,
    MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, MOUSEINPUT, MOUSE_EVENT_FLAGS, VIRTUAL_KEY,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetForegroundWindow, GetSystemMetrics, GetWindowThreadProcessId, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};

use super::to_global;
use crate::{keymap, DisplayInfo, InputInjector, MouseButton};

pub struct SendInputInjector {
    display: DisplayInfo,
}

impl SendInputInjector {
    pub fn open(display: &DisplayInfo) -> anyhow::Result<Self> {
        // Physical-pixel coordinates everywhere (matches DXGI/GDI capture).
        crate::capture::windows::ensure_dpi_awareness();
        Ok(Self { display: display.clone() })
    }
}

fn send(inputs: &[INPUT]) -> anyhow::Result<()> {
    // SAFETY: inputs is a valid slice of INPUT structs.
    let n = unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) };
    if n as usize != inputs.len() {
        return Err(anyhow!(
            "SendInput injected {n}/{} events (blocked by UIPI: the target window may run as administrator, \
             or the secure desktop is active)",
            inputs.len()
        ));
    }
    Ok(())
}

fn mouse(dx: i32, dy: i32, data: i32, flags: MOUSE_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT { dx, dy, mouseData: data as u32, dwFlags: flags, time: 0, dwExtraInfo: 0 },
        },
    }
}

fn key_input(vk: u16, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: VIRTUAL_KEY(vk), wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 } },
    }
}

/// Map a global pixel coordinate to the 0..=65535 range of
/// `MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK`. Windows converts back with
/// `pixel = n * size / 65536` (truncating), so aim at the centre of the target
/// pixel; the naive `px * 65535 / (size - 1)` lands one pixel short for most
/// positions.
fn normalize(g: f64, origin: i32, size: i32) -> i32 {
    let size = size.max(1) as f64;
    let px = (g.floor() - origin as f64).clamp(0.0, size - 1.0);
    ((px + 0.5) * 65536.0 / size).floor().clamp(0.0, 65535.0) as i32
}

/// Set-1 scan code (+ E0 "extended" flag) for a W3C `KeyboardEvent.code`.
/// `None` → use the virtual-key code from [`keymap`] instead.
fn scan_code(code: &str) -> Option<(u16, bool)> {
    const LETTERS: &[(&str, u16)] = &[
        ("KeyQ", 0x10), ("KeyW", 0x11), ("KeyE", 0x12), ("KeyR", 0x13), ("KeyT", 0x14), ("KeyY", 0x15),
        ("KeyU", 0x16), ("KeyI", 0x17), ("KeyO", 0x18), ("KeyP", 0x19), ("KeyA", 0x1E), ("KeyS", 0x1F),
        ("KeyD", 0x20), ("KeyF", 0x21), ("KeyG", 0x22), ("KeyH", 0x23), ("KeyJ", 0x24), ("KeyK", 0x25),
        ("KeyL", 0x26), ("KeyZ", 0x2C), ("KeyX", 0x2D), ("KeyC", 0x2E), ("KeyV", 0x2F), ("KeyB", 0x30),
        ("KeyN", 0x31), ("KeyM", 0x32),
    ];
    if let Some(&(_, sc)) = LETTERS.iter().find(|(c, _)| *c == code) {
        return Some((sc, false));
    }
    Some(match code {
        "Escape" => (0x01, false),
        "Digit1" => (0x02, false),
        "Digit2" => (0x03, false),
        "Digit3" => (0x04, false),
        "Digit4" => (0x05, false),
        "Digit5" => (0x06, false),
        "Digit6" => (0x07, false),
        "Digit7" => (0x08, false),
        "Digit8" => (0x09, false),
        "Digit9" => (0x0A, false),
        "Digit0" => (0x0B, false),
        "Minus" => (0x0C, false),
        "Equal" => (0x0D, false),
        "Backspace" => (0x0E, false),
        "Tab" => (0x0F, false),
        "BracketLeft" => (0x1A, false),
        "BracketRight" => (0x1B, false),
        "Enter" => (0x1C, false),
        "ControlLeft" => (0x1D, false),
        "Semicolon" => (0x27, false),
        "Quote" => (0x28, false),
        "Backquote" => (0x29, false),
        "ShiftLeft" => (0x2A, false),
        "Backslash" => (0x2B, false),
        "Comma" => (0x33, false),
        "Period" => (0x34, false),
        "Slash" => (0x35, false),
        "ShiftRight" => (0x36, false),
        "NumpadMultiply" => (0x37, false),
        "AltLeft" => (0x38, false),
        "Space" => (0x39, false),
        "CapsLock" => (0x3A, false),
        "F1" => (0x3B, false),
        "F2" => (0x3C, false),
        "F3" => (0x3D, false),
        "F4" => (0x3E, false),
        "F5" => (0x3F, false),
        "F6" => (0x40, false),
        "F7" => (0x41, false),
        "F8" => (0x42, false),
        "F9" => (0x43, false),
        "F10" => (0x44, false),
        "ScrollLock" => (0x46, false),
        "Numpad7" => (0x47, false),
        "Numpad8" => (0x48, false),
        "Numpad9" => (0x49, false),
        "NumpadSubtract" => (0x4A, false),
        "Numpad4" => (0x4B, false),
        "Numpad5" => (0x4C, false),
        "Numpad6" => (0x4D, false),
        "NumpadAdd" => (0x4E, false),
        "Numpad1" => (0x4F, false),
        "Numpad2" => (0x50, false),
        "Numpad3" => (0x51, false),
        "Numpad0" => (0x52, false),
        "NumpadDecimal" => (0x53, false),
        "IntlBackslash" => (0x56, false),
        "F11" => (0x57, false),
        "F12" => (0x58, false),
        "NumpadEqual" => (0x59, false),
        "F13" => (0x64, false),
        "F14" => (0x65, false),
        "F15" => (0x66, false),
        "F16" => (0x67, false),
        "F17" => (0x68, false),
        "F18" => (0x69, false),
        "F19" => (0x6A, false),
        "F20" => (0x6B, false),
        "F21" => (0x6C, false),
        "F22" => (0x6D, false),
        "F23" => (0x6E, false),
        "IntlRo" => (0x73, false),
        "F24" => (0x76, false),
        "IntlYen" => (0x7D, false),
        "NumpadComma" => (0x7E, false),
        "NumpadEnter" => (0x1C, true),
        "ControlRight" => (0x1D, true),
        "NumpadDivide" => (0x35, true),
        "PrintScreen" => (0x37, true),
        "AltRight" => (0x38, true),
        "Home" => (0x47, true),
        "ArrowUp" => (0x48, true),
        "PageUp" => (0x49, true),
        "ArrowLeft" => (0x4B, true),
        "ArrowRight" => (0x4D, true),
        "End" => (0x4F, true),
        "ArrowDown" => (0x50, true),
        "PageDown" => (0x51, true),
        "Insert" => (0x52, true),
        "Delete" => (0x53, true),
        "MetaLeft" | "OSLeft" => (0x5B, true),
        "MetaRight" | "OSRight" => (0x5C, true),
        "ContextMenu" => (0x5D, true),
        _ => return None,
    })
}

const VK_RETURN: u16 = 0x0D;
const VK_TAB: u16 = 0x09;

fn push_vk_press(v: &mut Vec<INPUT>, vk: u16) {
    // SAFETY: pure lookup.
    let scan = unsafe { MapVirtualKeyW(vk as u32, MAPVK_VK_TO_VSC) } as u16;
    v.push(key_input(vk, scan, KEYBD_EVENT_FLAGS(0)));
    v.push(key_input(vk, scan, KEYEVENTF_KEYUP));
}

impl InputInjector for SendInputInjector {
    fn mouse_move_abs(&mut self, x: f64, y: f64) -> anyhow::Result<()> {
        let (gx, gy) = to_global(&self.display, x, y);
        // SAFETY: simple metric queries.
        let (vx, vy, vw, vh) = unsafe {
            (
                GetSystemMetrics(SM_XVIRTUALSCREEN),
                GetSystemMetrics(SM_YVIRTUALSCREEN),
                GetSystemMetrics(SM_CXVIRTUALSCREEN).max(2),
                GetSystemMetrics(SM_CYVIRTUALSCREEN).max(2),
            )
        };
        let nx = normalize(gx, vx, vw);
        let ny = normalize(gy, vy, vh);
        send(&[mouse(nx, ny, 0, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK)])
    }

    fn button(&mut self, b: MouseButton, down: bool) -> anyhow::Result<()> {
        let (flags, data) = match (b, down) {
            (MouseButton::Left, true) => (MOUSEEVENTF_LEFTDOWN, 0),
            (MouseButton::Left, false) => (MOUSEEVENTF_LEFTUP, 0),
            (MouseButton::Right, true) => (MOUSEEVENTF_RIGHTDOWN, 0),
            (MouseButton::Right, false) => (MOUSEEVENTF_RIGHTUP, 0),
            (MouseButton::Middle, true) => (MOUSEEVENTF_MIDDLEDOWN, 0),
            (MouseButton::Middle, false) => (MOUSEEVENTF_MIDDLEUP, 0),
            (MouseButton::Back, true) => (MOUSEEVENTF_XDOWN, 1),
            (MouseButton::Back, false) => (MOUSEEVENTF_XUP, 1),
            (MouseButton::Forward, true) => (MOUSEEVENTF_XDOWN, 2),
            (MouseButton::Forward, false) => (MOUSEEVENTF_XUP, 2),
        };
        send(&[mouse(0, 0, data, flags)])
    }

    fn wheel(&mut self, dx: i32, dy: i32) -> anyhow::Result<()> {
        let mut v = Vec::new();
        if dy != 0 {
            // WHEEL_DELTA = 120; positive = away from the user (scroll up).
            v.push(mouse(0, 0, -dy.clamp(-100, 100) * 120, MOUSEEVENTF_WHEEL));
        }
        if dx != 0 {
            v.push(mouse(0, 0, dx.clamp(-100, 100) * 120, MOUSEEVENTF_HWHEEL));
        }
        if v.is_empty() {
            return Ok(());
        }
        send(&v)
    }

    fn key(&mut self, code: &str, down: bool) -> anyhow::Result<()> {
        let up = if down { KEYBD_EVENT_FLAGS(0) } else { KEYEVENTF_KEYUP };
        let alias = match code {
            "VolumeMute" => "AudioVolumeMute",
            "VolumeDown" => "AudioVolumeDown",
            "VolumeUp" => "AudioVolumeUp",
            c => c,
        };
        if let Some((scan, ext)) = scan_code(alias) {
            // SAFETY: plain queries; a NULL foreground window yields the system default layout.
            let vk = unsafe {
                let tid = GetWindowThreadProcessId(GetForegroundWindow(), None);
                let hkl = GetKeyboardLayout(tid);
                MapVirtualKeyExW(if ext { 0xE000 | scan as u32 } else { scan as u32 }, MAPVK_VSC_TO_VK_EX, Some(hkl))
            } as u16;
            let mut flags = up;
            if ext {
                flags |= KEYEVENTF_EXTENDEDKEY;
            }
            if vk != 0 {
                return send(&[key_input(vk, scan, flags)]);
            }
            if keymap::lookup(code).map(|e| e.win_vk == keymap::NONE).unwrap_or(true) {
                // The layout has no VK for this position: let Windows resolve the raw scan code.
                return send(&[key_input(0, scan, flags | KEYEVENTF_SCANCODE)]);
            }
        }
        let e = keymap::lookup(code).ok_or_else(|| anyhow!("unknown key code {code:?}"))?;
        if e.win_vk == keymap::NONE {
            anyhow::bail!("key {code:?} has no Windows equivalent");
        }
        // SAFETY: pure lookup.
        let scan = unsafe { MapVirtualKeyW(e.win_vk as u32, MAPVK_VK_TO_VSC) } as u16;
        let mut flags = up;
        if e.win_extended {
            flags |= KEYEVENTF_EXTENDEDKEY;
        }
        send(&[key_input(e.win_vk, scan, flags)])
    }

    fn text(&mut self, s: &str) -> anyhow::Result<()> {
        let mut v = Vec::with_capacity(s.len() * 2);
        let mut prev_cr = false;
        for ch in s.chars() {
            match ch {
                // "\r\n" is one line break
                '\n' if prev_cr => {}
                '\r' | '\n' => push_vk_press(&mut v, VK_RETURN),
                '\t' => push_vk_press(&mut v, VK_TAB),
                c if c.is_control() => {}
                c => {
                    // Each UTF-16 unit (both halves of a surrogate pair for emoji)
                    // becomes a WM_CHAR; apps reassemble surrogate pairs.
                    let mut buf = [0u16; 2];
                    for unit in c.encode_utf16(&mut buf) {
                        v.push(key_input(0, *unit, KEYEVENTF_UNICODE));
                        v.push(key_input(0, *unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
                    }
                }
            }
            prev_cr = ch == '\r';
        }
        if v.is_empty() {
            return Ok(());
        }
        // Keep each SendInput batch bounded so a huge paste cannot stall the input queue.
        for chunk in v.chunks(512) {
            send(chunk)?;
        }
        Ok(())
    }

    fn backend(&self) -> &'static str {
        "sendinput"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_round_trips_every_pixel() {
        // Windows maps back with floor(n * size / 65536); every pixel must come back exactly.
        for size in [800, 1366, 1920, 2560, 3840, 5120 + 1920] {
            for px in 0..size {
                let n = normalize(px as f64 - 100.0, -100, size);
                assert_eq!((n as i64 * size as i64) >> 16, px as i64, "size {size} px {px}");
            }
        }
    }

    #[test]
    fn scan_codes() {
        assert_eq!(scan_code("KeyA"), Some((0x1E, false)));
        assert_eq!(scan_code("ArrowLeft"), Some((0x4B, true)));
        assert_eq!(scan_code("AudioVolumeUp"), None);
        // every key in the shared table either has a scan code or a VK
        for e in keymap::KEYS {
            assert!(scan_code(e.code).is_some() || e.win_vk != keymap::NONE || e.code == "NumpadEqual", "{}", e.code);
        }
    }

    /// Interactive end-to-end check of the GDI fallback capturer + SendInput (Unicode text,
    /// scan codes, absolute pointer). Types into a Notepad it starts itself, so run it on a
    /// throw-away desktop, e.g. a Wine virtual desktop:
    ///
    /// ```sh
    /// LUMORA_SHOT=/tmp/shot wine explorer /desktop=lumoratest,1280x720 \
    ///   target/x86_64-pc-windows-gnu/debug/deps/lumora_media-*.exe --ignored --exact \
    ///   input::windows::tests::gdi_capture_and_unicode_input
    /// ```
    /// Writes `$LUMORA_SHOT.png` (the captured frame) and `$LUMORA_SHOT.txt` (results).
    #[test]
    #[ignore]
    fn gdi_capture_and_unicode_input() {
        use std::fmt::Write as _;
        use std::time::Duration;
        use windows::core::w;
        use windows::Win32::Foundation::{POINT, RECT};
        use windows::Win32::UI::WindowsAndMessaging::{FindWindowW, GetCursorPos, GetWindowRect, SetForegroundWindow};

        let out = std::env::var("LUMORA_SHOT").unwrap_or_else(|_| "lumora-shot".into());
        let mut report = String::new();
        let mut child = std::process::Command::new("notepad.exe").spawn().expect("start notepad");
        std::thread::sleep(Duration::from_secs(3));
        let hwnd = unsafe { FindWindowW(w!("Notepad"), None) }.expect("notepad window");
        unsafe {
            let _ = SetForegroundWindow(hwnd);
        }
        std::thread::sleep(Duration::from_millis(500));
        let displays = crate::capture::windows::list_displays();
        writeln!(report, "displays: {displays:?}").unwrap();
        let d = displays.first().cloned().unwrap_or_default();
        let mut inj = SendInputInjector::open(&d).unwrap();
        let r_text = inj.text("Xin chào tiếng Việt: ắ ổ ữ đ Ư — 🎉\r\nDòng thứ hai\tTAB ");
        // scan-code path: Shift+KeyL, KeyU, KeyM → "Lum"
        let mut r_keys = Ok(());
        for (code, down) in [("ShiftLeft", true), ("KeyL", true), ("KeyL", false), ("ShiftLeft", false),
                             ("KeyU", true), ("KeyU", false), ("KeyM", true), ("KeyM", false)] {
            r_keys = r_keys.and(inj.key(code, down));
        }
        let mut wr = RECT::default();
        unsafe { GetWindowRect(hwnd, &mut wr) }.unwrap();
        let (tx, ty) = ((wr.left + wr.right) / 2, (wr.top + wr.bottom) / 2);
        let nx = (tx - d.x) as f64 / (d.width.max(2) - 1) as f64;
        let ny = (ty - d.y) as f64 / (d.height.max(2) - 1) as f64;
        let r_move = inj.mouse_move_abs(nx, ny);
        std::thread::sleep(Duration::from_millis(800));
        let mut p = POINT::default();
        unsafe { GetCursorPos(&mut p) }.unwrap();
        writeln!(report, "text: {r_text:?}; keys: {r_keys:?}; move: {r_move:?}").unwrap();
        writeln!(report, "pointer target ({tx},{ty}) actual ({},{})", p.x, p.y).unwrap();
        writeln!(report, "cursor: {}", crate::capture::windows::cursor_debug()).unwrap();

        use crate::Capturer as _;
        let opts = crate::CaptureOptions { fps: 10, cursor: true, ..Default::default() };
        let mut cap = crate::capture::windows::GdiCapturer::open(d.index, &opts).unwrap();
        let f = cap.next_frame(Duration::from_secs(2)).unwrap().expect("a frame");
        f.validate().unwrap();
        writeln!(report, "frame {}x{} stride {}", f.width, f.height, f.stride).unwrap();
        let mut rgba = Vec::with_capacity((f.width * f.height * 4) as usize);
        for y in 0..f.height as usize {
            let row = &f.data[y * f.stride as usize..][..f.width as usize * 4];
            for px in row.chunks_exact(4) {
                rgba.extend_from_slice(&[px[2], px[1], px[0], 255]);
            }
        }
        let file = std::fs::File::create(format!("{out}.png")).unwrap();
        let mut enc = png::Encoder::new(std::io::BufWriter::new(file), f.width, f.height);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        enc.write_header().unwrap().write_image_data(&rgba).unwrap();
        let tile = crate::capture::windows::cursor_tile();
        let changed = tile.chunks(4).filter(|p| p[..3] != [255, 255, 255]).count();
        writeln!(report, "cursor overlay changed {changed} px of a 64x64 white tile").unwrap();
        let file = std::fs::File::create(format!("{out}-cursor.png")).unwrap();
        let mut enc = png::Encoder::new(std::io::BufWriter::new(file), 64, 64);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        let rgba: Vec<u8> = tile.chunks(4).flat_map(|p| [p[2], p[1], p[0], 255]).collect();
        enc.write_header().unwrap().write_image_data(&rgba).unwrap();
        std::fs::write(format!("{out}.txt"), &report).unwrap();
        let _ = child.kill();
        let _ = child.wait();
        assert!(r_text.is_ok() && r_keys.is_ok() && r_move.is_ok(), "{report}");
        // Under Wine on XWayland the compositor ignores pointer warps, so the position can't be checked there.
        if crate::capture::windows::wine_version().is_none() {
            assert!((p.x - tx).abs() <= 1 && (p.y - ty).abs() <= 1, "{report}");
        }
    }
}
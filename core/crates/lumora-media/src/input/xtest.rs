//! X11 input injection via the XTest extension.
//!
//! `text()` types any Unicode character: if the current keymap has no key for
//! a character, a spare keycode is temporarily remapped to its keysym (the
//! technique xdotool uses).

use std::collections::HashSet;
use std::time::Duration;

use anyhow::{anyhow, Context};
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{ConnectionExt as _, Keycode, Keysym, Window};
use x11rb::protocol::xtest::ConnectionExt as _;
use x11rb::rust_connection::RustConnection;

use super::to_global;
use crate::{keymap, DisplayInfo, InputInjector, MouseButton};

const KEY_PRESS: u8 = 2;
const KEY_RELEASE: u8 = 3;
const BUTTON_PRESS: u8 = 4;
const BUTTON_RELEASE: u8 = 5;
const MOTION_NOTIFY: u8 = 6;
const SHIFT_KEYCODE: Keycode = 42 + 8;

pub struct XtestInjector {
    conn: RustConnection,
    root: Window,
    display: DisplayInfo,
    min_keycode: u8,
    per_keycode: usize,
    keysyms: Vec<Keysym>,
    spare: Option<Keycode>,
    pressed_keys: HashSet<u8>,
    pressed_buttons: HashSet<u8>,
}

impl XtestInjector {
    pub fn open(display: &DisplayInfo) -> anyhow::Result<Self> {
        let (conn, screen) = x11rb::connect(None).map_err(|e| anyhow!("cannot connect to X server: {e}"))?;
        conn.xtest_get_version(2, 2)?.reply().context("XTest extension not available on this X server")?;
        let root = conn.setup().roots[screen].root;
        let mut me = Self {
            conn,
            root,
            display: display.clone(),
            min_keycode: 8,
            per_keycode: 0,
            keysyms: Vec::new(),
            spare: None,
            pressed_keys: HashSet::new(),
            pressed_buttons: HashSet::new(),
        };
        me.reload_mapping()?;
        Ok(me)
    }

    fn reload_mapping(&mut self) -> anyhow::Result<()> {
        let setup = self.conn.setup();
        let (min, max) = (setup.min_keycode, setup.max_keycode);
        let r = self.conn.get_keyboard_mapping(min, max - min + 1)?.reply()?;
        self.min_keycode = min;
        self.per_keycode = r.keysyms_per_keycode as usize;
        self.keysyms = r.keysyms;
        // A spare keycode: one with no symbols at all, scanning from the top.
        self.spare = (0..=(max - min) as usize)
            .rev()
            .find(|&i| {
                let row = &self.keysyms[i * self.per_keycode..(i + 1) * self.per_keycode];
                row.iter().all(|&k| k == 0)
            })
            .map(|i| min + i as u8);
        Ok(())
    }

    fn fake(&self, ty: u8, detail: u8, x: i16, y: i16) -> anyhow::Result<()> {
        self.conn.xtest_fake_input(ty, detail, 0, self.root, x, y, 0)?;
        self.conn.flush()?;
        Ok(())
    }

    fn key_raw(&mut self, kc: u8, down: bool) -> anyhow::Result<()> {
        self.fake(if down { KEY_PRESS } else { KEY_RELEASE }, kc, 0, 0)?;
        if down {
            self.pressed_keys.insert(kc);
        } else {
            self.pressed_keys.remove(&kc);
        }
        Ok(())
    }

    fn find_keysym(&self, ks: Keysym) -> Option<(Keycode, bool)> {
        if self.per_keycode == 0 {
            return None;
        }
        for (i, row) in self.keysyms.chunks(self.per_keycode).enumerate() {
            if row.first() == Some(&ks) {
                return Some((self.min_keycode + i as u8, false));
            }
            if row.get(1) == Some(&ks) {
                return Some((self.min_keycode + i as u8, true));
            }
        }
        None
    }

    fn type_keysym(&mut self, ks: Keysym) -> anyhow::Result<()> {
        if let Some((kc, shift)) = self.find_keysym(ks) {
            if shift {
                self.key_raw(SHIFT_KEYCODE, true)?;
            }
            self.key_raw(kc, true)?;
            self.key_raw(kc, false)?;
            if shift {
                self.key_raw(SHIFT_KEYCODE, false)?;
            }
            return Ok(());
        }
        let spare = self.spare.ok_or_else(|| anyhow!("no spare keycode available to type keysym {ks:#x}"))?;
        let n = self.per_keycode.max(1);
        let syms = vec![ks; n];
        self.conn.change_keyboard_mapping(1, spare, n as u8, &syms)?;
        self.conn.get_input_focus()?.reply()?; // round-trip so the mapping is applied
        std::thread::sleep(Duration::from_millis(10));
        self.key_raw(spare, true)?;
        self.key_raw(spare, false)?;
        self.conn.get_input_focus()?.reply()?;
        std::thread::sleep(Duration::from_millis(10));
        let empty = vec![0; n];
        self.conn.change_keyboard_mapping(1, spare, n as u8, &empty)?;
        self.conn.flush()?;
        Ok(())
    }
}

impl Drop for XtestInjector {
    fn drop(&mut self) {
        for k in self.pressed_keys.drain().collect::<Vec<_>>() {
            let _ = self.conn.xtest_fake_input(KEY_RELEASE, k, 0, self.root, 0, 0, 0);
        }
        for b in self.pressed_buttons.drain().collect::<Vec<_>>() {
            let _ = self.conn.xtest_fake_input(BUTTON_RELEASE, b, 0, self.root, 0, 0, 0);
        }
        let _ = self.conn.flush();
    }
}

fn char_keysym(c: char) -> Keysym {
    match c {
        '\n' | '\r' => 0xff0d,
        '\t' => 0xff09,
        '\u{8}' => 0xff08,
        c if (0x20..=0x7e).contains(&(c as u32)) || (0xa0..=0xff).contains(&(c as u32)) => c as u32,
        c => 0x0100_0000 | c as u32,
    }
}

impl InputInjector for XtestInjector {
    fn mouse_move_abs(&mut self, x: f64, y: f64) -> anyhow::Result<()> {
        let (gx, gy) = to_global(&self.display, x, y);
        self.fake(MOTION_NOTIFY, 0, gx.round() as i16, gy.round() as i16)
    }

    fn button(&mut self, b: MouseButton, down: bool) -> anyhow::Result<()> {
        let detail = match b {
            MouseButton::Left => 1,
            MouseButton::Middle => 2,
            MouseButton::Right => 3,
            MouseButton::Back => 8,
            MouseButton::Forward => 9,
        };
        self.fake(if down { BUTTON_PRESS } else { BUTTON_RELEASE }, detail, 0, 0)?;
        if down {
            self.pressed_buttons.insert(detail);
        } else {
            self.pressed_buttons.remove(&detail);
        }
        Ok(())
    }

    fn wheel(&mut self, dx: i32, dy: i32) -> anyhow::Result<()> {
        let clicks = |button: u8, n: i32| -> anyhow::Result<()> {
            for _ in 0..n.unsigned_abs().min(100) {
                self.fake(BUTTON_PRESS, button, 0, 0)?;
                self.fake(BUTTON_RELEASE, button, 0, 0)?;
            }
            Ok(())
        };
        clicks(if dy > 0 { 5 } else { 4 }, dy)?;
        clicks(if dx > 0 { 7 } else { 6 }, dx)?;
        Ok(())
    }

    fn key(&mut self, code: &str, down: bool) -> anyhow::Result<()> {
        let e = keymap::lookup(code).ok_or_else(|| anyhow!("unknown key code {code:?}"))?;
        if e.evdev == keymap::NONE || e.evdev > 247 {
            anyhow::bail!("key {code:?} cannot be sent through X11");
        }
        self.key_raw(e.evdev as u8 + 8, down)
    }

    fn text(&mut self, s: &str) -> anyhow::Result<()> {
        for c in s.chars() {
            self.type_keysym(char_keysym(c))?;
        }
        Ok(())
    }

    fn backend(&self) -> &'static str {
        "xtest"
    }
}

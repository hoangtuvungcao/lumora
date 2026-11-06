//! macOS input injection with Quartz `CGEvent`s posted to the HID tap.
//!
//! Needs the Accessibility permission (System Settings → Privacy & Security →
//! Accessibility). Coordinates are global "points" (CGDisplayBounds).

use std::collections::HashSet;

use anyhow::anyhow;
use core_graphics::event::{CGEvent, CGEventTapLocation, CGEventType, CGMouseButton, EventField, ScrollEventUnit};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use core_graphics::geometry::CGPoint;

use super::to_global;
use crate::{keymap, DisplayInfo, InputInjector, MouseButton};

pub struct CgEventInjector {
    display: DisplayInfo,
    pos: CGPoint,
    pressed: HashSet<MouseButton>,
}

// SAFETY: only plain data is stored; event sources are created per call.
unsafe impl Send for CgEventInjector {}

fn source() -> anyhow::Result<CGEventSource> {
    CGEventSource::new(CGEventSourceStateID::HIDSystemState)
        .map_err(|_| anyhow!("CGEventSourceCreate failed (Accessibility permission missing?)"))
}

impl CgEventInjector {
    pub fn open(display: &DisplayInfo) -> anyhow::Result<Self> {
        source()?;
        Ok(Self { display: display.clone(), pos: CGPoint::new(0.0, 0.0), pressed: HashSet::new() })
    }

    fn post_mouse(&self, ty: CGEventType, button: CGMouseButton, number: Option<i64>) -> anyhow::Result<()> {
        let ev = CGEvent::new_mouse_event(source()?, ty, self.pos, button).map_err(|_| anyhow!("CGEventCreateMouseEvent failed"))?;
        if let Some(n) = number {
            ev.set_integer_value_field(EventField::MOUSE_EVENT_BUTTON_NUMBER, n);
        }
        ev.post(CGEventTapLocation::HID);
        Ok(())
    }
}

impl InputInjector for CgEventInjector {
    fn mouse_move_abs(&mut self, x: f64, y: f64) -> anyhow::Result<()> {
        let (gx, gy) = to_global(&self.display, x, y);
        self.pos = CGPoint::new(gx, gy);
        // While a button is held macOS expects "dragged" events.
        let (ty, btn) = if self.pressed.contains(&MouseButton::Left) {
            (CGEventType::LeftMouseDragged, CGMouseButton::Left)
        } else if self.pressed.contains(&MouseButton::Right) {
            (CGEventType::RightMouseDragged, CGMouseButton::Right)
        } else if !self.pressed.is_empty() {
            (CGEventType::OtherMouseDragged, CGMouseButton::Center)
        } else {
            (CGEventType::MouseMoved, CGMouseButton::Left)
        };
        self.post_mouse(ty, btn, None)
    }

    fn button(&mut self, b: MouseButton, down: bool) -> anyhow::Result<()> {
        let (ty, btn, num) = match (b, down) {
            (MouseButton::Left, true) => (CGEventType::LeftMouseDown, CGMouseButton::Left, None),
            (MouseButton::Left, false) => (CGEventType::LeftMouseUp, CGMouseButton::Left, None),
            (MouseButton::Right, true) => (CGEventType::RightMouseDown, CGMouseButton::Right, None),
            (MouseButton::Right, false) => (CGEventType::RightMouseUp, CGMouseButton::Right, None),
            (MouseButton::Middle, d) => (if d { CGEventType::OtherMouseDown } else { CGEventType::OtherMouseUp }, CGMouseButton::Center, Some(2)),
            (MouseButton::Back, d) => (if d { CGEventType::OtherMouseDown } else { CGEventType::OtherMouseUp }, CGMouseButton::Center, Some(3)),
            (MouseButton::Forward, d) => (if d { CGEventType::OtherMouseDown } else { CGEventType::OtherMouseUp }, CGMouseButton::Center, Some(4)),
        };
        if down {
            self.pressed.insert(b);
        } else {
            self.pressed.remove(&b);
        }
        self.post_mouse(ty, btn, num)
    }

    fn wheel(&mut self, dx: i32, dy: i32) -> anyhow::Result<()> {
        if dx == 0 && dy == 0 {
            return Ok(());
        }
        // Quartz: positive wheel1 scrolls up, positive wheel2 scrolls left.
        let ev = CGEvent::new_scroll_event(source()?, ScrollEventUnit::LINE, 2, -dy.clamp(-100, 100), -dx.clamp(-100, 100), 0)
            .map_err(|_| anyhow!("CGEventCreateScrollWheelEvent failed"))?;
        ev.post(CGEventTapLocation::HID);
        Ok(())
    }

    fn key(&mut self, code: &str, down: bool) -> anyhow::Result<()> {
        let e = keymap::lookup(code).ok_or_else(|| anyhow!("unknown key code {code:?}"))?;
        if e.mac == keymap::NONE {
            anyhow::bail!("key {code:?} has no macOS equivalent");
        }
        let ev = CGEvent::new_keyboard_event(source()?, e.mac, down).map_err(|_| anyhow!("CGEventCreateKeyboardEvent failed"))?;
        ev.post(CGEventTapLocation::HID);
        Ok(())
    }

    fn text(&mut self, s: &str) -> anyhow::Result<()> {
        // Send in chunks of up to 20 UTF-16 units (Quartz limit per event).
        let units: Vec<u16> = s.encode_utf16().collect();
        for chunk in units.chunks(20) {
            for down in [true, false] {
                let ev = CGEvent::new_keyboard_event(source()?, 0, down).map_err(|_| anyhow!("CGEventCreateKeyboardEvent failed"))?;
                ev.set_string_from_utf16_unchecked(chunk);
                ev.post(CGEventTapLocation::HID);
            }
        }
        Ok(())
    }

    fn backend(&self) -> &'static str {
        "cgevent"
    }
}

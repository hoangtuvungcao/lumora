//! Android input "injection".
//!
//! Rust cannot inject input on Android: only an `AccessibilityService`
//! (`dispatchGesture`, `performGlobalAction`, `ACTION_SET_TEXT`) can, and that
//! lives in Kotlin. The injector therefore serialises every event as a small
//! JSON object into a bounded queue; the app's Kotlin side drains it with the
//! JNI function `LumoraNative.nextInput(ByteBuffer, timeoutMs)` (exported
//! below) and turns pointer events into gestures.
//!
//! Wire format (one JSON object per call, same names as `remote_input.ev`):
//! `{"t":"move","x":0.5,"y":0.25}` · `{"t":"button","b":"left","down":true}` ·
//! `{"t":"wheel","dx":0,"dy":-1}` · `{"t":"key","code":"Escape","down":true}` ·
//! `{"t":"text","s":"Xin chào"}`.

use std::collections::VecDeque;
use std::ffi::c_void;
use std::sync::OnceLock;
use std::time::Duration;

use parking_lot::{Condvar, Mutex};

use crate::{DisplayInfo, InputInjector, MouseButton};

const CAP: usize = 512;

struct Queue {
    q: Mutex<VecDeque<String>>,
    cv: Condvar,
}

fn queue() -> &'static Queue {
    static Q: OnceLock<Queue> = OnceLock::new();
    Q.get_or_init(|| Queue { q: Mutex::new(VecDeque::with_capacity(64)), cv: Condvar::new() })
}

fn push(ev: serde_json::Value) {
    let s = ev.to_string();
    let q = queue();
    let mut g = q.q.lock();
    // Coalesce consecutive moves so a slow consumer never lags behind the pointer.
    if g.back().map(|b| b.starts_with("{\"t\":\"move\"")).unwrap_or(false) && s.starts_with("{\"t\":\"move\"") {
        g.pop_back();
    }
    while g.len() >= CAP {
        g.pop_front();
    }
    g.push_back(s);
    drop(g);
    q.cv.notify_one();
}

/// Wait up to `timeout` for the next queued input event (JSON).
pub fn next_android_input(timeout: Duration) -> Option<String> {
    let q = queue();
    let mut g = q.q.lock();
    if g.is_empty() {
        q.cv.wait_for(&mut g, timeout);
    }
    g.pop_front()
}

pub(crate) struct AndroidInjector;

impl AndroidInjector {
    pub(crate) fn open(_display: &DisplayInfo) -> anyhow::Result<Self> {
        queue().q.lock().clear();
        Ok(AndroidInjector)
    }
}

fn button_name(b: MouseButton) -> &'static str {
    match b {
        MouseButton::Left => "left",
        MouseButton::Right => "right",
        MouseButton::Middle => "middle",
        MouseButton::Back => "back",
        MouseButton::Forward => "forward",
    }
}

impl InputInjector for AndroidInjector {
    fn mouse_move_abs(&mut self, x: f64, y: f64) -> anyhow::Result<()> {
        let x = if x.is_finite() { x.clamp(0.0, 1.0) } else { 0.0 };
        let y = if y.is_finite() { y.clamp(0.0, 1.0) } else { 0.0 };
        push(serde_json::json!({"t": "move", "x": x, "y": y}));
        Ok(())
    }
    fn button(&mut self, b: MouseButton, down: bool) -> anyhow::Result<()> {
        push(serde_json::json!({"t": "button", "b": button_name(b), "down": down}));
        Ok(())
    }
    fn wheel(&mut self, dx: i32, dy: i32) -> anyhow::Result<()> {
        push(serde_json::json!({"t": "wheel", "dx": dx, "dy": dy}));
        Ok(())
    }
    fn key(&mut self, code: &str, down: bool) -> anyhow::Result<()> {
        push(serde_json::json!({"t": "key", "code": code, "down": down}));
        Ok(())
    }
    fn text(&mut self, s: &str) -> anyhow::Result<()> {
        push(serde_json::json!({"t": "text", "s": s}));
        Ok(())
    }
    fn backend(&self) -> &'static str {
        "android-accessibility"
    }
}

// ----------------------------------------------------------------- JNI glue
//
// Hand-written against the JNI function table so no extra crate is needed.
// Indices from the JNI spec (jni.h, JNINativeInterface): 230 =
// GetDirectBufferAddress, 231 = GetDirectBufferCapacity.

pub(crate) type JniEnv = *mut *const *const c_void;

pub(crate) unsafe fn direct_buffer(env: JniEnv, buf: *mut c_void) -> Option<(*mut u8, usize)> {
    if env.is_null() || buf.is_null() {
        return None;
    }
    let table = *env;
    let addr_fn: extern "system" fn(JniEnv, *mut c_void) -> *mut c_void = std::mem::transmute(*table.add(230));
    let cap_fn: extern "system" fn(JniEnv, *mut c_void) -> i64 = std::mem::transmute(*table.add(231));
    let p = addr_fn(env, buf);
    let n = cap_fn(env, buf);
    if p.is_null() || n <= 0 {
        return None;
    }
    Some((p as *mut u8, n as usize))
}

/// `static native int nextInput(ByteBuffer direct, int timeoutMs)` on
/// `vn.lumora.lumora.LumoraNative`: blocks up to `timeoutMs`, writes one UTF-8
/// JSON event into the direct buffer and returns its length (0 = none,
/// -1 = buffer unusable).
///
/// # Safety
/// Called by the JVM with a valid `JNIEnv*` and a direct `ByteBuffer`.
#[no_mangle]
pub unsafe extern "system" fn Java_vn_lumora_lumora_LumoraNative_nextInput(
    env: JniEnv,
    _class: *mut c_void,
    buf: *mut c_void,
    timeout_ms: i32,
) -> i32 {
    // never unwind into the JVM
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let Some((p, cap)) = direct_buffer(env, buf) else { return -1 };
        let Some(ev) = next_android_input(Duration::from_millis(timeout_ms.clamp(0, 5000) as u64)) else { return 0 };
        let b = ev.as_bytes();
        if b.len() > cap {
            return 0; // oversized (text > buffer): drop
        }
        std::ptr::copy_nonoverlapping(b.as_ptr(), p, b.len());
        b.len() as i32
    }))
    .unwrap_or(-1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queue_coalesces_moves() {
        let mut i = AndroidInjector::open(&DisplayInfo::default()).unwrap();
        i.mouse_move_abs(0.1, 0.1).unwrap();
        i.mouse_move_abs(0.2, 0.2).unwrap();
        i.button(MouseButton::Left, true).unwrap();
        let a = next_android_input(Duration::from_millis(1)).unwrap();
        assert!(a.contains("0.2"));
        assert!(next_android_input(Duration::from_millis(1)).unwrap().contains("button"));
        assert!(next_android_input(Duration::from_millis(1)).is_none());
    }
}

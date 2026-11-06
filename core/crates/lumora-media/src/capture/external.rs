//! Capturer fed by the host application.
//!
//! On Android, screen capture must go through `MediaProjection`, which is only
//! reachable from Kotlin/Java: the Flutter plugin obtains an `ImageReader`
//! (RGBA_8888), and for every `Image` calls into the Rust FFI, which forwards
//! the plane to [`push_external_frame`]. iOS (ReplayKit broadcast extension)
//! works the same way. The Rust side then uses [`open_external_capturer`]
//! (which [`crate::open_capturer`] returns on those platforms) like any other
//! capturer.
//!
//! This is available on every platform, which also makes it useful for tests.

use std::sync::{Arc, OnceLock};
use std::time::Duration;

use bytes::Bytes;
use parking_lot::Mutex;

use super::FrameQueue;
use crate::{Capturer, DisplayInfo, Frame, PixelFormat};

struct Shared {
    queue: Arc<FrameQueue>,
    display: Mutex<Option<DisplayInfo>>,
}

fn shared() -> &'static Shared {
    static S: OnceLock<Shared> = OnceLock::new();
    S.get_or_init(|| Shared { queue: FrameQueue::new(2), display: Mutex::new(None) })
}

/// Push a frame produced outside Rust (e.g. Android `ImageReader`).
/// The data is copied. Rows are `stride` bytes apart, 4 bytes per pixel.
pub fn push_external_frame(
    width: u32,
    height: u32,
    stride: u32,
    format: PixelFormat,
    data: &[u8],
    ts_us: u64,
) -> anyhow::Result<()> {
    let frame = Frame { width, height, stride, format, data: Bytes::copy_from_slice(data), ts_us };
    frame.validate()?;
    let s = shared();
    {
        let mut d = s.display.lock();
        let needs = d.as_ref().map(|d| d.width != width || d.height != height).unwrap_or(true);
        if needs {
            let mut info = d.clone().unwrap_or_else(|| DisplayInfo { name: "external".into(), ..Default::default() });
            info.width = width;
            info.height = height;
            *d = Some(info);
        }
    }
    s.queue.push(frame);
    Ok(())
}

/// Describe the external display (name, logical size, scale) for `displays()`.
pub fn set_external_display(info: DisplayInfo) {
    *shared().display.lock() = Some(info);
}

pub(crate) fn external_display() -> Option<DisplayInfo> {
    shared().display.lock().clone()
}

/// Drop any queued external frames (e.g. when the projection stops).
pub fn clear_external_frames() {
    shared().queue.clear();
}

/// Capturer reading frames pushed via [`push_external_frame`].
pub fn open_external_capturer() -> ExternalCapturer {
    ExternalCapturer { _p: () }
}

pub struct ExternalCapturer {
    _p: (),
}

impl Capturer for ExternalCapturer {
    fn displays(&self) -> Vec<DisplayInfo> {
        external_display().into_iter().collect()
    }
    fn next_frame(&mut self, timeout: Duration) -> anyhow::Result<Option<Frame>> {
        shared().queue.pop(timeout)
    }
}

// ----------------------------------------------------------- Android JNI glue
//
// `vn.lumora.lumora.LumoraNative` (Kotlin) loads liblumora_ffi.so and calls
// these with the RGBA_8888 plane of each `ImageReader` image (a direct
// ByteBuffer, so no copy on the Java side). They live here rather than in
// lumora-ffi because lumora-ffi does not depend on lumora-media directly.

/// `static native int pushFrame(int w, int h, int stride, ByteBuffer plane)`:
/// 0 ok, -1 bad buffer, -2 invalid geometry.
///
/// # Safety
/// Called by the JVM with a valid `JNIEnv*` and a direct `ByteBuffer`.
#[cfg(target_os = "android")]
#[no_mangle]
pub unsafe extern "system" fn Java_vn_lumora_lumora_LumoraNative_pushFrame(
    env: crate::input::android::JniEnv,
    _class: *mut std::ffi::c_void,
    width: i32,
    height: i32,
    stride: i32,
    buf: *mut std::ffi::c_void,
) -> i32 {
    // never unwind into the JVM
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let Some((p, len)) = crate::input::android::direct_buffer(env, buf) else { return -1 };
        if width <= 0 || height <= 0 || stride <= 0 {
            return -2;
        }
        let data = std::slice::from_raw_parts(p as *const u8, len);
        match push_external_frame(width as u32, height as u32, stride as u32, PixelFormat::Rgba, data, crate::now_us()) {
            Ok(()) => 0,
            Err(_) => -2,
        }
    }))
    .unwrap_or(-1)
}

/// `static native void setDisplay(int w, int h, float scale)`: describe the
/// phone screen before the first frame arrives (the core reads the size when
/// the remote session starts).
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_vn_lumora_lumora_LumoraNative_setDisplay(
    _env: *mut std::ffi::c_void,
    _class: *mut std::ffi::c_void,
    width: i32,
    height: i32,
    scale: f32,
) {
    // never unwind into the JVM
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if width > 0 && height > 0 {
            set_external_display(DisplayInfo {
                name: "Android".into(),
                width: width as u32,
                height: height as u32,
                scale: if scale.is_finite() && scale > 0.0 { scale } else { 1.0 },
                ..Default::default()
            });
        }
    }))
    .unwrap_or(())
}

/// `static native void clearFrames()`: the projection stopped.
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_vn_lumora_lumora_LumoraNative_clearFrames(_env: *mut std::ffi::c_void, _class: *mut std::ffi::c_void) {
    // never unwind into the JVM
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        clear_external_frames();
    }))
    .unwrap_or(())
}

/// `static native void initContext(Context ctx)`: hand the JVM + application context
/// to the audio backend (cpal/AAudio looks them up through `ndk-context`). Must run
/// once before the first call; repeated calls are ignored.
///
/// # Safety
/// Called by the JVM with a valid `JNIEnv*` and a `Context` object.
#[cfg(target_os = "android")]
#[no_mangle]
pub unsafe extern "system" fn Java_vn_lumora_lumora_LumoraNative_initContext(
    env: crate::input::android::JniEnv,
    _class: *mut std::ffi::c_void,
    ctx: *mut std::ffi::c_void,
) {
    // never unwind into the JVM
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        static DONE: std::sync::Once = std::sync::Once::new();
        if env.is_null() || ctx.is_null() {
            return;
        }
        DONE.call_once(|| {
            let table = *env;
            // JNI function table: NewGlobalRef = 21, GetJavaVM = 219
            let new_global: extern "system" fn(crate::input::android::JniEnv, *mut std::ffi::c_void) -> *mut std::ffi::c_void =
                std::mem::transmute(*table.add(21));
            let get_vm: extern "system" fn(crate::input::android::JniEnv, *mut *mut std::ffi::c_void) -> i32 = std::mem::transmute(*table.add(219));
            let mut vm: *mut std::ffi::c_void = std::ptr::null_mut();
            if get_vm(env, &mut vm) != 0 || vm.is_null() {
                return;
            }
            let gctx = new_global(env, ctx);
            ndk_context::initialize_android_context(vm, gctx);
        });
    }))
    .unwrap_or(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_and_pull() {
        let mut c = open_external_capturer();
        assert!(push_external_frame(2, 2, 8, PixelFormat::Rgba, &[0u8; 3], 0).is_err());
        push_external_frame(2, 2, 8, PixelFormat::Rgba, &[7u8; 16], 42).unwrap();
        let f = c.next_frame(Duration::from_millis(10)).unwrap().unwrap();
        assert_eq!((f.width, f.ts_us), (2, 42));
        assert_eq!(c.displays()[0].width, 2);
    }
}

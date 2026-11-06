//! C ABI used by the Flutter app (dart:ffi). See docs/src/dev/api.md.
//!
//! All functions are thread-safe. `lumora_request` and `lumora_next_event` block, so the
//! Dart side calls them from a background isolate.

use lumora_core::node::{Node, NodeConfig};
use parking_lot::Mutex;
use std::ffi::{c_char, CStr, CString};
use std::future::Future;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::{broadcast, watch};

struct Instance {
    /// Taken by `lumora_stop` to shut the runtime down (callers use `handle`).
    rt: Mutex<Option<tokio::runtime::Runtime>>,
    handle: tokio::runtime::Handle,
    node: Arc<Node>,
    events: Mutex<broadcast::Receiver<serde_json::Value>>,
    /// `true` once `lumora_stop` began: blocked calls return at once.
    stop: watch::Sender<bool>,
}

impl Instance {
    /// Run `fut` on the runtime; `None` if the instance is (or starts) stopping.
    fn block_on<F: Future>(&self, fut: F) -> Option<F::Output> {
        let mut stop = self.stop.subscribe();
        if *stop.borrow_and_update() {
            return None;
        }
        self.handle.block_on(async move {
            tokio::select! {
                biased;
                _ = stop.wait_for(|s| *s) => None,
                r = fut => Some(r),
            }
        })
    }
}

static INSTANCE: Mutex<Option<Arc<Instance>>> = Mutex::new(None);
/// Held for the whole of `lumora_start` / `lumora_stop`: a start waits for a stop in
/// progress (the old node must be gone before the data folder is opened again).
static LIFECYCLE: Mutex<()> = Mutex::new(());
static LAST_ERROR: Mutex<Option<CString>> = Mutex::new(None);
static LAST_ERROR_JSON: Mutex<Option<CString>> = Mutex::new(None);
static LOG_INIT: OnceLock<()> = OnceLock::new();

/// How long `lumora_start` waits for a concurrent start/stop to finish.
const LIFECYCLE_WAIT: Duration = Duration::from_secs(15);
/// How long `lumora_stop` waits for calls in progress to return.
const IN_FLIGHT_WAIT: Duration = Duration::from_secs(3);
/// How long `lumora_stop` waits for the stopped node to be dropped.
const NODE_RELEASE_WAIT: Duration = Duration::from_secs(2);

/// Run an entry point's body; a panic becomes `fallback()` instead of unwinding into
/// C / Dart / Java (the release profile keeps `panic = "unwind"` for this).
fn guard<R>(body: impl FnOnce() -> R, fallback: impl FnOnce() -> R) -> R {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(body)).unwrap_or_else(|_| fallback())
}

fn set_error(e: impl std::fmt::Display) {
    *LAST_ERROR.lock() = CString::new(e.to_string().replace('\0', " ")).ok();
}

fn set_error_json(v: serde_json::Value) {
    *LAST_ERROR_JSON.lock() = CString::new(v.to_string().replace('\0', " ")).ok();
}

fn to_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', " ")).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut())
}

fn inst() -> Option<Arc<Instance>> {
    INSTANCE.lock().clone()
}

fn internal_error(id: Option<&serde_json::Value>, detail: &str) -> *mut c_char {
    let mut v = serde_json::json!({"ok": false, "error": lumora_core::i18n::tr("err.generic"), "code": "internal", "detail": detail});
    if let Some(id) = id {
        v["id"] = id.clone();
    }
    to_c(v.to_string())
}

/// Start the node. Returns 0 on success, -1 on error (see `lumora_last_error`), 1 if already running.
/// While `lumora_stop` is still shutting the previous node down this waits for it (up to
/// 15 s, then fails).
///
/// # Safety
/// `config_json` must be NULL or a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn lumora_start(config_json: *const c_char) -> i32 {
    let fail = |e: anyhow::Error| {
        // plain text only; the raw cause goes to the log
        tracing::warn!("start failed: {e:#}");
        let e = lumora_core::i18n::or_user(e, "err.start_failed");
        set_error(lumora_core::i18n::error_text(&e));
        set_error_json(serde_json::Value::Object(lumora_core::i18n::error_fields(&e)));
        -1
    };
    let panicked = || {
        set_error(lumora_core::i18n::tr("err.start_failed"));
        set_error_json(serde_json::json!({"error": lumora_core::i18n::tr("err.start_failed"), "code": "internal", "detail": "panic during start"}));
        -1
    };
    guard(
        || {
            let Some(_life) = LIFECYCLE.try_lock_for(LIFECYCLE_WAIT) else {
                return fail(lumora_core::i18n::user_err("err.start_failed").detail("the previous session is still shutting down").into());
            };
            if inst().is_some() {
                return 1;
            }
            let cfg_s = if config_json.is_null() { "{}".to_string() } else { CStr::from_ptr(config_json).to_string_lossy().to_string() };
            match start_instance(&cfg_s) {
                Ok(i) => {
                    *INSTANCE.lock() = Some(i);
                    0
                }
                Err(e) => fail(e),
            }
        },
        panicked,
    )
}

fn start_instance(cfg_s: &str) -> anyhow::Result<Arc<Instance>> {
    let v: serde_json::Value = serde_json::from_str(cfg_s)?;
    LOG_INIT.get_or_init(|| {
        let lvl = v.get("log").and_then(|l| l.as_str()).unwrap_or("info,quinn=warn,rustls=warn,mainline=warn").to_string();
        #[cfg(target_os = "android")]
        let _ = tracing_subscriber::fmt().with_env_filter(lvl).with_ansi(false).without_time().with_writer(logcat::Logcat::default).try_init();
        #[cfg(not(target_os = "android"))]
        let _ = tracing_subscriber::fmt().with_env_filter(lvl).with_writer(std::io::stderr).try_init();
    });
    let mut cfg: NodeConfig = serde_json::from_value(v)?;
    if let Some(l) = cfg.lang.as_deref() {
        lumora_core::i18n::set_lang(l);
    }
    if cfg.data_dir.as_os_str().is_empty() {
        cfg.data_dir = NodeConfig::default().data_dir;
    }
    let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(4).enable_all().thread_name("lumora").build()?;
    let node = rt.block_on(Node::start(cfg))?;
    // probe the OS H.264 codec now (cached per device), so a call never waits for it
    #[cfg(feature = "media")]
    lumora_core::node::media_pipe::warm_up(&node);
    let events = Mutex::new(node.subscribe());
    let handle = rt.handle().clone();
    Ok(Arc::new(Instance { rt: Mutex::new(Some(rt)), handle, node, events, stop: watch::channel(false).0 }))
}

/// Is a passphrase required to unlock `data_dir`? 1 yes, 0 no, -1 no identity yet.
///
/// # Safety
/// `data_dir` must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn lumora_needs_passphrase(data_dir: *const c_char) -> i32 {
    guard(
        || {
            if data_dir.is_null() {
                return -1;
            }
            let d = std::path::PathBuf::from(CStr::from_ptr(data_dir).to_string_lossy().to_string());
            if !lumora_core::keystore::exists(&d) {
                return -1;
            }
            lumora_core::keystore::needs_passphrase(&d) as i32
        },
        || -1,
    )
}

/// "Forgot password": does the recovery `phrase` belong to the locked identity in
/// `data_dir`? 1 yes, 0 no (a different account), -1 can't tell (older keystore, no
/// identity, or not a valid phrase).
///
/// # Safety
/// `data_dir` and `phrase` must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn lumora_phrase_matches(data_dir: *const c_char, phrase: *const c_char) -> i32 {
    guard(
        || {
            if data_dir.is_null() || phrase.is_null() {
                return -1;
            }
            let d = std::path::PathBuf::from(CStr::from_ptr(data_dir).to_string_lossy().to_string());
            let p = zeroize::Zeroizing::new(CStr::from_ptr(phrase).to_string_lossy().to_string());
            match lumora_core::keystore::phrase_matches(&d, &p) {
                Some(true) => 1,
                Some(false) => 0,
                None => -1,
            }
        },
        || -1,
    )
}

/// Blocking JSON request. Returns a heap string (free with `lumora_free`).
/// A request still running when `lumora_stop` is called returns an error at once.
///
/// # Safety
/// `req` must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn lumora_request(req: *const c_char) -> *mut c_char {
    let id: OnceLock<serde_json::Value> = OnceLock::new();
    guard(
        || {
            let Some(i) = inst() else { return internal_error(None, "node not started") };
            if req.is_null() {
                return internal_error(None, "null request");
            }
            let s = CStr::from_ptr(req).to_string_lossy().to_string();
            let v: serde_json::Value = match serde_json::from_str(&s) {
                Ok(v) => v,
                Err(e) => return internal_error(None, &format!("bad json: {e}")),
            };
            if let Some(x) = v.get("id") {
                let _ = id.set(x.clone());
            }
            let node = i.node.clone();
            match i.block_on(lumora_core::api::handle(&node, &v)) {
                Some(resp) => to_c(resp.to_string()),
                None => internal_error(v.get("id"), "node stopping"),
            }
        },
        || internal_error(id.get(), "panic while handling the request"),
    )
}

/// Wait up to `timeout_ms` for the next event; NULL on timeout, when the node isn't
/// running, or as soon as `lumora_stop` is called.
#[no_mangle]
pub extern "C" fn lumora_next_event(timeout_ms: i32) -> *mut c_char {
    guard(
        || {
            let Some(i) = inst() else { return std::ptr::null_mut() };
            let mut rx = i.events.lock();
            let wait = Duration::from_millis(timeout_ms.max(0) as u64);
            let r = i
                .block_on(async {
                    match tokio::time::timeout(wait, rx.recv()).await {
                        Ok(Ok(v)) => Some(v),
                        Ok(Err(broadcast::error::RecvError::Lagged(n))) => Some(serde_json::json!({"event": "lagged", "missed": n})),
                        Ok(Err(_)) | Err(_) => None,
                    }
                })
                .flatten();
            match r {
                Some(v) => to_c(v.to_string()),
                None => std::ptr::null_mut(),
            }
        },
        std::ptr::null_mut,
    )
}

/// Copy the latest RGBA frame of `stream` into `dst` (capacity `cap`).
/// Returns bytes written, 0 if no new frame since `last_seq`, or -needed if `cap` is too
/// small (a NULL `dst` counts as capacity 0, so it can be used to ask for the size).
/// `w`, `h` and `seq` receive the frame's size and sequence number; NULL ones are skipped.
///
/// # Safety
/// `dst` must be NULL or point to `cap` writable bytes; `w`, `h`, `seq` must be NULL or valid pointers.
#[no_mangle]
pub unsafe extern "C" fn lumora_frame(stream: u32, last_seq: u64, dst: *mut u8, cap: u32, w: *mut u32, h: *mut u32, seq: *mut u64) -> i64 {
    guard(
        || {
            let Some(i) = inst() else { return 0 };
            let slot = i.node.remote.frames.lock().get(&stream).cloned();
            let Some(f) = slot else { return 0 };
            if f.seq <= last_seq {
                return 0;
            }
            let n = f.rgba.len();
            if n == 0 {
                return 0;
            }
            let cap = if dst.is_null() { 0 } else { cap as usize };
            if n > cap {
                return -(n as i64);
            }
            std::ptr::copy_nonoverlapping(f.rgba.as_ptr(), dst, n);
            if !w.is_null() {
                *w = f.w;
            }
            if !h.is_null() {
                *h = f.h;
            }
            if !seq.is_null() {
                *seq = f.seq;
            }
            n as i64
        },
        || 0,
    )
}

/// # Safety
/// `s` must come from this library.
#[no_mangle]
pub unsafe extern "C" fn lumora_free(s: *mut c_char) {
    guard(
        || {
            if !s.is_null() {
                drop(CString::from_raw(s));
            }
        },
        || (),
    )
}

/// Last error message (owned by the library; valid until the next error). Plain,
/// localized text meant for the user.
#[no_mangle]
pub extern "C" fn lumora_last_error() -> *const c_char {
    guard(|| LAST_ERROR.lock().as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null()), std::ptr::null)
}

/// Last error as JSON `{"error", "code", "detail"?}` (owned by the library; valid until
/// the next error). `detail` holds technical information for a "Technical details" view.
#[no_mangle]
pub extern "C" fn lumora_last_error_json() -> *const c_char {
    guard(|| LAST_ERROR_JSON.lock().as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null()), std::ptr::null)
}

/// Stop the node and its runtime. Blocked `lumora_next_event` / `lumora_request` calls
/// return at once; this waits for calls in progress (up to 3 s), lets the network
/// endpoint say goodbye, shuts the runtime down (up to 2 s for blocking work) and waits
/// for the node to be released (up to 2 s). A `lumora_start` issued meanwhile waits
/// until this has finished, so the data folder is never opened by two nodes.
#[no_mangle]
pub extern "C" fn lumora_stop() {
    guard(
        || {
            let _life = LIFECYCLE.lock();
            // new calls see "not started" from here on
            let Some(i) = INSTANCE.lock().take() else { return };
            i.stop.send_replace(true);
            // calls in progress hold a clone of the instance
            let deadline = Instant::now() + IN_FLIGHT_WAIT;
            while Arc::strong_count(&i) > 1 && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(2));
            }
            if Arc::strong_count(&i) > 1 {
                tracing::warn!("lumora_stop: {} call(s) still running, shutting down anyway", Arc::strong_count(&i) - 1);
            }
            i.node.shutdown();
            let rt = i.rt.lock().take();
            if let Some(rt) = rt {
                // flush the connection-close frames to peers, then cancel every task
                let ep = i.node.net.endpoint.clone();
                rt.block_on(async move {
                    let _ = tokio::time::timeout(Duration::from_millis(500), ep.wait_idle()).await;
                });
                rt.shutdown_timeout(Duration::from_secs(2));
            }
            // threads outside the runtime may still hold the node briefly: give them a
            // moment so its database is closed before a new start can open the folder
            let node = Arc::downgrade(&i.node);
            drop(i);
            let deadline = Instant::now() + NODE_RELEASE_WAIT;
            while node.strong_count() > 0 && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(5));
            }
            if node.strong_count() > 0 {
                tracing::warn!("lumora_stop: the stopped node is still referenced");
            }
        },
        || tracing::error!("lumora_stop panicked"),
    )
}

/// Push one packed RGBA/BGRA camera frame into an active video call (prefer
/// [`lumora_push_camera_yuv`], which skips the RGB round trip and rotates).
/// `format`: 0 = RGBA, 1 = BGRA. Returns 0 accepted, 1 dropped (encoder busy /
/// no call wants the camera), -1 bad arguments.
///
/// # Safety
/// `data` must point to `len` readable bytes (`len >= stride * height`).
#[cfg(feature = "media")]
#[no_mangle]
pub unsafe extern "C" fn lumora_push_camera_frame(width: u32, height: u32, stride: u32, format: u32, data: *const u8, len: usize) -> i32 {
    guard(|| push_camera_frame(width, height, stride, format, data, len), || -1)
}

#[cfg(feature = "media")]
unsafe fn push_camera_frame(width: u32, height: u32, stride: u32, format: u32, data: *const u8, len: usize) -> i32 {
    if data.is_null() || width == 0 || height == 0 || (stride as usize) * (height as usize) > len {
        return -1;
    }
    let bytes = std::slice::from_raw_parts(data, len).to_vec();
    let f = lumora_media::Frame {
        width,
        height,
        stride,
        format: if format == 1 { lumora_media::PixelFormat::Bgra } else { lumora_media::PixelFormat::Rgba },
        data: bytes.into(),
        ts_us: lumora_media::now_us(),
    };
    match lumora_core::node::media_pipe::push_camera_frame(f) {
        0 => 0,
        _ => 1,
    }
}

/// Flag OR-ed into `rotation` of [`lumora_push_camera_yuv`]: the picture uses
/// full-range levels (0..255, Android YUV_420_888 / Apple `…FullRange`).
#[cfg(feature = "media")]
pub const LUMORA_CAMERA_FULL_RANGE: u32 = 0x1_0000;

#[cfg(feature = "media")]
static CAMERA_ADAPT: OnceLock<Mutex<lumora_media::camera_in::CameraAdapt>> = OnceLock::new();

/// Convert one platform picture, hand it to the call and feed the 720p/480p adaptation.
#[cfg(feature = "media")]
fn push_camera_planes(p: &lumora_media::camera_in::YuvPlanes<'_>, rotation: u32) -> i32 {
    let adapt = CAMERA_ADAPT.get_or_init(|| Mutex::new(lumora_media::camera_in::CameraAdapt::new()));
    let max_short = adapt.lock().max_short();
    let full = rotation & LUMORA_CAMERA_FULL_RANGE != 0;
    let Ok(f) = lumora_media::camera_in::yuv420_to_frame(p, rotation & 0xffff, full, max_short, lumora_media::now_us()) else { return -1 };
    match lumora_core::node::media_pipe::push_camera_frame(f) {
        0 => {
            adapt.lock().record(false);
            0
        }
        1 => {
            adapt.lock().record(true);
            1
        }
        _ => {
            // Nobody wants the camera (call ended / camera off): start fresh next time.
            adapt.lock().reset();
            2
        }
    }
}

/// Push one 4:2:0 camera picture straight from the platform capture (Android
/// CameraX, iOS/macOS AVFoundation, Windows Media Foundation) into the active
/// video call. The core rotates it `rotation & 0xffff` degrees clockwise
/// (0/90/180/270) so it is upright, converts it to I420 in one pass (no RGB) and
/// downscales 720p → 480p while the encoder lags. OR [`LUMORA_CAMERA_FULL_RANGE`]
/// into `rotation` for full-range input.
///
/// Layouts: I420 = separate `u`/`v` planes, `uv_pixel_stride` 1; NV12 = `u` the
/// CbCr plane, `v = u + 1`, `uv_pixel_stride` 2; NV21 = `v` the CrCb plane,
/// `u = v + 1`, 2.
///
/// Returns 0 accepted, 1 dropped (encoder busy), 2 dropped (no call wants the
/// camera), -1 bad arguments.
///
/// # Safety
/// The planes must be readable for the geometry given (`y_stride * (height-1) + width`
/// bytes for Y, `stride * (ceil(height/2)-1) + (ceil(width/2)-1) * uv_pixel_stride + 1` for U and V).
#[cfg(feature = "media")]
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn lumora_push_camera_yuv(
    width: u32,
    height: u32,
    y: *const u8,
    y_stride: u32,
    u: *const u8,
    u_stride: u32,
    v: *const u8,
    v_stride: u32,
    uv_pixel_stride: u32,
    rotation: u32,
) -> i32 {
    guard(|| push_camera_yuv(width, height, y, y_stride, u, u_stride, v, v_stride, uv_pixel_stride, rotation), || -1)
}

#[cfg(feature = "media")]
#[allow(clippy::too_many_arguments)]
unsafe fn push_camera_yuv(
    width: u32,
    height: u32,
    y: *const u8,
    y_stride: u32,
    u: *const u8,
    u_stride: u32,
    v: *const u8,
    v_stride: u32,
    uv_pixel_stride: u32,
    rotation: u32,
) -> i32 {
    if y.is_null() || u.is_null() || v.is_null() || width < 16 || height < 16 || width > 4096 || height > 4096 || uv_pixel_stride == 0 || uv_pixel_stride > 4 {
        return -1;
    }
    let (w, h) = (width as usize, height as usize);
    let (ys, us, vs, step) = (y_stride as usize, u_stride as usize, v_stride as usize, uv_pixel_stride as usize);
    if ys < w || us == 0 || vs == 0 {
        return -1;
    }
    let (yl, ul, vl) = lumora_media::camera_in::YuvPlanes::required(w, h, ys, us, vs, step);
    let p = lumora_media::camera_in::YuvPlanes {
        width: w,
        height: h,
        y: std::slice::from_raw_parts(y, yl),
        y_stride: ys,
        u: std::slice::from_raw_parts(u, ul),
        u_stride: us,
        v: std::slice::from_raw_parts(v, vl),
        v_stride: vs,
        uv_step: step,
    };
    push_camera_planes(&p, rotation)
}

/// Android: `LumoraNative.pushCameraYuv(w, h, y, yStride, u, uStride, v, vStride,
/// uvPixelStride, rotation)` with the direct `ByteBuffer` planes of a CameraX
/// `ImageProxy` (YUV_420_888) — no copy on the Java side. Same results as
/// [`lumora_push_camera_yuv`].
///
/// # Safety
/// Called by the JVM with a valid `JNIEnv*` and direct `ByteBuffer`s.
#[cfg(all(feature = "media", target_os = "android"))]
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "system" fn Java_vn_lumora_lumora_LumoraNative_pushCameraYuv(
    env: *mut *const *const std::ffi::c_void,
    _class: *mut std::ffi::c_void,
    width: i32,
    height: i32,
    y: *mut std::ffi::c_void,
    y_stride: i32,
    u: *mut std::ffi::c_void,
    u_stride: i32,
    v: *mut std::ffi::c_void,
    v_stride: i32,
    uv_pixel_stride: i32,
    rotation: i32,
) -> i32 {
    // never unwind into the JVM
    guard(
        || {
            // JNI function table (jni.h): 230 = GetDirectBufferAddress, 231 = GetDirectBufferCapacity.
            unsafe fn direct(env: *mut *const *const std::ffi::c_void, buf: *mut std::ffi::c_void) -> Option<&'static [u8]> {
                if env.is_null() || buf.is_null() {
                    return None;
                }
                let table = *env;
                let addr: extern "system" fn(*mut *const *const std::ffi::c_void, *mut std::ffi::c_void) -> *mut std::ffi::c_void = std::mem::transmute(*table.add(230));
                let cap: extern "system" fn(*mut *const *const std::ffi::c_void, *mut std::ffi::c_void) -> i64 = std::mem::transmute(*table.add(231));
                let (p, n) = (addr(env, buf), cap(env, buf));
                (!p.is_null() && n > 0).then(|| std::slice::from_raw_parts(p as *const u8, n as usize))
            }
            if width < 16 || height < 16 || width > 4096 || height > 4096 || y_stride <= 0 || u_stride <= 0 || v_stride <= 0 || !(1..=4).contains(&uv_pixel_stride) {
                return -1;
            }
            let (Some(yb), Some(ub), Some(vb)) = (direct(env, y), direct(env, u), direct(env, v)) else { return -1 };
            let p = lumora_media::camera_in::YuvPlanes {
                width: width as usize,
                height: height as usize,
                y: yb,
                y_stride: y_stride as usize,
                u: ub,
                u_stride: u_stride as usize,
                v: vb,
                v_stride: v_stride as usize,
                uv_step: uv_pixel_stride as usize,
            };
            // Lengths are checked by the conversion (`YuvPlanes::check`).
            push_camera_planes(&p, rotation as u32)
        },
        || -1,
    )
}

/// A Bonjour/DNS-SD sighting of another Lumora device (iOS: `NWBrowser` in
/// `LumoraBonjour.swift`). `hint` is the advertised instance name / TXT `id`
/// (16 hex chars), `ip` an IPv4/IPv6 literal, `port` its QUIC port.
/// Returns 1 if recorded, 0 if ignored (bad input or core not running).
///
/// # Safety
/// `hint` and `ip` must be valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn lumora_lan_candidate(hint: *const c_char, ip: *const c_char, port: u16) -> i32 {
    guard(
        || {
            if hint.is_null() || ip.is_null() || port == 0 {
                return 0;
            }
            let Some(i) = inst() else { return 0 };
            let hint = CStr::from_ptr(hint).to_string_lossy();
            let Ok(ip) = CStr::from_ptr(ip).to_string_lossy().trim().trim_matches(['[', ']']).parse::<std::net::IpAddr>() else { return 0 };
            i.node.net.lan.add_hint(&hint, vec![std::net::SocketAddr::new(ip, port)]) as i32
        },
        || 0,
    )
}

/// Push one *screen* frame produced by the host app (iOS: ReplayKit broadcast
/// frames relayed from the extension through the App Group; also usable in tests).
/// The remote-desktop host reads these through `lumora_media::open_capturer`, which
/// returns the external capturer on iOS and Android.
/// `format`: 0 = RGBA, 1 = BGRA. Returns 0 on success, -1 on bad arguments.
///
/// # Safety
/// `data` must point to `len` readable bytes (`len >= stride * height`).
#[cfg(feature = "media")]
#[no_mangle]
pub unsafe extern "C" fn lumora_push_screen_frame(width: u32, height: u32, stride: u32, format: u32, data: *const u8, len: usize) -> i32 {
    guard(
        || {
            if data.is_null() || width == 0 || height == 0 || (stride as usize) * (height as usize) > len {
                return -1;
            }
            let fmt = if format == 1 { lumora_media::PixelFormat::Bgra } else { lumora_media::PixelFormat::Rgba };
            let data = std::slice::from_raw_parts(data, len);
            match lumora_media::push_external_frame(width, height, stride, fmt, data, lumora_media::now_us()) {
                Ok(()) => 0,
                Err(_) => -1,
            }
        },
        || -1,
    )
}

/// Describe the externally captured screen (pixel size + UI scale) before the
/// first frame arrives, so the viewer gets the right aspect ratio immediately.
#[cfg(feature = "media")]
#[no_mangle]
pub extern "C" fn lumora_set_screen_display(width: u32, height: u32, scale: f32) {
    guard(
        || {
            if width == 0 || height == 0 {
                return;
            }
            lumora_media::set_external_display(lumora_media::DisplayInfo {
                name: if cfg!(target_os = "ios") { "iPhone".into() } else { "external".into() },
                width,
                height,
                scale: if scale.is_finite() && scale > 0.0 { scale } else { 1.0 },
                ..Default::default()
            });
        },
        || (),
    )
}

/// The external screen source stopped (e.g. the user ended the ReplayKit broadcast).
#[cfg(feature = "media")]
#[no_mangle]
pub extern "C" fn lumora_clear_screen_frames() {
    guard(lumora_media::clear_external_frames, || ())
}

/// Android discards stderr: route core logs to the system log (logcat, tag "lumora").
#[cfg(target_os = "android")]
mod logcat {
    use std::ffi::CString;
    use std::os::raw::{c_char, c_int};

    #[link(name = "log")]
    extern "C" {
        fn __android_log_write(prio: c_int, tag: *const c_char, text: *const c_char) -> c_int;
    }

    #[derive(Default)]
    pub struct Logcat(Vec<u8>);

    impl std::io::Write for Logcat {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            if self.0.is_empty() {
                return Ok(());
            }
            let text = String::from_utf8_lossy(&self.0).trim_end().replace('\0', "");
            self.0.clear();
            let prio = if text.contains("ERROR") { 6 } else if text.contains("WARN") { 5 } else { 4 };
            if let Ok(c) = CString::new(text) {
                // SAFETY: both pointers are valid NUL-terminated strings for the call's duration.
                unsafe { __android_log_write(prio, c"lumora".as_ptr(), c.as_ptr()) };
            }
            Ok(())
        }
    }

    impl Drop for Logcat {
        fn drop(&mut self) {
            let _ = std::io::Write::flush(self);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn take(p: *mut c_char) -> Option<String> {
        // SAFETY: `p` is NULL or came from this library.
        (!p.is_null()).then(|| unsafe {
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            lumora_free(p);
            s
        })
    }

    #[test]
    fn panics_become_error_values() {
        assert_eq!(guard(|| -> i32 { panic!("boom") }, || -7), -7);
        assert_eq!(guard(|| 3, || -7), 3);
    }

    /// One test drives the process-wide instance (tests run in parallel threads).
    #[test]
    fn stop_wakes_waiters_and_the_data_dir_can_be_reopened() {
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir().join(format!("lumora-ffi-test-{}-{nanos}", std::process::id()));
        let cfg = serde_json::json!({
            "data_dir": dir, "log": "warn", "enable_lan": false, "enable_upnp": false, "enable_dht": false,
            "enable_nostr": false, "relays": [], "nostr": [], "stun": [],
        });
        let cfg = CString::new(cfg.to_string()).unwrap();
        let last_error = || unsafe { CStr::from_ptr(lumora_last_error_json()).to_string_lossy().into_owned() };
        unsafe {
            // not running: calls answer without blocking
            assert!(lumora_next_event(10).is_null());
            assert!(take(lumora_request(c"{\"id\":1,\"cmd\":\"ping\"}".as_ptr())).unwrap().contains("not started"));

            assert_eq!(lumora_start(cfg.as_ptr()), 0, "{}", last_error());
            assert_eq!(lumora_start(cfg.as_ptr()), 1, "already running");
            let pong = take(lumora_request(c"{\"id\":7,\"cmd\":\"ping\"}".as_ptr())).unwrap();
            assert!(pong.contains("pong") && pong.contains("\"id\":7"), "{pong}");

            // lumora_frame: NULL out-pointers are skipped, a NULL dst asks for the size
            let node = inst().unwrap().node.clone();
            node.remote.frames.lock().insert(9, lumora_core::node::remote::FrameSlot { w: 2, h: 2, rgba: vec![5u8; 16].into(), seq: 3 });
            let (mut w, mut h, mut seq) = (0u32, 0u32, 0u64);
            assert_eq!(lumora_frame(9, 0, std::ptr::null_mut(), 1024, &mut w, &mut h, &mut seq), -16);
            let mut buf = [0u8; 16];
            assert_eq!(lumora_frame(9, 0, buf.as_mut_ptr(), 8, &mut w, &mut h, &mut seq), -16);
            assert_eq!(lumora_frame(9, 0, buf.as_mut_ptr(), 16, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut()), 16);
            assert_eq!(buf, [5u8; 16]);
            assert_eq!(lumora_frame(9, 0, buf.as_mut_ptr(), 16, &mut w, &mut h, &mut seq), 16);
            assert_eq!((w, h, seq), (2, 2, 3));
            assert_eq!(lumora_frame(9, 3, buf.as_mut_ptr(), 16, &mut w, &mut h, &mut seq), 0, "no newer frame");
            let node_alive = Arc::downgrade(&node);
            drop(node);

            // the event isolate is parked in lumora_next_event(10 s)
            while take(lumora_next_event(50)).is_some() {}
            let waiter = std::thread::spawn(|| loop {
                if take(lumora_next_event(10_000)).is_none() {
                    return Instant::now();
                }
            });
            std::thread::sleep(Duration::from_millis(300));
            let t = Instant::now();
            lumora_stop();
            let stop_took = t.elapsed();
            let woke = waiter.join().unwrap();
            assert!(woke.saturating_duration_since(t) < Duration::from_millis(1500), "waiter woke {:?} after stop", woke - t);
            assert!(stop_took < Duration::from_secs(5), "stop took {stop_took:?}");
            assert!(inst().is_none());
            assert!(node_alive.upgrade().is_none(), "the old node is still alive after lumora_stop");
            lumora_stop(); // twice is harmless

            // same folder again right away
            assert_eq!(lumora_start(cfg.as_ptr()), 0, "{}", last_error());
            // a start racing a stop either finds the node running or waits for the stop
            let stopper = std::thread::spawn(|| lumora_stop());
            std::thread::sleep(Duration::from_millis(1));
            let r = lumora_start(cfg.as_ptr());
            stopper.join().unwrap();
            assert!(r == 0 || r == 1, "start during stop: {r} {}", last_error());
            lumora_stop();
            assert_eq!(lumora_start(cfg.as_ptr()), 0, "{}", last_error());
            lumora_stop();
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}

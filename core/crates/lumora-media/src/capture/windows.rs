//! Windows screen capture.
//!
//! * **DXGI Desktop Duplication** (Windows 8+, preferred): the duplicated
//!   desktop texture is copied into a CPU-readable staging texture, mapped,
//!   rotated to desktop orientation if the monitor is rotated, and the mouse
//!   cursor is composited on the CPU. Duplication is recreated transparently
//!   after `DXGI_ERROR_ACCESS_LOST` (resolution change, fullscreen switch,
//!   secure desktop).
//! * **GDI `BitBlt`** (fallback): used when duplication is unavailable, e.g.
//!   some RDP sessions, Hyper-V basic display, Wine, or when the GPU driver
//!   refuses `DuplicateOutput`. Slower (CPU copy of the whole monitor every
//!   frame) but works almost everywhere. Force it with `LUMORA_CAPTURE=gdi`.
//!
//! Coordinates: the process is made per-monitor DPI aware (v2) before any
//! enumeration so that monitor rectangles, cursor positions and `SendInput`
//! all use the same physical-pixel virtual-desktop space.
//!
//! Limitations (both back-ends): the secure desktop (UAC prompt, Ctrl+Alt+Del,
//! lock screen) cannot be captured by a normal user process; frames simply
//! stop until the user desktop is back. Capturing it would need a SYSTEM
//! service that follows the input desktop (`OpenInputDesktop`).

use std::sync::Once;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context};
use bytes::Bytes;
use windows::core::{s, w, Interface};
use windows::Win32::Foundation::{E_ACCESSDENIED, HMODULE, LPARAM, RECT};
use windows::Win32::Graphics::Direct3D::{
    D3D_DRIVER_TYPE_UNKNOWN, D3D_FEATURE_LEVEL, D3D_FEATURE_LEVEL_10_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_11_0,
    D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_9_1, D3D_FEATURE_LEVEL_9_2, D3D_FEATURE_LEVEL_9_3,
};
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D, D3D11_CPU_ACCESS_READ,
    D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_MAPPED_SUBRESOURCE, D3D11_MAP_READ, D3D11_SDK_VERSION,
    D3D11_TEXTURE2D_DESC, D3D11_USAGE_STAGING,
};
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_MODE_ROTATION, DXGI_MODE_ROTATION_ROTATE180, DXGI_MODE_ROTATION_ROTATE270,
    DXGI_MODE_ROTATION_ROTATE90, DXGI_SAMPLE_DESC,
};
use windows::Win32::Graphics::Dxgi::{
    CreateDXGIFactory1, IDXGIAdapter1, IDXGIFactory1, IDXGIOutput, IDXGIOutput1, IDXGIOutputDuplication,
    IDXGIResource, DXGI_ERROR_ACCESS_LOST, DXGI_ERROR_NOT_FOUND, DXGI_ERROR_WAIT_TIMEOUT, DXGI_OUTDUPL_FRAME_INFO,
    DXGI_OUTPUT_DESC,
};
use windows::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, EnumDisplayMonitors, GdiFlush, GetDC,
    GetMonitorInfoW, GetObjectW, ReleaseDC, SelectObject, BITMAP, BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
    DIB_RGB_COLORS, HBITMAP, HDC, HGDIOBJ, HMONITOR, MONITORINFO, MONITORINFOEXW, SRCCOPY,
};
use windows::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress, LoadLibraryW};
use windows::Win32::UI::WindowsAndMessaging::{
    DrawIconEx, GetCursorInfo, GetIconInfo, LoadCursorW, SetProcessDPIAware, IDC_ARROW, CURSORINFO, CURSOR_SHOWING, DI_NORMAL, HICON,
    ICONINFO, MONITORINFOF_PRIMARY,
};

use crate::{CaptureOptions, Capturer, DisplayInfo, Frame, PixelFormat};

/// Re-deliver the last frame after this long without screen changes so a
/// keyframe request from the viewer is always answered on a static screen.
const IDLE_RESEND: Duration = Duration::from_millis(1000);

// ---------------------------------------------------------------------------
// Process-wide setup
// ---------------------------------------------------------------------------

/// Make the process per-monitor DPI aware (v2) exactly once, before any
/// monitor geometry is read. Without this, a process on a 150% display gets
/// DPI-virtualised (logical) coordinates from `GetSystemMetrics`/`GetCursorInfo`
/// while DXGI reports physical pixels, so clicks land in the wrong place.
///
/// `SetProcessDpiAwarenessContext` only exists on Windows 10 1703+, so it is
/// resolved at run time (a static import would stop the program from loading
/// on Windows 8/8.1); older systems fall back to `SetProcessDPIAware`.
/// If the executable's manifest already set an awareness (Flutter's runner
/// does: PerMonitorV2) the call fails harmlessly with ERROR_ACCESS_DENIED.
pub(crate) fn ensure_dpi_awareness() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        // SAFETY: GetProcAddress result is transmuted to the documented signature
        // `BOOL SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT)`.
        unsafe {
            let user32 = GetModuleHandleW(w!("user32.dll")).or_else(|_| LoadLibraryW(w!("user32.dll")));
            if let Ok(h) = user32 {
                if let Some(p) = GetProcAddress(h, s!("SetProcessDpiAwarenessContext")) {
                    type SetCtx = unsafe extern "system" fn(isize) -> i32;
                    let f: SetCtx = std::mem::transmute(p);
                    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 == (HANDLE)-4
                    let ok = f(-4) != 0;
                    tracing::debug!("SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2) -> {ok}");
                    return;
                }
            }
            let _ = SetProcessDPIAware();
            tracing::debug!("SetProcessDpiAwarenessContext unavailable; used SetProcessDPIAware");
        }
    });
}

/// `Some(version)` when running under Wine (ntdll exports `wine_get_version`).
pub(crate) fn wine_version() -> Option<String> {
    // SAFETY: documented Wine export `const char* wine_get_version(void)`.
    unsafe {
        let ntdll = GetModuleHandleW(w!("ntdll.dll")).ok()?;
        let p = GetProcAddress(ntdll, s!("wine_get_version"))?;
        type GetVer = unsafe extern "C" fn() -> *const std::ffi::c_char;
        let f: GetVer = std::mem::transmute(p);
        let s = f();
        if s.is_null() {
            return Some(String::new());
        }
        Some(std::ffi::CStr::from_ptr(s).to_string_lossy().into_owned())
    }
}

// ---------------------------------------------------------------------------
// Display enumeration
// ---------------------------------------------------------------------------

struct OutputRef {
    adapter: IDXGIAdapter1,
    output: IDXGIOutput,
    info: DisplayInfo,
}

fn wide_to_string(w: &[u16]) -> String {
    let n = w.iter().position(|&c| c == 0).unwrap_or(w.len());
    String::from_utf16_lossy(&w[..n])
}

fn info_from_rect(index: u32, name: String, r: RECT, primary: bool) -> DisplayInfo {
    DisplayInfo {
        index,
        name,
        width: (r.right - r.left).max(0) as u32,
        height: (r.bottom - r.top).max(0) as u32,
        x: r.left,
        y: r.top,
        // Per-monitor-v2 aware: everything (capture, cursor, SendInput) is in
        // physical pixels, so the input coordinate space has scale 1.
        scale: 1.0,
        primary,
    }
}

fn enumerate_dxgi() -> anyhow::Result<Vec<OutputRef>> {
    ensure_dpi_awareness();
    let mut v = Vec::new();
    // SAFETY: plain COM calls; every returned interface is owned.
    unsafe {
        let factory: IDXGIFactory1 = CreateDXGIFactory1().context("CreateDXGIFactory1 failed")?;
        let mut ai = 0;
        loop {
            let adapter = match factory.EnumAdapters1(ai) {
                Ok(a) => a,
                Err(e) if e.code() == DXGI_ERROR_NOT_FOUND => break,
                Err(e) => return Err(anyhow!("EnumAdapters1 failed: {e}")),
            };
            let mut oi = 0;
            loop {
                let output = match adapter.EnumOutputs(oi) {
                    Ok(o) => o,
                    Err(_) => break,
                };
                oi += 1;
                let Ok(desc) = output.GetDesc() else { continue };
                let desc: DXGI_OUTPUT_DESC = desc;
                if desc.AttachedToDesktop.as_bool() {
                    let r = desc.DesktopCoordinates;
                    // The primary monitor is the one at the virtual-desktop origin.
                    let primary = r.left == 0 && r.top == 0;
                    let info = info_from_rect(v.len() as u32, wide_to_string(&desc.DeviceName), r, primary);
                    v.push(OutputRef { adapter: adapter.clone(), output, info });
                }
            }
            ai += 1;
        }
    }
    Ok(v)
}

fn enumerate_gdi() -> Vec<DisplayInfo> {
    ensure_dpi_awareness();
    unsafe extern "system" fn cb(m: HMONITOR, _: HDC, _: *mut RECT, data: LPARAM) -> windows::core::BOOL {
        // SAFETY: `data` is the &mut Vec passed below, alive for the whole enumeration.
        let v = unsafe { &mut *(data.0 as *mut Vec<DisplayInfo>) };
        let mut mi = MONITORINFOEXW::default();
        mi.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
        // SAFETY: MONITORINFOEXW starts with MONITORINFO and cbSize says which one it is.
        if unsafe { GetMonitorInfoW(m, &mut mi as *mut MONITORINFOEXW as *mut MONITORINFO) }.as_bool() {
            let primary = mi.monitorInfo.dwFlags & MONITORINFOF_PRIMARY != 0;
            v.push(info_from_rect(0, wide_to_string(&mi.szDevice), mi.monitorInfo.rcMonitor, primary));
        }
        true.into()
    }
    let mut v: Vec<DisplayInfo> = Vec::new();
    // SAFETY: callback only runs during this call.
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(cb), LPARAM(&mut v as *mut Vec<DisplayInfo> as isize));
    }
    // Primary first (matches DXGI order on single-GPU systems), then left-to-right.
    v.sort_by_key(|d| (!d.primary, d.x, d.y));
    for (i, d) in v.iter_mut().enumerate() {
        d.index = i as u32;
    }
    v
}

/// Displays as seen by the capture back-ends: DXGI outputs when available,
/// otherwise GDI monitors. Indices are what [`crate::open_capturer`] takes.
pub fn list_displays() -> Vec<DisplayInfo> {
    match enumerate_dxgi() {
        Ok(v) if !v.is_empty() => v.into_iter().map(|o| o.info).collect(),
        _ => enumerate_gdi(),
    }
}

/// Open the best capturer: DXGI duplication, falling back to GDI BitBlt.
/// `LUMORA_CAPTURE=gdi|dxgi` forces one back-end.
pub fn open(display: u32, opts: &CaptureOptions) -> anyhow::Result<Box<dyn Capturer>> {
    ensure_dpi_awareness();
    let forced = std::env::var("LUMORA_CAPTURE").unwrap_or_default().to_ascii_lowercase();
    if forced == "gdi" {
        return Ok(Box::new(GdiCapturer::open(display, opts)?));
    }
    match DxgiCapturer::open(display, opts) {
        Ok(c) => Ok(Box::new(c)),
        Err(e) if forced == "dxgi" => Err(e),
        Err(e) => {
            tracing::warn!("DXGI Desktop Duplication unavailable ({e:#}); falling back to GDI BitBlt capture");
            let g = GdiCapturer::open(display, opts).map_err(|ge| {
                anyhow!(
                    "screen capture unavailable: DXGI Desktop Duplication failed ({e:#}) and the GDI fallback \
                     failed too ({ge:#})"
                )
            })?;
            Ok(Box::new(g))
        }
    }
}

/// Which back-end [`open`] would pick right now (for diagnostics).
/// `Ok("dxgi")`, or `Err(reason)` when only GDI is usable.
pub(crate) fn probe_dxgi() -> Result<(), String> {
    DxgiCapturer::open(0, &CaptureOptions::default()).map(|_| ()).map_err(|e| format!("{e:#}"))
}

// ---------------------------------------------------------------------------
// Cursor compositing (shared by both back-ends)
// ---------------------------------------------------------------------------

struct CursorImage {
    handle: isize,
    w: i32,
    h: i32,
    hot_x: i32,
    hot_y: i32,
    /// BGRA, straight alpha.
    px: Vec<u8>,
    /// Per pixel: true = XOR/invert the screen (monochrome I-beam etc.).
    invert: Vec<bool>,
}

/// Off-screen 32-bit top-down DIB selected into a memory DC.
struct Dib {
    dc: HDC,
    bmp: HBITMAP,
    old: HGDIOBJ,
    bits: *mut u8,
    w: i32,
    h: i32,
}

impl Dib {
    fn new(w: i32, h: i32) -> anyhow::Result<Self> {
        // SAFETY: standard GDI object creation; every handle is released in Drop.
        unsafe {
            let screen = GetDC(None);
            let dc = CreateCompatibleDC(Some(screen));
            ReleaseDC(None, screen);
            if dc.is_invalid() {
                anyhow::bail!("CreateCompatibleDC failed");
            }
            let bmi = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: w,
                    biHeight: -h, // top-down
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };
            let mut bits: *mut std::ffi::c_void = std::ptr::null_mut();
            let bmp = match CreateDIBSection(Some(dc), &bmi, DIB_RGB_COLORS, &mut bits, None, 0) {
                Ok(b) if !bits.is_null() => b,
                Ok(b) => {
                    let _ = DeleteObject(b.into());
                    let _ = DeleteDC(dc);
                    anyhow::bail!("CreateDIBSection returned no pixel buffer");
                }
                Err(e) => {
                    let _ = DeleteDC(dc);
                    anyhow::bail!("CreateDIBSection({w}x{h}) failed: {e}");
                }
            };
            let old = SelectObject(dc, bmp.into());
            Ok(Self { dc, bmp, old, bits: bits as *mut u8, w, h })
        }
    }

    fn bytes(&self) -> &[u8] {
        // SAFETY: the DIB section holds w*h*4 bytes (32 bpp rows are DWORD aligned) for our lifetime.
        unsafe { std::slice::from_raw_parts(self.bits, (self.w * self.h * 4) as usize) }
    }

    fn bytes_mut(&mut self) -> &mut [u8] {
        // SAFETY: as above, exclusive through &mut self.
        unsafe { std::slice::from_raw_parts_mut(self.bits, (self.w * self.h * 4) as usize) }
    }
}

impl Drop for Dib {
    fn drop(&mut self) {
        // SAFETY: handles created in `new`.
        unsafe {
            SelectObject(self.dc, self.old);
            let _ = DeleteObject(self.bmp.into());
            let _ = DeleteDC(self.dc);
        }
    }
}

fn render_cursor(hicon: HICON) -> Option<CursorImage> {
    match try_render_cursor(hicon) {
        Ok(c) => Some(c),
        Err(e) => {
            tracing::debug!("cursor image unavailable: {e}");
            None
        }
    }
}

fn try_render_cursor(hicon: HICON) -> Result<CursorImage, String> {
    // SAFETY: GetIconInfo returns two bitmaps we own and delete; DrawIconEx draws into our DIBs.
    unsafe {
        let mut ii = ICONINFO::default();
        GetIconInfo(hicon, &mut ii).map_err(|e| format!("GetIconInfo: {e}"))?;
        let color = !ii.hbmColor.is_invalid();
        let src = if color { ii.hbmColor } else { ii.hbmMask };
        let mut bm = BITMAP::default();
        let got = GetObjectW(src.into(), std::mem::size_of::<BITMAP>() as i32, Some(&mut bm as *mut BITMAP as *mut _));
        if !ii.hbmColor.is_invalid() {
            let _ = DeleteObject(ii.hbmColor.into());
        }
        if !ii.hbmMask.is_invalid() {
            let _ = DeleteObject(ii.hbmMask.into());
        }
        if got == 0 {
            return Err("GetObjectW failed".into());
        }
        let w = bm.bmWidth.clamp(1, 256);
        // A monochrome cursor's mask holds AND and XOR halves stacked vertically.
        let h = if color { bm.bmHeight } else { bm.bmHeight / 2 }.clamp(1, 256);
        let mut on_black = Dib::new(w, h).map_err(|e| format!("{e:#}"))?;
        let mut on_white = Dib::new(w, h).map_err(|e| format!("{e:#}"))?;
        on_black.bytes_mut().fill(0);
        on_white.bytes_mut().fill(255);
        DrawIconEx(on_black.dc, 0, 0, hicon, w, h, 0, None, DI_NORMAL).map_err(|e| format!("DrawIconEx: {e}"))?;
        DrawIconEx(on_white.dc, 0, 0, hicon, w, h, 0, None, DI_NORMAL).map_err(|e| format!("DrawIconEx: {e}"))?;
        let _ = GdiFlush();
        let (b, wh) = (on_black.bytes(), on_white.bytes());
        let n = (w * h) as usize;
        let mut px = vec![0u8; n * 4];
        let mut invert = vec![false; n];
        for (i, inv) in invert.iter_mut().enumerate() {
            let o = i * 4;
            let (kb, kw) = (&b[o..o + 3], &wh[o..o + 3]);
            if kb.iter().zip(kw).all(|(x, y)| x > y) {
                // white on black, black on white: an XOR (inverting) pixel
                *inv = true;
                continue;
            }
            // c_black = a*c, c_white = a*c + (1-a)*255  =>  a = 255 - (c_white - c_black)
            let diff = kw.iter().zip(kb).map(|(y, x)| y.saturating_sub(*x) as u32).max().unwrap_or(255);
            let a = 255 - diff.min(255);
            if a == 0 {
                continue;
            }
            for c in 0..3 {
                px[o + c] = ((kb[c] as u32 * 255 + a / 2) / a).min(255) as u8;
            }
            px[o + 3] = a as u8;
        }
        Ok(CursorImage {
            handle: hicon.0 as isize,
            w,
            h,
            hot_x: ii.xHotspot as i32,
            hot_y: ii.yHotspot as i32,
            px,
            invert,
        })
    }
}

#[derive(Default)]
struct CursorOverlay {
    cache: Option<CursorImage>,
    /// (x, y, handle, visible) of the last query, to detect pointer-only changes.
    last_state: Option<(i32, i32, isize, bool)>,
}

impl CursorOverlay {
    /// Current cursor state in global physical coordinates.
    fn query(&mut self) -> Option<(i32, i32, HICON)> {
        let mut ci = CURSORINFO { cbSize: std::mem::size_of::<CURSORINFO>() as u32, ..Default::default() };
        // SAFETY: valid out struct with cbSize set.
        let ok = unsafe { GetCursorInfo(&mut ci) }.is_ok();
        let visible = ok && (ci.flags.0 & CURSOR_SHOWING.0) != 0 && !ci.hCursor.is_invalid();
        self.last_state = Some((ci.ptScreenPos.x, ci.ptScreenPos.y, ci.hCursor.0 as isize, visible));
        visible.then_some((ci.ptScreenPos.x, ci.ptScreenPos.y, HICON(ci.hCursor.0)))
    }

    /// True if the pointer moved / changed shape since the last `query`.
    fn changed(&mut self) -> bool {
        let before = self.last_state;
        let _ = self.query();
        before != self.last_state
    }

    /// Composite the cursor onto `buf` (BGRA, `w`x`h`, `stride`), whose top-left
    /// corner is at global (`ox`, `oy`).
    fn draw(&mut self, buf: &mut [u8], w: u32, h: u32, stride: usize, ox: i32, oy: i32) {
        let Some((cx, cy, hicon)) = self.query() else { return };
        if self.cache.as_ref().map(|c| c.handle) != Some(hicon.0 as isize) {
            // Cursor handles of other processes are shared USER objects on Windows; under
            // Wine they are per-process and GetIconInfo fails → draw the standard arrow so
            // the viewer still sees where the pointer is.
            self.cache = render_cursor(hicon)
                .or_else(|| {
                    // SAFETY: loading a stock system cursor.
                    let arrow = unsafe { LoadCursorW(None, IDC_ARROW) }.ok()?;
                    render_cursor(HICON(arrow.0))
                })
                .map(|mut c| {
                    c.handle = hicon.0 as isize;
                    c
                });
        }
        let Some(img) = self.cache.as_ref() else { return };
        let x0 = cx - img.hot_x - ox;
        let y0 = cy - img.hot_y - oy;
        for j in 0..img.h {
            let y = y0 + j;
            if y < 0 || y >= h as i32 {
                continue;
            }
            for i in 0..img.w {
                let x = x0 + i;
                if x < 0 || x >= w as i32 {
                    continue;
                }
                let s = (j * img.w + i) as usize;
                let d = y as usize * stride + x as usize * 4;
                let Some(dst) = buf.get_mut(d..d + 3) else { continue };
                if img.invert[s] {
                    for c in dst.iter_mut() {
                        *c = 255 - *c;
                    }
                    continue;
                }
                let a = img.px[s * 4 + 3] as u32;
                if a == 0 {
                    continue;
                }
                for (c, dc) in dst.iter_mut().enumerate() {
                    let sc = img.px[s * 4 + c] as u32;
                    *dc = ((sc * a + *dc as u32 * (255 - a) + 127) / 255) as u8;
                }
            }
        }
    }
}

/// Human-readable cursor state (tests / troubleshooting).
#[allow(dead_code)]
pub(crate) fn cursor_debug() -> String {
    let mut ci = CURSORINFO { cbSize: std::mem::size_of::<CURSORINFO>() as u32, ..Default::default() };
    // SAFETY: valid out struct with cbSize set.
    let r = unsafe { GetCursorInfo(&mut ci) };
    let img = try_render_cursor(HICON(ci.hCursor.0));
    format!(
        "GetCursorInfo={:?} flags={:#x} pos=({},{}) hcursor={:?} image={}",
        r.is_ok(),
        ci.flags.0,
        ci.ptScreenPos.x,
        ci.ptScreenPos.y,
        ci.hCursor.0,
        match img {
            Ok(i) => {
                let opaque = i.px.chunks(4).filter(|p| p[3] > 0).count();
                let inv = i.invert.iter().filter(|&&b| b).count();
                format!("{}x{} hot ({},{}) opaque {opaque} invert {inv}", i.w, i.h, i.hot_x, i.hot_y)
            }
            Err(e) => format!("error: {e}"),
        }
    )
}

/// Draw the current cursor into a 64x64 white BGRA tile with the hotspot at (16,16);
/// returns the tile (tests / troubleshooting).
#[allow(dead_code)]
pub(crate) fn cursor_tile() -> Vec<u8> {
    let mut ov = CursorOverlay::default();
    let mut buf = vec![255u8; 64 * 64 * 4];
    if let Some((x, y, _)) = ov.query() {
        ov.draw(&mut buf, 64, 64, 64 * 4, x - 16, y - 16);
    }
    buf
}

/// Wait until the frame interval has elapsed. Returns false if that would
/// take longer than `timeout` (in which case it slept `timeout`).
fn pace(last: Option<Instant>, interval: Duration, timeout: Duration) -> bool {
    if let Some(l) = last {
        let due = l + interval.mul_f32(0.9);
        let now = Instant::now();
        if due > now {
            let wait = due - now;
            if wait > timeout {
                std::thread::sleep(timeout);
                return false;
            }
            std::thread::sleep(wait);
        }
    }
    true
}

// ---------------------------------------------------------------------------
// DXGI Desktop Duplication
// ---------------------------------------------------------------------------

pub struct DxgiCapturer {
    device: ID3D11Device,
    ctx: ID3D11DeviceContext,
    output: IDXGIOutput1,
    dup: Option<IDXGIOutputDuplication>,
    rotation: DXGI_MODE_ROTATION,
    staging: Option<(ID3D11Texture2D, u32, u32)>,
    display: DisplayInfo,
    all: Vec<DisplayInfo>,
    /// Last desktop image in desktop orientation, tightly packed BGRA.
    desk: Vec<u8>,
    desk_w: u32,
    desk_h: u32,
    have_frame: bool,
    cursor: Option<CursorOverlay>,
    interval: Duration,
    last_emit: Option<Instant>,
    lost_since: Option<Instant>,
}

// SAFETY: the D3D11 device is free-threaded; the immediate context, the
// duplication and the GDI handles are only used through `&mut self`, i.e. from
// one thread at a time.
unsafe impl Send for DxgiCapturer {}

impl DxgiCapturer {
    pub fn open(display: u32, opts: &CaptureOptions) -> anyhow::Result<Self> {
        let outs = enumerate_dxgi()?;
        let all: Vec<DisplayInfo> = outs.iter().map(|o| o.info.clone()).collect();
        let o = outs
            .into_iter()
            .find(|o| o.info.index == display)
            .ok_or_else(|| anyhow!("display {display} not found ({} attached)", all.len()))?;
        // Desktop duplication works on every feature level from 9.1 up; offering
        // only 11.0 would needlessly fail on older / virtual GPUs.
        const LEVELS: [D3D_FEATURE_LEVEL; 7] = [
            D3D_FEATURE_LEVEL_11_1,
            D3D_FEATURE_LEVEL_11_0,
            D3D_FEATURE_LEVEL_10_1,
            D3D_FEATURE_LEVEL_10_0,
            D3D_FEATURE_LEVEL_9_3,
            D3D_FEATURE_LEVEL_9_2,
            D3D_FEATURE_LEVEL_9_1,
        ];
        // SAFETY: COM calls with valid out-pointers.
        unsafe {
            let mut device: Option<ID3D11Device> = None;
            let mut ctx: Option<ID3D11DeviceContext> = None;
            let mut r = D3D11CreateDevice(
                &o.adapter,
                D3D_DRIVER_TYPE_UNKNOWN,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                Some(&LEVELS),
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut ctx),
            );
            if r.is_err() {
                // The D3D 11.0 runtime (Windows 7 w/o platform update) rejects 11_1 with E_INVALIDARG.
                r = D3D11CreateDevice(
                    &o.adapter,
                    D3D_DRIVER_TYPE_UNKNOWN,
                    HMODULE::default(),
                    D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                    Some(&LEVELS[1..]),
                    D3D11_SDK_VERSION,
                    Some(&mut device),
                    None,
                    Some(&mut ctx),
                );
            }
            r.context("D3D11CreateDevice failed")?;
            let device = device.ok_or_else(|| anyhow!("D3D11CreateDevice returned no device"))?;
            let ctx = ctx.ok_or_else(|| anyhow!("D3D11CreateDevice returned no context"))?;
            let output: IDXGIOutput1 =
                o.output.cast().context("IDXGIOutput1 not supported (Windows 8+ required)")?;
            let mut me = Self {
                device,
                ctx,
                output,
                dup: None,
                rotation: DXGI_MODE_ROTATION::default(),
                staging: None,
                display: o.info,
                all,
                desk: Vec::new(),
                desk_w: 0,
                desk_h: 0,
                have_frame: false,
                cursor: opts.cursor.then(CursorOverlay::default),
                interval: Duration::from_micros(1_000_000 / opts.fps.clamp(1, 240) as u64),
                last_emit: None,
                lost_since: None,
            };
            me.duplicate()?;
            Ok(me)
        }
    }

    fn duplicate(&mut self) -> anyhow::Result<()> {
        self.dup = None;
        // SAFETY: COM call.
        let dup = unsafe { self.output.DuplicateOutput(&self.device) }.map_err(|e| {
            let hint = if e.code() == E_ACCESSDENIED {
                "the secure desktop (UAC prompt / lock screen / Ctrl+Alt+Del) is active, or Lumora runs as a service"
            } else {
                "Desktop Duplication is unavailable over some RDP sessions / basic display drivers / Wine, or too \
                 many apps already duplicate this output"
            };
            anyhow!("DuplicateOutput failed: {e} ({hint})")
        })?;
        // SAFETY: COM call returning a plain struct.
        self.rotation = unsafe { dup.GetDesc() }.Rotation;
        // Mode or layout may have changed (that is what ACCESS_LOST usually means).
        // SAFETY: COM call.
        if let Ok(d) = unsafe { self.output.GetDesc() } {
            let r = d.DesktopCoordinates;
            self.display = info_from_rect(self.display.index, wide_to_string(&d.DeviceName), r, r.left == 0 && r.top == 0);
            if let Ok(outs) = enumerate_dxgi() {
                self.all = outs.into_iter().map(|o| o.info).collect();
            }
        }
        self.dup = Some(dup);
        Ok(())
    }

    /// Copy the mapped (unrotated) surface into `self.desk` in desktop orientation.
    fn store(&mut self, src: &[u8], pitch: usize, tw: u32, th: u32) {
        let rot = self.rotation;
        let swap = rot == DXGI_MODE_ROTATION_ROTATE90 || rot == DXGI_MODE_ROTATION_ROTATE270;
        let (dw, dh) = if swap { (th, tw) } else { (tw, th) };
        self.desk.resize(dw as usize * dh as usize * 4, 0);
        self.desk_w = dw;
        self.desk_h = dh;
        let (tw, th) = (tw as usize, th as usize);
        if rot != DXGI_MODE_ROTATION_ROTATE90 && rot != DXGI_MODE_ROTATION_ROTATE180 && rot != DXGI_MODE_ROTATION_ROTATE270 {
            for y in 0..th {
                self.desk[y * tw * 4..(y + 1) * tw * 4].copy_from_slice(&src[y * pitch..y * pitch + tw * 4]);
            }
            return;
        }
        let dw = dw as usize;
        for y in 0..dh as usize {
            for x in 0..dw {
                // desktop (x, y) <- surface (sx, sy); same mapping as Microsoft's
                // DesktopDuplication sample (SetDirtyVert).
                let (sx, sy) = match rot {
                    DXGI_MODE_ROTATION_ROTATE90 => (tw - 1 - y, x),
                    DXGI_MODE_ROTATION_ROTATE180 => (tw - 1 - x, th - 1 - y),
                    _ => (y, th - 1 - x), // ROTATE270
                };
                let s = sy * pitch + sx * 4;
                let d = (y * dw + x) * 4;
                self.desk[d..d + 4].copy_from_slice(&src[s..s + 4]);
            }
        }
    }

    fn emit(&mut self) -> Frame {
        let mut data = self.desk.clone();
        let stride = self.desk_w as usize * 4;
        if let Some(c) = self.cursor.as_mut() {
            c.draw(&mut data, self.desk_w, self.desk_h, stride, self.display.x, self.display.y);
        }
        self.last_emit = Some(Instant::now());
        Frame {
            width: self.desk_w,
            height: self.desk_h,
            stride: stride as u32,
            format: PixelFormat::Bgra,
            data: Bytes::from(data),
            ts_us: crate::now_us(),
        }
    }

    fn idle_due(&self) -> bool {
        self.have_frame && self.last_emit.map(|t| t.elapsed() >= IDLE_RESEND).unwrap_or(true)
    }

    fn grab(&mut self, timeout: Duration) -> anyhow::Result<Option<Frame>> {
        if !pace(self.last_emit, self.interval, timeout) {
            return Ok(None);
        }
        if self.dup.is_none() {
            if let Err(e) = self.duplicate() {
                // Transient while the secure desktop is shown or a mode switch is in
                // progress: keep the session alive and retry; give up only if a
                // non-access error persists.
                let since = *self.lost_since.get_or_insert_with(Instant::now);
                let msg = format!("{e:#}");
                if !msg.contains("secure desktop") && since.elapsed() > Duration::from_secs(15) {
                    return Err(e);
                }
                std::thread::sleep(timeout.min(Duration::from_millis(250)));
                return Ok(None);
            }
            self.lost_since = None;
        }
        let Some(dup) = self.dup.clone() else { return Ok(None) };
        let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
        let mut res: Option<IDXGIResource> = None;
        let wait = if self.have_frame {
            let left = self.last_emit.map(|t| IDLE_RESEND.saturating_sub(t.elapsed())).unwrap_or_default();
            timeout.min(left.max(Duration::from_millis(1)))
        } else {
            timeout
        };
        // SAFETY: COM calls with valid out-pointers; ReleaseFrame is always called after a successful acquire.
        unsafe {
            match dup.AcquireNextFrame(wait.as_millis().min(u32::MAX as u128) as u32, &mut info, &mut res) {
                Ok(()) => {}
                Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => {
                    let pointer = self.have_frame && self.cursor.as_mut().map(|c| c.changed()).unwrap_or(false);
                    return Ok((pointer || self.idle_due()).then(|| self.emit()));
                }
                Err(e) if e.code() == DXGI_ERROR_ACCESS_LOST => {
                    self.dup = None;
                    return Ok(None);
                }
                Err(e) => return Err(anyhow!("AcquireNextFrame failed: {e}")),
            }
            let result = (|| -> anyhow::Result<bool> {
                if info.LastPresentTime == 0 {
                    return Ok(false); // only the pointer moved
                }
                let tex: ID3D11Texture2D = res.as_ref().ok_or_else(|| anyhow!("no desktop resource"))?.cast()?;
                let mut desc = D3D11_TEXTURE2D_DESC::default();
                tex.GetDesc(&mut desc);
                if desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM {
                    anyhow::bail!("unsupported desktop format {:?} (HDR desktops are not supported yet)", desc.Format);
                }
                let need_new = !matches!(&self.staging, Some((_, w, h)) if *w == desc.Width && *h == desc.Height);
                if need_new {
                    let sdesc = D3D11_TEXTURE2D_DESC {
                        Width: desc.Width,
                        Height: desc.Height,
                        MipLevels: 1,
                        ArraySize: 1,
                        Format: desc.Format,
                        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                        Usage: D3D11_USAGE_STAGING,
                        BindFlags: 0,
                        CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                        MiscFlags: 0,
                    };
                    let mut st: Option<ID3D11Texture2D> = None;
                    self.device.CreateTexture2D(&sdesc, None, Some(&mut st)).context("CreateTexture2D(staging) failed")?;
                    let st = st.ok_or_else(|| anyhow!("CreateTexture2D returned nothing"))?;
                    self.staging = Some((st, desc.Width, desc.Height));
                }
                let Some((staging, w, h)) = self.staging.clone() else { return Ok(false) };
                self.ctx.CopyResource(&staging, &tex);
                let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
                self.ctx.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped)).context("Map(staging) failed")?;
                let pitch = mapped.RowPitch as usize;
                let src = std::slice::from_raw_parts(mapped.pData as *const u8, pitch * h as usize);
                self.store(src, pitch, w, h);
                self.ctx.Unmap(&staging, 0);
                self.have_frame = true;
                Ok(true)
            })();
            let _ = dup.ReleaseFrame();
            let new_image = result?;
            let pointer = !new_image && info.LastMouseUpdateTime != 0 && self.cursor.is_some();
            if self.have_frame && (new_image || pointer || self.idle_due()) {
                Ok(Some(self.emit()))
            } else {
                Ok(None)
            }
        }
    }
}

impl Capturer for DxgiCapturer {
    fn displays(&self) -> Vec<DisplayInfo> {
        self.all.clone()
    }

    fn next_frame(&mut self, timeout: Duration) -> anyhow::Result<Option<Frame>> {
        self.grab(timeout)
    }
}

// ---------------------------------------------------------------------------
// GDI BitBlt fallback
// ---------------------------------------------------------------------------

pub struct GdiCapturer {
    display: DisplayInfo,
    all: Vec<DisplayInfo>,
    dib: Dib,
    cursor: Option<CursorOverlay>,
    interval: Duration,
    last: Option<Instant>,
    last_layout_check: Instant,
    warned: bool,
}

// SAFETY: GDI handles are only used through `&mut self` (one thread at a time);
// memory DCs and DIB sections are not tied to the creating thread.
unsafe impl Send for GdiCapturer {}

impl GdiCapturer {
    pub fn open(display: u32, opts: &CaptureOptions) -> anyhow::Result<Self> {
        ensure_dpi_awareness();
        let all = list_displays();
        let d = all
            .iter()
            .find(|d| d.index == display)
            .cloned()
            .ok_or_else(|| anyhow!("display {display} not found ({} attached)", all.len()))?;
        if d.width == 0 || d.height == 0 {
            anyhow::bail!("display {display} has an empty size");
        }
        let dib = Dib::new(d.width as i32, d.height as i32)?;
        let mut me = Self {
            display: d,
            all,
            dib,
            cursor: opts.cursor.then(CursorOverlay::default),
            interval: Duration::from_micros(1_000_000 / opts.fps.clamp(1, 240) as u64),
            last: None,
            last_layout_check: Instant::now(),
            warned: false,
        };
        // Fail now (not on the first frame) if the screen cannot be read at all.
        me.blit().context("BitBlt from the screen failed")?;
        Ok(me)
    }

    fn blit(&mut self) -> anyhow::Result<()> {
        // SAFETY: the screen DC is released right after the copy; the DIB is ours.
        unsafe {
            let screen = GetDC(None);
            if screen.is_invalid() {
                anyhow::bail!("GetDC(NULL) failed (no interactive desktop?)");
            }
            // No CAPTUREBLT: with DWM composition layered windows are included
            // anyway, and CAPTUREBLT makes the real cursor flicker.
            let r = BitBlt(
                self.dib.dc,
                0,
                0,
                self.dib.w,
                self.dib.h,
                Some(screen),
                self.display.x,
                self.display.y,
                SRCCOPY,
            );
            ReleaseDC(None, screen);
            let _ = GdiFlush();
            r.map_err(|e| anyhow!("BitBlt failed: {e}"))
        }
    }

    /// Re-read the monitor layout every few seconds; resize when the resolution changed.
    fn check_layout(&mut self) -> anyhow::Result<()> {
        if self.last_layout_check.elapsed() < Duration::from_secs(3) {
            return Ok(());
        }
        self.last_layout_check = Instant::now();
        let all = list_displays();
        if let Some(d) = all.iter().find(|d| d.index == self.display.index).cloned() {
            if (d.width, d.height) != (self.display.width, self.display.height) && d.width > 0 && d.height > 0 {
                self.dib = Dib::new(d.width as i32, d.height as i32)?;
            }
            self.display = d;
        }
        self.all = all;
        Ok(())
    }
}

impl Capturer for GdiCapturer {
    fn displays(&self) -> Vec<DisplayInfo> {
        self.all.clone()
    }

    fn next_frame(&mut self, timeout: Duration) -> anyhow::Result<Option<Frame>> {
        if !pace(self.last, self.interval, timeout) {
            return Ok(None);
        }
        self.last = Some(Instant::now());
        self.check_layout()?;
        if let Err(e) = self.blit() {
            // Typically the secure desktop (UAC) is active: keep the session and retry.
            if !self.warned {
                tracing::warn!("GDI capture: {e:#} (secure desktop active?) — retrying");
                self.warned = true;
            }
            return Ok(None);
        }
        self.warned = false;
        let (w, h) = (self.dib.w as u32, self.dib.h as u32);
        let mut data = self.dib.bytes().to_vec();
        if let Some(c) = self.cursor.as_mut() {
            c.draw(&mut data, w, h, w as usize * 4, self.display.x, self.display.y);
        }
        Ok(Some(Frame {
            width: w,
            height: h,
            stride: w * 4,
            format: PixelFormat::Bgra,
            data: Bytes::from(data),
            ts_us: crate::now_us(),
        }))
    }
}

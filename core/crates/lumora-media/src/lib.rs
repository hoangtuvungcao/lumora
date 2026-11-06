//! # lumora-media
//!
//! Platform media layer for Lumora:
//!
//! * **Screen capture** ([`open_capturer`]): Wayland via the xdg-desktop-portal
//!   ScreenCast interface + PipeWire, X11 via MIT-SHM, Windows via DXGI Desktop
//!   Duplication, macOS via CoreGraphics, Android/iOS via frames pushed from the
//!   host app ([`push_external_frame`]).
//! * **Video** ([`VideoEncoder`] / [`VideoDecoder`]): bundled libvpx VP8/VP9
//!   everywhere, plus H.264 where the OS provides it (MediaCodec, Media
//!   Foundation, VideoToolbox) — negotiated per call, see [`codec`].
//! * **Input injection** ([`open_injector`]): RemoteDesktop portal / uinput /
//!   XTest on Linux, `SendInput` on Windows, `CGEvent` on macOS.
//! * **Audio** ([`audio`]): cpal capture/playback, Opus, adaptive jitter buffer.
//! * **Camera effects** ([`video_fx`]): beauty smoothing, low-light boost and
//!   mirroring on the I420 picture right before encoding (sender side).
//! * **Diagnostics** ([`diag`]): explains (in Vietnamese, for end users) why
//!   capture or input does not work and how to fix it.
//!
//! Every fallible entry point returns a descriptive `anyhow::Error` in English;
//! nothing in this crate is supposed to panic on bad input or a hostile
//! environment.

use std::time::Duration;

use serde::{Deserialize, Serialize};

pub mod audio;
pub mod camera;
pub mod camera_in;
mod capture;
pub mod color;
pub mod diag;
mod input;
pub mod keymap;
#[cfg(feature = "video")]
pub mod codec;
#[cfg(feature = "video")]
mod video;
pub mod video_fx;

pub use capture::external::{
    clear_external_frames, open_external_capturer, push_external_frame, set_external_display,
};
pub use capture::{list_displays, open_capturer};
pub use crate::CaptureSource as Source;
pub use input::{
    open_injector, open_injector_with, set_clipboard_paste_hook, ClipboardPasteHook, InjectorBackend,
    InjectorOptions, InjectorStatus, InjectorWorker, InputEvent,
};
#[cfg(feature = "video")]
pub use codec::{Caps, VideoFormat};
#[cfg(feature = "video")]
pub use video::{is_keyframe, sniff_format, ContentHint, EncodedFrame, EncoderConfig, FrameSync, VideoDecoder, VideoEncoder};

/// Pixel layout of a [`Frame`]: 4 bytes per pixel, byte order as named.
/// (`Bgra` is also used for BGRx — the 4th byte is then undefined/ignored.)
/// `I420` is planar 4:2:0 (camera frames from the app, see [`camera_in`]):
/// tightly packed Y (`width`x`height`), then U and V (`ceil(w/2)`x`ceil(h/2)`),
/// `stride == width`. Only the video encoder accepts it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PixelFormat {
    Bgra,
    Rgba,
    I420,
}

/// A raw video frame (packed 32-bit pixels, or planar I420).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Frame {
    pub width: u32,
    pub height: u32,
    /// Bytes per row (>= width * 4; == width for I420).
    pub stride: u32,
    pub format: PixelFormat,
    pub data: bytes::Bytes,
    /// Capture timestamp in microseconds (monotonic, arbitrary epoch).
    pub ts_us: u64,
}

impl Frame {
    /// Same geometry and identical pixels (a static screen captured again).
    /// Cheap: pointer check first, then one `memcmp`.
    pub fn same_pixels(&self, other: &Frame) -> bool {
        self.width == other.width
            && self.height == other.height
            && self.stride == other.stride
            && self.format == other.format
            && ((self.data.as_ptr() == other.data.as_ptr() && self.data.len() == other.data.len()) || self.data == other.data)
    }

    /// Validate that `data` is large enough for the declared geometry.
    pub fn validate(&self) -> anyhow::Result<()> {
        if self.width == 0 || self.height == 0 {
            anyhow::bail!("frame has empty dimensions {}x{}", self.width, self.height);
        }
        if self.format == PixelFormat::I420 {
            let (w, h) = (self.width as usize, self.height as usize);
            let need = w * h + 2 * w.div_ceil(2) * h.div_ceil(2);
            if self.data.len() < need {
                anyhow::bail!("I420 frame buffer too small: {} bytes, need {need} for {w}x{h}", self.data.len());
            }
            return Ok(());
        }
        let min_stride = self.width as usize * 4;
        if (self.stride as usize) < min_stride {
            anyhow::bail!("frame stride {} is smaller than width*4 = {}", self.stride, min_stride);
        }
        let need = self.stride as usize * (self.height as usize - 1) + min_stride;
        if self.data.len() < need {
            anyhow::bail!(
                "frame buffer too small: {} bytes, need {} for {}x{} stride {}",
                self.data.len(),
                need,
                self.width,
                self.height,
                self.stride
            );
        }
        Ok(())
    }
}

/// Description of a monitor / capture source.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DisplayInfo {
    pub index: u32,
    pub name: String,
    /// Size in logical (compositor) pixels, i.e. the coordinate space input uses.
    pub width: u32,
    pub height: u32,
    /// Position of the display's top-left corner in the global desktop layout.
    pub x: i32,
    pub y: i32,
    /// Device pixels per logical pixel (1.0 when unknown).
    pub scale: f32,
    pub primary: bool,
}

impl Default for DisplayInfo {
    fn default() -> Self {
        Self { index: 0, name: String::new(), width: 0, height: 0, x: 0, y: 0, scale: 1.0, primary: true }
    }
}

/// Options for [`open_capturer`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CaptureOptions {
    /// Target frame rate (frames are delivered at most this often).
    pub fps: u32,
    /// Draw the mouse cursor into the captured frames.
    pub cursor: bool,
    /// Wayland portal restore token from a previous session; when valid the
    /// user is not asked again. Ignored on other platforms.
    pub restore_token: Option<String>,
    /// What the user may pick in the system dialog (Wayland portal): a whole screen,
    /// a single window/application, or either.
    #[serde(default)]
    pub source: CaptureSource,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CaptureSource {
    /// Whole monitor (remote desktop).
    #[default]
    Monitor,
    /// One window / application only.
    Window,
    /// Let the user choose a screen or a window (screen sharing in calls).
    Any,
}

impl Default for CaptureOptions {
    fn default() -> Self {
        Self { fps: 30, cursor: true, restore_token: None, source: CaptureSource::Monitor }
    }
}

/// A source of screen frames.
pub trait Capturer: Send {
    /// The display(s) this capturer knows about. For the Wayland portal this
    /// is the stream the user selected.
    fn displays(&self) -> Vec<DisplayInfo>;
    /// Wait up to `timeout` for the next frame. `Ok(None)` means no new frame
    /// arrived in time (e.g. the screen is static); `Err` means the capture
    /// session is dead and must be reopened.
    fn next_frame(&mut self, timeout: Duration) -> anyhow::Result<Option<Frame>>;
}

/// Mouse buttons understood by [`InputInjector::button`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MouseButton {
    Left,
    Right,
    Middle,
    /// "Back" side button (X1).
    Back,
    /// "Forward" side button (X2).
    Forward,
}

/// Injects remote input into the local session.
pub trait InputInjector: Send {
    /// Move the pointer to an absolute position, `x`/`y` in `0.0..=1.0`
    /// relative to the display the injector was opened for.
    fn mouse_move_abs(&mut self, x: f64, y: f64) -> anyhow::Result<()>;
    fn button(&mut self, b: MouseButton, down: bool) -> anyhow::Result<()>;
    /// Scroll by whole wheel notches; positive `dy` scrolls down, positive `dx` right.
    fn wheel(&mut self, dx: i32, dy: i32) -> anyhow::Result<()>;
    /// Press/release a physical key named by its W3C `KeyboardEvent.code`.
    fn key(&mut self, code: &str, down: bool) -> anyhow::Result<()>;
    /// Type a Unicode string (already composed by the remote IME).
    fn text(&mut self, s: &str) -> anyhow::Result<()>;
    /// Human-readable backend name (e.g. "uinput", "xtest", "portal").
    fn backend(&self) -> &'static str {
        "unknown"
    }
}

/// Monotonic clock in microseconds, used for frame timestamps.
pub fn now_us() -> u64 {
    use std::sync::OnceLock;
    use std::time::Instant;
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_micros() as u64
}

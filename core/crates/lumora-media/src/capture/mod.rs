//! Screen capture back-ends and dispatch.

use std::collections::VecDeque;
use std::sync::Arc;
use std::time::{Duration, Instant};

use parking_lot::{Condvar, Mutex};

use crate::{CaptureOptions, Capturer, DisplayInfo, Frame};

pub mod external;

#[cfg(target_os = "linux")]
mod wayland;
#[cfg(target_os = "linux")]
pub(crate) mod x11;

#[cfg(windows)]
pub(crate) mod windows;

#[cfg(target_os = "macos")]
mod macos;

/// Open a screen capturer for display `display` (index into [`list_displays`]).
///
/// Returns the capturer and, on Wayland, a portal restore token to pass in
/// [`CaptureOptions::restore_token`] next time so the user is not asked again.
///
/// Backend selection on Linux: `WAYLAND_DISPLAY` set → ScreenCast portal +
/// PipeWire (the user picks the monitor in the portal dialog; `display` is
/// ignored); otherwise X11 MIT-SHM. Override with `LUMORA_CAPTURE=x11|portal`.
pub fn open_capturer(display: u32, opts: CaptureOptions) -> anyhow::Result<(Box<dyn Capturer>, Option<String>)> {
    #[cfg(target_os = "linux")]
    {
        let forced = std::env::var("LUMORA_CAPTURE").unwrap_or_default();
        let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some()
            || std::env::var("XDG_SESSION_TYPE").map(|s| s == "wayland").unwrap_or(false);
        let use_portal = match forced.as_str() {
            "x11" => false,
            "portal" => true,
            _ => wayland,
        };
        if use_portal {
            let (c, tok) = wayland::PortalCapturer::open(display, &opts)?;
            Ok((Box::new(c), tok))
        } else {
            let c = x11::X11Capturer::open(display, &opts)?;
            Ok((Box::new(c), None))
        }
    }
    #[cfg(windows)]
    {
        // DXGI Desktop Duplication, falling back to GDI BitBlt (RDP, Wine, …).
        Ok((windows::open(display, &opts)?, None))
    }
    #[cfg(target_os = "macos")]
    {
        let c = macos::CgCapturer::open(display, &opts)?;
        Ok((Box::new(c), None))
    }
    #[cfg(any(target_os = "android", target_os = "ios"))]
    {
        let _ = (display, opts);
        Ok((Box::new(external::open_external_capturer()), None))
    }
    #[cfg(not(any(target_os = "linux", windows, target_os = "macos", target_os = "android", target_os = "ios")))]
    {
        let _ = (display, opts);
        anyhow::bail!("screen capture is not supported on this platform")
    }
}

/// Best-effort list of displays. On Wayland this uses XWayland's RandR view
/// of the outputs (logical sizes); if XWayland is unavailable it returns an
/// empty list (the portal dialog chooses the monitor anyway).
pub fn list_displays() -> Vec<DisplayInfo> {
    #[cfg(target_os = "linux")]
    {
        x11::list_displays().unwrap_or_default()
    }
    #[cfg(windows)]
    {
        windows::list_displays()
    }
    #[cfg(target_os = "macos")]
    {
        macos::list_displays()
    }
    #[cfg(not(any(target_os = "linux", windows, target_os = "macos")))]
    {
        external::external_display().into_iter().collect()
    }
}

/// Bounded frame queue shared between a producer thread and the capturer.
/// When full, the *oldest* frame is dropped so the consumer always gets the
/// freshest picture (low latency beats completeness for remote desktop).
pub(crate) struct FrameQueue {
    inner: Mutex<QueueState>,
    cv: Condvar,
    cap: usize,
}

struct QueueState {
    frames: VecDeque<Frame>,
    closed: Option<String>,
    dropped: u64,
}

impl FrameQueue {
    pub fn new(cap: usize) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(QueueState { frames: VecDeque::with_capacity(cap), closed: None, dropped: 0 }),
            cv: Condvar::new(),
            cap: cap.max(1),
        })
    }

    pub fn push(&self, f: Frame) {
        let mut st = self.inner.lock();
        while st.frames.len() >= self.cap {
            st.frames.pop_front();
            st.dropped += 1;
        }
        st.frames.push_back(f);
        drop(st);
        self.cv.notify_one();
    }

    /// Mark the queue closed with a reason; consumers get an error after draining.
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    pub fn close(&self, reason: impl Into<String>) {
        let mut st = self.inner.lock();
        if st.closed.is_none() {
            st.closed = Some(reason.into());
        }
        drop(st);
        self.cv.notify_all();
    }

    pub fn clear(&self) {
        self.inner.lock().frames.clear();
    }

    #[allow(dead_code)]
    pub fn dropped(&self) -> u64 {
        self.inner.lock().dropped
    }

    pub fn pop(&self, timeout: Duration) -> anyhow::Result<Option<Frame>> {
        let deadline = Instant::now() + timeout;
        let mut st = self.inner.lock();
        loop {
            if let Some(f) = st.frames.pop_front() {
                return Ok(Some(f));
            }
            if let Some(r) = &st.closed {
                anyhow::bail!("capture stopped: {r}");
            }
            if self.cv.wait_until(&mut st, deadline).timed_out() {
                return Ok(st.frames.pop_front());
            }
        }
    }
}

/// Simple frame-rate limiter for producers.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) struct FpsLimiter {
    interval: Duration,
    last: Option<Instant>,
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
impl FpsLimiter {
    pub fn new(fps: u32) -> Self {
        Self { interval: Duration::from_micros(1_000_000 / fps.clamp(1, 240) as u64), last: None }
    }
    /// Returns true if a frame should be emitted now.
    pub fn tick(&mut self) -> bool {
        let now = Instant::now();
        match self.last {
            // Allow 10% early so a 60 Hz source is not decimated to 30 fps
            // by timing jitter when 60 fps is requested.
            Some(l) if now.duration_since(l) < self.interval.mul_f32(0.9) => false,
            _ => {
                self.last = Some(now);
                true
            }
        }
    }
    #[allow(dead_code)]
    pub fn interval(&self) -> Duration {
        self.interval
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::PixelFormat;

    fn f(ts: u64) -> Frame {
        Frame { width: 1, height: 1, stride: 4, format: PixelFormat::Bgra, data: vec![0; 4].into(), ts_us: ts }
    }

    #[test]
    fn queue_drops_oldest() {
        let q = FrameQueue::new(2);
        q.push(f(1));
        q.push(f(2));
        q.push(f(3));
        assert_eq!(q.pop(Duration::ZERO).unwrap().unwrap().ts_us, 2);
        assert_eq!(q.pop(Duration::ZERO).unwrap().unwrap().ts_us, 3);
        assert!(q.pop(Duration::from_millis(5)).unwrap().is_none());
        assert_eq!(q.dropped(), 1);
        q.close("bye");
        assert!(q.pop(Duration::ZERO).is_err());
    }
}

//! macOS screen capture via CoreGraphics (`CGDisplayCreateImage`).
//!
//! Requires the "Screen & System Audio Recording" permission; without it macOS
//! returns only the wallpaper/menu bar (see `diag`). `CGDisplayCreateImage`
//! is deprecated in favour of ScreenCaptureKit (macOS 12.3+); it still works
//! on current releases and keeps this backend dependency-free. Frames are
//! polled at the requested fps.

use std::time::{Duration, Instant};

use anyhow::anyhow;
use bytes::Bytes;
use core_graphics::display::CGDisplay;

use crate::{CaptureOptions, Capturer, DisplayInfo, Frame, PixelFormat};

pub fn list_displays() -> Vec<DisplayInfo> {
    let ids = CGDisplay::active_displays().unwrap_or_default();
    ids.iter()
        .enumerate()
        .map(|(i, &id)| {
            let d = CGDisplay::new(id);
            let b = d.bounds();
            let w = b.size.width.max(1.0);
            DisplayInfo {
                index: i as u32,
                name: format!("display-{id}"),
                width: b.size.width as u32,
                height: b.size.height as u32,
                x: b.origin.x as i32,
                y: b.origin.y as i32,
                scale: (d.pixels_wide() as f64 / w) as f32,
                primary: d.is_main(),
            }
        })
        .collect()
}

pub struct CgCapturer {
    id: u32,
    all: Vec<DisplayInfo>,
    interval: Duration,
    last: Option<Instant>,
}

impl CgCapturer {
    pub fn open(display: u32, opts: &CaptureOptions) -> anyhow::Result<Self> {
        let ids = CGDisplay::active_displays().map_err(|e| anyhow!("CGGetActiveDisplayList failed: {e}"))?;
        let id = *ids
            .get(display as usize)
            .ok_or_else(|| anyhow!("display {display} not found ({} active)", ids.len()))?;
        Ok(Self {
            id,
            all: list_displays(),
            interval: Duration::from_micros(1_000_000 / opts.fps.clamp(1, 120) as u64),
            last: None,
        })
    }
}

// SAFETY: only a display id (u32) is stored.
unsafe impl Send for CgCapturer {}

impl Capturer for CgCapturer {
    fn displays(&self) -> Vec<DisplayInfo> {
        self.all.clone()
    }

    fn next_frame(&mut self, timeout: Duration) -> anyhow::Result<Option<Frame>> {
        if let Some(last) = self.last {
            let due = last + self.interval;
            let now = Instant::now();
            if due > now {
                if due - now > timeout {
                    std::thread::sleep(timeout);
                    return Ok(None);
                }
                std::thread::sleep(due - now);
            }
        }
        self.last = Some(Instant::now());
        let img = CGDisplay::new(self.id)
            .image()
            .ok_or_else(|| anyhow!("CGDisplayCreateImage failed (display disconnected or Screen Recording permission missing)"))?;
        if img.bits_per_pixel() != 32 {
            anyhow::bail!("unsupported screen pixel depth {} bpp", img.bits_per_pixel());
        }
        let (w, h, stride) = (img.width() as u32, img.height() as u32, img.bytes_per_row() as u32);
        let data = img.data();
        Ok(Some(Frame {
            width: w,
            height: h,
            stride,
            format: PixelFormat::Bgra,
            data: Bytes::copy_from_slice(data.bytes()),
            ts_us: crate::now_us(),
        }))
    }
}

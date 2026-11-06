//! Webcam support.
//!
//! * [`list_cameras`] (Linux): enumerates V4L2 capture nodes via sysfs — no
//!   extra dependencies, always available.
//! * [`open_camera`] (Linux, cargo feature `camera-v4l`): captures YUYV frames
//!   with the `v4l` crate on a dedicated thread and converts them to RGBA
//!   [`Frame`](crate::Frame)s. MJPEG-only cameras are not supported (would
//!   need a JPEG decoder); most UVC webcams offer YUYV at 640x480@30.
//! * Windows/macOS/Android/iOS: camera capture is expected to come from the
//!   Flutter side (platform camera plugins) and be pushed as frames — the same
//!   way as [`crate::push_external_frame`]; nothing is implemented here.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CameraInfo {
    pub index: u32,
    pub path: String,
    pub name: String,
}

/// List V4L2 video devices (Linux). Metadata-only nodes are included because
/// sysfs cannot tell them apart cheaply; opening one fails with a clear error.
pub fn list_cameras() -> Vec<CameraInfo> {
    #[cfg(target_os = "linux")]
    {
        let mut v = Vec::new();
        if let Ok(rd) = std::fs::read_dir("/sys/class/video4linux") {
            for e in rd.flatten() {
                let fname = e.file_name().to_string_lossy().into_owned();
                let Some(idx) = fname.strip_prefix("video").and_then(|n| n.parse::<u32>().ok()) else { continue };
                let name = std::fs::read_to_string(e.path().join("name")).unwrap_or_default().trim().to_string();
                // `index` attribute 0 = the primary node of a physical device.
                let node_index = std::fs::read_to_string(e.path().join("index")).ok().and_then(|s| s.trim().parse::<u32>().ok());
                if node_index.unwrap_or(0) != 0 {
                    continue;
                }
                v.push(CameraInfo { index: idx, path: format!("/dev/{fname}"), name });
            }
        }
        v.sort_by_key(|c| c.index);
        v
    }
    #[cfg(not(target_os = "linux"))]
    {
        Vec::new()
    }
}

#[cfg(all(target_os = "linux", feature = "camera-v4l"))]
pub use v4l_cam::{open_camera, Camera};

#[cfg(all(target_os = "linux", feature = "camera-v4l"))]
mod v4l_cam {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::thread::JoinHandle;
    use std::time::Duration;

    use anyhow::{anyhow, Context};
    use bytes::Bytes;
    use v4l::buffer::Type;
    use v4l::io::traits::CaptureStream;
    use v4l::prelude::*;
    use v4l::video::Capture;
    use v4l::FourCC;

    use crate::capture::FrameQueue;
    use crate::{Frame, PixelFormat};

    pub struct Camera {
        queue: Arc<FrameQueue>,
        stop: Arc<AtomicBool>,
        thread: Option<JoinHandle<()>>,
        pub width: u32,
        pub height: u32,
    }

    /// Open `/dev/video{index}` at roughly `width`x`height`@`fps` (YUYV).
    pub fn open_camera(index: u32, width: u32, height: u32, fps: u32) -> anyhow::Result<Camera> {
        let path = format!("/dev/video{index}");
        let dev = Device::with_path(&path).map_err(|e| match e.kind() {
            std::io::ErrorKind::PermissionDenied => {
                anyhow!("permission denied opening {path}: add the user to the 'video' group (sudo usermod -aG video $USER) and log in again")
            }
            _ => anyhow!("cannot open camera {path}: {e}"),
        })?;
        let fmt = dev
            .set_format(&v4l::Format::new(width, height, FourCC::new(b"YUYV")))
            .with_context(|| format!("{path}: cannot set YUYV format"))?;
        if fmt.fourcc != FourCC::new(b"YUYV") {
            anyhow::bail!("{path}: camera does not support YUYV (offers {}); MJPEG-only cameras are unsupported", fmt.fourcc);
        }
        let _ = dev.set_params(&v4l::video::capture::Parameters::with_fps(fps.max(1)));
        let (w, h, stride) = (fmt.width, fmt.height, fmt.stride.max(fmt.width * 2));
        let queue = FrameQueue::new(2);
        let stop = Arc::new(AtomicBool::new(false));
        let (q2, s2) = (queue.clone(), stop.clone());
        let thread = std::thread::Builder::new()
            .name("lumora-camera".into())
            .spawn(move || {
                let mut stream = match MmapStream::with_buffers(&dev, Type::VideoCapture, 4) {
                    Ok(s) => s,
                    Err(e) => {
                        q2.close(format!("cannot start camera stream: {e}"));
                        return;
                    }
                };
                while !s2.load(Ordering::Relaxed) {
                    match stream.next() {
                        Ok((buf, _meta)) => {
                            let rgba = yuyv_to_rgba(buf, w as usize, h as usize, stride as usize);
                            q2.push(Frame {
                                width: w,
                                height: h,
                                stride: w * 4,
                                format: PixelFormat::Rgba,
                                data: Bytes::from(rgba),
                                ts_us: crate::now_us(),
                            });
                        }
                        Err(e) => {
                            q2.close(format!("camera read failed: {e}"));
                            return;
                        }
                    }
                }
                q2.close("camera closed");
            })
            .context("failed to spawn camera thread")?;
        Ok(Camera { queue, stop, thread: Some(thread), width: w, height: h })
    }

    impl Camera {
        pub fn next_frame(&mut self, timeout: Duration) -> anyhow::Result<Option<Frame>> {
            self.queue.pop(timeout)
        }
    }

    impl Drop for Camera {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
            if let Some(t) = self.thread.take() {
                let _ = t.join();
            }
        }
    }

    fn yuyv_to_rgba(src: &[u8], w: usize, h: usize, stride: usize) -> Vec<u8> {
        let mut out = vec![0u8; w * h * 4];
        for y in 0..h {
            let Some(row) = src.get(y * stride..y * stride + w * 2) else { break };
            for x in (0..w).step_by(2) {
                let (y0, u, y1, v) = (row[x * 2] as i32, row[x * 2 + 1] as i32, row[x * 2 + 2] as i32, row[x * 2 + 3] as i32);
                for (k, yy) in [(0usize, y0), (1, y1)] {
                    if x + k >= w {
                        break;
                    }
                    let c = 298 * (yy - 16);
                    let (d, e) = (u - 128, v - 128);
                    let o = (y * w + x + k) * 4;
                    out[o] = ((c + 409 * e + 128) >> 8).clamp(0, 255) as u8;
                    out[o + 1] = ((c - 100 * d - 208 * e + 128) >> 8).clamp(0, 255) as u8;
                    out[o + 2] = ((c + 516 * d + 128) >> 8).clamp(0, 255) as u8;
                    out[o + 3] = 255;
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn list_does_not_panic() {
        let _ = super::list_cameras();
    }
}

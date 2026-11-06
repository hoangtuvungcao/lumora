//! X11 screen capture with MIT-SHM `GetImage` (falls back to plain `GetImage`),
//! cursor composited from XFixes, monitor layout from RandR 1.5. With the
//! DAMAGE extension the screen is only grabbed when something was drawn (or
//! the pointer moved), so an idle desktop costs almost nothing.

use std::time::{Duration, Instant};

use anyhow::{anyhow, Context};
use bytes::Bytes;
use x11rb::connection::Connection;
use x11rb::protocol::damage::{self, ConnectionExt as _};
use x11rb::protocol::randr::ConnectionExt as _;
use x11rb::protocol::Event;
use x11rb::protocol::shm::{self, ConnectionExt as _};
use x11rb::protocol::xfixes::ConnectionExt as _;
use x11rb::protocol::xproto::{ConnectionExt as _, ImageFormat, Window};
use x11rb::rust_connection::RustConnection;

use crate::{CaptureOptions, Capturer, DisplayInfo, Frame, PixelFormat};

/// Query RandR monitors of the default X display.
pub(crate) fn list_displays() -> anyhow::Result<Vec<DisplayInfo>> {
    let (conn, screen_num) = x11rb::connect(None).map_err(|e| anyhow!("cannot connect to X server: {e}"))?;
    let root = conn.setup().roots[screen_num].root;
    list_displays_on(&conn, root, screen_num)
}

fn list_displays_on(conn: &RustConnection, root: Window, screen_num: usize) -> anyhow::Result<Vec<DisplayInfo>> {
    let mut out = Vec::new();
    if let Ok(cookie) = conn.randr_get_monitors(root, true) {
        if let Ok(reply) = cookie.reply() {
            for (i, m) in reply.monitors.iter().enumerate() {
                let name = conn
                    .get_atom_name(m.name)
                    .ok()
                    .and_then(|c| c.reply().ok())
                    .map(|r| String::from_utf8_lossy(&r.name).into_owned())
                    .unwrap_or_else(|| format!("monitor-{i}"));
                out.push(DisplayInfo {
                    index: i as u32,
                    name,
                    width: m.width as u32,
                    height: m.height as u32,
                    x: m.x as i32,
                    y: m.y as i32,
                    scale: 1.0,
                    primary: m.primary,
                });
            }
        }
    }
    if out.is_empty() {
        let s = &conn.setup().roots[screen_num];
        out.push(DisplayInfo {
            index: 0,
            name: "screen".into(),
            width: s.width_in_pixels as u32,
            height: s.height_in_pixels as u32,
            ..Default::default()
        });
    }
    if !out.iter().any(|d| d.primary) {
        if let Some(d) = out.first_mut() {
            d.primary = true;
        }
    }
    Ok(out)
}

struct ShmSeg {
    seg: shm::Seg,
    addr: *mut u8,
    size: usize,
}

// SAFETY: the segment is only accessed from the owning capturer.
unsafe impl Send for ShmSeg {}

pub struct X11Capturer {
    conn: RustConnection,
    root: Window,
    display: DisplayInfo,
    all: Vec<DisplayInfo>,
    shm: Option<ShmSeg>,
    cursor: bool,
    interval: Duration,
    /// last capture tick (paces polling at the frame rate)
    tick: Option<Instant>,
    /// last frame actually grabbed
    last: Option<Instant>,
    /// DAMAGE object on the root window (None: extension missing → grab every tick)
    damage: Option<damage::Damage>,
    dirty: bool,
    pointer: (i16, i16),
    /// Z-pixmap layout of the root depth (bits per pixel, scanline pad in bits)
    bpp: u8,
    scanline_pad: u8,
}

/// Even when nothing changes, send a frame this often (a viewer that just
/// joined or lost a frame gets a fresh picture).
const IDLE_REFRESH: Duration = Duration::from_secs(2);

impl X11Capturer {
    pub fn open(display: u32, opts: &CaptureOptions) -> anyhow::Result<Self> {
        let (conn, screen_num) = x11rb::connect(None).map_err(|e| {
            anyhow!("cannot connect to the X server (DISPLAY={:?}): {e}", std::env::var("DISPLAY").ok())
        })?;
        let root = conn.setup().roots[screen_num].root;
        let depth = conn.setup().roots[screen_num].root_depth;
        if depth != 24 && depth != 32 {
            anyhow::bail!("unsupported X11 root depth {depth} (need 24 or 32 bit colour)");
        }
        let (bpp, scanline_pad) = conn
            .setup()
            .pixmap_formats
            .iter()
            .find(|f| f.depth == depth)
            .map(|f| (f.bits_per_pixel, f.scanline_pad))
            .unwrap_or((32, 32));
        if bpp != 24 && bpp != 32 {
            anyhow::bail!("unsupported X11 pixel layout: {bpp} bits per pixel at depth {depth}");
        }
        let all = list_displays_on(&conn, root, screen_num)?;
        let disp = all
            .iter()
            .find(|d| d.index == display)
            .cloned()
            .ok_or_else(|| anyhow!("display {display} not found ({} monitor(s) available)", all.len()))?;
        let mut me = Self {
            conn,
            root,
            display: disp,
            all,
            shm: None,
            cursor: opts.cursor,
            interval: Duration::from_micros(1_000_000 / opts.fps.clamp(1, 240) as u64),
            tick: None,
            last: None,
            damage: None,
            dirty: true,
            pointer: (i16::MIN, i16::MIN),
            bpp,
            scanline_pad,
        };
        if let Err(e) = me.setup_damage() {
            tracing::info!("X DAMAGE unavailable, grabbing every frame: {e:#}");
        }
        if let Err(e) = me.setup_shm() {
            tracing::info!("MIT-SHM unavailable, using slow GetImage path: {e:#}");
        }
        if me.cursor && me.conn.xfixes_query_version(4, 0).ok().and_then(|c| c.reply().ok()).is_none() {
            me.cursor = false;
        }
        Ok(me)
    }

    fn setup_damage(&mut self) -> anyhow::Result<()> {
        self.conn.damage_query_version(1, 1)?.reply().context("DAMAGE extension not present")?;
        let id = self.conn.generate_id()?;
        self.conn.damage_create(id, self.root, damage::ReportLevel::NON_EMPTY)?.check()?;
        self.damage = Some(id);
        Ok(())
    }

    /// Anything drawn (or the pointer moved) since the last grab?
    fn changed(&mut self) -> bool {
        let Some(_) = self.damage else { return true };
        while let Ok(Some(ev)) = self.conn.poll_for_event() {
            if matches!(ev, Event::DamageNotify(_)) {
                self.dirty = true;
            }
        }
        if self.cursor {
            if let Ok(Ok(p)) = self.conn.query_pointer(self.root).map(|c| c.reply()) {
                if (p.root_x, p.root_y) != self.pointer {
                    self.pointer = (p.root_x, p.root_y);
                    self.dirty = true;
                }
            }
        }
        self.dirty
    }

    fn setup_shm(&mut self) -> anyhow::Result<()> {
        self.conn.shm_query_version()?.reply().context("MIT-SHM extension not present")?;
        let size = self.display.width as usize * self.display.height as usize * 4;
        // SAFETY: plain SysV shm calls; results are checked.
        unsafe {
            let id = libc::shmget(libc::IPC_PRIVATE, size, libc::IPC_CREAT | 0o600);
            if id < 0 {
                anyhow::bail!("shmget failed: {}", std::io::Error::last_os_error());
            }
            let addr = libc::shmat(id, std::ptr::null(), 0);
            if addr as isize == -1 {
                libc::shmctl(id, libc::IPC_RMID, std::ptr::null_mut());
                anyhow::bail!("shmat failed: {}", std::io::Error::last_os_error());
            }
            let seg = self.conn.generate_id()?;
            // read_only = false: the server writes the image into the segment (GetImage)
            let attached = self.conn.shm_attach(seg, id as u32, false).map(|c| c.check());
            // Mark for deletion now; it lives until both sides detach.
            libc::shmctl(id, libc::IPC_RMID, std::ptr::null_mut());
            match attached {
                Ok(Ok(())) => {}
                _ => {
                    libc::shmdt(addr);
                    anyhow::bail!("X server refused the shared memory segment (remote X connection?)");
                }
            }
            self.shm = Some(ShmSeg { seg, addr: addr as *mut u8, size });
        }
        Ok(())
    }

    fn grab(&mut self) -> anyhow::Result<Frame> {
        let d = &self.display;
        let (w, h) = (d.width as u16, d.height as u16);
        let data: Vec<u8> = if let Some(s) = &self.shm {
            self.conn
                .shm_get_image(self.root, d.x as i16, d.y as i16, w, h, !0, ImageFormat::Z_PIXMAP.into(), s.seg, 0)?
                .reply()
                .map_err(|e| anyhow!("MIT-SHM GetImage failed: {e}"))?;
            // SAFETY: the segment is `size` bytes and the server finished writing (reply received).
            unsafe { std::slice::from_raw_parts(s.addr, s.size) }.to_vec()
        } else {
            self.conn
                .get_image(ImageFormat::Z_PIXMAP, self.root, d.x as i16, d.y as i16, w, h, !0)?
                .reply()
                .map_err(|e| anyhow!("X11 GetImage failed: {e}"))?
                .data
        };
        // 24-bpp servers pack pixels in 3 bytes: hand out BGRx like everywhere else
        let mut data = to_bgrx(data, w as usize, h as usize, self.bpp, self.scanline_pad)
            .ok_or_else(|| anyhow!("X server returned a short or unsupported image ({} bits per pixel)", self.bpp))?;
        if self.cursor {
            self.draw_cursor(&mut data);
        }
        Ok(Frame {
            width: w as u32,
            height: h as u32,
            stride: w as u32 * 4,
            format: PixelFormat::Bgra,
            data: Bytes::from(data),
            ts_us: crate::now_us(),
        })
    }

    /// Composite the XFixes cursor onto `data` (tightly packed BGRx, see [`to_bgrx`]).
    fn draw_cursor(&self, data: &mut [u8]) {
        let Ok(Ok(c)) = self.conn.xfixes_get_cursor_image().map(|c| c.reply()) else { return };
        let (fw, fh) = (self.display.width as usize, self.display.height as usize);
        let ox = c.x as i32 - c.xhot as i32 - self.display.x;
        let oy = c.y as i32 - c.yhot as i32 - self.display.y;
        let cur = CursorImage { argb: &c.cursor_image, width: c.width as usize, height: c.height as usize };
        blend_cursor(data, fw, fh, fw * 4, 32, &cur, ox, oy);
    }
}

/// Bytes per row of a Z-pixmap image (`scanline_pad` in bits).
fn row_bytes(width: usize, bpp: u8, scanline_pad: u8) -> usize {
    let pad = (scanline_pad as usize).max(8);
    (width * bpp as usize).div_ceil(pad) * pad / 8
}

/// Repack a little-endian Z-pixmap image of `bpp` bits per pixel into tightly
/// packed 32-bit BGRx rows. `None` if the layout is unsupported or `data` is short.
fn to_bgrx(mut data: Vec<u8>, width: usize, height: usize, bpp: u8, scanline_pad: u8) -> Option<Vec<u8>> {
    let src_stride = row_bytes(width, bpp, scanline_pad);
    if data.len() < src_stride.checked_mul(height)? {
        return None;
    }
    match bpp {
        32 if src_stride == width * 4 => {
            data.truncate(width * height * 4);
            Some(data)
        }
        32 | 24 => {
            let step = bpp as usize / 8;
            let mut out = vec![0u8; width * height * 4];
            for (src, dst) in data.chunks(src_stride).zip(out.chunks_exact_mut(width * 4)) {
                for (s, d) in src[..width * step].chunks_exact(step).zip(dst.chunks_exact_mut(4)) {
                    d[..3].copy_from_slice(&s[..3]);
                }
            }
            Some(out)
        }
        _ => None,
    }
}

/// An XFixes cursor: `width × height` premultiplied ARGB pixels.
struct CursorImage<'a> {
    argb: &'a [u32],
    width: usize,
    height: usize,
}

/// Composite `cur` with its top-left corner at (`ox`, `oy`) onto a little-endian
/// image of `width × height` pixels (`stride` bytes per row) with `bpp` = 32 (BGRx),
/// 24 (BGR) or 16 (RGB565). Other layouts are left untouched; pixels outside the
/// image or past the end of `data` are skipped.
#[allow(clippy::too_many_arguments)]
fn blend_cursor(data: &mut [u8], width: usize, height: usize, stride: usize, bpp: u8, cur: &CursorImage<'_>, ox: i32, oy: i32) {
    let step = match bpp {
        32 => 4,
        24 => 3,
        16 => 2,
        _ => return,
    };
    if stride < width * step {
        return;
    }
    for cy in 0..cur.height {
        let py = oy as i64 + cy as i64;
        if py < 0 || py >= height as i64 {
            continue;
        }
        for cx in 0..cur.width {
            let px = ox as i64 + cx as i64;
            if px < 0 || px >= width as i64 {
                continue;
            }
            let Some(&argb) = cur.argb.get(cy * cur.width + cx) else { continue };
            let a = argb >> 24;
            if a == 0 {
                continue;
            }
            let i = py as usize * stride + px as usize * step;
            let Some(p) = data.get_mut(i..i + step) else { continue };
            // premultiplied source over destination, per channel
            let over = |s: u32, d: u32| (s + d * (255 - a) / 255).min(255);
            let (sb, sg, sr) = (argb & 0xFF, (argb >> 8) & 0xFF, (argb >> 16) & 0xFF);
            if step == 2 {
                let v = u16::from_le_bytes([p[0], p[1]]) as u32;
                // expand 5/6/5 bits to 8 and back
                let (r, g, b) = (((v >> 11) & 0x1F) * 255 / 31, ((v >> 5) & 0x3F) * 255 / 63, (v & 0x1F) * 255 / 31);
                let (r, g, b) = (over(sr, r), over(sg, g), over(sb, b));
                let v = ((r * 31 / 255) << 11) | ((g * 63 / 255) << 5) | (b * 31 / 255);
                p.copy_from_slice(&(v as u16).to_le_bytes());
            } else {
                p[0] = over(sb, p[0] as u32) as u8;
                p[1] = over(sg, p[1] as u32) as u8;
                p[2] = over(sr, p[2] as u32) as u8;
            }
        }
    }
}

impl Drop for X11Capturer {
    fn drop(&mut self) {
        if let Some(s) = self.shm.take() {
            let _ = self.conn.shm_detach(s.seg);
            let _ = self.conn.flush();
            // SAFETY: addr came from shmat.
            unsafe {
                libc::shmdt(s.addr as *const libc::c_void);
            }
        }
    }
}

impl Capturer for X11Capturer {
    fn displays(&self) -> Vec<DisplayInfo> {
        self.all.clone()
    }

    fn next_frame(&mut self, timeout: Duration) -> anyhow::Result<Option<Frame>> {
        if let Some(last) = self.tick {
            let due = last + self.interval;
            let now = Instant::now();
            if due > now {
                let wait = due - now;
                if wait > timeout {
                    std::thread::sleep(timeout);
                    return Ok(None);
                }
                std::thread::sleep(wait);
            }
        }
        self.tick = Some(Instant::now());
        let idle_refresh = self.last.is_none_or(|l| l.elapsed() >= IDLE_REFRESH);
        if !self.changed() && !idle_refresh {
            // nothing drawn: wait for the next tick without grabbing or encoding
            return Ok(None);
        }
        if let Some(d) = self.damage {
            let _ = self.conn.damage_subtract(d, x11rb::NONE, x11rb::NONE);
            let _ = self.conn.flush();
        }
        self.dirty = false;
        self.last = Some(Instant::now());
        self.grab().map(Some)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 3×3 cursor: opaque red centre pixel, half-transparent white corner, rest clear.
    fn cursor() -> Vec<u32> {
        let mut c = vec![0u32; 9];
        c[4] = 0xFFFF_0000; // opaque red
        c[0] = 0x8080_8080; // 50% white, premultiplied
        c
    }

    #[test]
    fn cursor_blends_on_16_24_32_bpp_without_overflowing() {
        let argb = cursor();
        let cur = CursorImage { argb: &argb, width: 3, height: 3 };
        for (bpp, step) in [(32u8, 4usize), (24, 3), (16, 2)] {
            let (w, h) = (4usize, 3usize);
            let stride = row_bytes(w, bpp, 32);
            let mut img = vec![0u8; stride * h];
            // cursor centre on pixel (1, 1); the cursor also hangs off the right/bottom edge
            blend_cursor(&mut img, w, h, stride, bpp, &cur, 0, 0);
            let px = |img: &[u8], x: usize, y: usize| img[y * stride + x * step..y * stride + x * step + step].to_vec();
            match bpp {
                16 => {
                    assert_eq!(px(&img, 1, 1), 0xF800u16.to_le_bytes().to_vec(), "red in RGB565");
                    let v = u16::from_le_bytes([img[0], img[1]]);
                    assert!(v != 0 && v != 0xFFFF, "half white blends: {v:#x}");
                }
                _ => {
                    assert_eq!(&px(&img, 1, 1)[..3], &[0, 0, 255], "red in BGR");
                    assert_eq!(&px(&img, 0, 0)[..3], &[128, 128, 128]);
                }
            }
            assert!(px(&img, 2, 2).iter().all(|&b| b == 0), "transparent pixels untouched ({bpp} bpp)");
            // off every edge, partly outside, and with a buffer shorter than claimed: no panic
            for (ox, oy) in [(-2, -2), (3, 2), (100, 100), (-100, 0), (i32::MAX, i32::MIN)] {
                blend_cursor(&mut img, w, h, stride, bpp, &cur, ox, oy);
            }
            let mut short = vec![0u8; stride * h - 1];
            blend_cursor(&mut short, w, h, stride, bpp, &cur, 1, 1);
        }
        // unknown layouts are left alone
        let mut img = vec![7u8; 64];
        blend_cursor(&mut img, 4, 4, 4, 8, &cur, 0, 0);
        assert!(img.iter().all(|&b| b == 7));
    }

    #[test]
    fn pixmaps_are_repacked_to_bgrx() {
        // 2×2 at 24 bpp, rows padded to 32 bits (6 → 8 bytes)
        let src = vec![1, 2, 3, 4, 5, 6, 0, 0, 7, 8, 9, 10, 11, 12, 0, 0];
        let out = to_bgrx(src, 2, 2, 24, 32).unwrap();
        assert_eq!(out, vec![1, 2, 3, 0, 4, 5, 6, 0, 7, 8, 9, 0, 10, 11, 12, 0]);
        // 32 bpp passes through (trailing bytes of a larger SHM segment dropped)
        let src: Vec<u8> = (0..20).collect();
        assert_eq!(to_bgrx(src, 2, 2, 32, 32).unwrap(), (0..16).collect::<Vec<u8>>());
        // short or unsupported images are refused, not indexed past the end
        assert!(to_bgrx(vec![0; 15], 2, 2, 32, 32).is_none());
        assert!(to_bgrx(vec![0; 15], 2, 2, 24, 32).is_none());
        assert!(to_bgrx(vec![0; 64], 2, 2, 16, 32).is_none());
    }

    /// Needs an X server (`DISPLAY`): an idle screen yields the first frame plus
    /// the periodic refresh only. `cargo test -p lumora-media x11_idle -- --ignored`
    #[test]
    #[ignore]
    fn x11_idle_screen_is_not_regrabbed() {
        let opts = CaptureOptions { fps: 60, cursor: false, restore_token: None, source: crate::CaptureSource::Monitor };
        let mut c = X11Capturer::open(0, &opts).expect("X server");
        assert!(c.damage.is_some(), "DAMAGE extension missing");
        let t = Instant::now();
        let mut frames = 0;
        while t.elapsed() < Duration::from_secs(3) {
            if c.next_frame(Duration::from_millis(100)).unwrap().is_some() {
                frames += 1;
            }
        }
        eprintln!("{frames} frames in 3 s at 60 fps on an idle screen");
        assert!(frames <= 4, "{frames} grabs on an idle screen");
    }
}

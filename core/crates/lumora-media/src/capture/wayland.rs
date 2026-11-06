//! Wayland screen capture: xdg-desktop-portal ScreenCast + PipeWire.
//!
//! Threads:
//! * **portal thread** — owns a tokio current-thread runtime and the D-Bus
//!   connection. It negotiates the session (the compositor shows its
//!   permission dialog unless a valid restore token is supplied), hands the
//!   PipeWire fd + node id back, then keeps the session alive until the
//!   capturer is dropped (the portal closes sessions whose D-Bus client goes
//!   away).
//! * **PipeWire thread** — runs a `pw::MainLoop`, connects to the portal's
//!   PipeWire remote and consumes the video node, copying SHM/MemFd buffers
//!   into a bounded [`FrameQueue`] (capacity 2, drop-oldest).

use std::os::fd::OwnedFd;
use std::sync::mpsc;
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

use anyhow::{anyhow, Context};
use ashpd::desktop::screencast::{CursorMode, Screencast, SelectSourcesOptions, SourceType};
use ashpd::desktop::PersistMode;
use bytes::Bytes;

use super::{FpsLimiter, FrameQueue};
use crate::{CaptureOptions, Capturer, DisplayInfo, Frame, PixelFormat};

/// How long we wait for the user to answer the portal dialog.
fn portal_timeout() -> Duration {
    let secs = std::env::var("LUMORA_PORTAL_TIMEOUT_SECS").ok().and_then(|s| s.parse().ok()).unwrap_or(60u64);
    Duration::from_secs(secs.clamp(5, 600))
}

struct PortalResult {
    fd: OwnedFd,
    node_id: u32,
    size: Option<(i32, i32)>,
    position: Option<(i32, i32)>,
    restore_token: Option<String>,
}

pub struct PortalCapturer {
    queue: Arc<FrameQueue>,
    display: DisplayInfo,
    pw_quit: Option<pipewire::channel::Sender<()>>,
    pw_thread: Option<JoinHandle<()>>,
    portal_quit: Option<tokio::sync::oneshot::Sender<()>>,
    portal_thread: Option<JoinHandle<()>>,
}

impl PortalCapturer {
    pub fn open(display: u32, opts: &CaptureOptions) -> anyhow::Result<(Self, Option<String>)> {
        let (res_tx, res_rx) = mpsc::channel::<anyhow::Result<PortalResult>>();
        let (quit_tx, quit_rx) = tokio::sync::oneshot::channel::<()>();
        let cursor = opts.cursor;
        let source = opts.source;
        let token = opts.restore_token.clone().filter(|t| !t.is_empty());

        let portal_thread = std::thread::Builder::new()
            .name("lumora-portal".into())
            .spawn(move || {
                let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
                    Ok(rt) => rt,
                    Err(e) => {
                        let _ = res_tx.send(Err(anyhow!("cannot start async runtime for the portal: {e}")));
                        return;
                    }
                };
                rt.block_on(async move {
                    match negotiate(cursor, token.as_deref(), source).await {
                        Ok((proxy, session, res)) => {
                            let _ = res_tx.send(Ok(res));
                            // Keep the D-Bus connection (and thus the session) alive.
                            let _ = quit_rx.await;
                            let _ = session.close().await;
                            drop(proxy);
                        }
                        Err(e) => {
                            let _ = res_tx.send(Err(e));
                        }
                    }
                });
            })
            .context("failed to spawn portal thread")?;

        let timeout = portal_timeout();
        let res = match res_rx.recv_timeout(timeout) {
            Ok(Ok(r)) => r,
            Ok(Err(e)) => {
                let _ = quit_tx.send(());
                let _ = portal_thread.join();
                return Err(e);
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                // Leave the thread to finish on its own; dropping quit_tx ends it
                // once the dialog is answered.
                drop(quit_tx);
                anyhow::bail!(
                    "timed out after {}s waiting for the screen-sharing permission dialog \
                     (xdg-desktop-portal ScreenCast). Make sure the dialog is answered; \
                     run diagnostics for details",
                    timeout.as_secs()
                );
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                let _ = portal_thread.join();
                anyhow::bail!("the xdg-desktop-portal negotiation thread crashed (unexpected portal reply)");
            }
        };

        let (w, h) = res.size.map(|(w, h)| (w.max(0) as u32, h.max(0) as u32)).unwrap_or((0, 0));
        let (x, y) = res.position.unwrap_or((0, 0));
        let display_info = DisplayInfo {
            index: display,
            name: format!("pipewire-node-{}", res.node_id),
            width: w,
            height: h,
            x,
            y,
            scale: 1.0,
            primary: true,
        };

        let queue = FrameQueue::new(2);
        let (pw_tx, pw_rx) = pipewire::channel::channel::<()>();
        let (ready_tx, ready_rx) = mpsc::channel::<anyhow::Result<()>>();
        let q2 = queue.clone();
        let fps = opts.fps.clamp(1, 240);
        let node_id = res.node_id;
        let fd = res.fd;
        let pw_thread = std::thread::Builder::new()
            .name("lumora-pipewire".into())
            .spawn(move || {
                let q3 = q2.clone();
                if let Err(e) = run_pipewire(fd, node_id, fps, q2, pw_rx, ready_tx) {
                    tracing::warn!("pipewire capture thread ended: {e:#}");
                    q3.close(format!("{e:#}"));
                } else {
                    q3.close("PipeWire stream stopped");
                }
            })
            .context("failed to spawn PipeWire thread")?;

        let mut me = Self {
            queue,
            display: display_info,
            pw_quit: Some(pw_tx),
            pw_thread: Some(pw_thread),
            portal_quit: Some(quit_tx),
            portal_thread: Some(portal_thread),
        };
        match ready_rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Ok(())) => {}
            Ok(Err(e)) => return Err(e),
            Err(_) => {
                me.shutdown();
                anyhow::bail!("PipeWire did not respond while connecting to the screencast stream");
            }
        }
        Ok((me, res.restore_token))
    }

    fn shutdown(&mut self) {
        if let Some(tx) = self.pw_quit.take() {
            let _ = tx.send(());
        }
        if let Some(t) = self.pw_thread.take() {
            let _ = t.join();
        }
        if let Some(tx) = self.portal_quit.take() {
            let _ = tx.send(());
        }
        if let Some(t) = self.portal_thread.take() {
            let _ = t.join();
        }
    }
}

impl Drop for PortalCapturer {
    fn drop(&mut self) {
        self.shutdown();
    }
}

impl Capturer for PortalCapturer {
    fn displays(&self) -> Vec<DisplayInfo> {
        vec![self.display.clone()]
    }

    fn next_frame(&mut self, timeout: Duration) -> anyhow::Result<Option<Frame>> {
        let f = self.queue.pop(timeout)?;
        if let Some(f) = &f {
            // The portal may not report a size (or the output may be resized).
            if self.display.width == 0 || self.display.height == 0 {
                self.display.width = f.width;
                self.display.height = f.height;
            } else if self.display.width != f.width && f.width > 0 {
                // Frame is in device pixels; derive the scale factor.
                self.display.scale = f.width as f32 / self.display.width as f32;
            }
        }
        Ok(f)
    }
}

fn describe_portal_error(e: ashpd::Error) -> anyhow::Error {
    let msg = e.to_string();
    let lower = msg.to_lowercase();
    if lower.contains("cancel") {
        anyhow!("screen sharing was denied or cancelled in the portal dialog ({msg})")
    } else if lower.contains("serviceunknown") || lower.contains("not provided") || lower.contains("unknownmethod")
        || lower.contains("no such interface") || lower.contains("unknowninterface")
    {
        anyhow!(
            "xdg-desktop-portal ScreenCast interface is not available ({msg}); install the portal \
             backend for your desktop (xdg-desktop-portal-gnome/-kde/-wlr/-hyprland/-cosmic)"
        )
    } else {
        anyhow!("xdg-desktop-portal ScreenCast request failed: {msg}")
    }
}

/// Tell the portal who we are, so dialogs say "Lumora" instead of "Unknown Application".
/// Must run before the first portal request on this connection; failures are harmless.
async fn register_app_id() {
    if let Ok(id) = ashpd::AppID::try_from("vn.lumora.Lumora") {
        let _ = ashpd::register_host_app(id).await;
    }
}

async fn negotiate(
    cursor: bool,
    token: Option<&str>,
    source: crate::CaptureSource,
) -> anyhow::Result<(Screencast, ashpd::desktop::Session<Screencast>, PortalResult)> {
    register_app_id().await;
    let proxy = Screencast::new().await.map_err(describe_portal_error)?;
    let available = proxy.available_source_types().await.unwrap_or_else(|_| SourceType::Monitor.into());
    let wanted: ashpd::enumflags2::BitFlags<SourceType> = match source {
        crate::CaptureSource::Monitor => SourceType::Monitor.into(),
        crate::CaptureSource::Window => SourceType::Window.into(),
        crate::CaptureSource::Any => SourceType::Monitor | SourceType::Window,
    };
    // fall back to whatever the desktop supports (e.g. monitor-only backends)
    let sources = if (available & wanted).is_empty() { SourceType::Monitor.into() } else { available & wanted };
    let cursor_modes = proxy.available_cursor_modes().await.unwrap_or_default();
    let cursor_mode = if cursor && cursor_modes.contains(CursorMode::Embedded) {
        CursorMode::Embedded
    } else if cursor_modes.contains(CursorMode::Hidden) || cursor_modes.is_empty() {
        CursorMode::Hidden
    } else {
        CursorMode::Embedded
    };
    // Persistence (restore tokens) requires ScreenCast v4.
    let persist = proxy.version() >= 4;
    let session = proxy.create_session(Default::default()).await.map_err(describe_portal_error)?;
    let mut sel = SelectSourcesOptions::default()
        .set_cursor_mode(cursor_mode)
        .set_sources(sources)
        .set_multiple(false);
    if persist {
        sel = sel.set_persist_mode(PersistMode::ExplicitlyRevoked).set_restore_token(token);
    }
    proxy
        .select_sources(&session, sel)
        .await
        .map_err(describe_portal_error)?
        .response()
        .map_err(describe_portal_error)?;
    let streams = proxy
        .start(&session, None, Default::default())
        .await
        .map_err(describe_portal_error)?
        .response()
        .map_err(describe_portal_error)?;
    let stream = streams
        .streams()
        .first()
        .ok_or_else(|| anyhow!("the portal returned no screencast stream (nothing was selected)"))?;
    let node_id = stream.pipe_wire_node_id();
    let size = stream.size();
    let position = stream.position();
    let restore_token = streams.restore_token().map(str::to_owned);
    let fd = proxy
        .open_pipe_wire_remote(&session, Default::default())
        .await
        .map_err(describe_portal_error)?;
    Ok((proxy, session, PortalResult { fd, node_id, size, position, restore_token }))
}

struct StreamData {
    format: pipewire::spa::param::video::VideoInfoRaw,
    pix: Option<PixelFormat>,
    limiter: FpsLimiter,
    queue: Arc<FrameQueue>,
    warned_unmappable: bool,
}

fn run_pipewire(
    fd: OwnedFd,
    node_id: u32,
    fps: u32,
    queue: Arc<FrameQueue>,
    quit_rx: pipewire::channel::Receiver<()>,
    ready: mpsc::Sender<anyhow::Result<()>>,
) -> anyhow::Result<()> {
    use pipewire as pw;
    use pw::spa;
    use pw::spa::param::video::VideoFormat;
    use pw::spa::pod::Pod;

    pw::init();
    let setup = || -> anyhow::Result<_> {
        let mainloop = pw::main_loop::MainLoopRc::new(None).map_err(|e| anyhow!("pw_main_loop_new failed: {e}"))?;
        let context = pw::context::ContextRc::new(&mainloop, None).map_err(|e| anyhow!("pw_context_new failed: {e}"))?;
        let core = context
            .connect_fd_rc(fd, None)
            .map_err(|e| anyhow!("cannot connect to the portal's PipeWire remote: {e}"))?;
        Ok((mainloop, context, core))
    };
    let (mainloop, _context, core) = match setup() {
        Ok(v) => v,
        Err(e) => {
            let _ = ready.send(Err(anyhow!("{e:#}")));
            return Err(e);
        }
    };

    let ml_weak = mainloop.downgrade();
    let _quit = quit_rx.attach(mainloop.loop_(), move |_| {
        if let Some(ml) = ml_weak.upgrade() {
            ml.quit();
        }
    });

    let stream = pw::stream::StreamBox::new(
        &core,
        "lumora-screen",
        pw::properties::properties! {
            *pw::keys::MEDIA_TYPE => "Video",
            *pw::keys::MEDIA_CATEGORY => "Capture",
            *pw::keys::MEDIA_ROLE => "Screen",
        },
    )
    .map_err(|e| anyhow!("cannot create PipeWire stream: {e}"))?;

    let data = StreamData {
        format: Default::default(),
        pix: None,
        limiter: FpsLimiter::new(fps),
        queue: queue.clone(),
        warned_unmappable: false,
    };

    let ml_weak2 = mainloop.downgrade();
    let q_state = queue.clone();
    let _listener = stream
        .add_local_listener_with_user_data(data)
        .state_changed(move |_, _, old, new| {
            tracing::debug!("pipewire stream state {old:?} -> {new:?}");
            if let pw::stream::StreamState::Error(msg) = new {
                q_state.close(format!("PipeWire stream error: {msg}"));
                if let Some(ml) = ml_weak2.upgrade() {
                    ml.quit();
                }
            }
        })
        .param_changed(|stream, ud, id, param| {
            let Some(param) = param else { return };
            if id != pw::spa::param::ParamType::Format.as_raw() {
                return;
            }
            let Ok((mt, mst)) = pw::spa::param::format_utils::parse_format(param) else { return };
            if mt != pw::spa::param::format::MediaType::Video || mst != pw::spa::param::format::MediaSubtype::Raw {
                return;
            }
            if ud.format.parse(param).is_err() {
                return;
            }
            ud.pix = match ud.format.format() {
                VideoFormat::BGRx | VideoFormat::BGRA => Some(PixelFormat::Bgra),
                VideoFormat::RGBx | VideoFormat::RGBA => Some(PixelFormat::Rgba),
                other => {
                    tracing::warn!("unsupported negotiated video format {other:?}");
                    None
                }
            };
            tracing::debug!(
                "negotiated {:?} {}x{}",
                ud.format.format(),
                ud.format.size().width,
                ud.format.size().height
            );
            // Ask for shared-memory buffers we can map (MemFd / MemPtr).
            let mask = (1i32 << spa::sys::SPA_DATA_MemFd) | (1i32 << spa::sys::SPA_DATA_MemPtr);
            let obj = spa::pod::Object {
                type_: spa::utils::SpaTypes::ObjectParamBuffers.as_raw(),
                id: spa::param::ParamType::Buffers.as_raw(),
                properties: vec![spa::pod::Property {
                    key: spa::sys::SPA_PARAM_BUFFERS_dataType,
                    flags: spa::pod::PropertyFlags::empty(),
                    value: spa::pod::Value::Int(mask),
                }],
            };
            if let Ok(bytes) = serialize_pod(spa::pod::Value::Object(obj)) {
                if let Some(pod) = Pod::from_bytes(&bytes) {
                    let _ = stream.update_params(&mut [pod]);
                }
            }
        })
        .process(|stream, ud| {
            let Some(mut buffer) = stream.dequeue_buffer() else { return };
            let Some(pix) = ud.pix else { return };
            let size = ud.format.size();
            let (w, h) = (size.width, size.height);
            if w == 0 || h == 0 {
                return;
            }
            let datas = buffer.datas_mut();
            let Some(d) = datas.first_mut() else { return };
            let chunk = d.chunk();
            let (offset, csize, cstride) = (chunk.offset() as usize, chunk.size() as usize, chunk.stride());
            if csize == 0 {
                return; // cursor-only / no-damage update
            }
            if !ud.limiter.tick() {
                return;
            }
            let stride = if cstride > 0 { cstride as usize } else { w as usize * 4 };
            let Some(mem) = d.data() else {
                if !ud.warned_unmappable {
                    ud.warned_unmappable = true;
                    ud.queue.close(
                        "the compositor delivered GPU (DMA-BUF) buffers that cannot be mapped; \
                         SHM screencast buffers are required",
                    );
                }
                return;
            };
            let need = stride * (h as usize - 1) + w as usize * 4;
            if mem.len() < offset + need || stride < w as usize * 4 {
                return;
            }
            let end = (offset + stride * h as usize).min(mem.len());
            let bytes = Bytes::copy_from_slice(&mem[offset..end]);
            ud.queue.push(Frame { width: w, height: h, stride: stride as u32, format: pix, data: bytes, ts_us: crate::now_us() });
        })
        .register()
        .map_err(|e| anyhow!("cannot register PipeWire stream listener: {e}"))?;

    let fps_i = fps.clamp(1, 240);
    let obj = pw::spa::pod::object!(
        pw::spa::utils::SpaTypes::ObjectParamFormat,
        pw::spa::param::ParamType::EnumFormat,
        pw::spa::pod::property!(pw::spa::param::format::FormatProperties::MediaType, Id, pw::spa::param::format::MediaType::Video),
        pw::spa::pod::property!(pw::spa::param::format::FormatProperties::MediaSubtype, Id, pw::spa::param::format::MediaSubtype::Raw),
        pw::spa::pod::property!(
            pw::spa::param::format::FormatProperties::VideoFormat,
            Choice,
            Enum,
            Id,
            VideoFormat::BGRx,
            VideoFormat::BGRx,
            VideoFormat::BGRA,
            VideoFormat::RGBx,
            VideoFormat::RGBA
        ),
        pw::spa::pod::property!(
            pw::spa::param::format::FormatProperties::VideoSize,
            Choice,
            Range,
            Rectangle,
            pw::spa::utils::Rectangle { width: 1920, height: 1080 },
            pw::spa::utils::Rectangle { width: 1, height: 1 },
            pw::spa::utils::Rectangle { width: 8192, height: 8192 }
        ),
        pw::spa::pod::property!(
            pw::spa::param::format::FormatProperties::VideoFramerate,
            Choice,
            Range,
            Fraction,
            pw::spa::utils::Fraction { num: fps_i, denom: 1 },
            pw::spa::utils::Fraction { num: 0, denom: 1 },
            pw::spa::utils::Fraction { num: 1000, denom: 1 }
        ),
    );
    let values = serialize_pod(pw::spa::pod::Value::Object(obj))?;
    let pod = Pod::from_bytes(&values).ok_or_else(|| anyhow!("failed to build PipeWire format pod"))?;
    let mut params = [pod];
    if let Err(e) = stream.connect(
        spa::utils::Direction::Input,
        Some(node_id),
        pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::MAP_BUFFERS,
        &mut params,
    ) {
        let err = anyhow!("cannot connect to PipeWire screencast node {node_id}: {e}");
        let _ = ready.send(Err(anyhow!("{err:#}")));
        return Err(err);
    }
    let _ = ready.send(Ok(()));
    mainloop.run();
    let _ = stream.disconnect();
    Ok(())
}

fn serialize_pod(v: pipewire::spa::pod::Value) -> anyhow::Result<Vec<u8>> {
    Ok(pipewire::spa::pod::serialize::PodSerializer::serialize(std::io::Cursor::new(Vec::new()), &v)
        .map_err(|e| anyhow!("pod serialization failed: {e:?}"))?
        .0
        .into_inner())
}

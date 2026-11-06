//! Input injection through the xdg-desktop-portal RemoteDesktop interface
//! (GNOME/Mutter, KDE/KWin). Preferred over uinput when available: it needs no
//! device permissions and works inside Flatpak.
//!
//! A ScreenCast source is selected on the same session so that absolute
//! pointer motion can be addressed to the monitor's stream.

use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::Duration;

use anyhow::{anyhow, Context};
use ashpd::desktop::remote_desktop::{Axis, DeviceType, KeyState, RemoteDesktop, SelectDevicesOptions};
use ashpd::desktop::screencast::{CursorMode, Screencast, SelectSourcesOptions, SourceType};
use ashpd::desktop::PersistMode;
use tokio::sync::mpsc as tmpsc;

use crate::{keymap, DisplayInfo, InputInjector, MouseButton};

enum Cmd {
    Abs(f64, f64),
    Button(i32, bool),
    Axis(Axis, i32),
    Keycode(i32, bool),
    Keysym(i32, bool),
}

pub struct PortalInjector {
    tx: Option<tmpsc::UnboundedSender<Cmd>>,
    thread: Option<JoinHandle<()>>,
}

struct Ready {
    token: Option<String>,
}

impl PortalInjector {
    pub fn open(_display: &DisplayInfo, restore_token: Option<&str>) -> anyhow::Result<(Self, Option<String>)> {
        let (ready_tx, ready_rx) = mpsc::channel::<anyhow::Result<Ready>>();
        let (tx, mut rx) = tmpsc::unbounded_channel::<Cmd>();
        let token = restore_token.map(str::to_owned).filter(|t| !t.is_empty());
        let thread = std::thread::Builder::new()
            .name("lumora-rd-portal".into())
            .spawn(move || {
                let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
                    Ok(rt) => rt,
                    Err(e) => {
                        let _ = ready_tx.send(Err(anyhow!("cannot start async runtime: {e}")));
                        return;
                    }
                };
                rt.block_on(async move {
                    let setup = async {
                        let rd = RemoteDesktop::new().await?;
                        let sc = Screencast::new().await?;
                        let session = rd.create_session(Default::default()).await?;
                        let mut dev = SelectDevicesOptions::default().set_devices(DeviceType::Keyboard | DeviceType::Pointer);
                        if rd.version() >= 2 {
                            dev = dev.set_persist_mode(PersistMode::ExplicitlyRevoked).set_restore_token(token.as_deref());
                        }
                        rd.select_devices(&session, dev).await?.response()?;
                        sc.select_sources(
                            &session,
                            SelectSourcesOptions::default()
                                .set_sources(ashpd::enumflags2::BitFlags::from(SourceType::Monitor))
                                .set_multiple(false)
                                .set_cursor_mode(CursorMode::Hidden),
                        )
                        .await?
                        .response()?;
                        let sel = rd.start(&session, None, Default::default()).await?.response()?;
                        Ok::<_, ashpd::Error>((rd, session, sel))
                    };
                    let (rd, session, sel) = match setup.await {
                        Ok(v) => v,
                        Err(e) => {
                            let _ = ready_tx.send(Err(anyhow!("RemoteDesktop portal request failed: {e}")));
                            return;
                        }
                    };
                    if !sel.devices().contains(DeviceType::Pointer) && !sel.devices().contains(DeviceType::Keyboard) {
                        let _ = ready_tx.send(Err(anyhow!("remote control was not granted in the portal dialog")));
                        return;
                    }
                    let stream = sel.streams().first();
                    let node = stream.map(|s| s.pipe_wire_node_id());
                    let (sw, sh) = stream
                        .and_then(|s| s.size())
                        .map(|(w, h)| (w.max(1) as f64, h.max(1) as f64))
                        .unwrap_or((1920.0, 1080.0));
                    let _ = ready_tx.send(Ok(Ready { token: sel.restore_token().map(str::to_owned) }));
                    while let Some(cmd) = rx.recv().await {
                        let r = match cmd {
                            Cmd::Abs(x, y) => match node {
                                Some(n) => {
                                    rd.notify_pointer_motion_absolute(&session, n, x * (sw - 1.0), y * (sh - 1.0), Default::default())
                                        .await
                                }
                                None => Ok(()),
                            },
                            Cmd::Button(b, d) => {
                                rd.notify_pointer_button(&session, b, state(d), Default::default()).await
                            }
                            Cmd::Axis(a, n) => rd.notify_pointer_axis_discrete(&session, a, n, Default::default()).await,
                            Cmd::Keycode(k, d) => {
                                rd.notify_keyboard_keycode(&session, k, state(d), Default::default()).await
                            }
                            Cmd::Keysym(k, d) => {
                                rd.notify_keyboard_keysym(&session, k, state(d), Default::default()).await
                            }
                        };
                        if let Err(e) = r {
                            tracing::warn!("RemoteDesktop portal call failed: {e}");
                        }
                    }
                    let _ = session.close().await;
                });
            })
            .context("failed to spawn portal thread")?;

        let timeout = Duration::from_secs(
            std::env::var("LUMORA_PORTAL_TIMEOUT_SECS").ok().and_then(|s| s.parse().ok()).unwrap_or(60u64).clamp(5, 600),
        );
        match ready_rx.recv_timeout(timeout) {
            Ok(Ok(r)) => Ok((Self { tx: Some(tx), thread: Some(thread) }, r.token)),
            Ok(Err(e)) => {
                let _ = thread.join();
                Err(e)
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                anyhow::bail!("timed out after {}s waiting for the remote-control permission dialog", timeout.as_secs())
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                let _ = thread.join();
                anyhow::bail!("the RemoteDesktop portal thread crashed (unexpected portal reply)")
            }
        }
    }

    fn send(&self, c: Cmd) -> anyhow::Result<()> {
        self.tx
            .as_ref()
            .and_then(|t| t.send(c).ok())
            .ok_or_else(|| anyhow!("the RemoteDesktop portal session has ended"))
    }
}

fn state(down: bool) -> KeyState {
    if down {
        KeyState::Pressed
    } else {
        KeyState::Released
    }
}

impl Drop for PortalInjector {
    fn drop(&mut self) {
        self.tx.take();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn char_keysym(c: char) -> i32 {
    match c {
        '\n' | '\r' => 0xff0d,
        '\t' => 0xff09,
        c if (0x20..=0x7e).contains(&(c as u32)) || (0xa0..=0xff).contains(&(c as u32)) => c as i32,
        c => (0x0100_0000 | c as u32) as i32,
    }
}

impl InputInjector for PortalInjector {
    fn mouse_move_abs(&mut self, x: f64, y: f64) -> anyhow::Result<()> {
        let x = if x.is_finite() { x.clamp(0.0, 1.0) } else { 0.0 };
        let y = if y.is_finite() { y.clamp(0.0, 1.0) } else { 0.0 };
        self.send(Cmd::Abs(x, y))
    }
    fn button(&mut self, b: MouseButton, down: bool) -> anyhow::Result<()> {
        let code = match b {
            MouseButton::Left => 0x110,
            MouseButton::Right => 0x111,
            MouseButton::Middle => 0x112,
            MouseButton::Back => 0x113,
            MouseButton::Forward => 0x114,
        };
        self.send(Cmd::Button(code, down))
    }
    fn wheel(&mut self, dx: i32, dy: i32) -> anyhow::Result<()> {
        if dy != 0 {
            self.send(Cmd::Axis(Axis::Vertical, dy.clamp(-100, 100)))?;
        }
        if dx != 0 {
            self.send(Cmd::Axis(Axis::Horizontal, dx.clamp(-100, 100)))?;
        }
        Ok(())
    }
    fn key(&mut self, code: &str, down: bool) -> anyhow::Result<()> {
        let e = keymap::lookup(code).ok_or_else(|| anyhow!("unknown key code {code:?}"))?;
        if e.evdev == keymap::NONE {
            anyhow::bail!("key {code:?} has no Linux equivalent");
        }
        self.send(Cmd::Keycode(e.evdev as i32, down))
    }
    fn text(&mut self, s: &str) -> anyhow::Result<()> {
        for c in s.chars() {
            let ks = char_keysym(c);
            self.send(Cmd::Keysym(ks, true))?;
            self.send(Cmd::Keysym(ks, false))?;
        }
        Ok(())
    }
    fn backend(&self) -> &'static str {
        "portal"
    }
}

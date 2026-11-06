//! Environment diagnostics for screen capture and remote input.
//!
//! [`diagnostics`] never panics and never blocks for long (D-Bus queries
//! time out after 3 s). Texts (`title`, `detail`, `fix_steps`) are Vietnamese
//! technical notes; the app shows its own plain, localized title/summary/fix keyed
//! by the stable English `id` and keeps these texts plus `commands` (terminal
//! commands, never mixed into `fix_steps`) under "Technical details". The user guide
//! `docs/src/user/wayland.md` mirrors these fix steps.

use serde::{Deserialize, Serialize};

/// Severity of a failing check.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    /// Purely informational (never blocks anything).
    Info,
    /// A feature is degraded or an alternative path is used.
    Warning,
    /// A feature cannot work until fixed.
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Check {
    pub id: String,
    pub ok: bool,
    pub severity: Severity,
    pub title: String,
    pub detail: String,
    /// Plain-language steps (no shell commands).
    pub fix_steps: Vec<String>,
    /// Terminal commands for the fix, kept apart so the UI can show them only under
    /// "Technical details".
    #[serde(default)]
    pub commands: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Diagnostics {
    pub platform: String,
    /// `wayland`, `x11`, `tty`, `windows`, `macos`, … (`XDG_SESSION_TYPE` on Linux).
    pub session_type: String,
    /// `XDG_CURRENT_DESKTOP` on Linux (e.g. `COSMIC`, `GNOME`, `KDE`, `sway`).
    pub desktop: String,
    /// Which capture backend `open_capturer` will use.
    pub capture_backend: String,
    /// Which input backend `open_injector` is expected to use (`none` if none works).
    pub input_backend: String,
    pub checks: Vec<Check>,
}

impl Diagnostics {
    /// True when no check with `Error` severity failed.
    pub fn all_ok(&self) -> bool {
        self.checks.iter().all(|c| c.ok || c.severity != Severity::Error)
    }
}

fn check(id: &str, ok: bool, severity: Severity, title: &str, detail: impl Into<String>, fix: Vec<String>) -> Check {
    let (commands, steps): (Vec<String>, Vec<String>) = if ok { (Vec::new(), Vec::new()) } else { fix.into_iter().partition(|f| is_command(f)) };
    Check {
        id: id.into(),
        ok,
        severity: if ok { Severity::Info } else { severity },
        title: title.into(),
        detail: detail.into(),
        fix_steps: steps,
        commands,
    }
}

/// Does this fix step contain a terminal command (possibly after a short label such as
/// "Kiểm tra: ls …")?
fn is_command(step: &str) -> bool {
    const WORDS: &[&str] = &[
        "sudo", "flatpak", "systemctl", "mkdir", "echo", "ls", "printf", "gsettings", "snap", "loginctl", "dbus-send", "busctl",
        "modprobe", "usermod", "udevadm", "xhost", "kwriteconfig5", "kwriteconfig6", "export", "cat", "grep", "pactl", "wpctl",
        "setcap", "sh", "bash", "apt", "dnf", "pacman", "zypper", "tccutil", "open", "reg", "powershell", "netsh", "xdg-open",
        "pkill", "killall", "rm", "cp", "ln", "chmod", "groups", "id", "env", "dconf", "pw-cli", "pipewire",
    ];
    let looks = |t: &str| {
        let t = t.trim().trim_start_matches("$ ");
        let first = t.split_whitespace().next().unwrap_or("");
        t.is_ascii() && (WORDS.contains(&first) || t.contains(" | ") || t.contains(" && ") || t.contains(" > "))
    };
    looks(step) || step.split_once(": ").map(|(_, t)| looks(t)).unwrap_or(false)
}

fn s(v: &[&str]) -> Vec<String> {
    v.iter().map(|x| x.to_string()).collect()
}

/// Run all checks for the current platform.
pub fn diagnostics() -> Diagnostics {
    match std::panic::catch_unwind(imp::run) {
        Ok(d) => d,
        Err(_) => Diagnostics {
            platform: std::env::consts::OS.into(),
            session_type: "unknown".into(),
            desktop: String::new(),
            capture_backend: "unknown".into(),
            input_backend: "unknown".into(),
            checks: vec![check(
                "internal",
                false,
                Severity::Warning,
                "Lỗi nội bộ khi chẩn đoán",
                "Trình chẩn đoán gặp lỗi bất ngờ; kết quả không đầy đủ.",
                s(&["Hãy gửi báo cáo lỗi kèm phiên bản Lumora và hệ điều hành."]),
            )],
        },
    }
}

/// Version of a portal frontend interface (e.g.
/// `org.freedesktop.portal.ScreenCast`), or `None` if it is not exported.
#[cfg(target_os = "linux")]
pub fn portal_interface_version(iface: &str) -> Option<u32> {
    imp::portal_versions(&[iface]).into_iter().next().flatten()
}

#[cfg(not(target_os = "linux"))]
pub fn portal_interface_version(_iface: &str) -> Option<u32> {
    None
}

#[cfg(target_os = "linux")]
mod imp {
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    use super::*;

    const UDEV_RULE_CMD: &str = "echo 'KERNEL==\"uinput\", GROUP=\"input\", MODE=\"0660\", OPTIONS+=\"static_node=uinput\"' | sudo tee /etc/udev/rules.d/60-lumora-uinput.rules";

    #[derive(Clone, Copy, PartialEq, Eq, Debug)]
    enum Family {
        Gnome,
        Kde,
        Cosmic,
        Wlroots(&'static str),
        Hyprland,
        Other,
    }

    #[derive(Clone, Copy)]
    enum Pm {
        Apt,
        Dnf,
        Pacman,
        Zypper,
        Unknown,
    }

    fn pkg_manager() -> Pm {
        let txt = std::fs::read_to_string("/etc/os-release").unwrap_or_default();
        let mut ids = String::new();
        for line in txt.lines() {
            if let Some(v) = line.strip_prefix("ID=").or_else(|| line.strip_prefix("ID_LIKE=")) {
                ids.push(' ');
                ids.push_str(&v.trim_matches('"').to_lowercase());
            }
        }
        if ids.contains("debian") || ids.contains("ubuntu") || ids.contains("pop") {
            Pm::Apt
        } else if ids.contains("fedora") || ids.contains("rhel") {
            Pm::Dnf
        } else if ids.contains("arch") {
            Pm::Pacman
        } else if ids.contains("suse") {
            Pm::Zypper
        } else {
            Pm::Unknown
        }
    }

    fn install_cmd(pkg: &str) -> String {
        match pkg_manager() {
            Pm::Apt => format!("sudo apt install {pkg}"),
            Pm::Dnf => format!("sudo dnf install {pkg}"),
            Pm::Pacman => format!("sudo pacman -S {pkg}"),
            Pm::Zypper => format!("sudo zypper install {pkg}"),
            Pm::Unknown => format!("Cài gói `{pkg}` bằng trình quản lý gói của bản phân phối"),
        }
    }

    fn family(desktop: &str) -> Family {
        let d = desktop.to_lowercase();
        if std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_some() || d.contains("hyprland") {
            Family::Hyprland
        } else if d.contains("cosmic") {
            Family::Cosmic
        } else if d.contains("gnome") || d.contains("unity") || d.contains("ubuntu") || d.contains("pop") {
            Family::Gnome
        } else if d.contains("kde") || d.contains("plasma") {
            Family::Kde
        } else if std::env::var_os("SWAYSOCK").is_some() || d.contains("sway") {
            Family::Wlroots("sway")
        } else if d.contains("river") {
            Family::Wlroots("river")
        } else if d.contains("wayfire") {
            Family::Wlroots("wayfire")
        } else if d.contains("labwc") {
            Family::Wlroots("labwc")
        } else if d.contains("niri") {
            Family::Gnome // niri implements the GNOME/Mutter screencast API
        } else {
            Family::Other
        }
    }

    fn portal_backend(f: Family) -> (&'static str, &'static str) {
        // (portal file stem, package)
        match f {
            Family::Gnome => ("gnome", "xdg-desktop-portal-gnome"),
            Family::Kde => ("kde", "xdg-desktop-portal-kde"),
            Family::Cosmic => ("cosmic", "xdg-desktop-portal-cosmic"),
            Family::Hyprland => ("hyprland", "xdg-desktop-portal-hyprland"),
            Family::Wlroots(_) | Family::Other => ("wlr", "xdg-desktop-portal-wlr"),
        }
    }

    fn runtime_dir() -> Option<PathBuf> {
        std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from)
    }

    /// Query `version` of several portal interfaces at once (one D-Bus connection).
    pub(super) fn portal_versions(ifaces: &[&str]) -> Vec<Option<u32>> {
        let owned: Vec<String> = ifaces.iter().map(|s| s.to_string()).collect();
        let n = owned.len();
        let h = std::thread::Builder::new().name("lumora-diag-dbus".into()).spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().ok()?;
            rt.block_on(async move {
                let fut = async {
                    let conn = ashpd::zbus::Connection::session().await.ok()?;
                    let mut out = Vec::new();
                    for i in &owned {
                        let v = async {
                            let p = ashpd::zbus::proxy::Builder::<ashpd::zbus::Proxy>::new(&conn)
                                .destination("org.freedesktop.portal.Desktop")
                                .ok()?
                                .path("/org/freedesktop/portal/desktop")
                                .ok()?
                                .interface(i.as_str())
                                .ok()?
                                .cache_properties(ashpd::zbus::proxy::CacheProperties::No)
                                .build()
                                .await
                                .ok()?;
                            p.get_property::<u32>("version").await.ok()
                        }
                        .await;
                        out.push(v);
                    }
                    Some(out)
                };
                tokio::time::timeout(Duration::from_secs(3), fut).await.ok().flatten()
            })
        });
        h.ok().and_then(|h| h.join().ok().flatten()).unwrap_or_else(|| vec![None; n])
    }

    fn session_bus_ok() -> bool {
        if let Some(addr) = std::env::var_os("DBUS_SESSION_BUS_ADDRESS") {
            let a = addr.to_string_lossy();
            if let Some(p) = a.strip_prefix("unix:path=") {
                return Path::new(p.split(',').next().unwrap_or(p)).exists();
            }
            return true;
        }
        runtime_dir().map(|d| d.join("bus").exists()).unwrap_or(false)
    }

    fn writable(p: &Path) -> bool {
        let Ok(c) = std::ffi::CString::new(p.as_os_str().as_encoded_bytes()) else { return false };
        // SAFETY: valid NUL-terminated path.
        unsafe { libc::access(c.as_ptr(), libc::W_OK) == 0 }
    }

    fn process_in_group(gid: u32) -> bool {
        // SAFETY: getgroups with a sized buffer.
        unsafe {
            if libc::getegid() == gid {
                return true;
            }
            let n = libc::getgroups(0, std::ptr::null_mut());
            if n <= 0 {
                return false;
            }
            let mut v = vec![0 as libc::gid_t; n as usize];
            let n = libc::getgroups(n, v.as_mut_ptr());
            n > 0 && v[..n as usize].contains(&gid)
        }
    }

    fn group_gid(name: &str) -> Option<u32> {
        let txt = std::fs::read_to_string("/etc/group").ok()?;
        txt.lines().find_map(|l| {
            let mut it = l.split(':');
            (it.next()? == name).then(|| it.nth(1)?.parse().ok()).flatten()
        })
    }

    fn user_listed_in_group(name: &str, user: &str) -> bool {
        std::fs::read_to_string("/etc/group")
            .ok()
            .and_then(|t| {
                t.lines().find(|l| l.split(':').next() == Some(name)).map(|l| {
                    l.split(':').nth(3).unwrap_or("").split(',').any(|m| m.trim() == user)
                })
            })
            .unwrap_or(false)
    }

    fn which(bin: &str) -> bool {
        std::env::var_os("PATH")
            .map(|p| std::env::split_paths(&p).any(|d| d.join(bin).is_file()))
            .unwrap_or(false)
    }

    fn portal_impl_has(stem: &str, iface: &str) -> Option<bool> {
        let dirs = ["/usr/share/xdg-desktop-portal/portals", "/usr/local/share/xdg-desktop-portal/portals"];
        for d in dirs {
            let p = Path::new(d).join(format!("{stem}.portal"));
            if let Ok(t) = std::fs::read_to_string(&p) {
                return Some(t.contains(&format!("org.freedesktop.impl.portal.{iface}")));
            }
        }
        None
    }

    pub(super) fn run() -> Diagnostics {
        let session_type = std::env::var("XDG_SESSION_TYPE").unwrap_or_else(|_| {
            if std::env::var_os("WAYLAND_DISPLAY").is_some() {
                "wayland".into()
            } else if std::env::var_os("DISPLAY").is_some() {
                "x11".into()
            } else {
                "tty".into()
            }
        });
        let desktop = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default();
        let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some() || session_type == "wayland";
        let fam = family(&desktop);
        let (stem, portal_pkg) = portal_backend(fam);
        let flatpak = std::env::var_os("FLATPAK_ID").is_some() || Path::new("/.flatpak-info").exists();
        let snap = std::env::var_os("SNAP").is_some();
        let app_id = std::env::var("FLATPAK_ID").unwrap_or_else(|_| "<APP_ID>".into());
        let user = std::env::var("USER").unwrap_or_else(|_| "$USER".into());
        let mut checks = Vec::new();

        let restart_portal = format!(
            "systemctl --user restart xdg-desktop-portal xdg-desktop-portal-{stem} pipewire wireplumber"
        );

        // --- Session / desktop ------------------------------------------
        let fam_name = match fam {
            Family::Gnome => "GNOME (Mutter)".to_string(),
            Family::Kde => "KDE Plasma (KWin)".to_string(),
            Family::Cosmic => "COSMIC (cosmic-comp)".to_string(),
            Family::Hyprland => "Hyprland".to_string(),
            Family::Wlroots(n) => format!("{n} (wlroots)"),
            Family::Other => if desktop.is_empty() { "không rõ".into() } else { desktop.clone() },
        };
        checks.push(check(
            "session",
            session_type == "wayland" || session_type == "x11",
            Severity::Error,
            "Phiên đồ họa",
            format!("Loại phiên: {session_type}; môi trường desktop: {fam_name}."),
            s(&[
                "Lumora cần chạy bên trong một phiên đồ họa (Wayland hoặc X11), không phải TTY/SSH.",
                "Đăng nhập vào desktop rồi mở Lumora từ đó.",
            ]),
        ));

        // --- Sandbox ----------------------------------------------------------
        if flatpak {
            checks.push(check(
                "sandbox_flatpak",
                false,
                Severity::Warning,
                "Đang chạy trong Flatpak",
                "Chia sẻ màn hình qua portal hoạt động bình thường, nhưng Flatpak chặn /dev/uinput nên điều khiển từ xa \
                 trên COSMIC/wlroots sẽ không hoạt động nếu không cấp thêm quyền.",
                vec![
                    format!("flatpak override --user --device=all {app_id}"),
                    format!("flatpak override --user --socket=wayland --socket=fallback-x11 {app_id}"),
                    "Khởi động lại Lumora.".into(),
                    format!("Để hoàn tác: flatpak override --user --reset {app_id}"),
                ],
            ));
        }
        if snap {
            checks.push(check(
                "sandbox_snap",
                false,
                Severity::Warning,
                "Đang chạy trong Snap",
                "Snap cần được kết nối các interface để chia sẻ màn hình và điều khiển từ xa.",
                s(&[
                    "sudo snap connect lumora:screencast-legacy",
                    "sudo snap connect lumora:uinput",
                    "Khởi động lại Lumora.",
                ]),
            ));
        }

        let capture_backend;
        if wayland {
            capture_backend = "xdg-desktop-portal ScreenCast + PipeWire".to_string();

            // --- PipeWire ------------------------------------------------
            let pw_sock = runtime_dir().map(|d| d.join("pipewire-0"));
            let pw_ok = pw_sock.as_ref().map(|p| p.exists()).unwrap_or(false);
            checks.push(check(
                "pipewire",
                pw_ok,
                Severity::Error,
                "PipeWire",
                if pw_ok {
                    format!("PipeWire đang chạy ({}).", pw_sock.as_ref().map(|p| p.display().to_string()).unwrap_or_default())
                } else {
                    "Không tìm thấy socket PipeWire ($XDG_RUNTIME_DIR/pipewire-0). Chia sẻ màn hình trên Wayland cần PipeWire.".into()
                },
                vec![
                    install_cmd("pipewire wireplumber"),
                    "systemctl --user enable --now pipewire pipewire.socket wireplumber".into(),
                    "systemctl --user restart pipewire wireplumber".into(),
                    "Kiểm tra: ls $XDG_RUNTIME_DIR/pipewire-0".into(),
                ],
            ));

            // --- Portal --------------------------------------------------
            let bus = session_bus_ok();
            let v = portal_versions(&["org.freedesktop.portal.ScreenCast", "org.freedesktop.portal.RemoteDesktop"]);
            let (sc, rd) = (v.first().copied().flatten(), v.get(1).copied().flatten());
            let backend_installed = portal_impl_has(stem, "ScreenCast");
            let mut fix_sc = vec![install_cmd(&format!("xdg-desktop-portal {portal_pkg}"))];
            if let Family::Wlroots(n) = fam {
                fix_sc.push(format!(
                    "mkdir -p ~/.config/xdg-desktop-portal && printf '[preferred]\\ndefault=gtk\\norg.freedesktop.impl.portal.ScreenCast=wlr\\norg.freedesktop.impl.portal.Screenshot=wlr\\n' > ~/.config/xdg-desktop-portal/{n}-portals.conf"
                ));
                fix_sc.push(format!(
                    "Thêm vào cấu hình {n}: exec dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP={n}"
                ));
            }
            if fam == Family::Hyprland {
                fix_sc.push("Thêm vào hyprland.conf: exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP".into());
            }
            fix_sc.push(restart_portal.clone());
            fix_sc.push("Đăng xuất rồi đăng nhập lại nếu vẫn chưa được.".into());
            let sc_detail = match (bus, sc, backend_installed) {
                (false, _, _) => "Không kết nối được D-Bus phiên người dùng (DBUS_SESSION_BUS_ADDRESS).".to_string(),
                (true, Some(v), _) => format!(
                    "xdg-desktop-portal cung cấp ScreenCast phiên bản {v}{}.",
                    if v >= 4 { " (hỗ trợ ghi nhớ quyền — chỉ hỏi một lần)" } else { " (cũ: sẽ hỏi quyền mỗi lần chia sẻ)" }
                ),
                (true, None, Some(false)) => format!(
                    "xdg-desktop-portal không có giao diện ScreenCast: backend '{portal_pkg}' đã cài nhưng không hỗ trợ ScreenCast."
                ),
                (true, None, None) => format!(
                    "xdg-desktop-portal không có giao diện ScreenCast. Chưa cài backend portal cho desktop này ({portal_pkg})."
                ),
                (true, None, Some(true)) => format!(
                    "Backend {portal_pkg} đã cài nhưng xdg-desktop-portal chưa xuất giao diện ScreenCast (dịch vụ chưa chạy hoặc cấu hình portals.conf chọn sai backend)."
                ),
            };
            checks.push(check(
                "portal_screencast",
                sc.is_some(),
                Severity::Error,
                "Cổng chia sẻ màn hình (ScreenCast portal)",
                sc_detail,
                if bus { fix_sc } else { s(&["Đăng xuất và đăng nhập lại vào desktop (D-Bus phiên bị thiếu).", "Nếu chạy qua SSH/sudo: hãy chạy Lumora trực tiếp trong phiên desktop, không dùng sudo."]) },
            ));
            if let Some(v) = sc {
                checks.push(check(
                    "portal_screencast_persist",
                    v >= 4,
                    Severity::Warning,
                    "Ghi nhớ quyền chia sẻ màn hình",
                    if v >= 4 {
                        "Lumora sẽ lưu restore token: hộp thoại chọn màn hình chỉ hiện lần đầu.".to_string()
                    } else {
                        format!("ScreenCast portal phiên bản {v} < 4: không lưu được quyền, hộp thoại sẽ hiện mỗi lần chia sẻ.")
                    },
                    vec![install_cmd("xdg-desktop-portal"), "Cập nhật xdg-desktop-portal lên bản ≥ 1.12 và backend tương ứng.".into()],
                ));
            }
            checks.push(check(
                "permission_dialog",
                true,
                Severity::Info,
                "Hộp thoại cấp quyền",
                "Khi chia sẻ lần đầu, desktop sẽ hiện hộp thoại chọn màn hình. Nếu lỡ bấm \"Hủy\"/\"Từ chối\", chỉ cần bắt đầu chia sẻ lại; \
                 nếu Lumora đã lưu quyền cho màn hình sai, vào Cài đặt → Chia sẻ màn hình → \"Quên quyền đã lưu\".",
                Vec::new(),
            ));

            // --- Input ---------------------------------------------------
            let uinput = uinput_check(&user);
            let uinput_ok = uinput.ok;
            let rd_detail = match rd {
                Some(v) => format!("RemoteDesktop portal phiên bản {v} có sẵn: điều khiển từ xa dùng portal (không cần quyền thiết bị)."),
                None => match fam {
                    Family::Cosmic => "COSMIC chưa cung cấp RemoteDesktop portal; Lumora dùng /dev/uinput để điều khiển chuột/bàn phím.".into(),
                    Family::Wlroots(_) | Family::Hyprland => {
                        "Compositor dạng wlroots không có RemoteDesktop portal; Lumora dùng /dev/uinput.".into()
                    }
                    _ => "Không có RemoteDesktop portal; Lumora sẽ dùng /dev/uinput.".into(),
                },
            };
            let rd_fix = match fam {
                Family::Gnome => vec![install_cmd("xdg-desktop-portal-gnome"), restart_portal.clone()],
                Family::Kde => vec![install_cmd("xdg-desktop-portal-kde"), restart_portal.clone()],
                _ => s(&["Không cần làm gì nếu mục \"Quyền /dev/uinput\" đạt."]),
            };
            checks.push(check(
                "portal_remote_desktop",
                rd.is_some(),
                if uinput_ok { Severity::Info } else { Severity::Warning },
                "Cổng điều khiển từ xa (RemoteDesktop portal)",
                rd_detail,
                rd_fix,
            ));
            let input_backend = if rd.is_some() { "portal" } else if uinput_ok { "uinput" } else { "none" };
            let mut u = uinput;
            if rd.is_some() && !u.ok {
                u.severity = Severity::Info;
            }
            checks.push(u);
            if input_backend == "uinput" {
                let clip = which("wl-copy");
                checks.push(check(
                    "text_input_unicode",
                    clip,
                    Severity::Warning,
                    "Gõ tiếng Việt / ký tự Unicode",
                    if clip {
                        "Có wl-copy: chữ có dấu (tiếng Việt) được gửi bằng cách dán qua clipboard (Ctrl+V).".to_string()
                    } else {
                        "Thiếu wl-clipboard: qua uinput Lumora chỉ gõ được ký tự ASCII; chữ có dấu (tiếng Việt) sẽ bị bỏ qua.".into()
                    },
                    vec![install_cmd("wl-clipboard")],
                ));
            }
            return finish(session_type, desktop, capture_backend, input_backend.into(), checks, wayland);
        }

        // --- X11 ----------------------------------------------------------
        capture_backend = "X11 MIT-SHM".into();
        let x = x11_checks();
        let xtest_ok = x.iter().any(|c| c.id == "x11_xtest" && c.ok);
        checks.extend(x);
        let u = uinput_check(&user);
        let input_backend = if xtest_ok { "xtest" } else if u.ok { "uinput" } else { "none" };
        let mut u = u;
        if xtest_ok && !u.ok {
            u.severity = Severity::Info;
        }
        checks.push(u);
        finish(session_type, desktop, capture_backend, input_backend.into(), checks, false)
    }

    fn finish(
        session_type: String,
        desktop: String,
        capture_backend: String,
        input_backend: String,
        mut checks: Vec<Check>,
        wayland: bool,
    ) -> Diagnostics {
        checks.push(audio_check());
        if input_backend == "none" {
            let mut fix = s(&["Làm theo hướng dẫn của mục \"Quyền /dev/uinput\"."]);
            if wayland {
                let cosmic = desktop.to_lowercase().contains("cosmic");
                fix.push(if cosmic {
                    "COSMIC không có phiên X11: cách duy nhất là cấp quyền /dev/uinput như trên.".into()
                } else {
                    "Hoặc: đăng xuất và chọn phiên X11 (\"Ubuntu on Xorg\" / \"GNOME on Xorg\" / \"Plasma (X11)\") ở màn hình đăng nhập (biểu tượng bánh răng góc dưới).".into()
                });
            }
            checks.push(check(
                "input_ready",
                false,
                Severity::Error,
                "Điều khiển từ xa",
                "Không có cách nào để Lumora điều khiển chuột/bàn phím trên máy này: người xem chỉ thấy màn hình, không điều khiển được.",
                fix,
            ));
        } else {
            checks.push(check(
                "input_ready",
                true,
                Severity::Info,
                "Điều khiển từ xa",
                format!("Điều khiển chuột/bàn phím sẽ dùng: {input_backend}."),
                Vec::new(),
            ));
        }
        Diagnostics { platform: "linux".into(), session_type, desktop, capture_backend, input_backend, checks }
    }

    fn uinput_check(user: &str) -> Check {
        let p = Path::new("/dev/uinput");
        let exists = p.exists();
        let ok = exists && writable(p);
        let full_fix = vec![
            UDEV_RULE_CMD.to_string(),
            "echo uinput | sudo tee /etc/modules-load.d/uinput.conf && sudo modprobe uinput".to_string(),
            "sudo usermod -aG input $USER".to_string(),
            "sudo udevadm control --reload-rules && sudo udevadm trigger".to_string(),
            "Đăng xuất rồi đăng nhập lại (hoặc khởi động lại máy) để nhóm mới có hiệu lực.".to_string(),
            "Kiểm tra: ls -l /dev/uinput  (phải là crw-rw---- root input) và: id -nG | grep -w input".to_string(),
        ];
        if !exists {
            return check(
                "uinput",
                false,
                Severity::Error,
                "Quyền /dev/uinput",
                "Không có /dev/uinput: mô-đun kernel uinput chưa được nạp. Cần nó để điều khiển chuột/bàn phím trên Wayland khi không có RemoteDesktop portal.",
                full_fix,
            );
        }
        use std::os::unix::fs::MetadataExt;
        let meta = std::fs::metadata(p).ok();
        let (mode, gid) = meta.map(|m| (m.mode() & 0o777, m.gid())).unwrap_or((0, 0));
        let input_gid = group_gid("input");
        let gname = if Some(gid) == input_gid { "input".to_string() } else if gid == 0 { "root".into() } else { gid.to_string() };
        if ok {
            let how = if input_gid == Some(gid) && process_in_group(gid) && mode & 0o060 == 0o060 {
                "cấp qua nhóm input"
            } else {
                "cấp qua ACL của phiên đăng nhập — udev uaccess"
            };
            return check(
                "uinput",
                true,
                Severity::Info,
                "Quyền /dev/uinput",
                format!("Có quyền ghi /dev/uinput ({how}; mode {mode:o}, nhóm {gname}). Lumora có thể tạo chuột/bàn phím ảo."),
                Vec::new(),
            );
        }
        let in_group_file = user_listed_in_group("input", user);
        let in_group_now = input_gid.map(process_in_group).unwrap_or(false);
        let rule_ok = input_gid == Some(gid) && mode & 0o060 == 0o060;
        let detail;
        let fix;
        if rule_ok && in_group_file && !in_group_now {
            detail = format!(
                "/dev/uinput thuộc nhóm input (mode {mode:o}) và tài khoản '{user}' đã được thêm vào nhóm input, nhưng phiên hiện tại chưa nhận nhóm mới."
            );
            fix = s(&["Đăng xuất rồi đăng nhập lại (hoặc khởi động lại máy).", "Kiểm tra: id -nG | grep -w input"]);
        } else if rule_ok {
            detail = format!(
                "/dev/uinput thuộc nhóm input (mode {mode:o}) nhưng tài khoản '{user}' không thuộc nhóm input."
            );
            fix = s(&[
                "sudo usermod -aG input $USER",
                "Đăng xuất rồi đăng nhập lại (hoặc khởi động lại máy).",
                "Kiểm tra: id -nG | grep -w input",
            ]);
        } else {
            detail = format!(
                "Tài khoản '{user}' không có quyền ghi /dev/uinput (chủ sở hữu nhóm {gname}, mode {mode:o}). Cần quyền này để điều khiển chuột/bàn phím trên Wayland khi không có RemoteDesktop portal."
            );
            fix = full_fix;
        }
        check("uinput", false, Severity::Error, "Quyền /dev/uinput", detail, fix)
    }

    fn x11_checks() -> Vec<Check> {
        use x11rb::connection::Connection;
        use x11rb::protocol::shm::ConnectionExt as _;
        use x11rb::protocol::xtest::ConnectionExt as _;
        let mut v = Vec::new();
        match x11rb::connect(None) {
            Ok((conn, _)) => {
                v.push(check("x11_display", true, Severity::Info, "Kết nối X11", format!("Đã kết nối X server (DISPLAY={}).", std::env::var("DISPLAY").unwrap_or_default()), Vec::new()));
                let shm = conn.shm_query_version().ok().and_then(|c| c.reply().ok()).is_some();
                v.push(check(
                    "x11_shm",
                    shm,
                    Severity::Warning,
                    "MIT-SHM",
                    if shm { "Có MIT-SHM: chụp màn hình nhanh.".to_string() } else { "Không có MIT-SHM: chụp màn hình chậm hơn (GetImage).".into() },
                    s(&["Đảm bảo Lumora chạy trên cùng máy với X server (không qua ssh -X)."]),
                ));
                let xt = conn.xtest_get_version(2, 2).ok().and_then(|c| c.reply().ok()).is_some();
                v.push(check(
                    "x11_xtest",
                    xt,
                    Severity::Warning,
                    "XTest",
                    if xt { "Có XTest: điều khiển chuột/bàn phím qua X11.".to_string() } else { "X server không có extension XTest.".into() },
                    s(&["Bật extension XTEST trong cấu hình Xorg (Section \"Extensions\" Option \"XTEST\" \"Enable\")."]),
                ));
                drop(conn.flush());
            }
            Err(e) => v.push(check(
                "x11_display",
                false,
                Severity::Error,
                "Kết nối X11",
                format!("Không kết nối được X server (DISPLAY={:?}): {e}", std::env::var("DISPLAY").ok()),
                s(&["Chạy Lumora trong phiên desktop đồ họa.", "Kiểm tra biến DISPLAY: echo $DISPLAY"]),
            )),
        }
        v
    }

    fn audio_check() -> Check {
        let pulse = runtime_dir().map(|d| d.join("pulse/native").exists()).unwrap_or(false);
        let alsa = std::fs::read_to_string("/proc/asound/cards").map(|t| !t.contains("no soundcards")).unwrap_or(false);
        check(
            "audio",
            pulse || alsa,
            Severity::Warning,
            "Âm thanh",
            if pulse {
                "Có máy chủ âm thanh (PipeWire/PulseAudio).".to_string()
            } else if alsa {
                "Có card âm thanh ALSA.".into()
            } else {
                "Không tìm thấy thiết bị âm thanh: cuộc gọi sẽ không có tiếng.".into()
            },
            vec![install_cmd("pipewire-pulse wireplumber"), "systemctl --user restart pipewire pipewire-pulse wireplumber".into()],
        )
    }

    pub(super) fn clipboard_helper_available() -> bool {
        which("wl-copy") || which("xclip") || which("xsel")
    }
}

#[cfg(windows)]
mod imp {
    use super::*;
    pub(super) fn run() -> Diagnostics {
        let service = std::env::var("SESSIONNAME").map(|s| s.eq_ignore_ascii_case("services")).unwrap_or(false);
        let rdp = std::env::var("SESSIONNAME").map(|s| s.to_ascii_uppercase().starts_with("RDP-")).unwrap_or(false);
        let wine = crate::capture::windows::wine_version();
        let displays = crate::capture::windows::list_displays();
        let dxgi = if service { Err("service session".to_string()) } else { crate::capture::windows::probe_dxgi() };
        let mut checks = vec![check(
            "session",
            !service,
            Severity::Error,
            "Phiên Windows",
            if service {
                "Lumora đang chạy như dịch vụ (session 0): không chụp được màn hình và không điều khiển được."
            } else {
                "Desktop Duplication và SendInput cần phiên người dùng tương tác."
            },
            s(&["Chạy Lumora như ứng dụng bình thường (không chạy dưới dạng dịch vụ).",
                "Để điều khiển cửa sổ chạy quyền Administrator (UAC), hãy chạy Lumora bằng \"Run as administrator\"."]),
        )];
        checks.push(check(
            "displays",
            !displays.is_empty(),
            Severity::Error,
            "Màn hình",
            if displays.is_empty() {
                "Không tìm thấy màn hình nào được gắn vào desktop.".to_string()
            } else {
                displays
                    .iter()
                    .map(|d| format!("{} {}x{} @({},{}){}", d.name, d.width, d.height, d.x, d.y, if d.primary { " (chính)" } else { "" }))
                    .collect::<Vec<_>>()
                    .join("; ")
            },
            s(&["Kiểm tra cáp/màn hình và Settings → System → Display."]),
        ));
        checks.push(check(
            "capture_dxgi",
            dxgi.is_ok(),
            Severity::Warning,
            "Chụp màn hình bằng DXGI Desktop Duplication",
            match &dxgi {
                Ok(()) => "DXGI Desktop Duplication hoạt động (nhanh, dùng GPU).".to_string(),
                Err(e) => format!(
                    "Không dùng được DXGI Desktop Duplication: {e}. Lumora tự chuyển sang chụp bằng GDI (chậm hơn, tốn CPU hơn)."
                ),
            },
            s(&["Cập nhật driver card đồ hoạ (Intel/AMD/NVIDIA), không dùng \"Microsoft Basic Display Adapter\".",
                "Trên máy có 2 GPU (laptop), chọn GPU đang nối với màn hình cho Lumora trong Settings → Display → Graphics.",
                "Qua Remote Desktop (RDP) hoặc Wine, DXGI thường không có: chế độ GDI vẫn chia sẻ được màn hình."]),
        ));
        if rdp {
            checks.push(check("rdp", false, Severity::Info, "Phiên Remote Desktop",
                "Đang chạy trong phiên RDP: hình ảnh là của phiên RDP; khi ngắt RDP màn hình sẽ bị khoá và không chụp được.",
                s(&["Dùng Lumora trực tiếp trên máy thay vì qua RDP nếu cần điều khiển sau khi ngắt kết nối."])));
        }
        if let Some(v) = &wine {
            checks.push(check("wine", false, Severity::Info, "Đang chạy dưới Wine",
                format!("Wine {v}: DXGI Desktop Duplication không được hỗ trợ, dùng GDI; điều khiển (SendInput) đi qua X11 của Wine."),
                Vec::new()));
        }
        Diagnostics {
            platform: "windows".into(),
            session_type: if rdp { "rdp".into() } else if wine.is_some() { "wine".into() } else { "windows".into() },
            desktop: "windows".into(),
            capture_backend: if dxgi.is_ok() { "DXGI Desktop Duplication".into() } else { "GDI BitBlt (fallback)".into() },
            input_backend: if service { "none".into() } else { "SendInput".into() },
            checks,
        }
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use super::*;

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGPreflightScreenCaptureAccess() -> bool;
    }
    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXIsProcessTrusted() -> bool;
    }

    pub(super) fn run() -> Diagnostics {
        // SAFETY: argument-less queries.
        let screen = unsafe { CGPreflightScreenCaptureAccess() };
        let ax = unsafe { AXIsProcessTrusted() };
        let checks = vec![
            check("screen_recording", screen, Severity::Error, "Quyền ghi màn hình",
                if screen { "Đã có quyền Screen Recording." } else { "Chưa có quyền Screen Recording: người xem sẽ thấy màn hình đen/chỉ hình nền." },
                s(&["Mở System Settings → Privacy & Security → Screen & System Audio Recording.", "Bật Lumora, rồi thoát và mở lại Lumora."])),
            check("accessibility", ax, Severity::Error, "Quyền Trợ năng (Accessibility)",
                if ax { "Đã có quyền Accessibility: điều khiển chuột/bàn phím được." } else { "Chưa có quyền Accessibility: không điều khiển được chuột/bàn phím." },
                s(&["Mở System Settings → Privacy & Security → Accessibility.", "Bật Lumora (bấm + để thêm nếu chưa có), rồi mở lại Lumora."])),
        ];
        Diagnostics {
            platform: "macos".into(),
            session_type: "macos".into(),
            desktop: "aqua".into(),
            capture_backend: "CoreGraphics".into(),
            input_backend: if ax { "CGEvent".into() } else { "none".into() },
            checks,
        }
    }
}

#[cfg(not(any(target_os = "linux", windows, target_os = "macos")))]
mod imp {
    use super::*;
    pub(super) fn run() -> Diagnostics {
        Diagnostics {
            platform: std::env::consts::OS.into(),
            session_type: "mobile".into(),
            desktop: String::new(),
            capture_backend: "external (MediaProjection / ReplayKit)".into(),
            input_backend: "none".into(),
            checks: vec![check(
                "capture_external",
                true,
                Severity::Info,
                "Chia sẻ màn hình",
                "Màn hình được chụp bởi ứng dụng (MediaProjection trên Android); hệ thống sẽ hỏi quyền mỗi lần chia sẻ.",
                Vec::new(),
            )],
        }
    }
}

/// Whether a clipboard helper for non-ASCII text typing exists (Linux).
pub fn clipboard_helper_available() -> bool {
    #[cfg(target_os = "linux")]
    {
        imp::clipboard_helper_available()
    }
    #[cfg(not(target_os = "linux"))]
    {
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diagnostics_does_not_panic_and_serializes() {
        let d = diagnostics();
        assert!(!d.platform.is_empty());
        assert!(!d.checks.is_empty());
        let json = serde_json::to_string(&d).unwrap();
        assert!(json.contains("\"checks\""));
        for c in &d.checks {
            assert!(!c.id.is_empty() && !c.title.is_empty());
            if !c.ok && c.severity == Severity::Error {
                assert!(!c.fix_steps.is_empty(), "failing check {} has no fix steps", c.id);
            }
        }
    }
}

#[cfg(test)]
mod command_split_tests {
    use super::*;
    #[test]
    fn commands_are_split_from_steps() {
        assert!(is_command("sudo snap connect lumora:uinput"));
        assert!(is_command("Kiểm tra: ls $XDG_RUNTIME_DIR/pipewire-0"));
        assert!(is_command("systemctl --user restart pipewire wireplumber"));
        assert!(!is_command("Khởi động lại Lumora."));
        assert!(!is_command("Đăng nhập vào desktop rồi mở Lumora từ đó."));
        let c = check("x", false, Severity::Error, "t", "d", vec!["Khởi động lại Lumora.".into(), "sudo modprobe uinput".into()]);
        assert_eq!(c.fix_steps, vec!["Khởi động lại Lumora.".to_string()]);
        assert_eq!(c.commands, vec!["sudo modprobe uinput".to_string()]);
    }
}

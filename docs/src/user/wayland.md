# Cấp quyền chia sẻ màn hình và điều khiển từ xa trên Linux

Trên Linux, Lumora cần hai quyền riêng biệt:

| Việc | Wayland (GNOME, KDE, COSMIC, Sway, Hyprland…) | X11 |
|---|---|---|
| **Chia sẻ màn hình** | Cổng *ScreenCast* của `xdg-desktop-portal` + PipeWire. Desktop sẽ hiện hộp thoại chọn màn hình. | Đọc trực tiếp (MIT-SHM), không cần hỏi. |
| **Điều khiển chuột/bàn phím** | Cổng *RemoteDesktop* (GNOME, KDE) **hoặc** thiết bị ảo `/dev/uinput` (COSMIC, Sway, Hyprland, river…). | Extension XTest, không cần cấu hình. |

> **Cách nhanh nhất:** mở Lumora → *Cài đặt → Chẩn đoán*. Mỗi mục bị đỏ có sẵn các lệnh sửa
> lỗi chính xác cho máy của bạn (giống hệt các bước trong trang này). Sau khi sửa, bấm *Kiểm tra lại*.

Không biết mình đang dùng gì? Chạy:

```sh
echo "$XDG_SESSION_TYPE  $XDG_CURRENT_DESKTOP"
```

Ví dụ `wayland  COSMIC`, `wayland  ubuntu:GNOME`, `x11  KDE`.

---

## 1. Hộp thoại chọn màn hình (mọi desktop Wayland)

Lần đầu bạn bắt đầu chia sẻ, desktop hiện hộp thoại *“Lumora muốn chia sẻ màn hình”*:

1. Chọn màn hình cần chia sẻ (nếu có nhiều màn hình).
2. Nếu có ô *“Ghi nhớ lựa chọn”* / *“Allow restore”*, hãy giữ nó được chọn.
3. Bấm **Chia sẻ** / **Share**.

Lumora lưu lại *restore token*, nên các lần sau **không hỏi lại** (cần `xdg-desktop-portal` ≥ 1.12,
tức ScreenCast phiên bản 4 trở lên — mục *Ghi nhớ quyền chia sẻ màn hình* trong Chẩn đoán).

### Lỡ bấm “Hủy” / “Từ chối”

Portal không ghi nhớ việc từ chối: chỉ cần bấm **Chia sẻ màn hình** lại trong Lumora, hộp thoại sẽ hiện lại.

### Lumora nhớ nhầm màn hình / muốn bị hỏi lại

Vào *Cài đặt → Chia sẻ màn hình → Quên quyền đã lưu*. Lần chia sẻ tiếp theo hộp thoại sẽ hiện lại.
Nếu Lumora cài bằng Flatpak, bạn cũng có thể xóa mọi quyền đã lưu:

```sh
flatpak permission-reset <APP_ID>
```

### Hộp thoại không hiện / báo lỗi “ScreenCast portal”

Thường do thiếu *backend* portal cho desktop hoặc dịch vụ bị treo. Làm theo mục của desktop bạn bên dưới,
sau đó khởi động lại dịch vụ:

```sh
systemctl --user restart xdg-desktop-portal xdg-desktop-portal-<backend> pipewire wireplumber
```

(`<backend>` là `gnome`, `kde`, `cosmic`, `wlr` hoặc `hyprland`.) Nếu vẫn không được, đăng xuất rồi đăng nhập lại.

Kiểm tra PipeWire đang chạy:

```sh
ls $XDG_RUNTIME_DIR/pipewire-0          # phải tồn tại
systemctl --user enable --now pipewire pipewire.socket wireplumber
```

---

## 2. GNOME (Ubuntu, Fedora Workstation, Pop!_OS 22.04…)

- **Chia sẻ màn hình:** cần gói `xdg-desktop-portal-gnome`.

  ```sh
  sudo apt install xdg-desktop-portal xdg-desktop-portal-gnome     # Ubuntu/Debian
  sudo dnf install xdg-desktop-portal xdg-desktop-portal-gnome     # Fedora
  sudo pacman -S xdg-desktop-portal xdg-desktop-portal-gnome       # Arch
  systemctl --user restart xdg-desktop-portal xdg-desktop-portal-gnome pipewire wireplumber
  ```

- **Điều khiển từ xa:** GNOME có cổng *RemoteDesktop*. Lần đầu người xem điều khiển, GNOME hỏi
  *“Cho phép điều khiển từ xa?”* → bấm **Cho phép**. Không cần `/dev/uinput`.

## 3. KDE Plasma

- Cần gói `xdg-desktop-portal-kde` (thường đã cài sẵn):

  ```sh
  sudo apt install xdg-desktop-portal xdg-desktop-portal-kde
  systemctl --user restart xdg-desktop-portal xdg-desktop-portal-kde pipewire wireplumber
  ```

- KDE hỏi chung một hộp thoại cho *chia sẻ màn hình* và *điều khiển từ xa* → chọn màn hình, đánh dấu
  cho phép điều khiển, bấm **OK**. Không cần `/dev/uinput`.

## 4. COSMIC (Pop!_OS 24.04)

- **Chia sẻ màn hình:** hoạt động sẵn qua `xdg-desktop-portal-cosmic`. Nếu thiếu:

  ```sh
  sudo apt install xdg-desktop-portal xdg-desktop-portal-cosmic
  systemctl --user restart xdg-desktop-portal xdg-desktop-portal-cosmic pipewire wireplumber
  ```

- **Điều khiển từ xa:** COSMIC **chưa có** cổng RemoteDesktop, nên Lumora dùng `/dev/uinput`
  → làm theo [mục 7](#7-cấp-quyền-devuinput). COSMIC không có phiên X11 để chuyển sang.

## 5. Sway, river, Wayfire, labwc (wlroots) và Hyprland

1. Cài backend portal:

   ```sh
   sudo apt install xdg-desktop-portal xdg-desktop-portal-wlr          # Sway, river, Wayfire, labwc
   sudo pacman -S xdg-desktop-portal xdg-desktop-portal-hyprland       # Hyprland
   ```

2. (wlroots) Chỉ định backend ScreenCast, ví dụ với Sway:

   ```sh
   mkdir -p ~/.config/xdg-desktop-portal
   printf '[preferred]\ndefault=gtk\norg.freedesktop.impl.portal.ScreenCast=wlr\norg.freedesktop.impl.portal.Screenshot=wlr\n' \
     > ~/.config/xdg-desktop-portal/sway-portals.conf
   ```

   (Thay `sway` bằng `river`, `wayfire`, `labwc` cho compositor của bạn.)

3. Xuất biến môi trường cho dịch vụ portal — thêm vào cấu hình compositor:

   ```sh
   # ~/.config/sway/config
   exec dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP=sway
   # ~/.config/hypr/hyprland.conf
   exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
   ```

4. Đăng xuất / đăng nhập lại. `xdg-desktop-portal-wlr` có thể hỏi chọn màn hình bằng một menu nhỏ
   (hoặc tự chọn màn hình đầu tiên, tùy cấu hình `chooser_type`).

5. **Điều khiển từ xa:** các compositor này không có cổng RemoteDesktop → [mục 7](#7-cấp-quyền-devuinput).

## 6. Flatpak / Snap

**Flatpak:** chia sẻ màn hình qua portal hoạt động bình thường. Nhưng Flatpak chặn `/dev/uinput`,
nên trên COSMIC/Sway/Hyprland cần cấp thêm quyền thiết bị:

```sh
flatpak override --user --device=all <APP_ID>
flatpak override --user --socket=wayland --socket=fallback-x11 <APP_ID>
# hoàn tác:
flatpak override --user --reset <APP_ID>
```

Sau đó vẫn phải cấp quyền `/dev/uinput` cho tài khoản ([mục 7](#7-cấp-quyền-devuinput)) và khởi động lại Lumora.

**Snap:**

```sh
sudo snap connect lumora:screencast-legacy
sudo snap connect lumora:uinput
```

## 7. Cấp quyền `/dev/uinput`

Cần khi desktop không có cổng RemoteDesktop (COSMIC, Sway, Hyprland, river…). Lumora tạo một
**chuột ảo** và **bàn phím ảo** giống như thiết bị USB thật.

Kiểm tra trước:

```sh
ls -l /dev/uinput                       # mong đợi: crw-rw---- 1 root input ...
test -w /dev/uinput && echo "Đã có quyền" || echo "Chưa có quyền"
```

Nếu chưa có quyền, chạy lần lượt:

```sh
# 1. Quy tắc udev: /dev/uinput thuộc nhóm input, nhóm được đọc/ghi
echo 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' | sudo tee /etc/udev/rules.d/60-lumora-uinput.rules

# 2. Nạp mô-đun uinput khi khởi động (và ngay bây giờ)
echo uinput | sudo tee /etc/modules-load.d/uinput.conf && sudo modprobe uinput

# 3. Thêm tài khoản của bạn vào nhóm input
sudo usermod -aG input $USER

# 4. Áp dụng quy tắc udev
sudo udevadm control --reload-rules && sudo udevadm trigger
```

5. **Đăng xuất rồi đăng nhập lại** (hoặc khởi động lại máy) để nhóm mới có hiệu lực.
6. Kiểm tra: `id -nG | grep -w input` phải in ra `input`.

> **Lưu ý bảo mật.** Thành viên nhóm `input` đọc được *mọi* thiết bị nhập (kể cả bàn phím thật).
> Cách an toàn hơn — chỉ người đang ngồi trước máy mới có quyền, qua ACL của phiên đăng nhập —
> là dùng thẻ `uaccess` thay cho bước 1 và bỏ bước 3:
>
> ```sh
> echo 'KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"' | sudo tee /etc/udev/rules.d/60-lumora-uinput.rules
> sudo udevadm control --reload-rules && sudo udevadm trigger
> ```
>
> Chẩn đoán của Lumora nhận diện cả hai cách (*“cấp qua nhóm input”* hoặc *“cấp qua ACL của phiên đăng nhập”*).

### Gõ tiếng Việt khi dùng `/dev/uinput`

Bàn phím ảo chỉ bấm được các phím vật lý, nên chữ có dấu (*ă, ơ, ế, ữ…*) được gửi bằng cách
**dán qua clipboard** (Ctrl+V). Cần gói `wl-clipboard`:

```sh
sudo apt install wl-clipboard
```

Hạn chế đã biết: trong terminal, phím dán là Ctrl+Shift+V nên chữ có dấu có thể không vào được;
ký tự ASCII được gõ theo bố cục bàn phím US (máy được điều khiển nên dùng bố cục US/QWERTY).

## 8. Phương án cuối: đăng nhập phiên X11

Trên GNOME/KDE, nếu Wayland vẫn gây khó khăn, bạn có thể dùng phiên X11 — mọi thứ hoạt động không cần cấu hình:

1. Đăng xuất.
2. Ở màn hình đăng nhập, chọn tài khoản, bấm biểu tượng **bánh răng** (góc dưới).
3. Chọn **Ubuntu on Xorg** / **GNOME on Xorg** / **Plasma (X11)**, rồi đăng nhập.

COSMIC không có phiên X11.

---

## Bảng tra cứu nhanh theo mục Chẩn đoán

| Mã mục (`id`) | Ý nghĩa | Xem |
|---|---|---|
| `session` | Không chạy trong phiên đồ họa | Mở Lumora từ desktop, không qua SSH/sudo |
| `pipewire` | Không thấy PipeWire | [Mục 1](#1-hộp-thoại-chọn-màn-hình-mọi-desktop-wayland) |
| `portal_screencast` | Thiếu cổng ScreenCast | Mục 2–5 theo desktop |
| `portal_screencast_persist` | Portal cũ, hỏi quyền mỗi lần | Cập nhật `xdg-desktop-portal` |
| `portal_remote_desktop` | Không có cổng RemoteDesktop (bình thường trên COSMIC/wlroots) | [Mục 7](#7-cấp-quyền-devuinput) |
| `uinput` | Chưa có quyền ghi `/dev/uinput` | [Mục 7](#7-cấp-quyền-devuinput) |
| `text_input_unicode` | Thiếu `wl-clipboard`, không gõ được tiếng Việt | [Mục 7](#gõ-tiếng-việt-khi-dùng-devuinput) |
| `sandbox_flatpak` / `sandbox_snap` | Chạy trong sandbox | [Mục 6](#6-flatpak--snap) |
| `x11_display` / `x11_shm` / `x11_xtest` | Vấn đề phiên X11 | Kiểm tra `echo $DISPLAY` |
| `input_ready` | Không có cách nào điều khiển chuột/bàn phím | Mục 7 hoặc 8 |

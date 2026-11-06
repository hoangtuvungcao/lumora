# iPhone, iPad & Mac

*Tiếng Việt ở trên, English below.*

---

## Tiếng Việt

### Nói ngắn gọn

**Mac** dùng được **đầy đủ**: nhắn tin, gửi tệp, nhóm, gọi thoại/video, chia sẻ màn hình, điều khiển
máy khác **và** cho người khác điều khiển máy Mac. Lần đầu dùng, macOS hỏi hai quyền: *Ghi màn hình* và
*Trợ năng*. Lumora cho Mac được phát hành **ngoài App Store** (tải tệp `.dmg`), vì App Store bắt ứng dụng
chạy trong "hộp cát" và hộp cát cấm điều khiển chuột/bàn phím từ xa.

**iPhone / iPad** dùng được phần lớn, có giới hạn do Apple:

| Việc | iPhone/iPad | Ghi chú |
|---|---|---|
| Nhắn tin, gửi tệp, nhóm (khi đang mở app) | ✅ | Như trên máy tính. |
| Gọi thoại / video (khi đang mở app) | ✅ | Đang gọi mà chuyển sang app khác vẫn nghe/nói được. |
| Nhận tin khi app đã đóng | ✅ có máy chủ đẩy · ⚠️ không có | **Mặc định:** tin chờ ở máy người gửi và về **ngay khi bạn mở Lumora** (app tự kết nối lại lập tức). **Nếu bản app có máy chủ đẩy** và bạn bật *Cài đặt › Thông báo › Thông báo tức thì*: iPhone được đánh thức, thông báo hiện tên người gửi và đoạn đầu tin – giải mã ngay trên iPhone, máy chủ đẩy không đọc được. |
| Cuộc gọi đến khi app đã đóng | ✅ có máy chủ đẩy · ⚠️ không có | Có máy chủ đẩy: đổ chuông như cuộc gọi thường (màn hình gọi của iPhone). Không có: chỉ đổ chuông khi đang mở Lumora. |
| Tìm máy cùng Wi-Fi | ✅ | Dùng Bonjour của iPhone, không cần Apple duyệt quyền đặc biệt. Chỉ cần cho phép *Mạng cục bộ*. |
| Chia sẻ màn hình iPhone cho người khác xem | ✅* | Mục *Điều khiển từ xa* › *Bắt đầu phát sóng màn hình* › chọn Lumora. Người kia **chỉ xem**. Nên vừa chia sẻ vừa gọi thoại để iPhone không tạm dừng Lumora. |
| **Cho người khác điều khiển iPhone** | ❌ | **Apple không cho phép** bất kỳ ứng dụng nào bấm/chạm thay người dùng. Không có cách hợp lệ. |
| Dùng iPhone điều khiển máy tính khác | ✅ | Xem và điều khiển Windows / Mac / Linux / Android từ iPhone. |
| Chọn ảnh, tệp; lưu tệp nhận được | ✅ | Tệp nhận được nằm trong app *Tệp* › *Trên iPhone* › *Lumora*. |
| Khóa bí mật | ✅ | Giữ trong Chuỗi khóa (Keychain) của iPhone. |

\* Đã có đầy đủ trong mã và được CI build, nhưng phải thử trên iPhone thật (cần tài khoản Developer) mới chắc chắn.

**"Máy chủ đẩy" là gì?** Apple chỉ cho đánh thức một app iPhone đang đóng qua dịch vụ đẩy của Apple, và chỉ
người phát hành app (có khóa của Apple) mới gửi được. Lumora có một máy chủ đẩy nhỏ, mã nguồn mở, **tùy chọn**
(`lumora-push`). Nó chỉ nhận một "mã thiết bị" đã mã hóa và gửi đi câu "Bạn có tin nhắn mới" – **không thấy nội
dung, không biết ai nhắn cho ai**. Không có máy chủ này thì mọi thứ vẫn chạy, chỉ là tin nhắn về khi bạn mở app.
Xem [Máy chủ đẩy cho iPhone](../ops/push.md).

**Cần chuẩn bị gì?**

* **Tài khoản Apple Developer (99 USD/năm)** – bắt buộc để cài Lumora lên iPhone thật (trừ cách thử 7 ngày
  bằng Xcode với Apple ID miễn phí, cần máy Mac), để đưa lên TestFlight/App Store, để có khóa đẩy (APNs), và để
  ký + công chứng (notarize) bản Mac cho người dùng mở bình thường.
* **Kho GitHub** – CI tự build bản Mac (`.dmg`) và iPhone (`.ipa`) trên máy macOS của GitHub. Không cần Mac riêng.
* Không có tài khoản: bản **Mac** vẫn chạy được (chưa ký, phải cho phép thủ công một lần); bản **iPhone** thì
  **không cài được** lên máy thật.

### Những quyền người dùng sẽ thấy

**iPhone/iPad:** Camera (gọi video) · Micrô (gọi, tin thoại) · Mạng cục bộ (kết nối thẳng trong cùng Wi-Fi) ·
Ảnh (chọn ảnh gửi đi / lưu ảnh nhận được) · Vị trí (chỉ khi bạn gửi vị trí) · Thông báo (chỉ khi bật *Thông báo
tức thì*). Tất cả đều có lời giải thích tiếng Việt và tiếng Anh.

**Mac:** Camera · Micrô · **Ghi màn hình** (để người khác xem màn hình của bạn) · **Trợ năng** (để người khác
điều khiển chuột/bàn phím) · Mạng cục bộ (macOS 15 trở lên) · Tự động hóa *System Events* (chỉ khi người điều
khiển yêu cầu đăng xuất/khởi động lại). Ghi màn hình và Trợ năng được bật trong
*Cài đặt hệ thống › Quyền riêng tư & Bảo mật*; sau khi bật, hãy mở lại Lumora.

### Mở bản Mac chưa ký

Khi chưa có tài khoản Apple Developer, bản Mac (`Lumora-vX.Y.Z-macos-universal.dmg`, macOS 11 trở lên) vẫn
được phát hành nhưng **chưa ký**; ghi chú phát hành ghi rõ bản đó đã ký hay chưa. macOS sẽ chặn lần mở đầu tiên:

1. Kéo **Lumora** vào thư mục *Ứng dụng*, mở thử một lần (macOS báo không mở được).
2. Vào *Cài đặt hệ thống › Quyền riêng tư & Bảo mật*, kéo xuống, bấm **Vẫn mở** (*Open Anyway*), nhập mật khẩu.

Trước đó nên kiểm tra mã SHA-256 của tệp với `SHA256SUMS` trên trang phát hành (`shasum -a 256 -c SHA256SUMS
--ignore-missing`).

Lưu ý: với bản chưa ký, **mỗi lần cập nhật** macOS coi là ứng dụng mới, nên phải bật lại quyền Ghi màn hình và
Trợ năng. Bản đã ký bằng Developer ID không bị vậy – đây là lý do nên mua tài khoản Developer.

---

## English

### In plain words

**Mac: everything works** – chat, files, groups, voice/video calls, screen sharing, controlling other computers
**and being controlled**. macOS asks for *Screen Recording* and *Accessibility* the first time. The Mac app ships
**outside the Mac App Store** (a `.dmg` signed with Developer ID and notarized by Apple), because the App Store
requires the App Sandbox, and the sandbox forbids injecting mouse/keyboard input.

**iPhone/iPad: most things work**, within Apple's rules:

| Feature | iPhone/iPad | Why |
|---|---|---|
| Chat, files, groups (app open) | ✅ | Same Rust core, in-process. |
| Voice/video calls (app open) | ✅ | Audio keeps running if you switch apps during a call (`audio` background mode). |
| Messages while the app is closed | ✅ with a push bridge · ⚠️ without | Default: messages wait on the sender and arrive **as soon as you open Lumora** (it reconnects immediately on resume). With the publisher's optional push bridge and *Instant notifications* on, the iPhone is woken and the notification shows sender + preview, decrypted on the phone. |
| Incoming call while the app is closed | ✅ with a push bridge · ⚠️ without | PushKit → CallKit (native call screen). Without the bridge calls ring only while Lumora is open. |
| Find devices on the same Wi-Fi | ✅ | Bonjour/DNS-SD through the system (`NWBrowser` + `DNSServiceRegister`): no multicast entitlement. Needs *Local Network* permission. |
| Share the iPhone screen | ✅* | ReplayKit Broadcast Upload Extension → App Group shared-memory ring → core. View-only. |
| **Be remote-controlled** | ❌ | **iOS has no input-injection API.** No App-Store-legal way exists. |
| Control other computers from the iPhone | ✅ | Viewer + touch-to-mouse. |
| Pick files/photos, save received files | ✅ | Received files show in *Files › On My iPhone › Lumora*. |
| Keys in the Keychain | ✅ | `keyring` → Security.framework. |

\* Implemented and built by CI; needs a real iPhone (Developer account) to confirm end to end.

**Opening the unsigned Mac build.** Without a Developer ID the `.dmg` (`Lumora-vX.Y.Z-macos-universal.dmg`,
macOS 11 or later) is still published, unsigned; the release notes say whether a build is signed. Check it
against `SHA256SUMS` first (`shasum -a 256 -c SHA256SUMS --ignore-missing`), drag Lumora to *Applications*, try
to open it once, then *System Settings › Privacy & Security › Open Anyway* (macOS 15 removed the Control-click
→ Open shortcut). With ad-hoc signing every update resets the Screen Recording / Accessibility grants.

**You need:** an **Apple Developer Program membership ($99/year)** for any install on a real iPhone (except
7-day free provisioning from Xcode on a Mac), for TestFlight/App Store, for an APNs key, and for signed +
notarized Mac builds; a **GitHub repository** (CI builds both on GitHub's macOS runners); the **secrets** listed
in [CI & secrets](#ci--secrets); optionally a small server for the [push bridge](../ops/push.md).

---

### iOS – technical details

| # | Feature | Verdict | Implementation (files) |
|---|---|---|---|
| 1 | Chat, files, groups (foreground) | ✅ | Rust core in-process (`liblumora_ffi.a`, `DynamicLibrary.process()`) |
| 2 | Background delivery | ✅ bridge / ⚠️ none | resume fast path (`resume` API, `apple_services.dart`); opt-in push bridge (`lumora-push`, `node/push.rs`, `LumoraPush.swift`, `NotificationService.swift`) |
| 3 | Incoming calls when closed | ✅ bridge / ⚠️ none | VoIP wake (`remote.rs` → `push_call_wake`), PushKit + CallKit (`LumoraPush.swift`) |
| 4 | Voice/video calls (foreground) | ✅ | `AVAudioSession` `.playAndRecord` + `.voiceChat`/`.videoChat` (`AppDelegate.swift`, `apple_audio.dart`) |
| 5 | LAN discovery | ✅ | Bonjour: `mdns-sd` in the core (desktop/Android), `NWBrowser`/`DNSServiceRegister` on iOS (`LumoraBonjour.swift`) → `lumora_lan_candidate` |
| 6 | QUIC / UDP hole punching | ✅ (⚠️ in background) | Plain UDP sockets; resume re-dials |
| 7 | Screen sharing from the iPhone | ✅* | `LumoraBroadcast` extension + `Shared/lumora_ring.c` + `LumoraScreenShare.swift` |
| 8 | Being remote-controlled | ❌ | None exists; the core returns a clear "not supported on this device" error |
| 9 | Controlling other computers | ✅ | Viewer UI |
| 10 | Files, photos, notifications, keys | ✅ | `UIDocumentPickerViewController`, `PHPickerViewController`, `UNUserNotificationCenter`, Keychain |

#### 1. Chat, files, groups (foreground) – ✅

The Rust core (`liblumora_ffi.a`) is linked statically into the Runner and found by Dart with
`DynamicLibrary.process()` (`app/lib/core/ffi_api.dart`). Everything the core does in the foreground is allowed:
UDP/TCP sockets, QUIC, TLS (rustls), SQLCipher in the app container (`getApplicationSupportDirectory()`),
DHT/Nostr/relay signalling. Talking to devices on the LAN triggers the *Local Network* prompt
(`NSLocalNetworkUsageDescription`, iOS 14+); if the user declines, LAN paths fail silently and Internet paths are
used. `std::process::Command` cannot run inside the iOS sandbox: the only user (free-space check before a file
transfer, which shells out to `df`) is best-effort and is simply skipped on iOS (follow-up: use `statvfs`).

#### 2. Background delivery – ✅ with the push bridge, ⚠️ without

iOS suspends an app a few seconds after it leaves the screen; sockets stop and NAT mappings expire. APNs is the only
way to wake an app on demand, and only the holder of the publisher's APNs key can use it.

* **Always on – resume fast path.** Senders keep sealed messages in their outbox (and friends/relays keep
  store-and-forward mail). When Lumora comes back to the foreground, `AppleServices` calls the core's `resume`
  command, which clears dial back-off and re-dials every friend and outbox peer at once, so queued messages
  arrive within seconds instead of after the next 2-minute reconnect sweep. *Settings › Notifications* explains
  this plainly on iPhone.
* **Opt-in – push bridge** ([ops guide](../ops/push.md)). Only offered when the build was configured with a
  bridge (`--dart-define=LUMORA_PUSH_URL=… --dart-define=LUMORA_PUSH_KEY=…`), and only after the user turns on
  *Instant notifications*:
  1. Swift obtains the APNs token (and the PushKit VoIP token) and creates an X25519 *notification key* in the
     Keychain (access group shared with the Notification Service Extension).
  2. The core seals the tokens to the bridge's public key (`lumora_push::seal_token`) and sends the resulting
     `PushReg` (map-encoded, extensible) to friends – only to peers whose `Hello` advertises `+push1`, so older
     peers never see an unknown message.
  3. When a friend's core has to queue chat content for the offline iPhone, it POSTs `/wake` **once per burst**
     (60 s window, reset when the phone reconnects). It may attach the sender name + a 140-character preview
     sealed to the iPhone's notification key (X25519 → HKDF-SHA256 → ChaChaPoly).
  4. The bridge opens the token, checks the app topic, rate limits, and sends a content-free alert
     (`loc-key: PUSH_NEW_MESSAGE`, `mutable-content: 1`) carrying the opaque blob. On APNs `410` it remembers the
     token as dead and answers `410`, and the sender stops using that registration.
  5. The **Notification Service Extension** decrypts the blob with CryptoKit and shows "Name: preview" – or just
     "New message" when *Show content in notifications* is off (synced through the App Group).
* Not done on purpose: running the P2P core inside the extension (24 MB memory cap, ~30 s, SQLCipher shared with
  the app). Messages are fetched by the app on open; the extension only needs the preview the sender sealed.
* `BGAppRefreshTask` was skipped: iOS runs it rarely and never after a force-quit, so it adds review surface for
  little benefit.

#### 3. Incoming calls – ✅ with the push bridge, ⚠️ without

`call_start` to an offline iPhone with a registration sends a `call` wake; the bridge uses the PushKit VoIP token
(`apns-push-type: voip`, topic `<bundle>.voip`, expiration 0), falling back to an "Incoming call" alert if the
phone registered no VoIP token. The caller keeps re-sending the invite (every 3 s while ringing) as the phone
starts Lumora. On the phone, **every** VoIP push is reported to CallKit immediately (Apple requires it); the
caller's name comes from the sealed blob (hidden when the user hides notification content). *Answer* / *Decline*
in CallKit go to Dart, which answers the core's call when the invite arrives; the phone also re-dials friends
right away (`resume`). CallKit is not allowed on the **China** App Store; exclude that storefront.

#### 4. Voice/video calls in the foreground – ✅

* **Audio:** the core uses cpal (RemoteIO). cpal does **not** set an `AVAudioSession` category and the default
  (SoloAmbient) cannot record, so `AppDelegate.swift` exposes `vn.lumora/audio_session`: before a call it sets
  `.playAndRecord` + `.voiceChat` (earpiece) or `.videoChat` (speaker), with Bluetooth, then deactivates after
  the call (`lib/platform/apple_audio.dart`, hooked into `callStart`/`callAnswer`/`callEnd` and the remote
  "ended" event).
* `UIBackgroundModes: audio` keeps an **active call** (and a screen-sharing session with voice) alive.
* **Camera:** `LumoraCamera.swift` (one file, identical in `ios/Runner` and `macos/Runner`; CI checks with `cmp`): `AVCaptureVideoDataOutput` NV12 buffers go straight to `lumora_push_camera_yuv` — no copy, no Dart. iOS passes the clockwise rotation from the physical device orientation (as WebRTC does) and never mirrors; macOS resolves the symbol with `dlsym` from the dylib Dart loaded.
* **Video codec:** **VideoToolbox** H.264 (hardware, licensed by Apple, less battery) when the other side
  also has hardware H.264, otherwise the bundled libvpx VP8/VP9 — see [Video codecs](../dev/video-codecs.md).
  `core/crates/lumora-media/src/codec/vt.rs` is compile-checked only so far: run its `videotoolbox_roundtrip`
  test on a Mac/iPhone before release.

#### 5. LAN discovery – ✅

The core's raw multicast (239.255.76.77) would need Apple's `com.apple.developer.networking.multicast`
entitlement. Instead every platform now also speaks **Bonjour/DNS-SD**, service `_lumora._udp`:

* Instance name and TXT `id` = a 16-hex-character **daily LAN hint** (`blake3(peer, day)`), never the public
  key; only someone who already knows you can recognise it. TXT `v=1`.
* Desktop/Android: `mdns-sd` in the core (`net/discovery.rs`, cargo feature `mdns`, default on, off on iOS).
* iOS: `LumoraBonjour.swift` registers with `DNSServiceRegister` (no port binding – the QUIC socket belongs to
  the core) and browses with `NWBrowser`; each result is resolved to an IP with a short UDP `NWConnection` (no
  packet sent) and handed to the core with `lumora_lan_candidate(hint, ip, port)`.
* The core's `LanTable::get(peer)` merges multicast sightings and hint sightings, so every existing LAN fast
  path (dial, `lan_watch` while connecting) uses Bonjour transparently.
* `NSBonjourServices` (`_lumora._udp`, `_lumora._tcp`) + `NSLocalNetworkUsageDescription` are declared.
* Switches: `enable_lan` (user setting) controls both; `lan_multicast` / `mdns` (config, `lumorad
  --no-lan-multicast` / `--no-mdns`) control each method.

#### 6. QUIC / UDP hole punching – ✅ (⚠️ in background)

quinn on BSD UDP sockets works on iOS. Sockets are useless while suspended; the resume fast path re-dials.
Cellular CGNAT is often symmetric → relay fallback; IPv6 on cellular frequently connects directly. App Review
tests on an IPv6-only (NAT64) network: hostnames are fine, IPv4 literals are not.

#### 7. Screen sharing from the iPhone – ✅ (needs a device to confirm)

* **Why a ring buffer instead of running the core in the extension:** a Broadcast Upload Extension is a separate
  process capped at ~50 MB. The core (QUIC, SQLCipher, H.264, tokio) plus a live connection does not fit
  reliably, and linking the core's frame-push FFI into the extension would push frames into the *extension's*
  copy of the core, not the app's, so it would need its own identity and connection. The robust split:
  * `LumoraBroadcast/SampleHandler.swift` downscales each frame with vImage (NV12 → planes scaled first → BGRA,
    long side ≤ 960 px, ≤ 15 fps) **directly into** `screen.ring` in the App Group container, then posts a
    Darwin notification. Memory: two small scratch planes + the mapped ring (~11 MB).
  * `Shared/lumora_ring.c` – single-writer/single-reader seqlock ring (3 slots), C11 atomics over `mmap`. The
    reader never accepts a torn frame and always takes the newest one; numbering stays monotonic across
    extension restarts.
  * `Runner/LumoraScreenShare.swift` copies the newest frame out and calls `lumora_push_screen_frame`; the core's
    external capturer (`open_capturer` on iOS) encodes and sends it like any screen.
* The app must stay alive in the background while broadcasting: that is the case during a call (`audio` mode).
  So iPhone screen sharing is designed to run **together with a voice call**, like FaceTime screen sharing.
* UI: *Remote control › Start screen broadcast* opens `RPSystemBroadcastPickerView` with the extension
  preselected; control options are hidden on iOS (view-only).
* Frames are sent in the orientation ReplayKit delivers them (rotation by `RPVideoSampleOrientationKey` is a
  follow-up).

#### 8. Being remote-controlled – ❌

iOS has no public API to post touches or key presses into other apps or the system. `open_injector` returns
*"remote control is not supported on this device: iOS does not allow apps to control the screen …"*, which the
core turns into the localized `input_unavailable` error.

#### 9. Controlling other computers from the iPhone – ✅

Receive H.264, decode, draw, map touches to pointer events, send keys. No special permission.

#### 10. Files, photos, notifications, keys – ✅

* **Files:** `UIDocumentPickerViewController` via `file_picker`. Received files are saved to **Documents**;
  `UIFileSharingEnabled` makes them visible in the Files app.
* **Photos:** `PHPickerViewController` (no prompt); `NSPhotoLibraryUsageDescription` /
  `NSPhotoLibraryAddUsageDescription` declared (EN + VI).
* **Notifications:** asked only when the user turns on *Instant notifications*.
* **Keys:** identity KEK via `keyring` (generic password); notification key in a Keychain access group shared
  with the extension, `AfterFirstUnlockThisDeviceOnly`.

#### Targets, Info.plist and entitlements

| Target | Bundle id | Entitlements |
|---|---|---|
| Runner | `vn.lumora.lumora` | `aps-environment` (development for Debug, production otherwise), App Group `group.vn.lumora.lumora`, keychain group `$(AppIdentifierPrefix)vn.lumora.lumora.shared` |
| LumoraNotificationService | `vn.lumora.lumora.NotificationService` | App Group, keychain group |
| LumoraBroadcast | `vn.lumora.lumora.ScreenBroadcast` | App Group |

Runner `Info.plist`: privacy strings (EN, VI in `vi.lproj/InfoPlist.strings`), `NSBonjourServices`,
`UIBackgroundModes` = `audio`, `voip`, `UIFileSharingEnabled`, `CFBundleLocalizations` (en, vi),
`LumoraKeychainGroup`. Push texts: `Shared/{en,vi}.lproj/Localizable.strings` (`PUSH_NEW_MESSAGE`,
`PUSH_INCOMING_CALL`) in the app and the extension. Privacy manifest: `PrivacyInfo.xcprivacy`.

On developer.apple.com enable for the App IDs: **Push Notifications** and **App Groups** (`group.vn.lumora.lumora`)
for the app; **App Groups** for both extensions; the keychain group needs no extra capability.

#### App Store review risks

* **1.2 user-generated content:** chat apps need *block*, *report*, filtering and EULA terms. Add **Report** + an
  EULA before submitting – the most likely rejection.
* **5.1.1(v) account deletion:** expose "Delete my identity and data" in-app.
* **Review access:** keep a test contact online during review (e.g. a `lumorad` bot) and say so in the notes.
* **2.5.4 background modes:** `audio` only during calls/screen sharing with voice; `voip` only with CallKit (done).
  A build shipped **without** a push bridge should drop `voip` from `UIBackgroundModes` (it would be unused).
* **Export compliance:** standard encryption beyond Apple's (TLS, Olm, SQLCipher, X25519/ChaChaPoly): answer the
  questions in App Store Connect, yearly US self-classification report, French declaration if applicable.
* **Privacy manifest:** included. **IPv6-only networks**, **H.264 licensing**, **CallKit in China**: see above.
* **SDK requirement:** CI uses the newest stable Xcode on `macos-15`.

#### Apple Developer account

* **$99/year** for any IPA on a real device, APNs keys, App Groups and Developer ID + notarization on Mac.
* **Free Apple ID + Xcode**: 7-day installs on your own iPhone; no push, no App Groups – so no instant
  notifications and no screen broadcast in that mode.
* The unsigned `.ipa` from CI cannot be installed as-is; it proves the app and both extensions compile and link.

---

### macOS – technical details

| Feature | Verdict | Notes |
|---|---|---|
| Chat, files, groups, calls | ✅ | Universal (arm64 + x86_64) `liblumora_ffi.dylib` in `Contents/Frameworks`. |
| LAN discovery | ✅ | Multicast + Bonjour (`mdns-sd`); macOS 15 asks for *Local Network*. |
| Screen sharing (host) | ✅ / ⚠️ | CoreGraphics today; needs **Screen Recording**. Move to ScreenCaptureKit (see below). |
| Being remote-controlled | ✅ | `CGEventPost`; needs **Accessibility**. Impossible inside the App Sandbox. |
| Controlling others | ✅ | – |
| Remote log out / restart | ✅ | `osascript` → System Events: **Automation** prompt (`NSAppleEventsUsageDescription`). |
| Login window / before login | ❌ | A per-user app cannot see or control the login window; would need a privileged LaunchDaemon helper. |

* **Screen Recording** (TCC `ScreenCapture`): `capture/macos.rs` uses `CGDisplayCreateImage`. Without permission
  macOS returns only the wallpaper and menu bar; `diag` explains how to enable it, then Lumora must be restarted.
  `CGDisplayCreateImage` is deprecated (macOS 14) and marked obsoleted in the macOS 15 SDK headers; macOS 15 also
  re-asks users periodically about legacy capture. **Follow-up:** ScreenCaptureKit (`SCStream`, macOS 12.3+).
* **Accessibility** (TCC `Accessibility`/`PostEvent`): required for `CGEventPost`.
* **Hardened runtime** (mandatory for notarization): camera/microphone only work with
  `com.apple.security.device.camera` / `…device.audio-input`; Apple Events need
  `com.apple.security.automation.apple-events`; location `…personal-information.location`. All are in
  `app/macos/Runner/Release.entitlements` (and `DebugProfile.entitlements`, plus `cs.allow-jit`).
* **App Sandbox vs. direct distribution → Developer ID.** The Mac App Store requires the sandbox, which blocks
  posting input events to other apps. So the sandbox is **off** and we ship a **Developer ID-signed, notarized
  `.dmg`**.
* **Gatekeeper without signing:** at least ad-hoc signed (CI does that); macOS 15 removed the Control-click → Open
  bypass (*System Settings › Privacy & Security › Open Anyway*). TCC grants and Keychain access are tied to the
  signature: with ad-hoc signing **every update resets them**.
* **Minimum macOS:** 11 (Big Sur). The Xcode project, `app/tool/apple/build_core.sh`, CI
  (`MACOSX_DEPLOYMENT_TARGET=11.0`, also for the Bot Runner) and the website all say 11.

---

### How the build works

| Piece | iOS | macOS |
|---|---|---|
| Rust targets | `aarch64-apple-ios` (device), `aarch64-apple-ios-sim` (add `x86_64-apple-ios` with `IOS_SIM_TARGETS`) | `aarch64-apple-darwin` + `x86_64-apple-darwin` → `lipo` |
| Artifact | `liblumora_ffi.a` per SDK + `core/target/apple/LumoraFFI.xcframework` | `core/target/universal-apple-darwin/release/liblumora_ffi.dylib` |
| Linking | `app/ios/Flutter/Lumora.xcconfig`: `-force_load`, `-Wl,-u,_lumora_*`, system frameworks from `rustc --print native-static-libs`, `STRIP_STYLE = non-global` | Xcode phase **Embed Lumora core** copies + signs the dylib |
| Extensions | `LumoraBroadcast`, `LumoraNotificationService` (Swift; no Rust); embedded by *Embed Foundation Extensions* (before *Thin Binary*, avoiding Xcode's build cycle) | – |
| Dart loading | `DynamicLibrary.process()` | `Contents/Frameworks/liblumora_ffi.dylib` |

```sh
app/tool/apple/build_core.sh ios     # then: cd app && flutter run -d <iPhone>   (or flutter build ios)
app/tool/apple/build_core.sh macos   # then: cd app && flutter run -d macos      (or flutter build macos)
# optional push bridge baked into the iOS build:
flutter build ios --dart-define=LUMORA_PUSH_URL=https://push.example.org --dart-define=LUMORA_PUSH_KEY=<bridge public key>
```

### CI & secrets

`.github/workflows/build.yml`:

* **`core-tests`** (Linux) also runs `core/tests/apple_e2e.py` (Bonjour discovery + push wake-ups with a real
  `lumora-push` in dry-run mode) and the C ring stress test.
* **`push-image`** builds the bridge's Docker image and smoke-tests `/health` and `/pubkey`.
* **`macos`** – universal core → `flutter build macos` → verify → Developer ID + hardened runtime (if secrets) →
  `.dmg` (always `Lumora-<tag>-macos-universal.dmg`, published signed or not) → notarize + staple (if secrets).
* **`ios`** – static libs + xcframework → `flutter build ios --no-codesign` → verifies the C API survived linking,
  privacy strings, privacy manifest, **both extensions embedded with matching versions** → unsigned `.ipa`. With
  the secrets: signed App Store `.ipa` (manual signing per target) and, on `v*` tags, TestFlight upload. Nothing
  from this job is attached to the public release, so it does not gate the `release` job.

| Secret | What | How to get it |
|---|---|---|
| `APPLE_TEAM_ID` | 10-character Team ID | developer.apple.com › Membership |
| `APPLE_CERT_P12` / `APPLE_CERT_PASSWORD` | **Developer ID Application** certificate (`.p12`, base64) + password | Xcode › Settings › Accounts › Manage Certificates; export from Keychain Access; `base64 -i cert.p12` |
| `APPLE_ID` / `APPLE_APP_PASSWORD` | Apple ID + app-specific password (notarization, TestFlight) | appleid.apple.com › App-Specific Passwords |
| `IOS_CERT_P12` / `IOS_CERT_PASSWORD` | **Apple Distribution** certificate (`.p12`, base64) + password | as above |
| `IOS_PROVISION_PROFILE` | App Store profile for `vn.lumora.lumora` (Push + App Groups), base64 | developer.apple.com › Profiles |
| `IOS_PROVISION_PROFILE_BROADCAST` | App Store profile for `vn.lumora.lumora.ScreenBroadcast` (App Groups) | same |
| `IOS_PROVISION_PROFILE_NSE` | App Store profile for `vn.lumora.lumora.NotificationService` (App Groups) | same |

### What was verified, and what only CI or a device can verify

**On Linux (this repo's test machine):**

* `cargo check` of `lumora-ffi` with `media` for `aarch64-apple-ios` and `x86_64-apple-darwin`.
* `lumora-push`: 10 tests – sealing round trip/tamper, map-encoded `PushReg`, URL policy, and against a **mock
  APNs HTTP/2 server**: content-free alert with an ES256 JWT that verifies, VoIP vs. alert fallback, `410` →
  dead token never sent again, per-device/per-IP rate limits, garbage/foreign-app/oversized rejection, HTTP API.
* `core/tests/apple_e2e.py` (8 steps, real `lumorad` + real `lumora-push`): two nodes with multicast, Nostr, DHT
  and relays **off** find each other through mDNS only and connect on the `lan` path; negative control without
  mDNS cannot connect; a 5-message burst to an offline "iPhone" gives **exactly one** wake with no plaintext;
  the e2e blob opens with an independent Python implementation of the CryptoKit construction; a call sends one
  VoIP wake with the call id; the mailbox delivers all queued messages on return; the next burst wakes again.
* Core unit tests for the LAN hint table and the push module; C ring stress test (writer/reader processes,
  0 torn frames, monotonic across restarts) and a warning-free compile for Apple arm64.
* `dart analyze` of the new Dart code; workflow `actionlint` + shellcheck; all plists parse; `project.pbxproj`
  parses with no dangling references.

**CI only:** compiling the Swift (app + both extensions), linking, CocoaPods, signing/notarization/TestFlight,
the bridge's Docker image.

**Real iPhone only:** APNs/PushKit delivery, CallKit UI, Notification Service Extension decryption, Bonjour
under the Local Network prompt, ReplayKit broadcast memory/frame rate, background lifetime during calls.

### Next steps

1. Run on a device: push (sandbox), CallKit, broadcast, Bonjour.
2. Verify VideoToolbox H.264 on a real Mac/iPhone (code is in, compile-checked only); screen rotation from `RPVideoSampleOrientationKey`.
3. ScreenCaptureKit capture on macOS 12.3+.
4. App Review prerequisites: Report + EULA, in-app identity deletion, reviewer test contact.

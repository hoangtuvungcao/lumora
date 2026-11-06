# Owner notes (internal — NOT published)

This file is **not** part of the license and is never copied to the public release repo:
the release job in `.github/workflows/build.yml` publishes only `LICENSE.md` and
`THIRD_PARTY_NOTICES.md` from this folder. Keep it that way.

Status: `LICENSE.md` is a final v1.0 EULA (effective 2026-11-06) with the defaults below.
It is still not legal advice — have a lawyer review it when possible.

## 1. Defaults chosen in LICENSE.md (confirm or change)

| Clause | Default used |
|---|---|
| 1.3 Developer / publisher | "Lumora", contact via `https://github.com/hoangtuvungcao/get_lumora/issues` |
| 5.1 Vietnamese IP-law exceptions | generic reference, no article numbers (a lawyer can add exact citations of the Law on Intellectual Property) |
| 6.1 Security contact | GitHub private vulnerability reporting on `get_lumora` — **enable it**: repo Settings › Code security › Private vulnerability reporting |
| 13.2 Liability cap | greater of the amount paid or USD 50 |
| 15 Governing law / forum | Vietnam; competent People's Court in Vietnam |
| 16.1 Website alignment | refers to `https://getlumora.pages.dev/terms/` and `/privacy/` (keep those pages in sync with section 8) |
| 16.4 Prevailing language | Vietnamese |
| 16.5 Contact | GitHub Issues of `get_lumora` |

## 2. Open product items that affect the legal text

- **Peer relay toggle.** The owner decided friends' peer relaying "can be turned off", and the
  core reads kv `relay.help_friends` (core/crates/lumora-core/src/node/peer_relay.rs), but on
  2026-11-06 the app had **no UI switch** for it and `settings_set` does not expose it. The EULA
  (8.5) therefore says only "on by default" and does not promise a switch. When a switch ships,
  add "có thể tắt trong Cài đặt / can be turned off in Settings" to 8.5 (VI + EN) and to the
  website privacy page.
- **Public groups and IP addresses.** EULA 8.6 says members of groups you are in, *including
  public groups*, can see your IP (conservative; matches `may_reveal_addrs` in node/conn.rs on
  2026-11-06). If public-group semantics change to hide addresses from strangers in public
  groups, the text may be narrowed.

## 3. Third-party / licensing items (details in THIRD_PARTY_REVIEW.md, written by the notices generator; internal, never published)

- **Copyleft components** (no GPL/LGPL/AGPL/EPL/CDDL component is shipped): `attohttpc`
  (MPL-2.0, via `igd-next` for UPnP), `option-ext` (MPL-2.0, via `dirs`), `dbus` (Dart, MPL-2.0,
  Linux file picker), Flutter engine `fallback_root_certificates` (MPL-2.0). MPL-2.0 is file-level
  copyleft: a closed binary is fine, but keep the notices, say where the source of the MPL files
  is (the crates.io / pub.dev / upstream links in the notices) and publish changes to those files.
  EULA 10.2 preserves these rights.
- **Linux system libraries** (ALSA `libasound` LGPL-2.1+, GTK/GLib LGPL-2.1+, `libdbus`
  AFL-2.1/GPL-2.0+) are linked dynamically. The `.deb` depends on them; an **AppImage must not
  bundle** LGPL/GPL libraries unless they stay dynamically linked and replaceable, with their
  license texts and a source offer. `libdbus-sys` must keep its `vendored` feature off.
- **H.264:** release builds contain **no OpenH264** (CI checks the release dependency graphs);
  H.264 comes only from the OS codec (MediaCodec / Media Foundation / VideoToolbox / VA-API),
  VP8/VP9 from the bundled libvpx (BSD). The source-built OpenH264 is a dev-only feature
  (`openh264-source`) and must never be enabled in a release build.
- **Notices inside packages:** Rust/native notices are not shown in the app's license page
  (Flutter lists only Dart packages, the engine and the emoji entries). BSD/MIT/Apache require
  the notices to accompany the binary: ship `THIRD_PARTY_NOTICES.md` inside every package
  (installer, Linux bundle/.deb/AppImage, macOS app, APK) or register it with `LicenseRegistry`.
- **PDFium binary:** copy the LICENSE / licenses folder from the pdfium-binaries archive
  (FreeType, libjpeg-turbo, zlib, … notices).
- **Android:** Google Play services Location (proprietary) is inside the APK via
  `geolocator_android`.
- **Windows:** the VC++ runtime DLLs need a Visual Studio license with redistribution rights and
  should come from the VS redist folder; check the current Inno Setup license terms.
- **Demo/mock assets** (`app/assets/mock/`) ship in every build — confirm their origin or drop
  them from release builds. The BIP-39 word list has no explicit license — confirm.
- **OpenStreetMap tiles:** heavy use of `tile.openstreetmap.org` needs permission under the OSM
  tile usage policy; consider another tile provider if usage grows.

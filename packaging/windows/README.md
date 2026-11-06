# Lumora for Windows — build, installer and Wine tests

| File | What it is |
|---|---|
| `lumora.iss` | Inno Setup 6.3+ script → `Output/Lumora-Setup-<version>-x64.exe` (published as `Lumora-v<version>-windows-x86_64-setup.exe`) |
| `wine_e2e.py` | Windows⇄Linux end-to-end test: `lumorad.exe` under Wine vs. a native Linux `lumorad` |

## What the installer does

* Installs the Flutter release bundle (`lumora.exe`, `flutter_windows.dll`, plugin DLLs, `data\`)
  plus the Rust core `lumora_ffi.dll` (always taken from `core\target\release`, never a stale
  copy from the bundle) and, if present, the headless daemon `lumorad.exe`.
* Bundles `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll` when CI copied them next to
  `lumora.exe` (app-local deployment — both Flutter and an MSVC-built Rust DLL need them; no
  separate VC++ redistributable install).
* Registers the `lumora://` URL protocol (`HKLM\Software\Classes\lumora`,
  `"…\lumora.exe" "%1"`). `lib/main.dart` picks the link up from `argv`
  (`lumora://add/<peer>`, `lumora://join/<token>`, `lumora://remote/<id>`).
* Adds inbound firewall rules (task "Allow Lumora through Windows Firewall", on by default):
  * `Lumora (UDP in)` — program-scoped, UDP, all profiles, `edge=deferuser`. QUIC, STUN and
    NAT hole punching share one UDP socket on a random port, so the rule is per program, not
    per port. Without it Windows Defender Firewall drops unsolicited inbound packets on
    "Public" networks and hole punching falls back to the relay.
  * `Lumora LAN discovery (UDP in)` — private/domain profiles, `remoteip=localsubnet`
    (multicast discovery).
  Both rules are deleted before being re-added (upgrades, changed install dir) and on uninstall.
* Start-menu shortcut, optional desktop shortcut (both with `branding/icons/windows/lumora.ico`
  and AppUserModelID `vn.lumora.app`), "Launch Lumora" at the end.
* Uninstall removes files, protocol and firewall rules; it asks before deleting user data in
  `%APPDATA%\vn.lumora\Lumora` (identity keys, encrypted database) and keeps it in silent mode.
  Secrets stored by the OS keyring (Windows Credential Manager, `os-keyring` feature) are not touched.

Requires admin (firewall + HKLM). There is no MSI; for unattended / mass deployment use the Inno Setup
installer's silent mode from an elevated prompt (or Intune / GPO / SCCM as a Win32 app):

```bat
Lumora-vX.Y.Z-windows-x86_64-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
:: pick tasks explicitly:          /TASKS="desktopicon,firewall"
:: other folder / log file:        /DIR="D:\Apps\Lumora" /LOG="%TEMP%\lumora-setup.log"
:: silent uninstall (keeps user data): "%ProgramFiles%\Lumora\unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES
```

Exit code 0 means success. The portable `Lumora-vX.Y.Z-windows-x86_64-portable.zip` needs no install but adds
no firewall rules or `lumora://` links. The wizard is English only: Inno
Setup ships no official Vietnamese translation; drop an unofficial `Vietnamese.isl` into the
`[Languages]` section to add one.

## Building locally (on Windows)

```powershell
# 1. Rust core (MSVC toolchain; needs Strawberry Perl for the vendored OpenSSL used by SQLCipher)
$env:OPENSSL_SRC_PERL = "C:\Strawberry\perl\bin\perl.exe"
cd core
cargo build --release -p lumora-ffi --features media
cargo build --release -p lumora-cli --features media        # optional lumorad.exe
cd ..
# 2. Flutter UI
cd app; flutter build windows --release; cd ..
# 3. VC++ runtime next to lumora.exe (optional but recommended)
foreach ($f in "msvcp140.dll","vcruntime140.dll","vcruntime140_1.dll") {
  Copy-Item "$env:SystemRoot\System32\$f" app\build\windows\x64\runner\Release }
# 4. Installer
iscc /DAppVersion=1.0.0 packaging\windows\lumora.iss
```

## GitHub Actions (`.github/workflows/build.yml`, job `desktop`, matrix `windows`)

Runs on `windows-latest` after `core-tests`:

1. `dtolnay/rust-toolchain@stable` (MSVC host) + `Swatinem/rust-cache`.
2. Sets `OPENSSL_SRC_PERL=C:\Strawberry\perl\bin\perl.exe` so `openssl-src` (vendored by
   `rusqlite/bundled-sqlcipher-vendored-openssl`) never picks Git-for-Windows' msys perl, whose
   missing modules make OpenSSL's `Configure` fail. `nmake` comes from the VS install on the
   runner (if a future image breaks this, add `ilammy/msvc-dev-cmd@v1`); NASM (libvpx assembly) is
   installed with `choco install nasm`.
3. `cargo build --release -p lumora-ffi --features media` — VP8/VP9 come from the vendored libvpx
   (NASM for its assembly), Opus via CMake; H.264 only through Windows' own Media Foundation codecs
   (OpenH264 is never shipped). No system libraries are needed on Windows.
4. `flutter build windows --release --build-name X.Y.Z --build-number <MAJOR*10000+MINOR*100+PATCH>`
   (from the tag), then copies `lumora_ffi.dll` into `app/build/windows/x64/runner/Release/`.
5. Builds `lumorad.exe`, copies the VC++ runtime DLLs into the bundle, installs Inno Setup via
   Chocolatey only if `ISCC.exe` is not already on the image, and runs
   `iscc /DAppVersion=<tag without v | 0.0.0-dev> packaging/windows/lumora.iss`.
6. Uploads `lumora-windows` (the raw bundle) and `lumora-windows-installer`
   (`packaging/windows/Output/*.exe`); on tags the `release` job publishes them as
   `Lumora-vX.Y.Z-windows-x86_64-setup.exe` and `Lumora-vX.Y.Z-windows-x86_64-portable.zip`.

Not done in CI (needs secrets): Authenticode signing. Add a `signtool sign /fd sha256 /tr
<timestamp-url> /td sha256 …` step for `lumora.exe`, `lumora_ffi.dll` and the setup exe, or use
Inno's `SignTool=` directive, once a certificate is available — unsigned installers trigger
SmartScreen warnings.

## Cross-compiling from Linux and testing under Wine

```sh
rustup target add x86_64-pc-windows-gnu      # + apt install mingw-w64 wine
cd core
CARGO_BUILD_JOBS=4 cargo build --target x86_64-pc-windows-gnu \
    -p lumora-cli -p lumora-ffi --features lumora-core/media
cargo build -p lumora-cli                     # native peer
python3 ../packaging/windows/wine_e2e.py      # add --relay ws://127.0.0.1:8443/ws if LAN fails
```

`wine_e2e.py` starts `wine lumorad.exe --data C:\lumora-test --name "Máy Windows" --no-nostr --stdio`
and `lumorad --data /tmp/lumora-win-peer --name "Máy Linux" --no-nostr --stdio`, then checks:
connect, friend requests both ways (base32 and 9-digit ID), chat both ways with delivery/read
receipts, 5 MB transfers both ways with SHA-256 verification, group create + messages, the
Windows `diagnostics` report, and a view-only remote-desktop session hosted by the Windows
node (no input is injected, because under Wine that would drive the real Linux desktop).

Notes from running the GNU build under Wine 9.0:

* The GNU build is for testing only; release builds use MSVC in CI. It imports
  `libstdc++-6.dll` / `libgcc_s_seh-1.dll` (C++ in the echo canceller) — the script points
  `WINEPATH` at mingw's `13-win32` runtime directory; ship those DLLs if you ever distribute a GNU build.
* SQLCipher's vendored OpenSSL cross-compiles with mingw out of the box (needs `perl` + `make` on the
  build host; any perl with core modules works).
* Wine has no `IP_RECVECN`, so quinn-udp's optimized socket setup fails with `WSAENOPROTOOPT (10042)`.
  `lumora-core` (`net/magicsock.rs`, `cfg(windows)`) then falls back to a plain UDP socket
  (no ECN/GSO) and logs `UDP socket: optimized I/O unavailable … using plain UDP`.
* DXGI Desktop Duplication: `D3D11CreateDevice` works but `DuplicateOutput` returns
  `E_NOTIMPL (0x80004001)`, so capture uses the GDI `BitBlt` fallback (also used on Windows for
  RDP sessions / basic display drivers, or with `LUMORA_CAPTURE=gdi`). With `LUMORA_CAPTURE=dxgi`
  (`wine_e2e.py --capture dxgi`) the host refuses the session with a clear reason instead.
* On a Wayland desktop (XWayland) the root window cannot be read, so GDI capture of the *real*
  desktop is black; inside a Wine virtual desktop it works. The ignored unit test
  `input::windows::tests::gdi_capture_and_unicode_input` starts Notepad, types Vietnamese text
  with `KEYEVENTF_UNICODE` plus physical keys, captures the screen with GDI and writes a PNG:

  ```sh
  cargo test --no-run --target x86_64-pc-windows-gnu -p lumora-media --lib
  LUMORA_SHOT='Z:\tmp\shot' WINEPATH='Z:\usr\lib\gcc\x86_64-w64-mingw32\13-win32' \
    wine explorer /desktop=lumoratest,1280x720 target/x86_64-pc-windows-gnu/debug/deps/lumora_media-<hash>.exe \
    --ignored --exact input::windows::tests::gdi_capture_and_unicode_input
  ```
* Cursor handles are per-process in Wine, so the overlay draws the stock arrow there; on Windows
  the real cursor shape (incl. inverting I-beam) is composited.

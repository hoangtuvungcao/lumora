# Building & releasing

```bash
# core library + daemon
cd core && cargo build --release -p lumora-ffi -p lumora-cli --features lumora-ffi/media
# app
cd app && flutter build linux --release      # windows / macos / apk on their CI runners
```

CI (`.github/workflows/build.yml`, private repo `hoangtuvungcao/lumora`) builds Linux, Windows, macOS and
Android packages and, on a version tag, puts them into a draft release of the public repo
`hoangtuvungcao/get_lumora` (binaries, README and docs only, never source). Then `landing/releases.json` is
filled from that release and the website is redeployed (see [Release flow](#release-flow)).

Every push and pull request also runs: `core-tests` (Rust tests, `e2e.py`, `multidevice_e2e.py`,
`ip_privacy_e2e.py`, `video_e2e.py`, `apple_e2e.py`), `app-tests` (`flutter analyze` + all Flutter tests except
the `*screenshots_test.dart` suites, which only render PNGs for review), `sdk` (`gen_reference.py --check` and
the static checks of `sdk/tests/test_features.py`), `website` (`build_pages.py` must not change any committed
file, then `make_dist.sh` + `branding/tools/check_dist.py`) and `fuzz-regressions`. The `release` job waits for
all of them except `ios`, whose output is never published here (TestFlight).

Code signing: Android **must** be signed with the release key (below). Windows Authenticode and Apple
notarisation are optional but avoid SmartScreen/Gatekeeper warnings. Apple builds (macOS `.dmg`, iOS
`.ipa`/TestFlight), the core build script and the Apple secrets are described in
[iPhone, iPad & Mac](../platforms/apple.md).

## Version numbers

The tag is the only source of the version: `vMAJOR.MINOR.PATCH` (anything else fails the build). Linux,
Windows and Android get `--build-name MAJOR.MINOR.PATCH --build-number MAJOR*10000 + MINOR*100 + PATCH`
(`v1.2.3` → build `10203`; MINOR and PATCH must stay below 100). On Android the build number is the
`versionCode`, which must grow with every release or phones refuse the update. Branch and pull-request builds
are `0.0.0` (build 1). macOS/iOS use the same version name and the workflow run number as build number
(TestFlight only needs it to grow). `app/pubspec.yaml`'s `version:` is only the default for local builds.

## Release hardening

- **Rust** (`core/Cargo.toml` `[profile.release]`): thin LTO, one codegen unit, `strip = "symbols"`, no debug
  info. `panic = "unwind"` stays: `lumora-ffi` catches panics at every C entry point so a bug can't take the
  whole app down. CI sets `RUSTFLAGS=--remap-path-prefix=…` (Rust panic locations) and runs build scripts in a
  neutral `CARGO_BUILD_BUILD_DIR` (`/tmp/lumora-build`, `C:\lumora-build`), because the vendored OpenSSL compiles
  its build directory into the library; no `-ffile-prefix-map` is used, since OpenSSL also embeds its CFLAGS.
  Binaries contain no runner paths or user names, and CI fails the build if one slips through.
- **Dart**: every `flutter build` runs with `--obfuscate --split-debug-info=build/symbols/<platform>`. The
  symbol maps are uploaded only as private workflow artifacts named `symbols-*` (kept 90 days) — keep a copy for
  each released version to decode crash stack traces (`flutter symbolize -i trace.txt -d app.android-arm64.symbols`).
  They are never attached to a release.
- **No test back doors**: environment knobs used by the test suites (`LUMORA_MDNS_SERVICE`, `LUMORA_HIST_BATCH`)
  are ignored by release builds; the Flutter debug driver and `LUMORA_FFI_LIB` / `LUMORA_AUTO_*` only work in
  debug builds; `lumora-core`'s `fuzzing` feature is used only by `core/fuzz`.

## Release flow

Pushing a tag `vX.Y.Z` to the private source repo runs every job and then the `release` job, which:

1. fails if `LICENSE.md` or `THIRD_PARTY_NOTICES.md` still contain draft markers (`TODO`, `DRAFT`,
   `BẢN NHÁP`, notes for the owner);
2. collects exactly these files (any missing or extra file fails the job), never `symbols-*`, iOS builds or the
   xcframework:

   | File | What |
   |---|---|
   | `Lumora-vX.Y.Z-windows-x86_64-setup.exe` | Windows 10/11 installer (Inno Setup; silent: `/VERYSILENT /SUPPRESSMSGBOXES`, see `packaging/windows/README.md`). There is no MSI. |
   | `Lumora-vX.Y.Z-windows-x86_64-portable.zip` | Windows, no install (no firewall rules, no `lumora://` links) |
   | `Lumora-vX.Y.Z-macos-universal.dmg` | macOS 11+, Apple Silicon + Intel; signed + notarized when the Apple secrets exist, otherwise **unsigned** (the release notes say which; opening it: [iPhone, iPad & Mac](../platforms/apple.md)) |
   | `Lumora-vX.Y.Z-linux-amd64.deb` | Debian/Ubuntu package (installs to `/opt/lumora`, `/usr/bin/lumora`, menu entry + icons) |
   | `Lumora-vX.Y.Z-linux-x86_64.AppImage` | any other distribution; static type2 runtime, so no libfuse2 needed |
   | `Lumora-vX.Y.Z-linux-x86_64.tar.gz` | the plain Flutter bundle in one folder |
   | `Lumora-vX.Y.Z-android-universal.apk` | all three ABIs in one — **the recommended download** (some phones, e.g. Xiaomi with a 32-bit userspace, refuse the arm64-only APK with "package appears to be invalid") |
   | `Lumora-vX.Y.Z-android-arm64-v8a.apk` | lighter build for recent 64-bit phones |
   | `Lumora-vX.Y.Z-android-armeabi-v7a.apk` / `…-android-x86_64.apk` | old 32-bit phones / emulators and Chromebooks |
   | `Lumora-bot-runner-vX.Y.Z-{linux-x86_64, windows-x86_64.exe, macos-universal}` | headless `lumorad` for bot developers |
   | `LICENSE.md`, `THIRD_PARTY_NOTICES.md` | EULA (proprietary freeware) and open-source notices |
   | `SHA256SUMS`, `SHA256SUMS.sigstore.json` | checksums and their Sigstore signature |

3. writes `SHA256SUMS`, signs it with **cosign keyless** (Sigstore, GitHub OIDC — no key to manage; the
   signature is logged in the public Rekor transparency log, which records the source repo name and tag) and adds
   GitHub **build-provenance attestations** (these need GitHub Enterprise Cloud for a private source repo; on
   other plans that step is skipped and the cosign signature is the provenance proof);
4. creates a **draft** release in the public repo `hoangtuvungcao/get_lumora` using the secret
   `RELEASE_REPO_TOKEN` (fine-grained PAT, *Contents: read & write* on that repo only). Review it there and
   press *Publish*.

After publishing, point the website at the new files and redeploy it:

```bash
python3 branding/tools/update_releases.py --tag vX.Y.Z   # fills landing/releases.json: url, sha256, size, available
                                                         # add --mac-signed if the release notes say the DMG is notarized
python3 branding/tools/build_pages.py && bash branding/tools/make_dist.sh
python3 branding/tools/check_dist.py dist/landing
npx wrangler pages deploy dist/landing --project-name getlumora --branch main
```

### Linux packages

`packaging/linux/package.sh <bundle> <version> <out>` (run by the `desktop` job, where the executable bits are
still intact) builds the `.tar.gz`, the `.deb` (with `dpkg-deb`) and the AppImage (with `appimagetool` 1.9.1 and
the type2 runtime, both downloaded at pinned versions and checked against their SHA-256). It reads every
`NEEDED` library of the bundle and maps it to a Debian package; an unknown library fails the build, so a new
dependency can't silently break installs. `Depends` also gets `libc6 (>= <highest GLIBC_ symbol version>)`:
built on Ubuntu 24.04 that is glibc 2.39, i.e. Ubuntu 24.04 / Debian 13 / Fedora 40 or newer. Optional tools
are `Recommends`: `pulseaudio-utils` + `ffmpeg` (voice messages), `zenity | kdialog` (file picker),
`xdg-utils`, `xdg-desktop-portal`, `libva2` + `libva-drm2` (hardware H.264). The desktop entry is
`packaging/linux/vn.lumora.lumora.desktop` (same id as the GTK application, so Wayland docks show the icon).

## Android signing key

Android only installs an update when it is signed with **the same key** as the installed app. The key is made
**once**, by the owner, and then kept forever:

* **Back it up** (the `.jks` file *and* both passwords) in at least two safe places, e.g. a password manager
  and an encrypted offline drive. **If it is lost, no existing user can ever update Lumora again**: they would
  have to uninstall (losing local data unless they made a backup) and install a new app. If it leaks, anyone
  can publish a fake "update". Never commit it: `*.jks`, `*.keystore` and `app/android/key.properties` are in
  `.gitignore`.

1. Create the key (JDK `keytool`; answer the name questions with e.g. `Lumora`; 4096-bit RSA, valid ~100 years):

   ```bash
   keytool -genkeypair -v -keystore lumora-release.jks -storetype PKCS12 \
     -alias lumora -keyalg RSA -keysize 4096 -validity 36500
   ```

   With PKCS12 the key password is the store password; use the same value for both secrets below.

2. Give it to CI (GitHub CLI, in a clone of `hoangtuvungcao/lumora`):

   ```bash
   base64 -w0 lumora-release.jks | gh secret set ANDROID_KEYSTORE_BASE64 --repo hoangtuvungcao/lumora
   gh secret set ANDROID_KEYSTORE_PASSWORD --repo hoangtuvungcao/lumora   # prompts for the value
   gh secret set ANDROID_KEY_ALIAS --repo hoangtuvungcao/lumora --body lumora
   gh secret set ANDROID_KEY_PASSWORD --repo hoangtuvungcao/lumora        # prompts (same as the store password)
   ```

   (macOS: `base64 -i lumora-release.jks | tr -d '\n' | gh secret set …`.)

3. Local release builds (optional): create `app/android/key.properties` (never committed):

   ```properties
   storeFile=/absolute/path/to/lumora-release.jks
   storePassword=…
   keyAlias=lumora
   keyPassword=…
   ```

`app/android/app/build.gradle.kts` signs release builds with `key.properties` or, in CI, with
`ANDROID_KEYSTORE_PATH` / `ANDROID_KEYSTORE_BASE64` + `ANDROID_KEYSTORE_PASSWORD` + `ANDROID_KEY_ALIAS` +
`ANDROID_KEY_PASSWORD`. Without a key it falls back to the debug key so local `flutter run --release` keeps
working; such APKs are for testing only. On version tags CI **fails** if any of the four secrets is missing,
checks the keystore with `keytool`, sets `LUMORA_REQUIRE_RELEASE_SIGNING=1` (Gradle refuses the debug key) and
verifies every APK with `apksigner` (no `CN=Android Debug`). The printed certificate SHA-256 is the app's
identity; it never changes while the key is kept.

## Secrets (private repo `hoangtuvungcao/lumora`)

| Secret | Needed for |
|---|---|
| `RELEASE_REPO_TOKEN` | creating the draft release in `get_lumora` (required on tags) |
| `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | Android release signing (required on tags) |
| `APPLE_TEAM_ID`, `APPLE_CERT_P12`, `APPLE_CERT_PASSWORD`, `APPLE_ID`, `APPLE_APP_PASSWORD` | signed + notarized Mac `.dmg` (optional; without them the `.dmg` is published unsigned) |
| `IOS_*` | TestFlight ([apple.md](../platforms/apple.md#ci--secrets)) |

## Verifying a download (for users)

```bash
# 1. the file is the one listed in SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing            # macOS: shasum -a 256 -c SHA256SUMS --ignore-missing
# 2. SHA256SUMS was produced by Lumora's official build workflow for that tag (https://docs.sigstore.dev/cosign/system_config/installation/)
cosign verify-blob --bundle SHA256SUMS.sigstore.json \
  --certificate-identity "https://github.com/hoangtuvungcao/lumora/.github/workflows/build.yml@refs/tags/vX.Y.Z" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com SHA256SUMS
```

Windows (PowerShell): `Get-FileHash .\Lumora-vX.Y.Z-windows-x86_64-setup.exe -Algorithm SHA256` and compare with
the line in `SHA256SUMS`.

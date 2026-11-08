# Lumora app (Flutter)

The Lumora user interface for Android, iOS, Windows, macOS and Linux. It talks to the Rust core
(`core/crates/lumora-ffi`) through FFI (JNI on Android); without the native library it runs on a
mock core (`lib/core/mock_api.dart`), which is what the widget and screenshot tests use.

| Path | What |
|---|---|
| `lib/core/` | API to the core (`api.dart`), the mock core, version |
| `lib/state/` | Stores (chats, contacts, calls, devices, settings…) fed by core events |
| `lib/ui/` | Screens and widgets — `chats/`, `calls/`, `groups/`, `devices/`, `remote/`, `bots/`, `settings/`, `shell/` |
| `lib/l10n/` | Vietnamese + English strings (both required) |
| `lib/platform/` | Platform bridges (Android services, notifications, camera, screen capture) |
| `android/`, `ios/`, `macos/`, `windows/`, `linux/` | Platform projects (Kotlin, Swift, C++) |
| `test/` | Widget, integration-style and screenshot tests (`screenshots/` is generated) |

```bash
flutter pub get && dart run pdfrx:remove_wasm_modules
flutter analyze && flutter test     # Flutter 3.38.9
flutter run -d linux                # needs core/target/…/liblumora_ffi.so for the real core
```

Building, platform requirements and releases: see the [repository README](../README.md).

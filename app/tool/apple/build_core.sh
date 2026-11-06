#!/usr/bin/env bash
# Build the Lumora Rust core (lumora-ffi) for Apple platforms. Run on macOS with Xcode.
#
#   app/tool/apple/build_core.sh ios     static libs for iPhone + Simulator, an xcframework,
#                                        and app/ios/Flutter/LumoraCore.generated.xcconfig
#                                        (exact link flags for the Runner target)
#   app/tool/apple/build_core.sh macos   universal (arm64 + x86_64) liblumora_ffi.dylib, embedded
#                                        into Lumora.app by the "Embed Lumora core" Xcode phase
#
# Environment (all optional):
#   PROFILE=release|debug           cargo profile (default release)
#   FEATURES=media                  lumora-ffi cargo features (default media: calls + remote desktop)
#   IOS_SIM_TARGETS="aarch64-apple-ios-sim x86_64-apple-ios"   simulator slices (default: arm64 only)
#   MACOS_TARGETS="aarch64-apple-darwin x86_64-apple-darwin"   (default: both → universal)
#   IPHONEOS_DEPLOYMENT_TARGET (13.0) / MACOSX_DEPLOYMENT_TARGET (11.0), same as the Flutter projects
#
# Every step verifies its output (architectures, exported lumora_* symbols, no Homebrew/local
# dylib dependencies) and fails loudly, so CI cannot ship a half-built app.
set -euo pipefail

MODE="${1:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CORE="$ROOT/core"
TARGET_DIR="${CARGO_TARGET_DIR:-$CORE/target}"
PROFILE="${PROFILE:-release}"
FEATURES="${FEATURES:-media}"

export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-13.0}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
# Opus: build the bundled source and link it statically. Never pick up a Homebrew libopus
# through pkg-config: the shipped app would then depend on /opt/homebrew/lib/libopus.dylib.
export LIBOPUS_STATIC=1 LIBOPUS_NO_PKG=1

die() { echo "error: $*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || die "Apple builds need macOS with Xcode (this is $(uname -s))"
command -v xcrun >/dev/null || die "xcrun not found: install Xcode and run 'sudo xcode-select -s /Applications/Xcode.app'"

profile_flag=()
[ "$PROFILE" = release ] && profile_flag=(--release)

sdk_for() {
  case "$1" in
    *-apple-ios-sim | x86_64-apple-ios) echo iphonesimulator ;;
    *-apple-ios) echo iphoneos ;;
    *-apple-darwin) echo macosx ;;
    *) die "unknown Apple target $1" ;;
  esac
}

# build <rust-target> <crate-type>  →  prints nothing; log in $TARGET_DIR/apple-logs/<target>.log
build() {
  local tgt="$1" kind="$2" sdk sysroot var
  sdk="$(sdk_for "$tgt")"
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  var="${tgt//-/_}"
  # aec-rs-sys runs bindgen: make libclang parse the *target* SDK headers, otherwise
  # size_t/ssize_t come out wrong (or stdio.h is missing) when cross-compiling.
  export "BINDGEN_EXTRA_CLANG_ARGS_${var}=-isysroot ${sysroot}"
  rustup target add "$tgt" >/dev/null 2>&1 || true
  mkdir -p "$TARGET_DIR/apple-logs"
  echo "==> cargo build lumora-ffi ($kind) for $tgt [$PROFILE, features: ${FEATURES:-none}]"
  (
    cd "$CORE"
    cargo rustc -p lumora-ffi --lib --locked --target "$tgt" "${profile_flag[@]}" \
      ${FEATURES:+--features "$FEATURES"} --crate-type "$kind" -- --print native-static-libs
  ) 2>&1 | tee "$TARGET_DIR/apple-logs/$tgt.log"
}

out_of() { echo "$TARGET_DIR/$1/$PROFILE/$2"; }

require_symbols() { # <binary> : the Dart bindings look these up by name
  local bin="$1" missing=0 syms
  # list once: `nm | grep -q` under pipefail fails on big static archives (grep exits at the
  # first match, nm dies of SIGPIPE and the pipeline counts as failed)
  syms="$(nm -gU "$bin" 2>/dev/null)" || die "nm cannot read $bin"
  for s in lumora_start lumora_request lumora_next_event lumora_free lumora_stop; do
    grep -q " _${s}\$" <<<"$syms" || { echo "missing symbol _${s} in $bin" >&2; missing=1; }
  done
  [ "$missing" = 0 ] || die "$bin does not export the Lumora C API"
}

case "$MODE" in
ios)
  DEVICE=aarch64-apple-ios
  read -r -a SIMS <<<"${IOS_SIM_TARGETS:-aarch64-apple-ios-sim}"
  build "$DEVICE" staticlib
  dev_lib="$(out_of "$DEVICE" liblumora_ffi.a)"
  [ -f "$dev_lib" ] || die "missing $dev_lib"
  lipo -info "$dev_lib"
  require_symbols "$dev_lib"

  sim_libs=()
  for t in "${SIMS[@]}"; do
    build "$t" staticlib
    sim_libs+=("$(out_of "$t" liblumora_ffi.a)")
  done
  sim_lib="$TARGET_DIR/apple-ios-sim/$PROFILE/liblumora_ffi.a"
  mkdir -p "$(dirname "$sim_lib")"
  lipo -create "${sim_libs[@]}" -output "$sim_lib"
  lipo -info "$sim_lib"

  xcf="$TARGET_DIR/apple/LumoraFFI.xcframework"
  rm -rf "$xcf" && mkdir -p "$(dirname "$xcf")"
  xcodebuild -create-xcframework -library "$dev_lib" -library "$sim_lib" -output "$xcf"

  # Link flags for app/ios/Flutter/Lumora.xcconfig (overrides its defaults):
  #  - the system libraries/frameworks rustc says the static lib needs;
  #  - -u for every exported lumora_* symbol: nothing in the Runner calls them (Dart looks
  #    them up at run time with DynamicLibrary.process()), so without -u the linker's dead
  #    code stripping would drop them from the app.
  native="$(grep -o 'native-static-libs: .*' "$TARGET_DIR/apple-logs/$DEVICE.log" | tail -1 | sed 's/^native-static-libs: //')"
  [ -n "$native" ] || die "rustc did not report native-static-libs"
  keep="$(nm -gU "$dev_lib" 2>/dev/null | awk '$2 == "T" && $3 ~ /^_lumora_/ { print "-Wl,-u," $3 }' | sort -u | tr '\n' ' ')"
  gen="$ROOT/app/ios/Flutter/LumoraCore.generated.xcconfig"
  {
    echo "// Generated by app/tool/apple/build_core.sh ios ($PROFILE). Do not edit."
    echo "LUMORA_PROFILE = $PROFILE"
    echo "LUMORA_NATIVE_LIBS = $native"
    echo "LUMORA_KEEP_SYMBOLS = $keep"
  } >"$gen"
  echo "==> wrote $gen"
  cat "$gen"
  ;;

macos)
  read -r -a TARGETS <<<"${MACOS_TARGETS:-aarch64-apple-darwin x86_64-apple-darwin}"
  libs=()
  for t in "${TARGETS[@]}"; do
    build "$t" cdylib
    libs+=("$(out_of "$t" liblumora_ffi.dylib)")
  done
  uni="$TARGET_DIR/universal-apple-darwin/$PROFILE/liblumora_ffi.dylib"
  mkdir -p "$(dirname "$uni")"
  lipo -create "${libs[@]}" -output "$uni"
  install_name_tool -id @rpath/liblumora_ffi.dylib "$uni"
  lipo -info "$uni"
  require_symbols "$uni"
  # Only system libraries may be linked dynamically (no Homebrew, no /usr/local).
  if otool -L "$uni" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/|@rpath/liblumora_ffi)'; then
    die "liblumora_ffi.dylib links non-system libraries (listed above); they would be missing on users' Macs"
  fi
  echo "==> $uni"
  ;;

*)
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
  ;;
esac

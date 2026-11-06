#!/usr/bin/env bash
# Package the Flutter Linux release bundle as a .tar.gz, a Debian/Ubuntu .deb and an AppImage.
#
#   packaging/linux/package.sh <bundle-dir> <version> <out-dir>
#
#   <bundle-dir>  app/build/linux/x64/release/bundle (lumora, lib/ with liblumora_ffi.so, data/)
#   <version>     1.2.3 (no leading "v")
#   <out-dir>     receives Lumora-v<version>-linux-x86_64.tar.gz, Lumora-v<version>-linux-amd64.deb
#                 and Lumora-v<version>-linux-x86_64.AppImage
#
# Needs: dpkg-deb, readelf (binutils), curl. appimagetool and the AppImage runtime are downloaded
# at pinned versions and checked against their SHA-256 (or set APPIMAGETOOL / APPIMAGE_RUNTIME to
# local copies). Set SKIP_APPIMAGE=1 to build only the .deb. Used by .github/workflows/build.yml
# (job desktop, linux); see docs/src/ops/release.md.
set -euo pipefail

BUNDLE="${1:?bundle dir}"
VERSION="${2:?version}"
OUT="${3:?out dir}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ICONS="$ROOT/branding/icons/linux/hicolor"
DESKTOP="$HERE/vn.lumora.lumora.desktop"
APP_ID="vn.lumora.lumora"

# Pinned tools (https://github.com/AppImage/appimagetool, https://github.com/AppImage/type2-runtime).
# The type2 runtime is static: the AppImage runs without libfuse2 installed.
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage"
APPIMAGETOOL_SHA256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
RUNTIME_URL="https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64"
RUNTIME_SHA256="2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d"

die() { echo "package.sh: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([~+.][0-9A-Za-z.~+-]*)?$ ]] || die "bad version '$VERSION'"
[ -x "$BUNDLE/lumora" ] || die "$BUNDLE/lumora missing (run flutter build linux --release first)"
[ -f "$BUNDLE/lib/liblumora_ffi.so" ] || die "$BUNDLE/lib/liblumora_ffi.so missing (copy the Rust core into the bundle)"
[ -d "$BUNDLE/data" ] || die "$BUNDLE/data missing"
for t in dpkg-deb readelf; do command -v "$t" >/dev/null || die "$t not found"; done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- runtime dependencies
# Every shared library the bundle needs must be either inside the bundle or provided by a
# package listed below. A new plugin / core dependency with an unknown library fails the
# build here instead of crashing on users' machines.
declare -A PKG=(
  [libc.so.6]=libc6 [libm.so.6]=libc6 [libdl.so.2]=libc6 [libpthread.so.0]=libc6 [librt.so.1]=libc6
  [ld-linux-x86-64.so.2]=libc6
  [libstdc++.so.6]=libstdc++6 [libgcc_s.so.1]=libgcc-s1
  [libgtk-3.so.0]="libgtk-3-0t64 | libgtk-3-0" [libgdk-3.so.0]="libgtk-3-0t64 | libgtk-3-0"
  [libpangocairo-1.0.so.0]="libpangocairo-1.0-0" [libpango-1.0.so.0]="libpango-1.0-0"
  [libatk-1.0.so.0]="libatk1.0-0t64 | libatk1.0-0" [libcairo.so.2]=libcairo2
  [libgdk_pixbuf-2.0.so.0]="libgdk-pixbuf-2.0-0"
  [libgio-2.0.so.0]="libglib2.0-0t64 | libglib2.0-0" [libgobject-2.0.so.0]="libglib2.0-0t64 | libglib2.0-0"
  [libglib-2.0.so.0]="libglib2.0-0t64 | libglib2.0-0" [libgmodule-2.0.so.0]="libglib2.0-0t64 | libglib2.0-0"
  [libepoxy.so.0]=libepoxy0 [libfontconfig.so.1]=libfontconfig1 [libharfbuzz.so.0]=libharfbuzz0b
  [libdbus-1.so.3]=libdbus-1-3 [libopus.so.0]=libopus0
  [libpipewire-0.3.so.0]="libpipewire-0.3-0t64 | libpipewire-0.3-0"
  [libasound.so.2]="libasound2t64 | libasound2"
  [libX11.so.6]=libx11-6 [libXtst.so.6]=libxtst6 [libXext.so.6]=libxext6 [libXi.so.6]=libxi6
  [libxdo.so.3]=libxdo3 [libgbm.so.1]=libgbm1 [libEGL.so.1]=libegl1 [libGL.so.1]=libgl1
  [libxcb.so.1]=libxcb1 [libz.so.1]=zlib1g
)
mapfile -t ELFS < <(find "$BUNDLE" -type f \( -name '*.so*' -o -path "$BUNDLE/lumora" \) | sort)
bundled="$(for f in "${ELFS[@]}"; do basename "$f"; done)"
declare -A DEPS=()
glibc_min="2.17"
for f in "${ELFS[@]}"; do
  readelf -h "$f" >/dev/null 2>&1 || continue
  while read -r lib; do
    grep -qxF "$lib" <<<"$bundled" && continue
    [ -n "${PKG[$lib]:-}" ] || die "$(basename "$f") needs $lib: add its package to PKG in packaging/linux/package.sh"
    DEPS["${PKG[$lib]}"]=1
  done < <(readelf -d "$f" | sed -nE 's/.*\(NEEDED\).*\[(.*)\]/\1/p')
  v="$(readelf -V "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sed 's/GLIBC_//' | sort -V | tail -1 || true)"
  [ -n "$v" ] && glibc_min="$(printf '%s\n%s\n' "$glibc_min" "$v" | sort -V | tail -1)"
done
unset 'DEPS[libc6]'
depends="libc6 (>= $glibc_min)"
mapfile -t sorted < <(printf '%s\n' "${!DEPS[@]}" | sort)
for d in "${sorted[@]}"; do depends+=", $d"; done
echo "minimum glibc: $glibc_min"
echo "Depends: $depends"

# ---------------------------------------------------------------- .tar.gz (portable bundle)
TOP="Lumora-v$VERSION-linux-x86_64"
install -d "$WORK/tar/$TOP"
cp -a "$BUNDLE/." "$WORK/tar/$TOP/"
chmod -R u+rwX,go+rX,go-w "$WORK/tar/$TOP"
tar --sort=name --owner=0 --group=0 --numeric-owner -C "$WORK/tar" -czf "$OUT/$TOP.tar.gz" "$TOP"
echo "built $OUT/$TOP.tar.gz"

# ---------------------------------------------------------------- .deb
DEB_ROOT="$WORK/deb"
install -d "$DEB_ROOT/DEBIAN" "$DEB_ROOT/opt/lumora" "$DEB_ROOT/usr/bin" "$DEB_ROOT/usr/share/applications"
cp -a "$BUNDLE/." "$DEB_ROOT/opt/lumora/"
# Flutter finds lib/ and data/ next to the real executable (/proc/self/exe), so a symlink works.
ln -s /opt/lumora/lumora "$DEB_ROOT/usr/bin/lumora"
install -m 0644 "$DESKTOP" "$DEB_ROOT/usr/share/applications/$APP_ID.desktop"
for d in "$ICONS"/*/apps; do
  size="$(basename "$(dirname "$d")")"
  install -d "$DEB_ROOT/usr/share/icons/hicolor/$size/apps"
  install -m 0644 "$d"/lumora.* "$DEB_ROOT/usr/share/icons/hicolor/$size/apps/"
done
install -d "$DEB_ROOT/usr/share/doc/lumora"
for f in LICENSE.md THIRD_PARTY_NOTICES.md; do
  [ -f "$ROOT/packaging/release-repo/$f" ] && install -m 0644 "$ROOT/packaging/release-repo/$f" "$DEB_ROOT/usr/share/doc/lumora/"
done
chmod -R u+rwX,go+rX,go-w "$DEB_ROOT/opt" "$DEB_ROOT/usr"
installed_kb="$(du -sk --exclude=DEBIAN "$DEB_ROOT" | cut -f1)"
cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: lumora
Version: $VERSION
Architecture: amd64
Maintainer: Lumora <https://github.com/hoangtuvungcao/get_lumora>
Installed-Size: $installed_kb
Depends: $depends
Recommends: xdg-utils, xdg-desktop-portal, pulseaudio-utils, ffmpeg, zenity | kdialog, libva2, libva-drm2
Section: net
Priority: optional
Homepage: https://getlumora.pages.dev
Description: Private chat, calls, file sharing and remote desktop
 Lumora connects your devices directly to your friends' devices: messages, voice
 and video calls, file transfers and remote desktop are end-to-end encrypted and
 no central server stores your conversations.
EOF
DEB="$OUT/Lumora-v$VERSION-linux-amd64.deb"
dpkg-deb --root-owner-group -Zxz --build "$DEB_ROOT" "$DEB" >/dev/null
dpkg-deb --info "$DEB" >/dev/null
dpkg-deb --contents "$DEB" | grep './opt/lumora/lib/liblumora_ffi.so' >/dev/null || die "core library missing from the .deb"
echo "built $DEB"

# ---------------------------------------------------------------- AppImage
[ "${SKIP_APPIMAGE:-0}" = 1 ] && exit 0
fetch() { # url sha256 dest
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c --quiet - || die "checksum mismatch for $1"
  chmod +x "$3"
}
TOOL="${APPIMAGETOOL:-}"
RUNTIME="${APPIMAGE_RUNTIME:-}"
[ -n "$TOOL" ] || { TOOL="$WORK/appimagetool"; fetch "$APPIMAGETOOL_URL" "$APPIMAGETOOL_SHA256" "$TOOL"; }
[ -n "$RUNTIME" ] || { RUNTIME="$WORK/runtime-x86_64"; fetch "$RUNTIME_URL" "$RUNTIME_SHA256" "$RUNTIME"; }

APPDIR="$WORK/Lumora.AppDir"
install -d "$APPDIR/usr/lib/lumora" "$APPDIR/usr/share/applications"
cp -a "$BUNDLE/." "$APPDIR/usr/lib/lumora/"
install -d "$APPDIR/usr/share/icons"
cp -a "$ICONS" "$APPDIR/usr/share/icons/"
install -m 0644 "$DESKTOP" "$APPDIR/$APP_ID.desktop"
install -m 0644 "$DESKTOP" "$APPDIR/usr/share/applications/$APP_ID.desktop"
install -m 0644 "$ICONS/256x256/apps/lumora.png" "$APPDIR/lumora.png"
ln -s lumora.png "$APPDIR/.DirIcon"
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/lib/lumora/lumora" "$@"
EOF
chmod 0755 "$APPDIR/AppRun"
chmod -R u+rwX,go+rX,go-w "$APPDIR"
APPIMAGE="$OUT/Lumora-v$VERSION-linux-x86_64.AppImage"
# --appimage-extract-and-run: CI runners (and containers) have no FUSE.
ARCH=x86_64 VERSION="$VERSION" "$TOOL" --appimage-extract-and-run --no-appstream --runtime-file "$RUNTIME" \
  "$APPDIR" "$APPIMAGE"
[ -s "$APPIMAGE" ] || die "appimagetool produced nothing"
chmod 0755 "$APPIMAGE"
echo "built $APPIMAGE"

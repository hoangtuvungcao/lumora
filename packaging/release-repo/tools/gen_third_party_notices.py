#!/usr/bin/env python3
"""Generate THIRD_PARTY_NOTICES.md for the closed Lumora binary releases.

Python 3 standard library only. Run it isolated:

    python3 -I packaging/release-repo/tools/gen_third_party_notices.py

What it does
------------
1. Rust: runs `cargo metadata --format-version 1 --locked [--offline]` in core/ once per
   release target (--filter-platform), walks the resolve graph from the shipped crates
   (lumora-ffi with feature `media`, lumora-cli with feature `media`) along *normal*
   dependencies only, and takes the union over all targets. Dev-dependencies are never
   followed. Build-dependencies are skipped (build scripts and code generators such as
   cc, cmake, bindgen do not end up in the binary) EXCEPT build-only crates whose name ends
   in `-src` (openssl-src, sqlcipher-src): those carry C sources that are compiled INTO the
   binary. Proc-macro crates are kept (conservative: their expansions end up in the binary).
   Workspace crates are excluded. Per-target filtering (rather than "everything in
   Cargo.lock") avoids listing wasm/other-OS crates that are never shipped.
2. Flutter/Dart: runs `flutter pub deps --json` in app/, walks the non-dev transitive
   dependencies, reads each package's LICENSE from the location given in
   app/.dart_tool/package_config.json, guesses the license type and embeds each distinct
   license text once. Flutter framework/engine and Dart SDK licenses are read from the SDK.
3. Things neither cargo nor pub describes (fonts, emoji artwork, native libraries vendored
   inside -sys crates, prebuilt PDFium, Android/Windows runtime libraries, the installer):
   see BUNDLED and RUST_NATIVE below. THOSE LISTS ARE HAND-MAINTAINED: update them whenever
   assets, plugins or packaging change. Every entry names an `evidence` path that must
   exist; entries whose evidence is missing are reported in the review file instead of
   being silently printed.

Anything whose license cannot be determined, plus the legal points the owner must check, goes
to a separate INTERNAL file (--review-out, default THIRD_PARTY_REVIEW.md next to the notices)
that is never published. The public notices file contains only neutral facts. Not legal advice.
"""

import argparse
import collections
import datetime
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RELEASE_REPO = os.path.dirname(HERE)
PROJECT = os.path.dirname(os.path.dirname(RELEASE_REPO))  # .../p2p_all

DEFAULT_TARGETS = [
    "x86_64-unknown-linux-gnu",
    "x86_64-pc-windows-msvc",
    "aarch64-apple-darwin",
    "x86_64-apple-darwin",
    "aarch64-apple-ios",
    "aarch64-linux-android",
    "armv7-linux-androideabi",
    "x86_64-linux-android",
]
DEFAULT_ROOTS = ["lumora-ffi", "lumora-cli"]
DEFAULT_FEATURES = "lumora-ffi/media,lumora-cli/media"

# Order in which we *elect* a license from an "A OR B" choice (lower = preferred).
PREFERENCE = [
    "MIT", "Apache-2.0", "BSD-3-Clause", "BSD-2-Clause", "ISC", "Zlib", "0BSD", "MIT-0",
    "Unlicense", "CC0-1.0", "Unicode-3.0", "Unicode-DFS-2016", "BSL-1.0", "BlueOak-1.0.0",
    "CDLA-Permissive-2.0", "Apache-2.0 WITH LLVM-exception", "blessing", "WTFPL", "OFL-1.1",
    "CC-BY-4.0", "MPL-2.0",
]
COPYLEFT_PREFIXES = ("GPL", "LGPL", "AGPL", "MPL", "EPL", "CDDL", "EUPL", "OSL", "CPL", "SSPL")

# Short, well-known texts that are usually only found in source headers.
FALLBACK_TEXTS = {
    "WTFPL": (
        "            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE\n"
        "                    Version 2, December 2004\n\n"
        " Copyright (C) 2004 Sam Hocevar <sam@hocevar.net>\n\n"
        " Everyone is permitted to copy and distribute verbatim or modified\n"
        " copies of this license document, and changing it is allowed as long\n"
        " as the name is changed.\n\n"
        "            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE\n"
        "   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION\n\n"
        "  0. You just DO WHAT THE FUCK YOU WANT TO.\n"
    ),
    "blessing": (
        "The author disclaims copyright to this source code.  In place of\n"
        "a legal notice, here is a blessing:\n\n"
        "   May you do good and not evil.\n"
        "   May you find forgiveness for yourself and forgive others.\n"
        "   May you share freely, never taking more than you give.\n"
    ),
}

# ---------------------------------------------------------------------------------------
# HAND-MAINTAINED: native code vendored inside Rust crates (compiled into lumora_ffi /
# lumorad). Update when lumora-media / lumora-core native dependencies change.
# `files` are relative to the crate directory in ~/.cargo/registry.
# ---------------------------------------------------------------------------------------
RUST_NATIVE = [
    {"crate": "audiopus_sys", "component": "Opus audio codec (Xiph.Org and contributors)",
     "license": "BSD-3-Clause", "files": ["opus/COPYING", "opus/LICENSE_PLEASE_READ.txt"],
     "note": "Bundled source is compiled in unless the build host provides a system libopus "
             "via pkg-config (then libopus is linked dynamically and is not shipped)."},
    {"crate": "aec-rs-sys", "component": "SpeexDSP echo canceller (Xiph.Org and contributors)",
     "license": "BSD-3-Clause", "files": ["speexdsp/COPYING"],
     "note": "Compiled from the copy inside aec-rs-sys. The crate itself ships no license file."},
    {"crate": "secp256k1-sys", "component": "libsecp256k1 (Bitcoin Core contributors)",
     "license": "MIT", "files": ["depend/secp256k1/COPYING"], "note": ""},
    {"crate": "openssl-src", "component": "OpenSSL 3.x libcrypto (used by SQLCipher)",
     "license": "Apache-2.0", "files": ["openssl/LICENSE.txt"],
     "note": "Vendored and statically linked via rusqlite feature bundled-sqlcipher-vendored-openssl."},
    {"crate": "sqlcipher-src", "component": "SQLCipher (Zetetic LLC) with SQLite (public domain) "
     "and LibTomCrypt", "license": "BSD-3-Clause AND blessing",
     "files": ["sqlcipher/LICENSE-sqlcipher", "sqlcipher/LICENSE-libtomcrypt"],
     "note": "SQLite itself is public domain (blessing). LibTomCrypt sources are present in the "
             "package (public domain / WTFPL dual license); with vendored OpenSSL it is not the "
             "selected crypto provider."},
    {"crate": "ring", "component": "BoringSSL / OpenSSL-derived crypto code inside ring",
     "license": "Apache-2.0 AND ISC", "files": ["LICENSE-BoringSSL", "LICENSE-other-bits"], "note": ""},
]

# ---------------------------------------------------------------------------------------
# HAND-MAINTAINED: bundled assets and binaries that cargo/pub do not describe.
# MUST be updated when assets, fonts, plugins, native libraries or installers change.
#   evidence:      repo-relative paths/globs (or {flutter}/{pub:<pkg>} prefixed) that must exist
#   evidence_grep: optional (path, regex) that must match, to prove the thing is really used
#   license_file:  optional file whose text is embedded (same prefixes allowed)
#   text_id:       optional SPDX id whose canonical text (collected elsewhere) applies
#   review:        optional string -> also listed in the internal review file
#   kind:          bundled | runtime-lib | build-tool | service | not-distributed
# ---------------------------------------------------------------------------------------
BUNDLED = [
    {"name": "libvpx 1.17.0 - VP8/VP9 video codec (WebM Project), vendored in core/third_party/libvpx",
     "license": "BSD-3-Clause", "platforms": "all", "kind": "bundled",
     "evidence": ["core/third_party/libvpx/LICENSE", "core/third_party/libvpx/PATENTS",
                  "core/crates/lumora-vpx-sys/build.rs"],
     "evidence_grep": ("core/crates/lumora-media/Cargo.toml", r"lumora-vpx-sys"),
     "license_file": "core/third_party/libvpx/LICENSE",
     "attribution": "Copyright (c) 2010, The WebM Project authors. Compiled from source into the "
                    "Lumora core (lumora-vpx-sys) for VP8/VP9 video calls and screen sharing. Google "
                    "grants a royalty-free patent license for VP8/VP9 (core/third_party/libvpx/PATENTS, "
                    "reproduced in the next entry)."},
    {"name": "x86inc.asm (x264 project), part of the libvpx x86 assembly", "license": "ISC",
     "platforms": "Windows, Linux, macOS (x86_64), Android (x86_64)", "kind": "bundled",
     "evidence": ["core/third_party/libvpx/third_party/x86inc/x86inc.asm"],
     "license_file": "core/third_party/libvpx/third_party/x86inc/LICENSE",
     "attribution": "Copyright (C) 2005-2012 x264 project. Assembler macros used to build libvpx's "
                    "x86 SIMD code (NASM)."},
    {"name": "libva (VA-API, Intel) - system library loaded at run time on Linux if present",
     "license": "MIT", "platforms": "Linux", "kind": "runtime-lib",
     "evidence": ["core/crates/lumora-media/src/codec/vaapi.rs", "core/crates/lumora-media/src/codec/vaapi_sys.rs"],
     "evidence_grep": ("core/crates/lumora-media/src/codec/vaapi.rs", r"libva"),
     "attribution": "Not shipped: libva.so.2 / libva-drm.so.2 of the user's system are opened with "
                    "dlopen for hardware H.264 on Intel/AMD GPUs. The type definitions in vaapi_sys.rs "
                    "are generated from the libva headers, Copyright (c) 2007-2018 Intel Corporation, MIT.",
     "text_id": "MIT"},
    {"name": "libvpx additional IP rights grant (patents)", "license": "LicenseRef-WebM-Patent-Grant",
     "platforms": "all", "kind": "bundled", "evidence": ["core/third_party/libvpx/PATENTS"],
     "license_file": "core/third_party/libvpx/PATENTS",
     "attribution": "Google's royalty-free patent license for its VP8/VP9 implementation (no "
                    "attribution required; reproduced for completeness)."},
    {"name": "Noto Animated Emoji (about 120 Lottie animations, modified)", "license": "CC-BY-4.0",
     "platforms": "all", "kind": "bundled",
     "evidence": ["app/assets/emoji_anim/*.json.gz", "app/tool/fetch_animated_emoji.py"],
     "attribution": "Animated emoji: Noto Animated Emoji, copyright Google LLC. "
                    "https://googlefonts.github.io/noto-emoji-animation/ - licensed under CC BY 4.0 "
                    "(https://creativecommons.org/licenses/by/4.0/legalcode). Changes: a selection of "
                    "about 120 animations, re-encoded (numbers rounded to 3 decimals, minified, "
                    "gzip-compressed). The same attribution is shown in the app (Settings > About > "
                    "Open-source licenses).",
     "text_id": "CC-BY-4.0"},
    {"name": "Noto Color Emoji font (COLRv1)", "license": "OFL-1.1", "platforms": "Windows, Linux",
     "kind": "bundled", "evidence": ["app/assets/desktop/NotoColorEmoji-COLRv1.ttf"],
     "evidence_grep": ("app/linux/CMakeLists.txt", r"NotoColorEmoji-COLRv1\.ttf"),
     "license_file": "app/assets/desktop/NotoColorEmoji-OFL.txt",
     "attribution": "Copyright 2013 Google LLC. https://github.com/googlefonts/noto-emoji"},
    {"name": "Be Vietnam Pro font", "license": "OFL-1.1", "platforms": "all", "kind": "bundled",
     "evidence": ["app/assets/fonts/BeVietnamPro-*.ttf"], "license_file": "app/assets/fonts/OFL.txt",
     "attribution": "Copyright 2021 The Be Vietnam Pro Project Authors (https://github.com/bettergui/BeVietnamPro)"},
    {"name": "Phosphor Icons (icon fonts via phosphor_flutter)", "license": "MIT", "platforms": "all",
     "kind": "bundled", "evidence": ["{pub:phosphor_flutter}/LICENSE"],
     "license_file": "{pub:phosphor_flutter}/LICENSE",
     "attribution": "Copyright (c) 2020-2021 Phosphor Icons. https://phosphoricons.com"},
    {"name": "Material Icons font (Flutter SDK, tree-shaken)", "license": "CC-BY-4.0", "platforms": "all",
     "kind": "bundled", "evidence": ["{flutter}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf"],
     "evidence_grep": ("app/pubspec.yaml", r"(?m)^\s*uses-material-design:\s*true"),
     "license_file": "{flutter}/bin/cache/artifacts/material_fonts/MaterialIcons_LICENSE.txt",
     "attribution": "Material Icons, copyright Google LLC (license text as shipped in the Flutter SDK)."},
    {"name": "Unicode emoji data (emoji-test.txt, Emoji 15.1) and Unicode CLDR 45 annotations",
     "license": "Unicode-3.0", "platforms": "all", "kind": "bundled",
     "evidence": ["app/lib/ui/chats/emoji_data.dart", "app/lib/ui/chats/emoji_keywords.dart"],
     "evidence_grep": ("app/lib/ui/chats/emoji_keywords.dart", r"CLDR"), "text_id": "Unicode-3.0",
     "attribution": "Copyright (c) Unicode, Inc. Unicode License v3, https://www.unicode.org/license.txt"},
    {"name": "emojibase-data 15.3 (English emoji keywords and shortcodes)", "license": "MIT",
     "platforms": "all", "kind": "bundled", "evidence": ["app/lib/ui/chats/emoji_keywords.dart"],
     "evidence_grep": ("app/lib/ui/chats/emoji_keywords.dart", r"emojibase"), "text_id": "MIT",
     "attribution": "Copyright (c) Miles Johnson. https://github.com/milesj/emojibase"},
    {"name": "BIP-39 English word list (recovery phrase)", "license": "NOASSERTION", "platforms": "all",
     "kind": "bundled", "evidence": ["app/lib/core/bip39_wordlist.dart",
                                     "core/crates/lumora-core/src/bip39_english.txt"],
     "attribution": "From https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt",
     "review": "The BIP-39 document carries no explicit license header in the bitcoin/bips "
               "repository (a list of common English words is probably not copyrightable). "
               "Owner/lawyer to confirm; credit the source anyway."},
    {"name": "Demo/mock assets (photos assets/mock/*.jpg, sample files assets/mock/files/*)",
     "license": "NOASSERTION", "platforms": "all", "kind": "bundled",
     "evidence": ["app/assets/mock/*.jpg", "app/assets/mock/files/sample.pdf"],
     "evidence_grep": ("app/pubspec.yaml", r"assets/mock/"),
     "review": "These files are listed in pubspec.yaml and therefore ship inside every build. "
               "Their origin/license is not recorded in the repo. Either confirm they were "
               "created by the owner (or are licensed for redistribution), or drop them from "
               "release builds."},
    {"name": "PDFium (prebuilt by pdfium-binaries / pdfium-xcframework, downloaded by pdfium_flutter "
             "at build time)", "license": "BSD-3-Clause AND Apache-2.0", "platforms": "all",
     "kind": "runtime-lib", "evidence": ["{pub:pdfium_flutter}/linux/CMakeLists.txt"],
     "version_from": ("{pub:pdfium_flutter}/linux/CMakeLists.txt", r"set\(PDFIUM_RELEASE\s+([^)\s]+)\)"),
     "attribution": "Copyright 2014 The PDFium Authors. https://pdfium.googlesource.com/pdfium/ ; "
                    "binaries from https://github.com/bblanchon/pdfium-binaries (Windows, Linux, "
                    "Android) and https://github.com/espresso3389/pdfium-xcframework (Apple).",
     "review": "The PDFium binary also contains third-party libraries (for example FreeType, "
               "libjpeg-turbo, libpng, zlib, Little CMS, OpenJPEG) under their own licenses. The "
               "pdfium-binaries archive ships a LICENSE file / licenses folder with all of them: "
               "copy that text into the release (e.g. append it here) - this script cannot see it "
               "because the archive is only downloaded during `flutter build`. FreeType's FTL "
               "requires a credit line in the documentation. pdfrx's pdfium.wasm (web only) is "
               "removed in CI by `dart run pdfrx:remove_wasm_modules`."},
    {"name": "LLVM libc++ (libc++_shared.so from the Android NDK)",
     "license": "Apache-2.0 WITH LLVM-exception", "platforms": "Android", "kind": "runtime-lib",
     "evidence": ["app/android/app/src/main/jniLibs/*/libc++_shared.so"],
     "attribution": "Copyright (c) LLVM Project contributors. https://llvm.org/LICENSE.txt",
     "license_file": "{ndk}/toolchains/llvm/prebuilt/*/NOTICE",
     "license_cut": r"(?s)^.*?---- LLVM Exceptions to the Apache 2.0 License ----.*?(?=\n=====)"},
    {"name": "AndroidX, Jetpack Media3 (ExoPlayer), Kotlin standard library (pulled in by Flutter "
             "plugins through Gradle)", "license": "Apache-2.0", "platforms": "Android",
     "kind": "runtime-lib", "evidence": ["{pub:just_audio}/android/build.gradle.kts"],
     "evidence_grep": ("{pub:just_audio}/android/build.gradle.kts", r"androidx\.media3"), "text_id": "Apache-2.0",
     "attribution": "Copyright The Android Open Source Project / JetBrains s.r.o. and contributors."},
    {"name": "Google Play services Location (com.google.android.gms:play-services-location, via "
             "geolocator_android)", "license": "LicenseRef-Google-Android-SDK", "platforms": "Android",
     "kind": "runtime-lib", "evidence": ["{pub:geolocator_android}/android/build.gradle"],
     "evidence_grep": ("{pub:geolocator_android}/android/build.gradle", r"play-services-location"),
     "attribution": "Copyright Google LLC. Proprietary; distributed under the Android Software "
                    "Development Kit License Agreement / Google APIs Terms of Service.",
     "review": "Proprietary Google component inside the APK (not open source). Allowed for apps, "
               "but its terms are Google's, and it is unavailable on de-Googled devices. Its own "
               "notices can be generated with the oss-licenses Gradle plugin."},
    {"name": "Microsoft Visual C++ runtime DLLs (msvcp140.dll, vcruntime140.dll, vcruntime140_1.dll)",
     "license": "LicenseRef-Microsoft-VC-Redist", "platforms": "Windows", "kind": "runtime-lib",
     "evidence": ["packaging/windows/README.md"],
     "evidence_grep": ("packaging/windows/README.md", r"vcruntime140\.dll"),
     "attribution": "Copyright Microsoft Corporation. Redistributed as 'Distributable Code' under the "
                    "Microsoft Visual Studio license terms.",
     "review": "App-local deployment is allowed only for holders of a Visual Studio license that "
               "grants distributable-code rights, and Microsoft asks that the files be taken from "
               "the Visual Studio redist folder (VC\\Redist\\MSVC\\<ver>\\x64\\Microsoft.VC143.CRT), "
               "not copied from System32 as packaging/windows/README.md currently does."},
    {"name": "Inno Setup (installer engine / setup stub inside the Windows installer .exe)",
     "license": "LicenseRef-InnoSetup", "platforms": "Windows installer", "kind": "build-tool",
     "evidence": ["packaging/windows/lumora.iss"],
     "attribution": "Copyright (C) 1997-2025 Jordan Russell, Martijn Laan. https://jrsoftware.org/isinfo.php",
     "review": "The setup stub compiled into the installer is Inno Setup code. Check the CURRENT "
               "Inno Setup license (https://jrsoftware.org/files/is/license.txt): recent releases "
               "changed the terms for commercial use - confirm a freeware release qualifies or "
               "buy a commercial license; keep its copyright notice in the installer."},
    {"name": "OpenStreetMap map tiles (location messages)", "license": "ODbL-1.0 (data) / tile usage policy",
     "platforms": "all", "kind": "service", "evidence": ["app/lib/ui/chats/rich_bubbles.dart"],
     "evidence_grep": ("app/lib/ui/chats/rich_bubbles.dart", r"tile\.openstreetmap\.org"),
     "attribution": "(c) OpenStreetMap contributors - shown in the map widget. Tiles are fetched at "
                    "runtime from tile.openstreetmap.org, nothing is bundled.",
     "review": "The OSM Foundation tile usage policy forbids heavy use without permission and "
               "requires a valid User-Agent; consider a commercial tile provider for a public "
               "release. Also mentioned in the EULA privacy section."},
    {"name": "System libraries linked dynamically on Linux and NOT shipped: PipeWire (MIT), ALSA "
             "libasound (LGPL-2.1-or-later), libdbus (AFL-2.1 OR GPL-2.0-or-later), GTK 3 / GLib "
             "(LGPL-2.1-or-later, Flutter Linux embedder), X11/xcb libraries (MIT)",
     "license": "various (not distributed)", "platforms": "Linux", "kind": "not-distributed",
     "evidence": ["core/crates/lumora-media/Cargo.toml"],
     "evidence_grep": ("core/crates/lumora-media/Cargo.toml", r"pipewire"),
     "attribution": "Provided by the user's Linux distribution. If they are ever bundled (AppImage, "
                    "Flatpak runtime excluded), the LGPL ones must stay dynamically linked and "
                    "replaceable, with their license texts and source offer included."},
]


# ======================================================================================
# helpers
# ======================================================================================

def log(*a):
    print(*a, file=sys.stderr)


def read_text(path, limit=2_000_000):
    try:
        with open(path, "rb") as f:
            data = f.read(limit)
    except OSError:
        return None
    for enc in ("utf-8", "latin-1"):
        try:
            return data.decode(enc).replace("\r\n", "\n").replace("\r", "\n")
        except UnicodeDecodeError:
            continue
    return None


def run_json(cmd, cwd):
    log("$", " ".join(cmd), " (in %s)" % cwd)
    r = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if r.returncode != 0:
        raise RuntimeError("command failed (%d): %s\n%s" % (r.returncode, " ".join(cmd), r.stderr[-3000:]))
    return json.loads(r.stdout)


def md_cell(s):
    return (s or "").replace("|", "\\|").replace("\n", " ").strip()


def fence(text):
    text = text.rstrip("\n")
    n = 3
    while "`" * n in text:
        n += 1
    return "%stext\n%s\n%s" % ("`" * n, text, "`" * n)


LICENSE_FILE_RE = re.compile(r"(?i)^(licen[cs]e|copying|unlicense|copyright|notice)([-._].*)?$")
NOTICE_FILE_RE = re.compile(r"(?i)^notice([-._].*)?$")
COPYRIGHT_RE = re.compile(r"^\s*(?:[*#;/]+\s*)?((?:Copyright|COPYRIGHT|\(c\)|\(C\)|©):?\s*(?:\(c\)|\(C\)|©|\d|[A-Z]).*)$")
TEMPLATE_MARKERS = ("[yyyy]", "{yyyy}", "<year>", "[year]", "[fullname]", "<copyright holders>",
                    "[name of copyright owner]", "{name of copyright owner}", "<owner>")


def copyright_lines(text, limit=6):
    out = []
    for line in text.split("\n"):
        m = COPYRIGHT_RE.match(line)
        if not m:
            continue
        s = re.sub(r"\s+", " ", m.group(1)).strip()
        if re.match(r"\((c|C)\)\s*[^\d\s]", s) and not re.match(r"\((c|C)\)\s*copyright", s, re.I):
            continue  # "(c) You must retain ..." (Apache-2.0 clause 4(c)) and similar list items
        low = s.lower()
        if any(w in low for w in ("liable", "as is", "warrant", "holders and contributors",
                                  "holder and contributors", "owner or contributors", "permission notice")):
            continue  # disclaimer text, not a notice
        if any(t.lower() in low for t in TEMPLATE_MARKERS):
            continue
        if "copyright notice" in low or "copyright license" in low or "copyright and similar" in low \
                or "copyright owner" in low or "copyright holders" in low and len(s) > 120:
            continue
        if len(s) > 200:
            s = s[:200] + "..."
        if s not in out:
            out.append(s)
        if len(out) >= limit:
            break
    return out


def strip_copyright(text):
    keep = []
    for line in text.split("\n"):
        m = COPYRIGHT_RE.match(line)
        if m and not any(t.lower() in line.lower() for t in TEMPLATE_MARKERS) \
                and "notice" not in line.lower():
            continue
        keep.append(line)
    return "\n".join(keep).strip("\n")


def norm(text):
    return re.sub(r"[\s*#/]+", " ", strip_copyright(text)).strip().lower()


def classify_text(text, filename=""):
    """Heuristic license detection. Returns a sorted list of SPDX-ish ids (may be empty)."""
    t = re.sub(r"\s+", " ", text).lower()
    fn = filename.upper()
    ids = set()
    if "apache license" in t and ("version 2.0" in t or "2.0" in t):
        ids.add("Apache-2.0 WITH LLVM-exception" if "llvm exceptions" in t else "Apache-2.0")
    if "mozilla public license" in t and "2.0" in t:
        ids.add("MPL-2.0")
    mpl = "mozilla public license" in t and "2.0" in t
    # MPL-2.0 names the GPL/LGPL/AGPL as "Secondary Licenses": do not count those mentions.
    if mpl:
        pass
    elif "gnu affero general public license" in t:
        ids.add("AGPL")
    elif "gnu lesser general public license" in t or "gnu library general public license" in t:
        ids.add("LGPL")
    elif "gnu general public license" in t:
        ids.add("GPL")
    if "eclipse public license" in t:
        ids.add("EPL")
    if "common development and distribution license" in t:
        ids.add("CDDL")
    unicode = "unicode license v3" in t or "unicode, inc. license agreement" in t
    if "permission is hereby granted, free of charge" in t and not unicode:
        if "the above copyright notice and this permission notice shall be included" in t:
            ids.add("MIT")
        else:
            ids.add("MIT-0")
    if "redistribution and use in source and binary forms" in t:
        if re.search(r"neither the name|names of (its|the) contributors|name of the copyright holder"
                     r"|nor the names", t):
            ids.add("BSD-3-Clause")
        else:
            ids.add("BSD-2-Clause")
    if "permission to use, copy, modify, and/or distribute this software for any purpose" in t \
            or "permission to use, copy, modify, and distribute this software for any purpose with or without fee" in t:
        ids.add("ISC" if "0bsd" not in fn else "0BSD")
    if "altered source versions must be plainly marked" in t and "provided 'as-is'" in t:
        ids.add("Zlib")
    if "sil open font license" in t:
        ids.add("OFL-1.1")
    if "attribution 4.0 international" in t and "creative commons" in t:
        ids.add("CC-BY-4.0")
    if "cc0 1.0 universal" in t or ("creative commons legal code" in t and "cc0" in t):
        ids.add("CC0-1.0")
    if "unicode license v3" in t:
        ids.add("Unicode-3.0")
    elif "unicode, inc. license agreement" in t:
        ids.add("Unicode-DFS-2016")
    if "boost software license" in t:
        ids.add("BSL-1.0")
    if "free and unencumbered software released into the public domain" in t:
        ids.add("Unlicense")
    if "community data license agreement" in t and "permissive" in t:
        ids.add("CDLA-Permissive-2.0")
    if "blue oak model license" in t:
        ids.add("BlueOak-1.0.0")
    if "do what the fuck you want" in t:
        ids.add("WTFPL")
    if "may you do good and not evil" in t:
        ids.add("blessing")
    # filename hints for the common dual-license layout
    if not ids:
        if "APACHE" in fn:
            ids.add("Apache-2.0")
        elif "MIT" in fn:
            ids.add("MIT")
    return sorted(ids)


# ---- SPDX expressions ----------------------------------------------------------------

def spdx_tokens(expr):
    expr = expr.replace("/", " OR ")
    return re.findall(r"\(|\)|[^\s()]+", expr)


def spdx_dnf(expr):
    """Disjunctive normal form: list of frozensets of license ids."""
    toks = spdx_tokens(expr)
    pos = [0]

    def peek():
        return toks[pos[0]] if pos[0] < len(toks) else None

    def take():
        pos[0] += 1
        return toks[pos[0] - 1]

    def p_or():
        opts = p_and()
        while peek() and peek().upper() == "OR":
            take()
            opts = opts + p_and()
        return opts

    def p_and():
        opts = p_with()
        while peek() and peek().upper() == "AND":
            take()
            rhs = p_with()
            opts = [a | b for a in opts for b in rhs]
        return opts

    def p_with():
        if peek() == "(":
            take()
            o = p_or()
            if peek() == ")":
                take()
            return o
        lid = take()
        if peek() and peek().upper() == "WITH":
            take()
            lid = "%s WITH %s" % (lid, take())
        return [frozenset([lid])]

    if not toks:
        return []
    return p_or()


def canonical_expr(expr):
    return " ".join(spdx_tokens(expr)).replace("( ", "(").replace(" )", ")")


def rank(lid):
    base = PREFERENCE.index(lid) if lid in PREFERENCE else 60
    if lid.upper().startswith(COPYLEFT_PREFIXES) or lid in ("GPL", "LGPL", "AGPL"):
        base += 100
    return base


def elect(expr):
    opts = spdx_dnf(expr)
    if not opts:
        return frozenset()
    return min(opts, key=lambda o: (sum(rank(x) for x in o), len(o)))


def is_copyleft(lid):
    return lid.upper().startswith(COPYLEFT_PREFIXES) or lid in ("GPL", "LGPL", "AGPL")


# ======================================================================================
# Rust
# ======================================================================================

def cargo_metadata(core, target, features, offline):
    cmd = ["cargo", "metadata", "--format-version", "1", "--locked", "--features", features,
           "--filter-platform", target]
    if offline:
        try:
            return run_json(cmd + ["--offline"], core)
        except RuntimeError as e:
            log("offline cargo metadata failed, retrying online:", str(e)[:300])
    return run_json(cmd, core)


def collect_rust(core, targets, roots, features, offline):
    crates = {}       # id -> package
    per_target = {}
    for t in targets:
        m = cargo_metadata(core, t, features, offline)
        pk = {p["id"]: p for p in m["packages"]}
        nodes = {n["id"]: n for n in m["resolve"]["nodes"]}
        ws = set(m["workspace_members"])
        root_ids = [i for i in ws if pk[i]["name"] in roots]
        missing = set(roots) - {pk[i]["name"] for i in root_ids}
        if missing:
            raise RuntimeError("root crates not found in workspace: %s" % ", ".join(sorted(missing)))
        seen, stack = set(), list(root_ids)
        while stack:
            i = stack.pop()
            if i in seen:
                continue
            seen.add(i)
            for d in nodes[i]["deps"]:
                kinds = {k["kind"] for k in d["dep_kinds"]}
                dep = d["pkg"]
                if None in kinds:
                    stack.append(dep)
                elif "build" in kinds and pk[dep]["name"].endswith("-src"):
                    stack.append(dep)  # vendored C sources compiled into the binary
        per_target[t] = len(seen - ws)
        for i in seen - ws:
            crates.setdefault(i, pk[i])
            crates[i].setdefault("_targets", set()).add(t)
            crates[i].setdefault("_features", set()).update(nodes[i].get("features", []))
    return crates, per_target


def crate_license_files(pkg):
    d = os.path.dirname(pkg["manifest_path"])
    files = []
    try:
        names = sorted(os.listdir(d))
    except OSError:
        names = []
    for n in names:
        p = os.path.join(d, n)
        if os.path.isfile(p) and LICENSE_FILE_RE.match(n):
            files.append(p)
    lf = pkg.get("license_file")
    if lf:
        p = os.path.normpath(os.path.join(d, lf))
        if os.path.isfile(p) and p not in files:
            files.append(p)
    return d, files


# ======================================================================================
# Dart / Flutter
# ======================================================================================

def collect_dart(app, flutter):
    deps = run_json([flutter, "pub", "deps", "--json"], app)
    P = {p["name"]: p for p in deps["packages"]}
    root = P[deps["root"]]
    direct = root.get("directDependencies")
    if direct is None:
        direct = [x for x in root.get("dependencies", []) if x not in set(root.get("devDependencies", []))]
    seen, stack = set(), list(direct)
    while stack:
        n = stack.pop()
        if n in seen or n not in P:
            continue
        seen.add(n)
        stack += P[n].get("dependencies", [])
    pc = json.load(open(os.path.join(app, ".dart_tool", "package_config.json"), encoding="utf-8"))
    roots = {}
    for p in pc["packages"]:
        u = p["rootUri"]
        if u.startswith("file://"):
            u = u[len("file://"):]
        elif not u.startswith("/"):
            u = os.path.normpath(os.path.join(app, ".dart_tool", u))
        roots[p["name"]] = u
    out = []
    for n in sorted(seen):
        p = P[n]
        out.append({"name": n, "version": p.get("version", ""), "source": p.get("source", ""),
                    "dir": roots.get(n)})
    return out, deps.get("sdks", []), roots


def pubspec_field(d, field):
    t = read_text(os.path.join(d, "pubspec.yaml")) or ""
    m = re.search(r"(?m)^%s:\s*['\"]?([^'\"\s#]+)" % field, t)
    return m.group(1) if m else ""


def engine_components(sky_license):
    t = read_text(sky_license, limit=5_000_000) or ""
    names = set()
    for b in re.split(r"\n-{20,}\n", t):
        head = b.strip("\n").split("\n\n", 1)[0]
        for line in head.split("\n"):
            s = line.strip()
            if re.fullmatch(r"[a-z0-9][a-z0-9_.+-]{1,39}", s):
                names.add(s)
    return sorted(names)


# ======================================================================================
# main
# ======================================================================================

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--project", default=PROJECT)
    ap.add_argument("--flutter", default=os.environ.get("FLUTTER") or shutil.which("flutter")
                    or os.path.expanduser("~/develop/flutter/bin/flutter"))
    ap.add_argument("--out", default=os.path.join(RELEASE_REPO, "THIRD_PARTY_NOTICES.md"))
    ap.add_argument("--review-out", default=os.path.join(RELEASE_REPO, "THIRD_PARTY_REVIEW.md"),
                    help="internal (never published) list of items for the owner to check")
    ap.add_argument("--targets", default=",".join(DEFAULT_TARGETS))
    ap.add_argument("--roots", default=",".join(DEFAULT_ROOTS),
                    help="shipped workspace crates (add lumora-relay,lumora-push if their binaries are released)")
    ap.add_argument("--features", default=DEFAULT_FEATURES)
    ap.add_argument("--online", action="store_true", help="do not pass --offline to cargo")
    args = ap.parse_args()

    project = os.path.abspath(args.project)
    core, app = os.path.join(project, "core"), os.path.join(project, "app")
    flutter_bin = os.path.realpath(args.flutter)
    flutter_root = os.path.dirname(os.path.dirname(flutter_bin))
    review = []          # (area, item, reason)
    texts = {}           # license id -> canonical text
    text_votes = collections.defaultdict(collections.Counter)
    text_repr = {}

    # ---------------------------------------------------------------- Rust
    crates, per_target = collect_rust(core, args.targets.split(","), args.roots.split(","),
                                      args.features, not args.online)
    rust = []
    notices = []  # (owner label, path, text)
    for pid, p in crates.items():
        d, files = crate_license_files(p)
        expr = p.get("license") or ""
        if not expr:
            ids_from_files = sorted({i for f in files for i in classify_text(read_text(f) or "", os.path.basename(f))})
            expr = " AND ".join(ids_from_files) if ids_from_files else "UNKNOWN"
            review.append(("Rust", "%s %s" % (p["name"], p["version"]),
                           "no SPDX `license` field in Cargo.toml; detected from files: %s" % expr))
        cr = []
        for f in files:
            t = read_text(f) or ""
            base = os.path.basename(f)
            if NOTICE_FILE_RE.match(base):
                notices.append(("%s %s" % (p["name"], p["version"]), base, t))
                continue
            cr += [c for c in copyright_lines(t) if c not in cr]
            ids = classify_text(t, base)
            if len(ids) == 1:
                k = norm(t)
                text_votes[ids[0]][k] += 1
                text_repr.setdefault((ids[0], k), t)
        attribution = "; ".join(cr[:4])
        if not attribution:
            authors = ", ".join(p.get("authors") or [])
            attribution = ("Authors: " + authors) if authors else "(no copyright line packaged; see repository)"
        rust.append({"name": p["name"], "version": p["version"], "expr": canonical_expr(expr),
                     "elected": elect(expr) if expr != "UNKNOWN" else frozenset(["UNKNOWN"]),
                     "repo": p.get("repository") or p.get("homepage") or
                     "https://crates.io/crates/%s" % p["name"],
                     "attr": attribution, "has_files": bool(files), "dir": d,
                     "targets": p.get("_targets", set())})
        if expr == "UNKNOWN":
            review.append(("Rust", "%s %s" % (p["name"], p["version"]), "license could not be determined"))
    rust.sort(key=lambda c: (c["name"], c["version"]))
    by_name = {}
    for c in rust:
        by_name.setdefault(c["name"], c)

    # native code inside crates
    native = []
    for n in RUST_NATIVE:
        c = by_name.get(n["crate"])
        if not c:
            review.append(("Rust native", n["component"], "crate %s is no longer in the shipped graph - "
                           "remove or update the RUST_NATIVE entry" % n["crate"]))
            continue
        found = []
        for rel in n["files"]:
            fp = os.path.join(c["dir"], rel)
            t = read_text(fp)
            if t is None:
                review.append(("Rust native", n["component"], "expected license file %s not found in %s"
                               % (rel, c["dir"])))
                continue
            found.append((rel, t))
        native.append(dict(n, version=c["version"], found=found))

    for lid, votes in text_votes.items():
        k, _ = votes.most_common(1)[0]
        texts[lid] = strip_copyright(text_repr[(lid, k)])
    for lid, t in FALLBACK_TEXTS.items():
        texts.setdefault(lid, t)

    # ---------------------------------------------------------------- Dart
    dart_pkgs, sdks, pub_roots = collect_dart(app, args.flutter)
    sdk_names = {"flutter", "sky_engine", "flutter_web_plugins", "flutter_localizations"}
    dart = []
    dart_texts = collections.OrderedDict()  # hash -> {text, ids, pkgs}
    for p in dart_pkgs:
        if p["source"] == "sdk" or p["name"] in sdk_names:
            continue
        d = p["dir"]
        files = []
        if d and os.path.isdir(d):
            files = [os.path.join(d, n) for n in sorted(os.listdir(d))
                     if os.path.isfile(os.path.join(d, n)) and LICENSE_FILE_RE.match(n)]
        ids, h = [], None
        if files:
            body = "\n\n".join((read_text(f) or "").strip("\n") for f in files)
            ids = sorted({i for f in files for i in classify_text(read_text(f) or "", os.path.basename(f))})
            h = hashlib.sha256(re.sub(r"\s+", " ", body).strip().encode()).hexdigest()[:12]
            e = dart_texts.setdefault(h, {"text": body, "ids": ids, "pkgs": []})
            e["pkgs"].append("%s %s" % (p["name"], p["version"]))
            for f in files:
                t = read_text(f) or ""
                fi = classify_text(t, os.path.basename(f))
                if len(fi) == 1 and fi[0] not in texts:
                    texts[fi[0]] = strip_copyright(t)
        lic = " AND ".join(ids) if ids else "UNKNOWN"
        if not files:
            review.append(("Dart", "%s %s" % (p["name"], p["version"]), "no LICENSE file found in %s" % d))
        elif not ids:
            review.append(("Dart", "%s %s" % (p["name"], p["version"]),
                           "license file present but type not recognised - check text block %s" % h))
        cr = copyright_lines("\n".join(read_text(f) or "" for f in files)) if files else []
        repo = pubspec_field(d, "repository") or pubspec_field(d, "homepage") if d else ""
        dart.append({"name": p["name"], "version": p["version"], "lic": lic, "ids": ids,
                     "repo": repo or "https://pub.dev/packages/%s" % p["name"],
                     "attr": "; ".join(cr[:3]) or "(see license text)", "hash": h})

    flutter_license = read_text(os.path.join(flutter_root, "LICENSE")) or ""
    dart_sdk_license = read_text(os.path.join(flutter_root, "bin", "cache", "dart-sdk", "LICENSE")) or ""
    sky_license = os.path.join(flutter_root, "bin", "cache", "pkg", "sky_engine", "LICENSE")
    engine = engine_components(sky_license)
    if not flutter_license:
        review.append(("Flutter", "Flutter framework", "LICENSE not found under %s" % flutter_root))
    if not engine:
        review.append(("Flutter", "Flutter engine", "sky_engine LICENSE not found: %s" % sky_license))
    sdk_ver = {s["name"]: s["version"] for s in sdks}

    # ---------------------------------------------------------------- hand-maintained
    def find_ndk():
        sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
        lp = read_text(os.path.join(app, "android", "local.properties")) or ""
        m = re.search(r"(?m)^sdk\.dir=(.+)$", lp)
        if m:
            sdk = sdk or m.group(1).strip()
        nd = sorted(glob.glob(os.path.join(sdk or os.path.expanduser("~/Android/Sdk"), "ndk", "*")))
        return nd[-1] if nd else None

    ndk = find_ndk()

    def resolve(path):
        if path.startswith("{flutter}"):
            return flutter_root + path[len("{flutter}"):]
        if path.startswith("{ndk}"):
            if not ndk:
                return None
            hits = sorted(glob.glob(ndk + path[len("{ndk}"):]))
            return hits[0] if hits else None
        m = re.match(r"\{pub:([^}]+)\}(.*)", path)
        if m:
            r = pub_roots.get(m.group(1))
            return (r + m.group(2)) if r else None
        return os.path.join(project, path)

    bundled = []
    for b in BUNDLED:
        ok, missing = True, []
        for ev in b["evidence"]:
            rp = resolve(ev)
            if not rp or not glob.glob(rp):
                ok, missing = False, missing + [ev]
        if b.get("evidence_grep"):
            gp, rx = b["evidence_grep"]
            t = read_text(resolve(gp) or "") or ""
            if not re.search(rx, t):
                ok, missing = False, missing + ["%s !~ /%s/" % (gp, rx)]
        if not ok:
            review.append(("Bundled", b["name"], "evidence missing (%s) - the hand-maintained entry "
                           "is stale: remove or update it" % ", ".join(missing)))
            continue
        e = dict(b)
        if b.get("version_from"):
            vp, rx = b["version_from"]
            m = re.search(rx, read_text(resolve(vp) or "") or "")
            e["version"] = m.group(1).replace("%2F", "/") if m else ""
        if b.get("license_file"):
            e["text"] = read_text(resolve(b["license_file"]) or "")
            if e["text"] is not None and b.get("license_cut"):
                m = re.search(b["license_cut"], e["text"])
                e["text"] = m.group(0).strip("\n") if m else None
            if e["text"] is None:
                review.append(("Bundled", b["name"], "license file %s not found" % b["license_file"]))
        if b.get("review"):
            review.append(("Bundled", b["name"], b["review"]))
        if b["license"] == "NOASSERTION" and not b.get("review"):
            review.append(("Bundled", b["name"], "license unknown"))
        bundled.append(e)
        # a bundled license text can also serve as canonical text for its id
        if e.get("text") and b["license"] in ("CC-BY-4.0", "OFL-1.1") and b["license"] not in texts:
            texts[b["license"]] = e["text"]

    # ---------------------------------------------------------------- checks on Rust side
    needed = set()
    for c in rust:
        needed |= set(c["elected"])
    for n in native:
        for o in elect(n["license"]):
            needed.add(o)
    for lid in sorted(needed):
        if lid not in texts and lid != "UNKNOWN":
            review.append(("Rust", "license text " + lid, "no copy of the %s text was found in any "
                           "crate; add it by hand (https://spdx.org/licenses/%s.html)" % (lid, lid.split(" ")[0])))
    for c in rust:
        if not c["has_files"]:
            review.append(("Rust (minor)", "%s %s" % (c["name"], c["version"]),
                           "the published crate contains no license file; listed under its declared "
                           "license (%s) with the canonical text below" % c["expr"]))
    copyleft = []
    for c in rust:
        ids = {i for o in spdx_dnf(c["expr"]) for i in o}
        cl = sorted(i for i in c["elected"] if is_copyleft(i))
        if cl:
            copyleft.append(("Rust", "%s %s" % (c["name"], c["version"]), " ".join(cl), c["expr"]))
        elif any(is_copyleft(i) for i in ids):
            pass  # copyleft only offered as an alternative; a permissive option was elected
    for p in dart:
        cl = [i for i in p["ids"] if is_copyleft(i)]
        if cl:
            copyleft.append(("Dart", "%s %s" % (p["name"], p["version"]), " ".join(cl), p["lic"]))
    libdbus = [c for c in rust if c["name"] == "libdbus-sys"]

    # ---------------------------------------------------------------- render
    today = datetime.date.today().isoformat()
    cmdline = "python3 -I packaging/release-repo/tools/gen_third_party_notices.py"
    if len(sys.argv) > 1:
        cmdline += " " + " ".join(sys.argv[1:])
    L = []
    w = L.append
    w("# Third-party notices - Lumora")
    w("")
    w("> Generated on %s by `%s` (from `cargo metadata`, `flutter pub deps` and the hand-maintained "
      "lists inside the script). Do not edit by hand; edit the script and re-run it." % (today, cmdline))
    w("")
    w("Lumora is proprietary freeware (see LICENSE.md). It is built with the open-source and "
      "third-party components listed below, which remain under their own licenses. Nothing in the "
      "Lumora license limits the rights those licenses give you for those components.")
    w("")
    w("Scope: the Lumora desktop and mobile apps (Flutter UI + `lumora_ffi` Rust core with media "
      "features) and the `lumorad` command-line node, for targets: %s. Rust crates per target: %s."
      % (", ".join(args.targets.split(",")), ", ".join("%s=%d" % kv for kv in sorted(per_target.items()))))
    w("")

    # summary table
    counts = collections.defaultdict(lambda: [0, 0, 0])
    for c in rust:
        counts[" AND ".join(sorted(c["elected"]))][0] += 1
    for p in dart:
        counts[p["lic"]][1] += 1
    counts["BSD-3-Clause"][2] += 2  # Flutter framework/engine, Dart SDK
    for n in native:
        counts[n["license"]][2] += 1
    for b in bundled:
        if b["kind"] in ("bundled", "runtime-lib", "build-tool"):
            counts[b["license"]][2] += 1
    w("## Summary")
    w("")
    w("License under which each component is used (for \"A OR B\" choices the first option in the "
      "order MIT, Apache-2.0, BSD, ISC, Zlib, ... is elected).")
    w("")
    w("| License | Rust crates | Dart packages | Other (SDK, native, assets) | Total |")
    w("|---|---:|---:|---:|---:|")
    for lic, (a, b_, o) in sorted(counts.items(), key=lambda kv: (-sum(kv[1]), kv[0])):
        w("| %s | %d | %d | %d | %d |" % (md_cell(lic), a, b_, o, a + b_ + o))
    tot = [sum(v[i] for v in counts.values()) for i in range(3)]
    w("| **Total** | **%d** | **%d** | **%d** | **%d** |" % (tot[0], tot[1], tot[2], sum(tot)))
    w("")

    # main components
    w("## Main components")
    w("")
    w("| Component | License | Notes |")
    w("|---|---|---|")
    w("| Rust crates (%d, the Lumora core) | mostly MIT / Apache-2.0 | see \"Rust crates\" below |" % len(rust))
    w("| Flutter framework %s | BSD-3-Clause | Copyright 2014 The Flutter Authors |" % sdk_ver.get("Flutter", ""))
    w("| Flutter engine incl. Skia, Impeller, HarfBuzz, ICU, FreeType, BoringSSL, zlib, ... | BSD-3-Clause "
      "(Skia, Impeller, engine) + per-component licenses | %d components; full texts in the app "
      "(Settings > About > Open-source licenses) |" % len(engine))
    w("| Dart SDK %s | BSD-3-Clause | Copyright 2012 the Dart project authors |" % sdk_ver.get("Dart", ""))
    for b in bundled:
        if b["kind"] in ("bundled", "runtime-lib") and b["license"] not in ("NOASSERTION",):
            if any(k in b["name"] for k in ("Noto", "Phosphor", "PDFium", "Be Vietnam", "Material Icons")):
                w("| %s%s | %s | %s |" % (md_cell(b["name"]), (" " + b["version"]) if b.get("version") else "",
                                          md_cell(b["license"]), md_cell(b.get("platforms", ""))))
    for n in native:
        w("| %s (in crate %s %s) | %s | |" % (md_cell(n["component"]), n["crate"], n["version"], n["license"]))
    for name, lic, label in (("rustls", None, "rustls (TLS)"), ("quinn", None, "quinn (QUIC)"),
                             ("vodozemac", None, "vodozemac (Olm/Megolm crypto)"),
                             ("tokio", None, "tokio"), ("mainline", None, "mainline (BitTorrent DHT)"),
                             ("nnnoiseless", None, "nnnoiseless (RNNoise port)"),
                             ("cpal", None, "cpal (audio I/O)")):
        c = by_name.get(name)
        if c:
            w("| %s %s | %s | |" % (label, c["version"], md_cell(c["expr"])))
    for name in ("pdfrx", "flutter_map", "lottie", "just_audio", "record", "file_picker"):
        p = next((x for x in dart if x["name"] == name), None)
        if p:
            w("| %s %s (Dart) | %s | |" % (name, p["version"], md_cell(p["lic"])))
    w("")

    # copyleft
    w("## Copyleft and other attention items")
    w("")
    if copyleft:
        w("| Ecosystem | Component | Elected license | Declared |")
        w("|---|---|---|---|")
        for eco, comp, cl, decl in copyleft:
            w("| %s | %s | %s | %s |" % (eco, comp, cl, md_cell(decl)))
        w("")
        w("MPL-2.0 is file-level copyleft: the binary may be distributed under any terms, but recipients "
          "must be told where the MPL-covered source code can be obtained (the unmodified sources are on "
          "crates.io / pub.dev - the links in the tables satisfy this as long as Lumora does not modify "
          "those files) and the MPL notice must not be removed.")
    else:
        w("No component is used under a copyleft license.")
    w("")
    if libdbus:
        w("libdbus-sys is used with features `%s`: it links the system libdbus dynamically (the "
          "`vendored` feature, which would statically link libdbus under AFL-2.1 OR GPL-2.0-or-later, "
          "must stay off)." % ", ".join(sorted(crates_feature(crates, "libdbus-sys"))))
        w("")
    w("See also \"Notes\" at the end (video codecs, proprietary runtime pieces).")
    w("")

    # ---------------- Rust section
    w("## Rust crates")
    w("")
    w("Grouped by the license expression declared in each crate's Cargo.toml. \"Copyright\" shows "
      "the copyright line(s) found in the crate's packaged license file (or its authors when the "
      "crate packages none). The full license texts follow in \"License texts\".")
    w("")
    groups = collections.defaultdict(list)
    for c in rust:
        groups[c["expr"]].append(c)
    for expr in sorted(groups, key=lambda e: (-len(groups[e]), e)):
        cs = groups[expr]
        el = sorted({" AND ".join(sorted(c["elected"])) for c in cs})
        w("### %s (%d)" % (expr, len(cs)))
        w("")
        w("Used under: %s" % ", ".join(el))
        w("")
        w("| Crate | Version | Repository | Copyright |")
        w("|---|---|---|---|")
        for c in cs:
            w("| %s | %s | %s | %s |" % (c["name"], c["version"], md_cell(c["repo"]), md_cell(c["attr"])))
        w("")

    w("### Native (C/C++) code compiled into the Rust core")
    w("")
    for n in native:
        w("#### %s" % n["component"])
        w("")
        w("- Crate: `%s` %s - license: %s" % (n["crate"], n["version"], n["license"]))
        if n.get("note"):
            w("- Note: %s" % n["note"])
        w("")
        for rel, t in n["found"]:
            w("<details><summary>%s/%s</summary>" % (n["crate"], rel))
            w("")
            w(fence(t))
            w("")
            w("</details>")
            w("")

    if notices:
        w("### NOTICE files (reproduced verbatim, as required by Apache-2.0 section 4(d))")
        w("")
        seen_n = {}
        for owner, base, t in notices:
            k = norm(t)
            if k in seen_n:
                w("- **%s** `%s`: identical to the NOTICE of %s." % (owner, base, seen_n[k]))
                continue
            seen_n[k] = owner
            w("#### %s - %s" % (owner, base))
            w("")
            w(fence(t))
            w("")

    # ---------------- Flutter / Dart
    w("## Flutter, Dart SDK and Dart packages")
    w("")
    w("### Flutter SDK %s and Dart SDK %s" % (sdk_ver.get("Flutter", "?"), sdk_ver.get("Dart", "?")))
    w("")
    w("- Flutter framework: BSD-3-Clause (text below).")
    w("- Dart SDK / runtime: BSD-3-Clause (text below).")
    w("- Flutter engine (compiled into `libflutter`/`flutter_windows.dll`/`Flutter.framework`, "
      "including `icudtl.dat`): Skia, Impeller and the engine are BSD-3-Clause; the engine also "
      "contains the components below under their own licenses (BSD, MIT, Apache-2.0, ICU/Unicode, "
      "FreeType FTL, zlib, libpng, MPL-2.0 root-certificate data, ...). Their complete texts are in "
      "`<flutter>/bin/cache/pkg/sky_engine/LICENSE` and every Lumora build displays them at runtime "
      "(Settings > About > Open-source licenses, Flutter's `showLicensePage`).")
    w("")
    w("Engine components: " + ", ".join(engine))
    w("")
    if flutter_license:
        w("#### Flutter LICENSE")
        w("")
        w(fence(flutter_license))
        w("")
    if dart_sdk_license:
        w("#### Dart SDK LICENSE")
        w("")
        w(fence(dart_sdk_license))
        w("")
    w("### Dart packages (%d, non-dev, transitive)" % len(dart))
    w("")
    w("| Package | Version | License (detected) | Repository | Copyright | Text |")
    w("|---|---|---|---|---|---|")
    for p in dart:
        w("| %s | %s | %s | %s | %s | %s |" % (p["name"], p["version"], md_cell(p["lic"]), md_cell(p["repo"]),
                                               md_cell(p["attr"]), ("[D-%s](#d-%s)" % (p["hash"], p["hash"])) if p["hash"] else "-"))
    w("")
    w("#### Dart package license texts (identical texts merged)")
    w("")
    for h, e in dart_texts.items():
        w('<a id="d-%s"></a>' % h)
        w("")
        w("##### D-%s - %s" % (h, " AND ".join(e["ids"]) or "UNRECOGNISED"))
        w("")
        w("Used by: " + ", ".join(e["pkgs"]))
        w("")
        w(fence(e["text"]))
        w("")

    # ---------------- bundled
    w("## Bundled assets, prebuilt libraries and tools")
    w("")
    w("These are not described by cargo or pub; the list is maintained by hand in the generator "
      "script and each entry was checked against files in the repository at generation time.")
    w("")
    kinds = [("bundled", "Bundled in the app"), ("runtime-lib", "Prebuilt runtime libraries shipped with the app"),
             ("build-tool", "Installer tooling"), ("service", "Online services used at runtime (nothing bundled)"),
             ("not-distributed", "Linked but not distributed")]
    for kind, title in kinds:
        items = [b for b in bundled if b["kind"] == kind]
        if not items:
            continue
        w("### " + title)
        w("")
        for b in items:
            w("#### %s%s" % (b["name"], (" (" + b["version"] + ")") if b.get("version") else ""))
            w("")
            w("- License: %s" % b["license"])
            w("- Platforms: %s" % b.get("platforms", ""))
            if b.get("attribution"):
                w("- Attribution: %s" % b["attribution"])
            if b.get("review"):
                w("- **Review:** %s" % b["review"])
            if b.get("text"):
                if b["license"] in texts and norm(b["text"]) == norm(texts[b["license"]]):
                    w("- License text: see %s under \"License texts\"." % b["license"])
                else:
                    w("")
                    w("<details><summary>License text</summary>")
                    w("")
                    w(fence(b["text"]))
                    w("")
                    w("</details>")
            elif b.get("text_id"):
                w("- License text: see %s under \"License texts\"." % b["text_id"])
            w("")

    # ---------------- license texts
    w("## License texts")
    w("")
    w("One copy of each license text. Copyright lines were removed from these canonical copies; "
      "each component's own copyright notice is listed in the tables above.")
    w("")
    shown = sorted(set(texts) & (needed | {"CC-BY-4.0", "OFL-1.1", "Unicode-3.0", "MIT", "Apache-2.0",
                                           "BSD-3-Clause", "BSD-2-Clause"}
                                 | {i for p in dart for i in p["ids"]}))
    for lid in shown:
        w("### %s" % lid)
        w("")
        w(fence(texts[lid]))
        w("")

    # ---------------- notes (public, neutral facts only)
    codec = ("Lumora ships no H.264 implementation of its own and downloads nothing at run time. "
             "H.264 is used only through the operating system's codec (Android MediaCodec, Apple "
             "VideoToolbox, Windows Media Foundation, VA-API on Linux), whose patent licensing is the OS "
             "vendor's. The always-available codec is libvpx VP8/VP9 (BSD-3-Clause + Google's "
             "royalty-free patent grant). Release builds contain no OpenH264.")
    w("## Notes")
    w("")
    w("- **Video codecs.** " + codec)
    w("- **PDFium.** The prebuilt PDFium library also contains FreeType, libjpeg-turbo, libpng, zlib, "
      "Little CMS and OpenJPEG under their own permissive licenses.")
    w("- **Android.** The APK contains Google Play services Location (proprietary, Google's terms), "
      "used for sharing your location.")
    w("- **Maps.** Map tiles are loaded at run time from OpenStreetMap (data (c) OpenStreetMap "
      "contributors, ODbL-1.0); nothing is bundled.")
    major = [r for r in review if not r[0].endswith("(minor)")]
    minor = [r for r in review if r[0].endswith("(minor)")]
    if minor:
        w("")
        w("Crates that publish no license file are listed under their declared license, with "
          "attribution taken from their Cargo.toml authors: " + ", ".join("`%s`" % r[1] for r in minor) + ".")
    w("")

    # ---------------- internal review file (never published)
    R = []
    r = R.append
    r("# Third-party review items - INTERNAL, never publish")
    r("")
    r("Written by `%s` on %s together with THIRD_PARTY_NOTICES.md. The release job publishes only "
      "LICENSE.md and THIRD_PARTY_NOTICES.md; keep this file out of the public repo." % (cmdline, today))
    r("")
    r("- **Video codecs / patents.** " + codec + " A source-built OpenH264 exists only behind the "
      "dev/test cargo feature `openh264-source`; CI fails if it appears in a release dependency graph. "
      "Confirm this position with counsel before relying on it where H.264 patents are in force.")
    for area, item, why in major:
        r("- **%s - %s:** %s" % (area, item, why))
    if minor:
        r("")
        r("Crates that publish no license file (low risk; ideally fetch a copyright line from their "
          "repositories): " + ", ".join("`%s`" % x[1] for x in minor))
    r("")
    with open(args.review_out, "w", encoding="utf-8") as f:
        f.write("\n".join(R))

    out = "\n".join(L) + "\n"
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(out)
    log("wrote %s (%d bytes): %d Rust crates, %d Dart packages, %d bundled entries, %d review items"
        % (args.out, len(out), len(rust), len(dart), len(bundled), len(review)))
    log("license counts:")
    for lic, v in sorted(counts.items(), key=lambda kv: -sum(kv[1])):
        log("  %-45s rust=%d dart=%d other=%d" % (lic, *v))
    return 0


def crates_feature(crates, name):
    feats = set()
    for p in crates.values():
        if p["name"] == name:
            feats |= set(p.get("_features", []))
    return feats or {"default"}


if __name__ == "__main__":
    sys.exit(main())

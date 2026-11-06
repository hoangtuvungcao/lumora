// Colour emoji everywhere, the same on every desktop.
//
// * Android, iOS, macOS: the system emoji font (Noto Color Emoji / Apple Color
//   Emoji) is always there - nothing to do, nothing bundled.
// * Windows: Segoe UI Emoji has no flags (🇻🇳 shows as "VN") and Windows 10 lacks
//   everything after Emoji 12, so we always use the bundled Noto Color Emoji.
// * Linux: use the system font when fontconfig has a colour emoji font that
//   covers Emoji 15 (most distros ship Noto Color Emoji); otherwise (minimal
//   installs, old distros: boxes instead of emoji) load the bundled one.
//
// The bundled font is Noto Color Emoji in COLRv1 (vector, 4.8 MB, SIL OFL 1.1),
// which Flutter's Skia text stack renders in colour on desktop. It is installed
// next to the executable (data/fonts/, see linux|windows/CMakeLists.txt), not as
// a Flutter asset, so phone packages don't carry it.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Family name the theme lists first in `fontFamilyFallback`.
const kBundledEmojiFamily = 'NotoColorEmoji';

/// What [loadEmojiFallbackFont] decided (diagnostics).
String emojiFontSource = 'system';

/// Loads the bundled colour emoji font when this desktop needs it. Safe to
/// call without awaiting: text re-lays out when the font arrives.
Future<void> loadEmojiFallbackFont() async {
  if (kIsWeb || !(Platform.isLinux || Platform.isWindows)) return;
  try {
    final dir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    final f = File('$dir${sep}data${sep}fonts${sep}NotoColorEmoji-COLRv1.ttf');
    if (!await f.exists()) return;
    if (Platform.isLinux && await _linuxHasColorEmoji()) return;
    final bytes = await f.readAsBytes();
    final loader = FontLoader(kBundledEmojiFamily)..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    emojiFontSource = 'bundled';
  } catch (_) {
    // Fall back to whatever the system has.
  }
}

/// fontconfig knows a colour font with U+1FAE8 (shaking face, Emoji 15.0).
Future<bool> _linuxHasColorEmoji() async {
  try {
    final r = await Process.run('fc-list', [':charset=1fae8:color=true', 'family']).timeout(const Duration(seconds: 2));
    return r.exitCode == 0 && (r.stdout as String).trim().isNotEmpty;
  } catch (_) {
    return false; // no fontconfig tools: assume nothing usable
  }
}

/// Adds the emoji assets' licences to Settings > About > Open-source licenses
/// (Flutter's license page).
void registerEmojiLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['Noto Animated Emoji'], '''
Animated emoji: Noto Animated Emoji, copyright Google LLC.
https://googlefonts.github.io/noto-emoji-animation/

Licensed under the Creative Commons Attribution 4.0 International License (CC BY 4.0).
https://creativecommons.org/licenses/by/4.0/legalcode

Changes: a selection of about 120 animations, re-encoded (numbers rounded to 3 decimals, minified, gzip-compressed).''');
    yield const LicenseEntryWithLineBreaks(['Noto Color Emoji'], '''
Noto Color Emoji font (COLRv1), copyright 2013 Google LLC. Bundled with the Windows and Linux apps only.
https://github.com/googlefonts/noto-emoji

This Font Software is licensed under the SIL Open Font License, Version 1.1.
https://openfontlicense.org''');
    yield const LicenseEntryWithLineBreaks(['Unicode emoji data, CLDR', 'emojibase-data'], '''
Emoji list and order: Unicode emoji-test.txt (Emoji 15.1). Vietnamese names and keywords: Unicode CLDR 45.
Copyright (c) Unicode, Inc. Licensed under the Unicode License v3. https://www.unicode.org/license.txt

English keywords and shortcodes: emojibase-data 15.3, copyright (c) Miles Johnson. MIT License.''');
  });
}

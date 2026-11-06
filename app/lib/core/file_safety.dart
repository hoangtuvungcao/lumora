// Received files and pictures come from other people: names may hide the
// real type ("photo" + U+202E + "gpj.exe" shows as "photoexe.jpg"), programs must never
// start without a clear warning, and pictures are checked for absurd sizes
// before decoding (a tiny file can declare a 30 000 × 30 000 picture and
// exhaust memory: "decompression bomb").

import 'dart:io';
import 'dart:typed_data';

/// Bidi controls and invisible characters that can disguise a file name.
final RegExp _invisible = RegExp('[\u0000-\u001F\u007F\u00AD\u061C\u115F\u1160\u180E\u200B-\u200F\u202A-\u202E\u2060-\u206F\u3164\uFE00-\uFE0F\uFEFF\uFFA0\uFFF9-\uFFFB]');

/// File name safe to show: no direction overrides / invisible characters.
String safeDisplayName(String name) => name.replaceAll(_invisible, '');

/// Extensions that run code or open in a browser / installer when opened.
const Set<String> kDangerousExtensions = {
  // Windows programs, scripts, shortcuts, installers
  'exe', 'com', 'scr', 'pif', 'cpl', 'msi', 'msp', 'msix', 'appx', 'appxbundle', 'bat', 'cmd', 'ps1', 'psm1', 'psd1',
  'vbs', 'vbe', 'js', 'jse', 'wsf', 'wsh', 'hta', 'lnk', 'url', 'reg', 'inf', 'scf', 'gadget', 'application', 'msc',
  'chm', 'dll', 'sys', 'drv', 'ocx', 'library-ms', 'settingcontent-ms', 'xll', 'xlam', 'docm', 'xlsm', 'pptm',
  // web pages / active images (script runs in a browser)
  'html', 'htm', 'xhtml', 'shtml', 'mht', 'mhtml', 'svg', 'svgz', 'xml', 'xsl',
  // cross-platform
  'jar', 'jnlp', 'py', 'pyw', 'pyc', 'rb', 'pl', 'php', 'lua',
  // Linux / macOS
  'sh', 'bash', 'zsh', 'csh', 'ksh', 'fish', 'run', 'bin', 'desktop', 'appimage', 'deb', 'rpm', 'snap', 'flatpak',
  'flatpakref', 'dmg', 'pkg', 'mpkg', 'app', 'command', 'tool', 'workflow', 'scpt', 'applescript', 'terminal',
  'webloc', 'action', 'kext',
  // Android
  'apk', 'apks', 'xapk', 'aab',
  // disk images (auto-mount, can carry autorun / programs)
  'iso', 'img', 'vhd', 'vhdx',
};

/// True when opening [name] could run a program or script.
bool isDangerousFileName(String name) {
  // Windows ignores trailing dots and spaces: "evil.exe ." is "evil.exe".
  final n = safeDisplayName(name).trim().replaceAll(RegExp(r'[.\s]+$'), '').toLowerCase();
  final i = n.lastIndexOf('.');
  if (i <= 0 || i == n.length - 1) return false;
  return kDangerousExtensions.contains(n.substring(i + 1));
}

// ------------------------------------------------------------------ images

/// Largest picture side / area we agree to decode.
const int kMaxImageSide = 12000;
const int kMaxImagePixels = 50 * 1000 * 1000;

/// Width and height from the file header (PNG, JPEG, GIF, WebP, BMP), or
/// null when the format is not recognised.
(int, int)? imageDimensions(Uint8List b) {
  int u16be(int o) => (b[o] << 8) | b[o + 1];
  int u16le(int o) => b[o] | (b[o + 1] << 8);
  int u32be(int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
  int u32le(int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
  final n = b.length;
  // PNG: signature, IHDR first
  if (n >= 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return (u32be(16), u32be(20));
  }
  // GIF: logical screen size
  if (n >= 10 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return (u16le(6), u16le(8));
  }
  // BMP
  if (n >= 26 && b[0] == 0x42 && b[1] == 0x4D) {
    final w = u32le(18).toSigned(32).abs();
    final h = u32le(22).toSigned(32).abs();
    return (w, h);
  }
  // WebP: RIFF....WEBP + VP8 / VP8L / VP8X
  if (n >= 30 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
    final tag = String.fromCharCodes(b.sublist(12, 16));
    switch (tag) {
      case 'VP8 ':
        return (u16le(26) & 0x3FFF, u16le(28) & 0x3FFF);
      case 'VP8L':
        final v = u32le(21);
        return ((v & 0x3FFF) + 1, ((v >> 14) & 0x3FFF) + 1);
      case 'VP8X':
        return ((b[24] | (b[25] << 8) | (b[26] << 16)) + 1, (b[27] | (b[28] << 8) | (b[29] << 16)) + 1);
    }
    return null;
  }
  // JPEG: walk the markers up to the first SOFn
  if (n >= 4 && b[0] == 0xFF && b[1] == 0xD8) {
    var o = 2;
    while (o + 9 < n) {
      if (b[o] != 0xFF) return null;
      final m = b[o + 1];
      if (m == 0xFF) {
        o++;
        continue;
      }
      if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) {
        o += 2;
        continue;
      }
      final len = u16be(o + 2);
      if (len < 2) return null;
      final sof = m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC;
      if (sof) return (u16be(o + 7), u16be(o + 5));
      o += 2 + len;
    }
    return null;
  }
  return null;
}

/// True when [bytes] is a picture of sane size. Unknown formats are refused
/// unless [allowUnknown] (e.g. platform formats like HEIC for own files).
bool isSafeImageBytes(Uint8List bytes, {bool allowUnknown = false}) {
  final d = imageDimensions(bytes);
  if (d == null) return allowUnknown;
  final (w, h) = d;
  return w > 0 && h > 0 && w <= kMaxImageSide && h <= kMaxImageSide && w * h <= kMaxImagePixels;
}

final Map<String, bool> _fileVerdicts = {};

/// Header check for a picture on disk (first 1 MB, cached per path). A JPEG
/// whose size marker is pushed past that window by padding is refused.
bool isSafeImageFile(String path) {
  final hit = _fileVerdicts[path];
  if (hit != null) return hit;
  var ok = true;
  try {
    final f = File(path).openSync();
    try {
      final head = f.readSync(1 << 20);
      final jpeg = head.length >= 2 && head[0] == 0xFF && head[1] == 0xD8;
      ok = jpeg && imageDimensions(head) == null ? false : isSafeImageBytes(head, allowUnknown: true);
    } finally {
      f.closeSync();
    }
  } catch (_) {
    ok = true; // missing / unreadable: the image widget shows its error state
  }
  if (_fileVerdicts.length > 2000) _fileVerdicts.clear();
  return _fileVerdicts[path] = ok;
}

// ------------------------------------------------------------ saving files

const Set<String> _windowsDevices = {'CON', 'PRN', 'AUX', 'NUL', 'CONIN\$', 'CONOUT\$', 'CLOCK\$'};

bool _isWindowsDevice(String name) {
  final stem = name.split('.').first.replaceAll(RegExp(r' +$'), '').toUpperCase();
  if (_windowsDevices.contains(stem)) return true;
  final runes = stem.runes.toList();
  return (stem.startsWith('COM') || stem.startsWith('LPT')) &&
      runes.length == 4 &&
      RegExp(r'[0-9¹²³]').hasMatch(String.fromCharCode(runes.last));
}

/// A file name from another person → one harmless path component. Same rules
/// as the core's `files::sanitize`: no folders (`../`, `C:\`, UNC), no control
/// / invisible / bidi characters, none of `:*?"<>|`, no leading or trailing
/// dots and spaces, no Windows device names, at most 200 bytes (extension kept).
String sanitizeFileName(String name) {
  final parts = name.split(RegExp(r'[/\\]'));
  var s = parts.last.replaceAll(_invisible, '').replaceAll(RegExp(r'[:*?"<>|\u0080-\u009F]'), '');
  s = s.replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  const maxBytes = 200;
  if (utf8Length(s) > maxBytes) {
    final i = s.lastIndexOf('.');
    final ext = i > 0 && utf8Length(s.substring(i)) <= 16 ? s.substring(i) : '';
    final stem = StringBuffer();
    var used = utf8Length(ext);
    for (final r in s.substring(0, s.length - ext.length).runes) {
      final c = String.fromCharCode(r);
      if (used + utf8Length(c) > maxBytes) break;
      used += utf8Length(c);
      stem.write(c);
    }
    s = '${stem.toString().replaceAll(RegExp(r'[. ]+$'), '')}$ext';
  }
  if (s.isEmpty) return 'file';
  if (_isWindowsDevice(s)) s = '_$s';
  return s;
}

int utf8Length(String s) {
  var n = 0;
  for (final r in s.runes) {
    n += r < 0x80 ? 1 : (r < 0x800 ? 2 : (r < 0x10000 ? 3 : 4));
  }
  return n;
}

/// The name to save a received file under: the name of the file the core
/// actually wrote (already cleaned) when there is one, else the cleaned
/// [declared] name from the message.
String saveNameFor(String declared, {String? path}) {
  if (path != null && path.isNotEmpty && !path.startsWith('asset:')) {
    final base = path.split(RegExp(r'[/\\]')).last;
    if (base.isNotEmpty) return sanitizeFileName(base);
  }
  return sanitizeFileName(declared);
}

/// Creates a new, empty file `dir/name` — or `name (1)`, `name (2)`… — and
/// returns it. Never reuses an existing file (created exclusively, so a file
/// that appears meanwhile isn't overwritten either). [name] is cleaned first.
File createUniqueFile(String dir, String name) {
  final clean = sanitizeFileName(name);
  final dot = clean.lastIndexOf('.');
  final stem = dot > 0 ? clean.substring(0, dot) : clean;
  final ext = dot > 0 ? clean.substring(dot) : '';
  final sep = Platform.pathSeparator;
  for (var i = 0; i < 10000; i++) {
    final p = i == 0 ? '$dir$sep$clean' : '$dir$sep$stem ($i)$ext';
    final f = File(p);
    try {
      if (FileSystemEntity.typeSync(p, followLinks: false) != FileSystemEntityType.notFound) continue;
      f.createSync(exclusive: true);
      return f;
    } on FileSystemException {
      continue; // created by someone else meanwhile
    }
  }
  throw const FileSystemException('no free file name');
}

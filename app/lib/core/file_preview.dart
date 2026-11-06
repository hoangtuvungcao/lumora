// Previews of non-media files shown before download ("xem trước khi tải"):
// the first page of a PDF and the first lines of a text/code file.
//
// The sender's app makes them (it has the file and can render PDFs) and passes
// them to `send_file`; the core carries them inside the file message (see
// core/crates/lumora-core/src/file_preview.rs) and every receiver validates
// them again. Rules here mirror the core so both sides agree.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Text the sender includes (≈ the first 40–60 lines of code).
const kSnippetBytes = 2 * 1024;

/// Receiver caps (same as the core).
const kMaxPreviewText = 4 * 1024;
const kMaxPreviewImage = 64 * 1024;

/// What the sender aims for, so the whole message still fits one 64 KB
/// relay-mailbox frame for offline delivery.
const kTargetPreviewImage = 44 * 1024;

/// Line counting reads at most this much (bigger files report 0 = unknown).
const _maxCountBytes = 64 << 20;

/// Extensions previewed as text/code (mirrors core `TEXT_EXTS`). HTML and SVG
/// are text too: they are never rendered.
const kTextPreviewExts = {
  'txt', 'md', 'markdown', 'py', 'js', 'mjs', 'cjs', 'ts', 'tsx', 'jsx', 'dart', 'rs', 'go', 'java', 'kt', 'kts', //
  'swift', 'c', 'cc', 'cpp', 'cxx', 'h', 'hh', 'hpp', 'cs', 'rb', 'php', 'lua', 'json', 'yaml', 'yml', 'xml', 'html', //
  'htm', 'css', 'scss', 'csv', 'tsv', 'log', 'sh', 'bash', 'zsh', 'ps1', 'bat', 'sql', 'ini', 'toml', 'cfg', 'conf', //
  'env', 'gradle', 'properties', 'svg', 'tex', 'srt', 'vtt',
};
const _bareTextNames = {'makefile', 'dockerfile', 'readme', 'license'};

String _ext(String name) {
  final n = name.toLowerCase();
  final i = n.lastIndexOf('.');
  return i < 0 || i == n.length - 1 ? '' : n.substring(i + 1);
}

bool isTextPreviewable(String name) {
  final ext = _ext(name);
  if (ext.isEmpty) return _bareTextNames.contains(name.toLowerCase());
  return kTextPreviewExts.contains(ext);
}

bool isPdfName(String name) => _ext(name) == 'pdf';

/// Preview fields of a file message (`body.preview`).
@immutable
class FilePreview {
  const FilePreview({this.kind = '', this.text = '', this.pages = 0, this.lines = 0});

  /// "pdf" | "text" | … (unknown kinds are drawn from what is present).
  final String kind;
  final String text;
  final int pages;
  final int lines;

  bool get isEmpty => text.isEmpty && pages == 0 && lines == 0;

  /// Parses and re-sanitises (a peer could send anything).
  static FilePreview? fromJson(Object? j) {
    if (j is! Map) return null;
    int n(Object? v) => v is num ? math.max(0, v.toInt()) : 0;
    final p = FilePreview(
      kind: (j['kind']?.toString() ?? '').toLowerCase(),
      text: sanitizePreviewText(j['text']?.toString() ?? '', kMaxPreviewText),
      pages: n(j['pages']),
      lines: n(j['lines']),
    );
    return p.isEmpty && p.kind.isEmpty ? null : p;
  }

  Map<String, dynamic> toJson() => {'kind': kind, if (text.isNotEmpty) 'text': text, if (pages > 0) 'pages': pages, if (lines > 0) 'lines': lines};

  @override
  bool operator ==(Object other) => other is FilePreview && other.kind == kind && other.text == text && other.pages == pages && other.lines == lines;
  @override
  int get hashCode => Object.hash(kind, text, pages, lines);
}

/// Everything the sender passes to `send_file`.
class LocalPreview {
  const LocalPreview({this.preview, this.image, this.width = 0, this.height = 0});
  final FilePreview? preview;

  /// JPEG of the first page (PDF).
  final Uint8List? image;
  final int width;
  final int height;
}

// ------------------------------------------------------------------ text

bool _isBidiControl(int c) => (c >= 0x202A && c <= 0x202E) || (c >= 0x2066 && c <= 0x2069) || c == 0x200E || c == 0x200F || c == 0x061C;

/// CRLF/CR → LF, drops control characters except `\n` and `\t` (and bidi
/// overrides / BOM), cuts to at most [maxBytes] of UTF-8 on a character boundary.
String sanitizePreviewText(String s, [int maxBytes = kMaxPreviewText]) {
  final out = StringBuffer();
  var bytes = 0;
  final runes = s.runes.toList();
  for (var i = 0; i < runes.length; i++) {
    var c = runes[i];
    if (c == 0x0D) {
      if (i + 1 < runes.length && runes[i + 1] == 0x0A) continue;
      c = 0x0A;
    } else if (c != 0x0A && c != 0x09 && (c < 0x20 || (c >= 0x7F && c <= 0x9F) || _isBidiControl(c) || c == 0xFEFF)) {
      continue;
    }
    final len = c < 0x80 ? 1 : (c < 0x800 ? 2 : (c < 0x10000 ? 3 : 4));
    if (bytes + len > maxBytes) break;
    bytes += len;
    out.writeCharCode(c);
  }
  return out.toString();
}

/// Largest index ≤ [end] that doesn't split a UTF-8 sequence of [b].
int _utf8Boundary(List<int> b, int end) {
  var i = math.min(end, b.length);
  while (i > 0 && i < b.length && (b[i] & 0xC0) == 0x80) {
    i--;
  }
  return i;
}

/// The first [maxBytes] of [head] as text, or null when it looks binary (NUL
/// bytes, invalid UTF-8, more than 2 % control characters) — e.g. a ZIP or a
/// photo renamed to `.txt`. The cut never splits a character and prefers a
/// line end in the second half of the window.
String? textSnippet(List<int> head, {int maxBytes = kSnippetBytes}) {
  var b = head;
  if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) b = b.sublist(3);
  if (b.contains(0)) return null;
  String s;
  try {
    s = const Utf8Decoder().convert(b);
  } on FormatException {
    // a character cut by the read window is fine, anything else is not UTF-8
    final cut = _utf8Boundary(b, b.length - 1);
    if (b.length - cut > 3 || cut == b.length) return null;
    try {
      s = const Utf8Decoder().convert(b, 0, cut);
    } on FormatException {
      return null;
    }
  }
  final runes = s.runes;
  var ctrl = 0;
  for (final c in runes) {
    if ((c < 0x20 && c != 0x0A && c != 0x0D && c != 0x09 && c != 0x0C && c != 0x1B) || (c >= 0x7F && c <= 0x9F)) ctrl++;
  }
  if (runes.isNotEmpty && ctrl * 50 > runes.length) return null;
  final enc = utf8.encode(s);
  if (enc.length <= maxBytes) return sanitizePreviewText(s, maxBytes);
  final end = _utf8Boundary(enc, maxBytes);
  var cut = utf8.decode(enc.sublist(0, end));
  final nl = cut.lastIndexOf('\n');
  if (nl >= 0 && utf8.encode(cut.substring(0, nl)).length >= end ~/ 2) cut = cut.substring(0, nl);
  return sanitizePreviewText(cut, maxBytes);
}

/// Lines in [path] (a last line without `\n` counts); null when unreadable or
/// bigger than 64 MB.
Future<int?> countLines(String path) async {
  try {
    final f = File(path);
    final len = await f.length();
    if (len > _maxCountBytes) return null;
    var lines = 0;
    var last = 0x0A;
    await for (final chunk in f.openRead()) {
      for (final b in chunk) {
        if (b == 0x0A) lines++;
      }
      if (chunk.isNotEmpty) last = chunk.last;
    }
    if (len > 0 && last != 0x0A) lines++;
    return lines;
  } catch (_) {
    return null;
  }
}

Future<Uint8List> _readHead(String path, int n) async {
  final raf = await File(path).open();
  try {
    return await raf.read(n);
  } finally {
    await raf.close();
  }
}

/// Text/code preview, or null for binary or unreadable files.
Future<LocalPreview?> textPreview(String path) async {
  final head = await _readHead(path, 8 * 1024);
  final text = textSnippet(head);
  if (text == null) return null;
  final lines = await countLines(path) ?? 0;
  if (text.isEmpty && lines == 0) return null;
  return LocalPreview(preview: FilePreview(kind: 'text', text: text, lines: lines));
}

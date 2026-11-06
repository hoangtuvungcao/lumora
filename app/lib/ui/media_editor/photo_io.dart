// Photo I/O for the editor: load a source (file or demo asset), export the
// edited composition (compressed JPEG ~2560px q85, or "original quality"),
// strip metadata (EXIF/GPS, XMP, IPTC, comments), and save to the device
// (gallery on Android/iOS, save dialog on desktop).

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../../l10n/strings.dart';
import '../chats/attachments.dart' show openFile;
import '../widgets/common.dart' show UserMessageException, showTechnicalDetails, showTopToast;
import 'edit_render.dart';
import 'edit_state.dart';
import 'heic.dart';

/// Long-side cap of the decoded working copy (memory bound: 4096² RGBA = 64 MB).
const kWorkingMaxSide = 4096;

/// "Compressed" sending: long side and JPEG quality.
const kCompressedMaxSide = 2560;
const kCompressedQuality = 85;
const kOriginalQuality = 95;

const _editableExt = ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif', 'heic', 'heif', 'hif'];

/// Photos the editor can open (GIFs stay animated; HEIC is decoded where the
/// platform can and sent as JPEG).
bool isEditablePhoto(String path) {
  final n = path.toLowerCase();
  return _editableExt.any((e) => n.endsWith('.$e'));
}

Future<Uint8List> readPhotoBytes(String path) async {
  if (path.startsWith('asset:')) {
    final d = await rootBundle.load(path.substring(6));
    return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
  }
  return File(path).readAsBytes();
}

/// Decodes [bytes] (EXIF orientation applied by the codec), long side capped.
Future<ui.Image> decodeWorkingImage(Uint8List bytes, {int maxSide = kWorkingMaxSide}) async {
  final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
  final codec = await ui.instantiateImageCodecWithSize(buf, getTargetSize: (w, h) {
    final long = math.max(w, h);
    if (long <= maxSide) return ui.TargetImageSize(width: w, height: h);
    return ui.TargetImageSize(width: (w * maxSide / long).round());
  });
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

enum PhotoFormat { jpeg, png, other }

PhotoFormat sniffFormat(Uint8List b) {
  if (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return PhotoFormat.jpeg;
  if (b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return PhotoFormat.png;
  return PhotoFormat.other;
}

// ------------------------------------------------------------------ metadata

/// EXIF orientation (1..8) of a JPEG, 1 if absent/unreadable.
int jpegOrientation(Uint8List b) {
  for (final seg in _jpegSegments(b)) {
    if (seg.marker != 0xE1) continue;
    final d = ByteData.sublistView(b, seg.start, seg.end);
    if (d.lengthInBytes < 14 || String.fromCharCodes(b.sublist(seg.start, seg.start + 4)) != 'Exif') continue;
    const tiff = 6;
    final le = d.getUint8(tiff) == 0x49;
    final endian = le ? Endian.little : Endian.big;
    final ifd = tiff + d.getUint32(tiff + 4, endian);
    if (ifd + 2 > d.lengthInBytes) return 1;
    final n = d.getUint16(ifd, endian);
    for (var i = 0; i < n; i++) {
      final e = ifd + 2 + i * 12;
      if (e + 12 > d.lengthInBytes) break;
      if (d.getUint16(e, endian) == 0x0112) return d.getUint16(e + 8, endian);
    }
  }
  return 1;
}

class _Seg {
  _Seg(this.marker, this.start, this.end, this.headerStart);
  final int marker;

  /// Payload (after the 2-byte length).
  final int start;
  final int end;
  final int headerStart;
}

/// APPn/COM/etc. segments up to (not including) SOS.
Iterable<_Seg> _jpegSegments(Uint8List b) sync* {
  var i = 2;
  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) return;
    final m = b[i + 1];
    if (m == 0xFF) {
      i++;
      continue;
    }
    if (m == 0xDA || m == 0xD9) return;
    final len = (b[i + 2] << 8) | b[i + 3];
    if (len < 2 || i + 2 + len > b.length) return;
    yield _Seg(m, i + 4, i + 2 + len, i);
    i += 2 + len;
  }
}

/// Lossless metadata removal. Returns null when it can't be done without
/// re-encoding (unknown format, or a JPEG whose EXIF orientation must be
/// baked into the pixels first).
Uint8List? stripMetadataLossless(Uint8List b) {
  switch (sniffFormat(b)) {
    case PhotoFormat.jpeg:
      if (jpegOrientation(b) != 1) return null;
      final out = BytesBuilder(copy: false)..add(const [0xFF, 0xD8]);
      var end = 2;
      for (final s in _jpegSegments(b)) {
        end = s.end;
        // Drop APP1 (EXIF/XMP: GPS, camera, thumbnails), APP13 (IPTC), COM.
        if (s.marker == 0xE1 || s.marker == 0xED || s.marker == 0xFE) continue;
        out.add(Uint8List.sublistView(b, s.headerStart, s.end));
      }
      out.add(Uint8List.sublistView(b, end));
      return out.takeBytes();
    case PhotoFormat.png:
      final out = BytesBuilder(copy: false)..add(Uint8List.sublistView(b, 0, 8));
      var i = 8;
      const drop = {'eXIf', 'tEXt', 'zTXt', 'iTXt', 'tIME'};
      while (i + 12 <= b.length) {
        final len = ByteData.sublistView(b, i, i + 4).getUint32(0);
        final type = String.fromCharCodes(b.sublist(i + 4, i + 8));
        final next = i + 12 + len;
        if (next > b.length) return null;
        if (!drop.contains(type)) out.add(Uint8List.sublistView(b, i, next));
        i = next;
        if (type == 'IEND') break;
      }
      return out.takeBytes();
    case PhotoFormat.other:
      return null;
  }
}

/// Metadata removal at the byte level for pictures that can't be decoded or
/// re-encoded here: like [stripMetadataLossless], but a JPEG always loses
/// its EXIF (its rotation flag too — better than sending where it was
/// taken), and WebP drops its EXIF/XMP chunks. Null: format not handled
/// (e.g. HEIC) — the caller must not send it as a photo without asking.
Uint8List? stripMetadataForced(Uint8List b) {
  switch (sniffFormat(b)) {
    case PhotoFormat.jpeg:
      final out = BytesBuilder(copy: false)..add(const [0xFF, 0xD8]);
      var end = 2;
      var any = false;
      for (final s in _jpegSegments(b)) {
        any = true;
        end = s.end;
        if (s.marker == 0xE1 || s.marker == 0xED || s.marker == 0xFE) continue;
        out.add(Uint8List.sublistView(b, s.headerStart, s.end));
      }
      if (!any) return null;
      out.add(Uint8List.sublistView(b, end));
      return out.takeBytes();
    case PhotoFormat.png:
      return stripMetadataLossless(b);
    case PhotoFormat.other:
      return _stripWebp(b);
  }
}

/// WebP (RIFF): drops `EXIF` / `XMP ` chunks and clears their VP8X flags.
Uint8List? _stripWebp(Uint8List b) {
  if (b.length < 20 || String.fromCharCodes(b.sublist(0, 4)) != 'RIFF' || String.fromCharCodes(b.sublist(8, 12)) != 'WEBP') return null;
  final out = BytesBuilder(copy: false);
  var i = 12;
  while (i + 8 <= b.length) {
    final type = String.fromCharCodes(b.sublist(i, i + 4));
    final len = ByteData.sublistView(b, i + 4, i + 8).getUint32(0, Endian.little);
    final next = i + 8 + len + (len & 1);
    if (next > b.length) return null;
    if (type == 'EXIF' || type == 'XMP ') {
      i = next;
      continue;
    }
    final chunk = Uint8List.fromList(b.sublist(i, next));
    if (type == 'VP8X' && chunk.length > 8) chunk[8] &= ~0x0C; // EXIF (0x08) + XMP (0x04) flags
    out.add(chunk);
    i = next;
  }
  final body = out.takeBytes();
  final head = ByteData(12)
    ..setUint32(0, 0x46464952, Endian.little) // "RIFF"
    ..setUint32(4, body.length + 4, Endian.little)
    ..setUint32(8, 0x50424557, Endian.little); // "WEBP"
  return Uint8List.fromList([...head.buffer.asUint8List(), ...body]);
}

/// Writes already-cleaned bytes of an undecodable picture for sending.
Future<File> writeOutgoingBytes(Uint8List bytes, String ext) => writeOutgoing(ExportedPhoto(bytes, ext, 0, 0));

/// True if the bytes carry an EXIF block (tests / diagnostics).
bool hasExif(Uint8List b) {
  if (sniffFormat(b) == PhotoFormat.jpeg) {
    return _jpegSegments(b).any((s) => s.marker == 0xE1 && s.end - s.start >= 4 && String.fromCharCodes(b.sublist(s.start, s.start + 4)) == 'Exif');
  }
  if (sniffFormat(b) == PhotoFormat.png) {
    for (var i = 8; i + 8 <= b.length - 4;) {
      final len = ByteData.sublistView(b, i, i + 4).getUint32(0);
      if (String.fromCharCodes(b.sublist(i + 4, i + 8)) == 'eXIf') return true;
      i += 12 + len;
    }
  }
  return false;
}

// ------------------------------------------------------------------ export

class ExportedPhoto {
  const ExportedPhoto(this.bytes, this.ext, this.width, this.height);
  final Uint8List bytes;

  /// 'jpg' or 'png'.
  final String ext;
  final int width;
  final int height;
}

Uint8List _encodeJpg((Uint8List, int, int, int) j) {
  final im = img.Image.fromBytes(width: j.$2, height: j.$3, bytes: j.$1.buffer, numChannels: 4);
  return img.encodeJpg(im, quality: j.$4);
}

/// Produces the bytes to send/save. Never carries EXIF/GPS:
///  * untouched photo, original quality (or already small JPEG) → the source
///    bytes with metadata removed losslessly;
///  * otherwise the composition is rendered and re-encoded (JPEG; PNG for
///    PNG sources in original quality to keep screenshots crisp).
Future<ExportedPhoto> exportPhoto({
  required Uint8List source,
  required EditorAssets assets,
  required EditState state,
  required bool original,
}) async {
  final fmt = sniffFormat(source);
  if (state.pristine) {
    final small = fmt == PhotoFormat.jpeg &&
        math.max(assets.image.width, assets.image.height) <= kCompressedMaxSide &&
        source.length <= 1536 * 1024;
    if (original || small) {
      final s = stripMetadataLossless(source);
      if (s != null) return ExportedPhoto(s, fmt == PhotoFormat.png ? 'png' : 'jpg', assets.image.width, assets.image.height);
    }
  }
  final png = original && fmt == PhotoFormat.png;
  final image = await renderComposition(
    assets,
    state,
    maxSide: original ? kWorkingMaxSide : kCompressedMaxSide,
    background: png ? null : Colors.white,
  );
  try {
    if (png) {
      final d = await image.toByteData(format: ui.ImageByteFormat.png);
      return ExportedPhoto(d!.buffer.asUint8List(), 'png', image.width, image.height);
    }
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final job = (raw!.buffer.asUint8List(), image.width, image.height, original ? kOriginalQuality : kCompressedQuality);
    // Small images encode faster inline than the isolate round-trip.
    final bytes = image.width * image.height < 400 * 400 ? _encodeJpg(job) : await compute(_encodeJpg, job);
    return ExportedPhoto(bytes, 'jpg', image.width, image.height);
  } finally {
    image.dispose();
  }
}

// ------------------------------------------------------------------ files

String _two(int v) => v.toString().padLeft(2, '0');

/// `Lumora_2026-11-05_1830.jpg`
String photoFileName(String ext, [DateTime? at]) {
  final t = at ?? DateTime.now();
  return 'Lumora_${t.year}-${_two(t.month)}-${_two(t.day)}_${_two(t.hour)}${_two(t.minute)}.$ext';
}

/// Where edited photos are written before `send_file`. The core keeps
/// serving the file from this path (peers download it later, the sender's
/// own bubble shows it), so it lives in app support, not a temp folder.
Future<Directory> outgoingPhotoDir() async {
  Directory base;
  try {
    base = await getApplicationSupportDirectory();
  } catch (_) {
    base = Directory.systemTemp; // tests / unsupported platform
  }
  final d = Directory('${base.path}${Platform.pathSeparator}edited_photos');
  await d.create(recursive: true);
  return d;
}

/// Writes [p] to a unique file for sending; caller deletes it if sending fails.
Future<File> writeOutgoing(ExportedPhoto p) async {
  final dir = await outgoingPhotoDir();
  final now = DateTime.now();
  final base = photoFileName(p.ext, now).replaceAll('.${p.ext}', '');
  var f = File('${dir.path}${Platform.pathSeparator}$base.${p.ext}');
  for (var i = 2; f.existsSync(); i++) {
    f = File('${dir.path}${Platform.pathSeparator}${base}_$i.${p.ext}');
  }
  await f.writeAsBytes(p.bytes, flush: true);
  return f;
}

// ------------------------------------------------------------------ save to device

const _media = MethodChannel('lumora/media');

/// Overridable for tests / screenshots.
@visibleForTesting
Future<String?> Function(Uint8List bytes, String name, String mime)? debugSavePhotoOverride;

String? _picturesDir() {
  final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
  if (home == null) return null;
  final sep = Platform.pathSeparator;
  if (Platform.isLinux) {
    // XDG user dirs (localised folder names, e.g. "Ảnh").
    try {
      final cfg = File('$home/.config/user-dirs.dirs').readAsStringSync();
      final m = RegExp(r'XDG_PICTURES_DIR="([^"]+)"').firstMatch(cfg);
      if (m != null) {
        final p = m.group(1)!.replaceAll(r'$HOME', home);
        if (Directory(p).existsSync()) return p;
      }
    } catch (_) {}
  }
  final p = '$home${sep}Pictures';
  return Directory(p).existsSync() ? p : null;
}

/// Saves [bytes] as a new photo. Mobile: the system gallery
/// (Pictures/Lumora on Android via MediaStore, Photos on iOS, add-only).
/// Desktop: a save dialog opened in Pictures (fallback Downloads).
/// Shows a confirmation toast; returns the saved location or null.
Future<String?> savePhotoToDevice(BuildContext context, Uint8List bytes, {required String ext}) async {
  final s = S.read(context);
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  final name = photoFileName(ext);
  final mime = switch (ext) {
    'png' => 'image/png',
    'gif' => 'image/gif',
    _ => 'image/jpeg',
  };
  void show(String text, {String? openPath}) => showTopToast(null, text,
      overlay: overlay,
      duration: const Duration(seconds: 3),
      actionLabel: openPath == null ? null : s('open'),
      onAction: openPath == null ? null : () => openFile(context, openPath));
  try {
    if (debugSavePhotoOverride != null) {
      final r = await debugSavePhotoOverride!(bytes, name, mime);
      if (r != null) show(s('pe_saved_gallery'));
      return r;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      final r = await _media.invokeMethod<String>('saveToGallery', {'bytes': bytes, 'name': name, 'mime': mime});
      if (r != null) show(s('pe_saved_gallery'));
      return r;
    }
    String? initial = _picturesDir();
    if (initial == null) {
      try {
        initial = (await getDownloadsDirectory())?.path;
      } catch (_) {}
    }
    final uri = await FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: mime, dialogTitle: s('pe_save_device'), initialDirectory: initial);
    if (uri == null) return null;
    final path = uri.isScheme('file') ? uri.toFilePath() : uri.toString();
    if (uri.isScheme('file')) {
      final f = File(path);
      if (!f.existsSync() || f.lengthSync() == 0) await f.writeAsBytes(bytes, flush: true);
    }
    if (context.mounted) show(s('saved_to', {'path': path}), openPath: uri.isScheme('file') ? path : null);
    return path;
  } catch (e) {
    debugPrint('Lumora: save photo: $e');
    showTopToast(null, s('pe_save_failed'),
        overlay: overlay,
        duration: const Duration(seconds: 5),
        actionLabel: s('technical_details'),
        onAction: () {
          if (context.mounted) showTechnicalDetails(context, '$e');
        });
    return null;
  }
}

/// Saves an existing (received/sent) photo file as-is, minus its metadata.
Future<String?> saveExistingPhotoToDevice(BuildContext context, String path) async {
  final s = S.read(context);
  final bytes = await readPhotoBytes(path);
  // GIFs carry no EXIF/GPS: keep the animation byte-for-byte.
  if (bytes.length > 4 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
    if (!context.mounted) return null;
    return savePhotoToDevice(context, bytes, ext: 'gif');
  }
  if (isHeicPath(path)) {
    final image = await decodeHeic(path, maxSide: 1 << 14);
    if (image == null) throw UserMessageException(s('pe_heic_unsupported'));
    final assets = EditorAssets.of(image);
    try {
      final e = await exportPhoto(source: bytes, assets: assets, state: const EditState(), original: true);
      if (!context.mounted) return null;
      return savePhotoToDevice(context, e.bytes, ext: e.ext);
    } finally {
      assets.dispose();
    }
  }
  final fmt = sniffFormat(bytes);
  var out = stripMetadataLossless(bytes);
  var ext = fmt == PhotoFormat.png ? 'png' : 'jpg';
  if (out == null) {
    // Orientation must be baked in (or unknown format): re-encode once, high quality.
    final image = await decodeWorkingImage(bytes, maxSide: 1 << 14);
    final assets = EditorAssets.of(image);
    try {
      final e = await exportPhoto(source: bytes, assets: assets, state: const EditState(), original: true);
      out = e.bytes;
      ext = e.ext;
    } finally {
      assets.dispose();
    }
  }
  if (!context.mounted) return null;
  return savePhotoToDevice(context, out, ext: ext);
}

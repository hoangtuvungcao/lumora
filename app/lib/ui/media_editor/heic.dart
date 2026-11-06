// HEIC / HEIF (iPhone photos) without bundling a decoder:
//
//  1. Flutter's own codec (Android 9+ decodes HEIF through the platform);
//  2. Linux: the system libheif (dlopen `libheif.so.1`, tiny FFI) or the
//     `heif-convert` tool when installed;
//  3. iOS / macOS (ImageIO), Android (ImageDecoder), Windows (WIC + the
//     "HEIF Image Extensions") through the `lumora/media.heicToJpeg` channel.
//
// Everything returns null instead of throwing; callers show a friendly
// fallback ("Mở bằng ứng dụng khác").

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

bool isHeicPath(String path) {
  final n = path.toLowerCase();
  return n.endsWith('.heic') || n.endsWith('.heif') || n.endsWith('.hif');
}

const _media = MethodChannel('lumora/media');

/// Decodes a HEIC/HEIF file (orientation applied), long side ≤ [maxSide].
/// Null when this device has no decoder for it.
Future<ui.Image?> decodeHeic(String path, {int maxSide = 4096}) async {
  Uint8List bytes;
  try {
    bytes = await File(path).readAsBytes();
  } catch (_) {
    return null;
  }
  // 1) Flutter's codec (succeeds where the engine delegates to the platform).
  try {
    return await _decodeEncoded(bytes, maxSide);
  } catch (_) {}
  // 2) Linux: system libheif / heif-convert.
  if (!kIsWeb && Platform.isLinux) {
    try {
      final raw = await Isolate.run(() => decodeWithLibheif(path));
      if (raw != null) return await _fromRgba(raw.$1, raw.$2, raw.$3, maxSide);
    } catch (_) {}
    try {
      final jpeg = await _heifConvert(path);
      if (jpeg != null) return await _decodeEncoded(jpeg, maxSide);
    } catch (_) {}
    return null;
  }
  // 3) Native converters.
  try {
    final jpeg = await _media.invokeMethod<Uint8List>('heicToJpeg', {'path': path, 'maxSide': maxSide});
    if (jpeg != null) return await _decodeEncoded(jpeg, maxSide);
  } catch (_) {}
  return null;
}

Future<ui.Image> _decodeEncoded(Uint8List bytes, int maxSide) async {
  final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
  final codec = await ui.instantiateImageCodecWithSize(buf, getTargetSize: (w, h) {
    final long = math.max(w, h);
    return long <= maxSide ? ui.TargetImageSize(width: w, height: h) : ui.TargetImageSize(width: (w * maxSide / long).round());
  });
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

Future<ui.Image> _fromRgba(Uint8List rgba, int w, int h, int maxSide) async {
  final buf = await ui.ImmutableBuffer.fromUint8List(rgba);
  final desc = ui.ImageDescriptor.raw(buf, width: w, height: h, pixelFormat: ui.PixelFormat.rgba8888);
  final long = math.max(w, h);
  final codec = await desc.instantiateCodec(targetWidth: long > maxSide ? (w * maxSide / long).round() : null, targetHeight: long > maxSide ? (h * maxSide / long).round() : null);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
    desc.dispose();
    buf.dispose();
  }
}

String? _whichHeifConvert() {
  for (final d in (Platform.environment['PATH'] ?? '/usr/bin:/usr/local/bin').split(':')) {
    final f = File('$d/heif-convert');
    if (d.isNotEmpty && f.existsSync()) return f.path;
  }
  return null;
}

Future<Uint8List?> _heifConvert(String path) async {
  final tool = _whichHeifConvert();
  if (tool == null) return null;
  final out = File('${Directory.systemTemp.path}${Platform.pathSeparator}lumora_heic_${DateTime.now().microsecondsSinceEpoch}.jpg');
  try {
    final r = await Process.run(tool, ['-q', '92', path, out.path]);
    if (r.exitCode != 0 || !out.existsSync()) return null;
    return await out.readAsBytes();
  } on ProcessException {
    return null; // not installed
  } finally {
    try {
      if (out.existsSync()) out.deleteSync();
    } catch (_) {}
  }
}

// ------------------------------------------------------------------ libheif FFI

final class _HeifError extends Struct {
  @Int32()
  external int code;
  @Int32()
  external int subcode;
  external Pointer<Utf8> message;
}

const _colorspaceRgb = 1; // heif_colorspace_RGB
const _chromaRgba = 11; // heif_chroma_interleaved_RGBA
const _channelInterleaved = 10; // heif_channel_interleaved

DynamicLibrary? _openLibheif() {
  for (final name in ['libheif.so.1', 'libheif.so']) {
    try {
      return DynamicLibrary.open(name);
    } catch (_) {}
  }
  return null;
}

/// True when the system libheif can be loaded (Linux).
bool get libheifAvailable => !kIsWeb && Platform.isLinux && _openLibheif() != null;

/// Decodes the primary image to straight RGBA with libheif (transforms such
/// as rotation applied). Runs synchronously — call it from an isolate.
(Uint8List, int, int)? decodeWithLibheif(String path) {
  final lib = _openLibheif();
  if (lib == null) return null;
  try {
    lib.lookupFunction<_HeifError Function(Pointer<Void>), _HeifError Function(Pointer<Void>)>('heif_init')(nullptr);
  } catch (_) {} // libheif < 1.13 has no heif_init
  final alloc = lib.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('heif_context_alloc');
  final free = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('heif_context_free');
  final read = lib.lookupFunction<_HeifError Function(Pointer<Void>, Pointer<Utf8>, Pointer<Void>), _HeifError Function(Pointer<Void>, Pointer<Utf8>, Pointer<Void>)>(
      'heif_context_read_from_file');
  final primary = lib.lookupFunction<_HeifError Function(Pointer<Void>, Pointer<Pointer<Void>>), _HeifError Function(Pointer<Void>, Pointer<Pointer<Void>>)>(
      'heif_context_get_primary_image_handle');
  final releaseHandle = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('heif_image_handle_release');
  final decode = lib.lookupFunction<_HeifError Function(Pointer<Void>, Pointer<Pointer<Void>>, Int32, Int32, Pointer<Void>),
      _HeifError Function(Pointer<Void>, Pointer<Pointer<Void>>, int, int, Pointer<Void>)>('heif_decode_image');
  final releaseImage = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('heif_image_release');
  final width = lib.lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('heif_image_get_width');
  final height = lib.lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('heif_image_get_height');
  final plane = lib.lookupFunction<Pointer<Uint8> Function(Pointer<Void>, Int32, Pointer<Int32>), Pointer<Uint8> Function(Pointer<Void>, int, Pointer<Int32>)>(
      'heif_image_get_plane_readonly');

  final ctx = alloc();
  if (ctx == nullptr) return null;
  final cPath = path.toNativeUtf8();
  final handleOut = calloc<Pointer<Void>>();
  final imageOut = calloc<Pointer<Void>>();
  final stride = calloc<Int32>();
  try {
    if (read(ctx, cPath, nullptr).code != 0) return null;
    if (primary(ctx, handleOut).code != 0) return null;
    final handle = handleOut.value;
    try {
      if (decode(handle, imageOut, _colorspaceRgb, _chromaRgba, nullptr).code != 0) return null;
      final image = imageOut.value;
      try {
        final w = width(image, _channelInterleaved), h = height(image, _channelInterleaved);
        final data = plane(image, _channelInterleaved, stride);
        if (w <= 0 || h <= 0 || data == nullptr) return null;
        final s = stride.value;
        final out = Uint8List(w * h * 4);
        final src = data.asTypedList(s * h);
        for (var y = 0; y < h; y++) {
          out.setRange(y * w * 4, (y + 1) * w * 4, src, y * s);
        }
        return (out, w, h);
      } finally {
        releaseImage(image);
      }
    } finally {
      releaseHandle(handle);
    }
  } finally {
    calloc.free(cPath);
    calloc.free(handleOut);
    calloc.free(imageOut);
    calloc.free(stride);
    free(ctx);
  }
}

// ------------------------------------------------------------------ image provider

/// [ImageProvider] for HEIC files (chat bubbles, viewer). Fails with an
/// error (→ the widget's errorBuilder / thumbnail) when undecodable.
@immutable
class HeicFileImage extends ImageProvider<HeicFileImage> {
  const HeicFileImage(this.path, {this.maxSide = 2560});
  final String path;
  final int maxSide;

  @override
  Future<HeicFileImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(HeicFileImage key, ImageDecoderCallback decode) => OneFrameImageStreamCompleter(_load());

  Future<ImageInfo> _load() async {
    final img = await decodeHeic(path, maxSide: maxSide);
    if (img == null) throw StateError('heic_unsupported');
    return ImageInfo(image: img);
  }

  @override
  bool operator ==(Object other) => other is HeicFileImage && other.path == path && other.maxSide == maxSide;

  @override
  int get hashCode => Object.hash(path, maxSide);
}

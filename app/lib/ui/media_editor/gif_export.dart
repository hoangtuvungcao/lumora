// Animated GIF export: every frame gets the same crop / rotate / flip /
// filter, the pixelate & blur brushes (computed per frame, so moving content
// stays hidden) and the static overlay (drawings, text, emoji, stickers).
// Runs in a background isolate and reports progress; frame delays and the
// loop count are kept.

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Matrix4;
import 'package:image/image.dart' as img;

import 'edit_render.dart';
import 'edit_state.dart';

/// Size guard: bigger GIFs are offered a downscale or a still photo.
const kGifMaxFrames = 300;
const kGifMaxSide = 1080;

bool isGifBytes(Uint8List b) => b.length > 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38;

class GifStats {
  const GifStats(this.frames, this.width, this.height);
  final int frames;
  final int width;
  final int height;
  bool get animated => frames > 1;
  bool get oversize => frames > kGifMaxFrames || math.max(width, height) > kGifMaxSide;
}

GifStats? gifStats(Uint8List bytes) {
  if (!isGifBytes(bytes)) return null;
  try {
    final info = img.GifDecoder().startDecode(bytes);
    if (info == null) return null;
    return GifStats(info.numFrames, info.width, info.height);
  } catch (_) {
    return null;
  }
}

/// Everything the worker needs (all sendable to an isolate).
class GifJob {
  GifJob({
    required this.gif,
    required this.outW,
    required this.outH,
    required this.toSource,
    required this.filter,
    required this.overlay,
    required this.pixelMask,
    required this.blurMask,
    required this.pixelBlock,
    required this.blurBlock,
    required this.frameStep,
  });

  final Uint8List gif;
  final int outW;
  final int outH;

  /// Affine output-pixel → GIF-pixel mapping: sx = a·x + b·y + c, sy = d·x + e·y + f.
  final Float64List toSource;
  final List<double>? filter;
  final Uint8List overlay;
  final Uint8List? pixelMask;
  final Uint8List? blurMask;
  final double pixelBlock;
  final double blurBlock;

  /// Keep every n-th frame (durations are merged) when over the frame cap.
  final int frameStep;
}

/// Prepares the job for [gif] decoded as [assets] (first frame) with [st].
/// [downscale] caps the long side at [kGifMaxSide] and the frame count at
/// [kGifMaxFrames].
Future<GifJob> buildGifJob(Uint8List gif, EditorAssets assets, EditState st, {required bool downscale}) async {
  final stats = gifStats(gif)!;
  final (w, h, scale) = outputSize(assets.size, st, downscale ? kGifMaxSide : 1 << 14);
  final layers = await renderFrameLayers(assets, st, w, h, scale);
  final inv = Matrix4.inverted(EditGeometry(assets.size, st).sourceToOutput(scale));
  final m = inv.storage;
  // Working image → native GIF pixels (the working copy may be downscaled).
  final k = stats.width / assets.image.width;
  final long = math.max(assets.size.width, assets.size.height);
  return GifJob(
    gif: gif,
    outW: w,
    outH: h,
    toSource: Float64List.fromList([m[0] * k, m[4] * k, m[12] * k, m[1] * k, m[5] * k, m[13] * k]),
    filter: PhotoFilters.matrix(st.filter),
    overlay: layers.overlay,
    pixelMask: layers.pixelMask,
    blurMask: layers.blurMask,
    pixelBlock: math.max(2, EditorAssets.blockFor(assets.size) * scale),
    blurBlock: math.max(2, long / math.max(16, long / 22) * scale),
    frameStep: downscale && stats.frames > kGifMaxFrames ? (stats.frames / kGifMaxFrames).ceil() : 1,
  );
}

/// Runs [job] in a background isolate.
Future<Uint8List> runGifJob(GifJob job, {void Function(double progress)? onProgress}) async {
  final port = ReceivePort();
  final done = Completer<Uint8List>();
  port.listen((m) {
    if (m is double) {
      onProgress?.call(m);
    } else if (m is TransferableTypedData) {
      done.complete(m.materialize().asUint8List());
    } else {
      done.completeError(StateError('$m'));
    }
  });
  final iso = await Isolate.spawn(_gifEntry, (job, port.sendPort), onError: port.sendPort);
  try {
    return await done.future;
  } finally {
    port.close();
    iso.kill(priority: Isolate.immediate);
  }
}

void _gifEntry((GifJob, SendPort) a) {
  final (job, port) = a;
  try {
    final out = encodeEditedGif(job, (p) => port.send(p));
    port.send(TransferableTypedData.fromList([out]));
  } catch (e) {
    port.send('$e');
  }
}

/// The frame pipeline (synchronous; call through [runGifJob] from the UI).
Uint8List encodeEditedGif(GifJob j, [void Function(double)? progress]) {
  final anim = img.decodeGif(j.gif);
  if (anim == null) throw const FormatException('GIF');
  final frames = anim.frames;
  final enc = img.GifEncoder(repeat: anim.loopCount, quantizerType: img.QuantizerType.octree, dither: img.DitherKernel.none);
  final w = j.outW, h = j.outH, t = j.toSource;
  for (var k = 0; k < frames.length; k += j.frameStep) {
    var duration = 0;
    for (var i = k; i < math.min(k + j.frameStep, frames.length); i++) {
      duration += frames[i].frameDuration;
    }
    final src = frames[k].convert(numChannels: 4);
    final sb = src.toUint8List();
    final sw = src.width, sh = src.height;
    final out = Uint8List(w * h * 4);

    // Geometry: bilinear sample through the inverse affine map.
    for (var y = 0; y < h; y++) {
      final py = y + 0.5;
      for (var x = 0; x < w; x++) {
        final px = x + 0.5;
        final sx = (t[0] * px + t[1] * py + t[2] - 0.5).clamp(0.0, sw - 1.0);
        final sy = (t[3] * px + t[4] * py + t[5] - 0.5).clamp(0.0, sh - 1.0);
        final x0 = sx.floor(), y0 = sy.floor();
        final x1 = math.min(x0 + 1, sw - 1), y1 = math.min(y0 + 1, sh - 1);
        final fx = sx - x0, fy = sy - y0;
        final i00 = (y0 * sw + x0) * 4, i10 = (y0 * sw + x1) * 4, i01 = (y1 * sw + x0) * 4, i11 = (y1 * sw + x1) * 4;
        final o = (y * w + x) * 4;
        for (var c = 0; c < 4; c++) {
          final top = sb[i00 + c] + (sb[i10 + c] - sb[i00 + c]) * fx;
          final bot = sb[i01 + c] + (sb[i11 + c] - sb[i01 + c]) * fx;
          out[o + c] = (top + (bot - top) * fy).round();
        }
      }
    }
    final f = j.filter;
    if (f != null) _applyMatrix(out, f);
    if (j.pixelMask != null) _pixelate(out, w, h, j.pixelMask!, j.pixelBlock);
    if (j.blurMask != null) _blur(out, w, h, j.blurMask!, j.blurBlock);
    _overlay(out, j.overlay);
    enc.addFrame(img.Image.fromBytes(width: w, height: h, bytes: out.buffer, numChannels: 4), duration: (duration / 10).round());
    progress?.call(math.min(1, (k + j.frameStep) / frames.length));
  }
  return enc.finish()!;
}

void _applyMatrix(Uint8List p, List<double> m) {
  for (var i = 0; i < p.length; i += 4) {
    final r = p[i].toDouble(), g = p[i + 1].toDouble(), b = p[i + 2].toDouble(), a = p[i + 3].toDouble();
    p[i] = (m[0] * r + m[1] * g + m[2] * b + m[3] * a + m[4]).round().clamp(0, 255);
    p[i + 1] = (m[5] * r + m[6] * g + m[7] * b + m[8] * a + m[9]).round().clamp(0, 255);
    p[i + 2] = (m[10] * r + m[11] * g + m[12] * b + m[13] * a + m[14]).round().clamp(0, 255);
    p[i + 3] = (m[15] * r + m[16] * g + m[17] * b + m[18] * a + m[19]).round().clamp(0, 255);
  }
}

/// Block averages where the mask is set (mask alpha blends the edge).
void _pixelate(Uint8List p, int w, int h, Uint8List mask, double block) {
  final b = block.round().clamp(2, 1 << 12);
  for (var by = 0; by < h; by += b) {
    for (var bx = 0; bx < w; bx += b) {
      final ex = math.min(bx + b, w), ey = math.min(by + b, h);
      var any = false;
      for (var y = by; y < ey && !any; y++) {
        for (var x = bx; x < ex; x++) {
          if (mask[y * w + x] != 0) {
            any = true;
            break;
          }
        }
      }
      if (!any) continue;
      final sum = [0, 0, 0, 0];
      final n = (ex - bx) * (ey - by);
      for (var y = by; y < ey; y++) {
        for (var x = bx; x < ex; x++) {
          final o = (y * w + x) * 4;
          for (var c = 0; c < 4; c++) {
            sum[c] += p[o + c];
          }
        }
      }
      for (var y = by; y < ey; y++) {
        for (var x = bx; x < ex; x++) {
          final m = mask[y * w + x];
          if (m == 0) continue;
          final o = (y * w + x) * 4;
          for (var c = 0; c < 4; c++) {
            p[o + c] = (p[o + c] + (sum[c] / n - p[o + c]) * m / 255).round();
          }
        }
      }
    }
  }
}

/// Strong blur: box-downsample by [block], bilinear upsample where masked.
void _blur(Uint8List p, int w, int h, Uint8List mask, double block) {
  final b = block.round().clamp(2, 1 << 12);
  final sw = (w / b).ceil(), sh = (h / b).ceil();
  final small = Float64List(sw * sh * 4);
  for (var sy = 0; sy < sh; sy++) {
    for (var sx = 0; sx < sw; sx++) {
      final ex = math.min((sx + 1) * b, w), ey = math.min((sy + 1) * b, h);
      final n = (ex - sx * b) * (ey - sy * b);
      for (var y = sy * b; y < ey; y++) {
        for (var x = sx * b; x < ex; x++) {
          final o = (y * w + x) * 4;
          for (var c = 0; c < 4; c++) {
            small[(sy * sw + sx) * 4 + c] += p[o + c] / n;
          }
        }
      }
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final m = mask[y * w + x];
      if (m == 0) continue;
      final gx = ((x + 0.5) / b - 0.5).clamp(0.0, sw - 1.0), gy = ((y + 0.5) / b - 0.5).clamp(0.0, sh - 1.0);
      final x0 = gx.floor(), y0 = gy.floor(), x1 = math.min(x0 + 1, sw - 1), y1 = math.min(y0 + 1, sh - 1);
      final fx = gx - x0, fy = gy - y0;
      final o = (y * w + x) * 4;
      for (var c = 0; c < 4; c++) {
        final top = small[(y0 * sw + x0) * 4 + c] * (1 - fx) + small[(y0 * sw + x1) * 4 + c] * fx;
        final bot = small[(y1 * sw + x0) * 4 + c] * (1 - fx) + small[(y1 * sw + x1) * 4 + c] * fx;
        final v = top * (1 - fy) + bot * fy;
        p[o + c] = (p[o + c] + (v - p[o + c]) * m / 255).round().clamp(0, 255);
      }
    }
  }
}

/// Straight-alpha "over" of the overlay layer.
void _overlay(Uint8List p, Uint8List ov) {
  for (var i = 0; i < p.length; i += 4) {
    final a = ov[i + 3];
    if (a == 0) continue;
    if (a == 255) {
      p[i] = ov[i];
      p[i + 1] = ov[i + 1];
      p[i + 2] = ov[i + 2];
      p[i + 3] = 255;
      continue;
    }
    final t = a / 255;
    for (var c = 0; c < 3; c++) {
      p[i + c] = (ov[i + c] * t + p[i + c] * (1 - t)).round();
    }
    p[i + 3] = math.max(p[i + 3], a);
  }
}

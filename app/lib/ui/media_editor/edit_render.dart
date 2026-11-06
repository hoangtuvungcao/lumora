// Paints an [EditState] over its photo. The same code draws the live
// preview (scaled to the screen) and the exported file, so what you see is
// exactly what gets sent.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'edit_state.dart';

/// Decoded working image plus the derived "censor" sources and sticker
/// bitmaps. Owns the images (call [dispose]).
class EditorAssets {
  EditorAssets._(this.image, this.pixel, this.blur);

  final ui.Image image;

  /// Tiny, area-averaged copy drawn with nearest-neighbour → big blocks.
  final ui.Image pixel;

  /// Small blurred copy drawn with bilinear upscale → strong soft blur.
  final ui.Image blur;
  final Map<String, ui.Image> stickers = {};

  Size get size => Size(image.width.toDouble(), image.height.toDouble());

  /// Block edge of the pixelate brush in source pixels. Large on purpose:
  /// small mosaics of text can be reconstructed, ~1/40 of the photo can't.
  static double blockFor(Size s) => math.max(8, math.max(s.width, s.height) / 40);

  static EditorAssets of(ui.Image image) {
    final s = Size(image.width.toDouble(), image.height.toDouble());
    final block = blockFor(s);
    final pw = math.max(1, (s.width / block).ceil()), ph = math.max(1, (s.height / block).ceil());
    final pixel = _scaled(image, pw, ph, null);
    final long = math.max(s.width, s.height);
    final bs = math.max(16.0, long / 22) / long;
    final bw = math.max(1, (s.width * bs).round()), bh = math.max(1, (s.height * bs).round());
    final blur = _scaled(image, bw, bh, ui.ImageFilter.blur(sigmaX: 1.6, sigmaY: 1.6, tileMode: TileMode.clamp));
    return EditorAssets._(image, pixel, blur);
  }

  static ui.Image _scaled(ui.Image src, int w, int h, ui.ImageFilter? filter) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final p = Paint()..filterQuality = FilterQuality.medium;
    if (filter != null) p.imageFilter = filter;
    c.drawImageRect(src, Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()), Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), p);
    final pic = rec.endRecording();
    final out = pic.toImageSync(w, h);
    pic.dispose();
    return out;
  }

  void dispose() {
    image.dispose();
    pixel.dispose();
    blur.dispose();
    for (final s in stickers.values) {
      s.dispose();
    }
    stickers.clear();
  }
}

/// Smooth path through the touch points (quadratic mid-point spline).
Path strokePath(List<Offset> pts) {
  final p = Path()..moveTo(pts.first.dx, pts.first.dy);
  if (pts.length == 1) {
    p.lineTo(pts.first.dx + 0.01, pts.first.dy);
    return p;
  }
  for (var i = 1; i < pts.length - 1; i++) {
    final mid = (pts[i] + pts[i + 1]) / 2;
    p.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
  }
  p.lineTo(pts.last.dx, pts.last.dy);
  return p;
}

Paint _strokePaint(Stroke s) => Paint()
  ..style = PaintingStyle.stroke
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round
  ..strokeWidth = s.width
  ..isAntiAlias = true
  ..color = s.kind == StrokeKind.highlighter ? s.color.withValues(alpha: 0.42) : s.color;

/// Paints the whole composition into [c] whose origin is the top-left of the
/// cropped output, at [scale] output pixels per oriented source pixel.
void paintComposition(
  Canvas c,
  EditorAssets a,
  EditState st, {
  required double scale,
  Stroke? live,
  String? hiddenItem,
  Color? background,
  bool showFullFrame = false,
  bool photo = true,
}) {
  final view = showFullFrame ? st.copyWith(crop: EditState.full) : st;
  final g = EditGeometry(a.size, view);
  final out = g.cropPx.size * scale;
  final frame = Offset.zero & out;
  c.save();
  c.clipRect(frame);
  if (background != null) c.drawRect(frame, Paint()..color = background);
  c.transform(g.sourceToOutput(scale).storage);
  final srcRect = Offset.zero & a.size;
  final filter = PhotoFilters.of(st.filter);
  if (photo) {
    c.drawImageRect(a.image, srcRect, srcRect, Paint()
      ..filterQuality = FilterQuality.medium
      ..colorFilter = filter);
  }

  void censor(Stroke s) {
    final b = s.bounds.intersect(srcRect);
    if (b.isEmpty) return;
    c.saveLayer(b, Paint());
    c.drawPath(strokePath(s.points), _strokePaint(s)..color = const Color(0xFF000000));
    final small = s.kind == StrokeKind.pixelate ? a.pixel : a.blur;
    c.drawImageRect(
      small,
      Rect.fromLTWH(0, 0, small.width.toDouble(), small.height.toDouble()),
      srcRect,
      Paint()
        ..blendMode = BlendMode.srcIn
        ..filterQuality = s.kind == StrokeKind.pixelate ? FilterQuality.none : FilterQuality.low
        ..colorFilter = filter,
    );
    c.restore();
  }

  final all = [...st.strokes, ?live];
  // Censoring hides what is *in the photo*; it is applied before drawings.
  if (photo) {
    for (final s in all) {
      if (s.censor) censor(s);
    }
  }
  for (final s in all) {
    if (!s.censor) c.drawPath(strokePath(s.points), _strokePaint(s));
  }
  for (final it in st.items) {
    if (it.id == hiddenItem) continue;
    paintItem(c, it, st, a);
  }
  c.restore();
}

/// Max wrap width for text items, in source pixels.
double textWrapWidth(Size src) => math.max(src.width, src.height) * 0.8;

TextPainter layoutItemText(OverlayItem it, Size src, {Paint? foreground}) {
  final emoji = it.kind == OverlayKind.emoji;
  final textColor = switch (it.bg) {
    TextBg.solid => it.color.computeLuminance() > 0.6 ? const Color(0xFF111111) : Colors.white,
    _ => it.color,
  };
  final style = TextStyle(
    fontFamily: kFontFamily,
    fontFamilyFallback: kFontFallback,
    fontWeight: FontWeight.w700,
    fontSize: it.size,
    height: 1.22,
    color: foreground == null ? (emoji ? null : textColor) : null,
    foreground: foreground,
    shadows: !emoji && it.bg == TextBg.plain && foreground == null ? [Shadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: it.size * 0.18)] : null,
  );
  return TextPainter(
    text: TextSpan(text: it.text.isEmpty ? ' ' : it.text, style: style),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: emoji ? double.infinity : textWrapWidth(src));
}

EdgeInsets _pad(OverlayItem it) => it.kind == OverlayKind.text && (it.bg == TextBg.solid || it.bg == TextBg.translucent)
    ? EdgeInsets.symmetric(horizontal: it.size * 0.42, vertical: it.size * 0.2)
    : EdgeInsets.all(it.size * 0.08);

/// Un-rotated size of an item in source pixels (for hit tests / handles).
Size itemSize(OverlayItem it, Size src) {
  if (it.kind == OverlayKind.sticker) return Size(it.size, it.size);
  final tp = layoutItemText(it, src);
  final s = _pad(it).inflateSize(tp.size);
  tp.dispose();
  return s;
}

void paintItem(Canvas c, OverlayItem it, EditState st, EditorAssets a) {
  c.save();
  c.translate(it.pos.dx, it.pos.dy);
  if (st.flip) c.scale(-1, 1); // keep text / stickers readable when mirrored
  c.rotate(it.angle);
  if (it.kind == OverlayKind.sticker) {
    final img = a.stickers[it.sticker];
    final box = Rect.fromCenter(center: Offset.zero, width: it.size, height: it.size);
    if (img != null) {
      final iw = img.width.toDouble(), ih = img.height.toDouble();
      final f = math.min(box.width / iw, box.height / ih);
      final dst = Rect.fromCenter(center: Offset.zero, width: iw * f, height: ih * f);
      c.drawImageRect(img, Rect.fromLTWH(0, 0, iw, ih), dst, Paint()..filterQuality = FilterQuality.medium);
    }
  } else {
    final tp = layoutItemText(it, a.size);
    final pad = _pad(it);
    final box = Rect.fromCenter(center: Offset.zero, width: tp.width + pad.horizontal, height: tp.height + pad.vertical);
    final r = Radius.circular(it.size * 0.32);
    if (it.kind == OverlayKind.text && it.bg == TextBg.solid) {
      c.drawRRect(RRect.fromRectAndRadius(box, r), Paint()..color = it.color);
    } else if (it.kind == OverlayKind.text && it.bg == TextBg.translucent) {
      c.drawRRect(RRect.fromRectAndRadius(box, r), Paint()..color = Colors.black.withValues(alpha: 0.55));
    }
    final origin = Offset(-tp.width / 2, -tp.height / 2);
    if (it.kind == OverlayKind.text && it.bg == TextBg.outline) {
      final dark = it.color.computeLuminance() < 0.25;
      final outline = layoutItemText(
        it,
        a.size,
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = it.size * 0.16
          ..color = dark ? Colors.white : Colors.black,
      );
      outline.paint(c, origin);
      outline.dispose();
    }
    tp.paint(c, origin);
    tp.dispose();
  }
  c.restore();
}

/// Output pixel size for [st] with the long side capped at [maxSide].
(int, int, double) outputSize(Size src, EditState st, int maxSide) {
  final crop = EditGeometry(src, st).cropPx.size;
  final scale = math.min(1.0, maxSide / math.max(crop.width, crop.height));
  return (math.max(1, (crop.width * scale).round()), math.max(1, (crop.height * scale).round()), scale);
}

/// Renders the final bitmap (long side ≤ [maxSide]).
Future<ui.Image> renderComposition(EditorAssets a, EditState st, {required int maxSide, Color? background}) async {
  final (w, h, scale) = outputSize(a.size, st, maxSide);
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  // Exact-fit scale per axis would distort by < 1px; use the uniform one.
  paintComposition(c, a, st, scale: scale, background: background);
  final pic = rec.endRecording();
  final img = await pic.toImage(w, h);
  pic.dispose();
  return img;
}

/// Layers for frame-by-frame (GIF) export at [w]x[h], [scale] output px per
/// source px: the overlay (drawings, text, stickers) as straight RGBA, and
/// one alpha mask per censor kind (1 byte per pixel).
class FrameLayers {
  FrameLayers(this.overlay, this.pixelMask, this.blurMask);
  final Uint8List overlay;
  final Uint8List? pixelMask;
  final Uint8List? blurMask;
}

Future<FrameLayers> renderFrameLayers(EditorAssets a, EditState st, int w, int h, double scale) async {
  Future<Uint8List> render(void Function(Canvas c) paint, {bool straight = true}) async {
    final rec = ui.PictureRecorder();
    paint(Canvas(rec));
    final pic = rec.endRecording();
    final img = await pic.toImage(w, h);
    pic.dispose();
    final d = await img.toByteData(format: straight ? ui.ImageByteFormat.rawStraightRgba : ui.ImageByteFormat.rawRgba);
    img.dispose();
    return d!.buffer.asUint8List();
  }

  Future<Uint8List?> mask(StrokeKind kind) async {
    final strokes = st.strokes.where((s) => s.kind == kind).toList();
    if (strokes.isEmpty) return null;
    final rgba = await render((c) {
      c.clipRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
      c.transform(EditGeometry(a.size, st).sourceToOutput(scale).storage);
      for (final s in strokes) {
        c.drawPath(strokePath(s.points), _strokePaint(s)..color = const Color(0xFFFFFFFF));
      }
    });
    final out = Uint8List(w * h);
    for (var i = 0; i < out.length; i++) {
      out[i] = rgba[i * 4 + 3];
    }
    return out;
  }

  final overlay = await render((c) => paintComposition(c, a, st, scale: scale, photo: false));
  return FrameLayers(overlay, await mask(StrokeKind.pixelate), await mask(StrokeKind.blur));
}

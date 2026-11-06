// Crop frame maths + painter. Everything works in *display* coordinates of
// the editor stage (so it keeps working while the view is zoomed / panned):
// `image` is where the whole oriented photo currently sits on screen,
// `crop` the frame inside it.

import 'dart:math' as math;

import 'package:flutter/material.dart';

enum CropZone { tl, tr, bl, br, l, t, r, b, move }

abstract final class CropMath {
  static const minSide = 48.0;

  /// Largest rect of [aspect] (pixel ratio) inside a [size] frame, centred on
  /// [around] (normalised), returned normalised.
  static Rect fitAspect(Size size, double aspect, Offset around) {
    var w = size.width, h = w / aspect;
    if (h > size.height) {
      h = size.height;
      w = h * aspect;
    }
    final cx = (around.dx * size.width).clamp(w / 2, size.width - w / 2);
    final cy = (around.dy * size.height).clamp(h / 2, size.height - h / 2);
    final r = Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
    return Rect.fromLTRB(r.left / size.width, r.top / size.height, r.right / size.width, r.bottom / size.height);
  }

  /// Normalised crop → display rect inside [image].
  static Rect toDisplay(Rect crop, Rect image) =>
      Rect.fromLTRB(image.left + crop.left * image.width, image.top + crop.top * image.height, image.left + crop.right * image.width, image.top + crop.bottom * image.height);

  /// Display rect → normalised crop of [image].
  static Rect toNormal(Rect r, Rect image) => Rect.fromLTRB(
        ((r.left - image.left) / image.width).clamp(0, 1),
        ((r.top - image.top) / image.height).clamp(0, 1),
        ((r.right - image.left) / image.width).clamp(0, 1),
        ((r.bottom - image.top) / image.height).clamp(0, 1),
      );

  static CropZone? hit(Rect r, Offset p, {required bool locked}) {
    const k = 30.0, e = 20.0;
    bool near(Offset a) => (a - p).distance <= k;
    if (near(r.topLeft)) return CropZone.tl;
    if (near(r.topRight)) return CropZone.tr;
    if (near(r.bottomLeft)) return CropZone.bl;
    if (near(r.bottomRight)) return CropZone.br;
    final inY = p.dy > r.top && p.dy < r.bottom, inX = p.dx > r.left && p.dx < r.right;
    if (!locked) {
      if (inY && (p.dx - r.left).abs() < e) return CropZone.l;
      if (inY && (p.dx - r.right).abs() < e) return CropZone.r;
      if (inX && (p.dy - r.top).abs() < e) return CropZone.t;
      if (inX && (p.dy - r.bottom).abs() < e) return CropZone.b;
    }
    if (r.contains(p)) return CropZone.move;
    return null;
  }

  /// New display crop rect for a drag of [zone] that started on [r0] at
  /// [start], now at [p], kept inside [image].
  static Rect update(CropZone zone, Rect r0, Offset start, Offset p, Rect image, double? aspect) {
    // Work relative to the image's top-left.
    final o = image.topLeft;
    final q = p - o;
    final s0 = r0.shift(-o);
    final w = image.width, h = image.height;
    final minS = math.min(minSide, math.min(w, h));
    Rect out;
    switch (zone) {
      case CropZone.move:
        final d = p - start;
        out = s0.shift(Offset(d.dx.clamp(-s0.left, w - s0.right), d.dy.clamp(-s0.top, h - s0.bottom)));
      case CropZone.l:
        out = Rect.fromLTRB(q.dx.clamp(0, s0.right - minS), s0.top, s0.right, s0.bottom);
      case CropZone.r:
        out = Rect.fromLTRB(s0.left, s0.top, q.dx.clamp(s0.left + minS, w), s0.bottom);
      case CropZone.t:
        out = Rect.fromLTRB(s0.left, q.dy.clamp(0, s0.bottom - minS), s0.right, s0.bottom);
      case CropZone.b:
        out = Rect.fromLTRB(s0.left, s0.top, s0.right, q.dy.clamp(s0.top + minS, h));
      case CropZone.tl:
      case CropZone.tr:
      case CropZone.bl:
      case CropZone.br:
        final left = zone == CropZone.tl || zone == CropZone.bl, top = zone == CropZone.tl || zone == CropZone.tr;
        final ax = left ? s0.right : s0.left, ay = top ? s0.bottom : s0.top;
        final sx = left ? -1.0 : 1.0, sy = top ? -1.0 : 1.0;
        final maxW = left ? ax : w - ax, maxH = top ? ay : h - ay;
        var cw = ((q.dx - ax) * sx).clamp(minS, math.max(minS, maxW));
        var ch = ((q.dy - ay) * sy).clamp(minS, math.max(minS, maxH));
        if (aspect != null) {
          if (cw / ch > aspect) {
            ch = cw / aspect;
          } else {
            cw = ch * aspect;
          }
          if (cw > maxW) {
            cw = maxW;
            ch = cw / aspect;
          }
          if (ch > maxH) {
            ch = maxH;
            cw = ch * aspect;
          }
        }
        out = Rect.fromPoints(Offset(ax, ay), Offset(ax + sx * cw, ay + sy * ch));
    }
    return out.shift(o);
  }
}

/// Dims everything outside [r], draws the frame, thirds grid and handles.
class CropFramePainter extends CustomPainter {
  CropFramePainter(this.r);
  final Rect r;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.62);
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, r.top), dim);
    canvas.drawRect(Rect.fromLTRB(0, r.bottom, size.width, size.height), dim);
    canvas.drawRect(Rect.fromLTRB(0, r.top, r.left, r.bottom), dim);
    canvas.drawRect(Rect.fromLTRB(r.right, r.top, size.width, r.bottom), dim);
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = r.left + r.width * i / 3, y = r.top + r.height * i / 3;
      canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), grid);
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), grid);
    }
    canvas.drawRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white
        ..strokeWidth = 1.5,
    );
    final h = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final l = math.min(22.0, math.min(r.width, r.height) / 3);
    for (final (p, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomLeft, 1.0, -1.0),
      (r.bottomRight, -1.0, -1.0),
    ]) {
      final q = p + Offset(-dx * 1.5, -dy * 1.5);
      canvas.drawLine(q, q + Offset(dx * l, 0), h);
      canvas.drawLine(q, q + Offset(0, dy * l), h);
    }
  }

  @override
  bool shouldRepaint(CropFramePainter old) => old.r != r;
}

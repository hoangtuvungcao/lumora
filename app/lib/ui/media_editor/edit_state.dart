// Photo editor model: an immutable [EditState] (geometry, strokes, overlay
// items, filter) plus the geometry maths shared by the on-screen preview and
// the exporter, and a small undo/redo [EditHistory].
//
// Coordinates:
//  * strokes and overlay items live in *source pixel* space (the decoded
//    working image), so crop / rotate never move them relative to the photo;
//  * the crop rect is normalised (0..1) in *oriented* space (after the
//    quarter-turn rotation and the horizontal flip).

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/painting.dart' show MatrixUtils;
import 'package:flutter/widgets.dart' show ChangeNotifier, Matrix4, immutable;

enum StrokeKind { pen, highlighter, pixelate, blur }

@immutable
class Stroke {
  const Stroke(this.kind, this.points, this.width, this.color);
  final StrokeKind kind;

  /// Source-pixel points.
  final List<Offset> points;

  /// Source-pixel width.
  final double width;
  final Color color;

  bool get censor => kind == StrokeKind.pixelate || kind == StrokeKind.blur;

  Rect get bounds {
    var l = double.infinity, t = double.infinity, r = -double.infinity, b = -double.infinity;
    for (final p in points) {
      l = math.min(l, p.dx);
      t = math.min(t, p.dy);
      r = math.max(r, p.dx);
      b = math.max(b, p.dy);
    }
    return Rect.fromLTRB(l, t, r, b).inflate(width);
  }
}

enum OverlayKind { text, emoji, sticker }

/// Background styles for text items.
enum TextBg { plain, outline, solid, translucent }

@immutable
class OverlayItem {
  const OverlayItem({
    required this.id,
    required this.kind,
    required this.pos,
    required this.size,
    this.text = '',
    this.sticker = '',
    this.color = const Color(0xFFFFFFFF),
    this.bg = TextBg.plain,
    this.angle = 0,
  });

  final String id;
  final OverlayKind kind;
  final String text;

  /// Sticker hash (kind == sticker).
  final String sticker;
  final Color color;
  final TextBg bg;

  /// Centre, source pixels.
  final Offset pos;

  /// Font size (text / emoji) or side length (sticker), source pixels.
  final double size;

  /// Local rotation (radians).
  final double angle;

  OverlayItem copyWith({String? text, Color? color, TextBg? bg, Offset? pos, double? size, double? angle}) => OverlayItem(
        id: id,
        kind: kind,
        text: text ?? this.text,
        sticker: sticker,
        color: color ?? this.color,
        bg: bg ?? this.bg,
        pos: pos ?? this.pos,
        size: size ?? this.size,
        angle: angle ?? this.angle,
      );
}

/// Colour filters (applied to the photo itself, not to drawings/text).
abstract final class PhotoFilters {
  static const ids = ['none', 'vivid', 'warm', 'cool', 'mono', 'fade', 'noir'];

  static List<double>? matrix(String id) => switch (id) {
        'vivid' => _mul(_saturation(1.35), _contrast(1.08)),
        'warm' => _mul(const [1.08, 0, 0, 0, 8, 0, 1.0, 0, 0, 2, 0, 0, 0.88, 0, -6, 0, 0, 0, 1, 0], _saturation(1.08)),
        'cool' => const [0.92, 0, 0, 0, -4, 0, 1.0, 0, 0, 2, 0, 0, 1.1, 0, 10, 0, 0, 0, 1, 0],
        'mono' => _saturation(0),
        'fade' => _mul(_saturation(0.75), const [0.86, 0, 0, 0, 26, 0, 0.86, 0, 0, 24, 0, 0, 0.86, 0, 30, 0, 0, 0, 1, 0]),
        'noir' => _mul(_contrast(1.35), _saturation(0)),
        _ => null,
      };

  static ColorFilter? of(String id) {
    final m = matrix(id);
    return m == null ? null : ColorFilter.matrix(m);
  }

  static List<double> _saturation(double s) {
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final sr = (1 - s) * lr, sg = (1 - s) * lg, sb = (1 - s) * lb;
    return [sr + s, sg, sb, 0, 0, sr, sg + s, sb, 0, 0, sr, sg, sb + s, 0, 0, 0, 0, 0, 1, 0];
  }

  static List<double> _contrast(double c) {
    final t = 128 * (1 - c);
    return [c, 0, 0, 0, t, 0, c, 0, 0, t, 0, 0, c, 0, t, 0, 0, 0, 1, 0];
  }

  /// a ∘ b (apply b first, then a) for 4x5 colour matrices.
  static List<double> _mul(List<double> a, List<double> b) {
    final out = List<double>.filled(20, 0);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 5; c++) {
        var v = c == 4 ? a[r * 5 + 4] : 0.0;
        for (var k = 0; k < 4; k++) {
          v += a[r * 5 + k] * b[k * 5 + c];
        }
        out[r * 5 + c] = v;
      }
    }
    return out;
  }
}

@immutable
class EditState {
  const EditState({
    this.turns = 0,
    this.flip = false,
    this.crop = const Rect.fromLTRB(0, 0, 1, 1),
    this.filter = 'none',
    this.strokes = const [],
    this.items = const [],
  });

  /// Clockwise quarter turns, 0..3.
  final int turns;
  final bool flip;

  /// Normalised crop in oriented space.
  final Rect crop;
  final String filter;
  final List<Stroke> strokes;
  final List<OverlayItem> items;

  static const full = Rect.fromLTRB(0, 0, 1, 1);

  bool get pristine => turns == 0 && !flip && _isFull(crop) && filter == 'none' && strokes.isEmpty && items.isEmpty;

  static bool _isFull(Rect r) => r.left <= 1e-4 && r.top <= 1e-4 && r.right >= 1 - 1e-4 && r.bottom >= 1 - 1e-4;

  EditState copyWith({int? turns, bool? flip, Rect? crop, String? filter, List<Stroke>? strokes, List<OverlayItem>? items}) => EditState(
        turns: turns ?? this.turns,
        flip: flip ?? this.flip,
        crop: crop ?? this.crop,
        filter: filter ?? this.filter,
        strokes: strokes ?? this.strokes,
        items: items ?? this.items,
      );

  /// Rotates the whole composition 90° counter-clockwise (crop follows).
  EditState rotatedLeft() {
    // Oriented point (x, y) → (y, 1 - x) when turning counter-clockwise.
    final c = crop;
    return copyWith(turns: (turns + 3) % 4, crop: Rect.fromLTRB(c.top, 1 - c.right, c.bottom, 1 - c.left));
  }

  EditState flipped() => copyWith(flip: !flip, crop: Rect.fromLTRB(1 - crop.right, crop.top, 1 - crop.left, crop.bottom));

  EditState withItem(OverlayItem it) {
    final i = items.indexWhere((x) => x.id == it.id);
    final next = List.of(items);
    if (i < 0) {
      next.add(it);
    } else {
      next[i] = it;
    }
    return copyWith(items: next);
  }

  EditState withoutItem(String id) => copyWith(items: items.where((x) => x.id != id).toList());

  /// Angle that makes a new text item read upright in the current orientation.
  double get uprightAngle => flip ? turns * math.pi / 2 : -turns * math.pi / 2;
}

/// Geometry for a source image of [src] pixels under [st].
class EditGeometry {
  EditGeometry(this.src, this.st);
  final Size src;
  final EditState st;

  Size get oriented => st.turns.isOdd ? Size(src.height, src.width) : src;

  Rect get cropPx {
    final o = oriented;
    final c = st.crop;
    return Rect.fromLTRB(c.left * o.width, c.top * o.height, c.right * o.width, c.bottom * o.height);
  }

  /// Source pixels → oriented pixels.
  Matrix4 sourceToOriented() {
    final o = oriented;
    final m = Matrix4.identity()..translateByDouble(o.width / 2, o.height / 2, 0, 1);
    if (st.flip) m.scaleByDouble(-1, 1, 1, 1);
    m.rotateZ(st.turns * math.pi / 2);
    m.translateByDouble(-src.width / 2, -src.height / 2, 0, 1);
    return m;
  }

  /// Source pixels → output canvas (cropped, scaled by [scale]).
  Matrix4 sourceToOutput(double scale) {
    final c = cropPx;
    return Matrix4.identity()
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-c.left, -c.top, 0, 1)
      ..multiply(sourceToOriented());
  }

  /// On-screen rotation of an item with local [angle].
  double visualAngle(double angle) => st.flip ? angle - st.turns * math.pi / 2 : angle + st.turns * math.pi / 2;

  static Offset apply(Matrix4 m, Offset p) => MatrixUtils.transformPoint(m, p);

  static Offset applyInverse(Matrix4 m, Offset p) => apply(Matrix4.inverted(m), p);
}

/// Linear undo/redo over immutable states.
class EditHistory extends ChangeNotifier {
  EditHistory([EditState initial = const EditState()]) : _states = [initial];

  final List<EditState> _states;
  int _i = 0;

  EditState get current => _states[_i];
  bool get canUndo => _i > 0;
  bool get canRedo => _i < _states.length - 1;
  bool get edited => !current.pristine;

  void push(EditState s) {
    if (identical(s, current)) return;
    _states.removeRange(_i + 1, _states.length);
    _states.add(s);
    if (_states.length > 80) _states.removeAt(0);
    _i = _states.length - 1;
    notifyListeners();
  }

  void undo() {
    if (!canUndo) return;
    _i--;
    notifyListeners();
  }

  void redo() {
    if (!canRedo) return;
    _i++;
    notifyListeners();
  }

  /// Back to the untouched photo (itself undoable).
  void reset() {
    if (current.pristine) return;
    push(const EditState());
  }
}

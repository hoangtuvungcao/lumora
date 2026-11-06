// Full-screen photo editor + send preview (Telegram/Zalo style).
//
// Preview mode: the photo(s), "Chỉnh sửa", caption, quality toggle and the
// finish actions (Gửi / Chuyển tiếp… / Lưu về máy).
// Edit mode: crop & rotate, draw (pen / highlighter), hide (pixelate / blur
// brush), text, emoji & stickers, filters, with undo / redo / reset.

import 'dart:convert';
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/file_safety.dart' show isSafeImageBytes;
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../chats/attachments.dart' show openFile;
import '../chats/forward_sheet.dart' show pickConversation;
import '../widgets/app_icons.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'crop_overlay.dart';
import 'edit_render.dart';
import 'edit_state.dart';
import 'editor_icons.dart';
import 'editor_panels.dart';
import 'gif_export.dart';
import 'heic.dart';
import 'photo_fallback.dart' show heicHint;
import 'photo_io.dart';

enum EditorTool { none, crop, draw, hide, text, sticker, filter }

enum PhotoEditorPurpose {
  /// Picked / pasted / dropped photos: preview → (edit) → send.
  beforeSend,

  /// "Chỉnh sửa" from the media viewer: edit → send here / forward / save.
  fromViewer,
}

/// What the screen did when it closed.
enum PhotoEditorResult { sent, forwarded }

/// One photo being prepared.
class PhotoDraft {
  PhotoDraft(this.path);
  final String path;

  /// Committed edits (what will be sent).
  EditState state = const EditState();
  Uint8List? bytes;
  EditorAssets? assets;
  Object? error;

  /// Set for GIF files (frame count / size).
  GifStats? gif;
  Future<void>? _loading;

  bool get heic => isHeicPath(path);

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final b = await readPhotoBytes(path);
      // Same decompression-bomb guard as chat images (huge declared sizes).
      if (!isSafeImageBytes(b, allowUnknown: true)) throw StateError('image_too_large');
      bytes = b;
      gif = gifStats(b);
      final ui.Image image;
      if (heic && !path.startsWith('asset:')) {
        image = await decodeHeic(path) ?? (throw StateError('heic_unsupported'));
      } else {
        image = await decodeWorkingImage(b);
      }
      assets = EditorAssets.of(image);
    } catch (e) {
      error = e;
    }
  }

  void dispose() => assets?.dispose();
}

class PhotoEditorScreen extends StatefulWidget {
  const PhotoEditorScreen({super.key, required this.conv, required this.paths, this.purpose = PhotoEditorPurpose.beforeSend, this.startEditing = false});

  final String conv;
  final List<String> paths;
  final PhotoEditorPurpose purpose;
  final bool startEditing;

  @override
  State<PhotoEditorScreen> createState() => PhotoEditorScreenState();
}

class _ItemDrag {
  _ItemDrag(this.item, this.start);
  final OverlayItem item;
  final Offset start; // source px (move) or display px (handle)
}

class PhotoEditorScreenState extends State<PhotoEditorScreen> {
  late final List<PhotoDraft> drafts = widget.paths.map(PhotoDraft.new).toList();
  late final Future<void> ready = Future.wait(drafts.map((d) => d.load())).then((_) {
    if (mounted) setState(() {});
  });
  int _index = 0;
  PhotoDraft get draft => drafts[_index];

  /// Undo/redo of the current edit session (null in preview mode).
  EditHistory? _session;
  bool _committedOnce = false;
  EditorTool _tool = EditorTool.none;
  bool _original = false;
  bool _busy = false;
  final _caption = TextEditingController();
  final _stackKey = GlobalKey();

  StrokeKind _penKind = StrokeKind.pen;
  Color _penColor = const Color(0xFFEF4444);
  int _penSize = 1;
  StrokeKind _censorKind = StrokeKind.pixelate;
  int _censorSize = 1;
  String _aspectId = 'free';

  List<Offset>? _livePts;
  EditState? _transient;
  String? _selected;
  OverlayItem? _textEditing;
  _ItemDrag? _drag;
  int _ids = 0;

  // ---- view (zoom / pan) and layout of the last build
  static const _maxZoom = 8.0;
  double _zoom = 1;
  Offset _pan = Offset.zero;
  Size _stageSize = Size.zero;
  Size _frame = Size.zero;
  double _fit = 1;
  EditGeometry? _geom;
  _ViewDrag? _view;
  _Gesture _g = _Gesture.none;
  (CropZone, Rect, Offset)? _cropDrag;
  final Set<int> _pointers = {};
  bool _multiTouch = false;
  bool _spaceHeld = false;
  int? _midPointer;
  Offset? _lastDown;
  Offset? _midPan;
  (int, Duration, Offset)? _tapDown;
  (Duration, Offset)? _lastTap;

  /// GIF export progress (0..1) while the busy overlay is up.
  double? _progress;

  double get _viewScale => _fit * _zoom;
  Offset get _origin => _stageSize.center(Offset.zero) + _pan - Offset(_frame.width, _frame.height) * (_viewScale / 2);
  bool get _cropMode => editing && _tool == EditorTool.crop;
  bool get _drawMode => editing && (_tool == EditorTool.draw || _tool == EditorTool.hide);
  Rect get _imageDisp => _origin & (_frame * _viewScale);
  Rect get _cropDisp => CropMath.toDisplay(_state.crop, _imageDisp);

  bool get editing => _session != null;
  EditState get _base => _session?.current ?? draft.state;
  EditState get _state => _transient ?? _base;

  @override
  void initState() {
    super.initState();
    if (widget.startEditing) _beginEdit();
  }

  @override
  void dispose() {
    _session?.dispose();
    _caption.dispose();
    for (final d in drafts) {
      d.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------- session

  void _beginEdit([EditorTool tool = EditorTool.none]) {
    setState(() {
      _session = EditHistory(draft.state)..addListener(_onHistory);
      _tool = tool;
      _selected = null;
    });
  }

  void _onHistory() => setState(() {});

  void _endSession() {
    _session?.removeListener(_onHistory);
    _session?.dispose();
    _session = null;
    _tool = EditorTool.none;
    _selected = null;
    _transient = null;
    _livePts = null;
    _textEditing = null;
  }

  void _commitEdit() {
    setState(() {
      draft.state = _session!.current;
      _committedOnce = true;
      _endSession();
    });
  }

  Future<bool> _confirmDiscard() => confirm(context, title: S.read(context)('pe_discard_title'), body: S.read(context)('pe_discard_body'), action: S.read(context)('pe_discard'), danger: true);

  Future<void> _cancelEdit() async {
    final changed = _session!.current != draft.state;
    if (changed && !await _confirmDiscard()) return;
    if (!mounted) return;
    if (widget.startEditing && !_committedOnce) {
      Navigator.pop(context);
      return;
    }
    setState(_endSession);
  }

  Future<void> _close() async {
    if (_busy) return;
    if (editing) return _cancelEdit();
    if (drafts.any((d) => !d.state.pristine) && !await _confirmDiscard()) return;
    if (mounted) Navigator.pop(context);
  }

  void _push(EditState s) => _session?.push(s);

  void _setTool(EditorTool t) {
    if (t == EditorTool.text) {
      setState(() => _tool = t);
      _newText(null);
      return;
    }
    if (t == EditorTool.sticker) {
      setState(() => _tool = t);
      _addSticker();
      return;
    }
    setState(() {
      _tool = _tool == t && t != EditorTool.crop ? EditorTool.none : t;
      if (_tool == EditorTool.crop || _tool == EditorTool.draw || _tool == EditorTool.hide) _selected = null;
    });
  }

  // ---------------------------------------------------------------- geometry

  Matrix4 get _toDisplay => Matrix4.translationValues(_origin.dx, _origin.dy, 0)..multiply(_geom!.sourceToOutput(_viewScale));
  Offset _toSrc(Offset display) => EditGeometry.applyInverse(_toDisplay, display);
  Offset _toDisp(Offset src) => EditGeometry.apply(_toDisplay, src);

  double get _shortSide {
    final c = EditGeometry(draft.assets!.size, _state).cropPx;
    return math.min(c.width, c.height);
  }

  OverlayItem? _hitItem(Offset display) {
    final a = draft.assets;
    if (a == null) return null;
    final st = _state;
    final p = _toSrc(display);
    final slop = 12 / _viewScale;
    for (final it in st.items.reversed) {
      var d = p - it.pos;
      if (st.flip) d = Offset(-d.dx, d.dy);
      final c = math.cos(-it.angle), s = math.sin(-it.angle);
      final local = Offset(d.dx * c - d.dy * s, d.dx * s + d.dy * c);
      final sz = itemSize(it, a.size);
      if (local.dx.abs() <= sz.width / 2 + slop && local.dy.abs() <= sz.height / 2 + slop) return it;
    }
    return null;
  }

  // ---------------------------------------------------------------- strokes

  double get _strokeWidth {
    final px = switch ((_tool, _penKind)) {
      (EditorTool.hide, _) => const [22.0, 38.0, 60.0][_censorSize],
      (_, StrokeKind.highlighter) => const [14.0, 24.0, 36.0][_penSize],
      _ => const [3.0, 6.0, 12.0][_penSize],
    };
    return px / _viewScale;
  }

  Stroke? get _liveStroke {
    final pts = _livePts;
    if (pts == null || pts.isEmpty) return null;
    return _tool == EditorTool.hide ? Stroke(_censorKind, pts, _strokeWidth, Colors.black) : Stroke(_penKind, pts, _strokeWidth, _penColor);
  }

  void _strokeStart(Offset display) => setState(() => _livePts = [_toSrc(display)]);

  void _strokeUpdate(Offset display) {
    final pts = _livePts;
    if (pts == null) return;
    final p = _toSrc(display);
    if ((p - pts.last).distance * _viewScale < 1.5) return;
    setState(() => pts.add(p));
  }

  void _strokeEnd() {
    final s = _liveStroke;
    _livePts = null;
    if (s == null || s.points.length < 2) return setState(() {}); // a tap is not a stroke
    _push(_base.copyWith(strokes: [..._base.strokes, Stroke(s.kind, List.unmodifiable(s.points), s.width, s.color)]));
  }

  // ---------------------------------------------------------------- items

  String _newId() => 'it${DateTime.now().microsecondsSinceEpoch}_${_ids++}';

  Offset get _centerSrc {
    final c = EditGeometry(draft.assets!.size, _state);
    final crop = c.cropPx;
    return EditGeometry.applyInverse(c.sourceToOriented(), crop.center);
  }

  void _newText(Offset? atSrc) {
    if (draft.assets == null) return;
    setState(() {
      _selected = null;
      _textEditing = OverlayItem(
        id: _newId(),
        kind: OverlayKind.text,
        pos: atSrc ?? _centerSrc,
        size: math.max(14, _shortSide * 0.075),
        color: Colors.white,
        bg: TextBg.plain,
        angle: _state.uprightAngle,
      );
    });
  }

  void _textDone(OverlayItem it) {
    setState(() {
      _textEditing = null;
      if (it.text.isEmpty) {
        if (_base.items.any((x) => x.id == it.id)) _push(_base.withoutItem(it.id));
        _selected = null;
      } else {
        _push(_base.withItem(it));
        _selected = it.id;
      }
    });
  }

  Future<void> _ensureSticker(String hash) async {
    final a = draft.assets;
    if (a == null || a.stickers.containsKey(hash)) return;
    final api = context.read<LumoraApi>();
    try {
      final (_, data) = await api.stickerGet(hash);
      if (data.isEmpty) return;
      final img = await decodeWorkingImage(base64Decode(data), maxSide: 768);
      if (a.stickers.containsKey(hash)) {
        img.dispose();
      } else {
        a.stickers[hash] = img;
      }
    } catch (_) {}
  }

  Future<void> _addSticker() async {
    final r = await pickEditorSticker(context);
    if (r == null || !mounted || draft.assets == null) {
      if (mounted) setState(() => _tool = EditorTool.none);
      return;
    }
    final (kind, value) = r;
    if (kind == OverlayKind.sticker) await _ensureSticker(value);
    if (!mounted) return;
    final it = OverlayItem(
      id: _newId(),
      kind: kind,
      text: kind == OverlayKind.emoji ? value : '',
      sticker: kind == OverlayKind.sticker ? value : '',
      pos: _centerSrc,
      size: _shortSide * (kind == OverlayKind.emoji ? 0.16 : 0.3),
      angle: _state.uprightAngle,
    );
    _push(_base.withItem(it));
    setState(() {
      _selected = it.id;
      _tool = EditorTool.none;
    });
  }

  void _deleteSelected() {
    final id = _selected;
    if (id == null) return;
    _push(_base.withoutItem(id));
    setState(() => _selected = null);
  }

  void _onTap(Offset display) {
    final hit = _hitItem(display);
    if (hit != null) {
      if (hit.kind == OverlayKind.text && (hit.id == _selected || _tool == EditorTool.text)) {
        setState(() => _textEditing = hit);
      } else {
        setState(() => _selected = hit.id);
      }
      return;
    }
    if (_tool == EditorTool.text) {
      _newText(_toSrc(display));
    } else {
      setState(() => _selected = null);
    }
  }

  // ---------------------------------------------------------------- view

  Offset _clampPan(Offset p, double z) {
    if (z <= 1.0001) return Offset.zero;
    final sc = _fit * z;
    final lx = math.max(0.0, (_frame.width * sc - _stageSize.width) / 2 + 48);
    final ly = math.max(0.0, (_frame.height * sc - _stageSize.height) / 2 + 48);
    return Offset(p.dx.clamp(-lx, lx), p.dy.clamp(-ly, ly));
  }

  /// Zoom [z] with the photo's top-left at display [origin].
  void _setView(double z, Offset origin) {
    z = z.clamp(1.0, _maxZoom);
    final pan = origin - _stageSize.center(Offset.zero) + Offset(_frame.width, _frame.height) * (_fit * z / 2);
    setState(() {
      _zoom = z;
      _pan = _clampPan(pan, z);
    });
  }

  /// Zooms to [z] keeping the photo point under [at] in place.
  void _zoomAt(Offset at, double z) {
    final u = (at - _origin) / _viewScale;
    z = z.clamp(1.0, _maxZoom);
    _setView(z, at - u * (_fit * z));
  }

  void _panBy(Offset d) => _setView(_zoom, _origin + d);

  void _resetView() => setState(() {
    _zoom = 1;
    _pan = Offset.zero;
  });

  void _viewStart(Offset focal) => _view = _ViewDrag(_zoom, (focal - _origin) / _viewScale);

  void _viewUpdate(Offset focal, double scale) {
    final v = _view;
    if (v == null) return;
    final z = (v.zoom * scale).clamp(1.0, _maxZoom);
    _setView(z, focal - v.anchor * (_fit * z));
  }

  // ---------------------------------------------------------------- gestures

  void _onScaleStart(ScaleStartDetails d) {
    final multi = d.pointerCount >= 2;
    // One finger: start where it touched down, not where the slop was crossed.
    final p = !multi && _lastDown != null ? _lastDown! : d.localFocalPoint;
    if (multi) _multiTouch = true;
    _g = _Gesture.view;
    if (editing && !_spaceHeld && _midPan == null) {
      if (_cropMode) {
        final z = multi || _multiTouch ? null : CropMath.hit(_cropDisp, p, locked: _aspect != null);
        if (z != null) {
          _g = _Gesture.crop;
          _cropDrag = (z, _cropDisp, p);
          return;
        }
      } else if (_drawMode) {
        if (!multi && !_multiTouch) {
          _g = _Gesture.stroke;
          _strokeStart(p);
          return;
        }
      } else {
        final hit = _hitItem(p);
        if (hit != null && (multi || !_multiTouch)) {
          _g = _Gesture.item;
          _drag = _ItemDrag(hit, _toSrc(p));
          setState(() => _selected = hit.id);
          return;
        }
      }
    }
    _viewStart(p);
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final p = d.localFocalPoint;
    switch (_g) {
      case _Gesture.view:
        _viewUpdate(p, d.scale);
      case _Gesture.stroke:
        _strokeUpdate(p);
      case _Gesture.crop:
        final (zone, r0, start) = _cropDrag!;
        final r = CropMath.update(zone, r0, start, p, _imageDisp, _aspect);
        setState(() => _transient = _base.copyWith(crop: CropMath.toNormal(r, _imageDisp)));
      case _Gesture.item:
        final g = _drag;
        if (g == null) return;
        final it = g.item;
        final short = _shortSide;
        setState(() => _transient = _base.withItem(it.copyWith(pos: it.pos + (_toSrc(p) - g.start), size: (it.size * d.scale).clamp(short * 0.02, short * 2.5), angle: it.angle + d.rotation)));
      case _Gesture.none:
        break;
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final g = _g;
    _g = _Gesture.none;
    _view = null;
    _cropDrag = null;
    switch (g) {
      case _Gesture.stroke:
        // pointerCount > 0: a second finger landed → it was a pinch, drop the stroke.
        if (d.pointerCount > 0) {
          setState(() => _livePts = null);
        } else {
          _strokeEnd();
        }
      case _Gesture.item:
      case _Gesture.crop:
        _gestureEnd();
      case _Gesture.view:
      case _Gesture.none:
        break;
    }
  }

  void _onPointerDown(PointerDownEvent e) {
    _pointers.add(e.pointer);
    _lastDown = _pointers.length == 1 ? e.localPosition : null;
    if (e.kind == PointerDeviceKind.mouse && (e.buttons & kMiddleMouseButton) != 0) {
      _midPointer = e.pointer;
      _midPan = e.localPosition;
      setState(() {});
      return;
    }
    _tapDown = _pointers.length == 1 ? (e.pointer, e.timeStamp, e.localPosition) : null;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.pointer == _midPointer && _midPan != null) {
      _panBy(e.localPosition - _midPan!);
      _midPan = e.localPosition;
    }
    final t = _tapDown;
    if (t != null && t.$1 == e.pointer && (e.localPosition - t.$3).distance > kTouchSlop) _tapDown = null;
  }

  void _pointerGone(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.isEmpty) _multiTouch = false;
    if (pointer == _midPointer) {
      setState(() {
        _midPointer = null;
        _midPan = null;
      });
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    _pointerGone(e.pointer);
    final t = _tapDown;
    _tapDown = null;
    if (t == null || t.$1 != e.pointer || e.timeStamp - t.$2 > const Duration(milliseconds: 300)) return;
    final last = _lastTap;
    if (last != null && e.timeStamp - last.$1 < const Duration(milliseconds: 350) && (e.localPosition - last.$2).distance < 40) {
      _lastTap = null;
      _onDoubleTap(e.localPosition);
    } else {
      _lastTap = (e.timeStamp, e.localPosition);
    }
  }

  /// Double tap / double click: fit ↔ 2×.
  void _onDoubleTap(Offset p) {
    if (editing && (_tool == EditorTool.text || _hitItem(p) != null)) return;
    if (_zoom > 1.01) {
      _resetView();
    } else {
      _zoomAt(p, 2);
    }
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
        final sc = ev as PointerScrollEvent;
        final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
        if (ctrl) {
          _zoomAt(sc.localPosition, _zoom * math.exp(-sc.scrollDelta.dy / 300));
        } else if (_zoom > 1.001) {
          _panBy(-sc.scrollDelta);
        }
      });
    } else if (e is PointerScaleEvent) {
      _zoomAt(e.localPosition, _zoom * e.scale);
    }
  }

  /// Test / screenshot hooks.
  @visibleForTesting
  void debugZoom(double z, {Offset? at}) => _zoomAt(at ?? _stageSize.center(Offset.zero), z);
  @visibleForTesting
  void debugProgress(double? p) => setState(() {
    _busy = p != null;
    _progress = p;
  });
  @visibleForTesting
  double get zoom => _zoom;
  @visibleForTesting
  EditState get debugState => _state;
  @visibleForTesting
  double get viewScale => _viewScale;
  @visibleForTesting
  Offset debugToSource(Offset global) => _toSrc(_stackLocal(global));
  @visibleForTesting
  Rect debugImageRectGlobal() {
    final box = _stackKey.currentContext!.findRenderObject()! as RenderBox;
    final r = _imageDisp;
    return box.localToGlobal(r.topLeft) & r.size;
  }

  void _gestureEnd() {
    final t = _transient;
    _drag = null;
    _transient = null;
    if (t != null) {
      _push(t);
    } else {
      setState(() {});
    }
  }

  Offset _stackLocal(Offset global) => (_stackKey.currentContext!.findRenderObject()! as RenderBox).globalToLocal(global);

  void _handleStart(DragStartDetails d, OverlayItem it) => _drag = _ItemDrag(it, _stackLocal(d.globalPosition));

  void _handleUpdate(DragUpdateDetails d) {
    final g = _drag;
    if (g == null) return;
    final c = _toDisp(g.item.pos);
    final v0 = g.start - c, v = _stackLocal(d.globalPosition) - c;
    if (v0.distance < 4) return;
    final short = _shortSide;
    setState(() => _transient = _base.withItem(g.item.copyWith(size: (g.item.size * v.distance / v0.distance).clamp(short * 0.02, short * 2.5), angle: g.item.angle + (v.direction - v0.direction))));
  }

  // ---------------------------------------------------------------- crop

  static const _aspects = <(String, double?)>[('free', null), ('1:1', 1), ('4:3', 4 / 3), ('3:4', 3 / 4), ('16:9', 16 / 9), ('9:16', 9 / 16)];

  double? get _aspect => _aspects.firstWhere((a) => a.$1 == _aspectId, orElse: () => _aspects.first).$2;

  void _pickAspect(String id) {
    setState(() => _aspectId = id);
    final a = _aspect;
    if (a == null || draft.assets == null) return;
    final o = EditGeometry(draft.assets!.size, _base).oriented;
    _push(_base.copyWith(crop: CropMath.fitAspect(o, a, _base.crop.center)));
  }

  void _rotate() {
    setState(() => _aspectId = 'free');
    _push(_base.rotatedLeft());
  }

  // ---------------------------------------------------------------- export & finish

  /// Bytes for [d] with its committed edits (or the live session for the
  /// current photo) at the chosen quality.
  @visibleForTesting
  Future<ExportedPhoto> exportDraft(PhotoDraft d, {bool? gifDownscale}) async {
    if (d.assets == null) await d.load();
    final st = identical(d, draft) && _session != null ? _session!.current : d.state;
    final gif = d.gif;
    if (gif != null) {
      // Untouched GIF: the original file (keeps the animation, has no EXIF).
      if (st.pristine) return ExportedPhoto(d.bytes!, 'gif', gif.width, gif.height);
      if (gif.animated) {
        var downscale = gifDownscale ?? false;
        if (gif.oversize && gifDownscale == null) {
          final choice = await _askBigGif(gif);
          if (choice == null) throw const _Cancelled();
          if (choice == _GifChoice.still) return exportPhoto(source: d.bytes!, assets: d.assets!, state: st, original: _original);
          downscale = true;
        }
        final job = await buildGifJob(d.bytes!, d.assets!, st, downscale: downscale);
        if (mounted) setState(() => _progress = 0);
        try {
          final bytes = await runGifJob(
            job,
            onProgress: (p) {
              if (mounted) setState(() => _progress = p);
            },
          );
          return ExportedPhoto(bytes, 'gif', job.outW, job.outH);
        } finally {
          if (mounted) setState(() => _progress = null);
        }
      }
    }
    return exportPhoto(source: d.bytes!, assets: d.assets!, state: st, original: _original);
  }

  Future<_GifChoice?> _askBigGif(GifStats g) {
    final s = S.read(context);
    return showDialog<_GifChoice>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(s('pe_gif_big_title')),
        content: Text(s('pe_gif_big_body', {'frames': g.frames, 'w': g.width, 'h': g.height, 'side': kGifMaxSide, 'max': kGifMaxFrames})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(s('cancel'))),
          TextButton(key: const ValueKey('pe-gif-still'), onPressed: () => Navigator.pop(c, _GifChoice.still), child: Text(s('pe_gif_still'))),
          FilledButton(key: const ValueKey('pe-gif-downscale'), onPressed: () => Navigator.pop(c, _GifChoice.downscale), child: Text(s('pe_gif_downscale'))),
        ],
      ),
    );
  }

  /// Test / screenshot hook: replace the current photo's edit state.
  @visibleForTesting
  void debugApply(EditState st, {bool editingMode = true, EditorTool tool = EditorTool.none, String? caption}) {
    setState(() {
      if (editingMode) {
        if (_session == null) _beginEdit(tool);
        _session!.push(st);
        _tool = tool;
      } else {
        draft.state = st;
      }
      if (caption != null) _caption.text = caption;
    });
  }

  Future<T?> _working<T>(Future<T> Function() job) async {
    setState(() => _busy = true);
    try {
      return await job();
    } on _Cancelled {
      return null;
    } catch (e) {
      if (mounted) toastError(context, e, fallbackKey: 'pe_send_failed');
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendTo(String conv, PhotoEditorResult result) async {
    if (editing) _commitEdit();
    final files = context.read<FilesStore>();
    final chat = context.read<ChatStore>();
    final caption = _caption.text.trim();
    final ok = await _working(() async {
      for (final d in drafts) {
        // A retry after a failure never sends the same photo twice.
        if (_sent.contains(d)) continue;
        if (d.assets == null && d.error == null) await d.load();
        if (d.assets == null) {
          // Can't be opened here: still never send where it was taken.
          final f = await _cleanUndecodable(d.path);
          if (f == null) {
            if (!mounted) return false;
            final asFile = await _askSendAsFile();
            if (!asFile) throw const _Cancelled();
            await files.send(conv, d.path);
          } else {
            await _sendFile(files, conv, f);
          }
          _sent.add(d);
          continue;
        }
        final out = await exportDraft(d);
        await _sendFile(files, conv, await writeOutgoing(out));
        _sent.add(d);
      }
      if (caption.isNotEmpty && !_captionSent) {
        await chat.send(conv, caption);
        _captionSent = true;
      }
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context, result);
  }

  Future<void> _send() => _sendTo(widget.conv, PhotoEditorResult.sent);

  /// Photos (and the caption) already sent in this editor session.
  final Set<PhotoDraft> _sent = {};
  bool _captionSent = false;

  Future<void> _sendFile(FilesStore files, String conv, File f) async {
    try {
      await files.send(conv, f.path);
    } catch (_) {
      try {
        await f.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// A metadata-free copy of a picture this editor can't decode, or null
  /// when its format can't be cleaned (e.g. HEIC on some systems).
  Future<File?> _cleanUndecodable(String path) async {
    try {
      final bytes = await readPhotoBytes(path);
      final clean = stripMetadataForced(bytes);
      if (clean == null) return null;
      final ext = switch (sniffFormat(clean)) {
        PhotoFormat.jpeg => 'jpg',
        PhotoFormat.png => 'png',
        PhotoFormat.other => 'webp',
      };
      return writeOutgoingBytes(clean, ext);
    } catch (_) {
      return null;
    }
  }

  /// "Can't remove location / camera info": send it unchanged as a file, or not at all.
  Future<bool> _askSendAsFile() async {
    final s = S.read(context);
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(AppIcons.warning, color: LC.warning),
        title: Text(s('pe_meta_title')),
        content: Text(s('pe_meta_body')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(s('pe_send_as_file'))),
        ],
      ),
    );
    return r ?? false;
  }

  Future<void> _forward() async {
    final to = await pickConversation(context, title: S.read(context)('forward_to'));
    if (to == null || !mounted) return;
    await _sendTo(to, to == widget.conv ? PhotoEditorResult.sent : PhotoEditorResult.forwarded);
  }

  Future<void> _save() async {
    if (draft.assets == null) return;
    final out = await _working(() => exportDraft(draft));
    if (out == null || !mounted) return;
    await savePhotoToDevice(context, out.bytes, ext: out.ext);
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildTheme(Brightness.dark),
      child: Builder(
        builder: (context) {
          final s = S.of(context);
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _close();
            },
            child: Focus(
              autofocus: true,
              onKeyEvent: _onKey,
              child: Scaffold(
                backgroundColor: Colors.black,
                resizeToAvoidBottomInset: true,
                body: FutureBuilder<void>(
                  future: ready,
                  builder: (context, snap) {
                    final loading = snap.connectionState != ConnectionState.done;
                    return Stack(
                      children: [
                        Column(
                          children: [
                            _topBar(s),
                            Expanded(child: loading ? const Center(child: CircularProgressIndicator()) : _stage(s)),
                            if (!loading) editing ? _editBottom(s) : _previewBottom(s),
                          ],
                        ),
                        if (_textEditing != null)
                          Positioned.fill(
                            child: TextEntryOverlay(key: ValueKey(_textEditing!.id), item: _textEditing!, onDone: _textDone),
                          ),
                        if (_busy)
                          Positioned.fill(
                            child: ColoredBox(
                              color: Colors.black54,
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_progress == null)
                                      const CircularProgressIndicator()
                                    else
                                      SizedBox(
                                        width: 220,
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(4),
                                          child: LinearProgressIndicator(value: _progress, minHeight: 6, backgroundColor: Colors.white12, color: LC.primary),
                                        ),
                                      ),
                                    const SizedBox(height: 14),
                                    Text(_progress == null ? s('pe_processing') : s('pe_processing_gif', {'p': ((_progress ?? 0) * 100).round()}), style: const TextStyle(color: Colors.white70)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Editor shortcuts (only when no text field has focus, so Ctrl+Z / Delete
  /// keep working inside the caption and the text entry).
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.space && FocusManager.instance.primaryFocus?.context?.widget is! EditableText) {
      // Hold Space + drag = pan (desktop).
      final held = e is! KeyUpEvent;
      if (held != _spaceHeld) setState(() => _spaceHeld = held);
      return KeyEventResult.handled;
    }
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (k == LogicalKeyboardKey.escape) {
      if (_textEditing == null) _close();
      return KeyEventResult.handled;
    }
    final typing = FocusManager.instance.primaryFocus?.context?.widget is EditableText;
    if (typing || _session == null) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (ctrl && k == LogicalKeyboardKey.keyZ) {
      shift ? _session!.redo() : _session!.undo();
      return KeyEventResult.handled;
    }
    if (ctrl && k == LogicalKeyboardKey.keyY) {
      _session!.redo();
      return KeyEventResult.handled;
    }
    if ((k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) && _selected != null) {
      _deleteSelected();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _topBar(S s) {
    final h = _session;
    final wide = isDesktop(context);
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black, Color(0x00000000)]),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
          child: Row(
            children: [
              IconButton(
                onPressed: _close,
                icon: const Icon(EditorIcons.close, color: Colors.white),
                tooltip: editing ? s('cancel') : s('close'),
              ),
              if (!editing || wide)
                Expanded(
                  child: Text(
                    editing ? s('pe_edit_photo') : (widget.purpose == PhotoEditorPurpose.beforeSend ? s('pe_send_n', {'n': drafts.length}) : s('pe_edit_photo')),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                )
              else
                const Spacer(),
              if (h != null) ...[
                _TopIcon(icon: EditorIcons.undo, tooltip: s('pe_undo'), onTap: h.canUndo ? h.undo : null),
                _TopIcon(icon: EditorIcons.redo, tooltip: s('pe_redo'), onTap: h.canRedo ? h.redo : null),
                _TopIcon(
                  icon: EditorIcons.reset,
                  tooltip: s('pe_reset'),
                  onTap: h.current.pristine
                      ? null
                      : () {
                          setState(() {
                            _selected = null;
                            _aspectId = 'free';
                          });
                          h.reset();
                        },
                ),
                if (!wide) const Spacer() else const SizedBox(width: 16),
                FilledButton.icon(key: const ValueKey('pe-done'), onPressed: _commitEdit, icon: const Icon(EditorIcons.check, size: 18), label: Text(s('done'))),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _unreadable(S s) {
    final d = draft;
    final canOpen = !d.path.startsWith('asset:');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_outlined, color: Colors.white38, size: 56),
            const SizedBox(height: 12),
            Text(
              d.heic ? s('pe_heic_unsupported') : s('image_unreadable'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
            ),
            if (d.heic) ...[
              const SizedBox(height: 6),
              Text(
                heicHint(s),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white60, fontSize: 13),
              ),
            ],
            if (canOpen) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: const ValueKey('pe-open-external'),
                onPressed: () => openFile(context, d.path),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38),
                ),
                icon: const Icon(AppIcons.openExternal, size: 18),
                label: Text(s('pe_open_with')),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stage(S s) {
    final a = draft.assets;
    if (a == null) return _unreadable(s);
    return LayoutBuilder(
      builder: (context, c) {
        final crop = _cropMode;
        final st = _state;
        final g = EditGeometry(a.size, crop ? st.copyWith(crop: EditState.full) : st);
        final frame = g.cropPx.size;
        final pad = crop ? 28.0 : 16.0;
        final stage = c.biggest;
        final fit = math.min(math.max(1.0, stage.width - pad * 2) / frame.width, math.max(1.0, stage.height - pad * 2) / frame.height);
        if (frame != _frame) {
          // New framing (crop applied, rotated, other photo, crop tool): back to fit.
          _zoom = 1;
          _pan = Offset.zero;
        }
        _stageSize = stage;
        _frame = frame;
        _fit = fit;
        _geom = g;
        _pan = _clampPan(_pan, _zoom);
        final drawing = _drawMode;
        final sel = editing && !crop && !drawing ? st.items.where((i) => i.id == _selected).firstOrNull : null;
        final grabbing = _spaceHeld || _midPan != null;
        final cursor = grabbing
            ? (_midPan != null ? SystemMouseCursors.grabbing : SystemMouseCursors.grab)
            : drawing
            ? SystemMouseCursors.precise
            : SystemMouseCursors.basic;
        final gif = draft.gif;
        return Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: (e) => _pointerGone(e.pointer),
          onPointerSignal: _onPointerSignal,
          child: ClipRect(
            child: Stack(
              key: _stackKey,
              children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(key: const ValueKey('pe-canvas'), painter: _CompositionPainter(a, st, _viewScale, _origin, _liveStroke, crop)),
                  ),
                ),
                if (crop)
                  Positioned.fill(
                    child: IgnorePointer(child: CustomPaint(painter: CropFramePainter(_cropDisp))),
                  ),
                Positioned.fill(
                  child: MouseRegion(
                    cursor: cursor,
                    child: GestureDetector(
                      key: const ValueKey('pe-gesture-layer'),
                      behavior: HitTestBehavior.opaque,
                      dragStartBehavior: DragStartBehavior.down,
                      onTapUp: editing && !crop && !drawing ? (d) => _onTap(d.localPosition) : null,
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: _onScaleUpdate,
                      onScaleEnd: _onScaleEnd,
                    ),
                  ),
                ),
                if (sel != null) _selectionBox(sel, a, g),
                if (gif != null && gif.animated)
                  Positioned(
                    left: math.max(12.0, _imageDisp.left + 10),
                    top: math.max(10.0, _imageDisp.top + 10),
                    child: IgnorePointer(
                      child: _Badge(icon: EditorIcons.animation, text: s('pe_gif_badge', {'n': gif.frames})),
                    ),
                  ),
                if (_zoom > 1.001)
                  Positioned(
                    right: 12,
                    top: 10,
                    child: _ZoomChip(key: const ValueKey('pe-zoom-chip'), percent: (_zoom * 100).round(), tooltip: s('pe_zoom_reset'), onTap: _resetView),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _selectionBox(OverlayItem it, EditorAssets a, EditGeometry g) {
    const m = 18.0;
    final c = _toDisp(it.pos);
    final sz = itemSize(it, a.size) * _viewScale;
    final w = sz.width + m * 2, h = sz.height + m * 2;
    return Positioned(
      left: c.dx - w / 2,
      top: c.dy - h / 2,
      width: w,
      height: h,
      child: Transform.rotate(
        angle: g.visualAngle(it.angle),
        child: Stack(
          children: [
            Positioned.fill(
              left: m - 4,
              top: m - 4,
              right: m - 4,
              bottom: m - 4,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 1.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              child: _Handle(icon: EditorIcons.delete, color: LC.danger, onTap: _deleteSelected),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: GestureDetector(
                onPanStart: (d) => _handleStart(d, it),
                onPanUpdate: _handleUpdate,
                onPanEnd: (_) => _gestureEnd(),
                child: const MouseRegion(
                  cursor: SystemMouseCursors.resizeDownRight,
                  child: _Handle(icon: EditorIcons.rotateLeft, color: LC.primary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- bottom bars

  Widget _editBottom(S s) {
    Widget? options = switch (_tool) {
      EditorTool.crop => _cropOptions(s),
      EditorTool.draw => Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          EditorSegment<StrokeKind>(
            value: _penKind,
            options: [(StrokeKind.pen, EditorIcons.pen, s('pe_pen')), (StrokeKind.highlighter, EditorIcons.highlighter, s('pe_highlighter'))],
            onChanged: (v) => setState(() => _penKind = v),
          ),
          ColorPalette(value: _penColor, onChanged: (c) => setState(() => _penColor = c)),
          SizeDots(index: _penSize, color: _penColor, onChanged: (i) => setState(() => _penSize = i)),
        ],
      ),
      EditorTool.hide => Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          EditorSegment<StrokeKind>(
            value: _censorKind,
            options: [(StrokeKind.pixelate, EditorIcons.pixelate, s('pe_pixelate')), (StrokeKind.blur, EditorIcons.blur, s('pe_blur'))],
            onChanged: (v) => setState(() => _censorKind = v),
          ),
          SizeDots(index: _censorSize, onChanged: (i) => setState(() => _censorSize = i)),
        ],
      ),
      EditorTool.filter => _filterStrip(s),
      _ => null,
    };
    // One-line guidance above the tool options.
    final st = _state;
    final selected = _selected != null && st.items.any((i) => i.id == _selected);
    final hint = switch (_tool) {
      EditorTool.hide => _Hint(icon: EditorIcons.hide, text: s('pe_hide_hint')),
      EditorTool.text when !selected => _Hint(icon: EditorIcons.text, text: s('pe_tap_to_add_text')),
      EditorTool.crop || EditorTool.draw || EditorTool.filter => null,
      _ when selected => _Hint(icon: EditorIcons.sticker, text: s('pe_drag_hint')),
      _ => null,
    };
    if (hint != null) {
      options = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          hint,
          if (options != null) ...[const SizedBox(height: 10), options],
        ],
      );
    }
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black, Color(0xCC000000)]),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: Motion.normal,
              curve: Motion.curve,
              child: options == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                      child: Center(child: options),
                    ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: MediaQuery.sizeOf(context).width - 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final (t, icon, label) in [
                      (EditorTool.crop, EditorIcons.crop, s('pe_crop')),
                      (EditorTool.draw, EditorIcons.draw, s('pe_draw')),
                      (EditorTool.hide, EditorIcons.hide, s('pe_hide')),
                      (EditorTool.text, EditorIcons.text, s('pe_text')),
                      (EditorTool.sticker, EditorIcons.sticker, s('pe_sticker')),
                      (EditorTool.filter, EditorIcons.filter, s('pe_filter')),
                    ])
                      _ToolButton(key: ValueKey('pe-tool-${t.name}'), icon: icon, label: label, selected: _tool == t, onTap: () => _setTool(t)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cropOptions(S s) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TopIcon(icon: EditorIcons.rotateLeft, tooltip: s('pe_rotate'), onTap: _rotate),
              _TopIcon(icon: EditorIcons.flip, tooltip: s('pe_flip'), onTap: () => _push(_base.flipped())),
              Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 8), color: Colors.white24),
              for (final (id, _) in _aspects)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: ChoiceChip(
                    key: ValueKey('pe-aspect-$id'),
                    label: Text(id == 'free' ? s('pe_free') : id),
                    selected: _aspectId == id,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    selectedColor: LC.primary,
                    backgroundColor: Colors.white.withValues(alpha: 0.08),
                    side: BorderSide.none,
                    labelStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                    onSelected: (_) => _pickAspect(id),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _filterStrip(S s) {
    final a = draft.assets!;
    return SizedBox(
      height: 92,
      child: ListView(
        scrollDirection: Axis.horizontal,
        shrinkWrap: true,
        children: [
          for (final id in PhotoFilters.ids)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: InkWell(
                key: ValueKey('pe-filter-$id'),
                borderRadius: BorderRadius.circular(Radii.md),
                onTap: () => _push(_base.copyWith(filter: id)),
                child: Column(
                  children: [
                    AnimatedContainer(
                      duration: Motion.fast,
                      width: 60,
                      height: 60,
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(Radii.md),
                        border: Border.all(color: _base.filter == id ? LC.primary : Colors.transparent, width: 2),
                      ),
                      child: ClipRRect(borderRadius: BorderRadius.circular(Radii.sm), child: _filtered(id, a)),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      s('pe_f_$id'),
                      style: TextStyle(color: _base.filter == id ? Colors.white : Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _filtered(String id, EditorAssets a) {
    final f = PhotoFilters.of(id);
    final img = RawImage(image: a.image, fit: BoxFit.cover, filterQuality: FilterQuality.medium);
    return f == null ? img : ColorFiltered(colorFilter: f, child: img);
  }

  Widget _previewBottom(S s) {
    final viewer = widget.purpose == PhotoEditorPurpose.fromViewer;
    final wide = isDesktop(context);
    final canEdit = draft.assets != null;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black, Color(0xCC000000)]),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (drafts.length > 1) _thumbs(),
                  Row(
                    children: [
                      _PillButton(key: const ValueKey('pe-edit'), icon: EditorIcons.edit, label: s('edit'), onTap: canEdit ? () => _beginEdit() : null),
                      if (draft.assets != null && draft.gif == null) ...[
                        const SizedBox(width: 8),
                        _PillButton(
                          key: const ValueKey('pe-quality'),
                          icon: _original ? EditorIcons.check : EditorIcons.hd,
                          label: s('pe_original'),
                          selected: _original,
                          tooltip: s('pe_quality_hint'),
                          onTap: () => setState(() => _original = !_original),
                        ),
                      ],
                      const Spacer(),
                      if (wide)
                        Flexible(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(EditorIcons.privacy, size: 15, color: Colors.white54),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  s('pe_privacy_note'),
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('pe-caption'),
                          controller: _caption,
                          minLines: 1,
                          maxLines: 4,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: s('add_caption'),
                            hintStyle: const TextStyle(color: Colors.white54),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.1),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.xl), borderSide: BorderSide.none),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.xl), borderSide: BorderSide.none),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(Radii.xl),
                              borderSide: const BorderSide(color: LC.primary, width: 1.5),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _RoundAction(key: const ValueKey('pe-save'), icon: EditorIcons.save, tooltip: s('pe_save_device'), label: wide ? s('pe_save_device') : null, onTap: canEdit ? _save : null),
                      if (viewer) _RoundAction(key: const ValueKey('pe-forward'), icon: EditorIcons.forward, tooltip: s('pe_forward'), label: wide ? s('pe_forward') : null, onTap: _forward),
                      const SizedBox(width: 4),
                      Tooltip(
                        message: s('send'),
                        child: FilledButton(
                          key: const ValueKey('pe-send'),
                          onPressed: _busy ? null : _send,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48),
                            padding: EdgeInsets.symmetric(horizontal: wide ? 20 : 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.xl)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(EditorIcons.send, size: 20),
                              if (wide) ...[const SizedBox(width: 8), Text(s('send'))],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (!wide) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(EditorIcons.privacy, size: 13, color: Colors.white38),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            s('pe_privacy_note'),
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white38, fontSize: 11.5),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _thumbs() {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 8),
        itemCount: drafts.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final d = drafts[i];
          return GestureDetector(
            onTap: () => setState(() => _index = i),
            child: Stack(
              children: [
                AnimatedContainer(
                  duration: Motion.fast,
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Radii.sm + 2),
                    border: Border.all(color: i == _index ? LC.primary : Colors.transparent, width: 2),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    child: d.assets == null
                        ? const ColoredBox(
                            color: Colors.white10,
                            child: Icon(Icons.broken_image_outlined, color: Colors.white38),
                          )
                        : RawImage(image: d.assets!.image, fit: BoxFit.cover, filterQuality: FilterQuality.medium),
                  ),
                ),
                if (!d.state.pristine) const Positioned(left: 4, bottom: 4, child: Icon(EditorIcons.edit, size: 13, color: Colors.white)),
                Positioned(
                  right: 2,
                  top: 2,
                  child: InkWell(
                    onTap: () => setState(() {
                      drafts.removeAt(i).dispose();
                      _index = _index.clamp(0, drafts.length - 1);
                    }),
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                      child: const Icon(EditorIcons.close, size: 12, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ------------------------------------------------------------------ pieces

class _CompositionPainter extends CustomPainter {
  _CompositionPainter(this.a, this.st, this.scale, this.origin, this.live, this.full);
  final EditorAssets a;
  final EditState st;
  final double scale;
  final Offset origin;
  final Stroke? live;
  final bool full;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(origin.dx, origin.dy);
    paintComposition(canvas, a, st, scale: scale, live: live, showFullFrame: full);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CompositionPainter o) => o.a != a || o.st != st || o.scale != scale || o.origin != origin || o.live != live || o.full != full;
}

enum _Gesture { none, view, stroke, item, crop }

enum _GifChoice { downscale, still }

class _Cancelled implements Exception {
  const _Cancelled();
}

class _ViewDrag {
  _ViewDrag(this.zoom, this.anchor);
  final double zoom;

  /// Photo point under the focal point, in output units (display / scale).
  final Offset anchor;
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(Radii.xl)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: Colors.white),
        const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

class _ZoomChip extends StatelessWidget {
  const _ZoomChip({super.key, required this.percent, required this.tooltip, required this.onTap});
  final int percent;
  final String tooltip;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: Colors.black.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(Radii.xl),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.xl),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$percent%',
                style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
              ),
              const SizedBox(width: 6),
              const Icon(EditorIcons.fit, size: 15, color: Colors.white70),
            ],
          ),
        ),
      ),
    ),
  );
}

class _TopIcon extends StatelessWidget {
  const _TopIcon({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onTap,
    tooltip: tooltip,
    icon: Icon(icon, color: onTap == null ? Colors.white30 : Colors.white),
  );
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({super.key, required this.icon, required this.label, required this.selected, required this.onTap});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.md),
        child: AnimatedContainer(
          duration: Motion.fast,
          width: 58,
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(color: selected ? LC.primary.withValues(alpha: 0.22) : null, borderRadius: BorderRadius.circular(Radii.md)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: selected ? const Color(0xFFB9B0FF) : Colors.white),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: selected ? const Color(0xFFB9B0FF) : Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle({required this.icon, required this.color, this.onTap});
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Icon(icon, size: 15, color: Colors.white),
    ),
  );
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(Radii.xl)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: Colors.white70),
        const SizedBox(width: 6),
        Flexible(
          child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12.5)),
        ),
      ],
    ),
  );
}

class _PillButton extends StatelessWidget {
  const _PillButton({super.key, required this.icon, required this.label, required this.onTap, this.selected = false, this.tooltip});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool selected;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final child = Material(
      color: selected ? LC.primary : Colors.white.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(Radii.xl),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.xl),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: onTap == null ? Colors.white30 : Colors.white),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(color: onTap == null ? Colors.white30 : Colors.white, fontWeight: FontWeight.w600, fontSize: 13.5),
              ),
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? child : Tooltip(message: tooltip!, child: child);
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({super.key, required this.icon, required this.tooltip, required this.onTap, this.label});
  final IconData icon;
  final String tooltip;
  final String? label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l = label;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: l == null
          ? IconButton(
              onPressed: onTap,
              tooltip: tooltip,
              style: IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.1), minimumSize: const Size(48, 48)),
              icon: Icon(icon, color: Colors.white, size: 21),
            )
          : TextButton.icon(
              onPressed: onTap,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: Colors.white.withValues(alpha: 0.1),
                minimumSize: const Size(48, 48),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.xl)),
              ),
              icon: Icon(icon, size: 19),
              label: Text(l),
            ),
    );
  }
}

// One image picker + cropper flow reused for avatars, covers, group icons
// and wallpapers: pick (file dialog / drag-and-drop / paste a file path),
// crop (circle, square, 16:9 or free), then resize & JPEG-compress
// client-side to the size budget the core expects.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'app_icons.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../../l10n/strings.dart';
import '../theme.dart';
import 'common.dart';

enum CropShape { circle, square, cover, free }

class CropSpec {
  const CropSpec(this.shape, {required this.outWidth, required this.outHeight, required this.maxBytes});
  final CropShape shape;
  final int outWidth;

  /// For [CropShape.free] the output keeps the crop aspect with the longest
  /// side ≤ max(outWidth, outHeight).
  final int outHeight;
  final int maxBytes;

  double? get aspect => switch (shape) {
        CropShape.circle || CropShape.square => 1,
        CropShape.cover => 16 / 9,
        CropShape.free => null,
      };

  static const avatar = CropSpec(CropShape.circle, outWidth: 256, outHeight: 256, maxBytes: 96 * 1024);
  static const groupAvatar = CropSpec(CropShape.square, outWidth: 256, outHeight: 256, maxBytes: 96 * 1024);
  static const cover = CropSpec(CropShape.cover, outWidth: 1280, outHeight: 720, maxBytes: 320 * 1024);
  static const wallpaper = CropSpec(CropShape.free, outWidth: 1920, outHeight: 1920, maxBytes: 1536 * 1024);
}

/// Returns compressed JPEG bytes, or null if cancelled.
Future<Uint8List?> pickAndCropImage(BuildContext context, CropSpec spec, {Uint8List? initial}) {
  return Navigator.of(context, rootNavigator: true).push<Uint8List>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => ImageCropScreen(spec: spec, initial: initial),
  ));
}

class _EncodeJob {
  _EncodeJob(this.rgba, this.w, this.h, this.maxBytes);
  final Uint8List rgba;
  final int w;
  final int h;
  final int maxBytes;
}

Uint8List? _encodeJpeg(_EncodeJob j) {
  var im = img.Image.fromBytes(width: j.w, height: j.h, bytes: j.rgba.buffer, numChannels: 4);
  for (var round = 0; round < 4; round++) {
    for (final q in [88, 80, 72, 62, 52]) {
      final out = img.encodeJpg(im, quality: q);
      if (out.length <= j.maxBytes) return out;
    }
    im = img.copyResize(im, width: (im.width * 0.8).round());
  }
  return null;
}

class ImageCropScreen extends StatefulWidget {
  const ImageCropScreen({super.key, required this.spec, this.initial});
  final CropSpec spec;
  final Uint8List? initial;
  @override
  State<ImageCropScreen> createState() => _ImageCropScreenState();
}

class _ImageCropScreenState extends State<ImageCropScreen> {
  ui.Image? _image;
  final _tc = TransformationController();
  bool _busy = false;
  bool _dragging = false;
  Size _viewport = Size.zero;
  double _freeAspect = 9 / 16;

  @override
  void initState() {
    super.initState();
    if (widget.initial != null) _load(widget.initial!);
  }

  @override
  void dispose() {
    _image?.dispose();
    _tc.dispose();
    super.dispose();
  }

  Future<void> _load(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final f = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) return;
      setState(() {
        _image?.dispose();
        _image = f.image;
        _tc.value = Matrix4.identity();
        if (widget.spec.shape == CropShape.free) {
          _freeAspect = _viewport.isEmpty ? 9 / 16 : (_viewport.width / _viewport.height).clamp(0.4, 2.2);
        }
      });
    } catch (_) {
      if (mounted) toast(context, S.read(context)('image_unreadable'));
    }
  }

  Future<void> _pick() async {
    final f = await FilePicker.pickFile(type: FileType.image);
    if (f?.path != null) await _load(await File(f!.path!).readAsBytes());
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData('text/plain');
    var t = d?.text?.trim() ?? '';
    if (t.startsWith('file://')) t = Uri.parse(t).toFilePath();
    if (t.isNotEmpty && File(t).existsSync()) await _load(await File(t).readAsBytes());
  }

  double get _aspect => widget.spec.aspect ?? _freeAspect;

  /// Crop frame inside the viewport.
  Rect _frame(Size vp) {
    final maxW = vp.width * 0.86, maxH = vp.height * 0.8;
    var w = maxW, h = w / _aspect;
    if (h > maxH) {
      h = maxH;
      w = h * _aspect;
    }
    return Rect.fromCenter(center: vp.center(Offset.zero), width: w, height: h);
  }

  /// Image rect (BoxFit.cover of the frame) in child coordinates.
  Rect _imageRect(Size vp) {
    final im = _image!;
    final frame = _frame(vp);
    final scale = math.max(frame.width / im.width, frame.height / im.height);
    final w = im.width * scale, h = im.height * scale;
    return Rect.fromCenter(center: frame.center, width: w, height: h);
  }

  Future<void> _done() async {
    final im = _image;
    if (im == null) return;
    setState(() => _busy = true);
    try {
      final vp = _viewport;
      final frame = _frame(vp);
      final inv = Matrix4.inverted(_tc.value);
      Offset toChild(Offset p) => MatrixUtils.transformPoint(inv, p);
      final a = toChild(frame.topLeft), b = toChild(frame.bottomRight);
      final ir = _imageRect(vp);
      final sx = im.width / ir.width;
      var src = Rect.fromPoints((a - ir.topLeft) * sx, (b - ir.topLeft) * sx);
      src = src.intersect(Rect.fromLTWH(0, 0, im.width.toDouble(), im.height.toDouble()));
      int ow = widget.spec.outWidth, oh = widget.spec.outHeight;
      if (widget.spec.shape == CropShape.free) {
        final longest = math.max(widget.spec.outWidth, widget.spec.outHeight).toDouble();
        final k = math.min(1.0, longest / math.max(src.width, src.height));
        ow = (src.width * k).round();
        oh = (src.height * k).round();
      }
      final rec = ui.PictureRecorder();
      Canvas(rec).drawImageRect(im, src, Rect.fromLTWH(0, 0, ow.toDouble(), oh.toDouble()), Paint()..filterQuality = FilterQuality.high);
      final out = await rec.endRecording().toImage(ow, oh);
      final rgba = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
      out.dispose();
      final jpg = await compute(_encodeJpeg, _EncodeJob(rgba!.buffer.asUint8List(), ow, oh, widget.spec.maxBytes));
      if (!mounted) return;
      if (jpg == null) {
        toast(context, S.read(context)('avatar_too_large'));
        setState(() => _busy = false);
        return;
      }
      Navigator.pop(context, jpg);
    } catch (e) {
      if (mounted) {
        toastError(context, e);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final title = switch (widget.spec.shape) {
      CropShape.circle => s('crop_avatar'),
      CropShape.square => s('crop_group'),
      CropShape.cover => s('crop_cover'),
      CropShape.free => s('crop_wallpaper'),
    };
    return Scaffold(
      backgroundColor: const Color(0xFF07070F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF07070F),
        foregroundColor: Colors.white,
        title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18)),
        actions: [
          if (_image != null) TextButton.icon(onPressed: _pick, icon: const Icon(AppIcons.gallery, color: Colors.white70), label: Text(s('change'), style: const TextStyle(color: Colors.white70))),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(onPressed: _image == null || _busy ? null : _done, child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Text(s('done'))),
          ),
        ],
      ),
      body: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.keyV, control: true): _paste},
        child: Focus(
          autofocus: true,
          child: DropTarget(
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: (d) async {
              setState(() => _dragging = false);
              if (d.files.isNotEmpty) await _load(await File(d.files.first.path).readAsBytes());
            },
            child: LayoutBuilder(builder: (context, c) {
              _viewport = Size(c.maxWidth, c.maxHeight);
              if (_image == null) return _EmptyPicker(onPick: _pick, dragging: _dragging);
              final frame = _frame(_viewport);
              final ir = _imageRect(_viewport);
              return Stack(children: [
                Positioned.fill(
                  child: InteractiveViewer(
                    transformationController: _tc,
                    minScale: 1,
                    maxScale: 6,
                    boundaryMargin: EdgeInsets.symmetric(horizontal: frame.left, vertical: frame.top),
                    child: SizedBox(
                      width: _viewport.width,
                      height: _viewport.height,
                      child: Stack(children: [
                        Positioned.fromRect(rect: ir, child: RawImage(image: _image, fit: BoxFit.fill)),
                      ]),
                    ),
                  ),
                ),
                IgnorePointer(child: CustomPaint(size: _viewport, painter: _MaskPainter(frame, widget.spec.shape == CropShape.circle))),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 16,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(Radii.xl)),
                      child: Text(s('crop_hint'), style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                    ),
                  ),
                ),
              ]);
            }),
          ),
        ),
      ),
    );
  }
}

class _EmptyPicker extends StatelessWidget {
  const _EmptyPicker({required this.onPick, required this.dragging});
  final VoidCallback onPick;
  final bool dragging;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Center(
      child: AnimatedContainer(
        duration: Motion.fast,
        width: 420,
        padding: const EdgeInsets.all(32),
        margin: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: dragging ? LC.primary.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(Radii.xl),
          border: Border.all(color: dragging ? LC.primary : Colors.white24, width: dragging ? 2 : 1),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(AppIcons.addImage, color: Colors.white70, size: 48),
          const SizedBox(height: 12),
          Text(s('pick_image_title'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 6),
          Text(s('pick_image_hint'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60, height: 1.4)),
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: onPick, icon: const Icon(AppIcons.gallery), label: Text(s('choose_photo'))),
        ]),
      ),
    );
  }
}

class _MaskPainter extends CustomPainter {
  _MaskPainter(this.frame, this.circle);
  final Rect frame;
  final bool circle;
  @override
  void paint(Canvas canvas, Size size) {
    final outer = Path()..addRect(Offset.zero & size);
    final hole = Path();
    circle ? hole.addOval(frame) : hole.addRRect(RRect.fromRectAndRadius(frame, const Radius.circular(12)));
    canvas.drawPath(Path.combine(PathOperation.difference, outer, hole), Paint()..color = Colors.black.withValues(alpha: 0.62));
    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    circle ? canvas.drawOval(frame, border) : canvas.drawRRect(RRect.fromRectAndRadius(frame, const Radius.circular(12)), border);
    if (!circle) {
      final grid = Paint()
        ..color = Colors.white24
        ..strokeWidth = 1;
      for (var i = 1; i < 3; i++) {
        final x = frame.left + frame.width * i / 3, y = frame.top + frame.height * i / 3;
        canvas.drawLine(Offset(x, frame.top), Offset(x, frame.bottom), grid);
        canvas.drawLine(Offset(frame.left, y), Offset(frame.right, y), grid);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MaskPainter old) => old.frame != frame || old.circle != circle;
}

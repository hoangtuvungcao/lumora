// Chat wallpapers: brand presets (painted, light/dark variants),
// solid colours ("color:#RRGGBB") and user photos
// ("image:<base64>|blur=8|dim=0.3").

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/image_crop.dart';

class WallpaperPreset {
  const WallpaperPreset(this.id, this.dark, this.light, {this.pattern});
  final String id;
  final List<Color> dark;
  final List<Color> light;

  /// null | 'doodle' | 'paper' | 'aurora' | 'waves' | 'dots'
  final String? pattern;
}

const kWallpapers = <WallpaperPreset>[
  WallpaperPreset('aurora', [Color(0xFF14123A), Color(0xFF1B2F4A), Color(0xFF0F1020)], [Color(0xFFE9E5FF), Color(0xFFD8F7FA), Color(0xFFF7F8FC)], pattern: 'aurora'),
  WallpaperPreset('midnight', [Color(0xFF0B0C1A), Color(0xFF161935), Color(0xFF0B0C1A)], [Color(0xFFDDE1F2), Color(0xFFEEF0F8), Color(0xFFDDE1F2)], pattern: 'dots'),
  WallpaperPreset('sunset', [Color(0xFF3A1838), Color(0xFF4A2030), Color(0xFF1D1028)], [Color(0xFFFFE1D2), Color(0xFFFFD1DC), Color(0xFFFFF1E6)]),
  WallpaperPreset('ocean', [Color(0xFF071B2E), Color(0xFF0A2B44), Color(0xFF06131F)], [Color(0xFFD7F0FF), Color(0xFFCDEBF5), Color(0xFFEAF7FF)], pattern: 'waves'),
  WallpaperPreset('mint', [Color(0xFF0C2420), Color(0xFF113128), Color(0xFF0A1A17)], [Color(0xFFDDF7EA), Color(0xFFE9FBF2), Color(0xFFD3F2E4)]),
  WallpaperPreset('sakura', [Color(0xFF2A1426), Color(0xFF341A30), Color(0xFF1C0F1C)], [Color(0xFFFFE6EE), Color(0xFFFCEFF5), Color(0xFFFFDCE8)], pattern: 'sakura'),
  WallpaperPreset('paper', [Color(0xFF1C1B22), Color(0xFF201F27), Color(0xFF1C1B22)], [Color(0xFFF6F1E7), Color(0xFFF2ECDF), Color(0xFFF6F1E7)], pattern: 'paper'),
  WallpaperPreset('doodle', [Color(0xFF13142A), Color(0xFF171A33), Color(0xFF13142A)], [Color(0xFFEDEBFF), Color(0xFFF1F3FB), Color(0xFFE6F9FB)], pattern: 'doodle'),
  WallpaperPreset('lavender', [Color(0xFF1E1638), Color(0xFF2A1F4D), Color(0xFF150F28)], [Color(0xFFEFE8FF), Color(0xFFE4DCFF), Color(0xFFF6F2FF)]),
  WallpaperPreset('forest', [Color(0xFF0F1D14), Color(0xFF16291C), Color(0xFF0B140E)], [Color(0xFFE5F2E3), Color(0xFFDDEDD8), Color(0xFFF0F7EE)], pattern: 'dots'),
];

const kWallpaperColors = [0xFF0F1020, 0xFF1F2340, 0xFF2D2670, 0xFF0B3F47, 0xFF3A1838, 0xFFF7F8FC, 0xFFE6E2FF, 0xFFD5F7FA, 0xFFFFE6EE, 0xFFF6F1E7];

/// Parsed wallpaper value.
class WallpaperSpec {
  WallpaperSpec._({this.preset, this.color, this.image, this.blur = 0, this.dim = 0});
  final WallpaperPreset? preset;
  final Color? color;
  final Uint8List? image;
  final double blur;
  final double dim;

  static final Map<String, WallpaperSpec?> _cache = {};

  static WallpaperSpec? parse(String? v) {
    if (v == null || v.isEmpty || v == 'none') return null;
    if (_cache.containsKey(v)) return _cache[v];
    WallpaperSpec? r;
    if (v.startsWith('color:#')) {
      final hex = int.tryParse(v.substring(7), radix: 16);
      if (hex != null) r = WallpaperSpec._(color: Color(0xFF000000 | hex));
    } else if (v.startsWith('image:')) {
      final parts = v.substring(6).split('|');
      double blur = 0, dim = 0;
      for (final p in parts.skip(1)) {
        final kv = p.split('=');
        if (kv.length == 2 && kv[0] == 'blur') blur = double.tryParse(kv[1]) ?? 0;
        if (kv.length == 2 && kv[0] == 'dim') dim = double.tryParse(kv[1]) ?? 0;
      }
      try {
        r = WallpaperSpec._(image: base64Decode(parts.first), blur: blur, dim: dim);
      } catch (_) {}
    } else {
      for (final p in kWallpapers) {
        if (p.id == v) r = WallpaperSpec._(preset: p);
      }
    }
    if (_cache.length > 24) _cache.clear();
    _cache[v] = r;
    return r;
  }
}

/// Paints a wallpaper behind [child].
class ChatWallpaper extends StatelessWidget {
  const ChatWallpaper({super.key, required this.value, required this.child});
  final String? value;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final spec = WallpaperSpec.parse(value);
    if (spec == null) return child;
    return Stack(fit: StackFit.expand, children: [
      RepaintBoundary(child: WallpaperBackground(spec: spec)),
      child,
    ]);
  }
}

class WallpaperBackground extends StatelessWidget {
  const WallpaperBackground({super.key, required this.spec});
  final WallpaperSpec spec;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (spec.color != null) return ColoredBox(color: spec.color!);
    if (spec.image != null) {
      final w = MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context);
      Widget img = Image.memory(spec.image!, fit: BoxFit.cover, cacheWidth: w.round().clamp(320, 1920), gaplessPlayback: true);
      if (spec.blur > 0) img = ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: spec.blur, sigmaY: spec.blur, tileMode: TileMode.clamp), child: img);
      return Stack(fit: StackFit.expand, children: [img, ColoredBox(color: Colors.black.withValues(alpha: spec.dim.clamp(0, 0.85)))]);
    }
    final p = spec.preset!;
    final colors = dark ? p.dark : p.light;
    return CustomPaint(painter: _PresetPainter(p, colors, dark), child: const SizedBox.expand());
  }
}

class _PresetPainter extends CustomPainter {
  _PresetPainter(this.p, this.colors, this.dark);
  final WallpaperPreset p;
  final List<Color> colors;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors).createShader(rect));
    final accentA = dark ? 0.16 : 0.10;
    switch (p.pattern) {
      case 'aurora':
        for (final (c, o, r) in [
          (LC.primary, const Offset(0.15, 0.2), 0.55),
          (LC.accent, const Offset(0.85, 0.45), 0.5),
          (const Color(0xFFEC4899), const Offset(0.3, 0.9), 0.45),
        ]) {
          final center = Offset(size.width * o.dx, size.height * o.dy);
          final radius = size.shortestSide * r + size.longestSide * 0.15;
          canvas.drawCircle(
            center,
            radius,
            Paint()..shader = RadialGradient(colors: [c.withValues(alpha: dark ? 0.28 : 0.22), c.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: center, radius: radius)),
          );
        }
      case 'dots':
        final paint = Paint()..color = (dark ? Colors.white : const Color(0xFF14162B)).withValues(alpha: dark ? 0.05 : 0.06);
        for (var y = 12.0; y < size.height; y += 24) {
          for (var x = (y ~/ 24).isEven ? 12.0 : 24.0; x < size.width; x += 24) {
            canvas.drawCircle(Offset(x, y), 1.4, paint);
          }
        }
      case 'waves':
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = LC.accent.withValues(alpha: accentA);
        for (var y = 30.0; y < size.height + 40; y += 34) {
          final path = Path()..moveTo(0, y);
          for (var x = 0.0; x <= size.width; x += 8) {
            path.lineTo(x, y + math.sin(x / 38 + y / 50) * 7);
          }
          canvas.drawPath(path, paint);
        }
      case 'sakura':
        final rnd = math.Random(5);
        for (var i = 0; i < (size.width * size.height / 9000).clamp(12, 220); i++) {
          final c = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
          final r = 3.0 + rnd.nextDouble() * 5;
          final paint = Paint()..color = const Color(0xFFF472B6).withValues(alpha: dark ? 0.16 : 0.22);
          for (var k = 0; k < 5; k++) {
            final a = k * math.pi * 2 / 5 + rnd.nextDouble();
            canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * r * 0.8, r * 0.55, paint);
          }
        }
      case 'paper':
        final rnd = math.Random(9);
        final paint = Paint();
        for (var i = 0; i < (size.width * size.height / 260).clamp(200, 9000); i++) {
          paint.color = (dark ? Colors.white : Colors.black).withValues(alpha: rnd.nextDouble() * 0.035);
          canvas.drawRect(Rect.fromLTWH(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height, 1.4, 1.4), paint);
        }
      case 'doodle':
        final rnd = math.Random(3);
        final stroke = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round;
        const cell = 64.0;
        for (var y = 0.0; y < size.height + cell; y += cell) {
          for (var x = 0.0; x < size.width + cell; x += cell) {
            final c = Offset(x + 16 + rnd.nextDouble() * 32, y + 16 + rnd.nextDouble() * 32);
            stroke.color = (rnd.nextBool() ? LC.primary : LC.accent).withValues(alpha: dark ? 0.16 : 0.18);
            switch (rnd.nextInt(5)) {
              case 0: // spark
                final path = Path();
                for (var k = 0; k < 8; k++) {
                  final a = -math.pi / 2 + k * math.pi / 4;
                  final r = k.isEven ? 8.0 : 2.5;
                  final pt = c + Offset(math.cos(a), math.sin(a)) * r;
                  k == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
                }
                canvas.drawPath(path..close(), stroke);
              case 1: // chat bubble
                canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: 18, height: 12), const Radius.circular(5)), stroke);
              case 2: // heart-ish circle pair
                canvas.drawCircle(c, 6, stroke);
                canvas.drawCircle(c + const Offset(9, 4), 3, stroke);
              case 3: // wave
                final path = Path()..moveTo(c.dx - 10, c.dy);
                path.quadraticBezierTo(c.dx - 5, c.dy - 6, c.dx, c.dy);
                path.quadraticBezierTo(c.dx + 5, c.dy + 6, c.dx + 10, c.dy);
                canvas.drawPath(path, stroke);
              default: // plus
                canvas.drawLine(c - const Offset(5, 0), c + const Offset(5, 0), stroke);
                canvas.drawLine(c - const Offset(0, 5), c + const Offset(0, 5), stroke);
            }
          }
        }
    }
  }

  @override
  bool shouldRepaint(covariant _PresetPainter old) => old.p != p || old.dark != dark;
}

// ------------------------------------------------------------------ picker

Future<void> showWallpaperPicker(BuildContext context, String conv) {
  final body = WallpaperPicker(conv: conv);
  if (isDesktop(context)) {
    return showDialog<void>(context: context, builder: (_) => Dialog(child: SizedBox(width: 760, height: 600, child: body)));
  }
  return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => Scaffold(body: SafeArea(child: body))));
}

class WallpaperPicker extends StatefulWidget {
  const WallpaperPicker({super.key, required this.conv});
  final String conv;
  @override
  State<WallpaperPicker> createState() => _WallpaperPickerState();
}

class _WallpaperPickerState extends State<WallpaperPicker> {
  late String? _value = context.read<ChatStore>().wallpaperOf(widget.conv);
  Uint8List? _image;
  double _blur = 0;
  double _dim = 0.25;

  String? get _effective => _image != null ? 'image:${base64Encode(_image!)}|blur=${_blur.toStringAsFixed(0)}|dim=${_dim.toStringAsFixed(2)}' : _value;

  Future<void> _pick() async {
    final bytes = await pickAndCropImage(context, CropSpec.wallpaper);
    if (bytes == null || !mounted) return;
    setState(() => _image = bytes);
  }

  Future<void> _apply({required bool all}) async {
    await context.read<ChatStore>().setWallpaper(widget.conv, _effective, all: all);
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final desktop = isDesktop(context);
    final preview = Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(Radii.lg), border: Border.all(color: context.lc.divider), color: context.lc.bg),
      clipBehavior: Clip.antiAlias,
      child: ChatWallpaper(value: _effective ?? 'none', child: const _PreviewBubbles()),
    );
    final options = ListView(padding: const EdgeInsets.all(16), children: [
      SectionLabel(s('wallpaper_presets'), padding: const EdgeInsets.fromLTRB(0, 0, 0, 8)),
      GridView.count(
        crossAxisCount: desktop ? 4 : 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.7,
        children: [
          _Tile(selected: _image == null && (_value == null || _value == 'none'), label: s('wallpaper_none'), onTap: () => setState(() {
                _image = null;
                _value = 'none';
              }), child: ColoredBox(color: context.lc.bg, child: const SizedBox.expand())),
          for (final p in kWallpapers)
            _Tile(
              selected: _image == null && _value == p.id,
              label: s('wp_${p.id}'),
              onTap: () => setState(() {
                _image = null;
                _value = p.id;
              }),
              child: WallpaperBackground(spec: WallpaperSpec.parse(p.id)!),
            ),
        ],
      ),
      SectionLabel(s('wallpaper_colors'), padding: const EdgeInsets.fromLTRB(0, 16, 0, 8)),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final c in kWallpaperColors)
          Builder(builder: (context) {
            final v = 'color:#${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
            final sel = _image == null && _value == v;
            return InkWell(
              customBorder: const CircleBorder(),
              onTap: () => setState(() {
                _image = null;
                _value = v;
              }),
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Color(c),
                  shape: BoxShape.circle,
                  border: Border.all(color: sel ? LC.primary : context.lc.divider, width: sel ? 3 : 1),
                ),
              ),
            );
          }),
      ]),
      SectionLabel(s('wallpaper_photo'), padding: const EdgeInsets.fromLTRB(0, 16, 0, 8)),
      OutlinedButton.icon(onPressed: _pick, icon: const Icon(AppIcons.gallery), label: Text(s('choose_photo'))),
      if (_image != null) ...[
        const SizedBox(height: 8),
        Row(children: [SizedBox(width: 72, child: Text(s('blur'))), Expanded(child: Slider(value: _blur, max: 20, onChanged: (v) => setState(() => _blur = v)))]),
        Row(children: [SizedBox(width: 72, child: Text(s('dim'))), Expanded(child: Slider(value: _dim, max: 0.8, onChanged: (v) => setState(() => _dim = v)))]),
      ],
    ]);
    final actions = Padding(
      padding: const EdgeInsets.all(16),
      child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
        OutlinedButton(onPressed: () => _apply(all: true), child: Text(s('apply_all_chats'))),
        FilledButton(onPressed: () => _apply(all: false), child: Text(s('apply_this_chat'))),
      ]),
    );
    return Column(children: [
      PaneHeader(title: Text(s('wallpaper')), onBack: () => Navigator.of(context).maybePop()),
      Expanded(
        child: desktop
            ? Row(children: [
                Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(16, 16, 0, 0), child: preview)),
                SizedBox(width: 360, child: options),
              ])
            : Column(children: [
                SizedBox(height: 220, child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 0), child: preview)),
                Expanded(child: options),
              ]),
      ),
      actions,
    ]);
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.selected, required this.label, required this.onTap, required this.child});
  final bool selected;
  final String label;
  final VoidCallback onTap;
  final Widget child;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.md),
        child: Column(children: [
          Expanded(
            child: AnimatedContainer(
              duration: Motion.fast,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.md),
                border: Border.all(color: selected ? LC.primary : context.lc.divider, width: selected ? 2.5 : 1),
              ),
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
          ),
          const SizedBox(height: 4),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall?.copyWith(fontSize: 11.5)),
        ]),
      );
}

class _PreviewBubbles extends StatelessWidget {
  const _PreviewBubbles();
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    Widget bubble(String t, bool mine) => Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              gradient: mine ? const LinearGradient(colors: [LC.primary, Color(0xFF5A4BD8)]) : null,
              color: mine ? null : context.lc.bubbleIn,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(t, style: TextStyle(color: mine ? Colors.white : context.lc.text)),
          ),
        );
    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const DateChip(label: '12:30'),
      bubble(s('wp_preview_1'), false),
      bubble(s('wp_preview_2'), true),
      bubble(s('wp_preview_3'), false),
    ]);
  }
}

/// Glass chip used for day separators so they stay readable on wallpapers.
class DateChip extends StatelessWidget {
  const DateChip({super.key, required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: (dark ? const Color(0xFF0F1020) : Colors.white).withValues(alpha: dark ? 0.55 : 0.75),
        borderRadius: BorderRadius.circular(Radii.xl),
        border: Border.all(color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.06)),
      ),
      child: Text(label, style: context.tt.labelSmall?.copyWith(letterSpacing: 0.2, color: context.lc.text.withValues(alpha: 0.85))),
    );
  }
}

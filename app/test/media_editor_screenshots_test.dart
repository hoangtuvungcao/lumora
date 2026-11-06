// Screenshots of the photo editor flow with the mock API (dark theme,
// desktop 1440x900 + mobile 390x844 @2x) → app/screenshots/.
// Run: flutter test test/media_editor_screenshots_test.dart

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lumora/app.dart';
import 'package:lumora/ui/chats/attachments.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/media_editor/edit_state.dart';
import 'package:lumora/ui/media_editor/photo_editor_screen.dart';
import 'package:lumora/ui/theme.dart';

import 'helpers.dart';

/// Image decoding completes on the engine side: alternate real waits with
/// pumps (the loads were started inside the fake-async test zone).
Future<void> pumpUntilLoaded(WidgetTester tester, PhotoEditorScreenState st) async {
  for (var i = 0; i < 100 && !st.drafts.every((d) => d.assets != null || d.error != null); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
  }
  await tester.pump();
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String path) async {
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final f = File(path);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// A phone-screenshot-like PNG with secrets to hide (Wi-Fi password, phone
/// number), 900x1200.
String _secretScreenshot() {
  final f = File('${Directory.systemTemp.path}/lumora_pe_secret.png');
  if (f.existsSync()) return f.path;
  final im = img.Image(width: 900, height: 1200);
  img.fill(im, color: img.ColorRgb8(244, 245, 251));
  img.fillRect(im, x1: 0, y1: 0, x2: 900, y2: 150, color: img.ColorRgb8(108, 92, 231));
  img.drawString(im, 'Wi-Fi & Network', font: img.arial48, x: 48, y: 64, color: img.ColorRgb8(255, 255, 255));
  void card(int y, int h) => img.fillRect(im, x1: 32, y1: y, x2: 868, y2: y + h, color: img.ColorRgb8(255, 255, 255), radius: 24);
  void label(String t, int y) => img.drawString(im, t, font: img.arial24, x: 64, y: y, color: img.ColorRgb8(91, 96, 125));
  void value(String t, int y) => img.drawString(im, t, font: img.arial48, x: 64, y: y, color: img.ColorRgb8(20, 22, 43));
  card(200, 220);
  label('Network name', 230);
  value('Lumora_Home_5G', 270);
  img.fillRect(im, x1: 64, y1: 345, x2: 836, y2: 347, color: img.ColorRgb8(227, 230, 240));
  label('Security: WPA3', 365);
  card(450, 200);
  label('Password', 480);
  value('Pho-Co-Ha-Noi#2026', 520);
  card(680, 200);
  label('Support hotline', 710);
  value('+84 912 345 678', 750);
  card(910, 220);
  label('Router admin', 940);
  value('192.168.1.1', 980);
  label('Last changed: 05/11/2026', 1060);
  f.writeAsBytesSync(img.encodePng(im));
  return f.path;
}

/// A 3-frame animated "city lights" GIF, 480x320.
String _sampleGif() {
  final f = File('${Directory.systemTemp.path}/lumora_pe_city.gif');
  if (f.existsSync()) return f.path;
  img.Image frame(int k) {
    final im = img.Image(width: 480, height: 320, numChannels: 3);
    for (var y = 0; y < 320; y++) {
      final t = y / 320;
      img.drawLine(im, x1: 0, y1: y, x2: 479, y2: y, color: img.ColorRgb8((30 + 80 * t).round(), (20 + 30 * t).round(), (70 + 60 * t).round()));
    }
    final rnd = math.Random(7);
    for (var b = 0; b < 12; b++) {
      final x = b * 40, h = 90 + rnd.nextInt(150);
      img.fillRect(im, x1: x + 2, y1: 320 - h, x2: x + 38, y2: 320, color: img.ColorRgb8(18, 16, 40));
      for (var wy = 320 - h + 10; wy < 310; wy += 16) {
        for (var wx = x + 8; wx < x + 34; wx += 10) {
          final on = (wx * 7 + wy * 3 + k * 5 + b) % 4 != 0;
          if (on) img.fillRect(im, x1: wx, y1: wy, x2: wx + 4, y2: wy + 6, color: img.ColorRgb8(255, 205 - k * 20, 90 + k * 30));
        }
      }
    }
    img.fillCircle(im, x: 400, y: 60, radius: 26 + k * 2, color: img.ColorRgb8(250, 240, 200));
    im.frameDuration = 180;
    return im;
  }

  final anim = frame(0)..addFrame(frame(1))..addFrame(frame(2));
  f.writeAsBytesSync(img.encodeGif(anim));
  return f.path;
}

EditState _gifEdit() => const EditState(
      filter: 'vivid',
      items: [
        OverlayItem(id: 'g1', kind: OverlayKind.text, text: 'Phố đêm ✨', pos: Offset(150, 64), size: 34, color: LC.accent, bg: TextBg.solid, angle: -0.05),
        OverlayItem(id: 'g2', kind: OverlayKind.emoji, text: '🎉', pos: Offset(330, 70), size: 56, angle: 0.2),
      ],
    );

String _brokenHeic() {
  final f = File('${Directory.systemTemp.path}/IMG_4021.HEIC');
  if (!f.existsSync()) f.writeAsBytesSync(List.filled(512, 7));
  return f.path;
}

/// Drawing + text + pixelate + blur on [_secretScreenshot].
EditState _secretEdit() {
  List<Offset> line(Offset a, Offset b, [int n = 24]) => [for (var i = 0; i <= n; i++) Offset.lerp(a, b, i / n)!];
  List<Offset> ellipse(Offset c, double rx, double ry, double from, double to, [int n = 48]) =>
      [for (var i = 0; i <= n; i++) c + Offset(math.cos(from + (to - from) * i / n) * rx, math.sin(from + (to - from) * i / n) * ry)];
  return EditState(
    strokes: [
      Stroke(StrokeKind.pixelate, line(const Offset(70, 548), const Offset(560, 548)), 74, Colors.black),
      Stroke(StrokeKind.blur, line(const Offset(70, 776), const Offset(470, 776)), 70, Colors.black),
      Stroke(StrokeKind.highlighter, line(const Offset(64, 302), const Offset(420, 302)), 40, const Color(0xFFFACC15)),
      Stroke(StrokeKind.pen, ellipse(const Offset(250, 1000), 220, 62, -2.9, 3.5), 7, const Color(0xFFEF4444)),
      Stroke(StrokeKind.pen, line(const Offset(700, 1150), const Offset(500, 1062), 12), 7, const Color(0xFFEF4444)),
      Stroke(StrokeKind.pen, [const Offset(522, 1100), const Offset(498, 1061), const Offset(543, 1056)], 7, const Color(0xFFEF4444)),
    ],
    items: const [
      OverlayItem(id: 't1', kind: OverlayKind.text, text: 'Vào trang này để đổi mật khẩu', pos: Offset(560, 1150), size: 34, color: LC.primary, bg: TextBg.solid, angle: -0.04),
      OverlayItem(id: 't2', kind: OverlayKind.text, text: 'Wi-Fi nhà mình nè', pos: Offset(650, 392), size: 34, color: Colors.white, bg: TextBg.translucent),
      OverlayItem(id: 'e1', kind: OverlayKind.emoji, text: '🔒', pos: Offset(780, 540), size: 72, angle: 0.15),
    ],
  );
}

/// A sample composition on assets/mock/dalat.jpg (640x427).
EditState _sampleEdit() {
  List<Offset> arc(Offset c, double r, double from, double to, [int n = 40]) =>
      [for (var i = 0; i <= n; i++) c + Offset.fromDirection(from + (to - from) * i / n, r) * 1.0];
  return EditState(
    strokes: [
      Stroke(StrokeKind.highlighter, [for (var x = 70.0; x <= 330; x += 10) Offset(x, 98)], 14, const Color(0xFFFACC15)),
      Stroke(StrokeKind.pen, arc(const Offset(470, 150), 62, -2.6, 3.4), 5, const Color(0xFFEF4444)),
      Stroke(StrokeKind.pen, [const Offset(300, 110), const Offset(340, 125), const Offset(385, 135), const Offset(402, 140)], 5, const Color(0xFFEF4444)),
      Stroke(StrokeKind.pen, [const Offset(384, 126), const Offset(404, 140), const Offset(382, 150)], 5, const Color(0xFFEF4444)),
    ],
    items: const [
      OverlayItem(id: 't1', kind: OverlayKind.text, text: 'Đà Lạt mùa sương', pos: Offset(200, 60), size: 30, color: Color(0xFF6C5CE7), bg: TextBg.solid, angle: -0.06),
      OverlayItem(id: 't2', kind: OverlayKind.text, text: 'chỗ này nè!', pos: Offset(470, 238), size: 24, color: Colors.white, bg: TextBg.outline),
      OverlayItem(id: 'e1', kind: OverlayKind.emoji, text: '🌲', pos: Offset(585, 70), size: 54, angle: 0.2),
    ],
  );
}

class _Shot {
  const _Shot(this.name, this.run);
  final String name;
  final Future<Widget?> Function(WidgetTester t, AppServices sv, bool desktop, GlobalKey<PhotoEditorScreenState> ek) run;
}

String _ha(AppServices sv) => 'd:${sv.contacts.friends.firstWhere((c) => c.name == 'Phạm Thu Hà').peer}';

final _shots = <_Shot>[
  _Shot('pe1_viewer_edit', (t, sv, d, ek) async {
    final conv = _ha(sv);
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }),
  _Shot('pe2_photo_editor', (t, sv, d, ek) async => PhotoEditorScreen(
        key: ek,
        conv: _ha(sv),
        paths: [_secretScreenshot()],
        purpose: PhotoEditorPurpose.fromViewer,
        startEditing: true,
      )),
  _Shot('pe3_photo_send_preview', (t, sv, d, ek) async => PhotoEditorScreen(
        key: ek,
        conv: _ha(sv),
        paths: const ['asset:assets/mock/dalat.jpg', 'asset:assets/mock/coffee.jpg', 'asset:assets/mock/city.jpg'],
      )),
  _Shot('pe5_editor_zoomed', (t, sv, d, ek) async => PhotoEditorScreen(
        key: ek,
        conv: _ha(sv),
        paths: [_secretScreenshot()],
        purpose: PhotoEditorPurpose.fromViewer,
        startEditing: true,
      )),
  _Shot('pe6_gif_editor', (t, sv, d, ek) async => PhotoEditorScreen(
        key: ek,
        conv: _ha(sv),
        paths: [_sampleGif()],
        purpose: PhotoEditorPurpose.fromViewer,
        startEditing: true,
      )),
  _Shot('pe7_gif_progress', (t, sv, d, ek) async => PhotoEditorScreen(
        key: ek,
        conv: _ha(sv),
        paths: [_sampleGif()],
      )),
  _Shot('pe8_heic_fallback', (t, sv, d, ek) async => PhotoEditorScreen(
        key: ek,
        conv: _ha(sv),
        paths: [_brokenHeic()],
      )),
  _Shot('pe4_photo_crop', (t, sv, d, ek) async => PhotoEditorScreen(
        key: ek,
        conv: _ha(sv),
        paths: const ['asset:assets/mock/city.jpg'],
        purpose: PhotoEditorPurpose.fromViewer,
        startEditing: true,
      )),
];

void main() {
  final filter = Platform.environment['SHOT_FILTER'];
  setUpAll(loadFonts);

  for (final shot in _shots) {
    if (filter != null && !shot.name.contains(filter)) continue;
    for (final desktop in [true, false]) {
      final name = '${shot.name}_${desktop ? 'desktop' : 'mobile'}_dark';
      testWidgets(name, (tester) async {
        if (desktop) {
          setSize(tester, const Size(1440, 900));
        } else {
          setSize(tester, const Size(390, 844), dpr: 2);
        }
        final sv = await makeServices(tester, theme: ThemeMode.dark);
        final ek = GlobalKey<PhotoEditorScreenState>();
        final home = await shot.run(tester, sv, desktop, ek);
        final key = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(key: key, child: LumoraApp(services: sv, home: home)));
        await settle(tester);
        if (shot.name.startsWith('pe1')) {
          final conv = _ha(sv);
          final m = sv.chat.thread(conv).messages.firstWhere((m) => m.isFile);
          openMediaViewer(tester.element(find.byType(ChatView)), conv: conv, initialId: m.id);
          await settle(tester, frames: 6);
        } else {
          await pumpUntilLoaded(tester, ek.currentState!);
          await tester.pump();
          final st = ek.currentState!;
          if (shot.name.startsWith('pe2')) {
            st.debugApply(_secretEdit(), tool: EditorTool.hide);
          } else if (shot.name.startsWith('pe3')) {
            st.debugApply(_sampleEdit(), editingMode: false, caption: 'Sáng nay ở Đà Lạt, lạnh mà đẹp lắm 😍');
          } else if (shot.name.startsWith('pe5')) {
            st.debugApply(_secretEdit(), tool: EditorTool.hide);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            final r = st.debugImageRectGlobal();
            final stageTopLeft = tester.getTopLeft(find.byKey(const ValueKey('pe-gesture-layer')));
            st.debugZoom(2.5, at: Offset(r.left + r.width * 0.35, r.top + r.height * 0.42) - stageTopLeft);
          } else if (shot.name.startsWith('pe6')) {
            st.debugApply(_gifEdit(), tool: EditorTool.none);
          } else if (shot.name.startsWith('pe7')) {
            st.debugApply(_gifEdit(), editingMode: false, caption: 'Tối nay đi phố đi bộ không? 🎉');
            await tester.pump();
            st.debugProgress(0.62);
          } else if (shot.name.startsWith('pe8')) {
            // nothing: the fallback is the screen
          } else {
            st.debugApply(const EditState(crop: Rect.fromLTRB(0.08, 0.1, 0.82, 0.92)), tool: EditorTool.crop);
          }
          await tester.pump();
        }
        for (var i = 0; i < 3; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
          await tester.pump(const Duration(milliseconds: 40));
        }
        await _capture(tester, key, 'screenshots/$name.png');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 100));
        sv.dispose();
        resetSize(tester);
      });
    }
  }
}

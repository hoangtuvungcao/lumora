// In-chat camera: the composer's camera button (phones), what each capture
// leads to (photo → photo preview, video → send sheet), the attach menu entry
// only where a camera exists, and screenshots of the camera screen.
// Screenshots: SHOT_CAMERA=1 flutter test test/chat_camera_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lumora/app.dart';
import 'package:lumora/ui/chats/camera_capture.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/media_editor/photo_editor_screen.dart';

import 'helpers.dart';

final _shots = Platform.environment['SHOT_CAMERA'] == '1';

String _photo() {
  final f = File('${Directory.systemTemp.path}/lumora_cam_shot.jpg');
  if (!f.existsSync()) {
    final im = img.Image(width: 600, height: 800);
    img.fill(im, color: img.ColorRgb8(70, 120, 200));
    img.fillCircle(im, x: 300, y: 380, radius: 160, color: img.ColorRgb8(250, 200, 80));
    f.writeAsBytesSync(img.encodeJpg(im));
  }
  return f.path;
}

String _video() {
  final f = File('${Directory.systemTemp.path}/lumora_cam_clip.mp4');
  if (!f.existsSync()) f.writeAsBytesSync(List.filled(256, 7));
  return f.path;
}

Future<void> _png(WidgetTester t, String path) async {
  await t.runAsync(() async {
    final view = t.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    final image = await layer.toImage(Offset.zero & (view.size * t.view.devicePixelRatio), pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// A stand-in "camera picture": a sunset-ish scene.
class _FakeScene extends StatelessWidget {
  const _FakeScene();
  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF3A6EA5), Color(0xFFF2A65A), Color(0xFF5B3A29)]),
        ),
        child: Align(alignment: Alignment(0, -0.1), child: CircleAvatar(radius: 70, backgroundColor: Color(0xFFFFE08A))),
      );
}

void main() {
  setUpAll(() async {
    if (_shots) await loadFonts();
  });
  tearDown(() => chatCamera = null);

  Future<(AppServices, String)> open(WidgetTester t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv));
    await settle(t);
    final conv = sv.chat.sorted.firstWhere((c) => !c.isGroup && !c.isSaved).id;
    sv.nav.openConv(conv);
    Navigator.of(t.element(find.byType(Scaffold).first)).push(MaterialPageRoute<void>(builder: (_) => ChatView(conv: conv)));
    await settle(t);
    return (sv, conv);
  }

  Future<void> close(WidgetTester t, AppServices sv) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(t);
  }

  Finder camBtn() => find.byKey(const ValueKey('composer_camera'));

  testWidgets('no camera (desktop): no button, no attach entry', (t) async {
    chatCamera = null;
    final (sv, _) = await open(t);
    expect(camBtn(), findsNothing);
    await t.tap(find.byTooltip('Đính kèm tệp'));
    await settle(t);
    expect(find.text('Camera'), findsNothing);
    await close(t, sv);
  });

  testWidgets('camera button hides while typing; a photo opens the photo preview', (t) async {
    var opened = 0;
    chatCamera = (_) async {
      opened++;
      return CapturedFile(_photo(), video: false);
    };
    final (sv, _) = await open(t);
    expect(camBtn(), findsOneWidget);
    await t.enterText(find.byType(TextField).last, 'xin chào');
    await t.pump();
    expect(camBtn(), findsNothing, reason: 'typing: the pill keeps its room for text');
    await t.enterText(find.byType(TextField).last, '');
    await t.pump();
    await t.tap(camBtn());
    await settle(t);
    expect(opened, 1);
    expect(find.byType(PhotoEditorScreen), findsOneWidget, reason: 'caption / edit / send before anything goes out');
    await close(t, sv);
  });

  testWidgets('a video opens the send sheet; the attach menu has "Camera"', (t) async {
    chatCamera = (_) async => CapturedFile(_video(), video: true);
    final (sv, _) = await open(t);
    await t.tap(find.byTooltip('Đính kèm tệp'));
    await settle(t);
    await t.tap(find.text('Camera'));
    await settle(t);
    expect(find.text('Gửi'), findsOneWidget);
    expect(find.text('lumora_cam_clip.mp4'), findsOneWidget);
    await close(t, sv);
  });

  testWidgets('camera screen: controls and labels', (t) async {
    setSize(t, const Size(390, 844), dpr: 3);
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv));
    await settle(t);
    Navigator.of(t.element(find.byType(Scaffold).first)).push(MaterialPageRoute<void>(builder: (_) => const ChatCameraScreen(debugPreview: _FakeScene())));
    await settle(t);
    expect(find.byKey(const ValueKey('cam_shutter')), findsOneWidget);
    expect(find.byKey(const ValueKey('cam_gallery')), findsOneWidget);
    expect(find.byKey(const ValueKey('cam_flip')), findsOneWidget);
    expect(find.text('Chạm để chụp, giữ để quay video'), findsOneWidget);
    if (_shots) await _png(t, 'screenshots/narrow/chat_camera.png');
    await t.pumpWidget(const SizedBox());
    sv.dispose();
    resetSize(t);
  });

  testWidgets('camera screen: recording', (t) async {
    setSize(t, const Size(390, 844), dpr: 3);
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv));
    await settle(t);
    Navigator.of(t.element(find.byType(Scaffold).first))
        .push(MaterialPageRoute<void>(builder: (_) => const ChatCameraScreen(debugPreview: _FakeScene(), debugRecording: true)));
    await settle(t);
    expect(find.text('Thả tay để xem lại và gửi'), findsOneWidget);
    if (_shots) await _png(t, 'screenshots/narrow/chat_camera_recording.png');
    await t.pumpWidget(const SizedBox());
    sv.dispose();
    resetSize(t);
  });

  testWidgets('camera screen: permission refused', (t) async {
    setSize(t, const Size(390, 844), dpr: 3);
    final sv = await makeServices(t, theme: ThemeMode.light);
    await t.pumpWidget(LumoraApp(services: sv));
    await settle(t);
    Navigator.of(t.element(find.byType(Scaffold).first)).push(MaterialPageRoute<void>(builder: (_) => const ChatCameraScreen(debugDenied: true)));
    await settle(t);
    expect(find.text('Quay lại cuộc trò chuyện'), findsOneWidget);
    if (_shots) await _png(t, 'screenshots/narrow/chat_camera_denied.png');
    await t.pumpWidget(const SizedBox());
    sv.dispose();
    resetSize(t);
  });

  testWidgets('composer with the camera button (screenshot)', (t) async {
    chatCamera = (_) async => null;
    final (sv, _) = await open(t);
    if (_shots) await _png(t, 'screenshots/narrow/chat_composer_camera.png');
    await close(t, sv);
  });
}

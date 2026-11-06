// HEIC (iPhone photos): the friendly fallback when this machine can't decode
// it, and the real decode path where the system libheif is present (Linux).
// Fixture: test/fixtures/sample.heic (Flutter engine test resource, BSD).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lumora/app.dart';
import 'package:lumora/ui/media_editor/heic.dart';
import 'package:lumora/ui/media_editor/photo_editor_screen.dart';
import 'package:lumora/ui/media_editor/photo_fallback.dart';
import 'package:lumora/ui/media_editor/photo_io.dart';

import 'helpers.dart';

Future<void> _pumpUntilLoaded(WidgetTester tester, PhotoEditorScreenState st) async {
  for (var i = 0; i < 400 && !st.drafts.every((d) => d.assets != null || d.error != null); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
  }
  await tester.pump();
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('lumora_heic'));
  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('fallback: missing or broken HEIC → null, never throws', (tester) async {
    final bogus = File('${dir.path}/broken.heic')..writeAsBytesSync(List.filled(256, 7));
    expect(isHeicPath(bogus.path), isTrue);
    expect(isEditablePhoto(bogus.path), isTrue);
    expect(await tester.runAsync(() => decodeHeic('${dir.path}/missing.heic')), isNull);
    expect(await tester.runAsync(() => decodeHeic(bogus.path)), isNull);
    expect(decodeWithLibheif(bogus.path), isNull);
  });

  testWidgets('fallback UI: editor and viewer explain it and offer "Mở bằng ứng dụng khác"', (tester) async {
    setSize(tester, const Size(1280, 860));
    final sv = await makeServices(tester);
    final bogus = File('${dir.path}/IMG_4021.HEIC')..writeAsBytesSync(List.filled(256, 7));
    final key = GlobalKey<PhotoEditorScreenState>();
    await tester.pumpWidget(LumoraApp(services: sv, home: PhotoEditorScreen(key: key, conv: 'd:x', paths: [bogus.path])));
    await _pumpUntilLoaded(tester, key.currentState!);
    final d0 = key.currentState!.drafts.single;
    expect(d0.error, isNotNull, reason: 'assets=${d0.assets} bytes=${d0.bytes?.length}');
    expect(find.byKey(const ValueKey('pe-open-external')), findsOneWidget);
    expect(find.text('Máy này chưa xem được ảnh HEIC (ảnh iPhone)'), findsOneWidget);

    // Viewer stand-in (shown by the media viewer's errorBuilder).
    await tester.pumpWidget(LumoraApp(services: sv, home: Scaffold(body: PhotoDecodeFallback(path: bogus.path))));
    await tester.pump();
    expect(find.byKey(const ValueKey('open-with-other-app')), findsOneWidget);
    expect(find.textContaining('libheif'), findsOneWidget); // Linux tip

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(tester);
  });

  testWidgets('decode: system libheif opens the sample; the editor sends it as JPEG without EXIF', (tester) async {
    setSize(tester, const Size(1280, 860));
    final heic = File('${dir.path}/IMG_0001.heic')..writeAsBytesSync(File('test/fixtures/sample.heic').readAsBytesSync());
    final raw = decodeWithLibheif(heic.path)!;
    expect(raw.$2, greaterThan(0));
    expect(raw.$3, greaterThan(0));
    expect(raw.$1.length, raw.$2 * raw.$3 * 4);

    final image = (await tester.runAsync(() => decodeHeic(heic.path)))!;
    expect(image.width, raw.$2);
    expect(image.height, raw.$3);
    image.dispose();

    final sv = await makeServices(tester);
    final key = GlobalKey<PhotoEditorScreenState>();
    await tester.pumpWidget(LumoraApp(services: sv, home: PhotoEditorScreen(key: key, conv: 'd:x', paths: [heic.path])));
    await _pumpUntilLoaded(tester, key.currentState!);
    final st = key.currentState!;
    expect(st.drafts.single.assets, isNotNull);
    final out = (await tester.runAsync(() => st.exportDraft(st.drafts.single)))!;
    expect(out.ext, 'jpg');
    expect(sniffFormat(out.bytes), PhotoFormat.jpeg);
    expect(hasExif(out.bytes), isFalse);
    final jpg = img.decodeJpg(out.bytes)!;
    expect(jpg.width, raw.$2);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(tester);
  }, skip: !libheifAvailable);
}

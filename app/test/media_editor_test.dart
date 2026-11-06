// Photo editor: opens on a sample JPEG that carries GPS EXIF, applies
// crop (1:1) + text + pixelate brush through the real UI, exports, and
// checks the output size, that no EXIF/GPS survives, that the brushed area
// is really obscured, and that sending creates a new file message.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lumora/app.dart';
import 'package:lumora/ui/media_editor/edit_state.dart';
import 'package:lumora/ui/media_editor/photo_editor_screen.dart';
import 'package:lumora/ui/media_editor/photo_io.dart';

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

/// 1200x800 JPEG: soft gradient, a band of fine black/white stripes (the
/// "password" to hide) and GPS coordinates in EXIF.
Uint8List sampleJpegWithGps() {
  final im = img.Image(width: 1200, height: 800);
  for (var y = 0; y < 800; y++) {
    for (var x = 0; x < 1200; x++) {
      final stripes = y >= 200 && y < 320 && x >= 300 && x < 900;
      if (stripes) {
        final v = (x ~/ 4).isEven ? 255 : 0;
        im.setPixelRgb(x, y, v, v, v);
      } else {
        im.setPixelRgb(x, y, 60 + x * 120 ~/ 1200, 80 + y * 100 ~/ 800, 160);
      }
    }
  }
  im.exif.gpsIfd.gpsLatitudeRef = 'N';
  im.exif.gpsIfd.gpsLatitude = 21.0285;
  im.exif.gpsIfd.gpsLongitudeRef = 'E';
  im.exif.gpsIfd.gpsLongitude = 105.8542;
  im.exif.imageIfd.make = 'LumoraCam';
  return img.encodeJpg(im, quality: 92);
}

double _stddev(img.Image im, int x0, int y0, int w, int h) {
  final v = <double>[];
  for (var y = y0; y < y0 + h; y++) {
    for (var x = x0; x < x0 + w; x++) {
      v.add(im.getPixel(x, y).luminanceNormalized.toDouble() * 255);
    }
  }
  final mean = v.reduce((a, b) => a + b) / v.length;
  return math.sqrt(v.map((e) => (e - mean) * (e - mean)).reduce((a, b) => a + b) / v.length);
}

void main() {
  test('sample carries GPS (sanity)', () {
    final b = sampleJpegWithGps();
    expect(img.decodeJpgExif(b)!.gpsIfd.hasGPSLatitude, isTrue);
    expect(hasExif(b), isTrue);
    final stripped = stripMetadataLossless(b)!;
    expect(hasExif(stripped), isFalse);
    expect(img.decodeJpg(stripped)!.width, 1200);
  });

  testWidgets('crop + text + pixelate → export has 1:1 size and no EXIF/GPS; send makes a new message', (tester) async {
    setSize(tester, const Size(1280, 860));
    final sv = await makeServices(tester);
    final dir = Directory.systemTemp.createTempSync('lumora_pe_test');
    final src = File('${dir.path}/IMG_0001.jpg')..writeAsBytesSync(sampleJpegWithGps());
    final conv = sv.chat.sorted.firstWhere((c) => !c.isSaved && !c.isGroup).id;
    final before = sv.chat.thread(conv).messages.length;

    final key = GlobalKey<PhotoEditorScreenState>();
    await tester.pumpWidget(LumoraApp(
      services: sv,
      home: PhotoEditorScreen(key: key, conv: conv, paths: [src.path], purpose: PhotoEditorPurpose.fromViewer, startEditing: true),
    ));
    await pumpUntilLoaded(tester, key.currentState!);
    await tester.pump();
    final st0 = key.currentState!;
    expect(st0.drafts.single.assets!.image.width, 1200);

    // Crop 1:1.
    await tester.tap(find.byKey(const ValueKey('pe-tool-crop')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('pe-aspect-1:1')));
    await tester.pump();

    // Pixelate brush across the stripes (upper part of the square crop).
    await tester.tap(find.byKey(const ValueKey('pe-tool-hide')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final rect = st0.debugImageRectGlobal();
    // Source rows 200..320 of the 800px-high crop → display.
    final y = rect.top + rect.height * (260 / 800);
    final g = await tester.startGesture(Offset(rect.left + rect.width * 0.1, y));
    for (var i = 1; i <= 20; i++) {
      await g.moveTo(Offset(rect.left + rect.width * (0.1 + 0.8 * i / 20), y));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();

    // Text in the middle.
    await tester.tap(find.byKey(const ValueKey('pe-tool-text')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byKey(const ValueKey('pe-text-field')), 'Bí mật');
    await tester.tap(find.byKey(const ValueKey('pe-text-done')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('pe-done')));
    await tester.pump();

    final st = st0.drafts.single.state;
    expect(st.strokes.single.kind, StrokeKind.pixelate);
    expect(st.items.single.text, 'Bí mật');
    final crop = EditGeometry(st0.drafts.single.assets!.size, st).cropPx;
    expect(crop.width, closeTo(800, 1));
    expect(crop.height, closeTo(800, 1));

    final out = (await tester.runAsync(() => st0.exportDraft(st0.drafts.single)))!;
    expect(out.ext, 'jpg');
    final decoded = img.decodeJpg(out.bytes)!;
    expect(decoded.width, 800);
    expect(decoded.height, 800);
    expect(hasExif(out.bytes), isFalse);
    expect(img.decodeJpgExif(out.bytes)?.gpsIfd.hasGPSLatitude ?? false, isFalse);

    // The stripes under the brush are gone (crop starts at x = 200).
    final orig = img.decodeJpg(src.readAsBytesSync())!;
    expect(_stddev(orig, 500, 250, 40, 20), greaterThan(90));
    expect(_stddev(decoded, 300, 250, 40, 20), lessThan(30));
    // Stripes outside the brushed band stay sharp.
    expect(_stddev(decoded, 300, 205, 40, 6), greaterThan(60));

    // Original quality, untouched photo: lossless, full size, still no GPS.
    final pristine = (await tester.runAsync(() => exportPhoto(source: st0.drafts.single.bytes!, assets: st0.drafts.single.assets!, state: const EditState(), original: true)))!;
    expect(img.decodeJpg(pristine.bytes)!.width, 1200);
    expect(hasExif(pristine.bytes), isFalse);

    // Caption + send → a new file message (the original photo is untouched).
    await tester.enterText(find.byKey(const ValueKey('pe-caption')), 'Đã che mật khẩu');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pe-send')));
    for (var i = 0; i < 60 && sv.files.byId.values.where((f) => f.conv == conv && f.name.startsWith('Lumora_')).isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    final sent = sv.files.byId.values.where((f) => f.conv == conv && f.name.startsWith('Lumora_')).toList();
    expect(sent, hasLength(1));
    expect(File(sent.single.path).existsSync(), isTrue);
    expect(hasExif(File(sent.single.path).readAsBytesSync()), isFalse);
    await tester.pump(const Duration(milliseconds: 300));
    expect(sv.chat.thread(conv).messages.length, greaterThanOrEqualTo(before + 2)); // photo + caption
    expect(src.existsSync(), isTrue);

    try {
      File(sent.single.path).deleteSync();
      dir.deleteSync(recursive: true);
    } catch (_) {}
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(tester);
  });

  testWidgets('zoom: double-tap → 2×, a stroke drawn while zoomed lands on the right photo pixels', (tester) async {
    setSize(tester, const Size(1280, 860));
    final sv = await makeServices(tester);
    final dir = Directory.systemTemp.createTempSync('lumora_pe_zoom');
    final src = File('${dir.path}/zoom.jpg')..writeAsBytesSync(sampleJpegWithGps());
    final key = GlobalKey<PhotoEditorScreenState>();
    await tester.pumpWidget(LumoraApp(
      services: sv,
      home: PhotoEditorScreen(key: key, conv: 'd:x', paths: [src.path], purpose: PhotoEditorPurpose.fromViewer, startEditing: true),
    ));
    await pumpUntilLoaded(tester, key.currentState!);
    final st = key.currentState!;
    final fit = st.viewScale;
    final img0 = st.debugImageRectGlobal();
    // A point at 30% / 40% of the photo.
    final p = Offset(img0.left + img0.width * 0.3, img0.top + img0.height * 0.4);
    final srcP = st.debugToSource(p);
    expect(srcP.dx, closeTo(360, 1.5));
    expect(srcP.dy, closeTo(320, 1.5));

    // Double tap → 2× around that point (the point stays under the finger).
    await tester.tapAt(p);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(p);
    await tester.pump();
    expect(st.zoom, closeTo(2, 1e-6));
    expect(st.viewScale, closeTo(fit * 2, 1e-6));
    expect(st.debugToSource(p).dx, closeTo(srcP.dx, 0.5));
    expect(find.byKey(const ValueKey('pe-zoom-chip')), findsOneWidget);
    expect(find.text('200%'), findsOneWidget);

    // Draw 120 display px to the right with the pen. (The pen options take
    // some height, so re-read the mapping after the layout settles.)
    await tester.tap(find.byKey(const ValueKey('pe-tool-draw')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(st.zoom, closeTo(2, 1e-6));
    final scale = st.viewScale;
    final srcAt = st.debugToSource(p);
    final g = await tester.startGesture(p);
    for (var i = 1; i <= 12; i++) {
      await g.moveTo(p + Offset(10.0 * i, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pe-done')));
    await tester.pump();
    final s = st.drafts.single.state.strokes.single;
    expect(s.points.first.dx, closeTo(srcAt.dx, 0.5));
    expect(s.points.first.dy, closeTo(srcAt.dy, 0.5));
    // 120 display px at the zoomed scale = 120 / scale photo px.
    expect(s.points.last.dx, closeTo(srcAt.dx + 120 / scale, 0.5));
    expect(s.points.last.dy, closeTo(srcAt.dy, 0.5));
    // Pen width is constant on screen → thinner in photo pixels when zoomed.
    expect(s.width, closeTo(6 / scale, 1e-6));

    // The chip resets to fit.
    await tester.tap(find.byKey(const ValueKey('pe-zoom-chip')));
    await tester.pump();
    expect(st.zoom, 1);

    dir.deleteSync(recursive: true);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(tester);
  });

  testWidgets('animated GIF: 3 frames edited → 3 frames out, overlay on every frame, delays kept', (tester) async {
    setSize(tester, const Size(1280, 860));
    final sv = await makeServices(tester);
    final dir = Directory.systemTemp.createTempSync('lumora_pe_gif');
    // 120x80, frames red / green / blue, 100 / 200 / 300 ms.
    final anim = img.Image(width: 120, height: 80, numChannels: 3);
    img.fill(anim, color: img.ColorRgb8(220, 30, 30));
    anim.frameDuration = 100;
    for (final (c, ms) in [(img.ColorRgb8(30, 200, 30), 200), (img.ColorRgb8(30, 30, 220), 300)]) {
      final f = img.Image(width: 120, height: 80, numChannels: 3);
      img.fill(f, color: c);
      f.frameDuration = ms;
      anim.addFrame(f);
    }
    final gifBytes = img.encodeGif(anim);
    final src = File('${dir.path}/party.gif')..writeAsBytesSync(gifBytes);
    final key = GlobalKey<PhotoEditorScreenState>();
    await tester.pumpWidget(LumoraApp(
      services: sv,
      home: PhotoEditorScreen(key: key, conv: 'd:x', paths: [src.path], purpose: PhotoEditorPurpose.fromViewer, startEditing: true),
    ));
    await pumpUntilLoaded(tester, key.currentState!);
    final st = key.currentState!;
    final d = st.drafts.single;
    expect(d.gif!.frames, 3);
    expect(find.text('GIF · 3 khung hình'), findsOneWidget);

    // Untouched → the original bytes (animation intact).
    final pristine = (await tester.runAsync(() => st.exportDraft(d)))!;
    expect(pristine.ext, 'gif');
    expect(pristine.bytes, gifBytes);

    // White bar across the middle + a pixelated strip at the top; crop the left 10 px off.
    st.debugApply(const EditState(
      crop: Rect.fromLTRB(10 / 120, 0, 1, 1),
      strokes: [
        Stroke(StrokeKind.pen, [Offset(0, 40), Offset(120, 40)], 10, Color(0xFFFFFFFF)),
        Stroke(StrokeKind.pixelate, [Offset(10, 8), Offset(110, 8)], 10, Color(0xFF000000)),
      ],
    ));
    await tester.pump();
    final out = (await tester.runAsync(() => st.exportDraft(d)))!;
    expect(out.ext, 'gif');
    final decoded = img.decodeGif(out.bytes)!;
    expect(decoded.numFrames, 3);
    expect(decoded.width, 110);
    expect(decoded.height, 80);
    final expected = [(220, 30, 30), (30, 200, 30), (30, 30, 220)];
    for (var i = 0; i < 3; i++) {
      final f = decoded.frames[i];
      expect(f.frameDuration, [100, 200, 300][i]);
      final bar = f.getPixel(55, 40);
      expect(bar.r > 200 && bar.g > 200 && bar.b > 200, isTrue, reason: 'overlay on frame $i: $bar');
      final bg = f.getPixel(55, 65);
      expect((bg.r - expected[i].$1).abs() < 40 && (bg.g - expected[i].$2).abs() < 40 && (bg.b - expected[i].$3).abs() < 40, isTrue, reason: 'frame $i colour: $bg');
    }

    dir.deleteSync(recursive: true);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(tester);
  });

  testWidgets('crop handles keep working while zoomed', (tester) async {
    setSize(tester, const Size(1280, 860));
    final sv = await makeServices(tester);
    final dir = Directory.systemTemp.createTempSync('lumora_pe_cropzoom');
    final src = File('${dir.path}/c.jpg')..writeAsBytesSync(sampleJpegWithGps());
    final key = GlobalKey<PhotoEditorScreenState>();
    await tester.pumpWidget(LumoraApp(
      services: sv,
      home: PhotoEditorScreen(key: key, conv: 'd:x', paths: [src.path], purpose: PhotoEditorPurpose.fromViewer, startEditing: true),
    ));
    await pumpUntilLoaded(tester, key.currentState!);
    final st = key.currentState!;
    await tester.tap(find.byKey(const ValueKey('pe-tool-crop')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final stage = tester.getTopLeft(find.byKey(const ValueKey('pe-gesture-layer')));
    // Zoom 2× around the bottom-right corner so it stays on screen.
    final r0 = st.debugImageRectGlobal();
    st.debugZoom(2, at: r0.bottomRight - stage - const Offset(1, 1));
    await tester.pump();
    expect(st.zoom, 2);
    final r = st.debugImageRectGlobal();
    final corner = r.bottomRight - const Offset(2, 2);
    final g = await tester.startGesture(corner);
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(corner - Offset(10.0 * i, 6.0 * i));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();
    final crop = st.debugState.crop;
    expect(crop.right, closeTo((corner.dx - 100 - r.left) / r.width, 0.004));
    expect(crop.bottom, closeTo((corner.dy - 60 - r.top) / r.height, 0.004));
    expect(crop.left, 0);
    expect(crop.top, 0);

    dir.deleteSync(recursive: true);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(tester);
  });
}

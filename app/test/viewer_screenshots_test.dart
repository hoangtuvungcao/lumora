// Screenshots of the in-app file viewers (code, PDF, Markdown, CSV) at
// desktop (1440x900) and mobile (390x844 @2x) sizes, dark + light.
// Run: flutter test test/viewer_screenshots_test.dart
// (SHOT_FILTER=pdf to render a subset). PDF shots need PDFium:
// PDFIUM_PATH=/path/to/libpdfium.so (skipped without it).

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/ui/viewers/csv_viewer.dart';
import 'package:lumora/ui/viewers/file_viewer.dart';
import 'package:lumora/ui/viewers/markdown_viewer.dart';
import 'package:lumora/ui/viewers/pdf_viewer.dart';
import 'package:lumora/ui/viewers/text_viewer.dart';
import 'package:pdfrx/pdfrx.dart';

import 'helpers.dart';

typedef _Page = Widget Function();

final _shots = <(String, _Page, bool)>[
  ('fv1_viewer_code', () => const TextFileViewer(source: ViewerSource('asset:assets/mock/files/main.py', 'main.py')), false),
  ('fv2_viewer_pdf', () => const PdfFileViewer(source: ViewerSource('asset:assets/mock/files/sample.pdf', 'bao-cao-q3.pdf')), true),
  ('fv3_viewer_markdown', () => const MarkdownFileViewer(source: ViewerSource('asset:assets/mock/files/README.md', 'README.md')), false),
  ('fv4_viewer_csv', () => const CsvFileViewer(source: ViewerSource('asset:assets/mock/files/data.csv', 'lich-su-gui-tep.csv')), false),
];

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

bool _pdfReady = false;
int _noop(int x) => x;

Future<void> _initPdfium() async {
  if (_pdfReady) return;
  Pdfrx.loadAsset = (name) async {
    final d = await rootBundle.load(name);
    return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
  };
  // flutter_test blocks HTTP, so pdfrx can't download PDFium from here: point
  // PDFIUM_PATH at libpdfium.so (github.com/bblanchon/pdfium-binaries,
  // chromium/7520 — the build pdfium_flutter bundles in the real app).
  Pdfrx.pdfiumModulePath = Platform.environment['PDFIUM_PATH'];
  final cache = Directory('${Directory.systemTemp.path}/lumora-pdfrx')..createSync(recursive: true);
  Pdfrx.getCacheDirectory = () => cache.path;
  // start pdfrx's worker isolate first: initialising it from inside init()
  // stalls under flutter_test
  await PdfrxEntryFunctions.instance.compute(_noop, 0);
  await PdfrxEntryFunctions.instance.init();
  await ensurePdfium();
  _pdfReady = true;
}

void main() {
  final filter = Platform.environment['SHOT_FILTER'];
  setUpAll(() async {
    await loadFonts();
    // a mono font with full Vietnamese coverage (DejaVu Sans Mono lacks a few letters)
    final f = File('/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf');
    if (f.existsSync()) {
      await (FontLoader('Noto Sans Mono')..addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer)))).load();
    }
  });

  for (final (name, page, pdf) in _shots) {
    if (filter != null && !name.contains(filter)) continue;
    for (final desktop in [true, false]) {
      for (final theme in [ThemeMode.dark, ThemeMode.light]) {
        final file = '${name}_${desktop ? 'desktop' : 'mobile'}_${theme.name}';
        testWidgets(file, (tester) async {
          if (pdf) await tester.runAsync(_initPdfium);
          if (desktop) {
            setSize(tester, const Size(1440, 900));
          } else {
            setSize(tester, const Size(390, 844), dpr: 2);
          }
          final sv = await makeServices(tester, theme: theme);
          final key = GlobalKey();
          await tester.pumpWidget(RepaintBoundary(key: key, child: LumoraApp(services: sv, home: page())));
          // real async work: asset loads, PDFium rendering on its worker
          for (var i = 0; i < (pdf ? 14 : 5); i++) {
            await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: pdf ? 250 : 60)));
            await tester.pump(const Duration(milliseconds: 50));
          }
          if (name == 'fv1_viewer_code') {
            // show search in action
            await tester.tap(find.byTooltip('Tìm trong tệp').first);
            await tester.pump();
            await tester.enterText(find.byType(TextField).first, 'photo');
            for (var i = 0; i < 3; i++) {
              await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
              await tester.pump(const Duration(milliseconds: 250));
            }
          }
          await _capture(tester, key, 'screenshots/$file.png');
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 1));
          sv.dispose();
          resetSize(tester);
        }, skip: pdf && Platform.environment['PDFIUM_PATH'] == null);
      }
    }
  }
}

// In-app file viewers: routing by type, CSV parsing, text decoding (binary
// refusal, UTF-8-safe truncation), search, and the text / JSON / Markdown /
// CSV viewer widgets.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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

int _noop(int x) => x;

/// PDFium for tests (flutter_test blocks the download): PDFIUM_PATH=libpdfium.so
Future<void> _initPdfium() async {
  Pdfrx.loadAsset = (name) async {
    final d = await rootBundle.load(name);
    return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
  };
  Pdfrx.pdfiumModulePath = Platform.environment['PDFIUM_PATH'];
  final cache = Directory('${Directory.systemTemp.path}/lumora-pdfrx')..createSync(recursive: true);
  Pdfrx.getCacheDirectory = () => cache.path;
  await PdfrxEntryFunctions.instance.compute(_noop, 0); // start the worker first (stalls otherwise)
  await PdfrxEntryFunctions.instance.init();
  await ensurePdfium();
}

Future<AppServices> _pump(WidgetTester tester, Widget page, {bool desktop = true}) async {
  setSize(tester, desktop ? const Size(1440, 900) : const Size(390, 844), dpr: desktop ? 1 : 2);
  final sv = await makeServices(tester);
  await tester.pumpWidget(LumoraApp(services: sv, home: page));
  await _settle(tester);
  return sv;
}

Future<void> _settle(WidgetTester tester, [int n = 5]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _done(WidgetTester tester, AppServices sv) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  sv.dispose();
  resetSize(tester);
}

void main() {
  group('viewerKindOf', () {
    test('routes by extension and mime', () {
      expect(viewerKindOf('Báo cáo.PDF'), ViewerKind.pdf);
      expect(viewerKindOf('x.bin', 'application/pdf'), ViewerKind.pdf);
      expect(viewerKindOf('README.md'), ViewerKind.markdown);
      expect(viewerKindOf('a.csv'), ViewerKind.csv);
      expect(viewerKindOf('a.tsv'), ViewerKind.csv);
      expect(viewerKindOf('config.json'), ViewerKind.json);
      for (final n in ['main.py', 'app.ts', 'lib.rs', 'x.dart', 'a.go', 'b.yaml', 'c.toml', 'd.sql', 'e.log', 'f.txt', 'Makefile']) {
        expect(viewerKindOf(n), ViewerKind.code, reason: n);
      }
      expect(viewerKindOf('a.bin', 'text/plain'), ViewerKind.code);
    });

    test('HTML and SVG are text, never rendered', () {
      expect(viewerKindOf('page.html'), ViewerKind.code);
      expect(viewerKindOf('logo.svg', 'image/svg+xml'), ViewerKind.code);
      expect(viewerKindOf('data.xml'), ViewerKind.code);
    });

    test('media and unknown files go to other apps', () {
      expect(viewerKindOf('a.jpg'), ViewerKind.image);
      expect(viewerKindOf('a.mp4'), ViewerKind.media);
      expect(viewerKindOf('a.mp3'), ViewerKind.media);
      expect(viewerKindOf('a.zip'), ViewerKind.none);
      expect(viewerKindOf('setup.exe'), ViewerKind.none);
      expect(canViewInApp('a.py'), isTrue);
      expect(canViewInApp('a.pdf'), isTrue);
      expect(canViewInApp('a.mp4'), isFalse);
      expect(canViewInApp('a.docx'), isFalse);
    });
  });

  group('CSV', () {
    test('quotes, escaped quotes and newlines inside quotes', () {
      final t = parseCsv('a,b,c\n1,"x, y","say ""hi"""\n2,"two\nlines",z\n');
      expect(t.rows, [
        ['a', 'b', 'c'],
        ['1', 'x, y', 'say "hi"'],
        ['2', 'two\nlines', 'z'],
      ]);
      expect(t.totalRows, 3);
      expect(t.columns, 3);
    });

    test('CRLF, BOM, blank lines, empty fields', () {
      final t = parseCsv('﻿a,b\r\n\r\n1,\r\n,2');
      expect(t.rows, [
        ['a', 'b'],
        ['1', ''],
        ['', '2'],
      ]);
    });

    test('delimiter detection', () {
      expect(detectDelimiter('a;b;c\n1;2;3'), ';');
      expect(detectDelimiter('a\tb\n1\t2'), '\t');
      expect(detectDelimiter('a,b\n"x;y;z",1'), ',');
      expect(parseCsv('a;b\n"1;5";2').rows[1], ['1;5', '2']);
    });

    test('row cap keeps counting', () {
      final text = List.generate(20, (i) => '$i,x').join('\n');
      final t = parseCsv(text, maxRows: 5);
      expect(t.rows.length, 5);
      expect(t.totalRows, 20);
    });
  });

  group('text decoding', () {
    test('binary files are refused', () {
      expect(looksBinary([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]), isTrue); // PNG renamed .txt
      expect(looksBinary(utf8.encode('PK\u0003\u0004') + [0, 0]), isTrue); // ZIP
      expect(looksBinary([0xC3, 0x28, 0x61, 0x62]), isTrue); // invalid UTF-8
      expect(looksBinary([1, 2, 3, 4, 0x61]), isTrue); // control characters
      expect(looksBinary(utf8.encode('xin chào\tthế giới\r\n')), isFalse);
      expect(decodeTextHead(Uint8List.fromList([0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0]), 8).binary, isTrue); // ELF
    });

    test('UTF-8 safe truncation', () {
      final b = utf8.encode('ếếế'); // 3 bytes each
      expect(utf8SafeEnd(b, 9), 9);
      expect(utf8SafeEnd(b, 8), 6);
      expect(utf8SafeEnd(b, 7), 6);
      expect(utf8SafeEnd(b, 6), 6);
      final head = Uint8List.fromList(b.sublist(0, 8));
      final r = decodeTextHead(head, 9000);
      expect(r.truncated, isTrue);
      expect(r.text, 'ếế');
      // a window ending mid-character is still recognised as text
      expect(looksBinary(b.sublist(0, 8)), isFalse);
    });

    test('BOM and line ends', () {
      final r = decodeTextHead(Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('a\r\nb\rc')]), 9);
      expect(r.text, 'a\nb\nc');
      expect(r.truncated, isFalse);
    });

    test('search is case-insensitive and finds every match', () {
      final m = findMatches(['Photo photo', 'none', 'PHOTOS'], 'photo');
      expect(m.length, 3);
      expect((m[1].line, m[1].start, m[1].end), (0, 6, 11));
      expect(m[2].line, 2);
      expect(findMatches(['aaaa'], 'aa').length, 2);
    });

    test('highlighting keeps one token list per line', () {
      const code = 'def f():\n    """doc\n    string"""\n    return 1\n';
      final lines = highlightLines(code, 'python');
      expect(lines.length, code.split('\n').length);
      expect(lines[0].map((t) => t.text).join(), 'def f():');
      // the multi-line string is coloured on both lines
      expect(lines[2].any((t) => t.scope?.contains('string') ?? false), isTrue);
      expect(languageFor('a.PY'), 'python');
      expect(languageFor('x.svg'), 'xml');
      expect(languageFor('notes.txt'), isNull);
    });
  });

  group('viewers', () {
    setUpAll(loadFonts);

    testWidgets('code viewer: info, search count, wrap toggle', (tester) async {
      final sv = await _pump(tester, const TextFileViewer(source: ViewerSource('asset:assets/mock/files/main.py', 'main.py')));
      expect(find.textContaining('Python · 45 dòng'), findsOneWidget);
      expect(find.text('1'), findsOneWidget); // gutter
      final view = find.byType(CodeView);
      expect(tester.widget<CodeView>(view).wrap, isFalse);
      await tester.tap(find.byTooltip('Ngắt dòng'));
      await tester.pump();
      expect(tester.widget<CodeView>(view).wrap, isTrue);
      await tester.tap(find.byTooltip('Tìm trong tệp'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'PHOTO');
      await _settle(tester, 3);
      expect(find.text('1 / 10'), findsOneWidget);
      await tester.tap(find.byTooltip('Kết quả tiếp theo'));
      await _settle(tester, 2);
      expect(find.text('2 / 10'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'không-có-đâu');
      await _settle(tester, 2);
      expect(find.text('Không thấy'), findsOneWidget);
      await _done(tester, sv);
    });

    testWidgets('binary file named .txt is refused', (tester) async {
      final dir = Directory.systemTemp.createTempSync('lumora-viewer');
      final f = File('${dir.path}/fake.txt')..writeAsBytesSync([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48]);
      final sv = await _pump(tester, TextFileViewer(source: ViewerSource(f.path, 'fake.txt')));
      expect(find.text('Không xem được tệp này'), findsOneWidget);
      expect(find.text('Mở bằng ứng dụng khác'), findsOneWidget);
      expect(find.byType(CodeView), findsNothing);
      await _done(tester, sv);
      dir.deleteSync(recursive: true);
    });

    testWidgets('large file: only the first 1.5 MB, with a banner', (tester) async {
      final dir = Directory.systemTemp.createTempSync('lumora-viewer');
      final line = 'dòng nhật ký số ${'x' * 60}\n';
      final f = File('${dir.path}/big.log')..writeAsStringSync(line * 26000); // ≈ 2 MB
      final sv = await _pump(tester, TextFileViewer(source: ViewerSource(f.path, 'big.log')));
      expect(find.textContaining('Chỉ hiển thị 1,5 MB đầu'), findsOneWidget);
      final shown = tester.widget<CodeView>(find.byType(CodeView)).text;
      expect(utf8.encode(shown).length, lessThanOrEqualTo(kViewerMaxBytes));
      expect(shown.startsWith('dòng nhật ký'), isTrue);
      await _done(tester, sv);
      dir.deleteSync(recursive: true);
    });

    testWidgets('JSON is pretty-printed, raw on demand', (tester) async {
      final sv = await _pump(tester, const TextFileViewer(source: ViewerSource('asset:assets/mock/files/config.json', 'config.json'), json: true));
      String text() => tester.widget<CodeView>(find.byType(CodeView)).text;
      expect(text(), contains('\n  "app": "lumora-sync",\n'));
      await tester.tap(find.byTooltip('Đã định dạng'));
      await _settle(tester, 2);
      expect(text().startsWith('{"app":"lumora-sync"'), isTrue);
      await _done(tester, sv);
    });

    testWidgets('markdown: rendered without network images, source toggle', (tester) async {
      final sv = await _pump(tester, const MarkdownFileViewer(source: ViewerSource('asset:assets/mock/files/README.md', 'README.md')));
      expect(find.text('Lumora Photo Sync'), findsWidgets);
      expect(find.text('Ảnh trên mạng (không tự tải)'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is Image && w.image is NetworkImage), findsNothing);
      expect(find.byType(CodeView), findsNothing);
      await tester.tap(find.text('Xem nguồn'));
      await _settle(tester, 2);
      expect(find.byType(CodeView), findsOneWidget);
      expect(tester.widget<CodeView>(find.byType(CodeView)).text, startsWith('# Lumora Photo Sync'));
      await _done(tester, sv);
    });

    testWidgets('pdf viewer: pages, search, page pill', (tester) async {
      await tester.runAsync(_initPdfium);
      setSize(tester, const Size(1440, 900));
      final sv = await makeServices(tester);
      await tester.pumpWidget(LumoraApp(services: sv, home: const PdfFileViewer(source: ViewerSource('asset:assets/mock/files/sample.pdf', 'sample.pdf'))));
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.textContaining('PDF · 3 trang'), findsOneWidget);
      expect(find.text('1 / 3'), findsOneWidget);
      await tester.tap(find.byTooltip('Tìm trong tệp'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Lumora');
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.textContaining(RegExp(r'^1 / [1-9]')), findsWidgets);
      await _done(tester, sv);
    }, skip: Platform.environment['PDFIUM_PATH'] == null);

    testWidgets('csv viewer: header, rows, numeric columns', (tester) async {
      final sv = await _pump(tester, const CsvFileViewer(source: ViewerSource('asset:assets/mock/files/data.csv', 'data.csv')), desktop: false);
      expect(find.textContaining('10 hàng · 6 cột'), findsOneWidget);
      expect(find.text('Ngày'), findsOneWidget);
      expect(find.text('Laptop của An'), findsWidgets);
      await _done(tester, sv);
    });
  });
}

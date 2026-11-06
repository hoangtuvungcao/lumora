// File previews before download: snippet extraction (UTF-8 safe cut, binary
// refusal), sanitising, the JPEG budget, mock data, and the bubbles/sheet.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/file_preview.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/core/preview_builder.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/chats/attachments.dart';
import 'package:lumora/ui/viewers/preview_card.dart';
import 'package:lumora/ui/viewers/text_viewer.dart';
import 'package:pdfrx/pdfrx.dart';

import 'helpers.dart';

int _noop(int x) => x;

void main() {
  group('textSnippet', () {
    test('cuts UTF-8 on a character boundary', () {
      final s = 'xin chào thế giới ' * 200;
      final sn = textSnippet(utf8.encode(s), maxBytes: 100)!;
      expect(utf8.encode(sn).length, lessThanOrEqualTo(100));
      expect(s.startsWith(sn), isTrue);
      // every cut position inside multi-byte letters stays valid
      final v = utf8.encode('ếếếếếếếếếế');
      for (var max = 1; max < v.length; max++) {
        final out = textSnippet(v, maxBytes: max)!;
        expect(utf8.encode(out).length, lessThanOrEqualTo(max));
        expect(out.runes.every((r) => r == 'ế'.runes.first), isTrue);
      }
    });

    test('a read window ending mid-character is still text', () {
      final b = utf8.encode('ếếếế');
      expect(textSnippet(b.sublist(0, b.length - 1)), 'ếếế');
      expect(textSnippet(b.sublist(0, b.length - 2)), 'ếếế');
    });

    test('prefers a line end in the second half of the window', () {
      const code = 'def f():\n    return 1\n\nprint(f())\n';
      expect(textSnippet(utf8.encode(code), maxBytes: 30), 'def f():\n    return 1\n');
    });

    test('strips the BOM and normalises CRLF', () {
      expect(textSnippet([0xEF, 0xBB, 0xBF, ...utf8.encode('a\r\nb\rc')]), 'a\nb\nc');
    });

    test('refuses binary files mislabelled as text', () {
      // ZIP, PNG, NUL bytes, invalid UTF-8 (Latin-1), many control characters
      expect(textSnippet([0x50, 0x4B, 0x03, 0x04, 0x14, 0, 0, 0]), isNull);
      expect(textSnippet([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D]), isNull);
      expect(textSnippet(latin1.encode('café olé niño')), isNull);
      expect(textSnippet([1, 2, 3, 0x61, 0x62]), isNull);
      expect(textSnippet(<int>[]), '');
      // a few escape sequences are fine (coloured logs)
      expect(textSnippet(utf8.encode('\x1b[32mOK\x1b[0m build passed and all tests are green')), isNotNull);
    });
  });

  test('sanitizePreviewText drops control characters and bidi overrides, caps at 4 KB', () {
    expect(sanitizePreviewText('a\u0000b\r\nc\u001b[31md\te\u202Ef\rg\u0085'), 'ab\nc[31md\tef\ng');
    final big = sanitizePreviewText('ắ' * 5000);
    expect(utf8.encode(big).length, lessThanOrEqualTo(kMaxPreviewText));
    expect(utf8.encode(big).length, greaterThan(kMaxPreviewText - 3));
  });

  test('FilePreview.fromJson re-sanitises what a peer sent', () {
    final p = FilePreview.fromJson({'kind': 'TEXT', 'text': 'x\u0000y\u2066', 'lines': 12, 'pages': -3})!;
    expect(p.kind, 'text');
    expect(p.text, 'xy');
    expect(p.lines, 12);
    expect(p.pages, 0);
    expect(FilePreview.fromJson('nope'), isNull);
    expect(FilePreview.fromJson({'kind': 'pdf', 'pages': 12})!.toJson(), {'kind': 'pdf', 'pages': 12});
  });

  test('FileRef.parse keeps the preview fields', () {
    final r = FileRef.parse(jsonEncode({
      'file_id': 'ab', 'name': 'a.py', 'size': 10, 'mime': 'application/octet-stream',
      'preview': {'kind': 'text', 'text': 'import os', 'lines': 3},
    }))!;
    expect(r.preview!.text, 'import os');
    expect(hasFilePreview(r), isTrue);
    // photos never use the preview pane
    final photo = FileRef.parse(jsonEncode({'file_id': 'cd', 'name': 'a.jpg', 'size': 1, 'mime': 'image/jpeg', 'thumb': base64Encode([0xFF, 0xD8, 0xFF])}))!;
    expect(hasFilePreview(photo), isFalse);
  });

  group('sender side', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('lumora-fpv'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('text/code preview with the line count', () async {
      final f = File('${dir.path}/xu_ly.py')..writeAsStringSync(List.generate(300, (i) => 'print("dòng $i")').join('\n'));
      final p = (await buildFilePreview(f.path))!;
      expect(p.preview!.kind, 'text');
      expect(p.preview!.lines, 300);
      expect(p.preview!.text.startsWith('print("dòng 0")\nprint("dòng 1")'), isTrue);
      expect(utf8.encode(p.preview!.text).length, lessThanOrEqualTo(kSnippetBytes));
      expect(p.preview!.text.endsWith('\n'), isFalse); // cut at a line end
      expect(p.image, isNull);
    });

    test('binary file renamed to .txt gets no preview; unknown types neither', () async {
      final fake = File('${dir.path}/ghi-chu.txt')..writeAsBytesSync([0x50, 0x4B, 0x03, 0x04, ...List.filled(500, 7), 0]);
      expect(await buildFilePreview(fake.path), isNull);
      final zip = File('${dir.path}/a.zip')..writeAsStringSync('hello');
      expect(await buildFilePreview(zip.path), isNull);
    });

    test('countLines counts a last line without newline', () async {
      final f = File('${dir.path}/a.txt')..writeAsStringSync('a\nb\nc');
      expect(await countLines(f.path), 3);
      f.writeAsStringSync('a\nb\n');
      expect(await countLines(f.path), 2);
      f.writeAsStringSync('');
      expect(await countLines(f.path), 0);
    });

    test('page JPEG fits the budget even for a busy page', () {
      final im = img.Image(width: 480, height: 680);
      var seed = 7;
      for (final p in im) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        p.setRgb(seed & 255, (seed >> 8) & 255, (seed >> 16) & 255);
      }
      final bgra = Uint8List(480 * 680 * 4);
      var i = 0;
      for (final p in im) {
        bgra[i++] = p.b.toInt();
        bgra[i++] = p.g.toInt();
        bgra[i++] = p.r.toInt();
        bgra[i++] = 255;
      }
      final jpg = encodePreviewJpeg((bgra, 480, 680));
      expect(jpg, isNotNull);
      expect(jpg!.length, lessThanOrEqualTo(kTargetPreviewImage));
      expect(jpg.sublist(0, 3), [0xFF, 0xD8, 0xFF]);
    });
  });

  // Real PDFium (PDFIUM_PATH=…/libpdfium.so): the sender renders page 1 + counts pages.
  testWidgets('PDF: first page JPEG ≤ budget, ~480 px wide, page count', (tester) async {
    late LocalPreview? p;
    await tester.runAsync(() async {
      Pdfrx.pdfiumModulePath = Platform.environment['PDFIUM_PATH'];
      final cache = Directory('${Directory.systemTemp.path}/lumora-pdfrx')..createSync(recursive: true);
      Pdfrx.getCacheDirectory = () => cache.path;
      await PdfrxEntryFunctions.instance.compute(_noop, 0); // start the worker first (stalls otherwise)
      await PdfrxEntryFunctions.instance.init();
      p = await buildFilePreview('assets/mock/files/sample.pdf', timeout: const Duration(seconds: 20));
    });
    expect(p, isNotNull);
    expect(p!.preview!.kind, 'pdf');
    expect(p!.preview!.pages, 3);
    expect(p!.width, 480);
    expect(p!.height, closeTo(480 * 842 / 595, 2));
    expect(p!.image!.length, lessThanOrEqualTo(kTargetPreviewImage));
    final decoded = img.decodeJpg(p!.image!)!;
    // the page is white with dark text near the top-left
    expect(decoded.getPixel(5, decoded.height - 5).r, greaterThan(240));
    // a damaged PDF gives no preview (and never throws)
    final bad = File('${Directory.systemTemp.path}/lumora-bad.pdf')..writeAsBytesSync(utf8.encode('%PDF-1.4 rác'));
    late LocalPreview? q;
    await tester.runAsync(() async => q = await buildFilePreview(bad.path));
    expect(q, isNull);
  }, skip: Platform.environment['PDFIUM_PATH'] == null);

  test('mock API has previews for a .pdf, .py, .txt, .md and .csv', () async {
    final api = MockLumoraApi(timers: false);
    await api.start({});
    final convs = await api.conversations();
    final nam = convs.firstWhere((c) => c.title.contains('Hoàng Nam')).id;
    final files = (await api.messages(nam)).where((m) => m.isFile).map((m) => FileRef.parse(m.body)!).toList();
    final byExt = {for (final f in files) f.name.split('.').last: f};
    for (final e in ['pdf', 'py', 'txt', 'md', 'csv']) {
      expect(byExt[e]?.preview, isNotNull, reason: e);
    }
    expect(byExt['pdf']!.thumb, isNotNull);
    expect(byExt['pdf']!.preview!.pages, 3);
    expect(byExt['py']!.preview!.text, contains('import hashlib'));
    // `files` returns the preview too
    final list = await api.request('files');
    expect((list as List).any((f) => f['preview'] != null), isTrue);
  });

  group('bubbles', () {
    Future<(AppServices, List<Message>)> pumpNamChat(WidgetTester tester, {ThemeMode theme = ThemeMode.dark}) async {
      setSize(tester, const Size(430, 900));
      final sv = await makeServices(tester, theme: theme);
      final nam = sv.chat.sorted.firstWhere((c) => c.title.contains('Hoàng Nam')).id;
      final msgs = (await tester.runAsync(() => sv.api.messages(nam)))!.where((m) => m.isFile).toList();
      return (sv, msgs);
    }

    Future<void> pumpCards(WidgetTester tester, AppServices sv, List<Message> msgs) async {
      await tester.pumpWidget(LumoraApp(
        services: sv,
        overlays: false,
        home: Scaffold(
          body: ListView(padding: const EdgeInsets.all(12), children: [
            for (final m in msgs) Padding(padding: const EdgeInsets.only(bottom: 12), child: FileCard(message: m, ref: FileRef.parse(m.body)!)),
          ]),
        ),
      ));
      await settle(tester, frames: 4);
    }

    Future<void> done(WidgetTester tester, AppServices sv) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 100));
      sv.dispose();
      resetSize(tester);
    }

    testWidgets('code bubble: language, line count, numbered first lines, no download needed', (tester) async {
      final (sv, msgs) = await pumpNamChat(tester);
      final py = msgs.firstWhere((m) => FileRef.parse(m.body)!.name.endsWith('.py'));
      await pumpCards(tester, sv, [py]);
      expect(find.text('Python · 45 dòng'), findsOneWidget);
      expect(find.textContaining('import', findRichText: true), findsWidgets);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('$kBubbleSnippetLines'), findsOneWidget);
      expect(find.text('${kBubbleSnippetLines + 1}'), findsNothing);
      await done(tester, sv);
    });

    testWidgets('PDF bubble: first page with the page count; tap → sheet → download', (tester) async {
      final (sv, msgs) = await pumpNamChat(tester, theme: ThemeMode.light);
      final pdf = msgs.firstWhere((m) => FileRef.parse(m.body)!.name.endsWith('.pdf'));
      await pumpCards(tester, sv, [pdf]);
      expect(find.text('3 trang'), findsOneWidget);
      expect(find.byType(Image), findsWidgets);
      await tester.tap(find.byType(FilePreviewPane));
      await settle(tester, frames: 6);
      expect(find.text('Trang 1 / 3'), findsOneWidget);
      expect(find.text('Bản xem trước trang đầu · tệp có 3 trang'), findsOneWidget);
      final ref = FileRef.parse(pdf.body)!;
      expect(sv.files.byId[ref.id]?.state, FileState.offered);
      await tester.tap(find.byKey(const ValueKey('fpv_download')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester, frames: 4);
      expect(sv.files.byId[ref.id]?.state, FileState.transferring);
      // the sheet now shows progress instead of the button
      expect(find.byKey(const ValueKey('fpv_download')), findsNothing);
      await done(tester, sv);
    });

    testWidgets('code preview sheet shows the whole snippet with numbers', (tester) async {
      final (sv, msgs) = await pumpNamChat(tester);
      final py = msgs.firstWhere((m) => FileRef.parse(m.body)!.name.endsWith('.py'));
      await pumpCards(tester, sv, [py]);
      await tester.tap(find.byType(FilePreviewPane));
      await settle(tester, frames: 6);
      expect(find.byType(FilePreviewSheet), findsOneWidget);
      expect(find.text('Tải về để xem đầy đủ'), findsOneWidget);
      expect(find.text('Bản xem trước toàn bộ nội dung'), findsOneWidget);
      expect(find.text('20'), findsOneWidget); // beyond the bubble's 6 lines
      await done(tester, sv);
    });

    testWidgets('downloaded file opens the in-app viewer', (tester) async {
      final (sv, msgs) = await pumpNamChat(tester);
      final md = msgs.firstWhere((m) => FileRef.parse(m.body)!.name == 'README.md');
      await pumpCards(tester, sv, [md]);
      expect(find.text('Xem'), findsOneWidget); // suggestion chip
      await tester.tap(find.byType(FilePreviewPane));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.byType(FilePreviewSheet), findsNothing);
      expect(find.text('Xem nguồn'), findsOneWidget); // markdown viewer toggle
      await done(tester, sv);
    });

    testWidgets('plain file without preview keeps the classic card', (tester) async {
      final (sv, _) = await pumpNamChat(tester);
      final m = Message.fromJson({
        'id': 'x1', 'conv': 'd:x', 'author': 'x', 'hlc': 1, 'ts': 1, 'kind': 'file', 'mine': false, 'status': 3,
        'body': {'file_id': 'zz', 'name': 'setup.exe', 'size': 1000},
      });
      await pumpCards(tester, sv, [m]);
      expect(find.byType(FilePreviewPane), findsNothing);
      expect(find.text('setup.exe'), findsOneWidget);
      expect(languageFor('setup.exe'), isNull);
      await done(tester, sv);
    });
  });
}

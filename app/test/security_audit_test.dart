// Security audit regression tests (app side): PIN lockout bypasses, lock
// state tampering, chat-lock leaks, dangerous files, image bombs, weak
// passwords and remote-request spoofing.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lumora/ui/flows.dart' show pendingDeepLink;
import 'package:lumora/ui/shell/palette.dart' show CommandPalette;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/file_safety.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/ui/chats/attachments.dart' show openFile;
import 'package:lumora/state/app_lock.dart';
import 'package:lumora/state/password_policy.dart';
import 'package:lumora/state/settings.dart';
import 'package:lumora/ui/files/files_screen.dart';
import 'package:lumora/ui/theme.dart';
import 'package:provider/provider.dart';
import 'package:lumora/app.dart';

import 'helpers.dart';

/// Minimal PNG: signature + IHDR with the given size (no pixel data).
Uint8List _pngHeader(int w, int h) {
  final b = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add([0, 0, 0, 13])
    ..add('IHDR'.codeUnits);
  final d = ByteData(8)
    ..setUint32(0, w)
    ..setUint32(4, h);
  b
    ..add(d.buffer.asUint8List())
    ..add([8, 6, 0, 0, 0])
    ..add([0, 0, 0, 0]);
  return b.toBytes();
}

/// Minimal baseline JPEG header: SOI, APP0 stub, SOF0 with the given size.
Uint8List _jpegHeader(int w, int h) => Uint8List.fromList([
      0xFF, 0xD8, // SOI
      0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, // APP0 (2 payload bytes)
      0xFF, 0xC0, 0x00, 0x11, 0x08, h >> 8, h & 0xff, w >> 8, w & 0xff, 3, //
      1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1,
    ]);

void main() {
  // ------------------------------------------------------------ PIN storage
  group('PIN hash format', () {
    test('a stored hash with an empty digest never matches', () {
      // Tampered / truncated record: zero-length digest made every PIN "right".
      expect(AppLock.checkPin('0000', 'pbkdf2-sha256\$1\$AAAAAAAAAAAAAAAAAAAAAA==\$'), isFalse);
      expect(AppLock.checkPin('0000', 'pbkdf2-sha256\$1\$\$AAAA'), isFalse, reason: 'no salt / short digest');
      final good = AppLock.hashPin('2468', iterations: 10);
      expect(AppLock.checkPin('2468', good), isTrue);
    });
  });

  // ------------------------------------------------------------ lockout
  group('PIN lockout', () {
    late DateTime now;
    late Duration up;
    late Settings st;
    late AppLock lock;
    setUp(() {
      now = DateTime(2026, 1, 1, 12);
      up = Duration.zero;
      st = Settings();
      lock = AppLock(st, clock: () => now, uptime: () => up);
      lock.setPin('1357');
    });
    tearDown(() => lock.detach());

    var next = 1000;
    // different wrong PINs (the same wrong PIN only counts once)
    Future<void> fiveWrong() async {
      for (var i = 0; i < AppLock.maxTries; i++) {
        await lock.tryUnlock('${next++}');
      }
    }

    test('moving the wall clock forward does not skip the wait', () async {
      await fiveWrong();
      expect(lock.waitSeconds, 30);
      now = now.add(const Duration(days: 365)); // attacker changes the clock
      expect(lock.waitSeconds, greaterThan(0));
      expect(await lock.tryUnlock('1357'), isFalse);
      up += const Duration(seconds: 31); // real time passes
      expect(lock.waitSeconds, 0);
      expect(await lock.tryUnlock('1357'), isTrue);
    });

    test('a clock set far back cannot lock the owner out for longer than the wait', () async {
      await fiveWrong();
      now = now.subtract(const Duration(days: 30));
      expect(lock.waitSeconds, lessThanOrEqualTo(30));
    });

    test('after 50 different wrong PINs only the recovery phrase helps (restart + clock tricks)', () async {
      for (var i = 0; i < AppLock.maxWrong; i++) {
        await lock.tryUnlock('${next++}');
        // simulate an app restart with the clock moved past the wait
        now = now.add(const Duration(days: 1));
        lock.detach();
        lock = AppLock(st, clock: () => now, uptime: () => up);
      }
      expect(lock.exhausted, isTrue);
      expect(await lock.tryUnlock('1357'), isFalse, reason: 'right PIN refused: guessing budget used up');
      lock.removePin(); // recovery phrase path
      expect(lock.exhausted, isFalse);
    });
  });

  // ------------------------------------------------------------ tampering
  group('lock state lives in the core', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('lumora-sec-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('editing ui_settings.json does not turn the lock off or unhide locked chats', () async {
      final api = MockLumoraApi(timers: false);
      final f = File('${tmp.path}/ui_settings.json');
      // 1) normal use: PIN + app lock + one locked chat
      var st = await Settings.load(f);
      var lock = AppLock(st, api: api);
      await lock.loadSecrets();
      lock.setPin('1357');
      lock.setChatLocked('d:SECRET', true);
      // wait for the (atomic) settings write itself, not a fixed delay (flaky on slow CI)
      await Future<void>.delayed(Duration.zero);
      await st.flushed();
      lock.detach();

      // 2) attacker edits the plain settings file while the app is closed
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      j['app_lock_on'] = false;
      j['pin_set'] = false;
      j['locked_chats'] = <String>[];
      await f.writeAsString(jsonEncode(j));

      // 3) next start
      st = await Settings.load(f);
      lock = AppLock(st, api: api);
      await lock.loadSecrets();
      expect(st.appLock, isTrue);
      expect(lock.locked, isTrue);
      expect(st.lockedChats, contains('d:SECRET'));
      expect(lock.isChatHidden('d:SECRET'), isTrue);
      lock.detach();
    });

    test('a PIN planted in the old settings format is dropped once the core answers', () async {
      final api = MockLumoraApi(timers: false);
      await api.uiSecretSet(AppLock.secretKey, jsonEncode({'hash': AppLock.hashPin('1357', iterations: 10), 'fails': 0, 'until': 0, 'level': 0}));
      final f = File('${tmp.path}/ui_settings.json');
      await f.writeAsString(jsonEncode({'pin_hash': AppLock.hashPin('0000', iterations: 10), 'pin_set': true, 'pin_len': 4}));
      final st = await Settings.load(f);
      final lock = AppLock(st, api: api);
      // the attacker types their own PIN in the moment before the core is read
      await lock.tryUnlock('0000');
      await lock.loadSecrets();
      expect(lock.locked, isTrue, reason: 'the real PIN (from the core) is required');
      expect(await lock.tryUnlock('0000'), isFalse);
      expect(await lock.tryUnlock('1357'), isTrue);
      lock.detach();
    });
  });

  // ------------------------------------------------------------ files
  group('dangerous files', () {
    test('executables, scripts and installers are flagged', () {
      for (final n in [
        'setup.exe', 'run.BAT', 'x.cmd', 'a.ps1', 'b.sh', 'app.apk', 'pkg.msi', 'saver.scr', 'link.lnk', 'tool.jar',
        'x.js', 'y.vbs', 'page.html', 'page.htm', 'pic.svg', 'start.desktop', 'a.AppImage', 'b.deb', 'c.rpm', 'd.dmg',
        'e.pkg', 'f.command', 'g.py', 'h.reg', 'i.hta', 'j.wsf', 'k.cpl', 'l.com', 'm.pif', 'n.iso', 'o.img',
        'invoice.pdf.exe', 'evil.exe.', 'evil.exe  ', 'photo\u202Egpj.exe', 'a.e\u200Bxe',
      ]) {
        expect(isDangerousFileName(n), isTrue, reason: n);
      }
      for (final n in ['photo.jpg', 'report.pdf', 'notes.txt', 'song.mp3', 'clip.mp4', 'sheet.xlsx', 'exe', 'README']) {
        expect(isDangerousFileName(n), isFalse, reason: n);
      }
    });

    test('bidi / invisible characters are removed from shown names', () {
      expect(safeDisplayName('photo\u202Egpj.exe'), 'photogpj.exe');
      expect(safeDisplayName('a\u200B\u2066b.txt'), 'ab.txt');
    });
  });

  group('image bombs', () {
    test('huge declared dimensions are refused before decoding', () {
      expect(imageDimensions(_pngHeader(320, 240)), (320, 240));
      expect(isSafeImageBytes(_pngHeader(320, 240)), isTrue);
      expect(isSafeImageBytes(_pngHeader(30000, 30000)), isFalse);
      expect(imageDimensions(_jpegHeader(640, 480)), (640, 480));
      expect(isSafeImageBytes(_jpegHeader(65000, 65000)), isFalse);
      // unknown format: refused for peer thumbnails
      expect(isSafeImageBytes(Uint8List.fromList(List.filled(64, 7))), isFalse);
    });
  });

  // ------------------------------------------------------------ passwords
  group('password policy', () {
    test('weak passwords are refused', () {
      for (final p in ['12345678', 'password', 'aaaaaaaa', 'abcdefgh', 'qwertyui', '01012000', 'matkhau123', 'abcabcabc', 'Password1']) {
        expect(passwordProblem(p), isNotNull, reason: p);
      }
      expect(passwordProblem('short'), 'pass_too_short');
      for (final p in ['mây trôi 2026', 'Correct-Horse-Battery', 'ca phe sua da 3 ly']) {
        expect(passwordProblem(p), isNull, reason: p);
      }
    });
  });

  // ------------------------------------------------------------ chat lock leaks
  testWidgets('files of a locked chat stay out of the Files screen', (tester) async {
    setSize(tester, const Size(1200, 900));
    final sv = await makeServices(tester);
    await tester.runAsync(() => sv.files.load());
    final all = sv.files.sorted;
    final f = all.firstWhere((x) => x.conv.isNotEmpty && all.where((y) => y.name == x.name).length == 1);
    sv.appLock.setPin('2580', appLock: false);
    sv.appLock.setChatLocked(f.conv, true);
    sv.appLock.hideLockedChats();
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<AppServices>.value(value: sv),
        ChangeNotifierProvider.value(value: sv.settings),
        ChangeNotifierProvider.value(value: sv.files),
        ChangeNotifierProvider.value(value: sv.contacts),
        ChangeNotifierProvider.value(value: sv.appLock),
      ],
      child: MaterialApp(theme: buildTheme(Brightness.dark), home: const FilesScreen()),
    ));
    await settle(tester, frames: 3);
    expect(find.text(f.name), findsNothing);
    sv.appLock.openLockedChats();
    await settle(tester, frames: 2);
    expect(find.text(f.name), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    sv.dispose();
    resetSize(tester);
  });

  testWidgets('opening a received program asks first (and Cancel keeps it closed)', (tester) async {
    final settings = Settings()..locale = 'en';
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Builder(builder: (c) => TextButton(onPressed: () => openFile(c, '/tmp/lumora-none/invoice.pdf\u202Eexe.scr'), child: const Text('open'))),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('This file can run a program'), findsOneWidget);
    expect(find.textContaining('invoice.pdfexe.scr'), findsOneWidget, reason: 'real name shown without the direction override');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('This file can run a program'), findsNothing);
  });

  testWidgets('keyboard shortcuts and deep links do not act behind the lock screen', (tester) async {
    setSize(tester, const Size(1440, 900));
    final sv = await makeServices(tester);
    sv.appLock.setPin('2580');
    sv.appLock.lock();
    await tester.pumpWidget(LumoraApp(services: sv));
    await settle(tester);
    // Ctrl+K would open the command palette (chat titles, message search)
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester, frames: 3);
    expect(find.byType(CommandPalette), findsNothing, reason: 'no palette (chat titles, message search) under the lock');
    // a deep link waits for the unlock
    pendingDeepLink.value = 'lumora://add/${'A' * 52}';
    await settle(tester, frames: 3);
    expect(pendingDeepLink.value, isNotNull);
    for (final k in [LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit5, LogicalKeyboardKey.digit8, LogicalKeyboardKey.digit0]) {
      await tester.sendKeyEvent(k);
    }
    await settle(tester, frames: 4);
    expect(sv.appLock.locked, isFalse, reason: 'fails=${sv.settings.pinFails} wait=${sv.appLock.waitSeconds} ready=${sv.appLock.ready}');
    expect(pendingDeepLink.value, isNull, reason: 'handled once unlocked');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    sv.dispose();
    resetSize(tester);
  });

  test('remote request: a stranger cannot borrow a friend\'s name', () {
    final r = RemoteRequest.fromJson({'session': 's', 'peer': 'P' * 52, 'name': 'Mẹ', 'short_id': 'ABCD-EFGH'});
    expect(r.shortId, 'ABCD-EFGH');
  });
}

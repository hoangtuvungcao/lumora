// App lock (PIN), copy & paste sync during remote sessions, session chat.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/ui/widgets/secure_input.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/app_lock.dart';
import 'package:lumora/state/data_rescue.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/chats/chat_list.dart';
import 'package:lumora/state/settings.dart';
import 'package:lumora/ui/lock/app_lock_screen.dart';
import 'package:lumora/ui/shell/home_shell.dart';

import 'helpers.dart';

/// Fake system clipboard behind the platform channel.
String? _clip;
void _mockClipboard(WidgetTester tester) {
  _clip = null;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    switch (call.method) {
      case 'Clipboard.setData':
        _clip = (call.arguments as Map)['text'] as String?;
        return null;
      case 'Clipboard.getData':
        return _clip == null ? null : {'text': _clip};
      case 'Clipboard.hasStrings':
        return {'value': _clip != null};
    }
    return null;
  });
}

void main() {
  group('PIN hashing', () {
    test('salted hash round-trips and rejects other PINs', () {
      final h = AppLock.hashPin('2468');
      expect(h, startsWith('pbkdf2-sha512\$'));
      expect(h.contains('2468'), isFalse);
      expect(AppLock.checkPin('2468', h), isTrue);
      expect(AppLock.checkPin('2469', h), isFalse);
      expect(AppLock.checkPin('2468', ''), isFalse);
      // Same PIN, different salt → different hash.
      expect(AppLock.hashPin('2468'), isNot(h));
    });

    test('PBKDF2-HMAC-SHA256 matches RFC 7914 test vector', () {
      final out = AppLock.pbkdf2('passwd'.codeUnits, 'salt'.codeUnits, 1, 64);
      expect(out.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(), '55ac046e56e3089f');
    });

    test('PIN rules: 4–6 digits', () {
      expect(AppLock.isValidPin('123'), isFalse);
      expect(AppLock.isValidPin('1234'), isTrue);
      expect(AppLock.isValidPin('123456'), isTrue);
      expect(AppLock.isValidPin('1234567'), isFalse);
      expect(AppLock.isValidPin('12a4'), isFalse);
    });

    test('recovery phrase compare ignores case, spacing and dashes', () {
      expect(AppLock.normalizePhrase('  Ánh  sao-biển\nxanh '), AppLock.normalizePhrase('ánh sao biển xanh'));
    });
  });

  group('lockout and auto-lock', () {
    late DateTime now;
    late Settings st;
    late AppLock lock;
    setUp(() {
      now = DateTime(2026, 1, 1, 12);
      st = Settings();
      lock = AppLock(st, clock: () => now);
      lock.setPin('1357');
    });
    tearDown(() => lock.detach());

    test('5 wrong tries → wait 30 s, then 60 s', () async {
      for (var i = 0; i < 4; i++) {
        expect(await lock.tryUnlock('000$i'), isFalse);
      }
      expect(lock.waitSeconds, 0);
      expect(lock.triesLeft, 1);
      expect(await lock.tryUnlock('0004'), isFalse);
      expect(lock.waitSeconds, 30);
      // Even the right PIN is refused during the wait.
      expect(await lock.tryUnlock('1357'), isFalse);
      now = now.add(const Duration(seconds: 31));
      for (var i = 0; i < 5; i++) {
        await lock.tryUnlock('001$i');
      }
      expect(lock.waitSeconds, 60);
      now = now.add(const Duration(seconds: 61));
      expect(await lock.tryUnlock('1357'), isTrue);
      expect(st.pinLockLevel, 0);
    });

    test('locks on resume only after the chosen delay', () {
      st.autoLockSec = 60;
      lock.didChangeAppLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(seconds: 30));
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(lock.locked, isFalse);
      lock.didChangeAppLifecycleState(AppLifecycleState.hidden);
      now = now.add(const Duration(seconds: 61));
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(lock.locked, isTrue);
    });

    test('"immediately" locks as soon as the app is left', () {
      st.autoLockSec = 0;
      lock.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(lock.locked, isTrue);
    });

    test('notifications hide content while the lock is on', () {
      expect(st.hideNotificationContent, isTrue);
      lock.removePin();
      expect(st.hideNotificationContent, isFalse);
      st.notifyPreview = false;
      expect(st.hideNotificationContent, isTrue);
    });
  });

  testWidgets('lock screen covers the app and unlocks with the keyboard', (tester) async {
    setSize(tester, const Size(390, 844), dpr: 2);
    final sv = await makeServices(tester);
    sv.appLock.setPin('2580');
    sv.appLock.lock();
    await tester.pumpWidget(LumoraApp(services: sv));
    await settle(tester);
    expect(find.byType(PinLockScreen), findsOneWidget);

    // Wrong PIN: stays locked.
    for (final k in [LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit1]) {
      await tester.sendKeyEvent(k);
    }
    await settle(tester, frames: 3);
    expect(sv.appLock.locked, isTrue);
    expect(sv.settings.pinFails, 1, reason: 'one wrong try recorded');
    expect(find.textContaining('Sai mã PIN. Bạn còn thử được tiếp'), findsOneWidget);

    // Right PIN via the on-screen keypad and the keyboard.
    await tester.tap(find.text('2'));
    await tester.tap(find.text('5'));
    await tester.sendKeyEvent(LogicalKeyboardKey.numpad8);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await settle(tester, frames: 4);
    expect(sv.appLock.locked, isFalse);
    expect(find.byType(PinLockScreen), findsNothing);
    expect(find.byType(HomeShell), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    sv.dispose();
    resetSize(tester);
  });

  testWidgets('forgot PIN: the recovery phrase removes it', (tester) async {
    setSize(tester, const Size(1440, 900));
    final sv = await makeServices(tester);
    sv.appLock.setPin('2580');
    sv.appLock.lock();
    await tester.pumpWidget(LumoraApp(services: sv));
    await settle(tester);
    await tester.tap(find.text('Quên mã PIN?'));
    await settle(tester, frames: 4);
    final phrase = (await tester.runAsync(() => sv.api.recoveryPhrase()))!;
    await tester.enterText(find.descendant(of: find.byType(RecoveryPhraseInput), matching: find.byType(TextField)).first, 'sai hoàn toàn');
    await tester.runAsync(() async {
      await tester.tap(find.text('Gỡ mã PIN'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await settle(tester, frames: 3);
    expect(sv.settings.appLock, isTrue);
    await tester.enterText(find.descendant(of: find.byType(RecoveryPhraseInput), matching: find.byType(TextField)).first, phrase.toUpperCase());
    await tester.runAsync(() async {
      await tester.tap(find.text('Gỡ mã PIN'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await settle(tester, frames: 4);
    expect(sv.settings.appLock, isFalse);
    expect(sv.appLock.locked, isFalse);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
    sv.dispose();
    resetSize(tester);
  });

  testWidgets('copy & paste: incoming text lands in the clipboard and is not sent back', (tester) async {
    _mockClipboard(tester);
    final sv = await makeServices(tester);
    final api = sv.api as MockLumoraApi;
    final peer = sv.contacts.friends[3].peer;
    api.debugAddRemoteSession('s9', peer);

    await tester.runAsync(() async {
      sv.remote.onState({'session': 's9', 'peer': peer, 'state': 'active', 'role': 'viewer', 'width': 1920, 'height': 1080, 'stream': 100, 'control': true});
      _clip = 'old local text';
      await sv.remote.pollClipboard(); // first read only records what is there
      expect(api.clipboardSent, isEmpty);

      // The partner copied a password.
      await sv.remote.onClipboard({'peer': peer, 'text': 'Mật-khẩu#2026'});
      expect(_clip, 'Mật-khẩu#2026');
      await sv.remote.pollClipboard();
      await sv.remote.pollClipboard();
      expect(api.clipboardSent, isEmpty, reason: 'received text must not echo back');

      // Something from another device is ignored.
      await sv.remote.onClipboard({'peer': sv.contacts.friends[0].peer, 'text': 'spam'});
      expect(_clip, 'Mật-khẩu#2026');

      // Local copy → sent once; the mock echoes it back, which must not loop.
      _clip = 'copied here';
      await sv.remote.pollClipboard();
      await Future<void>.delayed(const Duration(milliseconds: 30)); // echo event
      await sv.remote.pollClipboard();
      await sv.remote.pollClipboard();
      expect(api.clipboardSent, ['copied here']);
      expect(_clip, 'copied here');

      // Turned off in Settings: nothing crosses either way.
      sv.settings.update((s) => s.remoteClipboard = false);
      await sv.remote.onClipboard({'peer': peer, 'text': 'blocked'});
      expect(_clip, 'copied here');
      _clip = 'not sent';
      await sv.remote.pollClipboard();
      expect(api.clipboardSent, ['copied here']);

      // Session over: polling stops.
      sv.settings.update((s) => s.remoteClipboard = true);
      sv.remote.onState({'session': 's9', 'peer': peer, 'state': 'ended', 'role': 'viewer'});
      _clip = 'after end';
      await sv.remote.pollClipboard();
      expect(api.clipboardSent, ['copied here']);

      // A view-only session never shares the clipboard, in either direction.
      api.debugAddRemoteSession('s10', peer);
      sv.remote.onState({'session': 's10', 'peer': peer, 'state': 'active', 'role': 'viewer', 'width': 1920, 'height': 1080, 'stream': 100, 'control': false});
      await sv.remote.onClipboard({'peer': peer, 'text': 'host secret'});
      expect(_clip, 'after end');
      _clip = 'viewer text';
      await sv.remote.pollClipboard();
      await sv.remote.pollClipboard();
      expect(api.clipboardSent, ['copied here']);
      sv.remote.onState({'session': 's10', 'peer': peer, 'state': 'ended', 'role': 'viewer'});
      // …and the host side doesn't push its clipboard to a view-only viewer.
      sv.remote.onState({'session': 'h1', 'peer': peer, 'state': 'active', 'role': 'host', 'width': 1920, 'height': 1080, 'control': false});
      _clip = 'host clipboard';
      await sv.remote.pollClipboard();
      await sv.remote.pollClipboard();
      expect(api.clipboardSent, ['copied here']);
      await sv.remote.onClipboard({'peer': peer, 'text': 'from viewer'});
      expect(_clip, 'host clipboard');
      sv.remote.onState({'session': 'h1', 'peer': peer, 'state': 'ended', 'role': 'host'});
    });

    sv.dispose();
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('remote viewer: chat panel opens and counts unread while closed', (tester) async {
    setSize(tester, const Size(1440, 900));
    _mockClipboard(tester);
    final sv = await makeServices(tester);
    final peer = sv.contacts.friends[3].peer;
    sv.remote.onState({'session': 's2', 'peer': peer, 'state': 'active', 'role': 'viewer', 'width': 1920, 'height': 1080, 'stream': 100, 'control': true});
    await tester.pumpWidget(LumoraApp(services: sv));
    await settle(tester);

    sv.chat.onMessage({
      'id': 'f' * 32, 'conv': 'd:$peer', 'author': peer, 'hlc': 1, 'ts': DateTime.now().millisecondsSinceEpoch,
      'kind': 'text', 'body': {'text': 'Bạn thấy màn hình chưa?'}, 'status': 2, 'mine': false,
    }, myPeer: sv.session.me!.peer);
    await settle(tester, frames: 2);
    expect(find.text('1'), findsWidgets, reason: 'unread badge on the Chat button');

    await tester.tap(find.byTooltip('Trò chuyện').last);
    await settle(tester);
    expect(find.text('Trò chuyện trong lúc điều khiển'), findsOneWidget);
    expect(find.text('Bạn thấy màn hình chưa?'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
    sv.dispose();
    resetSize(tester);
  });

  for (final w in [320.0, 360.0, 390.0]) {
    testWidgets('remote viewer toolbar + chat fit at ${w.toInt()}dp (no overflow)', (tester) async {
      setSize(tester, Size(w, 760), dpr: 2);
      _mockClipboard(tester);
      final sv = await makeServices(tester);
      final peer = sv.contacts.friends.firstWhere((c) => c.name == 'Trần Bảo Ngọc').peer;
      sv.remote.onState({'session': 's2', 'peer': peer, 'state': 'active', 'role': 'viewer', 'width': 1920, 'height': 1080, 'stream': 100, 'control': true});
      await tester.pumpWidget(LumoraApp(services: sv));
      await settle(tester);
      sv.remote.clipboardPulse.value++;
      await settle(tester, frames: 3);
      await tester.tap(find.byTooltip('Thêm').last);
      await settle(tester, frames: 4);
      await tester.tap(find.text('Trò chuyện').last);
      await settle(tester, frames: 4);
      expect(find.text('Trò chuyện trong lúc điều khiển'), findsOneWidget);
      // The panel starts below the toolbar: its header is not covered.
      final header = tester.getRect(find.text('Trò chuyện trong lúc điều khiển'));
      final end = tester.getRect(find.byTooltip('Kết thúc'));
      expect(header.top, greaterThan(end.bottom));
      expect(end.right, lessThanOrEqualTo(w));

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 11));
      sv.dispose();
      resetSize(tester);
    });
  }

  testWidgets('chat lock: hidden from the list and search, folder opens with the PIN', (tester) async {
    setSize(tester, const Size(390, 844), dpr: 2);
    final sv = await makeServices(tester);
    final c = sv.chat.sorted.firstWhere((c) => !c.isSaved && !c.isGroup);
    sv.appLock.setPin('1470', appLock: false);
    sv.appLock.setChatLocked(c.id, true);
    expect(sv.settings.appLock, isFalse, reason: 'chat lock alone does not lock the whole app');
    await tester.pumpWidget(LumoraApp(services: sv));
    await settle(tester);
    expect(find.text('Đã khoá'), findsOneWidget);
    expect(find.descendant(of: find.byType(ConversationTile), matching: find.text(c.title)), findsNothing);

    // Notices from a locked chat never show who or what.
    sv.notices.add(Notice(kind: NoticeKind.mention, title: 'Ai đó', body: 'bí mật', conv: c.id));
    expect(sv.notices.items.first.body, isEmpty);
    expect(sv.notices.items.first.title, 'Tin nhắn trong cuộc trò chuyện đã khoá');

    await tester.tap(find.text('Đã khoá'));
    await settle(tester, frames: 4);
    for (final d in ['1', '4', '7', '0']) {
      await tester.tap(find.text(d).last);
    }
    await settle(tester, frames: 4);
    expect(sv.appLock.chatsOpen, isTrue);
    expect(find.descendant(of: find.byType(ConversationTile), matching: find.text(c.title)), findsOneWidget);

    // Leaving the app hides the folder again.
    sv.appLock.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(sv.appLock.chatsOpen, isFalse);

    // Forgot PIN: the reset also unlocks the chats.
    sv.appLock.removePin();
    expect(sv.settings.lockedChats, isEmpty);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
    sv.dispose();
    resetSize(tester);
  });

  testWidgets('forgot data password: old data set aside, account restored, can switch back', (tester) async {
    final sv = await makeServices(tester, start: false);
    sv.settings.hasPassphrase = true;
    final rescue = DataRescue(sv);
    final phrase = (await tester.runAsync(() => sv.api.recoveryPhrase()))!;
    await tester.runAsync(() => rescue.restoreFresh(phrase: phrase));
    expect(sv.session.phase, SessionPhase.ready);
    expect(sv.settings.hasPassphrase, isFalse);
    expect(rescue.aside.single.locked, isTrue);
    expect(rescue.aside.single.when, isNotNull);

    // "Try old password": the old folder comes back, the new one is kept.
    await tester.runAsync(() => rescue.switchTo(rescue.aside.single.path));
    expect(sv.session.phase, SessionPhase.locked);
    expect(rescue.aside.single.locked, isFalse);
    await tester.pump(const Duration(seconds: 3));
    sv.dispose();
  });
}

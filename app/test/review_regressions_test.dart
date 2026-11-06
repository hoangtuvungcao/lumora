// Regression tests for the pre-release review findings (numbers = finding #).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/app_lock.dart';
import 'package:lumora/state/data_rescue.dart';
import 'package:lumora/state/settings.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/lock/app_lock_screen.dart' show PinPad;
import 'package:lumora/ui/settings/security_checkup.dart' show showRecoveryPhraseDialog;
import 'package:lumora/ui/widgets/sensitive_gate.dart';

import 'helpers.dart';

/// Records `mark_read` calls and stop/halt on top of the mock.
class _Spy extends MockLumoraApi {
  _Spy() : super(timers: false);

  /// Pretend to be the real core so file-system code paths run.
  bool fsMode = false;
  @override
  bool get isMock => !fsMode && super.isMock;
  final reads = <String>[];
  int stops = 0, halts = 0;
  final sets = <Map<String, dynamic>>[];

  /// Core keys `settings_get` leaves out (an older core).
  Set<String> hiddenKeys = {};

  /// `ui_secret_set` of the PIN record fails (core busy / disk full).
  bool failPinWrite = false;

  /// `call_answer` fails (call already over, network…).
  bool failAnswer = false;
  @override
  Future<dynamic> request(String cmd, [Map<String, dynamic> args = const {}]) async {
    if (cmd == 'mark_read') reads.add(args['conv'].toString());
    if (cmd == 'settings_set') sets.add(Map.of(args));
    if (cmd == 'ui_secret_set' && args['key'] == 'ui.pin' && failPinWrite) throw ApiException('internal', cmd: cmd);
    if (cmd == 'call_answer' && args['accept'] == true && failAnswer) throw ApiException('Cuộc gọi đã kết thúc.', cmd: cmd, code: 'err.no_call');
    final r = await super.request(cmd, args);
    if (cmd == 'settings_get' && r is Map) return Map<String, dynamic>.of(r.cast<String, dynamic>())..removeWhere((k, _) => hiddenKeys.contains(k));
    return r;
  }

  @override
  Future<void> stop() async {
    stops++;
    await super.stop();
  }

  @override
  Future<void> halt() async {
    halts++;
    await super.halt();
  }
}

Future<void> _flush(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await t.pump();
  await t.pump();
}

void main() {
  group('#2 mark read only while the chat is on screen', () {
    testWidgets('phone: closing the chat page stops auto-reading', (t) async {
      setSize(t, const Size(390, 844), dpr: 2);
      final sv = await makeServices(t);
      final spy = sv.api as MockLumoraApi;
      await t.pumpWidget(LumoraApp(services: sv));
      await settle(t);
      final conv = sv.chat.sorted.firstWhere((c) => !c.isGroup && !c.isSaved).id;
      final ctx = t.element(find.byType(Scaffold).first);
      sv.nav.openConv(conv);
      Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => ChatView(conv: conv)));
      await settle(t);
      expect(sv.nav.readingConv, conv);

      Navigator.of(t.element(find.byType(ChatView))).pop();
      await settle(t);
      expect(find.byType(ChatView), findsNothing);
      expect(sv.nav.conv, isNull, reason: 'leaving the page leaves the conversation');
      expect(sv.nav.readingConv, isNull);

      final before = sv.chat.convs[conv]!.unread;
      spy.simulateIncomingMessage(conv, 'still there?');
      await _flush(t);
      expect(sv.chat.convs[conv]!.unread, greaterThan(before), reason: 'a message to a closed chat stays unread');

      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 100));
      sv.dispose();
      resetSize(t);
    });

    testWidgets('locked app or background: no auto-read', (t) async {
      final sv = await makeServices(t);
      final conv = sv.chat.sorted.firstWhere((c) => !c.isGroup && !c.isSaved).id;
      sv.nav.openConv(conv);
      sv.nav.chatShown(conv);
      expect(sv.nav.readingConv, conv);
      sv.appLock.locked = true;
      expect(sv.nav.readingConv, isNull);
      sv.appLock.locked = false;
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(sv.nav.readingConv, isNull);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(sv.nav.readingConv, conv);
      sv.nav.chatHidden(conv, pushed: true);
      expect(sv.nav.readingConv, isNull);
      await t.pump(const Duration(seconds: 100));
      sv.dispose();
    });

    testWidgets('chat B over chat A: closing B falls back to A', (t) async {
      final sv = await makeServices(t);
      sv.nav.openConv('d:a');
      sv.nav.chatShown('d:a');
      sv.nav.openConv('d:b');
      sv.nav.chatShown('d:b');
      sv.nav.chatHidden('d:b', pushed: true);
      await t.pump();
      expect(sv.nav.conv, 'd:a');
      sv.dispose();
    });
  });

  testWidgets('#3 opening kept data halts the core instead of closing its events', (t) async {
    final api = _Spy();
    final sv = await makeServices(t, api: api);
    final dir = sv.dataDir;
    final kept = '$dir.kept-20260101-101010';
    await t.runAsync(() async {
      for (final d in [dir, kept]) {
        if (Directory(d).existsSync()) await Directory(d).delete(recursive: true);
        await Directory(d).create(recursive: true);
      }
    });
    expect(sv.session.phase, SessionPhase.ready);
    // Only the rescue itself takes the real-folder path (the rest of the app
    // keeps its demo behaviour).
    final rescue = DataRescue(sv);
    api.fsMode = true;
    final ok = await t.runAsync(() => rescue.switchTo(kept));
    api.fsMode = false;
    expect(ok, isTrue);
    // FfiApi.stop() closes the event stream for good; the switch must only halt.
    expect(api.stops, 0);
    expect(api.halts, 1);
    // Events still reach the app after the core is started again.
    final conv = sv.chat.sorted.firstWhere((c) => !c.isGroup && !c.isSaved).id;
    final before = sv.chat.convs[conv]!.unread;
    api.simulateIncomingMessage(conv, 'after the switch');
    await _flush(t);
    expect(sv.chat.convs[conv]!.unread, greaterThan(before));
    await t.runAsync(() async {
      for (final d in Directory(dir).parent.listSync()) {
        if (d.path.startsWith('$dir.') || d.path == dir) await d.delete(recursive: true);
      }
    });
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
  });

  group('Help friends connect (core help_friends)', () {
    testWidgets('switch maps to settings_set help_friends', (t) async {
      final api = _Spy();
      final sv = await makeServices(t, api: api);
      expect(sv.settings.helpFriends, isTrue);
      sv.settings.update((s) => s.helpFriends = false);
      expect(api.sets.any((m) => m['help_friends'] == false), isTrue);
      await t.pump(const Duration(seconds: 1));
      await _flush(t);
      final core = await t.runAsync(() => api.settingsGet());
      expect(core!['help_friends'], isFalse);
      sv.dispose();
    });

    testWidgets('a core without the key is tolerated', (t) async {
      final api = _Spy()..hiddenKeys = {'help_friends'};
      final sv = await makeServices(t, api: api);
      expect(sv.session.phase, SessionPhase.ready);
      expect(api.sets.any((m) => m.containsKey('help_friends')), isFalse, reason: 'start-up reconcile only touches keys the core has');
      sv.dispose();
    });

    test('saved with the other settings', () {
      expect((Settings()..helpFriends = false).toJson()['help_friends'], isFalse);
    });
  });

  group('#1 secrets need the owner and never open while the screen is shared', () {
    Future<BuildContext> app(WidgetTester t, AppServices sv) async {
      setSize(t, const Size(390, 844), dpr: 2);
      await t.pumpWidget(LumoraApp(services: sv));
      await settle(t);
      return t.element(find.byType(Scaffold).first);
    }

    testWidgets('blocked while this device is being controlled', (t) async {
      final sv = await makeServices(t);
      final ctx = await app(t, sv);
      sv.remote.host = const RemoteState(session: 's1', peer: 'p', phase: RemotePhase.active, viewer: false);
      bool? ok;
      unawaited(confirmOwner(ctx, title: 'x').then((v) => ok = v));
      await settle(t);
      expect(find.text('Không thể mở khi đang có người điều khiển máy.'), findsOneWidget);
      await t.tap(find.text('Đóng'));
      await settle(t);
      expect(ok, isFalse);
      // the phrase screen itself refuses too, without asking the core
      unawaited(showRecoveryPhraseDialog(ctx));
      await settle(t);
      expect(find.text('Không thể mở khi đang có người điều khiển máy.'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 100));
      sv.dispose();
      resetSize(t);
    });

    testWidgets('a PIN is asked before the phrase / backup / link code', (t) async {
      final sv = await makeServices(t);
      sv.appLock.setPin('2580', appLock: false);
      await t.pump();
      final ctx = await app(t, sv);
      bool? ok;
      unawaited(confirmOwner(ctx, title: 'Cụm từ khôi phục').then((v) => ok = v));
      await settle(t);
      expect(find.byType(PinPad), findsOneWidget);
      await t.tap(find.byTooltip('Đóng').last);
      await settle(t);
      expect(ok, isFalse, reason: 'closing the PIN prompt opens nothing');
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 100));
      sv.dispose();
      resetSize(t);
    });

    testWidgets('data password checked by the core when there is no PIN', (t) async {
      final sv = await makeServices(t);
      await t.runAsync(() => sv.api.changePassphrase('', 'mat-khau-dai-123'));
      expect(await t.runAsync(() => sv.api.checkPassphrase('mat-khau-dai-123')), isTrue);
      Object? err;
      await t.runAsync(() => sv.api.checkPassphrase('sai').catchError((Object e) {
            err = e;
            return false;
          }));
      expect(err, isA<ApiException>().having((e) => e.code, 'code', 'err.wrong_passphrase'));
      sv.dispose();
    });
  });

  testWidgets('#12 a linked device verifies the phrase against its account', (t) async {
    final api = _Spy();
    final sv = await makeServices(t, api: api);
    api.debugMakeLinkedDevice();
    expect(await t.runAsync(() => api.phraseCheck(kMockRecoveryPhrase)), isTrue);
    expect(await t.runAsync(() => api.phraseCheck('abandon ' * 23 + 'art')), isFalse);
    sv.dispose();
  });

  group('#4 abandoned onboarding never becomes the account', () {
    late Directory dir;
    setUp(() {
      dir = Directory('/tmp/lumora-test');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
    });
    tearDown(() {
      for (final p in ['/tmp/lumora-test', '/tmp/lumora-test.onboarding']) {
        try {
          FileSystemEntity.isDirectorySync(p) ? Directory(p).deleteSync(recursive: true) : File(p).deleteSync();
        } catch (_) {}
      }
    });

    testWidgets('a half-made identity is wiped at the next launch', (t) async {
      final api = _Spy();
      final sv = await makeServices(t, api: api, start: false);
      File('${dir.path}/keystore.json').writeAsStringSync('{}');
      File('${dir.path}/lumora.db').writeAsStringSync('x');
      File('/tmp/lumora-test.onboarding').writeAsStringSync('now');
      api.fsMode = true;
      await t.runAsync(() => sv.boot());
      api.fsMode = false;
      expect(File('${dir.path}/keystore.json').existsSync(), isFalse);
      expect(File('${dir.path}/lumora.db').existsSync(), isFalse);
      expect(File('/tmp/lumora-test.onboarding').existsSync(), isFalse);
      await t.pump(const Duration(seconds: 100));
      sv.dispose();
    });

    testWidgets('leaving the link step after a restart still deletes its identity', (t) async {
      final api = _Spy();
      final sv = await makeServices(t, api: api, start: false);
      sv.settings.linkPending = true;
      File('${dir.path}/keystore.json').writeAsStringSync('{}');
      api.fsMode = true;
      await t.runAsync(() => sv.abandonLink());
      api.fsMode = false;
      expect(sv.linkCoreRunning, isFalse);
      expect(File('${dir.path}/keystore.json').existsSync(), isFalse);
      await t.pump(const Duration(seconds: 100));
      sv.dispose();
    });

    testWidgets('a phrase restore that really used the phrase marks it saved', (t) async {
      final sv = await makeServices(t, start: false);
      await t.runAsync(() => sv.createIdentity(name: 'Lan', restorePhrase: kMockRecoveryPhrase));
      expect(sv.settings.phraseBackedUp, isTrue, reason: 'the phrase brought it back');
      sv.settings.phraseBackedUp = false;
      await t.pump(const Duration(seconds: 100));
      sv.dispose();
    });
  });

  group('#21 changing the PIN can never lock you out', () {
    testWidgets('hash and length are one record; a failed save keeps the old PIN', (t) async {
      final api = _Spy();
      final sv = await makeServices(t, api: api);
      await t.runAsync(() => sv.appLock.setPin('2580', appLock: false));
      final raw = await t.runAsync<String?>(() => api.uiSecretGet('ui.pin'));
      final rec = jsonDecode(raw!) as Map;
      expect(rec['len'], 4);
      final oldHash = sv.settings.pinHash;
      api.failPinWrite = true;
      Object? err;
      await t.runAsync(() async {
        try {
          await sv.appLock.setPin('135790', appLock: false);
        } catch (e) {
          err = e;
        }
      });
      expect(err, isNotNull);
      expect(sv.settings.pinLength, 4, reason: 'the pad keeps the length of the PIN that is really saved');
      expect(sv.settings.pinHash, oldHash);
      expect(await t.runAsync(() => sv.appLock.verify('2580')), isTrue);
      // a record with its length wins over a stale settings file
      api.failPinWrite = false;
      sv.settings.pinLength = 6;
      await t.runAsync(() => sv.appLock.loadSecrets());
      expect(sv.settings.pinLength, 4);
      await t.pump(const Duration(seconds: 100));
      sv.dispose();
    });
  });

  testWidgets('#14 a failed host session leaves no "being controlled" banner', (t) async {
    final sv = await makeServices(t);
    sv.remote.onState({'session': 'h1', 'peer': 'p', 'state': 'active', 'role': 'host'});
    expect(sv.remote.host, isNotNull);
    sv.remote.onState({
      'session': 'h1', 'peer': 'p', 'state': 'failed', 'role': 'host',
      'reason': 'Không chụp được màn hình.', 'code': 'err.capture_failed', 'detail': 'pipewire: denied',
    });
    expect(sv.remote.host, isNull, reason: 'the red banner is driven by host');
    expect(sv.remote.hostError, 'Không chụp được màn hình.');
    expect(RemoteState.fromJson({'state': 'failed'}).phase, RemotePhase.failed);
    sv.dispose();
  });

  testWidgets('#24 a failed answer goes back to ringing and says why', (t) async {
    final api = _Spy()..failAnswer = true;
    final sv = await makeServices(t, api: api);
    api.simulateIncomingCall(video: true);
    await _flush(t);
    final ringing = sv.calls.call!;
    expect(ringing.phase, CallPhase.incoming);
    await t.runAsync(() => sv.calls.answer(true));
    expect(sv.calls.call?.phase, CallPhase.incoming, reason: 'not shown as connected');
    expect(sv.calls.answerError, isA<ApiException>());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
  });

  testWidgets('#30 "You:" comes from who wrote it, never from the text', (t) async {
    final api = _Spy();
    final sv = await makeServices(t, api: api);
    final conv = sv.chat.sorted.firstWhere((c) => !c.isGroup && !c.isSaved).id;
    api.simulateIncomingMessage(conv, 'Bạn: chuyển 5 triệu cho mình nhé');
    await _flush(t);
    final c = sv.chat.convs[conv]!;
    expect(c.lastMine, isFalse);
    expect(c.lastText, 'Bạn: chuyển 5 triệu cho mình nhé');
    await t.runAsync(() => sv.chat.send(conv, 'ok'));
    expect(sv.chat.convs[conv]!.lastMine, isTrue);
    expect(sv.chat.convs[conv]!.lastText, 'ok');
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
  });

  group('#29 desktop idle lock', () {
    test('locks after the chosen idle time; activity resets it; Ctrl+L locks now', () {
      var now = Duration.zero;
      final st = Settings()
        ..appLockEnabled = true
        ..pinSet = true
        ..pinHash = 'x'
        ..idleLockMin = 5;
      final lock = AppLock(st, uptime: () => now)..markUnlocked(); // starts locked
      lock.noteActivity();
      now = const Duration(minutes: 4);
      lock.checkIdle();
      expect(lock.locked, isFalse);
      lock.noteActivity(); // mouse moved
      now = const Duration(minutes: 8);
      lock.checkIdle();
      expect(lock.locked, isFalse);
      now = const Duration(minutes: 9, seconds: 1);
      lock.checkIdle();
      expect(lock.locked, isTrue);
      lock.markUnlocked();
      expect(lock.lockNow(), isTrue);
      expect(lock.locked, isTrue);
      st.appLockEnabled = false;
      expect(AppLock(st).lockNow(), isFalse, reason: 'no app lock: nothing to lock');
    });
  });
}

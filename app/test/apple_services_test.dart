// AppleServices (lib/platform/apple_services.dart) CallKit bookkeeping with a
// mocked `vn.lumora/push` channel: every call CallKit shows is ended with the
// right CXCallEndedReason (caller hung up, nobody answered, another device
// answered / declined, answered in Lumora's own screen, declined locally), a
// push that arrives after the call is over is ended at once, and locked chats
// are synced for PushKit. Plus DesktopLinks (lib/platform/desktop_links.dart).

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/platform/apple_services.dart';
import 'package:lumora/platform/desktop_links.dart';
import 'package:lumora/ui/flows.dart' show pendingDeepLink;

class _Api extends MockLumoraApi {
  _Api() : super(timers: false);

  final requests = <String>[];

  /// Calls the core knows about (call_answer fails for others, like the real core).
  final known = <String>{};

  /// Upcoming reminders (`reminders`).
  List<Map<String, dynamic>> reminders = [];

  @override
  Future<dynamic> request(String cmd, [Map<String, dynamic> args = const {}]) async {
    if (cmd == 'reminders') return reminders;
    if (cmd == 'call_answer' || cmd == 'call_end' || cmd == 'call_set') {
      final id = args['call_id'].toString();
      if (!known.contains(id)) throw Exception('err.call_ended');
      requests.add('$cmd $id${args.containsKey('accept') ? ' accept=${args['accept']}' : ''}'
          '${args.containsKey('mic') ? ' mic=${args['mic']}' : ''}');
      return null;
    }
    return null;
  }
}

const _push = MethodChannel('vn.lumora/push');
const _bonjour = MethodChannel('vn.lumora/bonjour');

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final apple = AppleServices.instance;

  late _Api api;
  late List<MethodCall> toSwift;
  // What Swift answers to `coreIncoming` (is CallKit showing this call?).
  late bool callKitShows;

  /// `callEnded` calls sent to Swift, as "id:reason".
  List<String> ended() => [
        for (final c in toSwift)
          if (c.method == 'callEnded') '${(c.arguments as Map)['call_id']}:${(c.arguments as Map)['reason']}',
      ];

  Future<void> fromSwift(String method, Map<String, dynamic> args) async {
    await apple.debugHandlePush(MethodCall(method, args));
    await _settle();
  }

  Future<void> core(String id, String state, {String? reason, int duration = 3}) async {
    apple.onCallEvent({'call_id': id, 'state': state, 'reason': ?reason, 'duration_s': duration});
    await _settle();
  }

  setUp(() async {
    AppleServices.debugIsIOS = true;
    apple.debugReset();
    api = _Api();
    toSwift = [];
    callKitShows = false;
    messenger.setMockMethodCallHandler(_push, (c) async {
      toSwift.add(c);
      if (c.method == 'coreIncoming') return callKitShows;
      return null;
    });
    messenger.setMockMethodCallHandler(_bonjour, (c) async => null);
    await apple.attach(api);
    toSwift.clear();
  });

  tearDown(() async {
    await apple.detach();
    apple.debugReset();
    AppleServices.debugIsIOS = null;
    messenger.setMockMethodCallHandler(_push, null);
    messenger.setMockMethodCallHandler(_bonjour, null);
  });

  group('CallKit calls end with the right reason', () {
    test('caller hangs up before anyone answers → remoteEnded', () async {
      await fromSwift('incomingCall', {'call_id': 'c1'});
      expect(apple.callKitCalls, {'c1'}, reason: 'tracked from the moment it rang, not only on answer');
      await core('c1', 'incoming');
      await core('c1', 'ended', duration: 8);
      expect(ended(), ['c1:remote']);
      expect(apple.callKitCalls, isEmpty);
    });

    test('nobody answers within the ring time → unanswered', () async {
      await fromSwift('incomingCall', {'call_id': 'c2'});
      await core('c2', 'incoming');
      await core('c2', 'ended', duration: 45);
      expect(ended(), ['c2:unanswered']);
    });

    test('another of my devices answered / declined', () async {
      await fromSwift('incomingCall', {'call_id': 'a'});
      await core('a', 'incoming');
      await core('a', 'ended', reason: 'answered_elsewhere');
      await fromSwift('incomingCall', {'call_id': 'b'});
      await core('b', 'incoming');
      await core('b', 'ended', reason: 'declined_elsewhere');
      expect(ended(), ['a:answered_elsewhere', 'b:declined_elsewhere']);
    });

    test('the hang-up beat the push → the late CallKit call ends at once', () async {
      await core('late', 'incoming');
      await core('late', 'ended', duration: 2);
      expect(ended(), isEmpty, reason: 'nothing on CallKit yet');
      await fromSwift('incomingCall', {'call_id': 'late'});
      expect(ended(), ['late:remote']);
      expect(apple.callKitCalls, isEmpty);
    });

    test('answered on the CallKit screen, then the other side hangs up', () async {
      await fromSwift('incomingCall', {'call_id': 'k'});
      api.known.add('k');
      await core('k', 'incoming');
      await fromSwift('answerCall', {'call_id': 'k', 'video': true});
      expect(api.requests, ['call_answer k accept=true']);
      await core('k', 'active');
      expect(ended(), isEmpty, reason: 'CallKit owns this call while it runs');
      await core('k', 'ended', duration: 120);
      expect(ended(), ['k:remote']);
    });

    test('CallKit "Answer" before the invite reached the core: answered when it rings', () async {
      await fromSwift('incomingCall', {'call_id': 'early'});
      await fromSwift('answerCall', {'call_id': 'early'});
      expect(api.requests, isEmpty);
      api.known.add('early');
      await core('early', 'incoming');
      expect(api.requests, ['call_answer early accept=true']);
    });

    test('answered in Lumora\'s own screen while CallKit rang → CallKit dismissed', () async {
      await fromSwift('incomingCall', {'call_id': 'u'});
      await core('u', 'incoming');
      await core('u', 'active');
      expect(ended(), ['u:answered_elsewhere']);
      await core('u', 'ended', duration: 60);
      expect(ended(), ['u:answered_elsewhere'], reason: 'not ended twice');
    });

    test('declined on the CallKit screen: declined in the core (also when the invite comes later)', () async {
      await fromSwift('incomingCall', {'call_id': 'd1'});
      api.known.add('d1');
      await core('d1', 'incoming');
      await fromSwift('endCall', {'call_id': 'd1', 'answered': false});
      expect(api.requests, ['call_answer d1 accept=false']);
      await core('d1', 'ended', duration: 6); // the core ends it after the decline

      await fromSwift('incomingCall', {'call_id': 'd2'});
      await fromSwift('endCall', {'call_id': 'd2', 'answered': false});
      api.known.add('d2');
      await core('d2', 'incoming');
      expect(api.requests.last, 'call_answer d2 accept=false');
      expect(ended(), isEmpty, reason: 'CallKit ended these itself');
    });

    test('hung up on the CallKit screen during the call → call_end', () async {
      await fromSwift('incomingCall', {'call_id': 'h'});
      api.known.add('h');
      await core('h', 'incoming');
      await fromSwift('answerCall', {'call_id': 'h'});
      await core('h', 'active');
      await fromSwift('muteCall', {'call_id': 'h', 'muted': true});
      await fromSwift('endCall', {'call_id': 'h', 'answered': true});
      expect(api.requests, ['call_answer h accept=true', 'call_set h mic=false', 'call_end h']);
    });

    test('declined in Lumora\'s own screen → ended as a local end action', () async {
      await fromSwift('incomingCall', {'call_id': 'l'});
      await core('l', 'incoming');
      apple.endedLocally('l');
      await _settle();
      await core('l', 'ended', duration: 4);
      expect(ended(), ['l:local']);
    });

    test('busy in another call: the PushKit ring stops at once', () async {
      await core('mine', 'active');
      await fromSwift('incomingCall', {'call_id': 'other'});
      expect(ended(), ['other:unanswered']);
      expect(apple.callKitCalls, isEmpty);
    });

    test('a ring Swift could not name is adopted when the core rings', () async {
      callKitShows = true;
      await core('x', 'incoming');
      expect(toSwift.where((c) => c.method == 'coreIncoming').map((c) => (c.arguments as Map)['call_id']), ['x']);
      expect(apple.callKitCalls, {'x'});
      await core('x', 'ended', duration: 5);
      expect(ended(), ['x:remote']);
    });

    test('calls CallKit never showed are left alone', () async {
      await core('plain', 'incoming');
      await core('plain', 'ended', duration: 5);
      expect(ended(), isEmpty);
    });

    test('Swift dropped a ring (timeout) → no stale end later', () async {
      await fromSwift('incomingCall', {'call_id': 't'});
      await fromSwift('callGone', {'call_id': 't'});
      await core('t', 'incoming');
      await core('t', 'ended', duration: 45);
      expect(ended(), isEmpty);
    });
  });

  group('locked chats', () {
    test('synced to Swift once per change, sorted', () async {
      AppleServices.lockedConvs = {'d:BBB', 'd:AAA'};
      AppleServices.lockedConvs = {'d:AAA', 'd:BBB'}; // same set: nothing sent
      await _settle();
      final sent = toSwift.where((c) => c.method == 'setLockedConvs').toList();
      expect(sent, hasLength(1));
      expect((sent.single.arguments as Map)['convs'], ['d:AAA', 'd:BBB']);
      expect(AppleServices.lockedConvs, {'d:AAA', 'd:BBB'});
      AppleServices.lockedConvs = {};
      await _settle();
      expect(toSwift.where((c) => c.method == 'setLockedConvs').last.arguments, {'convs': <String>[]});
    });

    test('not on iOS: nothing is sent', () async {
      AppleServices.debugIsIOS = false;
      AppleServices.lockedConvs = {'d:CCC'};
      apple.onCallEvent({'call_id': 'z', 'state': 'incoming'});
      await _settle();
      expect(toSwift, isEmpty);
    });
  });

  group('DesktopLinks', () {
    const links = MethodChannel('lumora/links');

    setUp(() {
      DesktopLinks.debugSupported = true;
      DesktopLinks.debugReset();
      pendingDeepLink.value = null;
    });

    tearDown(() {
      DesktopLinks.debugReset();
      DesktopLinks.debugSupported = null;
      messenger.setMockMethodCallHandler(links, null);
      pendingDeepLink.value = null;
    });

    Future<void> nativeOpens(String link) async {
      final done = Completer<void>();
      await messenger.handlePlatformMessage(
          'lumora/links', const StandardMethodCodec().encodeMethodCall(MethodCall('open', link)), (_) => done.complete());
      await done.future;
    }

    test('links queued before Dart listened, then links from later launches', () async {
      messenger.setMockMethodCallHandler(links, (c) async => c.method == 'ready' ? ['lumora://add/QUEUED'] : null);
      await DesktopLinks.init();
      expect(pendingDeepLink.value, 'lumora://add/QUEUED');
      pendingDeepLink.value = null; // consumed by the home shell

      await nativeOpens('https://getlumora.pages.dev/remote/123456789');
      expect(pendingDeepLink.value, 'https://getlumora.pages.dev/remote/123456789');

      pendingDeepLink.value = null;
      await nativeOpens('lumora://link/abc');
      expect(pendingDeepLink.value, isNull, reason: 'device-link codes are never taken from outside the app');

      await nativeOpens('https://evil.example/');
      expect(pendingDeepLink.value, isNull, reason: 'only Lumora links');
    });

    test('a runner without the channel is fine', () async {
      await DesktopLinks.init(); // no mock handler: MissingPluginException is swallowed
      expect(pendingDeepLink.value, isNull);
    });
  });

  group('reminders while in the background', () {
    tearDown(() {
      AppleServices.hideContent = false;
      AppleServices.reminderAlerts = true;
      AppleServices.snoozedReminders = () => const [];
    });

    test('upcoming and snoozed reminders become local notifications; private ones say nothing', () async {
      api.reminders = [
        {'conv': 'd:bob', 'msg_id': 'r1', 'at_ms': 2000000000000, 'title': 'Họp', 'note': 'Phòng 2'},
        {'conv': 'd:secret', 'msg_id': 'r2', 'at_ms': 2000000000001, 'title': 'Bí mật', 'note': ''},
      ];
      AppleServices.lockedConvs = {'d:secret'};
      AppleServices.snoozedReminders = () => [
            {'conv': 'd:bob', 'msg_id': 'r3', 'title': 'Gọi lại', 'snooze_until': 2000000000002},
          ];
      await apple.syncReminders(background: true);
      final call = toSwift.singleWhere((c) => c.method == 'scheduleReminders');
      final items = ((call.arguments as Map)['items'] as List).cast<Map>();
      expect(items.map((x) => x['id']), ['r1', 'r2', 'r3']);
      expect(items[0]['title'], 'Nhắc hẹn: Họp');
      expect(items[0]['body'], 'Phòng 2');
      expect(items[1]['title'], 'Lumora');
      expect('${items[1]}', isNot(contains('Bí mật')));
      expect(items[2]['at_ms'], 2000000000002);
    });

    test('back in front: cleared (the core rings them); off: nothing scheduled', () async {
      api.reminders = [
        {'conv': 'd:bob', 'msg_id': 'r1', 'at_ms': 2000000000000, 'title': 'Họp'},
      ];
      await apple.syncReminders(background: false);
      expect(toSwift.map((c) => c.method), containsAllInOrder(['clearReminders', 'requestLocalAlerts']));
      toSwift.clear();
      AppleServices.reminderAlerts = false;
      await apple.syncReminders(background: true);
      expect((toSwift.single.arguments as Map)['items'], isEmpty);
    });
  });
}

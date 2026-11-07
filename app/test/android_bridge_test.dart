// AndroidBridge (lib/platform/android_bridge.dart) with mocked platform
// channels: notification filtering (muted / locked chats, app language),
// the screen-share consent timeout, capture stopped natively, call FGS types
// and the FLAG_SECURE push/pop counter.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/platform/android_bridge.dart';
import 'package:lumora/state/stores.dart';

class _Api extends MockLumoraApi {
  _Api() : super(timers: false);

  final ctrl = StreamController<Map<String, dynamic>>.broadcast();
  final ended = <String>[];
  final callSets = <Map<String, dynamic>>[];

  @override
  Stream<Map<String, dynamic>> get events => ctrl.stream;

  @override
  Future<dynamic> request(String cmd, [Map<String, dynamic> args = const {}]) async {
    if (cmd == 'contacts') {
      return [
        {'peer': 'alice', 'name': 'Alice'},
      ];
    }
    if (cmd == 'contact_avatar') return {'avatar': args['peer'] == 'alice' ? base64Encode([1, 2, 3]) : null};
    if (cmd == 'group_avatar') return {'avatar': base64Encode([9, 9])};
    if (cmd == 'call_set') {
      callSets.add(Map.of(args));
      return null;
    }
    if (cmd == 'remote_end') {
      ended.add(args['session'].toString());
      return null;
    }
    return null;
  }
}

const _service = MethodChannel('lumora/service');
const _screen = MethodChannel('lumora/screen');
const _input = MethodChannel('lumora/input');

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;

  late _Api api;
  late List<MethodCall> serviceCalls;
  late List<MethodCall> screenCalls;
  // What `lumora/screen.start` answers (a never-completing future = no answer yet).
  late Future<bool?> Function() screenStart;

  final bridge = AndroidBridge.instance;

  setUp(() async {
    AndroidBridge.debugIsAndroid = true;
    AndroidBridge.notificationsOn = true;
    AndroidBridge.hideContent = false;
    AndroidBridge.lockedConvs = const {};
    AndroidBridge.isMuted = (_) => false;
    AndroidBridge.readGrace = Duration.zero;
    AndroidBridge.consentTimeout = const Duration(seconds: 60);
    AndroidBridge.debugResetSecure();
    serviceCalls = [];
    screenCalls = [];
    screenStart = () async => true;
    messenger.setMockMethodCallHandler(_service, (c) async {
      serviceCalls.add(c);
      return true;
    });
    messenger.setMockMethodCallHandler(_screen, (c) async {
      screenCalls.add(c);
      if (c.method == 'start') return screenStart();
      return true;
    });
    messenger.setMockMethodCallHandler(_input, (c) async => true);
    // Background: notifications are posted.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    api = _Api();
    await bridge.attach(api);
    await AndroidBridge.setLanguage('vi');
    serviceCalls.clear();
  });

  tearDown(() async {
    await bridge.detach();
    AndroidBridge.debugIsAndroid = null;
    messenger.setMockMethodCallHandler(_service, null);
    messenger.setMockMethodCallHandler(_screen, null);
    messenger.setMockMethodCallHandler(_input, null);
  });

  List<Map<Object?, Object?>> notifications() =>
      serviceCalls.where((c) => c.method == 'notify').map((c) => c.arguments as Map<Object?, Object?>).toList();

  group('notifications', () {
    test('muted conversations are not notified, others are', () async {
      AndroidBridge.isMuted = (c) => c == 'g:muted' || c == 'g:community';
      api.ctrl.add({'event': 'message', 'conv': 'g:muted', 'author': 'alice', 'body': {'text': 'hi'}});
      api.ctrl.add({'event': 'message', 'conv': 'g:community#general', 'author': 'alice', 'body': {'text': 'hi'}});
      api.ctrl.add({'event': 'message', 'conv': 'd:alice', 'author': 'alice', 'body': {'text': 'hello'}});
      await _settle();
      final n = notifications();
      expect(n, hasLength(1));
      expect(n.single['key'], 'd:alice');
      expect(n.single['title'], 'Alice');
      expect(n.single['body'], 'hello');
    });

    test('calls from a muted chat still ring', () async {
      AndroidBridge.isMuted = (_) => true;
      api.ctrl.add({'event': 'call', 'state': 'incoming', 'call_id': 'c1', 'conv': 'd:alice', 'from': 'alice'});
      await _settle();
      expect(notifications(), hasLength(1));
    });

    test('locked chat: incoming call shows no caller name', () async {
      AndroidBridge.lockedConvs = {'d:alice'};
      api.ctrl.add({'event': 'call', 'state': 'incoming', 'call_id': 'c1', 'conv': 'd:alice', 'from': 'alice', 'video': true});
      await _settle();
      final n = notifications().single;
      expect(n['kind'], 'call');
      expect(n['title'], 'Lumora');
      expect(n['body'], 'Cuộc gọi đến');
      expect('${n['title']} ${n['body']}', isNot(contains('Alice')));
    });

    test('unlocked chat: incoming call names the caller', () async {
      api.ctrl.add({'event': 'call', 'state': 'incoming', 'call_id': 'c1', 'conv': 'd:alice', 'from': 'alice'});
      await _settle();
      expect(notifications().single['title'], 'Alice');
    });

    test('chat locked on another device: the core marks the message, no name or text', () async {
      // this device's copy of the list doesn't know yet
      api.ctrl.add({'event': 'message', 'conv': 'd:alice', 'author': 'alice', 'body': {'text': 'secret plan'}, 'locked': true});
      await _settle();
      final n = notifications().single;
      expect(n['title'], 'Lumora');
      expect('${n['title']} ${n['body']}', isNot(anyOf(contains('Alice'), contains('secret'))));
    });

    test('texts follow the app language, which is also sent to Kotlin', () async {
      await AndroidBridge.setLanguage('en');
      expect(serviceCalls.where((c) => c.method == 'setLanguage').single.arguments, {'lang': 'en'});
      AndroidBridge.lockedConvs = {'d:alice'};
      api.ctrl.add({'event': 'call', 'state': 'incoming', 'call_id': 'c1', 'conv': 'd:alice', 'from': 'alice'});
      await _settle();
      expect(notifications().single['body'], 'Incoming call');
      // Unchanged language: not sent again.
      serviceCalls.clear();
      await AndroidBridge.setLanguage('en');
      expect(serviceCalls, isEmpty);
    });
  });

  group('calls', () {
    test('dialing/connected calls add the call FGS types, ending removes them', () async {
      api.ctrl.add({'event': 'call', 'state': 'incoming', 'call_id': 'c1', 'conv': 'd:alice'});
      await _settle();
      expect(serviceCalls.where((c) => c.method == 'setCall'), isEmpty);
      api.ctrl.add({'event': 'call', 'state': 'active', 'call_id': 'c1', 'conv': 'd:alice'});
      await _settle();
      api.ctrl.add({'event': 'call', 'state': 'ended', 'call_id': 'c1', 'conv': 'd:alice'});
      await _settle();
      expect(serviceCalls.where((c) => c.method == 'setCall').map((c) => c.arguments), [
        {'active': true},
        {'active': false},
      ]);
    });
  });

  group('screen share', () {
    test('no consent within the timeout ends the session and resets the request', () async {
      AndroidBridge.consentTimeout = const Duration(milliseconds: 80);
      final never = Completer<bool?>();
      screenStart = () => never.future;
      api.ctrl.add({'event': 'remote_state', 'role': 'host', 'session': 's1', 'state': 'active'});
      await _settle();
      expect(bridge.debugAsking, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(screenCalls.map((c) => c.method), containsAllInOrder(['start', 'cancel']));
      expect(api.ended, ['s1']);
      expect(bridge.debugAsking, isFalse);
      expect(bridge.debugHostSessions, isEmpty);
    });

    test('refused consent ends the session', () async {
      screenStart = () async => false;
      api.ctrl.add({'event': 'remote_state', 'role': 'host', 'session': 's1', 'state': 'active'});
      await _settle();
      expect(api.ended, ['s1']);
      expect(bridge.debugAsking, isFalse);
    });

    test('capture stopped natively ends the host sessions', () async {
      api.ctrl.add({'event': 'remote_state', 'role': 'host', 'session': 's1', 'state': 'active'});
      await _settle();
      expect(api.ended, isEmpty);
      expect(bridge.debugHostSessions, {'s1'});
      await messenger.handlePlatformMessage(
        'lumora/screen',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('stopped')),
        (_) {},
      );
      await _settle();
      expect(api.ended, ['s1']);
      expect(bridge.debugHostSessions, isEmpty);
    });

    test('session ended by the viewer while asking does not end anything else', () async {
      final answer = Completer<bool?>();
      screenStart = () => answer.future;
      api.ctrl.add({'event': 'remote_state', 'role': 'host', 'session': 's1', 'state': 'active'});
      await _settle();
      api.ctrl.add({'event': 'remote_state', 'role': 'host', 'session': 's1', 'state': 'ended'});
      await _settle();
      expect(screenCalls.map((c) => c.method), contains('stop'));
      answer.complete(false); // what Kotlin answers after `stop`
      await _settle();
      expect(api.ended, isEmpty);
      expect(bridge.debugAsking, isFalse);
    });
  });

  group('screen share in a call', () {
    // Regression: on Android the call's "share screen" only told the core,
    // which waited for MediaProjection frames that never came (no consent was
    // ever asked) — the other side saw nothing.
    Future<CallStore> inCall() async {
      final store = CallStore(api);
      store.onCall({'call_id': 'c1', 'state': 'active', 'conv': 'd:alice', 'peer': 'alice'});
      api.ctrl.add({'event': 'call', 'state': 'active', 'call_id': 'c1'});
      await _settle();
      return store;
    }

    test('asks for consent before telling the core; stopping stops the capture', () async {
      final store = await inCall();
      await store.toggle(screen: true);
      expect(screenCalls.map((c) => c.method), ['start']);
      expect(api.callSets.single['screen'], isTrue);
      expect(store.screen, isTrue);
      expect(bridge.debugCallShare, 'c1');
      await store.toggle(screen: false);
      expect(api.callSets.last['screen'], isFalse);
      expect(screenCalls.map((c) => c.method), ['start', 'stop']);
      expect(bridge.debugCallShare, isNull);
    });

    test('refused consent: the core is not told and the button stays off', () async {
      screenStart = () async => false;
      final store = await inCall();
      await store.toggle(screen: true);
      expect(api.callSets, isEmpty);
      expect(store.screen, isFalse);
      expect(bridge.debugCallShare, isNull);
    });

    test('capture stopped natively turns the share off in the core and the UI', () async {
      final store = await inCall();
      await store.toggle(screen: true);
      await messenger.handlePlatformMessage(
        'lumora/screen',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('stopped')),
        (_) {},
      );
      await _settle();
      expect(api.callSets.last['screen'], isFalse);
      expect(store.screen, isFalse);
      expect(bridge.debugCallShare, isNull);
    });

    test('the call ending stops the capture, a host session keeps it', () async {
      final store = await inCall();
      await store.toggle(screen: true);
      api.ctrl.add({'event': 'call', 'state': 'ended', 'call_id': 'c1'});
      await _settle();
      expect(screenCalls.map((c) => c.method), ['start', 'stop']);
      expect(bridge.debugCallShare, isNull);

      // A remote host session running: ending the call's share keeps capturing.
      screenCalls.clear();
      api.ctrl.add({'event': 'remote_state', 'role': 'host', 'session': 's1', 'state': 'active'});
      await _settle();
      store.onCall({'call_id': 'c2', 'state': 'active', 'conv': 'd:alice', 'peer': 'alice'});
      await store.toggle(screen: true);
      await store.toggle(screen: false);
      expect(screenCalls.map((c) => c.method), ['start', 'start']);
    });
  });

  test('a screen share that stopped is hidden, and shown again when it restarts', () {
    // Regression: the core keeps the decoder of a stopped share and only sends
    // call_peer screen:false — the viewer kept showing its last frame.
    final store = CallStore(api);
    store.onCall({'call_id': 'c1', 'state': 'active', 'conv': 'd:alice', 'peer': 'alice'});
    store.onVideoStream({'call_id': 'c1', 'peer': 'alice', 'stream': 5, 'kind': 'screen'});
    store.onCallPeer({'call_id': 'c1', 'peer': 'alice', 'mic': true, 'cam': true, 'screen': true});
    expect(store.liveScreenStreams, {'alice': 5});
    store.onCallPeer({'call_id': 'c1', 'peer': 'alice', 'mic': true, 'cam': true, 'screen': false});
    expect(store.liveScreenStreams, isEmpty);
    store.onCallPeer({'call_id': 'c1', 'peer': 'alice', 'mic': true, 'cam': true, 'screen': true});
    expect(store.liveScreenStreams, {'alice': 5});
  });

  group('FLAG_SECURE', () {
    List<Object?> secureCalls() => serviceCalls.where((c) => c.method == 'setSecure').map((c) => (c.arguments as Map)['on']).toList();

    test('push/pop OR with the user setting and nest', () async {
      await AndroidBridge.setSecure(false);
      await AndroidBridge.pushSecure();
      await AndroidBridge.pushSecure();
      await AndroidBridge.popSecure();
      expect(AndroidBridge.secureActive, isTrue);
      await AndroidBridge.popSecure();
      expect(AndroidBridge.secureActive, isFalse);
      await AndroidBridge.popSecure(); // extra pop: ignored
      expect(secureCalls(), [false, true, true, true, false, false]);

      serviceCalls.clear();
      await AndroidBridge.setSecure(true);
      await AndroidBridge.pushSecure();
      await AndroidBridge.popSecure();
      expect(AndroidBridge.secureActive, isTrue);
      expect(secureCalls(), [true, true, true]);
    });

    test('user setting changed while a sensitive screen is open stays blocked until pop', () async {
      await AndroidBridge.setSecure(true);
      await AndroidBridge.pushSecure();
      await AndroidBridge.setSecure(false);
      expect(AndroidBridge.secureActive, isTrue);
      await AndroidBridge.popSecure();
      expect(AndroidBridge.secureActive, isFalse);
      expect(secureCalls().last, false);
    });
  });

  group('mentions, other devices, reminders', () {
    tearDown(() {
      AndroidBridge.mentionsOnly = const {};
      AndroidBridge.onReminderAction = null;
      AndroidBridge.readGrace = Duration.zero;
    });

    test('an @mention goes to the mentions channel and through "mentions only"', () async {
      AndroidBridge.isMuted = (c) => c == 'g:grp';
      api.ctrl.add({'event': 'message', 'id': 'a', 'conv': 'g:grp', 'author': 'alice', 'body': {'text': 'plain'}});
      api.ctrl.add({'event': 'mention', 'id': 'b', 'conv': 'g:grp', 'author': 'alice'});
      api.ctrl.add({'event': 'message', 'id': 'b', 'conv': 'g:grp', 'author': 'alice', 'body': {'text': '@me'}});
      await _settle();
      expect(notifications(), isEmpty); // muted: mentions too

      AndroidBridge.mentionsOnly = {'g:grp'};
      api.ctrl.add({'event': 'message', 'id': 'c', 'conv': 'g:grp', 'author': 'alice', 'body': {'text': 'plain'}});
      api.ctrl.add({'event': 'mention', 'id': 'd', 'conv': 'g:grp', 'author': 'alice'});
      api.ctrl.add({'event': 'message', 'id': 'd', 'conv': 'g:grp', 'author': 'alice', 'body': {'text': '@me'}});
      await _settle();
      final n = notifications().single;
      expect(n['kind'], 'mention');
      expect(n['body'], '@me');
      expect(n['sound'], true);
    });

    test('read on another of my devices within the grace: not notified', () async {
      AndroidBridge.readGrace = const Duration(milliseconds: 150);
      api.ctrl.add({'event': 'message', 'id': 'a', 'conv': 'd:alice', 'author': 'alice', 'body': {'text': 'hi'}});
      await _settle();
      api.ctrl.add({'event': 'conversation', 'id': 'd:alice', 'unread': 0}); // read on my laptop
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(notifications(), isEmpty);

      api.ctrl.add({'event': 'message', 'id': 'b', 'conv': 'd:alice', 'author': 'alice', 'body': {'text': 'hi again'}});
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(notifications().single['body'], 'hi again');
    });

    test('a due reminder carries its data for the snooze / open actions', () async {
      api.ctrl.add({'event': 'reminder_due', 'conv': 'd:alice', 'msg_id': 'r1', 'title': 'Họp', 'at_ms': 5});
      await _settle();
      final n = notifications().single;
      expect(n['kind'], 'reminder');
      expect(n['sound'], true);
      final data = jsonDecode(n['reminder'] as String) as Map;
      expect(data['msg_id'], 'r1');
      expect(data.containsKey('event'), isFalse);

      final got = <(String, Map<String, dynamic>)>[];
      AndroidBridge.onReminderAction = (a, d) => got.add((a, d));
      final ok = await bridge.debugServiceCall(MethodCall('reminderAction', {'action': 'snooze', 'reminder': n['reminder']}));
      expect(ok, true);
      expect(got.single.$1, 'snooze');
      expect(got.single.$2['conv'], 'd:alice');
    });
  });

  test('bubbles are on by default (Settings › Chat bubbles can turn them off)', () {
    expect(AndroidBridge.bubbles, isTrue);
  });

  group('conversations, bubbles, opening a chat', () {
    setUp(() => AndroidBridge.bubbles = true);
    tearDown(() {
      AndroidBridge.bubbles = true; // the default
      AndroidBridge.onOpenConv = null;
      AndroidBridge.readingConv = () => null;
      AndroidBridge.convTitle = (_) => null;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    });

    test('a direct message is a conversation with the person, their picture and a bubble', () async {
      api.ctrl.add({'event': 'message', 'id': 'a', 'conv': 'd:alice', 'author': 'alice', 'ts': 1700000000000, 'body': {'text': 'hi'}});
      await _settle();
      final n = notifications().single;
      expect(n['conv'], 'd:alice');
      expect(n['sender'], 'Alice');
      expect(n['convTitle'], 'Alice');
      expect(n['group'], false);
      expect(n['bubble'], true);
      expect(n['ts'], 1700000000000);
      expect(n['avatar'], [1, 2, 3]);
    });

    test('a group message carries the group title and picture; bubbles can be turned off', () async {
      AndroidBridge.bubbles = false;
      AndroidBridge.convTitle = (c) => c == 'g:team' ? 'Nhóm dự án' : null;
      api.ctrl.add({'event': 'message', 'id': 'a', 'conv': 'g:team', 'author': 'bob', 'author_name': 'Bob', 'body': {'text': 'xin chào'}});
      await _settle();
      final n = notifications().single;
      expect(n['title'], 'Nhóm dự án – Bob');
      expect(n['convTitle'], 'Nhóm dự án');
      expect(n['sender'], 'Bob');
      expect(n['group'], true);
      expect(n['avatar'], [9, 9]);
      expect(n['bubble'], false);
    });

    test('hidden content or a locked chat: no conversation, no bubble, shortcuts removed', () async {
      AndroidBridge.lockedConvs = {'d:alice'};
      expect(serviceCalls.where((c) => c.method == 'forgetConversations').single.arguments, {'convs': ['d:alice']});
      api.ctrl.add({'event': 'message', 'id': 'a', 'conv': 'd:alice', 'author': 'alice', 'body': {'text': 'secret'}});
      await _settle();
      expect(notifications().single.containsKey('conv'), isFalse);
      expect(notifications().single['title'], 'Lumora');

      serviceCalls.clear();
      AndroidBridge.lockedConvs = const {};
      AndroidBridge.hideContent = true;
      expect(serviceCalls.where((c) => c.method == 'forgetConversations').single.arguments, {'convs': null});
      api.ctrl.add({'event': 'message', 'id': 'b', 'conv': 'd:carol', 'author': 'carol', 'body': {'text': 'x'}});
      await _settle();
      expect(notifications().single.containsKey('conv'), isFalse);
      AndroidBridge.hideContent = false;
    });

    test('a deleted chat loses its shortcut', () async {
      api.ctrl.add({'event': 'conversation_removed', 'conv': 'd:alice'});
      await _settle();
      expect(serviceCalls.where((c) => c.method == 'forgetConversations').single.arguments, {'convs': ['d:alice']});
    });

    test('in front: messages of another chat are notified, the chat on screen and calls are not', () async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      AndroidBridge.readingConv = () => 'd:alice';
      api.ctrl.add({'event': 'message', 'id': 'a', 'conv': 'd:alice', 'author': 'alice', 'body': {'text': 'on screen'}});
      api.ctrl.add({'event': 'message', 'id': 'b', 'conv': 'd:carol', 'author': 'carol', 'body': {'text': 'elsewhere'}});
      api.ctrl.add({'event': 'call', 'state': 'incoming', 'call_id': 'c1', 'conv': 'd:carol', 'from': 'carol'});
      await _settle();
      expect(notifications().map((n) => n['body']), ['elsewhere']);
    });

    test('shouldNotify', () {
      expect(AndroidBridge.shouldNotify({'event': 'call'}, foreground: false), isTrue);
      expect(AndroidBridge.shouldNotify({'event': 'call'}, foreground: true), isFalse);
      expect(AndroidBridge.shouldNotify({'event': 'reminder_due'}, foreground: true), isTrue);
      expect(AndroidBridge.shouldNotify({'event': 'message', 'conv': 'a'}, foreground: true, reading: 'a'), isFalse);
      expect(AndroidBridge.shouldNotify({'event': 'message', 'conv': 'a'}, foreground: true, reading: 'b'), isTrue);
      expect(AndroidBridge.shouldNotify({'event': 'message', 'conv': 'a'}, foreground: true), isTrue);
    });

    test('a tapped notification / bubble opens its chat', () async {
      expect(await bridge.debugServiceCall(const MethodCall('openConv', {'conv': 'd:alice'})), false, reason: 'not wired yet: Kotlin keeps it');
      final opened = <String>[];
      AndroidBridge.onOpenConv = opened.add;
      expect(await bridge.debugServiceCall(const MethodCall('openConv', {'conv': 'd:alice'})), true);
      expect(opened, ['d:alice']);
    });

    test('a chat tapped before Lumora was running is opened when it attaches', () async {
      final opened = <String>[];
      AndroidBridge.onOpenConv = opened.add;
      messenger.setMockMethodCallHandler(_service, (c) async {
        serviceCalls.add(c);
        return c.method == 'takeOpenConv' ? 'g:team' : true;
      });
      await bridge.attach(api);
      expect(opened, ['g:team']);
    });
  });

  test('background status and actions go to Kotlin', () async {
    messenger.setMockMethodCallHandler(_service, (c) async {
      serviceCalls.add(c);
      return c.method == 'background' ? {'ignoring': false, 'oem': 'xiaomi', 'autostart': true} : true;
    });
    final st = await AndroidBridge.backgroundStatus();
    expect(st!.ignoringBattery, isFalse);
    expect(st.oem, 'xiaomi');
    expect(st.autostart, isTrue);
    expect(await AndroidBridge.requestIgnoreBattery(), isTrue);
    expect(await AndroidBridge.openAutostart(), isTrue);
    expect(serviceCalls.map((c) => c.method), containsAll(['background', 'requestIgnoreBattery', 'openAutostart']));
  });

  group('incoming-call notification buttons', () {
    tearDown(() => AndroidBridge.onCallAction = null);

    test('the call notification carries its call id; Answer / Decline come back to Dart', () async {
      api.ctrl.add({'event': 'call', 'state': 'incoming', 'call_id': 'c7', 'conv': 'd:alice', 'from': 'alice'});
      await _settle();
      expect(notifications().single['callId'], 'c7');
      final got = <(String, String)>[];
      AndroidBridge.onCallAction = (a, id) => got.add((a, id));
      expect(await bridge.debugServiceCall(const MethodCall('callAction', {'action': 'decline', 'callId': 'c7'})), true);
      expect(await bridge.debugServiceCall(const MethodCall('callAction', {'action': 'answer', 'callId': 'c7'})), true);
      expect(await bridge.debugServiceCall(const MethodCall('callAction', {'action': 'bogus'})), false);
      expect(got, [('decline', 'c7'), ('answer', 'c7')]);
    });
  });
}

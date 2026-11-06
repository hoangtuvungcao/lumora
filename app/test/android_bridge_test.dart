// AndroidBridge (lib/platform/android_bridge.dart) with mocked platform
// channels: notification filtering (muted / locked chats, app language),
// the screen-share consent timeout, capture stopped natively, call FGS types
// and the FLAG_SECURE push/pop counter.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/platform/android_bridge.dart';

class _Api extends MockLumoraApi {
  _Api() : super(timers: false);

  final ctrl = StreamController<Map<String, dynamic>>.broadcast();
  final ended = <String>[];

  @override
  Stream<Map<String, dynamic>> get events => ctrl.stream;

  @override
  Future<dynamic> request(String cmd, [Map<String, dynamic> args = const {}]) async {
    if (cmd == 'contacts') {
      return [
        {'peer': 'alice', 'name': 'Alice'},
      ];
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
}

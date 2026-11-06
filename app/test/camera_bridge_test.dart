// CameraBridge (lib/platform/camera_bridge.dart) with a mocked
// `lumora/camera` channel: hanging up while the native start is still in
// flight, or while the camera is interrupted, must always reach the native
// `stop` — otherwise the camera comes back after the call.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/platform/camera_bridge.dart';
import 'package:lumora/state/stores.dart';

const _camera = MethodChannel('lumora/camera');

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;

  late CallStore calls;
  late CameraBridge cam;
  late List<String> log;
  late Completer<Map<String, Object?>> startReply;

  setUp(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    CameraBridge.debugHasBridge = true;
    log = [];
    startReply = Completer();
    messenger.setMockMethodCallHandler(_camera, (c) async {
      log.add(c.method);
      switch (c.method) {
        case 'permission':
          return 'granted';
        case 'start':
          return startReply.future;
      }
      return null;
    });
    calls = CallStore(MockLumoraApi(timers: false));
    cam = CameraBridge(calls)..attach();
  });

  tearDown(() {
    cam.dispose();
    CameraBridge.debugHasBridge = null;
    messenger.setMockMethodCallHandler(_camera, null);
  });

  void startVideoCall() {
    calls.call = const CallState(callId: 'c1', conv: 'd:bob', peer: 'bob', phase: CallPhase.active, video: true);
    calls.cam = true;
    calls.cameraRequested.value = true;
  }

  void hangUp() {
    calls.call = null;
    calls.cameraRequested.value = false;
  }

  test('hang-up while the native start is in flight stops the camera when it opens', () async {
    startVideoCall();
    await _settle();
    expect(log, ['permission', 'start']);
    hangUp();
    await _settle();
    // The start answers after the hang-up: the camera must not stay on.
    startReply.complete({'ok': true, 'facing': 'front', 'cameras': 2});
    await _settle();
    expect(log.last, 'stop');
    expect(cam.running, isFalse);
  });

  test('superseded start (native "cancelled") shows no notice and still stops', () async {
    startVideoCall();
    await _settle();
    hangUp();
    startReply.complete({'ok': false, 'error': 'cancelled', 'facing': 'front', 'cameras': 2});
    await _settle();
    expect(cam.issue, isNull);
    expect(log.last, 'stop');
  });

  test('hang-up while the camera is interrupted still sends the native stop', () async {
    startReply.complete({'ok': true, 'facing': 'front', 'cameras': 2});
    startVideoCall();
    await _settle();
    expect(cam.running, isTrue);
    // iOS took the camera (phone call, Split View): not running, but the
    // capture session still exists and resumes on its own later.
    await messenger.handlePlatformMessage(
      'lumora/camera',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('onError', {'code': 'interrupted', 'message': ''})),
      (_) {},
    );
    expect(cam.running, isFalse);
    log.clear();
    hangUp();
    await _settle();
    expect(log, ['stop']);
  });

  test('quick off/on does not leave the camera stopped', () async {
    startReply.complete({'ok': true, 'facing': 'front', 'cameras': 2});
    startVideoCall();
    await _settle();
    expect(cam.running, isTrue);
    calls.cam = false;
    calls.cameraRequested.value = false;
    calls.cameraRequested.value = true;
    calls.cam = true;
    calls.cameraRequested.value = false;
    calls.cameraRequested.value = true;
    await _settle();
    expect(cam.running, isTrue);
    expect(log.last, 'start');
  });

  test('no stop is sent when the camera never started', () async {
    hangUp();
    await _settle();
    expect(log, isEmpty);
  });
}

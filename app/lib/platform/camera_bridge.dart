// Video-call camera on Android, iOS, macOS and Windows.
//
// The core asks for frames with `camera_needed` (Linux captures through V4L2
// inside the core and never needs this). Capture itself is native and feeds
// the core directly — no frame ever crosses into Dart:
//   Android  CameraX ImageAnalysis → JNI → lumora_media::camera_in
//            (android/.../CameraCapture.kt)
//   iOS/mac  AVCaptureVideoDataOutput (NV12) → lumora_push_camera_yuv
//            (ios|macos/Runner/LumoraCamera.swift)
//   Windows  Media Foundation source reader (NV12) → lumora_push_camera_yuv
//            (windows/runner/lumora_camera.cpp)
// The self-view is the core's processed `video_stream {local: true}` (beauty
// filter included), so there is no plugin preview either.
//
// This class only decides *when* the camera runs (call active + video + camera
// on + app in front on phones), walks the permission flow, and exposes a small
// state for the call screen: which camera, how many, and a friendly issue to
// show (ask / denied / blocked / busy / none / failed).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/api.dart' show CallPhase;
import '../core/ffi_api.dart' show lumoraLoadedLibraryPath;
import '../state/stores.dart';

/// What the call screen should tell the user about the camera.
enum CameraIssue {
  /// Never asked: show our short explanation, then the system prompt.
  ask,

  /// Asked and refused, can ask again.
  denied,

  /// Refused for good (or restricted): only the system settings can fix it.
  blocked,

  /// Another app holds the camera.
  busy,

  /// No camera on this device.
  none,

  /// Anything else; "Try again" restarts it.
  failed,
}

class CameraBridge extends ChangeNotifier with WidgetsBindingObserver {
  CameraBridge(this.calls);

  static const _ch = MethodChannel('lumora/camera');

  /// Tests: pretend a native camera bridge exists (and the platform is a phone).
  @visibleForTesting
  static bool? debugHasBridge;

  /// Platforms with a native capture behind `lumora/camera`.
  static bool get platformHasBridge =>
      debugHasBridge ?? (!kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows));

  static bool get _mobile => debugHasBridge ?? (!kIsWeb && (Platform.isAndroid || Platform.isIOS));

  final CallStore calls;

  bool _attached = false;
  bool _foreground = true;
  bool _running = false;

  /// A native `start` was sent and no `stop` since: the device may be open
  /// (or about to be) even when [_running] is false — a start still in
  /// flight, an iOS interruption, an error the camera may recover from. Any
  /// such state gets a native `stop` when the camera is no longer wanted, so
  /// it can't come back after hang-up.
  bool _nativeOn = false;

  /// Bumped whenever the camera stops being wanted: a start that was in
  /// flight across a bump is stale (its errors are not shown).
  int _gen = 0;
  bool _stopQueued = false;

  /// "front" | "back" (desktop: built-in camera reports "front").
  String facing = 'front';

  /// Number of cameras (the switch button shows when > 1).
  int cameras = 0;
  CameraIssue? issue;

  /// Serialises start/stop/switch so a fast toggle can't race.
  Future<void> _queue = Future.value();
  Timer? _retry;
  int _retries = 0;

  bool get running => _running;
  bool get canSwitch => _running && cameras > 1;

  /// The core's self-view is always mirrored (like a mirror); for the back
  /// camera that looks wrong, so the call screen flips it back.
  bool get flipSelfView => facing == 'back';

  void attach() {
    if (_attached) return;
    _attached = true;
    calls.addListener(_reconcile);
    calls.cameraRequested.addListener(_reconcile);
    WidgetsBinding.instance.addObserver(this);
    _ch.setMethodCallHandler(_onNative);
  }

  @override
  void dispose() {
    if (_attached) {
      calls.removeListener(_reconcile);
      calls.cameraRequested.removeListener(_reconcile);
      WidgetsBinding.instance.removeObserver(this);
    }
    _retry?.cancel();
    if (_running || _nativeOn) unawaited(_invoke('stop'));
    _running = false;
    _nativeOn = false;
    super.dispose();
  }

  /// Should the camera run right now?
  bool get _wanted {
    final c = calls.call;
    return calls.cameraRequested.value && c != null && c.video && c.phase == CallPhase.active && calls.cam && _foreground;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_mobile) return;
    // Phones: give the camera back in the background (the OS would cut it
    // anyway). `inactive` is not enough — the permission prompt causes it.
    final fg = state != AppLifecycleState.paused && state != AppLifecycleState.hidden && state != AppLifecycleState.detached;
    if (fg == _foreground) return;
    _foreground = fg;
    // (Going to the background clears any notice, so coming back from the
    // system settings checks the permission again.)
    _reconcile();
  }

  void _reconcile() {
    final want = _wanted;
    if (!want && issue != null) {
      // Camera off, call over or app in the background: the notice is moot
      // (and permission is checked again next time).
      issue = null;
      notifyListeners();
    }
    if (!want) {
      // Hang-up / camera off / background: always reach the native stop,
      // even when a start is still in flight (it runs after it, in order).
      if (!_running && !_nativeOn) return;
      _gen++;
      _retry?.cancel();
      if (_stopQueued) return;
      _stopQueued = true;
      _queue = _queue.then((_) => _stop()).catchError((Object e) => debugPrint('camera: $e'));
      return;
    }
    if (_running) return;
    _queue = _queue.then((_) => _start()).catchError((Object e) => debugPrint('camera: $e'));
  }

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('camera $method: ${e.code} ${e.message}');
      return null;
    }
  }

  void _setIssue(CameraIssue? i) {
    if (issue == i) return;
    issue = i;
    notifyListeners();
  }

  Future<void> _start() async {
    if (!_wanted || _running) return;
    if (!platformHasBridge) {
      _setIssue(CameraIssue.none);
      return;
    }
    // An issue is on screen: wait for the user ("Cho phép", "Thử lại", settings).
    if (issue != null) return;
    final perm = await _invoke<String>('permission') ?? 'granted';
    if (perm != 'granted') {
      _setIssue(switch (perm) {
        'undetermined' => CameraIssue.ask,
        'denied' => CameraIssue.denied,
        _ => CameraIssue.blocked,
      });
      return;
    }
    await _open();
  }

  Future<void> _open() async {
    if (!_wanted) return;
    final gen = _gen;
    _nativeOn = true;
    final r = await _invoke<Map<Object?, Object?>>('start', {
      'facing': facing,
      'lib': lumoraLoadedLibraryPath,
      'width': 1280,
      'height': 720,
      'fps': 30,
    });
    if (r == null) {
      if (gen == _gen && _wanted) _setIssue(CameraIssue.none);
      return;
    }
    cameras = (r['cameras'] as num?)?.toInt() ?? cameras;
    facing = r['facing'] as String? ?? facing;
    if (r['ok'] == true) {
      _running = true;
      _retries = 0;
      issue = null;
      notifyListeners();
      // Turned off / hung up while the device was opening: stop right away
      // (a queued stop follows too; the second one is a no-op).
      if (gen != _gen || !_wanted) await _stop();
      return;
    }
    // Superseded natively (stop/another start came first), or stale: no notice.
    if (r['error'] == 'cancelled' || gen != _gen || !_wanted) return;
    _setIssue(switch (r['error']) {
      'permission' => CameraIssue.blocked,
      'busy' => CameraIssue.busy,
      'no_camera' => CameraIssue.none,
      _ => CameraIssue.failed,
    });
  }

  Future<void> _stop() async {
    _stopQueued = false;
    _retry?.cancel();
    if (!_running && !_nativeOn) return;
    // Wanted again by the time this runs (quick off → on): keep it.
    if (_wanted && _running) return;
    final was = _running;
    _running = false;
    _nativeOn = false;
    if (was) notifyListeners();
    await _invoke<void>('stop');
  }

  /// "Cho phép": system prompt, then start.
  Future<void> allow() async {
    final perm = await _invoke<String>('request') ?? 'granted';
    if (perm == 'granted') {
      issue = null;
      notifyListeners();
      _queue = _queue.then((_) => _open());
      return;
    }
    _setIssue(perm == 'denied' ? CameraIssue.denied : CameraIssue.blocked);
  }

  /// "Mở cài đặt".
  Future<void> openSettings() async {
    await _invoke<bool>('openSettings');
  }

  /// "Thử lại" after busy / failed.
  void retry() {
    issue = null;
    notifyListeners();
    _reconcile();
  }

  /// Front ↔ back (desktop: next camera).
  Future<void> switchCamera() async {
    if (!_running) return;
    final done = Completer<void>();
    _queue = _queue.then((_) async {
      final r = await _invoke<Map<Object?, Object?>>('switch');
      if (r != null) {
        facing = r['facing'] as String? ?? facing;
        cameras = (r['cameras'] as num?)?.toInt() ?? cameras;
        notifyListeners();
      }
    }).whenComplete(done.complete);
    return done.future;
  }

  Future<Object?> _onNative(MethodCall call) async {
    switch (call.method) {
      case 'onError':
        final code = (call.arguments as Map?)?['code'];
        _running = false;
        if (code == 'interrupted') {
          // iOS took the camera (another app in Split View, phone call…);
          // `onInterruptionEnded` brings it back.
          notifyListeners();
          return null;
        }
        if (code == 'disconnected' && _retries < 2) {
          // Unplugged webcam / camera service restart: try once more (another camera may exist).
          _retries++;
          notifyListeners();
          _retry?.cancel();
          _retry = Timer(const Duration(seconds: 1), _reconcile);
          return null;
        }
        _setIssue(code == 'permission' ? CameraIssue.blocked : (code == 'busy' ? CameraIssue.busy : CameraIssue.failed));
      case 'onInterruptionEnded':
        _reconcile();
    }
    return null;
  }
}

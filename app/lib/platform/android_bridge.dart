// Android-only glue between the core's events and the Kotlin side
// (app/android/app/src/main/kotlin/vn/lumora/lumora/).
//
// Design (remote desktop with the phone as host):
//  * Screen: when the core reports a *host* session as active, we ask for
//    MediaProjection consent over `lumora/screen`; Kotlin then pushes RGBA
//    frames straight into Rust over JNI (LumoraNative.pushFrame →
//    lumora_media::push_external_frame). Declining ends the session.
//  * Input: the core's Android injector queues the viewer's events; a Kotlin
//    thread in the foreground service drains them over JNI and the
//    AccessibilityService turns them into gestures/global actions/text. Dart
//    is not in that path (lower latency, works while the UI is backgrounded);
//    it only opens the accessibility onboarding when control was granted but
//    the service is off.
//  * Keep-alive: `lumora/service.start` runs a foreground service (persistent
//    low-priority notification "Lumora đang kết nối") that also holds the
//    Wi-Fi multicast lock for LAN discovery.
//  * Background notifications: while the UI is not resumed, incoming
//    messages, calls, friend and remote-access requests are posted as system
//    notifications (`lumora/service.notify`); cleared when the app resumes.
//    They use the app's language (`setLanguage`, also sent to Kotlin for the
//    channel and service texts), skip muted chats and never name the other
//    side of a locked chat.
//  * Screen-share consent: asked over `lumora/screen.start`; Kotlin brings
//    Lumora to the front (or posts a notification) when it is in the
//    background. No answer within [AndroidBridge.consentTimeout] ends the
//    session; capture stopped by Android/the user (`stopped` callback) ends
//    the host session(s) too.
//  * Calls: `lumora/service.setCall` adds the phoneCall/microphone types to
//    the foreground service while a call is dialing or connected.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/api.dart';

class AndroidBridge with WidgetsBindingObserver {
  AndroidBridge._();
  static final AndroidBridge instance = AndroidBridge._();

  static const _service = MethodChannel('lumora/service');
  static const _screen = MethodChannel('lumora/screen');
  static const _input = MethodChannel('lumora/input');

  StreamSubscription<Map<String, dynamic>>? _sub;
  LumoraApi? _api;
  final Set<String> _hostSessions = {};
  bool _asking = false;
  bool _observing = false;
  final Map<String, String> _names = {};
  DateTime _namesAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Calls dialing or connected (they use the microphone).
  final Set<String> _liveCalls = {};

  /// Tests: pretend to run on Android.
  @visibleForTesting
  static bool? debugIsAndroid;

  static bool get isAndroid => debugIsAndroid ?? (!kIsWeb && Platform.isAndroid);

  /// How long a remote session waits for the screen-capture consent before
  /// it is ended (the viewer would otherwise look at a black screen forever).
  /// Kotlin's consent notification expires after the same time.
  @visibleForTesting
  static Duration consentTimeout = const Duration(seconds: 60);

  /// Tests: is a screen-share consent request in progress?
  @visibleForTesting
  bool get debugAsking => _asking;

  /// Tests: host sessions being shared.
  @visibleForTesting
  Set<String> get debugHostSessions => Set.unmodifiable(_hostSessions);

  /// Mirrors Settings: system notifications on/off and whether they may show
  /// who wrote and what (hidden while the app lock is on).
  static bool notificationsOn = true;
  static bool hideContent = false;

  /// Locked chats: their notifications (messages, reminders, calls) never
  /// show a name or text.
  static Set<String> lockedConvs = const {};

  /// Muted chats get no message notifications (calls still ring). Wired by
  /// AppServices to the ChatStore.
  static bool Function(String conv) isMuted = _never;
  static bool _never(String _) => false;

  /// The app's language ('vi' | 'en') for notification texts; see [setLanguage].
  static String language = 'vi';

  /// Notifications follow the language chosen in Lumora, not the phone's:
  /// Dart-built texts use [language], and Kotlin gets it for the channel
  /// names and the foreground-service notification. Cheap to call repeatedly.
  static Future<void> setLanguage(String lang) async {
    final l = lang == 'en' ? 'en' : 'vi';
    if (l == language && _langSent == l) return;
    language = l;
    if (!isAndroid) return;
    for (var attempt = 0; attempt < 5; attempt++) {
      if (language != l) return; // superseded
      try {
        await _service.invokeMethod('setLanguage', {'lang': l});
        _langSent = l;
        return;
      } catch (e) {
        if (attempt == 4) debugPrint('Lumora: setLanguage: $e');
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    }
  }

  static String? _langSent;

  /// The user's "block screenshots" setting (from Settings via app.dart).
  static bool _userSecure = false;

  /// Screens that must never be captured (recovery phrase, backup, linking)
  /// currently open; see [pushSecure].
  static int _secureDepth = 0;

  /// What FLAG_SECURE currently is (user setting OR a sensitive screen open).
  static bool get secureActive => _userSecure || _secureDepth > 0;

  /// FLAG_SECURE on the Activity: blocks screenshots / screen recording and
  /// blanks the app in the recent-apps switcher. This is the *user's*
  /// setting; sensitive screens add to it with [pushSecure]/[popSecure].
  /// Safe to call repeatedly; applies to the current window immediately.
  /// No-op off Android.
  static Future<void> setSecure(bool on) {
    _userSecure = on;
    return _applySecure();
  }

  /// A sensitive screen opened (recovery phrase, backup, link device):
  /// screenshots are blocked until the matching [popSecure], whatever the
  /// user setting. Nests (counter).
  static Future<void> pushSecure() {
    _secureDepth++;
    return _applySecure();
  }

  /// The sensitive screen closed: back to the user's setting once every
  /// [pushSecure] has been popped. Extra pops are ignored.
  static Future<void> popSecure() {
    if (_secureDepth > 0) _secureDepth--;
    return _applySecure();
  }

  @visibleForTesting
  static void debugResetSecure() {
    _userSecure = false;
    _secureDepth = 0;
    _secureWanted = null;
  }

  static Future<void> _applySecure() async {
    if (!isAndroid) return;
    final on = secureActive;
    _secureWanted = on;
    // At startup the Activity may not have registered the channel yet.
    for (var attempt = 0; attempt < 5; attempt++) {
      if (_secureWanted != on) return; // superseded
      try {
        await _service.invokeMethod('setSecure', {'on': on});
        return;
      } catch (e) {
        if (attempt == 4) debugPrint('Lumora: setSecure: $e');
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    }
  }

  static bool? _secureWanted;

  /// Android 13+: blank preview in the recent-apps switcher (app lock on)
  /// without blocking screenshots or screen sharing. No-op elsewhere.
  static Future<void> setRecentsHidden(bool on) async {
    if (!isAndroid) return;
    _recentsWanted = on;
    for (var attempt = 0; attempt < 5; attempt++) {
      if (_recentsWanted != on) return; // superseded
      try {
        await _service.invokeMethod('setRecentsHidden', {'on': on});
        return;
      } catch (e) {
        if (attempt == 4) debugPrint('Lumora: setRecentsHidden: $e');
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    }
  }

  static bool? _recentsWanted;

  /// Extra start-config keys for Android (downloads go to the app's external
  /// files dir, visible over USB / in the Files app under Android/data).
  static Future<Map<String, dynamic>> configOverrides(Map<String, dynamic> config) async {
    if (!isAndroid || config['downloads_dir'] != null) return const {};
    try {
      final ext = await getExternalStorageDirectory();
      if (ext == null) return const {};
      final dir = Directory('${ext.path}/Download/Lumora');
      await dir.create(recursive: true);
      return {'downloads_dir': dir.path};
    } catch (_) {
      return const {};
    }
  }

  /// Called once the native node runs.
  Future<void> attach(LumoraApi api) async {
    if (!isAndroid) return;
    _api = api;
    await _sub?.cancel();
    _sub = api.events.listen(_onEvent);
    _screen.setMethodCallHandler(_onScreenCall);
    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
    }
    try {
      await _service.invokeMethod('start');
    } catch (e) {
      debugPrint('Lumora: foreground service: $e');
    }
  }

  Future<void> detach() async {
    if (_observing) {
      _observing = false;
      WidgetsBinding.instance.removeObserver(this);
    }
    await _sub?.cancel();
    _sub = null;
    _api = null;
    _hostSessions.clear();
    _liveCalls.clear();
    if (!isAndroid) return;
    _screen.setMethodCallHandler(null);
    try {
      await _screen.invokeMethod('stop');
      await _service.invokeMethod('setCall', {'active': false});
      await _service.invokeMethod('stop');
    } catch (_) {}
  }

  /// Is the remote-control accessibility service enabled?
  static Future<bool> inputEnabled() async {
    if (!isAndroid) return true;
    try {
      return await _input.invokeMethod<bool>('isEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the native onboarding screen that explains how to enable it.
  static Future<void> openInputGuide() async {
    if (!isAndroid) return;
    try {
      await _input.invokeMethod('openGuide');
    } catch (_) {}
  }

  /// Can this build share the screen (core built with media support)?
  static Future<bool> screenSupported() async {
    if (!isAndroid) return false;
    try {
      return await _screen.invokeMethod<bool>('supported') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_service.invokeMethod('clearNotifications').catchError((_) => null));
    }
  }

  bool get _foreground => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  bool get _vi => language == 'vi';

  Future<String> _nameOf(String peer) async {
    if (!_names.containsKey(peer) && DateTime.now().difference(_namesAt).inSeconds > 5) {
      _namesAt = DateTime.now();
      try {
        final list = await _api?.request('contacts');
        if (list is List) {
          for (final c in list) {
            if (c is Map) {
              final alias = c['alias']?.toString();
              _names[c['peer'].toString()] = (alias != null && alias.isNotEmpty) ? alias : (c['name']?.toString() ?? '');
            }
          }
        }
      } catch (_) {}
    }
    final n = _names[peer] ?? '';
    return n.isNotEmpty ? n : 'Lumora';
  }

  /// System notification while the UI is in the background.
  Future<void> _notifyBackground(Map<String, dynamic> ev) async {
    if (!notificationsOn) return;
    final vi = _vi;
    String? kind, key, title, body;
    switch (ev['event']) {
      case 'message':
        if (ev['mine'] == true || ev['kind'] == 'system') return;
        // "Gửi không âm báo": the sender asked for no sound / notification.
        if (ev['silent'] == true || (ev['meta'] is Map && (ev['meta'] as Map)['silent'] == true)) return;
        final conv = ev['conv']?.toString() ?? '';
        // Muted chat (or its community/group, for channel convs "group#channel").
        if (_muted(conv)) return;
        final b = ev['body'];
        final text = b is Map ? (b['text'] ?? (b['name'] != null ? '${vi ? 'Tệp' : 'File'}: ${b['name']}' : null)) : null;
        kind = 'message';
        key = conv;
        title = await _nameOf(ev['author']?.toString() ?? '');
        body = text?.toString() ?? (vi ? 'Tin nhắn mới' : 'New message');
      case 'call':
        if (ev['state'] != 'incoming') return;
        kind = 'call';
        key = 'call';
        title = await _nameOf(ev['from']?.toString() ?? ev['peer']?.toString() ?? '');
        body = ev['video'] == true
            ? (vi ? 'Cuộc gọi video đến' : 'Incoming video call')
            : (vi ? 'Cuộc gọi đến' : 'Incoming call');
      case 'remote_request':
        kind = 'remote';
        key = 'remote';
        title = vi ? 'Yêu cầu truy cập từ xa' : 'Remote access request';
        final who = ev['name']?.toString() ?? '';
        body = vi ? '$who muốn truy cập điện thoại này. Mở Lumora để trả lời.' : '$who wants to access this phone. Open Lumora to answer.';
      case 'reminder_due':
        kind = 'reminder';
        key = 'reminder:${ev['msg_id']}';
        title = ev['title'] == null ? (vi ? 'Nhắc hẹn' : 'Reminder') : '${vi ? 'Nhắc hẹn' : 'Reminder'}: ${ev['title']}';
        final note = ev['note']?.toString() ?? '';
        body = note.isNotEmpty ? note : (vi ? 'Đến giờ hẹn rồi' : "It's time");
      case 'friend_request':
        kind = 'friend';
        key = 'friend:${ev['peer']}';
        title = vi ? 'Lời mời kết bạn' : 'Friend request';
        final who = ev['name']?.toString() ?? '';
        final note = ev['note']?.toString() ?? '';
        body = note.isEmpty ? who : '$who: $note';
      default:
        return;
    }
    // Locked chats: neither messages, their reminders nor calls show a name or text.
    final lockedChat = (kind == 'message' && lockedConvs.contains(key)) ||
        ((kind == 'reminder' || kind == 'call') && lockedConvs.contains(ev['conv']?.toString()));
    if (hideContent || lockedChat) {
      // Privacy: never reveal names or message text (app lock / user choice).
      title = 'Lumora';
      body = switch (kind) {
        'message' => vi ? 'Bạn có tin nhắn mới' : 'You have a new message',
        'call' => vi ? 'Cuộc gọi đến' : 'Incoming call',
        'remote' => vi ? 'Có yêu cầu truy cập từ xa. Mở Lumora để trả lời.' : 'Someone asked for remote access. Open Lumora to answer.',
        'friend' => vi ? 'Bạn có lời mời kết bạn mới' : 'You have a new friend request',
        'reminder' => vi ? 'Bạn có một nhắc hẹn' : 'You have a reminder',
        _ => vi ? 'Bạn có thông báo mới' : 'You have a new notification',
      };
      if (kind == 'message') key = 'message';
    }
    try {
      await _service.invokeMethod('notify', {'kind': kind, 'key': key, 'title': title, 'body': body});
    } catch (_) {}
  }

  bool _muted(String conv) {
    if (conv.isEmpty) return false;
    try {
      if (isMuted(conv)) return true;
      final i = conv.indexOf('#');
      return i > 0 && isMuted(conv.substring(0, i));
    } catch (_) {
      return false;
    }
  }

  /// Foreground-service call types follow the calls that use the microphone.
  void _onCallEvent(Map<String, dynamic> ev) {
    final id = ev['call_id']?.toString() ?? '';
    final before = _liveCalls.isNotEmpty;
    switch (ev['state']) {
      case 'active' || 'connected' || 'ringing' || 'calling' || 'connecting':
        _liveCalls.add(id);
      case 'incoming':
        break; // not answered yet: no microphone
      default:
        _liveCalls.remove(id);
    }
    final now = _liveCalls.isNotEmpty;
    if (now != before) {
      unawaited(_service.invokeMethod('setCall', {'active': now}).catchError((_) => null));
    }
  }

  void _onEvent(Map<String, dynamic> ev) {
    // Reminders always ring (they are alarms); everything else only in the background.
    if (!_foreground || ev['event'] == 'reminder_due') unawaited(_notifyBackground(ev));
    if (ev['event'] == 'call') _onCallEvent(ev);
    if (ev['event'] != 'remote_state' || ev['role'] != 'host') return;
    final session = ev['session']?.toString() ?? '';
    final state = ev['state']?.toString() ?? '';
    if (state == 'active') {
      if (_hostSessions.add(session)) unawaited(_hostStarted(session, ev['control'] == true));
    } else if (state == 'ended' || state == 'failed' || state == 'denied') {
      _hostSessions.remove(session);
      if (_hostSessions.isEmpty) unawaited(_screen.invokeMethod('stop').catchError((_) => null));
    }
  }

  /// Native → Dart on `lumora/screen`.
  Future<Object?> _onScreenCall(MethodCall call) async {
    if (call.method == 'stopped') {
      // Capture ended without us asking (status-bar "stop sharing", screen
      // lock, Android revoked it): end the host sessions rather than leave
      // the viewer on a frozen picture.
      await _endHostSessions();
    }
    return null;
  }

  Future<void> _endHostSessions() async {
    final sessions = _hostSessions.toList();
    _hostSessions.clear();
    for (final s in sessions) {
      try {
        await _api?.remoteEnd(s);
      } catch (_) {}
    }
  }

  Future<void> _hostStarted(String session, bool control) async {
    // One consent covers every host session (one capture feeds them all).
    if (_asking) return;
    _asking = true;
    try {
      bool ok;
      try {
        ok = await _screen.invokeMethod<bool>('start').timeout(consentTimeout) ?? false;
      } on TimeoutException {
        // Nobody answered (Lumora stayed in the background): give up the
        // request natively too, so a late "Allow" is not used.
        await _screen.invokeMethod('cancel').catchError((_) => null);
        ok = false;
      }
      if (!ok) {
        // Consent refused / timed out (or no media support): don't leave the
        // viewer(s) on a black screen.
        if (_hostSessions.isNotEmpty) await _endHostSessions();
        return;
      }
      if (control && !await inputEnabled()) await openInputGuide();
    } catch (e) {
      debugPrint('Lumora: screen share: $e');
    } finally {
      _asking = false;
    }
  }
}

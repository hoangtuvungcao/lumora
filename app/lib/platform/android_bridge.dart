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
import 'dart:convert';
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

  /// The call whose screen share runs the MediaProjection capture (null: none).
  String? _callShare;

  /// Capture of a call's screen share ended natively (status-bar "stop
  /// sharing", screen lock, Android revoked it): the call screen turns its
  /// button off. The core was already told.
  void Function(String callId)? onCallShareStopped;

  /// Tests: the call whose screen is being shared.
  @visibleForTesting
  String? get debugCallShare => _callShare;

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
  static bool get hideContent => _hideContent;
  static set hideContent(bool v) {
    if (v && !_hideContent) _forget(null); // names and pictures leave the launcher too
    _hideContent = v;
  }

  static bool _hideContent = false;

  /// Settings › Notifications › Chat bubbles (Android 11+): message
  /// notifications carry a bubble that opens the chat over other apps.
  static bool bubbles = false; // follows Settings.chatBubbles (off by default)

  /// A notification, bubble or launcher shortcut asks to open this chat
  /// (wired by AppServices).
  static void Function(String conv)? onOpenConv;

  /// Answer / Decline on the incoming-call notification: action `answer` |
  /// `decline` and the call it was posted for (wired by AppServices).
  static void Function(String action, String callId)? onCallAction;

  /// The chat on screen right now (NavStore.readingConv): its messages are
  /// not notified; any other chat's are, also while Lumora is in front.
  static String? Function() readingConv = _none;
  static String? _none() => null;

  /// Settings › Notifications sounds: the call notification rings with the
  /// phone's ringtone, message notifications use the default notification
  /// sound, both vibrate (Notifier.kt picks the matching channel).
  static bool callSound = true;
  static bool messageSound = true;
  static bool reminderSound = true;
  static bool vibrate = true;

  /// Muted chats that still notify @mentions of me (Settings.mentionsOnlyChats).
  static Set<String> mentionsOnly = const {};

  /// How long a message notification waits for a read receipt from another of
  /// my devices (the chat open there) before it is posted.
  static Duration readGrace = const Duration(milliseconds: 1200);

  /// "Hoãn 10 phút" / "Mở" on a reminder notification (wired by AppServices).
  static void Function(String action, Map<String, dynamic> reminder)? onReminderAction;

  /// Locked chats: their notifications (messages, reminders, calls) never
  /// show a name or text (and a newly locked chat loses its shortcut/bubble).
  static Set<String> get lockedConvs => _lockedConvs;
  static set lockedConvs(Set<String> v) {
    final added = v.difference(_lockedConvs);
    _lockedConvs = v;
    if (added.isNotEmpty) _forget(added.toList());
  }

  static Set<String> _lockedConvs = const {};

  /// Removes chats' conversation shortcuts, bubbles and notifications (null: all).
  static void _forget(List<String>? convs) {
    if (!isAndroid) return;
    unawaited(_service.invokeMethod('forgetConversations', {'convs': convs}).catchError((_) => null));
  }

  /// Muted chats get no message notifications (calls still ring). Wired by
  /// AppServices to the ChatStore.
  static bool Function(String conv) isMuted = _never;
  static bool _never(String _) => false;

  /// A chat's title (group notifications read "Group – Author"). Wired by
  /// AppServices to the ChatStore.
  static String? Function(String conv) convTitle = _noTitle;
  static String? _noTitle(String _) => null;

  /// Notification keys to remove for a core event (`call` over / answered or
  /// declined elsewhere; a chat read on another device), else empty.
  static List<String> cancelKeysFor(Map<String, dynamic> ev) {
    switch (ev['event']) {
      case 'call':
        return ev['state'] == 'incoming' ? const [] : const ['call'];
      case 'conversation':
        final id = ev['id']?.toString() ?? '';
        final unread = ev['unread'];
        return id.isNotEmpty && unread is num && unread == 0 ? [id] : const [];
      case 'conversation_removed':
        final id = ev['conv']?.toString() ?? '';
        return id.isEmpty ? const [] : [id];
    }
    return const [];
  }

  /// Title of a message notification: the author, or "Group – Author".
  static String messageTitle(String conv, String author) {
    if (!conv.startsWith('g:')) return author;
    final group = convTitle(conv) ?? '';
    if (group.isEmpty) return author;
    return author.isEmpty || author == 'Lumora' ? group : '$group – $author';
  }

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
    _service.setMethodCallHandler(_onServiceCall);
    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
    }
    try {
      await _service.invokeMethod('start');
    } catch (e) {
      debugPrint('Lumora: foreground service: $e');
    }
    // A notification / bubble tapped while Lumora was not running yet.
    try {
      final conv = await _service.invokeMethod<String>('takeOpenConv');
      if (conv != null && conv.isNotEmpty) onOpenConv?.call(conv);
      final call = await _service.invokeMapMethod<String, Object?>('takeCallAction');
      if (call != null) onCallAction?.call(call['action']?.toString() ?? '', call['callId']?.toString() ?? '');
    } catch (_) {}
  }

  // ------------------------------------------------------------ background

  /// Is Lumora exempt from battery optimisation, and which phone maker
  /// (`xiaomi`, `oppo`, `vivo`, `huawei`, `samsung`, '') — `autostart`: the
  /// maker has its own autostart screen worth opening. null off Android.
  static Future<BackgroundStatus?> backgroundStatus() async {
    if (!isAndroid) return null;
    try {
      final m = await _service.invokeMapMethod<String, Object?>('background');
      if (m == null) return null;
      return BackgroundStatus(ignoringBattery: m['ignoring'] == true, oem: m['oem']?.toString() ?? '', autostart: m['autostart'] == true);
    } catch (_) {
      return null;
    }
  }

  /// Android's "let Lumora run in the background" dialog (battery optimisation).
  static Future<bool> requestIgnoreBattery() async {
    if (!isAndroid) return false;
    try {
      return await _service.invokeMethod<bool>('requestIgnoreBattery') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The phone maker's autostart screen (Xiaomi & co.), else the app's details.
  static Future<bool> openAutostart() async {
    if (!isAndroid) return false;
    try {
      return await _service.invokeMethod<bool>('openAutostart') ?? false;
    } catch (_) {
      return false;
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
    _callShare = null;
    if (!isAndroid) return;
    _screen.setMethodCallHandler(null);
    _service.setMethodCallHandler(null);
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

  /// Screen sharing in a call: on Android the core's capturer only gets
  /// frames from MediaProjection, so ask for the consent (and start the
  /// capture) before the core is told. false: refused / no answer / no media
  /// support — the call must not claim to share a black screen. Elsewhere the
  /// core captures by itself: always true.
  Future<bool> startCallShare(String callId) async {
    if (!isAndroid) return true;
    if (_callShare == callId) return true;
    bool ok;
    try {
      ok = await _screen.invokeMethod<bool>('start').timeout(consentTimeout) ?? false;
    } on TimeoutException {
      await _screen.invokeMethod('cancel').catchError((_) => null);
      ok = false;
    } catch (e) {
      debugPrint('Lumora: call screen share: $e');
      ok = false;
    }
    if (ok) _callShare = callId;
    return ok;
  }

  /// The call stopped sharing its screen (or ended): stop the capture unless
  /// a remote-desktop host session still uses it.
  Future<void> stopCallShare(String callId) async {
    if (_callShare != callId) return;
    _callShare = null;
    if (_hostSessions.isEmpty && !_asking) await _screen.invokeMethod('stop').catchError((_) => null);
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
    String? kind, key, title, body, sender, callId;
    switch (ev['event']) {
      case 'message':
        if (ev['mine'] == true || ev['kind'] == 'system') return;
        // "Gửi không âm báo": the sender asked for no sound / notification.
        if (ev['silent'] == true || (ev['meta'] is Map && (ev['meta'] as Map)['silent'] == true)) return;
        final conv = ev['conv']?.toString() ?? '';
        // An @mention of me: its own channel and sound, and it gets through a
        // chat muted as "Mentions only".
        final mention = _mentions.remove(ev['id']?.toString() ?? '') != null;
        // Muted chat (or its community/group, for channel convs "group#channel").
        if (_muted(conv) && !(mention && _mentionsOnly(conv))) return;
        // Read on another of my devices right away (its chat was open there):
        // the read receipt comes within [readGrace] — then no alert here.
        if (readGrace > Duration.zero) {
          final arrived = DateTime.now();
          await Future<void>.delayed(readGrace);
          final read = _readAt[conv];
          if (read != null && !read.isBefore(arrived)) return;
        }
        final b = ev['body'];
        final text = b is Map ? (b['text'] ?? (b['name'] != null ? '${vi ? 'Tệp' : 'File'}: ${b['name']}' : null)) : null;
        kind = mention ? 'mention' : 'message';
        key = conv;
        var author = await _nameOf(ev['author']?.toString() ?? '');
        if (author == 'Lumora' && ev['author_name'] is String) author = ev['author_name'] as String; // a group member, not a contact
        title = messageTitle(conv, author);
        body = text?.toString() ?? (vi ? 'Tin nhắn mới' : 'New message');
        sender = author;
      case 'call':
        if (ev['state'] != 'incoming') return;
        kind = 'call';
        key = 'call';
        callId = ev['call_id']?.toString();
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
    // (`locked` comes from the core: locked on another device of the account)
    final lockedChat = ev['locked'] == true ||
        ((kind == 'message' || kind == 'mention') && lockedConvs.contains(key)) ||
        ((kind == 'reminder' || kind == 'call') && lockedConvs.contains(ev['conv']?.toString()));
    if (hideContent || lockedChat) {
      // Privacy: never reveal names or message text (app lock / user choice).
      title = 'Lumora';
      body = switch (kind) {
        'message' || 'mention' => vi ? 'Bạn có tin nhắn mới' : 'You have a new message',
        'call' => vi ? 'Cuộc gọi đến' : 'Incoming call',
        'remote' => vi ? 'Có yêu cầu truy cập từ xa. Mở Lumora để trả lời.' : 'Someone asked for remote access. Open Lumora to answer.',
        'friend' => vi ? 'Bạn có lời mời kết bạn mới' : 'You have a new friend request',
        'reminder' => vi ? 'Bạn có một nhắc hẹn' : 'You have a reminder',
        _ => vi ? 'Bạn có thông báo mới' : 'You have a new notification',
      };
      if (kind == 'message' || kind == 'mention') key = 'message';
    }
    // A chat whose content may show: an Android conversation (person, picture,
    // launcher shortcut) with its bubble; tapping it opens the chat.
    final chat = (kind == 'message' || kind == 'mention') && !hideContent && !lockedChat && key.isNotEmpty && key != 'message'
        ? await conversationArgs(key, sender ?? '', author: ev['author']?.toString() ?? '', ts: ev['ts'])
        : const <String, Object?>{};
    try {
      await _service.invokeMethod('notify', {
        'kind': kind,
        'key': key,
        'title': title,
        'body': body,
        ...soundArgs(kind),
        ...chat,
        // Answer / Decline buttons hand it back (callAction)
        'callId': ?callId,
        // the "Hoãn 10 phút" / "Mở" actions hand this back (reminderAction)
        if (kind == 'reminder') 'reminder': jsonEncode({for (final e in ev.entries) if (e.key != 'event') e.key: e.value}),
      });
    } catch (_) {}
  }

  /// The `notify` arguments that make a message notification an Android
  /// conversation: the chat id (to open it), who wrote, the chat's name (a
  /// group's title), its picture and whether it may bubble.
  @visibleForTesting
  Future<Map<String, Object?>> conversationArgs(String conv, String sender, {String author = '', Object? ts}) async {
    final group = conv.startsWith('g:');
    final avatar = await _avatar(group ? conv : author);
    return {
      'conv': conv,
      'sender': sender,
      'convTitle': group ? (convTitle(conv) ?? '') : sender,
      'group': group,
      'avatar': ?avatar,
      'bubble': bubbles,
      if (ts is num && ts > 0) 'ts': ts.toInt(),
    };
  }

  /// Pictures for notifications: peer or `g:<gid>` → bytes (null: none), for a while.
  final Map<String, (DateTime, Uint8List?)> _avatars = {};

  Future<Uint8List?> _avatar(String id) async {
    final api = _api;
    if (id.isEmpty || api == null) return null;
    final hit = _avatars[id];
    if (hit != null && DateTime.now().difference(hit.$1) < const Duration(minutes: 10)) return hit.$2;
    Uint8List? bytes;
    try {
      final b64 = await (id.startsWith('g:') ? api.groupAvatar(id.substring(2)) : api.contactAvatar(id)).timeout(const Duration(seconds: 2));
      if (b64 != null && b64.isNotEmpty) bytes = base64Decode(b64.contains(',') ? b64.substring(b64.indexOf(',') + 1) : b64);
    } catch (_) {}
    if (_avatars.length > 64) _avatars.remove(_avatars.keys.first);
    _avatars[id] = (DateTime.now(), bytes);
    return bytes;
  }

  /// Sound / vibration of a system notification of [kind] (Notifier.kt).
  static Map<String, bool> soundArgs(String? kind) => switch (kind) {
        'call' => {'sound': callSound, 'vibrate': vibrate},
        'message' || 'mention' => {'sound': messageSound, 'vibrate': vibrate},
        'reminder' => {'sound': reminderSound, 'vibrate': vibrate},
        _ => const {},
      };

  /// Message id → when its `mention` event came (it precedes the message).
  final Map<String, DateTime> _mentions = {};

  /// conv → when it was last read (unread 0), here or on another device.
  final Map<String, DateTime> _readAt = {};

  bool _mentionsOnly(String conv) {
    if (mentionsOnly.contains(conv)) return true;
    final i = conv.indexOf('#');
    return i > 0 && mentionsOnly.contains(conv.substring(0, i));
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
        if (id == _callShare) unawaited(stopCallShare(id));
    }
    final now = _liveCalls.isNotEmpty;
    if (now != before) {
      unawaited(_service.invokeMethod('setCall', {'active': now}).catchError((_) => null));
    }
    // A live video call: leaving Lumora (Home / Recents) keeps it on screen picture-in-picture.
    if (ev.containsKey('video')) {
      if (_liveCalls.contains(id) && ev['video'] == true) {
        _videoCalls.add(id);
      } else {
        _videoCalls.remove(id);
      }
    }
    _videoCalls.retainWhere(_liveCalls.contains);
    final pip = _videoCalls.isNotEmpty;
    if (pip != _pipOn) {
      _pipOn = pip;
      unawaited(_service.invokeMethod('setPip', {'on': pip}).catchError((_) => null));
    }
  }

  final Set<String> _videoCalls = {};
  bool _pipOn = false;

  /// Is [ev] posted as a system notification? In the background: everything
  /// notifiable. In front: reminders (alarms) and messages of a chat that is
  /// not the one on screen — like a heads-up from any other app (the system
  /// notification makes the sound; SoundAlerts stays quiet on Android).
  static bool shouldNotify(Map<String, dynamic> ev, {required bool foreground, String? reading}) {
    if (!foreground) return true;
    switch (ev['event']) {
      case 'reminder_due':
        return true;
      case 'message':
        final conv = ev['conv']?.toString() ?? '';
        return conv.isNotEmpty && conv != reading;
    }
    return false;
  }

  /// Native → Dart: open a chat (notification / bubble / shortcut tap).
  @visibleForTesting
  static void debugOpenConv(String conv) => onOpenConv?.call(conv);

  /// An event raised by the app itself (a snoozed reminder firing again):
  /// notified like the core's own.
  void onLocalEvent(Map<String, dynamic> ev) {
    if (isAndroid && _api != null) _onEvent(ev);
  }

  void _onEvent(Map<String, dynamic> ev) {
    switch (ev['event']) {
      case 'mention':
        final id = ev['id']?.toString() ?? '';
        if (id.isNotEmpty) _mentions[id] = DateTime.now();
        if (_mentions.length > 64) _mentions.remove(_mentions.keys.first);
      case 'conversation':
        final id = ev['id']?.toString() ?? '';
        if (id.isNotEmpty && ev['unread'] == 0) _readAt[id] = DateTime.now();
    }
    for (final key in cancelKeysFor(ev)) {
      unawaited(_service.invokeMethod('cancelNotification', {'key': key}).catchError((_) => null));
    }
    if (ev['event'] == 'conversation_removed') {
      final conv = ev['conv']?.toString() ?? '';
      if (conv.isNotEmpty) _forget([conv]);
    }
    if (shouldNotify(ev, foreground: _foreground, reading: readingConv())) unawaited(_notifyBackground(ev));
    if (ev['event'] == 'call') _onCallEvent(ev);
    if (ev['event'] != 'remote_state' || ev['role'] != 'host') return;
    final session = ev['session']?.toString() ?? '';
    final state = ev['state']?.toString() ?? '';
    if (state == 'active') {
      if (_hostSessions.add(session)) unawaited(_hostStarted(session, ev['control'] == true));
    } else if (state == 'ended' || state == 'failed' || state == 'denied') {
      _hostSessions.remove(session);
      if (_hostSessions.isEmpty && _callShare == null) unawaited(_screen.invokeMethod('stop').catchError((_) => null));
    }
  }

  /// Native → Dart on `lumora/service`: a reminder notification's action.
  Future<Object?> _onServiceCall(MethodCall call) async {
    if (call.method == 'openConv') {
      final conv = (call.arguments as Map?)?['conv']?.toString() ?? '';
      if (conv.isEmpty || onOpenConv == null) return false;
      onOpenConv!(conv);
      return true;
    }
    if (call.method == 'callAction') {
      final a = (call.arguments as Map?) ?? const {};
      final action = a['action']?.toString() ?? '';
      if (onCallAction == null || (action != 'answer' && action != 'decline')) return false;
      onCallAction!(action, a['callId']?.toString() ?? '');
      return true;
    }
    if (call.method != 'reminderAction') return null;
    final a = (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
    Map<String, dynamic> data = const {};
    try {
      final j = jsonDecode(a['reminder']?.toString() ?? '');
      if (j is Map) data = j.cast<String, dynamic>();
    } catch (_) {}
    if (data.isEmpty) return false;
    onReminderAction?.call(a['action']?.toString() ?? '', data);
    return true;
  }

  @visibleForTesting
  Future<Object?> debugServiceCall(MethodCall call) => _onServiceCall(call);

  /// Native → Dart on `lumora/screen`.
  Future<Object?> _onScreenCall(MethodCall call) async {
    if (call.method == 'stopped') {
      // Capture ended without us asking (status-bar "stop sharing", screen
      // lock, Android revoked it): end the host sessions rather than leave
      // the viewer on a frozen picture. A call sharing its screen stops sharing.
      final share = _callShare;
      _callShare = null;
      if (share != null) {
        try {
          await _api?.callSet(share, screen: false);
        } catch (_) {}
        onCallShareStopped?.call(share);
      }
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

/// Whether Lumora may keep running in the background (see
/// [AndroidBridge.backgroundStatus]).
class BackgroundStatus {
  const BackgroundStatus({required this.ignoringBattery, this.oem = '', this.autostart = false});
  final bool ignoringBattery;
  final String oem;
  final bool autostart;
}

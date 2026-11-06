import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/api.dart';

/// iPhone/iPad integration (no-op on every other platform):
///
/// * **Bonjour** – advertise/browse `_lumora._udp` with the system's DNS-SD
///   (`LumoraBonjour.swift`); sightings go straight into the core via
///   `lumora_lan_candidate`. No Apple multicast entitlement needed.
/// * **Resume fast path** – when the app returns to the foreground the core
///   re-dials friends at once, so whatever they queued for us arrives now.
/// * **Instant notifications (opt-in)** – only when the build was configured with
///   a push bridge (`--dart-define=LUMORA_PUSH_URL=… --dart-define=LUMORA_PUSH_KEY=…`).
///   Swift gets the APNs/VoIP tokens, the core seals them to the bridge key and
///   gives them to friends (docs/src/ops/push.md).
/// * **CallKit** – calls that rang through PushKit: answering/declining/muting on
///   the CallKit screen, and ending the CallKit call with the right reason when
///   the caller hangs up, nobody answers, another of my devices answers, or the
///   call is answered/declined in Lumora's own screen. Locked chats ring without
///   a name ([lockedConvs]).
/// * **Screen broadcast** – opens the system picker for the ReplayKit extension.
class AppleServices with WidgetsBindingObserver {
  AppleServices._();
  static final instance = AppleServices._();

  static const pushUrl = String.fromEnvironment('LUMORA_PUSH_URL');
  static const pushKey = String.fromEnvironment('LUMORA_PUSH_KEY');
  static const appTopic = String.fromEnvironment('LUMORA_APP_TOPIC', defaultValue: 'vn.lumora.lumora');

  static const _bonjour = MethodChannel('vn.lumora/bonjour');
  static const _push = MethodChannel('vn.lumora/push');
  static const _screen = MethodChannel('vn.lumora/screen_broadcast');

  /// Tests: pretend to run on iOS.
  @visibleForTesting
  static bool? debugIsIOS;

  static bool get isIOS => debugIsIOS ?? (!kIsWeb && Platform.isIOS);

  /// The build has a push bridge, so the "instant notifications" switch can be shown.
  static bool get pushAvailable => isIOS && pushUrl.isNotEmpty && pushKey.isNotEmpty;

  /// The core rings an incoming call for this long (core: auto-miss after 45 s);
  /// an `ended` that comes this late without an answer is a missed call.
  static const _ringSeconds = 44;

  LumoraApi? _api;
  final Set<String> _answerWhenRinging = {};

  /// Declined on the CallKit screen before the invite reached the core.
  final Set<String> _declineWhenRinging = {};

  /// Calls CallKit is showing (reported through PushKit), from the moment Swift
  /// reported them until they end; each gets a matching CXCallEndedReason.
  final Set<String> _callKit = {};

  /// CallKit calls answered on the CallKit screen (not in Lumora's own one).
  final Set<String> _answeredInCallKit = {};

  /// Last core state per live call (`incoming`, `ringing`, `active`).
  final Map<String, String> _states = {};

  /// Recently ended calls → CallKit reason, for a push that arrives after the
  /// call is already over (e.g. the core got the hang-up first).
  final Map<String, String> _recentlyEnded = {};

  static Set<String> _lockedConvs = const {};

  /// Locked chats (Settings › Privacy). Their calls ring through CallKit as
  /// "Incoming call" without a name, and their notifications show no sender or
  /// text. Synced to the App Group (Swift keeps only hashes) so PushKit and the
  /// notification extension can decide before Dart runs. Set from
  /// `AppServices._syncPrivacy`.
  static Set<String> get lockedConvs => _lockedConvs;
  static set lockedConvs(Set<String> convs) {
    if (setEquals(convs, _lockedConvs)) return;
    _lockedConvs = Set.unmodifiable(convs);
    if (!isIOS) return;
    _push.invokeMethod<void>('setLockedConvs', {'convs': _lockedConvs.toList()..sort()}).catchError((_) {});
  }

  /// Ids of the calls CallKit is showing (tests, diagnostics).
  @visibleForTesting
  Set<String> get callKitCalls => Set.unmodifiable(_callKit);

  /// CallKit is showing (and ringing) this call: Lumora must not ring too.
  bool showsOnCallKit(String callId) => _callKit.contains(callId);

  /// Bumped whenever the calls CallKit shows may have changed (sound_alerts.dart
  /// stops its own ringtone once CallKit rings).
  final ValueNotifier<int> callKitRevision = ValueNotifier(0);
  void _kitChanged() => callKitRevision.value++;

  @visibleForTesting
  void debugReset() {
    _api = null;
    _answerWhenRinging.clear();
    _declineWhenRinging.clear();
    _callKit.clear();
    _answeredInCallKit.clear();
    _states.clear();
    _recentlyEnded.clear();
    _lockedConvs = const {};
  }

  /// Tests: deliver a call from Swift (`vn.lumora/push`).
  @visibleForTesting
  Future<dynamic> debugHandlePush(MethodCall call) => _onPushCall(call);

  Future<void> attach(LumoraApi api) async {
    if (!isIOS) return;
    _api = api;
    _states.clear(); // a new core session: no live calls yet
    WidgetsBinding.instance.addObserver(this);
    _push.setMethodCallHandler(_onPushCall);
    // Swift keeps tokens / CallKit answers that arrived before Dart was ready
    _push.invokeMethod<void>('refresh').catchError((_) {});
    await _advertise();
  }

  Future<void> detach() async {
    if (!isIOS) return;
    WidgetsBinding.instance.removeObserver(this);
    _push.setMethodCallHandler(null);
    _api = null;
    _states.clear();
    try {
      await _bonjour.invokeMethod<void>('stop');
    } catch (_) {}
  }

  Future<void> _advertise() async {
    final api = _api;
    if (api == null) return;
    try {
      final adv = await api.request('lan_advert');
      if (adv is Map) await _bonjour.invokeMethod<void>('start', Map<String, dynamic>.from(adv));
    } catch (e) {
      debugPrint('bonjour: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      unawaited(syncReminders(background: true));
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final api = _api;
    if (api == null) return;
    unawaited(syncReminders(background: false));
    // Reconnect now (friends flush their outbox to us) and refresh the daily Bonjour name.
    api.request('resume').catchError((_) => null);
    _advertise();
  }

  // ---------------------------------------------------------------- reminders

  /// Settings mirrored by AppServices: reminders alert at all (notifications
  /// and the reminder sound on), texts hidden, the app's language.
  static bool reminderAlerts = true;
  static bool hideContent = false;
  static String language = 'vi';

  /// Reminders snoozed in the app (reminder_snooze.dart), with `snooze_until`.
  static List<Map<String, dynamic>> Function() snoozedReminders = () => const [];

  /// In the background the core is suspended and cannot raise `reminder_due`:
  /// the upcoming reminders (and snoozed ones) become local notifications with
  /// the system sound. Back in front they are removed again (the core rings
  /// them in-app). Asks for notification permission once, in front, when
  /// there is something to remind.
  Future<void> syncReminders({required bool background}) async {
    if (!isIOS) return;
    if (!background) {
      await _push.invokeMethod<void>('clearReminders').catchError((_) {});
      final items = await reminderItems();
      if (items.isNotEmpty && reminderAlerts) await _push.invokeMethod<bool>('requestLocalAlerts').catchError((_) => false);
      return;
    }
    final items = reminderAlerts ? await reminderItems() : const <Map<String, Object>>[];
    await _push.invokeMethod<void>('scheduleReminders', {'items': items}).catchError((_) {});
  }

  /// What [syncReminders] schedules: {id, at_ms, title, body, conv}, private
  /// for locked chats / hidden content.
  @visibleForTesting
  Future<List<Map<String, Object>>> reminderItems() async {
    final out = <Map<String, Object>>[];
    final vi = language != 'en';
    final word = vi ? 'Nhắc hẹn' : 'Reminder';
    void add(Map d, int at) {
      final id = d['msg_id']?.toString() ?? '';
      if (id.isEmpty || at <= 0) return;
      final conv = d['conv']?.toString() ?? '';
      final private = hideContent || _lockedConvs.contains(conv);
      final title = d['title']?.toString() ?? '';
      final note = d['note']?.toString() ?? '';
      out.add({
        'id': id,
        'at_ms': at,
        'conv': conv,
        'title': private ? 'Lumora' : (title.isEmpty ? word : '$word: $title'),
        'body': private ? (vi ? 'Bạn có một nhắc hẹn' : 'You have a reminder') : (note.isNotEmpty ? note : (vi ? 'Đến giờ hẹn rồi' : "It's time")),
      });
    }

    try {
      final list = await _api?.request('reminders');
      if (list is List) {
        for (final d in list) {
          if (d is Map) add(d, (d['at_ms'] as num?)?.toInt() ?? 0);
        }
      }
    } catch (_) {}
    for (final d in snoozedReminders()) {
      add(d, (d['snooze_until'] as num?)?.toInt() ?? 0);
    }
    return out;
  }

  // ---------------------------------------------------------------- push (opt-in)

  /// Ask iOS for notification permission and register with the bridge.
  /// Returns false if the user declined or the build has no bridge.
  Future<bool> enablePush() async {
    if (!pushAvailable) return false;
    try {
      final ok = await _push.invokeMethod<bool>('enable', {'bridge_url': pushUrl, 'bridge_key': pushKey, 'topic': appTopic});
      return ok ?? false;
    } catch (e) {
      debugPrint('push enable: $e');
      return false;
    }
  }

  Future<void> disablePush() async {
    if (!isIOS) return;
    try {
      await _push.invokeMethod<void>('disable');
    } catch (_) {}
    await _api?.request('push_unregister').catchError((_) => null);
  }

  /// The Notification Service Extension reads this (App Group) and then shows only
  /// "New message" instead of the sender and text.
  static void syncHideContent(bool hide) {
    hideContent = hide;
    if (!isIOS) return;
    _push.invokeMethod<void>('setHideContent', {'hide': hide}).catchError((_) {});
  }

  Future<dynamic> _onPushCall(MethodCall call) async {
    try {
      return await _handlePush(call);
    } finally {
      _kitChanged();
    }
  }

  Future<dynamic> _handlePush(MethodCall call) async {
    final api = _api;
    final a = (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
    final id = a['call_id']?.toString() ?? '';
    switch (call.method) {
      case 'tokens': // Swift got APNs (+ VoIP) tokens: seal + share them through the core
        if (api == null) return false;
        await api.request('push_register', {
          'bridge_url': pushUrl,
          'bridge_key': pushKey,
          'topic': appTopic,
          'apns': a['apns'] ?? '',
          'voip': a['voip'] ?? '',
          'sandbox': a['sandbox'] == true,
          'notify_key': a['notify_key'] ?? '',
        });
        return true;
      case 'incomingCall': // rang through PushKit: CallKit shows it from now on
        api?.request('resume').catchError((_) => null); // dial friends now so the invite arrives fast
        if (id.isEmpty) return null;
        final over = _recentlyEnded[id];
        if (over != null) {
          _endCallKit(id, over); // the hang-up beat the push
          return null;
        }
        _callKit.add(id);
        final state = _states[id];
        if (state == 'active' && !_answeredInCallKit.contains(id)) {
          _callKit.remove(id);
          _endCallKit(id, 'answered_elsewhere'); // already answered in Lumora's own screen
        } else if (_states.entries.any((e) => e.key != id && e.value != 'ended')) {
          _callKit.remove(id);
          _endCallKit(id, 'unanswered'); // in another call: the core declines it (busy)
        }
        return null;
      case 'callGone': // Swift stopped showing it (timeout, Do Not Disturb, …)
        _callKit.remove(id);
        _answeredInCallKit.remove(id);
        return null;
      case 'answerCall': // CallKit "Answer"; the invite may not have reached the core yet
        if (id.isEmpty) return null;
        _callKit.add(id);
        _answeredInCallKit.add(id);
        if (api == null) {
          _answerWhenRinging.add(id);
          return null;
        }
        try {
          await api.callAnswer(id, true, video: a['video'] == true);
        } catch (_) {
          _answerWhenRinging.add(id);
        }
        return null;
      case 'endCall': // declined / hung up on the CallKit screen
        _answerWhenRinging.remove(id);
        _callKit.remove(id);
        _answeredInCallKit.remove(id);
        if (id.isEmpty) return null;
        final answered = a['answered'] == true || _states[id] == 'active';
        if (api == null || !_states.containsKey(id)) {
          // The invite has not reached the core yet: decline it when it does.
          if (!answered && !_recentlyEnded.containsKey(id)) _declineWhenRinging.add(id);
          return null;
        }
        try {
          if (answered) {
            await api.callEnd(id);
          } else {
            await api.callAnswer(id, false);
          }
        } catch (_) {
          await api.callEnd(id).catchError((_) {});
        }
        return null;
      case 'muteCall': // mute button on the CallKit screen
        if (id.isNotEmpty && api != null) {
          await api.callSet(id, mic: a['muted'] != true).catchError((_) {});
        }
        return null;
    }
    return null;
  }

  void _endCallKit(String id, String reason) {
    _push.invokeMethod<void>('callEnded', {'call_id': id, 'reason': reason}).catchError((_) {});
  }

  /// Called for every core `call` event (state/stores.dart).
  void onCallEvent(Map<String, dynamic> d) {
    if (!isIOS) return;
    final id = d['call_id']?.toString() ?? '';
    final state = d['state']?.toString() ?? '';
    if (id.isEmpty) return;
    if (state == 'ended') {
      final reason = _endReason(d, _states.remove(id));
      _answerWhenRinging.remove(id);
      _declineWhenRinging.remove(id);
      _answeredInCallKit.remove(id);
      _recentlyEnded.remove(id);
      _recentlyEnded[id] = reason;
      while (_recentlyEnded.length > 32) {
        _recentlyEnded.remove(_recentlyEnded.keys.first);
      }
      if (_callKit.remove(id)) {
        _endCallKit(id, reason);
        _kitChanged();
      }
      return;
    }
    final first = !_states.containsKey(id);
    _states[id] = state;
    if (state == 'incoming') {
      if (_declineWhenRinging.remove(id)) {
        _api?.callAnswer(id, false).catchError((_) {});
        return;
      }
      if (_answerWhenRinging.remove(id)) {
        _api?.callAnswer(id, true, video: d['video'] == true).catchError((_) {});
      }
      if (first && !_callKit.contains(id)) {
        // CallKit may show it already (or a ring whose push Swift could not open).
        _push.invokeMethod<bool>('coreIncoming', {'call_id': id}).then((shown) {
          if (shown == true && _states.containsKey(id)) {
            _callKit.add(id);
            _kitChanged();
          }
        }).catchError((_) {});
      }
    } else if (state == 'active' && _callKit.contains(id) && !_answeredInCallKit.contains(id)) {
      // Answered in Lumora's own screen while CallKit was ringing too: dismiss CallKit.
      _callKit.remove(id);
      _endCallKit(id, 'answered_elsewhere');
    }
  }

  /// The user declined or hung up in Lumora's own call screen. Ends a CallKit
  /// call the way CallKit expects (an end action) instead of as "remote ended".
  /// The lead's api.dart can call this from `callAnswer(id, false)` / `callEnd`.
  void endedLocally(String callId) {
    if (!isIOS) return;
    _answerWhenRinging.remove(callId);
    _answeredInCallKit.remove(callId);
    if (_callKit.remove(callId)) _endCallKit(callId, 'local');
  }

  /// CXCallEndedReason (as a string for Swift) for a core `ended` event.
  static String _endReason(Map<String, dynamic> d, String? lastState) {
    switch (d['reason']?.toString()) {
      case 'answered_elsewhere':
        return 'answered_elsewhere'; // another of my devices answered
      case 'declined_elsewhere':
        return 'declined_elsewhere';
    }
    if (lastState == 'incoming' || lastState == null) {
      final seconds = (d['duration_s'] as num?)?.toInt() ?? 0;
      return seconds >= _ringSeconds ? 'unanswered' : 'remote';
    }
    return 'remote';
  }

  // ---------------------------------------------------------------- screen broadcast

  /// Show the system "Start Broadcast" sheet preselecting Lumora's extension.
  static Future<void> showBroadcastPicker() async {
    if (!isIOS) return;
    try {
      await _screen.invokeMethod<void>('showPicker');
    } catch (e) {
      debugPrint('broadcast picker: $e');
    }
  }
}

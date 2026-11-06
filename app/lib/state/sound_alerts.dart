// When Lumora rings, plays the ringback and pings for a new message.
//
// Calls follow [CallStore]: the ringtone plays while a call is `incoming`
// (and not just answered on another of my devices), the ringback while my own
// call is `ringing`; anything else — answered, declined, hung up, answered or
// declined elsewhere, missed/timed out, busy — leaves that state and so
// stops the sound at once. On iPhone a call that CallKit shows rings through
// CallKit only (the system ringtone), never twice. On Android the call
// notification posted in the background carries the ringtone itself;
// CallTones.kt keeps the two from overlapping.
//
// Messages: a ping (and a short vibration on phones) for a new message from
// someone else in a chat that is neither open on screen nor muted, with the
// notifications and message-sound settings on; an @mention of me has its own,
// brighter sound and gets through a chat muted as "Mentions only". A message
// counts as new only when the chat's unread count went up with it (the core's
// `conversation` event right after the `message`): history copied from
// another device stays quiet, and so does a message read on another of my
// devices within [SoundAlerts.readGrace]. On iPhone only while Lumora is in
// front (in the background the system notification sounds); on Android never:
// every message of a chat not on screen is a system notification there, in
// front too, and it makes the sound.
//
// Reminders (`reminder_due`, also a snoozed one firing again): the reminder
// alarm sound, unless Android's reminder notification already rings.

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/api.dart';
import '../platform/android_bridge.dart';
import '../platform/apple_services.dart';
import '../platform/tones.dart';
import 'settings.dart';
import 'stores.dart';

enum CallTone { none, ring, ringback }

class SoundAlerts {
  SoundAlerts({
    required this.calls,
    required this.chat,
    required this.nav,
    required this.settings,
    TonePlayer? player,
    bool? phone,
    bool Function()? foreground,
    bool Function(String callId)? onCallKit,
    bool? reminderByNotification,
    bool? messagesByNotification,
  })  : player = player ?? TonePlayer.platform(),
        reminderByNotification = reminderByNotification ?? AndroidBridge.isAndroid,
        messagesByNotification = messagesByNotification ?? AndroidBridge.isAndroid,
        phone = phone ?? TonePlayer.canVibrate,
        _foreground = foreground ?? _appInFront,
        _onCallKit = onCallKit ?? AppleServices.instance.showsOnCallKit;

  final CallStore calls;
  final ChatStore chat;
  final NavStore nav;
  final Settings settings;
  final TonePlayer player;

  /// Android / iPhone: vibration, and pings only while Lumora is in front.
  final bool phone;
  final bool Function() _foreground;
  final bool Function(String callId) _onCallKit;

  /// Members whose messages I hide: no ping for them either.
  bool Function(String peer)? isHiddenMember;

  /// What plays now (tests).
  CallTone get tone => _tone;
  CallTone _tone = CallTone.none;
  (bool, bool)? _ringFlags;
  bool _attached = false;

  static bool _appInFront() {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null || s == AppLifecycleState.resumed;
  }

  void attach() {
    if (_attached) return;
    _attached = true;
    calls.addListener(sync);
    settings.addListener(sync);
    AppleServices.instance.callKitRevision.addListener(sync);
    sync();
  }

  void dispose() {
    if (_attached) {
      calls.removeListener(sync);
      settings.removeListener(sync);
      AppleServices.instance.callKitRevision.removeListener(sync);
      _attached = false;
    }
    for (final p in _pending.values) {
      p.timer.cancel();
    }
    _pending.clear();
    for (final t in _due.values) {
      t.cancel();
    }
    _due.clear();
    if (_tone != CallTone.none) unawaited(player.stop());
    _tone = CallTone.none;
  }

  bool get _ringSound => settings.callRingtone;
  bool get _ringVibrate => phone && settings.vibrate;

  /// The sound the current call wants.
  CallTone get wanted {
    final c = calls.call;
    if (c == null) return CallTone.none;
    switch (c.phase) {
      case CallPhase.incoming:
        if (calls.answeredElsewhere != null) return CallTone.none;
        if (_onCallKit(c.callId)) return CallTone.none; // CallKit rings
        return _ringSound || _ringVibrate ? CallTone.ring : CallTone.none;
      case CallPhase.ringing:
        // joining a voice channel is not "calling someone"
        return calls.isVoiceChannel(c.conv) ? CallTone.none : CallTone.ringback;
      case CallPhase.active || CallPhase.ended:
        return CallTone.none;
    }
  }

  /// Brings the sound in line with the call (CallStore / settings changed).
  void sync() {
    final w = wanted;
    final flags = w == CallTone.ring ? (_ringSound, _ringVibrate) : null;
    if (w == _tone && flags == _ringFlags) return;
    _tone = w;
    _ringFlags = flags;
    switch (w) {
      case CallTone.none:
        unawaited(player.stop());
      case CallTone.ring:
        unawaited(player.ring(sound: flags!.$1, vibrate: flags.$2));
      case CallTone.ringback:
        unawaited(player.ringback());
    }
  }

  // ---------------------------------------------------------------- messages

  /// Messages waiting for their chat's `conversation` event: conv → unread
  /// before, and whether it @mentions me.
  final Map<String, ({int unread, bool mention, Timer timer})> _pending = {};

  /// Pings waiting out [readGrace] (conv → its alert).
  final Map<String, Timer> _due = {};

  /// conv → when a `mention` event for it came (it precedes its `message`).
  final Map<String, DateTime> _mentioned = {};
  DateTime _lastPing = DateTime.fromMillisecondsSinceEpoch(0);

  /// A new message waits this long before it pings: if another of my devices
  /// has the chat open, its read receipt (`conversation`, unread 0) arrives
  /// meanwhile and this device stays quiet — one alert per account, like the
  /// big messengers.
  Duration readGrace = const Duration(milliseconds: 1200);

  /// Every core event (EventHub listener; runs before the stores update).
  void onEvent(String name, Map<String, dynamic> d) {
    switch (name) {
      case 'mention':
        final conv = d['conv']?.toString() ?? '';
        if (conv.isNotEmpty) _mentioned[conv] = DateTime.now();
      case 'message':
        _onMessage(d);
      case 'conversation':
        final id = d['id']?.toString() ?? '';
        final unread = d['unread'];
        if (unread is! num) return;
        final p = _pending.remove(id);
        if (p != null) {
          p.timer.cancel();
          if (unread > p.unread) _schedule(id, p.mention ? Alert.mention : Alert.message);
        } else if (unread == 0) {
          _due.remove(id)?.cancel(); // read on another of my devices
        }
      case 'reminder_due':
        _onReminder(d);
    }
  }

  /// Android posts a notification for a message of any chat that is not on
  /// screen, also in front (AndroidBridge.shouldNotify): its channel sounds,
  /// so no ping here.
  final bool messagesByNotification;

  void _onMessage(Map<String, dynamic> d) {
    final conv = d['conv']?.toString() ?? '';
    final at = _mentioned.remove(conv);
    final mention = at != null && DateTime.now().difference(at) < const Duration(seconds: 5);
    if (messagesByNotification || !_mayPing) return;
    if (d['mine'] == true) return;
    final kind = d['kind']?.toString() ?? 'text';
    if (kind == 'system' || kind == 'call') return;
    if (d['silent'] == true || (d['meta'] is Map && (d['meta'] as Map)['silent'] == true)) return;
    if (d['deleted'] == true || d['status'] == 3) return;
    if (conv.isEmpty || conv == nav.readingConv) return;
    if (_muted(conv) && !(mention && _mentionsOnly(conv))) return;
    if (isHiddenMember?.call(d['author']?.toString() ?? '') ?? false) return;
    final prev = _pending[conv];
    if (prev != null && (prev.mention || !mention)) return; // one ping per burst
    prev?.timer.cancel();
    _pending[conv] = (
      unread: prev?.unread ?? chat.convs[conv]?.unread ?? 0,
      mention: mention,
      timer: Timer(const Duration(seconds: 2), () => _pending.remove(conv)),
    );
  }

  bool get _mayPing {
    if (!settings.notifications) return false;
    if (!settings.messageSound && !(phone && settings.vibrate)) return false;
    if (calls.call != null) return false; // ringing or in a call
    if (phone && !_foreground()) return false; // the system notification sounds
    return true;
  }

  /// The chat (or its group, for a channel "group#channel").
  bool _either(String conv, bool Function(String c) f) {
    if (f(conv)) return true;
    final i = conv.indexOf('#');
    return i > 0 && f(conv.substring(0, i));
  }

  bool _muted(String conv) => _either(conv, (c) => chat.convs[c]?.muted ?? false);

  /// Muted, except for @mentions of me (the mute sheet's "Mentions only").
  bool _mentionsOnly(String conv) => _either(conv, settings.mentionsOnlyChats.contains);

  void _schedule(String conv, Alert kind) {
    _due.remove(conv)?.cancel();
    if (readGrace == Duration.zero) {
      _ping(conv, kind);
      return;
    }
    _due[conv] = Timer(readGrace, () {
      _due.remove(conv);
      _ping(conv, kind);
    });
  }

  void _ping(String conv, Alert kind) {
    // re-checked: the chat may have been opened / read / a call started meanwhile
    if (!_mayPing || conv == nav.readingConv) return;
    final now = DateTime.now();
    if (now.difference(_lastPing) < const Duration(milliseconds: 1500)) return;
    _lastPing = now;
    unawaited(player.alert(kind, sound: settings.messageSound, vibrate: phone && settings.vibrate));
  }

  // --------------------------------------------------------------- reminders

  /// Android posts every reminder as a notification on the "Reminders"
  /// channel (its own sound, even in front): nothing to play here.
  final bool reminderByNotification;

  void _onReminder(Map<String, dynamic> d) {
    if (reminderByNotification || !settings.notifications) return;
    final sound = settings.reminderSound;
    final vibrate = phone && settings.vibrate;
    if (!sound && !vibrate) return;
    if (calls.call != null) return; // the banner is enough during a call
    if (phone && !_foreground()) return; // iPhone: the local notification rings
    unawaited(player.alert(Alert.reminder, sound: sound, vibrate: vibrate));
  }
}

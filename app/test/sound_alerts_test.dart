// Ringtone / ringback / message ping (lib/state/sound_alerts.dart) with a fake
// TonePlayer: when they start and stop, and which messages ping.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/l10n/strings.dart';
import 'package:lumora/platform/android_bridge.dart';
import 'package:lumora/platform/tones.dart';
import 'package:lumora/state/reminder_snooze.dart';
import 'package:lumora/state/settings.dart';
import 'package:lumora/state/sound_alerts.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/settings/settings_screen.dart';
import 'package:lumora/ui/theme.dart';
import 'package:provider/provider.dart';

class _Api extends MockLumoraApi {
  _Api() : super(timers: false);
  final sent = <(String, Map<String, dynamic>)>[];

  @override
  Future<dynamic> request(String cmd, [Map<String, dynamic> args = const {}]) async {
    sent.add((cmd, args));
    if (cmd == 'call_start') return {'call_id': 'out1'};
    return null;
  }
}

class FakeTones implements TonePlayer {
  final log = <String>[];

  /// What plays now: 'ring(sound,vibrate)', 'ringback' or null.
  String? playing;
  int pings = 0;
  (bool, bool)? lastPing;
  final alerts = <Alert>[];

  @override
  Future<void> ring({required bool sound, required bool vibrate}) async {
    playing = 'ring($sound,$vibrate)';
    log.add(playing!);
  }

  @override
  Future<void> ringback() async {
    playing = 'ringback';
    log.add('ringback');
  }

  @override
  Future<void> stop() async {
    playing = null;
    log.add('stop');
  }

  @override
  Future<void> alert(Alert kind, {required bool sound, required bool vibrate}) async {
    alerts.add(kind);
    if (kind == Alert.reminder) return;
    pings++;
    lastPing = (sound, vibrate);
    log.add('ping');
  }
}

class _Rig {
  _Rig({bool phone = false, bool front = true, bool reminderByNotification = false, bool messagesByNotification = false, Duration readGrace = Duration.zero}) : _front = front {
    api = _Api();
    calls = CallStore(api);
    chat = ChatStore(api);
    nav = NavStore();
    settings = Settings();
    tones = FakeTones();
    sounds = SoundAlerts(
      calls: calls,
      chat: chat,
      nav: nav,
      settings: settings,
      player: tones,
      phone: phone,
      foreground: () => _front,
      onCallKit: callKit.contains,
      reminderByNotification: reminderByNotification,
      messagesByNotification: messagesByNotification,
    )
      ..readGrace = readGrace
      ..attach();
  }

  late final _Api api;
  late final CallStore calls;
  late final ChatStore chat;
  late final NavStore nav;
  late final Settings settings;
  late final FakeTones tones;
  late final SoundAlerts sounds;
  final Set<String> callKit = {};
  bool _front;
  set front(bool v) => _front = v;

  void call(String id, String state, {String? reason, String from = 'bob'}) => calls.onCall({
        'call_id': id,
        'conv': 'd:$from',
        'peer': from,
        'from': from,
        'state': state,
        'reason': ?reason,
      });

  void conv(String id, {int unread = 0, bool muted = false}) =>
      chat.onConversation({'id': id, 'kind': id.startsWith('g:') ? 1 : 0, 'title': id, 'last_ts': 1, 'unread': unread, 'muted': muted});

  /// A message event followed by the core's `conversation` row (unread → [unreadAfter]).
  void message(String conv, {bool mine = false, String kind = 'text', int? unreadAfter, String author = 'bob', bool mention = false, Map<String, dynamic> extra = const {}}) {
    final before = chat.convs[conv]?.unread ?? 0;
    final id = 'm${DateTime.now().microsecondsSinceEpoch}';
    if (mention) sounds.onEvent('mention', {'conv': conv, 'id': id, 'author': author, 'text': 'hi'});
    final m = {'id': id, 'conv': conv, 'author': author, 'mine': mine, 'kind': kind, 'body': {'text': 'hi'}, 'ts': 1, 'status': 2, ...extra};
    sounds.onEvent('message', m);
    final row = {'id': conv, 'kind': 0, 'title': conv, 'last_ts': 2, 'unread': unreadAfter ?? (mine ? before : before + 1), 'muted': chat.convs[conv]?.muted ?? false};
    sounds.onEvent('conversation', row);
    chat.onConversation(row);
  }
}

void main() {
  tearDown(() => TonePlayer.debugIsPhone = null);

  group('incoming call ringtone', () {
    test('rings on incoming, stops when answered', () async {
      final r = _Rig();
      r.call('c1', 'incoming');
      expect(r.tones.playing, 'ring(true,false)');
      await r.calls.answer(true);
      expect(r.tones.playing, isNull);
      expect(r.sounds.tone, CallTone.none);
    });

    test('stops when declined', () async {
      final r = _Rig();
      r.call('c1', 'incoming');
      await r.calls.answer(false);
      expect(r.tones.playing, isNull);
    });

    test('stops when the caller hangs up (ended)', () {
      final r = _Rig();
      r.call('c1', 'incoming');
      r.call('c1', 'ended');
      expect(r.tones.playing, isNull);
    });

    test('stops at once when answered on another of my devices', () {
      final r = _Rig();
      r.call('c1', 'incoming');
      r.call('c1', 'ended', reason: 'answered_elsewhere');
      // the incoming screen still says "answered on …" for a moment, silently
      expect(r.calls.answeredElsewhere, isNotNull);
      expect(r.tones.playing, isNull);
    });

    test('stops when declined on another device', () {
      final r = _Rig();
      r.call('c1', 'incoming');
      r.call('c1', 'ended', reason: 'declined_elsewhere');
      expect(r.tones.playing, isNull);
    });

    testWidgets('stops when the ring times out', (t) async {
      final r = _Rig();
      r.call('c1', 'incoming');
      expect(r.tones.playing, startsWith('ring'));
      await t.pump(const Duration(seconds: 91));
      expect(r.calls.call, isNull);
      expect(r.tones.playing, isNull);
    });

    test('a second call while in a call does not ring (busy)', () async {
      final r = _Rig();
      r.call('c1', 'incoming');
      await r.calls.answer(true);
      r.tones.log.clear();
      r.call('c2', 'incoming', from: 'carol');
      expect(r.tones.log.where((e) => e.startsWith('ring')), isEmpty);
    });

    test('respects the ringtone setting; phones may vibrate only', () {
      final desk = _Rig();
      desk.settings.update((s) => s.callRingtone = false);
      desk.call('c1', 'incoming');
      expect(desk.tones.playing, isNull);

      final phone = _Rig(phone: true);
      phone.settings.update((s) => s.callRingtone = false);
      phone.call('c1', 'incoming');
      expect(phone.tones.playing, 'ring(false,true)');
      phone.settings.update((s) => s.vibrate = false);
      expect(phone.tones.playing, isNull);
      phone.settings.update((s) => s.callRingtone = true);
      expect(phone.tones.playing, 'ring(true,false)');
    });

    test('a call CallKit shows is not rung again in-app', () {
      final r = _Rig();
      r.callKit.add('c1');
      r.call('c1', 'incoming');
      expect(r.tones.playing, isNull);
      // CallKit picks up a call already ringing in-app: ours stops
      final r2 = _Rig();
      r2.call('c9', 'incoming');
      expect(r2.tones.playing, startsWith('ring'));
      r2.callKit.add('c9');
      r2.sounds.sync();
      expect(r2.tones.playing, isNull);
    });
  });

  group('outgoing ringback', () {
    test('plays while ringing, stops when answered', () async {
      final r = _Rig();
      await r.calls.start('d:bob');
      expect(r.tones.playing, 'ringback');
      r.call('out1', 'active');
      expect(r.tones.playing, isNull);
    });

    test('stops when I hang up or the call ends unanswered', () async {
      final r = _Rig();
      await r.calls.start('d:bob');
      await r.calls.hangup();
      expect(r.tones.playing, isNull);

      final r2 = _Rig();
      await r2.calls.start('d:bob');
      r2.call('out1', 'ended');
      expect(r2.tones.playing, isNull);
    });

    test('no ringback when joining a voice channel', () async {
      final r = _Rig();
      await r.calls.start('g:abc#voice');
      expect(r.tones.playing, isNull);
    });
  });

  group('message ping', () {
    test('pings for a new message in a chat that is not open', () {
      final r = _Rig();
      r.conv('d:bob');
      r.message('d:bob');
      expect(r.tones.pings, 1);
      expect(r.tones.lastPing, (true, false));
    });

    test('Android: no in-app ping, also in front (the message notification sounds)', () {
      final r = _Rig(phone: true, messagesByNotification: true);
      r.conv('d:bob');
      r.message('d:bob');
      r.message('d:bob', mention: true);
      expect(r.tones.pings, 0);
    });

    test('no ping for my own messages, system lines, silent messages', () {
      final r = _Rig();
      r.conv('d:bob');
      r.message('d:bob', mine: true);
      r.message('d:bob', kind: 'system');
      r.message('d:bob', extra: {'silent': true});
      expect(r.tones.pings, 0);
    });

    test('no ping in a muted chat (or a channel of a muted group)', () {
      final r = _Rig();
      r.conv('d:bob', muted: true);
      r.conv('g:grp', muted: true);
      r.message('d:bob');
      r.message('g:grp#general');
      expect(r.tones.pings, 0);
    });

    test('no ping for the chat open on screen', () {
      final r = _Rig();
      r.conv('d:bob');
      r.nav.openConv('d:bob');
      r.nav.chatShown('d:bob');
      r.message('d:bob', unreadAfter: 0);
      expect(r.tones.pings, 0);
      r.conv('d:carol');
      r.message('d:carol');
      expect(r.tones.pings, 1);
    });

    test('no ping for history or a message already read on another device', () {
      final r = _Rig();
      r.conv('d:bob', unread: 2);
      r.message('d:bob', unreadAfter: 2); // history copied from my other device
      r.message('d:bob', unreadAfter: 0); // read there already
      r.message('d:bob', extra: {'status': 3});
      expect(r.tones.pings, 0);
    });

    test('settings: message sound / notifications off; phones vibrate', () {
      final r = _Rig();
      r.conv('d:bob');
      r.settings.update((s) => s.messageSound = false);
      r.message('d:bob');
      expect(r.tones.pings, 0);
      r.settings.update((s) {
        s.messageSound = true;
        s.notifications = false;
      });
      r.message('d:bob');
      expect(r.tones.pings, 0);

      final p = _Rig(phone: true);
      p.conv('d:bob');
      p.settings.update((s) => s.messageSound = false);
      p.message('d:bob');
      expect(p.tones.pings, 1);
      expect(p.tones.lastPing, (false, true));
    });

    test('phones: no in-app ping in the background (the notification sounds)', () {
      final r = _Rig(phone: true, front: false);
      r.conv('d:bob');
      r.message('d:bob');
      expect(r.tones.pings, 0);
      r.front = true;
      r.message('d:bob');
      expect(r.tones.pings, 1);
    });

    test('no ping while a call rings; a burst pings once', () {
      final r = _Rig();
      r.conv('d:bob');
      r.call('c1', 'incoming');
      r.message('d:bob');
      expect(r.tones.pings, 0);
      r.call('c1', 'ended');
      r.message('d:bob');
      r.message('d:bob');
      expect(r.tones.pings, 1);
    });

    test('hidden group members do not ping', () {
      final r = _Rig();
      r.sounds.isHiddenMember = (p) => p == 'troll';
      r.conv('g:grp');
      r.message('g:grp', author: 'troll');
      expect(r.tones.pings, 0);
    });
  });

  group('mentions, mute, other devices', () {
    test('an @mention has its own sound', () {
      final r = _Rig();
      r.conv('g:grp');
      r.message('g:grp', mention: true);
      expect(r.tones.alerts, [Alert.mention]);
    });

    test('muted chat: a mention stays quiet unless the chat is "mentions only"', () {
      final r = _Rig();
      r.conv('g:grp', muted: true);
      r.message('g:grp', mention: true);
      expect(r.tones.alerts, isEmpty);
      r.settings.update((s) => s.mentionsOnlyChats = ['g:grp']);
      r.message('g:grp'); // a plain message: still muted
      expect(r.tones.alerts, isEmpty);
      r.message('g:grp', mention: true);
      expect(r.tones.alerts, [Alert.mention]);
    });

    testWidgets('read on another of my devices within the grace: no ping here', (t) async {
      final r = _Rig(readGrace: const Duration(milliseconds: 1200));
      r.conv('d:bob');
      r.message('d:bob');
      await t.pump(const Duration(milliseconds: 400));
      // my phone had the chat open: its read receipt arrives
      r.sounds.onEvent('conversation', {'id': 'd:bob', 'kind': 0, 'unread': 0});
      await t.pump(const Duration(seconds: 2));
      expect(r.tones.pings, 0);
      // nobody reads it: it pings after the grace
      r.conv('d:carol');
      r.message('d:carol');
      await t.pump(const Duration(milliseconds: 1100));
      expect(r.tones.pings, 0);
      await t.pump(const Duration(milliseconds: 200));
      expect(r.tones.pings, 1);
    });
  });

  group('reminders', () {
    test('a due reminder plays the alarm (desktop / iPhone in front)', () {
      final r = _Rig();
      r.sounds.onEvent('reminder_due', {'conv': 'd:bob', 'msg_id': 'r1', 'title': 'Họp'});
      expect(r.tones.alerts, [Alert.reminder]);
    });

    test('respects notifications / reminder sound; phones vibrate; Android leaves it to the notification', () {
      final r = _Rig();
      r.settings.update((s) => s.reminderSound = false);
      r.sounds.onEvent('reminder_due', {'msg_id': 'r1'});
      r.settings.update((s) {
        s.reminderSound = true;
        s.notifications = false;
      });
      r.sounds.onEvent('reminder_due', {'msg_id': 'r2'});
      expect(r.tones.alerts, isEmpty);

      final android = _Rig(phone: true, reminderByNotification: true);
      android.sounds.onEvent('reminder_due', {'msg_id': 'r3'});
      expect(android.tones.alerts, isEmpty);

      final iphone = _Rig(phone: true);
      iphone.settings.update((s) => s.reminderSound = false);
      iphone.sounds.onEvent('reminder_due', {'msg_id': 'r4'});
      expect(iphone.tones.alerts, [Alert.reminder]); // vibration only
    });

    testWidgets('snooze: fires again after 10 minutes, kept across a restart', (t) async {
      final settings = Settings();
      final fired = <Map<String, dynamic>>[];
      final sn = ReminderSnoozer(settings: settings, fire: fired.add);
      sn.snooze({'conv': 'd:bob', 'msg_id': 'r1', 'title': 'Họp', 'late': true});
      expect(settings.snoozedReminders.single['msg_id'], 'r1');
      await t.pump(const Duration(minutes: 9));
      expect(fired, isEmpty);
      await t.pump(const Duration(minutes: 1, seconds: 1));
      expect(fired.single['msg_id'], 'r1');
      expect(fired.single['snoozed'], true);
      expect(fired.single['late'], false);
      expect(settings.snoozedReminders, isEmpty);

      // saved, then the app restarts after the snooze came due
      sn.snooze({'conv': 'd:bob', 'msg_id': 'r2'});
      sn.dispose();
      final restored = Settings()..snoozedReminders = settings.snoozedReminders.map((m) => {...m, 'snooze_until': 1}).toList();
      final again = <Map<String, dynamic>>[];
      ReminderSnoozer(settings: restored, fire: again.add).restore();
      await t.pump(const Duration(milliseconds: 1));
      expect(again.single['msg_id'], 'r2');
      expect(again.single['late'], true);
    });

    testWidgets('"seen" cancels a snooze', (t) async {
      final settings = Settings();
      final fired = <Map<String, dynamic>>[];
      final sn = ReminderSnoozer(settings: settings, fire: fired.add);
      sn.snooze({'msg_id': 'r1'});
      sn.cancel('r1');
      await t.pump(const Duration(minutes: 11));
      expect(fired, isEmpty);
      expect(settings.snoozedReminders, isEmpty);
    });
  });

  group('Android notification sound flags', () {
    test('call / message notifications carry the settings', () {
      AndroidBridge.callSound = false;
      AndroidBridge.messageSound = true;
      AndroidBridge.vibrate = false;
      addTearDown(() {
        AndroidBridge.callSound = true;
        AndroidBridge.messageSound = true;
        AndroidBridge.vibrate = true;
      });
      expect(AndroidBridge.soundArgs('call'), {'sound': false, 'vibrate': false});
      expect(AndroidBridge.soundArgs('message'), {'sound': true, 'vibrate': false});
      expect(AndroidBridge.soundArgs('mention'), {'sound': true, 'vibrate': false});
      expect(AndroidBridge.soundArgs('reminder'), {'sound': true, 'vibrate': false});
      expect(AndroidBridge.soundArgs('friend'), isEmpty);
    });
  });

  group('settings', () {
    test('defaults on and persisted', () {
      final s = Settings();
      expect((s.callRingtone, s.messageSound, s.vibrate), (true, true, true));
      final j = (s
            ..callRingtone = false
            ..vibrate = false)
          .toJson();
      expect(j['call_ringtone'], false);
      expect(j['message_sound'], true);
      expect(j['vibrate'], false);
    });

    testWidgets('notification settings show the sound toggles (vibrate on phones)', (t) async {
      TonePlayer.debugIsPhone = true;
      final st = Settings();
      await t.pumpWidget(_settingsApp(st));
      await t.pumpAndSettle();
      final s = S(true);
      for (final k in ['call_ringtone', 'message_sound', 'reminder_sound', 'vibrate']) {
        expect(find.text(s(k)), findsOneWidget);
      }
      await t.tap(find.text(s('call_ringtone')));
      await t.pumpAndSettle();
      expect(st.callRingtone, isFalse);
      await t.tap(find.text(s('vibrate')));
      await t.pumpAndSettle();
      expect(st.vibrate, isFalse);
    });

    testWidgets('no vibrate toggle on computers', (t) async {
      TonePlayer.debugIsPhone = false;
      await t.pumpWidget(_settingsApp(Settings()));
      await t.pumpAndSettle();
      final s = S(true);
      expect(find.text(s('message_sound')), findsOneWidget);
      expect(find.text(s('vibrate')), findsNothing);
    });
  });
}

Widget _settingsApp(Settings st) => MultiProvider(
      providers: [ChangeNotifierProvider.value(value: st)],
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const Scaffold(body: SingleChildScrollView(child: NotificationSettingsGroup()))),
    );

// Community voice channels are drop-in rooms: the participant list comes from
// the core's `voice` events (no made-up speaking / muted state), switching
// channels leaves the old one before joining (one start path, never
// `call_start`), the "Voice connected" bar follows the room, and errors toast.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/stores.dart';
import 'package:provider/provider.dart';
import 'package:lumora/ui/groups/server_view.dart';
import 'package:lumora/ui/theme.dart';
import 'package:lumora/ui/widgets/peer_avatar.dart';

import 'helpers.dart';

class _VoiceSpy extends MockLumoraApi {
  _VoiceSpy() : super(timers: false);
  final log = <String>[];
  @override
  Future<dynamic> request(String cmd, [Map<String, dynamic> args = const {}]) {
    if (cmd == 'voice_join' || cmd == 'voice_leave' || cmd == 'call_start') log.add('$cmd ${args['conv']}');
    return super.request(cmd, args);
  }
}

Future<void> _flush(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await settle(t, frames: 4);
}

/// A new community with two voice channels; returns (space, voice A, voice B).
Future<(Space, String, String)> _community(WidgetTester t, AppServices sv) async {
  late Space sp;
  await t.runAsync(() async {
    final g = await sv.api.request('create_group', {'name': 'Phòng thoại thử', 'members': <String>[], 'kind': 1}) as Map;
    await sv.api.request('group_channel', {'gid': g['gid'], 'name': 'Phòng 2', 'voice': true});
    await sv.spaces.load();
    sp = sv.spaces.spaces.firstWhere((x) => x.name == 'Phòng thoại thử');
  });
  final voice = sp.channels.where((c) => c.voice).map((c) => c.conv).toList();
  expect(voice.length, 2);
  return (sp, voice[0], voice[1]);
}

Future<void> _pumpList(WidgetTester t, AppServices sv, Space sp) async {
  await t.pumpWidget(LumoraApp(
    services: sv,
    home: Scaffold(body: Builder(builder: (c) => ChannelList(space: c.select<SpacesStore, Space?>((x) => x.byId(sp.id)) ?? sp, onOpen: (_) {}))),
    overlays: false,
  ));
  await settle(t);
}

Future<void> _tapChannel(WidgetTester t, String conv) async {
  await t.tap(find.descendant(of: find.byKey(ValueKey('voice_channel_$conv')), matching: find.byType(InkWell)).first);
  await _flush(t);
  await _flush(t);
}

Future<void> _done(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 100));
  sv.dispose();
  resetSize(t);
}

void main() {
  setUpAll(loadFonts);

  testWidgets('participants, speaking and muted come from `voice` events; the counts are real', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    final mock = sv.api as MockLumoraApi;
    final (sp, a, _) = await _community(t, sv);
    final friends = sv.contacts.byPeer.values.where((c) => c.status == ContactStatus.friend).map((c) => c.peer).toList();
    final (p1, p2) = (friends[0], friends[1]);
    await _pumpList(t, sv, sp);
    expect(find.byKey(ValueKey('voice_count_$a')), findsNothing, reason: 'nobody in the room yet');

    // others join (B talking is not known yet; C has the microphone off)
    mock.simulateVoicePresence(a, [p1, p2], muted: [p2]);
    await _flush(t);
    expect(find.byKey(ValueKey('voice_participant_${a}_$p1')), findsOneWidget);
    expect(find.byKey(ValueKey('voice_participant_${a}_$p2')), findsOneWidget);
    expect(find.byKey(ValueKey('voice_muted_${a}_$p2')), findsOneWidget);
    expect(find.byKey(ValueKey('voice_muted_${a}_$p1')), findsNothing);
    expect(t.widget<Text>(find.byKey(ValueKey('voice_count_$a'))).data, '2');
    expect(find.byWidgetPredicate((w) => w is PeerAvatar && w.ringColor == LC.success), findsNothing, reason: 'nobody talks: no ring');
    // a `spaces` reload (the debounced one after `group` events lands at any time)
    // keeps who is muted: the list carries `muted` like the core's
    await t.runAsync(() => sv.spaces.load());
    await _flush(t);
    expect(find.byKey(ValueKey('voice_muted_${a}_$p2')), findsOneWidget, reason: 'a reload must not wipe the muted state');
    expect(find.byKey(ValueKey('voice_participant_${a}_$p1')), findsOneWidget);

    // I join: in the list too, and who talks comes from the room call
    await _tapChannel(t, a);
    expect(sv.spaces.joinedVoice, a);
    expect(find.byKey(ValueKey('voice_participant_${a}_${sv.session.me!.peer}')), findsOneWidget);
    mock.simulateVoicePresence(a, [p1, p2], muted: [p2], speaking: [p1]);
    await _flush(t);
    expect(sv.calls.call?.speaking, {p1});
    expect(find.byWidgetPredicate((w) => w is PeerAvatar && w.peer == p1 && w.ringColor == LC.success), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is PeerAvatar && w.peer == p2 && w.ringColor == LC.success), findsNothing);
    // p1 mutes (per-peer media state of the room call)
    mock.simulateVoicePresence(a, [p1, p2], muted: [p1, p2]);
    await _flush(t);
    expect(find.byKey(ValueKey('voice_muted_${a}_$p1')), findsOneWidget);
    expect(sv.calls.accountMuted(p1), isTrue);
    // my own microphone switch shows on my row
    await t.runAsync(() => sv.calls.toggle(mic: false));
    await _flush(t);
    expect(find.byKey(ValueKey('voice_muted_${a}_${sv.session.me!.peer}')), findsOneWidget);

    // the communities list says how many are in voice
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SpacesMobileScreen()), overlays: false));
    await settle(t);
    expect(find.textContaining('3 đang trong kênh thoại'), findsOneWidget);
    // the phone voice stage: who is there, the leave button
    await t.tap(find.text('Phòng thoại thử'));
    await settle(t);
    expect(find.byKey(const ValueKey('voice_stage')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('voice_stage')), matching: find.text('3 đang trong kênh thoại')), findsOneWidget);
    for (final p in [p1, p2, sv.session.me!.peer]) {
      expect(find.byKey(ValueKey('voice_stage_$p')), findsOneWidget);
    }
    await t.tap(find.byKey(const ValueKey('voice_stage_leave')));
    await _flush(t);
    expect(sv.spaces.joinedVoice, isNull);
    expect(sv.calls.call, isNull);
    expect(find.byKey(const ValueKey('voice_stage')), findsNothing);
    await _done(t, sv);
  });

  testWidgets('switching channels leaves the old one, then joins — never call_start', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final spy = _VoiceSpy();
    final sv = await makeServices(t, api: spy);
    final (sp, a, b) = await _community(t, sv);
    await _pumpList(t, sv, sp);

    await _tapChannel(t, a);
    expect(sv.spaces.joinedVoice, a);
    expect(sv.calls.call?.conv, a);
    expect(sv.calls.call?.room, isTrue);
    expect(sv.calls.minimized, isTrue, reason: 'a room stays in the small panel');

    await _tapChannel(t, b);
    expect(spy.log, ['voice_join $a', 'voice_leave $a', 'voice_join $b']);
    expect(sv.spaces.joinedVoice, b);
    expect(sv.calls.call?.conv, b);
    expect(sv.spaces.voice[a], isNot(contains(sv.session.me!.peer)));
    expect(sv.spaces.voice[b], contains(sv.session.me!.peer));

    // tapping the channel I'm in leaves it
    await _tapChannel(t, b);
    expect(spy.log.last, 'voice_leave $b');
    expect(sv.spaces.joinedVoice, isNull);
    expect(sv.calls.call, isNull);
    await _done(t, sv);
  });

  testWidgets('the "Voice connected" bar clears when the room ends or moves to another device', (t) async {
    setSize(t, const Size(1280, 800));
    final sv = await makeServices(t);
    final mock = sv.api as MockLumoraApi;
    final (sp, a, _) = await _community(t, sv);
    await _pumpList(t, sv, sp);

    await _tapChannel(t, a);
    expect(find.text('Đã kết nối thoại'), findsOneWidget);
    // the room call ends on its own (lost / removed from the community)
    mock.simulateVoiceRoomLost(a);
    await _flush(t);
    expect(sv.spaces.joinedVoice, isNull);
    expect(sv.calls.call, isNull);
    expect(find.text('Đã kết nối thoại'), findsNothing);

    // joined on another of my devices: the bar goes and a toast says where
    await _tapChannel(t, a);
    expect(find.text('Đã kết nối thoại'), findsOneWidget);
    mock.simulateVoiceRoomLost(a, moved: true, device: 'Laptop ở nhà');
    await _flush(t);
    expect(find.text('Đã kết nối thoại'), findsNothing);
    expect(find.text('Bạn đã vào kênh thoại trên Laptop ở nhà'), findsOneWidget);

    // hanging up from the call pill (call_end on the room) clears it too
    await _tapChannel(t, a);
    await t.runAsync(() => sv.calls.hangup());
    await _flush(t);
    expect(sv.spaces.joinedVoice, isNull);
    expect(find.text('Đã kết nối thoại'), findsNothing);
    await _done(t, sv);
  });

  testWidgets('a failed join shows a toast and leaves nothing connected', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    final mock = sv.api as MockLumoraApi;
    final (sp, a, _) = await _community(t, sv);
    await _pumpList(t, sv, sp);

    mock.failVoiceJoin = 'err.in_other_call';
    await _tapChannel(t, a);
    expect(find.text('Bạn đang trong một cuộc gọi khác.'), findsOneWidget);
    expect(sv.spaces.joinedVoice, isNull);
    expect(find.text('Đã kết nối thoại'), findsNothing);
    await t.pump(const Duration(seconds: 6));

    mock.failVoiceJoin = 'err.not_voice_channel';
    await _tapChannel(t, a);
    expect(find.text('Không vào được kênh thoại này.'), findsOneWidget);
    expect(sv.spaces.joinedVoice, isNull);
    await _done(t, sv);
  });
}

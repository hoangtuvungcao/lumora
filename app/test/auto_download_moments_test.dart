// Automatic downloads per network / kind (Settings › Storage & data), the Wi-Fi / mobile
// data hint sent to the core, and who sees my Khoảnh khắc (composer audience picker,
// Settings › Privacy lists).

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/platform/network_hint.dart';
import 'package:lumora/ui/chats/stories.dart';
import 'package:lumora/ui/chats/story_audience.dart';
import 'package:lumora/ui/settings/storage_screen.dart';

import 'helpers.dart';

MockLumoraApi _mock(AppServices sv) => sv.api as MockLumoraApi;

class _FakeConnectivity implements Connectivity {
  final ctl = StreamController<List<ConnectivityResult>>.broadcast();
  List<ConnectivityResult> now = [ConnectivityResult.wifi];
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => now;
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => ctl.stream;
}

Future<void> _flush(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await settle(t, frames: 12); // (page transitions end: the next tap reaches the screen)
}

Future<void> _done(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 100));
  sv.dispose();
  resetSize(t);
}

/// Picks [option] in the dropdown of the auto-download row [key].
Future<void> _choose(WidgetTester t, String key, String option) async {
  final row = find.byKey(ValueKey(key));
  await t.ensureVisible(row);
  await t.tap(find.descendant(of: row, matching: find.byType(DropdownButton<int>)));
  await settle(t, frames: 4);
  await t.tap(find.text(option).last);
  await _flush(t);
}

void main() {
  setUpAll(loadFonts);

  test('metered = mobile data without Wi-Fi / Ethernet', () {
    expect(isMeteredNetwork([ConnectivityResult.mobile]), isTrue);
    expect(isMeteredNetwork([ConnectivityResult.mobile, ConnectivityResult.vpn]), isTrue);
    expect(isMeteredNetwork([ConnectivityResult.wifi, ConnectivityResult.mobile]), isFalse);
    expect(isMeteredNetwork([ConnectivityResult.ethernet]), isFalse);
    expect(isMeteredNetwork([ConnectivityResult.none]), isFalse);
  });

  test('network class: Android\'s view knows roaming and metered Wi-Fi', () {
    expect(networkClass([ConnectivityResult.wifi]), 'wifi');
    expect(networkClass([ConnectivityResult.mobile]), 'cell');
    expect(networkClass([ConnectivityResult.none]), isNull);
    expect(networkClass([]), isNull);
    final c = [ConnectivityResult.mobile];
    expect(networkClass(c, {'online': true, 'cell': true, 'roaming': true, 'metered': true}), 'roaming');
    expect(networkClass(c, {'online': true, 'cell': true, 'roaming': false, 'metered': true}), 'cell');
    expect(networkClass([ConnectivityResult.wifi], {'online': true, 'wifi': true, 'metered': true}), 'roaming', reason: 'phone hotspot');
    expect(networkClass([ConnectivityResult.wifi], {'online': true, 'wifi': true, 'metered': false}), 'wifi');
    expect(networkClass([ConnectivityResult.ethernet], {'online': false}), 'wifi', reason: 'no Android answer: the plain list decides');
  });

  test('auto-download decisions: every network × kind with the default limits', () {
    const d = AutoDownload();
    const mb = 1 << 20;
    // photos and voice messages everywhere; videos and files on Wi-Fi only
    final expected = <String, Map<String, bool>>{
      'wifi': {'photo': true, 'video': true, 'voice': true, 'file': true},
      'cell': {'photo': true, 'video': false, 'voice': true, 'file': false},
      'roaming': {'photo': true, 'video': false, 'voice': true, 'file': false},
    };
    for (final net in expected.keys) {
      for (final kind in expected[net]!.keys) {
        expect(d.allows(net, kind, 800 * 1024), expected[net]![kind], reason: '$net × $kind (800 KB)');
      }
    }
    // the size limits
    expect(d.allows('wifi', 'photo', 5 * mb), isTrue);
    expect(d.allows('wifi', 'photo', 5 * mb + 1), isFalse);
    expect(d.allows('roaming', 'photo', 2 * mb), isFalse);
    expect(d.allows('wifi', 'video', 50 * mb), isTrue);
    expect(d.allows('wifi', 'video', 60 * mb), isFalse);
    expect(d.allows('wifi', 'file', 20 * mb), isTrue);
    expect(d.allows('wifi', 'file', 20 * mb, inGroup: true), isFalse, reason: 'groups: 10 MB');
    expect(d.allows('cell', 'voice', 500 * mb), isTrue);
    expect(d.allows('roaming', 'voice', 6 * mb), isFalse);
    expect(d.allows('cell', 'file', 0), isFalse, reason: 'off means off');
    // a policy from the core without the roaming column keeps its defaults
    final old = AutoDownload.fromJson({'wifi': {'photo': 7}});
    expect(old.wifi.photo, 7);
    expect(old.roaming.photo, AutoLimits.roaming.photo);
  });

  test('the network hint follows Wi-Fi ↔ mobile data ↔ roaming and is sent again to a restarted core', () async {
    final api = MockLumoraApi(timers: false);
    final conn = _FakeConnectivity()..now = [ConnectivityResult.mobile];
    Map<String, Object?>? info;
    final hint = NetworkHint(api, connectivity: conn, enabled: true, info: () async => info);
    await hint.start();
    expect(api.networkHints.map((h) => h['network']), ['cell']);
    expect(api.networkHints.single['metered'], isTrue);
    conn.ctl.add([ConnectivityResult.wifi, ConnectivityResult.mobile]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    conn.ctl.add([ConnectivityResult.none]); // offline: keeps the last state
    conn.ctl.add([ConnectivityResult.wifi]); // same state: not sent again
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(api.networkHints.map((h) => h['network']), ['cell', 'wifi']);
    // abroad: Android reports roaming
    info = {'online': true, 'cell': true, 'roaming': true, 'metered': true};
    conn.ctl.add([ConnectivityResult.mobile]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(hint.network, 'roaming');
    expect(hint.metered, isTrue);
    expect((await api.settingsGet())['network'], 'roaming');
    await hint.resend();
    expect(api.networkHints.map((h) => h['network']), ['cell', 'wifi', 'roaming', 'roaming']);
    hint.dispose();
    // desktops never send it
    final off = NetworkHint(api, connectivity: conn, enabled: false);
    await off.start();
    expect(api.networkHints.length, 4);
  });

  testWidgets('Storage & data: auto-download limits per network and kind reach the core', (t) async {
    setSize(t, const Size(390, 1600));
    final sv = await makeServices(t);
    final mock = _mock(sv);
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SingleChildScrollView(child: StorageSettings())), overlays: false));
    await _flush(t);
    expect(find.byKey(const ValueKey('auto_network')), findsOneWidget);
    // Wi-Fi defaults: photos 5 MB, videos 50 MB, files 25 MB (10 MB in groups), voice 50 MB
    expect(find.descendant(of: find.byKey(const ValueKey('auto_wifi_photo')), matching: find.text('Đến 5 MB')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('auto_wifi_video')), matching: find.text('Đến 50 MB')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('auto_wifi_file')), matching: find.text('Đến 25 MB')), findsOneWidget);
    expect(find.text('Trong nhóm: Đến 10 MB'), findsOneWidget);

    expect(find.descendant(of: find.byKey(const ValueKey('auto_wifi_voice')), matching: find.text('Luôn tự tải')), findsOneWidget);

    // mobile data: photos + voice, videos and files wait for a tap
    await t.tap(find.text('Di động'));
    await settle(t, frames: 3);
    expect(find.descendant(of: find.byKey(const ValueKey('auto_cell_photo')), matching: find.text('Đến 5 MB')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('auto_cell_video')), matching: find.text('Không tự tải')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('auto_cell_file')), matching: find.text('Không tự tải')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('auto_cell_voice')), matching: find.text('Luôn tự tải')), findsOneWidget);

    // roaming / metered Wi-Fi: its own column (photos 1 MB, voice 5 MB)
    await t.tap(find.text('Chuyển vùng'));
    await settle(t, frames: 3);
    expect(find.textContaining('Wi-Fi tính phí'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('auto_roaming_photo')), matching: find.text('Đến 1 MB')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('auto_roaming_voice')), matching: find.text('Đến 5 MB')), findsOneWidget);
    await _choose(t, 'auto_roaming_voice', 'Không tự tải');
    expect(mock.autoDownload['roaming']!['voice'], 0);
    expect(mock.autoDownload['cell']!['voice'], kAutoDownloadAlways, reason: 'mobile data untouched');
    await t.tap(find.text('Di động'));
    await settle(t, frames: 3);

    // no photos on mobile data; Wi-Fi untouched
    await _choose(t, 'auto_cell_photo', 'Không tự tải');
    expect(mock.autoDownload['cell']!['photo'], 0);
    expect(mock.autoDownload['wifi']!['photo'], 5 << 20);
    expect(find.descendant(of: find.byKey(const ValueKey('auto_cell_photo')), matching: find.text('Không tự tải')), findsOneWidget);

    // Wi-Fi files up to 100 MB: groups stay at 10 MB
    await t.tap(find.text('Wi-Fi'));
    await settle(t, frames: 3);
    await _choose(t, 'auto_wifi_file', 'Đến 100 MB');
    expect(mock.autoDownload['wifi']!['file'], 100 << 20);
    expect(mock.autoDownload['wifi']!['file_group'], 10 << 20);
    expect(sv.net.storage?['policy']?['auto_download']?['wifi']?['file'], 100 << 20, reason: 'screen shows the core’s answer');
    await _choose(t, 'auto_wifi_video', 'Luôn tự tải');
    expect(mock.autoDownload['wifi']!['video'], kAutoDownloadAlways);
    await _done(t, sv);
  });

  testWidgets('composer: audience chip → picker sheet; close friends picked on first use', (t) async {
    setSize(t, const Size(390, 1000));
    final sv = await makeServices(t);
    final mock = _mock(sv);
    final friends = sv.contacts.friends;
    expect(friends.length, greaterThan(2));
    await t.pumpWidget(LumoraApp(services: sv, home: const StoryComposer(), overlays: false));
    await _flush(t);
    expect(find.descendant(of: find.byKey(const ValueKey('story_audience_chip')), matching: find.text('Bạn bè')), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('story_audience_chip')));
    await settle(t, frames: 4);
    expect(find.text('Ai xem được khoảnh khắc này?'), findsOneWidget);
    expect(find.text('Tất cả bạn bè'), findsOneWidget);
    expect(find.text('Chưa chọn ai'), findsOneWidget);

    // "Bạn thân" with an empty list: the friend picker opens first
    await t.tap(find.byKey(const ValueKey('audience_close')));
    await settle(t, frames: 4);
    expect(find.text('Đã chọn 0'), findsOneWidget);
    await t.tap(find.byKey(ValueKey('pick_${friends[0].peer}')));
    await settle(t, frames: 2);
    expect(find.text('Đã chọn 1'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('picker_done')));
    await _flush(t);
    expect(sv.stories.close, [friends[0].peer]);
    expect((await t.runAsync(() => sv.api.settingsGet()))!['story_close'], [friends[0].peer], reason: 'saved in the core (synced)');
    expect(find.descendant(of: find.byKey(const ValueKey('story_audience_chip')), matching: find.text('Bạn thân')), findsOneWidget);

    // hide from someone through the sheet
    await t.tap(find.byKey(const ValueKey('story_audience_chip')));
    await settle(t, frames: 4);
    expect(find.text('1 người'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('audience_hidden')));
    await settle(t, frames: 4);
    await t.tap(find.byKey(ValueKey('pick_${friends[1].peer}')));
    await t.tap(find.byKey(const ValueKey('picker_done')));
    await _flush(t);
    expect(sv.stories.hidden, [friends[1].peer]);
    expect(find.text('Bạn bè, trừ 1 người bạn đã ẩn'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('audience_close')));
    await settle(t, frames: 4);

    // post: the chosen audience reaches the core
    await t.enterText(find.byType(TextField), 'Chỉ bạn thân');
    await t.pump();
    await t.tap(find.text('Đăng').last);
    await _flush(t);
    expect(mock.storyAudiences.last, 'close');
    await _done(t, sv);
  });

  testWidgets('Settings › Privacy: hidden list and close friends with friend pickers (English)', (t) async {
    setSize(t, const Size(390, 1400));
    final sv = await makeServices(t, locale: 'en');
    final friends = sv.contacts.friends;
    await t.runAsync(() => sv.stories.setAudience(hidden: [friends[2].peer]));
    sv.stories.audienceLoaded = false;
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: StoryPrivacyRows()), overlays: false));
    await _flush(t);
    expect(find.text('Hide moments from…'), findsOneWidget);
    expect(find.text('1 people'), findsOneWidget);
    expect(find.text('Nobody chosen yet'), findsOneWidget);

    // the hidden list opens with its people ticked; clear it
    await t.tap(find.byKey(const ValueKey('story_hidden_row')));
    await settle(t, frames: 4);
    expect(t.widget<CheckboxListTile>(find.byKey(ValueKey('pick_${friends[2].peer}'))).value, isTrue);
    expect(find.text('The people you pick never receive your moments.'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('picker_clear')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('picker_done')));
    await _flush(t);
    expect(sv.stories.hidden, isEmpty);
    expect(find.text('Not hidden from anyone'), findsOneWidget);

    // close friends: two people
    await t.tap(find.byKey(const ValueKey('story_close_row')));
    await settle(t, frames: 4);
    await t.tap(find.byKey(ValueKey('pick_${friends[0].peer}')));
    await t.tap(find.byKey(ValueKey('pick_${friends[1].peer}')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('picker_done')));
    await _flush(t);
    expect(sv.stories.close.toSet(), {friends[0].peer, friends[1].peer});
    expect(find.text('2 people'), findsOneWidget);
    final core = (await t.runAsync(() => sv.api.settingsGet()))!;
    expect(core['story_hidden'], isEmpty);
    expect((core['story_close'] as List).toSet(), {friends[0].peer, friends[1].peer});

    // changed on another device: the `settings` event reloads the lists
    await t.runAsync(() => sv.api.settingsSet({'story_close': <String>[]}));
    _mock(sv).emitForTest('settings', {'key': 'privacy.story_close'});
    await _flush(t);
    expect(sv.stories.close, isEmpty);
    expect(find.text('Nobody chosen yet'), findsOneWidget);
    await _done(t, sv);
  });
}

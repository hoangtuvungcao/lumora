// Features the 2026-11-07 audit found unfinished or half-wired: phone
// navigation, story viewers, live group read receipts, removing one sticker,
// core settings without a switch, default timers, Bot Studio "clear chat",
// core events nobody showed (`storage`, `remote_action`), the missed-busy call
// line and the core-made remote password.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/community_defaults.dart';
import 'package:lumora/state/settings.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/bots/botfather.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/chats/message_bubble.dart';
import 'package:lumora/ui/chats/stickers.dart';
import 'package:lumora/ui/chats/stories.dart';
import 'package:lumora/ui/friends/friends_screen.dart';
import 'package:lumora/ui/network/network_screen.dart';
import 'package:lumora/ui/remote/remote_home.dart';
import 'package:lumora/ui/settings/settings_screen.dart';
import 'package:lumora/ui/shell/home_shell.dart';

import 'helpers.dart';

Future<void> _done(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 100));
  sv.dispose();
  resetSize(t);
}

// Core events reach the stores in the real-async zone (see helpers / makeServices).
Future<void> _flush(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await settle(t);
}

MockLumoraApi _api(AppServices sv) => sv.api as MockLumoraApi;

String _friend(AppServices sv) => sv.contacts.friends.first.peer;

void main() {
  setUpAll(loadFonts);

  // ------------------------------------------------------------ 1. phone navigation
  group('phone navigation follows NavStore', () {
    testWidgets('nav.go(Section.remote) shows the Remote screen', (t) async {
      setSize(t, const Size(390, 844), dpr: 2);
      final sv = await makeServices(t);
      await t.pumpWidget(LumoraApp(services: sv, home: const HomeShell()));
      await settle(t);
      expect(find.byType(RemoteHomeScreen).hitTestable(), findsNothing);
      sv.nav.go(Section.remote);
      await settle(t);
      expect(find.byType(RemoteHomeScreen).hitTestable(), findsOneWidget);
      // a tab tap keeps NavStore in step (next go() is a real change)
      await t.tap(find.text('Bạn bè').last);
      await settle(t);
      expect(sv.nav.section, Section.friends);
      expect(find.byType(FriendsScreen).hitTestable(), findsOneWidget);
      await _done(t, sv);
    });

    testWidgets('a pushed page closes for go(); a chat open never switches the tab; Network is pushed', (t) async {
      setSize(t, const Size(390, 844), dpr: 2);
      final sv = await makeServices(t);
      await t.pumpWidget(LumoraApp(services: sv, home: const HomeShell()));
      await settle(t);
      // friends tab, then a chat opens on top: the tab underneath stays
      await t.tap(find.text('Bạn bè').last);
      await settle(t);
      final ctx = t.element(find.byType(FriendsScreen));
      final conv = sv.chat.convs.keys.firstWhere((c) => c.startsWith('d:'));
      sv.nav.openConv(conv);
      Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => ChatView(conv: conv)));
      await settle(t);
      expect(find.byType(ChatView), findsOneWidget);
      // a notification asks for the Remote screen: the chat page closes, Remote is in front
      sv.nav.go(Section.remote);
      await settle(t);
      expect(find.byType(ChatView), findsNothing);
      expect(find.byType(RemoteHomeScreen).hitTestable(), findsOneWidget);
      // phones have no Network tab: it comes as its own page
      sv.nav.go(Section.network);
      await settle(t);
      expect(find.byType(NetworkScreen), findsOneWidget);
      expect(sv.nav.section, Section.remote, reason: 'the tab stays; reading chats is not blocked');
      await _done(t, sv);
    });
  });

  // ------------------------------------------------------------ 2. link previews
  testWidgets('no "link previews" switch; an old settings file with the key still loads', (t) async {
    final dir = Directory.systemTemp.createTempSync('lumora_settings');
    final f = File('${dir.path}/settings.json')..writeAsStringSync(jsonEncode({'link_previews': true, 'locale': 'en', 'read_receipts': false}));
    final st = await t.runAsync(() => Settings.load(f));
    expect(st!.locale, 'en');
    expect(st.readReceipts, isFalse);
    expect(st.toJson().containsKey('link_previews'), isFalse);
    dir.deleteSync(recursive: true);

    setSize(t, const Size(600, 2400));
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: const Scaffold(body: SettingsSubPage(page: SettingsPage.privacy))));
    await settle(t);
    expect(find.text('Xem trước liên kết'), findsNothing);
    expect(find.text("Hiện trạng thái 'Đã xem'"), findsOneWidget, reason: 'the rest of Messages is still there');
    await _done(t, sv);
  });

  // ------------------------------------------------------------ 3. story viewers
  testWidgets('"N views" on my story opens who saw it; story_view raises the count live', (t) async {
    setSize(t, const Size(500, 900));
    final sv = await makeServices(t);
    final me = sv.session.me!.peer;
    await t.runAsync(() async {
      await sv.api.postStory(text: 'Xin chào');
      await sv.stories.load();
    });
    final mine = sv.stories.mine(me);
    final id = mine.last.id;
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: StoryViewer(groups: [MapEntry(me, mine)], initial: 0)));
    await settle(t, frames: 3);
    expect(find.text('0 lượt xem'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('story_views')));
    await _flush(t);
    expect(find.text('Người đã xem'), findsOneWidget);
    // the mock's viewers: the first friends, by name, with when they looked
    final viewers = await t.runAsync(() => sv.api.storyViewers(id));
    expect(viewers, isNotEmpty);
    expect(find.text(sv.contacts.nameOf(viewers!.first.peer)), findsOneWidget);
    expect(find.text('10 phút trước'), findsWidgets);
    // opening the list took the core's count
    expect(sv.stories.stories.firstWhere((s) => s.id == id).views, viewers.length);
    // a new viewer comes in while the story is open (the list closed)
    await t.tapAt(const Offset(250, 20));
    await settle(t, frames: 4);
    expect(find.text('Người đã xem'), findsNothing);
    final stranger = sv.contacts.friends.map((c) => c.peer).firstWhere((p) => viewers.every((v) => v.peer != p), orElse: () => 'X' * 52);
    _api(sv).emitForTest('story_view', {'id': id, 'viewer': stranger});
    await _flush(t);
    expect(sv.stories.stories.firstWhere((s) => s.id == id).views, viewers.length + 1);
    // the same viewer again is not a new view
    _api(sv).emitForTest('story_view', {'id': id, 'viewer': stranger});
    await _flush(t);
    expect(sv.stories.stories.firstWhere((s) => s.id == id).views, viewers.length + 1);
    await _done(t, sv);
  });

  test('story_viewers: the core\'s [{peer, ts}] and an older core\'s bare ids both parse', () async {
    final api = _ViewersApi([
      {'peer': 'A' * 52, 'ts': 5},
      'B' * 52,
      {'nope': 1},
    ]);
    final v = await api.storyViewers('x');
    expect(v.map((e) => e.peer), ['A' * 52, 'B' * 52]);
    expect(v.first.ts, 5);
    expect(v.last.ts, 0);
  });

  // ------------------------------------------------------------ 4. group read receipts
  testWidgets('group_read marks my group messages read live and reloads "Seen by"', (t) async {
    final sv = await makeServices(t);
    final conv = sv.chat.convs.values.firstWhere((c) => c.id.startsWith('g:') && !c.isCommunity).id;
    expect(sv.chat.groupSeen(conv, 100), isFalse);
    final tick = sv.chat.groupReadTick.value;
    _api(sv).emitForTest('group_read', {'conv': conv, 'peer': _friend(sv), 'upto': 150});
    await _flush(t);
    expect(sv.chat.groupSeen(conv, 100), isTrue);
    expect(sv.chat.groupSeen(conv, 200), isFalse, reason: 'read up to 150 only');
    expect(sv.chat.groupSeen('g:other', 100), isFalse);
    expect(sv.chat.groupReadTick.value, tick + 1);
    // an older receipt changes nothing
    _api(sv).emitForTest('group_read', {'conv': conv, 'peer': _friend(sv), 'upto': 120});
    await _flush(t);
    expect(sv.chat.groupReadTick.value, tick + 1);
    await _done(t, sv);
  });

  testWidgets('an open "Seen by" list reloads on group_read for its chat', (t) async {
    setSize(t, const Size(500, 900));
    final api = _SeenApi();
    final sv = await makeServices(t, api: api);
    final conv = sv.chat.convs.values.firstWhere((c) => c.id.startsWith('g:') && !c.isCommunity).id;
    final friends = sv.contacts.friends.map((c) => c.peer).toList();
    api.seen = [friends[0]];
    final m = Message.fromJson({'id': 'mx', 'conv': conv, 'author': sv.session.me!.peer, 'ts': 1, 'hlc': 100, 'kind': 'text', 'body': 'hi', 'mine': true});
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => showSeenBy(c, m), child: const Text('open'))))));
    await settle(t);
    await t.tap(find.text('open'));
    await _flush(t);
    expect(find.text('Đã xem bởi 1 người'), findsOneWidget);
    api.seen = [friends[0], friends[1]];
    // another chat's receipt: no reload
    _api(sv).emitForTest('group_read', {'conv': 'g:other', 'peer': friends[1], 'upto': 150});
    await _flush(t);
    expect(find.text('Đã xem bởi 1 người'), findsOneWidget);
    _api(sv).emitForTest('group_read', {'conv': conv, 'peer': friends[1], 'upto': 150});
    await _flush(t);
    expect(find.text('Đã xem bởi 2 người'), findsOneWidget);
    expect(find.text(sv.contacts.nameOf(friends[1])), findsOneWidget);
    await _done(t, sv);
  });

  testWidgets('opening a group chat loads the read marks the core kept (seen ticks survive a restart)', (t) async {
    setSize(t, const Size(500, 900));
    final sv = await makeServices(t);
    final conv = sv.chat.convs.values.firstWhere((c) => c.id.startsWith('g:') && !c.isCommunity).id;
    final f = _friend(sv);
    // a fresh start: nothing arrived live, but the core kept a member's mark
    expect(sv.chat.groupSeen(conv, 100), isFalse);
    _api(sv).groupReadMarks[conv] = {f: 150};
    final tick = sv.chat.groupReadTick.value;
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => ChatView(conv: conv))), child: const Text('open'))))));
    await settle(t);
    await t.tap(find.text('open'));
    await _flush(t);
    expect(find.byType(ChatView), findsOneWidget);
    expect(sv.chat.groupSeen(conv, 100), isTrue);
    expect(sv.chat.groupSeen(conv, 200), isFalse);
    expect(sv.chat.groupReads[conv], {f: 150});
    expect(sv.chat.groupReadTick.value, tick + 1);
    // kept marks never move a newer live one back; loading again with nothing new is quiet
    _api(sv).emitForTest('group_read', {'conv': conv, 'peer': f, 'upto': 300});
    await _flush(t);
    await t.runAsync(() => sv.chat.loadGroupReads(conv));
    expect(sv.chat.groupReads[conv]![f], 300);
    expect(sv.chat.groupReadTick.value, tick + 2);
    // not a group: no request
    await t.runAsync(() => sv.chat.loadGroupReads('d:$f'));
    expect(sv.chat.groupReads.containsKey('d:$f'), isFalse);
    await _done(t, sv);
  });

  // ------------------------------------------------------------ 5. remove one sticker
  testWidgets('long-press a sticker of my pack → "Remove sticker"', (t) async {
    setSize(t, const Size(500, 900));
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: SizedBox(height: 400, child: StickerPanel(onSend: (_) {})))));
    await _flush(t);
    expect(find.byKey(const ValueKey('sticker_st_beach')), findsOneWidget);
    await t.longPress(find.byKey(const ValueKey('sticker_st_beach')));
    await settle(t);
    await t.tap(find.text('Gỡ nhãn dán'));
    await _flush(t);
    final packs = await t.runAsync(() => sv.api.stickerPacks());
    final pack = packs!.firstWhere((p) => p.id == 'pk_vn');
    expect(pack.stickers.map((s) => s.hash), isNot(contains('st_beach')));
    expect(pack.stickers, hasLength(3), reason: 'only that one sticker');
    expect(find.byKey(const ValueKey('sticker_st_beach')), findsNothing);
    await _done(t, sv);
  });

  // ------------------------------------------------------------ 6 + 7. core settings switches
  testWidgets('Remote access: refuse all requests, help friends wake; the new password comes from the core', (t) async {
    setSize(t, const Size(600, 1600));
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: const Scaffold(body: SettingsSubPage(page: SettingsPage.remote))));
    await _flush(t);
    expect(find.text('Từ chối mọi yêu cầu điều khiển'), findsOneWidget);
    await t.tap(find.text('Từ chối mọi yêu cầu điều khiển'));
    await _flush(t);
    expect((await t.runAsync(() => sv.api.remoteStatus()))!.allowIncoming, isFalse);
    expect(sv.remote.status.allowIncoming, isFalse);
    // the core's value is read back
    await t.runAsync(() => sv.remote.load());
    expect(sv.remote.status.allowIncoming, isFalse);

    expect(find.text('Giúp bạn bè đánh thức máy'), findsOneWidget);
    await t.tap(find.text('Giúp bạn bè đánh thức máy'));
    await _flush(t);
    expect((await t.runAsync(() => sv.api.settingsGet()))!['wake_for_friends'], isFalse);
    await _done(t, sv);
  });

  testWidgets('Advanced › Network: pure P2P live, restart hint under the start-only switches', (t) async {
    setSize(t, const Size(600, 2400));
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: const Scaffold(body: SettingsSubPage(page: SettingsPage.advanced))));
    await _flush(t);
    expect(find.byKey(const ValueKey('restart_hint')), findsOneWidget);
    expect(find.text('Thay đổi sẽ áp dụng ở lần khởi động tiếp theo'), findsOneWidget);
    expect(t.widget<Slider>(find.byType(Slider)).onChanged, isNotNull);
    await t.tap(find.text('Chỉ kết nối trực tiếp'));
    await _flush(t);
    expect((await t.runAsync(() => sv.api.settingsGet()))!['p2p_only'], isTrue);
    expect(t.widget<Slider>(find.byType(Slider)).onChanged, isNull, reason: 'no bridge: the wait does not apply');
    // back off: the chosen bridge wait is pushed again
    sv.settings.update((s) => s.relayDelayMs = 5000);
    await _flush(t);
    await t.tap(find.text('Chỉ kết nối trực tiếp'));
    await _flush(t);
    final core = await t.runAsync(() => sv.api.settingsGet());
    expect(core!['p2p_only'], isFalse);
    expect(core['relay_delay_ms'], 5000);
    await _done(t, sv);
  });

  // ------------------------------------------------------------ 8. default timers
  testWidgets('the default auto-delete timer applies to new chats only and survives a restart', (t) async {
    final sv = await makeServices(t);
    final old = sv.chat.convs.keys.firstWhere((c) => c.startsWith('d:'));
    sv.settings.update((s) => s.defaultTtlMs = 3600000);
    _api(sv).emitForTest('conversation', {'id': 'd:${'N' * 52}', 'kind': 0, 'title': 'Mới', 'last_ts': 1, 'unread': 0});
    await _flush(t);
    expect(sv.chat.ttlByConv['d:${'N' * 52}'], 3600000);
    expect(sv.chat.ttlByConv[old], isNull, reason: 'existing chats keep theirs');
    expect(sv.settings.chatTtls['d:${'N' * 52}'], 3600000, reason: 'kept on this device');
    // the chat's own choice still wins and is kept too
    sv.chat.setTtl('d:${'N' * 52}', 0);
    expect(sv.settings.chatTtls.containsKey('d:${'N' * 52}'), isFalse);
    sv.chat.setTtl(old, 300000);
    expect(sv.settings.chatTtls[old], 300000);
    // a restart: the timers come back
    final sv2 = AppServices(api: MockLumoraApi(timers: false), settings: sv.settings, dataDir: '/tmp/lumora-test');
    expect(sv2.chat.ttlByConv[old], 300000);
    sv2.dispose();
    await _done(t, sv);
  });

  testWidgets('Privacy › Messages: pick the default timer and community retention', (t) async {
    setSize(t, const Size(600, 2400));
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: const Scaffold(body: SettingsSubPage(page: SettingsPage.privacy))));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('default_ttl')));
    await settle(t);
    await t.tap(find.text('1 giờ').last);
    await settle(t);
    expect(sv.settings.defaultTtlMs, 3600000);
    await t.tap(find.byKey(const ValueKey('community_retention')));
    await settle(t);
    await t.tap(find.text('Tự xoá sau 7 ngày').last);
    await settle(t);
    expect(sv.settings.communityRetention, '7d');
    await _done(t, sv);
  });

  testWidgets('community retention default: applied on create / join, also to channels that come later', (t) async {
    final sv = await makeServices(t);
    sv.settings.update((s) => s.communityRetention = '7d');
    final conv = await t.runAsync(() => sv.api.createCommunity('Nhóm học', [_friend(sv)]));
    await t.runAsync(() => sv.communityDefaults.adopt(conv!, channels: ['$conv#voice']));
    expect(await t.runAsync(() => sv.api.getRetention(conv!)), '7d');
    expect(await t.runAsync(() => sv.api.getRetention('$conv#voice')), '7d');
    // a channel that shows up after joining
    _api(sv).emitForTest('conversation', {'id': '$conv#news', 'kind': 1, 'title': 'news', 'last_ts': 1, 'unread': 0});
    await _flush(t);
    expect(await t.runAsync(() => sv.api.getRetention('$conv#news')), '7d');
    // a chat whose retention was already chosen keeps it
    await t.runAsync(() => sv.api.setRetention('$conv#old', '24h'));
    _api(sv).emitForTest('conversation', {'id': '$conv#old', 'kind': 1, 'title': 'old', 'last_ts': 1, 'unread': 0});
    await _flush(t);
    expect(await t.runAsync(() => sv.api.getRetention('$conv#old')), '24h');
    // "forever" is the plain default: nothing to set
    final cd = CommunityDefaults(sv.api, sv.settings..communityRetention = 'forever');
    await t.runAsync(() => cd.adopt('g:abc'));
    expect(await t.runAsync(() => sv.api.getRetention('g:abc')), 'forever');
    await _done(t, sv);
  });

  // ------------------------------------------------------------ 9. Bot Studio clear
  testWidgets('Bot Studio menu → "Clear chat" empties the conversation (core copy too)', (t) async {
    setSize(t, const Size(500, 900));
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: const BotFatherChat(embedded: true)));
    await _flush(t);
    await t.tap(find.text('/help'));
    await _flush(t);
    expect((await t.runAsync(() => sv.api.botfatherHistory()))!, isNotEmpty);
    await t.tap(find.byKey(const ValueKey('botfather_menu')));
    await settle(t);
    await t.tap(find.text('Xoá cuộc trò chuyện'));
    await settle(t);
    await t.tap(find.widgetWithText(FilledButton, 'Xoá'));
    await _flush(t);
    expect((await t.runAsync(() => sv.api.botfatherHistory()))!, isEmpty);
    expect(find.text('/help'), findsOneWidget, reason: 'only the chip is left, not my line');
    await _done(t, sv);
  });

  // ------------------------------------------------------------ 10. storage / remote_action events
  testWidgets('auto-clean (`storage`) is told and refreshes the storage numbers', (t) async {
    setSize(t, const Size(500, 900));
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SizedBox())));
    await settle(t);
    sv.net.storage = {'stale': true};
    _api(sv).emitForTest('storage', {'freed_bytes': 3 * 1024 * 1024, 'removed_files': 4, 'cache_bytes': 1});
    await _flush(t);
    expect(find.text('Đã tự dọn 4 tệp cũ, giải phóng 3,0 MB'), findsOneWidget);
    expect(sv.net.storage!.containsKey('stale'), isFalse, reason: 'reloaded from the core');
    await t.pump(const Duration(seconds: 5));
    await _done(t, sv);
  });

  testWidgets('remote_action on this computer: the result is shown (and kept in the bell)', (t) async {
    setSize(t, const Size(500, 900));
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SizedBox())));
    await settle(t);
    _api(sv).emitForTest('remote_action', {'session': 'ab', 'action': 'restart', 'ok': false, 'code': 'err.power_not_allowed', 'error': 'x'});
    await _flush(t);
    expect(find.textContaining('muốn khởi động lại máy này nhưng bạn chưa cho phép'), findsOneWidget);
    expect(sv.notices.items.first.title, contains('chưa cho phép'));
    await t.pump(const Duration(seconds: 5));
    _api(sv).emitForTest('remote_action', {'session': 'ab', 'action': 'lock', 'ok': true});
    await _flush(t);
    expect(find.text('Người đang điều khiển đã khoá máy này'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    await _done(t, sv);
  });

  testWidgets('remote_action_result at the controller: what happened on the other computer is told', (t) async {
    setSize(t, const Size(500, 900));
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SizedBox())));
    await settle(t);
    final bell = sv.notices.items.length;
    Future<void> check(Map<String, dynamic> ev, String text) async {
      _api(sv).emitForTest('remote_action_result', {'session': 'ab', 'peer': _friend(sv), ...ev});
      await _flush(t);
      expect(find.text(text), findsOneWidget, reason: '$ev');
      await t.pump(const Duration(seconds: 5));
      await t.pump(const Duration(milliseconds: 500));
    }

    await check({'action': 'lock', 'ok': true}, 'Đã khoá máy');
    await check({'action': 'restart', 'ok': true}, 'Đang khởi động lại');
    await check({'action': 'logout', 'ok': true}, 'Đang đăng xuất');
    await check({'action': 'restart', 'ok': false, 'code': 'err.power_not_allowed'}, 'Máy kia không cho phép (bật trong Cài đặt)');
    await check({'action': 'logout', 'ok': false, 'code': 'err.power_failed'}, 'Không thực hiện được');
    // an unknown action is ignored; nothing goes to the bell (it was my own request)
    _api(sv).emitForTest('remote_action_result', {'session': 'ab', 'action': 'format_disk', 'ok': true});
    await _flush(t);
    expect(find.text('Đã khoá máy'), findsNothing);
    expect(sv.notices.items.length, bell);
    await _done(t, sv);
  });

  testWidgets('remote_action_result in English', (t) async {
    setSize(t, const Size(500, 900));
    final sv = await makeServices(t);
    sv.settings.locale = 'en';
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SizedBox())));
    await settle(t);
    _api(sv).emitForTest('remote_action_result', {'session': 'ab', 'action': 'restart', 'ok': false, 'code': 'err.power_not_allowed'});
    await _flush(t);
    expect(find.text("The other computer doesn't allow this (turn it on in its Settings)"), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    await t.pump(const Duration(milliseconds: 500));
    await _done(t, sv);
  });

  // ------------------------------------------------------------ 11. missed (busy) call line
  testWidgets('sys.call_missed_busy shows the friend\'s current name', (t) async {
    final sv = await makeServices(t);
    final friend = sv.contacts.friends.first;
    final m = Message.fromJson({
      'id': 'm1', 'conv': 'd:${friend.peer}', 'author': sv.session.me!.peer, 'ts': 1, 'kind': 'system',
      'body': jsonEncode({'code': 'sys.call_missed_busy', 'args': {'name': 'Tên cũ'}, 'text': 'Missed call from Tên cũ (you were in another call)'}),
    });
    String? text;
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Builder(builder: (c) {
      text = systemText(c, m);
      return const SizedBox();
    })));
    await settle(t, frames: 2);
    expect(text, 'Cuộc gọi nhỡ từ ${friend.displayName} (bạn đang trong cuộc gọi khác)');
    await _done(t, sv);
  });

  // ------------------------------------------------------------ 12. new remote password
  testWidgets('Remote screen "New password" asks the core (remote_new_password), not remote_set', (t) async {
    setSize(t, const Size(500, 1200));
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: const Scaffold(body: RemoteHomeScreen())));
    await settle(t);
    final before = sv.remote.status.password;
    await t.tap(find.byKey(const ValueKey('new_remote_password')));
    await _flush(t);
    final now = sv.remote.status.password;
    expect(now, isNot(before));
    expect(now, hasLength(8));
    expect((await t.runAsync(() => sv.api.remoteStatus()))!.password, now, reason: 'the core has the same one');
    expect(_api(sv).fixedRemotePassword, isNull, reason: 'the fixed unattended password is untouched');
    expect(find.text('Đã tạo mật khẩu mới'), findsOneWidget);
    await t.pump(const Duration(seconds: 3));
    await _done(t, sv);
  });
}

/// Answers `story_viewers` with a fixed payload.
class _ViewersApi extends MockLumoraApi {
  _ViewersApi(this.payload) : super(timers: false);
  final Object payload;
  @override
  Future<dynamic> request(String cmd, [Map<String, dynamic> args = const {}]) async => cmd == 'story_viewers' ? payload : super.request(cmd, args);
}

/// `seen_by` answers whatever the test put in [seen].
class _SeenApi extends MockLumoraApi {
  _SeenApi() : super(timers: false);
  List<String> seen = const [];
  @override
  Future<dynamic> request(String cmd, [Map<String, dynamic> args = const {}]) async => cmd == 'seen_by' ? [for (final p in seen) {'peer': p}] : super.request(cmd, args);
}

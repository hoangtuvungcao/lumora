// Community 2.0 on the mock core: roles (create / edit / delete), assigning a
// role colours the member's name, channel settings (rename, topic, category,
// private), composer states (announcement-only, timeout) and permission-gated
// settings sections.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/community.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/chats/composer.dart';
import 'package:lumora/ui/groups/community/community_channels.dart';
import 'package:lumora/ui/groups/community/community_settings.dart';
import 'package:lumora/ui/groups/server_view.dart';

import 'helpers.dart';

Future<void> _flush(WidgetTester t, {int frames = 6}) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await settle(t, frames: frames);
}

/// A community I own with two friends in it; returns its gid.
Future<String> _community(WidgetTester t, AppServices sv, {String name = 'Cộng đồng Vai trò'}) async {
  late String gid;
  await t.runAsync(() async {
    final friends = sv.contacts.byPeer.values.where((c) => c.status == ContactStatus.friend).take(2).map((c) => c.peer).toList();
    final g = await sv.api.request('create_group', {'name': name, 'members': friends, 'kind': 1}) as Map;
    gid = g['gid'] as String;
    await sv.spaces.load();
  });
  return gid;
}

Future<void> _pump(WidgetTester t, AppServices sv, Widget home) async {
  await t.pumpWidget(LumoraApp(services: sv, home: home, overlays: false));
  await _flush(t);
}

Future<GroupInfo> _info(WidgetTester t, AppServices sv, String gid) async {
  late GroupInfo g;
  await t.runAsync(() async => g = await sv.api.groupInfo(gid));
  return g;
}

Future<void> _done(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 100));
  sv.dispose();
  resetSize(t);
}

void main() {
  setUpAll(loadFonts);

  testWidgets('roles: create, edit, delete from community settings', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    final gid = await _community(t, sv);
    await _pump(t, sv, Builder(builder: (c) => Scaffold(body: Center(child: TextButton(onPressed: () => showCommunitySettings(c, gid, open: CommunitySection.roles), child: const Text('open'))))));
    await t.tap(find.text('open'));
    await _flush(t);
    expect(find.byKey(const ValueKey('cm_tab_roles')), findsOneWidget);
    expect(find.byKey(const ValueKey('cm_tab_channels')), findsOneWidget);
    expect(find.byKey(const ValueKey('role_row_everyone')), findsOneWidget);

    // create
    await t.tap(find.byKey(const ValueKey('cm_new_role')));
    await _flush(t);
    await t.enterText(find.byKey(const ValueKey('cm_role_name')), 'Điều phối');
    await t.tap(find.byKey(const ValueKey('cm_color_#EC4899')));
    FocusManager.instance.primaryFocus?.unfocus();
    await t.pump();
    await t.ensureVisible(find.byKey(const ValueKey('cm_perm_kick')));
    await settle(t, frames: 3);
    await t.tap(find.descendant(of: find.byKey(const ValueKey('cm_perm_kick')), matching: find.byType(Switch)));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('cm_role_save')));
    await _flush(t);
    await t.pump(const Duration(seconds: 3)); // the "saved" toast goes
    var g = await _info(t, sv, gid);
    final role = g.roles.firstWhere((r) => r.name == 'Điều phối');
    expect(role.color, '#EC4899');
    expect(role.perms, containsAll(['view_channel', 'send_messages', 'connect_voice', 'kick']));
    expect(role.builtin, isFalse);
    expect(find.byKey(ValueKey('role_row_${role.id}')), findsOneWidget);

    // edit: rename + drop a permission
    await t.tap(find.byKey(ValueKey('role_row_${role.id}')));
    await _flush(t);
    await t.enterText(find.byKey(const ValueKey('cm_role_name')), 'Điều phối viên');
    await t.tap(find.byKey(const ValueKey('cm_role_save')));
    await _flush(t);
    await t.pump(const Duration(seconds: 3)); // the "saved" toast goes
    g = await _info(t, sv, gid);
    expect(g.roleById(role.id)!.name, 'Điều phối viên');
    expect(find.text('Điều phối viên'), findsOneWidget);

    // @everyone's permissions are editable
    await t.tap(find.byKey(const ValueKey('role_row_everyone')));
    await _flush(t);
    expect(find.byKey(const ValueKey('cm_role_name')), findsNothing);
    await t.tap(find.descendant(of: find.byKey(const ValueKey('cm_perm_send_messages')), matching: find.byType(Switch)));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('cm_role_save')));
    await _flush(t);
    await t.pump(const Duration(seconds: 3)); // the "saved" toast goes
    g = await _info(t, sv, gid);
    expect(g.roleById('everyone')!.perms, isNot(contains('send_messages')));

    // delete
    await t.tap(find.byKey(ValueKey('role_row_${role.id}')));
    await _flush(t);
    await t.scrollUntilVisible(find.byKey(const ValueKey('cm_role_delete')), 300,
        scrollable: find.descendant(of: find.byType(RoleEditorPage), matching: find.byType(Scrollable)).first);
    await settle(t, frames: 3);
    await t.tap(find.byKey(const ValueKey('cm_role_delete')));
    await settle(t, frames: 3);
    await t.tap(find.widgetWithText(FilledButton, 'Xoá'));
    await _flush(t);
    g = await _info(t, sv, gid);
    expect(g.roleById(role.id), isNull);
    expect(find.byKey(ValueKey('role_row_${role.id}')), findsNothing);

    // built-in roles can't be deleted
    await t.runAsync(() async {
      await expectLater(sv.api.groupRoleDelete(gid, 'admin'), throwsA(isA<ApiException>()));
      await expectLater(sv.api.groupRoleDelete(gid, 'everyone'), throwsA(isA<ApiException>()));
    });
    await _done(t, sv);
  });

  testWidgets('roles: reorder by position, assign a role → the name takes its colour', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    final gid = await _community(t, sv);
    late String a, b;
    await t.runAsync(() async {
      a = await sv.api.groupRoleSet(gid, name: 'Hồng', color: '#EC4899', perms: const []);
      b = await sv.api.groupRoleSet(gid, name: 'Xanh', color: '#0EA5E9', perms: const []);
    });
    var g = await _info(t, sv, gid);
    // newest lands just above @everyone; admin always on top
    expect(g.roles.map((r) => r.id).toList(), ['admin', a, b, 'everyone']);
    await t.runAsync(() => sv.api.groupRoleSet(gid, id: b, name: 'Xanh', color: '#0EA5E9', perms: const [], position: 2));
    g = await _info(t, sv, gid);
    expect(g.roles.map((r) => r.id).toList(), ['admin', b, a, 'everyone']);

    final peer = g.members.firstWhere((m) => m.role == 'member').peer;
    await _pump(t, sv, Builder(builder: (c) => Scaffold(body: Center(child: TextButton(onPressed: () => showCommunitySettings(c, gid, open: CommunitySection.members), child: const Text('open'))))));
    await t.tap(find.text('open'));
    await _flush(t);
    expect(find.byKey(ValueKey('cm_member_row_$peer')), findsOneWidget);
    await t.tap(find.byKey(ValueKey('cm_member_more_$peer')));
    await settle(t, frames: 3);
    await t.tap(find.text('Gán vai trò').last);
    await settle(t, frames: 4);
    await t.tap(find.byKey(ValueKey('cm_pick_role_$a')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('cm_pick_save')));
    await _flush(t);
    g = await _info(t, sv, gid);
    expect(g.member(peer)!.roles, [a]);
    Text name() => t.widget<Text>(find.byKey(ValueKey('cm_member_name_$peer')));
    expect(name().style?.color, const Color(0xFFEC4899));
    expect(find.descendant(of: find.byKey(ValueKey('cm_member_row_$peer')), matching: find.byKey(ValueKey('role_chip_$a'))), findsOneWidget);

    // a second, higher role wins the colour
    await t.runAsync(() => sv.api.groupMemberRoles(gid, peer, [a, b]));
    await t.runAsync(() => CommunityStore.of(sv.api).load(gid));
    await _flush(t);
    expect(name().style?.color, const Color(0xFF0EA5E9));

    // timeout from the menu (5 minutes)
    await t.tap(find.byKey(ValueKey('cm_member_more_$peer')));
    await settle(t, frames: 3);
    await t.tap(find.text('Tạm cấm chat').last);
    await settle(t, frames: 3);
    await t.tap(find.byKey(const ValueKey('cm_timeout_5')));
    await _flush(t);
    g = await _info(t, sv, gid);
    expect(g.member(peer)!.timedOut(), isTrue);
    expect(find.byKey(ValueKey('cm_timed_out_$peer')), findsOneWidget);
    await _done(t, sv);
  });

  testWidgets('channels: rename, topic, category, private + list and header', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    final gid = await _community(t, sv);
    late String mod;
    await t.runAsync(() async => mod = await sv.api.groupRoleSet(gid, name: 'Mod', color: '#22C55E', perms: const []));
    await _pump(t, sv, Builder(builder: (c) => Scaffold(body: Center(child: TextButton(onPressed: () => openChannelEditor(c, gid, 'chung'), child: const Text('open'))))));
    await t.tap(find.text('open'));
    await _flush(t);
    await t.enterText(find.byKey(const ValueKey('cm_channel_name')), 'Tổng hợp');
    await t.enterText(find.byKey(const ValueKey('cm_channel_topic')), 'Mọi chủ đề ở đây');
    await t.enterText(find.byKey(const ValueKey('cm_channel_category')), 'THẢO LUẬN');
    await t.tap(find.descendant(of: find.byKey(const ValueKey('cm_channel_private')), matching: find.byType(Switch)));
    await settle(t, frames: 3);
    FocusManager.instance.primaryFocus?.unfocus();
    await t.pump();
    await t.ensureVisible(find.byKey(ValueKey('cm_allow_$mod')));
    await settle(t, frames: 3);
    await t.tap(find.byKey(ValueKey('cm_allow_$mod')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('cm_channel_save')));
    await _flush(t);
    final g = await _info(t, sv, gid);
    final ch = g.channels.firstWhere((c) => !c.voice);
    expect(ch.name, 'tổng-hợp');
    expect(ch.topic, 'Mọi chủ đề ở đây');
    expect(ch.category, 'THẢO LUẬN');
    expect(ch.private, isTrue);
    expect(ch.allowRoles, [mod]);
    expect(ch.conv, 'g:$gid', reason: 'renaming keeps the conversation');

    // the channel list: category header (collapsible), lock icon
    final sp = sv.spaces.byId(gid)!;
    expect(sp.channels.firstWhere((c) => !c.voice).topic, 'Mọi chủ đề ở đây');
    await _pump(t, sv, Scaffold(body: Builder(builder: (c) => ChannelList(space: sv.spaces.byId(gid)!, onOpen: (_) {}))));
    expect(find.text('THẢO LUẬN'), findsOneWidget);
    expect(find.byKey(ValueKey('private_${ch.conv}')), findsOneWidget);
    expect(find.text('tổng-hợp'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('category_THẢO LUẬN')));
    await settle(t, frames: 3);
    expect(find.text('tổng-hợp'), findsNothing);
    await t.tap(find.byKey(const ValueKey('category_THẢO LUẬN')));
    await settle(t, frames: 3);
    expect(find.text('tổng-hợp'), findsOneWidget);

    // long-press → edit / delete (I manage channels)
    await t.longPress(find.text('tổng-hợp'));
    await _flush(t);
    expect(find.byKey(const ValueKey('channel_menu_edit')), findsOneWidget);
    expect(find.byKey(const ValueKey('channel_menu_delete')), findsOneWidget);
    await t.tapAt(const Offset(10, 10));
    await settle(t, frames: 3);

    // the chat header shows the topic
    await _pump(t, sv, ChatView(conv: ch.conv, channelName: ch.name, spaceName: sp.name));
    expect(find.byKey(const ValueKey('channel_topic')), findsOneWidget);
    expect(find.text('Mọi chủ đề ở đây'), findsOneWidget);

    // new channel with a category, then reorder within it
    await t.runAsync(() async {
      await sv.api.groupChannel(gid, 'thứ-hai', category: 'THẢO LUẬN', topic: 'x');
      await sv.api.groupChannelUpdate(gid, 'thứ-hai', position: 0);
      await sv.spaces.load();
    });
    final order = channelSections(sv.spaces.byId(gid)!.channels);
    expect(order.first.$1, '');
    final talk = order.firstWhere((e) => e.$1 == 'THẢO LUẬN').$2.map((c) => c.name).toList();
    expect(talk, ['thứ-hai', 'tổng-hợp']);
    await _done(t, sv);
  });

  testWidgets('composer: announcement-only channel and timeout', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    final sp = sv.spaces.spaces.firstWhere((x) => x.name == 'Hội Lập Trình Việt');
    final announce = sp.channels.firstWhere((c) => c.name == 'thông-báo');
    final general = sp.channels.firstWhere((c) => c.name == 'chung');
    expect(announce.announce, isTrue);
    // a private channel for moderators is hidden from this member
    expect(sp.channels.any((c) => c.name == 'ban-điều-hành'), isFalse);

    await _pump(t, sv, ChatView(conv: announce.conv, channelName: announce.name, spaceName: sp.name));
    expect(find.byKey(const ValueKey('cm_gate_announce')), findsOneWidget);
    expect(find.text('Chỉ quản trị viên được đăng'), findsOneWidget);
    expect(find.byType(Composer), findsNothing);
    // the core refuses it too
    await t.runAsync(() async => expectLater(sv.api.request('send_text', {'conv': announce.conv, 'text': 'x'}), throwsA(isA<ApiException>())));

    await _pump(t, sv, ChatView(key: const ValueKey('general'), conv: general.conv, channelName: general.name, spaceName: sp.name));
    expect(find.byType(Composer), findsOneWidget);
    expect(find.byKey(const ValueKey('cm_gate_announce')), findsNothing);

    final until = DateTime.now().add(const Duration(hours: 1));
    (sv.api as MockLumoraApi).cmSetMyTimeoutForTest(sp.id, until.millisecondsSinceEpoch);
    await t.runAsync(() => CommunityStore.of(sv.api).load(sp.id));
    await _flush(t);
    final hm = '${until.hour.toString().padLeft(2, '0')}:${until.minute.toString().padLeft(2, '0')}';
    expect(find.byKey(const ValueKey('cm_gate_timeout')), findsOneWidget);
    expect(find.text('Bạn bị tạm cấm chat đến $hm'), findsOneWidget);
    expect(find.byType(Composer), findsNothing);

    (sv.api as MockLumoraApi).cmSetMyTimeoutForTest(sp.id, 0);
    await t.runAsync(() => CommunityStore.of(sv.api).load(sp.id));
    await _flush(t);
    expect(find.byType(Composer), findsOneWidget);
    await _done(t, sv);
  });

  testWidgets('permissions: a plain member sees no admin sections or channel menu', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    final sp = sv.spaces.spaces.firstWhere((x) => x.name == 'Hội Lập Trình Việt');
    await _pump(t, sv, Scaffold(body: ChannelList(space: sp, onOpen: (_) {})));
    await t.tap(find.byKey(const ValueKey('space_settings')));
    await _flush(t);
    expect(find.text('Cài đặt cộng đồng'), findsOneWidget);
    for (final tab in ['roles', 'members', 'channels', 'bots']) {
      expect(find.byKey(ValueKey('cm_tab_$tab')), findsNothing, reason: tab);
    }
    expect(find.text('Đổi tên nhóm'), findsNothing);
    // (pageBack() looks for the English "Back" tooltip; the app speaks Vietnamese)
    await t.tap(find.byType(BackButton));
    await _flush(t);
    // no edit menu on a channel
    await t.longPress(find.text('chung'));
    await _flush(t);
    expect(find.byKey(const ValueKey('channel_menu_edit')), findsNothing);

    // a role with manage_channels opens the Channels section only
    final mock = sv.api as MockLumoraApi;
    await t.runAsync(() async {
      final g = await sv.api.groupInfo(sp.id);
      expect(g.myPerms, isNot(contains('manage_roles')));
    });
    mock.setGroupRoleForTest(sp.id, 'owner');
    late String r;
    await t.runAsync(() async => r = await sv.api.groupRoleSet(sp.id, name: 'Kênh', color: '#0EA5E9', perms: const ['view_channel', 'send_messages', 'manage_channels']));
    mock.setGroupRoleForTest(sp.id, 'member');
    mock.cmSetMyRolesForTest(sp.id, [r]);
    await t.runAsync(() => CommunityStore.of(sv.api).load(sp.id));
    await t.tap(find.byKey(const ValueKey('space_settings')));
    await _flush(t);
    expect(find.byKey(const ValueKey('cm_tab_channels')), findsOneWidget);
    expect(find.byKey(const ValueKey('cm_tab_roles')), findsNothing);
    expect(find.byKey(const ValueKey('cm_tab_members')), findsNothing);
    await _done(t, sv);
  });
}

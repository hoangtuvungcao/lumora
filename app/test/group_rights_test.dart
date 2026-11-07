// Plain groups on the role engine: admin rights through an
// `admin:<peer>` role, member permissions (@everyone), timeouts, and the UI
// following my_perms (attach, pin, invite, change group info).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/community.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/chats/composer.dart';
import 'package:lumora/ui/groups/group_info.dart';

import 'helpers.dart';

Future<void> _flush(WidgetTester t, {int frames = 6}) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await settle(t, frames: frames);
}

String _gid(AppServices sv, String prefix) =>
    sv.chat.convs.values.firstWhere((c) => c.id.startsWith('g:') && !c.isCommunity && c.title.startsWith(prefix)).id.substring(2);

Future<GroupInfo> _info(WidgetTester t, AppServices sv, String gid) async {
  late GroupInfo g;
  await t.runAsync(() async => g = await sv.api.groupInfo(gid));
  return g;
}

Future<void> _refresh(WidgetTester t, AppServices sv, String gid) async {
  await t.runAsync(() => CommunityStore.of(sv.api).load(gid));
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

  testWidgets('admin rights: promote with chosen rights, edit, revoke; legacy admins keep all', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    final gid = _gid(sv, 'Dự án');
    var g = await _info(t, sv, gid);
    expect(g.myRole, 'owner');
    final legacy = g.members.firstWhere((m) => m.role == 'admin');
    expect(g.adminRightsOf(legacy.peer), containsAll([Perm.manageCommunity, Perm.ban, Perm.pin, Perm.invite]), reason: 'admins made before rights keep everything');
    final peer = g.members.firstWhere((m) => m.role == 'member').peer;

    await t.pumpWidget(LumoraApp(services: sv, home: Scaffold(body: GroupInfoView(gid: gid)), overlays: false));
    await _flush(t);
    Future<void> openMenu(String p) async {
      final more = find.byKey(ValueKey('group_member_more_$p'));
      await t.scrollUntilVisible(more, 200, scrollable: find.descendant(of: find.byType(GroupInfoView), matching: find.byType(Scrollable)).first);
      await settle(t, frames: 2);
      await t.tap(more);
      await settle(t, frames: 3);
    }

    // promote: the rights sheet, "pin" switched off
    await openMenu(peer);
    await t.tap(find.text('Đặt làm quản trị viên').last);
    await settle(t, frames: 4);
    expect(find.byKey(const ValueKey('gr_right_manage_roles')), findsOneWidget);
    await t.tap(find.descendant(of: find.byKey(const ValueKey('gr_right_pin')), matching: find.byType(Switch)));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('gr_rights_save')));
    await _flush(t);
    g = await _info(t, sv, gid);
    final role = g.roleById(Perm.adminRoleId(peer))!;
    expect(g.member(peer)!.role, 'admin');
    expect(g.member(peer)!.roles, contains(Perm.adminRoleId(peer)));
    expect(role.perms, containsAll([Perm.manageCommunity, Perm.manageMessages, Perm.ban, Perm.kick, Perm.invite, Perm.timeout]));
    expect(role.perms, isNot(contains(Perm.pin)));
    expect(role.perms, isNot(contains(Perm.manageRoles)));
    expect(g.adminRightsOf(peer), isNot(contains(Perm.pin)));
    // the rights role never shows as a role
    expect(g.rolesOf(g.member(peer)!).any((r) => r.isAdminRights), isFalse);

    // edit: give "add new admins"
    await t.pump(const Duration(seconds: 3));
    await openMenu(peer);
    await t.tap(find.text('Quyền quản trị viên').last);
    await settle(t, frames: 4);
    await t.tap(find.descendant(of: find.byKey(const ValueKey('gr_right_manage_roles')), matching: find.byType(Switch)));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('gr_rights_save')));
    await _flush(t);
    g = await _info(t, sv, gid);
    expect(g.roleById(Perm.adminRoleId(peer))!.perms, contains(Perm.manageRoles));

    // revoke: back to member, the rights role goes
    await t.pump(const Duration(seconds: 3));
    await openMenu(peer);
    await t.tap(find.text('Gỡ quyền quản trị').last);
    await _flush(t);
    g = await _info(t, sv, gid);
    expect(g.member(peer)!.role, 'member');
    expect(g.roleById(Perm.adminRoleId(peer)), isNull);

    // timeout from the member row
    await openMenu(peer);
    await t.tap(find.text('Tạm cấm chat').last);
    await settle(t, frames: 3);
    await t.tap(find.byKey(const ValueKey('cm_timeout_60')));
    await _flush(t);
    g = await _info(t, sv, gid);
    expect(g.member(peer)!.timedOut(), isTrue);
    await _done(t, sv);
  });

  testWidgets('member permissions: switches edit @everyone; the UI follows my_perms', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    final mock = sv.api as MockLumoraApi;
    final gid = _gid(sv, 'Gia đình'); // I'm a plain member here
    var g = await _info(t, sv, gid);
    expect(g.myRole, 'member');
    expect(g.myPerms, containsAll(Perm.everyoneGroupDefault));
    expect(g.myPerms, isNot(contains(Perm.manageCommunity)), reason: 'changing group info is owner/admins by default');
    // the core refuses it too
    await t.runAsync(() async => expectLater(sv.api.groupRename(gid, 'x'), throwsA(isA<ApiException>())));

    // as a member: no rename / description / cover / avatar actions, and no invite
    // links either (they are the admins' by default)
    expect(g.myPerms, isNot(contains(Perm.invite)));
    await t.pumpWidget(LumoraApp(services: sv, home: Scaffold(body: GroupInfoView(gid: gid)), overlays: false));
    await _flush(t);
    expect(find.text('Đổi tên nhóm'), findsNothing);
    expect(find.text('Sửa mô tả'), findsNothing);
    expect(find.byKey(const ValueKey('cover_change')), findsNothing);
    expect(find.byKey(const ValueKey('group_invite_link')), findsNothing);
    expect(find.byKey(const ValueKey('gr_member_perms')), findsNothing);

    // the owner switches media and pin off and "change group info" on (invite is
    // already off by default)
    mock.setGroupRoleForTest(gid, 'owner');
    await t.pumpWidget(LumoraApp(services: sv, home: Scaffold(body: GroupInfoView(key: const ValueKey('owner'), gid: gid)), overlays: false));
    await _flush(t);
    final tile = find.byKey(const ValueKey('gr_member_perms'));
    await t.scrollUntilVisible(tile, 200, scrollable: find.descendant(of: find.byType(GroupInfoView), matching: find.byType(Scrollable)).first);
    await settle(t, frames: 2);
    await t.tap(tile);
    await settle(t, frames: 4);
    for (final p in [Perm.sendMedia, Perm.pin, Perm.manageCommunity]) {
      await t.tap(find.descendant(of: find.byKey(ValueKey('gr_member_$p')), matching: find.byType(Switch)));
      await t.pump();
    }
    await t.tap(find.byKey(const ValueKey('gr_rights_save')));
    await _flush(t);
    mock.setGroupRoleForTest(gid, 'member');
    g = await _info(t, sv, gid);
    expect(g.roleById('everyone')!.perms, containsAll([Perm.sendMessages, Perm.manageCommunity]));
    expect(g.myPerms, isNot(contains(Perm.sendMedia)));
    expect(g.myPerms, isNot(contains(Perm.pin)));
    expect(g.myPerms, isNot(contains(Perm.invite)));
    expect(g.myPerms, contains(Perm.manageCommunity));

    // as a member again: info follows
    await t.pumpWidget(LumoraApp(services: sv, home: Scaffold(body: GroupInfoView(key: const ValueKey('member2'), gid: gid)), overlays: false));
    await _flush(t);
    expect(find.text('Đổi tên nhóm'), findsOneWidget);
    expect(find.byKey(const ValueKey('cover_change')), findsOneWidget);
    expect(find.byKey(const ValueKey('group_invite_link')), findsNothing);
    expect(find.byKey(const ValueKey('group_add_members')), findsNothing);

    // the chat: no attach button, no "pin" in the message menu
    await _refresh(t, sv, gid);
    await t.pumpWidget(LumoraApp(services: sv, home: ChatView(conv: 'g:$gid'), overlays: false));
    await _flush(t);
    expect(find.byType(Composer), findsOneWidget);
    expect(find.byTooltip('Đính kèm tệp'), findsNothing);
    await t.longPress(find.text('Ừ, mua 2 hộp nhé'));
    await settle(t, frames: 4);
    expect(find.text('Trả lời'), findsWidgets);
    expect(find.text('Ghim tin nhắn'), findsNothing);
    await t.tapAt(const Offset(10, 10));
    await settle(t, frames: 4);
    await t.runAsync(() async => expectLater(sv.api.request('send_file', {'conv': 'g:$gid', 'path': '/tmp/a.jpg'}), throwsA(isA<ApiException>())));

    // timed out in a plain group: the composer gives way
    mock.cmSetMyTimeoutForTest(gid, DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch);
    await _refresh(t, sv, gid);
    expect(find.byKey(const ValueKey('cm_gate_timeout')), findsOneWidget);
    expect(find.byType(Composer), findsNothing);
    await _done(t, sv);
  });

  testWidgets('owner: attach and pin stay', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    final gid = _gid(sv, 'Dự án');
    await _refresh(t, sv, gid);
    await t.pumpWidget(LumoraApp(services: sv, home: ChatView(conv: 'g:$gid'), overlays: false));
    await _flush(t);
    expect(find.byTooltip('Đính kèm tệp'), findsOneWidget);
    await _done(t, sv);
  });
}

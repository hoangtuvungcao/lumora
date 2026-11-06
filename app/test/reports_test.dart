// "Báo cáo / Report" (no server): group messages / members go to the group's
// admins, a whole group is left and blocked, a 1-1 chat blocks the person —
// and everything follows the account to its other devices (`settings`,
// `group_report_handled`).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/chats/chat_info.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/groups/group_info.dart';
import 'package:lumora/ui/settings/blocked_screen.dart';
import 'package:lumora/ui/shell/notifications.dart';

import 'helpers.dart';

Future<void> _done(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 100));
  sv.dispose();
  resetSize(t);
}

Future<void> _flush(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await settle(t);
}

MockLumoraApi _api(AppServices sv) => sv.api as MockLumoraApi;

String _groupConv(AppServices sv, String prefix) => sv.chat.convs.values.firstWhere((c) => c.title.startsWith(prefix)).id;

Future<Message> _msg(WidgetTester t, AppServices sv, String conv, String text) async {
  final list = await t.runAsync(() => sv.api.messages(conv));
  return list!.firstWhere((m) => m.body == text);
}

List<Notice> _reportNotices(AppServices sv) => sv.notices.items.where((n) => n.kind == NoticeKind.report).toList();

void main() {
  setUpAll(loadFonts);

  testWidgets('report a group message: to the admins, with a reason; "hide" hides the member', (t) async {
    final sv = await makeServices(t);
    final conv = _groupConv(sv, 'Gia đình');
    setSize(t, const Size(420, 1000)); // phone: long-press opens the action sheet
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: ChatView(conv: conv, embedded: true))));
    await settle(t);
    final target = await _msg(t, sv, conv, 'Ừ, mua 2 hộp nhé');
    await t.longPress(find.text('Ừ, mua 2 hộp nhé'));
    await settle(t);
    await t.ensureVisible(find.text('Báo cáo'));
    await settle(t);
    await t.tap(find.text('Báo cáo'));
    await settle(t);
    expect(find.text('Báo cáo tin nhắn'), findsOneWidget);
    expect(find.textContaining('trưởng nhóm và quản trị viên'), findsOneWidget);
    // no reason yet: nothing to send
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Gửi báo cáo')).onPressed, isNull);
    await t.tap(find.text('Quấy rối hoặc xúc phạm'));
    await t.enterText(find.byType(TextField).last, 'nói tục');
    await t.tap(find.textContaining('Ẩn tin nhắn của'));
    await settle(t);
    await t.tap(find.text('Gửi báo cáo'));
    await _flush(t);
    final sent = _api(sv).sentReports.single;
    expect(sent['gid'], conv.substring(2));
    expect(sent['msg_id'], target.id);
    expect(sent['peer'], target.author);
    expect(sent['reason'], 'harassment');
    expect(sent['note'], 'nói tục');
    expect(sent['hide'], isTrue);
    expect(find.text('Đã gửi báo cáo cho quản trị viên nhóm'), findsOneWidget);
    expect(sv.moderation.isHidden(target.author), isTrue);
    expect(find.text('Ừ, mua 2 hộp nhé'), findsNothing, reason: 'the hidden member\'s messages stay out of the chat');
    // shown again from Settings › Privacy
    await t.runAsync(() => sv.moderation.setHidden(target.author, false));
    await settle(t);
    expect(find.text('Ừ, mua 2 hộp nhé'), findsOneWidget);
    await _done(t, sv);
  });

  testWidgets('"hide this member" chosen on my other device applies here at once', (t) async {
    final sv = await makeServices(t);
    final conv = _groupConv(sv, 'Gia đình');
    final m = await _msg(t, sv, conv, 'Ừ, mua 2 hộp nhé');
    setSize(t, const Size(900, 1000));
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: ChatView(conv: conv, embedded: true))));
    await settle(t);
    expect(find.text('Ừ, mua 2 hộp nhé'), findsOneWidget);
    _api(sv).memberHiddenElsewhere(m.author);
    await _flush(t);
    expect(find.text('Ừ, mua 2 hộp nhé'), findsNothing);
    await _done(t, sv);
  });

  testWidgets('report a member from group info', (t) async {
    final sv = await makeServices(t);
    final conv = _groupConv(sv, 'Gia đình');
    final gid = conv.substring(2);
    setSize(t, const Size(500, 1600));
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: GroupInfoView(gid: gid, embedded: true))));
    await settle(t);
    final info = await t.runAsync(() => sv.api.groupInfo(gid));
    final member = info!.members.firstWhere((m) => m.role == 'member' && m.peer != sv.session.me!.peer);
    final row = find.ancestor(of: find.text(sv.contacts.nameOf(member.peer)), matching: find.byType(ListTile));
    await t.scrollUntilVisible(row, 300, scrollable: find.byType(Scrollable).first);
    await t.tap(find.descendant(of: row, matching: find.byType(PopupMenuButton<String>)));
    await settle(t);
    await t.tap(find.text('Báo cáo thành viên'));
    await settle(t);
    await t.tap(find.text('Tin rác hoặc lừa đảo'));
    await settle(t);
    await t.tap(find.text('Gửi báo cáo'));
    await _flush(t);
    final sent = _api(sv).sentReports.single;
    expect((sent['peer'], sent['reason'], sent['msg_id']), (member.peer, 'spam', null));
    expect(sv.moderation.isHidden(member.peer), isFalse);
    await _done(t, sv);
  });

  testWidgets('admin: a report lands in the bell and its actions handle it', (t) async {
    final sv = await makeServices(t);
    final conv = _groupConv(sv, 'Dự án Lumora');
    final gid = conv.substring(2);
    final m = await _msg(t, sv, conv, 'Để mình thử thêm trên điện thoại nữa');
    final id = _api(sv).simulateGroupReport(gid, msgId: m.id, reason: 'adult', note: 'xem giúp');
    await _flush(t);
    expect(_reportNotices(sv).single.ref, id);
    setSize(t, const Size(900, 900));
    await t.pumpWidget(LumoraApp(
      services: sv,
      overlays: false,
      home: Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => showNotificationCentre(c), child: const Text('bell')))),
    ));
    await settle(t);
    await t.tap(find.text('bell'));
    await settle(t);
    expect(find.text('Báo cáo mới trong Dự án Lumora 🚀'), findsOneWidget);
    await t.tap(find.text('Báo cáo mới trong Dự án Lumora 🚀'));
    await settle(t);
    expect(find.text('Báo cáo cần xử lý'), findsOneWidget);
    expect(find.text('Nội dung người lớn hoặc bạo lực'), findsOneWidget);
    expect(find.text('xem giúp'), findsOneWidget);
    expect(find.text('“Để mình thử thêm trên điện thoại nữa”'), findsOneWidget);
    await t.tap(find.text('Xoá tin nhắn với mọi người'));
    await _flush(t);
    final after = await t.runAsync(() => sv.api.messages(conv));
    expect(after!.firstWhere((x) => x.id == m.id).deleted, isTrue, reason: 'deleted for everyone');
    expect(sv.moderation.reports, isEmpty);
    expect(_reportNotices(sv), isEmpty, reason: 'handled: off the bell');
    expect(find.text('Báo cáo cần xử lý'), findsNothing);
    expect(await t.runAsync(() => sv.api.groupReports()), isEmpty);
    await _done(t, sv);
  });

  testWidgets('a report handled on my other device leaves the bell here', (t) async {
    final sv = await makeServices(t);
    final gid = _groupConv(sv, 'Dự án Lumora').substring(2);
    final a = _api(sv).simulateGroupReport(gid, reason: 'spam');
    final b = _api(sv).simulateGroupReport(gid, reason: 'other');
    await _flush(t);
    expect(_reportNotices(sv).length, 2);
    expect(sv.moderation.reports.length, 2);
    _api(sv).reportsHandledElsewhere([a]);
    await _flush(t);
    expect(_reportNotices(sv).map((n) => n.ref), [b]);
    expect(sv.moderation.reports.map((r) => r.id), [b]);
    // dismissed here → my other devices are told by the core (`group_report_done`)
    await t.runAsync(() => sv.moderation.handled(b));
    await _flush(t);
    expect(_reportNotices(sv), isEmpty);
    await _done(t, sv);
  });

  testWidgets('pending reports come back into the bell after a restart', (t) async {
    final api = MockLumoraApi(timers: false);
    final gid = api.debugGroupIdNamed('Dự án Lumora');
    api.simulateGroupReport(gid, reason: 'spam');
    final sv = await makeServices(t, api: api);
    await _flush(t);
    expect(_reportNotices(sv).length, 1);
    await _done(t, sv);
  });

  testWidgets('report a group: left and blocked, refused everywhere, unblock in Settings', (t) async {
    final sv = await makeServices(t);
    final conv = _groupConv(sv, 'Gia đình');
    final gid = conv.substring(2);
    setSize(t, const Size(500, 1600));
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: GroupInfoView(gid: gid, embedded: true))));
    await settle(t);
    await t.scrollUntilVisible(find.text('Báo cáo nhóm'), 300, scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('Báo cáo nhóm'));
    await settle(t);
    expect(find.textContaining('trên mọi thiết bị'), findsOneWidget);
    await t.tap(find.text('Rời và chặn'));
    await _flush(t);
    expect(sv.chat.convs.containsKey(conv), isFalse);
    expect(sv.moderation.isGroupBlocked(gid), isTrue);
    await t.runAsync(() => sv.chat.load());
    expect(sv.chat.convs.containsKey(conv), isFalse, reason: 'a reload must not bring it back');

    // Settings › Privacy › Blocked groups → unblock
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: const Scaffold(body: BlockedGroupsList())));
    await settle(t);
    expect(find.text('Gia đình 🏡'), findsOneWidget);
    await t.tap(find.text('Bỏ chặn'));
    await _flush(t);
    expect(sv.moderation.blockedGroups, isEmpty);
    expect(find.text('Chưa chặn nhóm nào'), findsOneWidget);
    await _done(t, sv);
  });

  testWidgets('blocked public groups are hidden from search and their links refused', (t) async {
    final sv = await makeServices(t);
    final found = await t.runAsync(() => sv.api.searchGroups('flutter'));
    expect(found!.length, 1);
    final gid = found.single['gid'] as String;
    await t.runAsync(() => sv.moderation.blockGroup(gid, name: 'Flutter Việt Nam'));
    expect(await t.runAsync(() => sv.api.searchGroups('flutter')), isEmpty);
    Object? err;
    await t.runAsync(() => sv.api.joinPublic(gid, 'x').catchError((Object e) => err = e));
    expect((err as ApiException).code, 'err.group_blocked');
    // invite link to a blocked group
    const link = 'lumora://join/aaaaaaaaaaaaaaaaaaaaaaaa';
    final raw = await t.runAsync(() => sv.api.request('inspect_invite', {'link': link})) as Map;
    await t.runAsync(() => sv.moderation.blockGroup(raw['gid'] as String));
    final info = await t.runAsync(() => sv.api.inspectInvite(link));
    expect(info!.blocked, isTrue);
    err = null;
    await t.runAsync(() => sv.api.joinInvite(link).catchError((Object e) {
          err = e;
          return '';
        }));
    expect((err as ApiException).code, 'err.group_blocked');
    await _done(t, sv);
  });

  testWidgets('a group blocked on my other device disappears here (settings event)', (t) async {
    final sv = await makeServices(t);
    final conv = _groupConv(sv, 'Gia đình');
    final gid = conv.substring(2);
    sv.nav.openConv(conv);
    _api(sv).groupBlockedElsewhere(gid);
    await _flush(t);
    expect(sv.chat.convs.containsKey(conv), isFalse);
    expect(sv.moderation.isGroupBlocked(gid), isTrue);
    expect(sv.nav.conv, isNull);
    await _done(t, sv);
  });

  testWidgets('report a 1-1 chat: block the person, optionally delete the chat — one dialog', (t) async {
    final sv = await makeServices(t);
    final friend = sv.contacts.friends.firstWhere((c) => sv.chat.convs.containsKey('d:${c.peer}'));
    final conv = 'd:${friend.peer}';
    setSize(t, const Size(500, 1600));
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: ChatInfoPanel(conv: conv, embedded: true))));
    await settle(t);
    await t.scrollUntilVisible(find.text('Báo cáo'), 300, scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('Báo cáo'));
    await settle(t);
    expect(find.text('Báo cáo ${friend.displayName}?'), findsOneWidget);
    await t.tap(find.text('Xoá luôn cuộc trò chuyện này'));
    await settle(t);
    await t.tap(find.widgetWithText(FilledButton, 'Chặn'));
    await _flush(t);
    expect(sv.contacts[friend.peer]?.status, ContactStatus.blocked);
    expect(sv.chat.convs.containsKey(conv), isFalse);
    await _done(t, sv);
  });
}

// v1.0.8 integration pass: joining by link (pending / turned down), admin
// rights only for the owner, recovery labels and notices, the recovery banner
// after my own device restored the history, and two small store fixes
// (CallStore.chatOpen on hang-up, ChatStore.load coalescing + default timer).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/group_invites.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/chats/message_bubble.dart';
import 'package:lumora/ui/chats/stories.dart';
import 'package:lumora/ui/widgets/app_icons.dart';
import 'package:lumora/ui/groups/group_info.dart';
import 'package:lumora/ui/groups/group_invites_ui.dart';
import 'package:lumora/ui/groups/invite.dart';
import 'package:lumora/ui/settings/friend_recovery.dart';

import 'helpers.dart';

Future<void> _wait(WidgetTester t, [int ms = 120]) async {
  await t.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await settle(t);
}

Future<void> _done(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 100));
  sv.dispose();
  resetSize(t);
}

const _link = 'lumora://join/approvejoinsabcdefgh';

void main() {
  setUpAll(loadFonts);

  testWidgets('join by link: "request sent", waiting card, turned down → clear message', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    final mock = sv.api as MockLumoraApi;
    await t.pumpWidget(LumoraApp(
      services: sv,
      overlays: false,
      home: Scaffold(
        body: Column(children: [
          const GroupInvitesBanner(),
          Builder(builder: (c) => TextButton(key: const ValueKey('open_join'), onPressed: () => showJoinByLink(c, initial: _link), child: const Text('join'))),
        ]),
      ),
    ));
    await _wait(t);
    await t.tap(find.byKey(const ValueKey('open_join')));
    await _wait(t, 200);
    await t.tap(find.text('Tham gia').last);
    await _wait(t, 200);
    expect(find.text('Đã gửi yêu cầu tham gia'), findsOneWidget, reason: 'not "joined": the group only comes after approval');
    final store = GroupInvitesStore.of(sv.api);
    expect(store.pendingJoins, hasLength(1));
    final gid = store.pendingJoins.keys.single;
    await t.pump(const Duration(seconds: 4));
    await _wait(t);
    expect(find.byKey(ValueKey('join_pending_$gid')), findsOneWidget);

    mock.debugEmit('group_join_denied', {'gid': gid, 'reason': 'denied', 'code': 'err.join_denied'});
    await _wait(t);
    expect(find.byKey(ValueKey('join_pending_$gid')), findsNothing);
    expect(find.byKey(const ValueKey('join_denied_banner')), findsOneWidget);
    expect(find.text('Quản trị viên đã từ chối yêu cầu tham gia của bạn.'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('join_denied_dismiss')));
    await _wait(t);
    expect(find.byKey(const ValueKey('join_denied_banner')), findsNothing);

    // a revoked link says so
    store.joinRequested('ab' * 16, 'Nhóm A');
    mock.debugEmit('group_join_denied', {'gid': 'ab' * 16, 'reason': 'revoked'});
    await _wait(t);
    expect(find.text('Không vào được nhóm “Nhóm A”'), findsOneWidget);
    expect(find.text('Liên kết mời này đã bị thu hồi. Hãy xin một liên kết mới.'), findsOneWidget);
    // approved: the group arrives and the waiting card goes away
    store.joinRequested('cd' * 16, 'Nhóm B');
    await _wait(t);
    expect(find.byKey(ValueKey('join_pending_${'cd' * 16}')), findsOneWidget);
    mock.debugEmit('group', {'gid': 'cd' * 16, 'my_role': 'member'});
    await _wait(t);
    expect(find.byKey(ValueKey('join_pending_${'cd' * 16}')), findsNothing);
    await _done(t, sv);
  });

  testWidgets('admin rights in a plain group: only the owner sees make/unmake admin and rights', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    final mock = sv.api as MockLumoraApi;
    final gid = sv.chat.convs.values.firstWhere((c) => c.id.startsWith('g:') && !c.isCommunity && c.title.startsWith('Dự án')).id.substring(2);
    mock.cmMakeMeAdminForTest(gid);
    late GroupInfo g;
    await t.runAsync(() async => g = await sv.api.groupInfo(gid));
    expect(g.myRole, 'admin');
    final member = g.members.firstWhere((m) => m.role == 'member').peer;
    await t.pumpWidget(LumoraApp(services: sv, home: Scaffold(body: GroupInfoView(gid: gid)), overlays: false));
    await _wait(t);
    final more = find.byKey(ValueKey('group_member_more_$member'));
    await t.scrollUntilVisible(more, 200, scrollable: find.descendant(of: find.byType(GroupInfoView), matching: find.byType(Scrollable)).first);
    await settle(t, frames: 2);
    await t.tap(more);
    await settle(t, frames: 3);
    expect(find.text('Đặt làm quản trị viên'), findsNothing, reason: 'admin:<peer> roles are owner-only in the core');
    expect(find.text('Quyền quản trị viên'), findsNothing);
    await _done(t, sv);
  });

  testWidgets('recovery: "Restored from …" on handed-back messages, neutral "Group restored" notice', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    final mock = sv.api as MockLumoraApi;
    final conv = sv.chat.convs.keys.firstWhere((c) => c.startsWith('d:'));
    mock.debugRestoredMessage(conv, 'tin cũ từ 3 tháng trước', 'Bình');
    // "mine" but not signed by me: never shown as a normal own message
    mock.debugRestoredMessage(conv, 'tin "của tôi" chưa ký', 'Bình', mine: true);
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: ChatView(conv: conv, embedded: true))));
    await _wait(t, 300);
    expect(find.textContaining('Khôi phục từ '), findsNWidgets(2));
    expect(find.textContaining('· chưa xác minh'), findsOneWidget, reason: 'my unsigned message is marked unverified');
    await _done(t, sv);

    final sv2 = await makeServices(t);
    final gconv = sv2.chat.convs.keys.firstWhere((c) => c.startsWith('g:'));
    (sv2.api as MockLumoraApi).debugSystemMessage(gconv, 'sys.group_restored', args: {'name': 'X'}, text: 'Group restored');
    await t.pumpWidget(LumoraApp(services: sv2, overlays: false, home: Scaffold(body: ChatView(conv: gconv, embedded: true))));
    await _wait(t, 300);
    expect(find.text('Đã khôi phục nhóm'), findsOneWidget);
    expect(find.textContaining('đã thêm bạn vào'), findsNothing);
    await _done(t, sv2);
  });

  testWidgets('recovery banner hides once my own device restored the history', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    final mock = sv.api as MockLumoraApi;
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: Column(children: [RecoveryBanner()])), overlays: false));
    mock.debugRecoveryOffer({'peer': 'b' * 52, 'name': 'Bình', 'messages': 4});
    await _wait(t, 300);
    expect(find.byKey(const ValueKey('recovery_banner')), findsOneWidget);
    // the core: history came from my linked device → recovering false
    mock.recovering = false;
    mock.debugEmit('recovery', {'recovering': false, 'own_device': true});
    await _wait(t, 400);
    expect(find.byKey(const ValueKey('recovery_banner')), findsNothing);
    await _done(t, sv);
  });

  testWidgets('CallStore: the in-call chat is closed when the call ends', (t) async {
    final sv = await makeServices(t);
    final calls = sv.calls;
    calls.onCall({'call_id': 'c1', 'conv': 'd:x', 'peer': 'x', 'state': 'active'});
    calls.toggleChat();
    calls.toggleHand();
    expect(calls.chatOpen, isTrue);
    calls.onCall({'call_id': 'c1', 'conv': 'd:x', 'peer': 'x', 'state': 'ended'});
    expect(calls.call, isNull);
    expect(calls.chatOpen, isFalse, reason: 'the next call would open with the chat panel');
    expect(calls.handRaised, isFalse);
    await _done(t, sv);
  });

  testWidgets('ChatStore.load: no concurrent reads (coalesced), new chats found get the default timer', (t) async {
    final sv = await makeServices(t);
    final spy = _CountingApi();
    final chat = ChatStore(spy)..defaultTtl = () => 86400000;
    await t.runAsync(() async {
      await chat.load();
      expect(spy.calls, 1);
      spy.gate = Completer<void>();
      final a = chat.load();
      final b = chat.load();
      final c = chat.load();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(spy.inFlight, 1, reason: 'one read at a time');
      spy.extra = true;
      spy.gate!.complete();
      await Future.wait([a, b, c]);
      await Future<void>.delayed(const Duration(milliseconds: 100)); // previews filled
    });
    expect(spy.calls, 3, reason: 'the running read + exactly one more for the callers that came during it');
    expect(spy.maxInFlight, 1);
    expect(chat.convs.containsKey('d:new'), isTrue);
    expect(chat.ttlByConv['d:new'], 86400000, reason: 'a chat found by load() starts with the default timer');
    expect(chat.ttlByConv.containsKey('d:old'), isFalse, reason: 'chats of the first load keep theirs');
    chat.dispose();
    await _done(t, sv);
  });

  testWidgets('upgrade to the new rules asks first (one way: older members can no longer follow)', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final api = _LegacyRulesApi();
    final sv = await makeServices(t, api: api);
    late String gid;
    await t.runAsync(() async {
      final g = await sv.api.request('create_group', {'name': 'Nhóm cũ', 'members': sv.contacts.friends.take(2).map((c) => c.peer).toList(), 'kind': 0}) as Map;
      gid = g['gid'] as String;
      api.legacy.add(gid);
    });
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: GroupInfoView(gid: gid))));
    await _wait(t);
    final tile = find.byKey(const ValueKey('rules_upgrade'));
    for (var i = 0; i < 30 && tile.evaluate().isEmpty; i++) {
      await t.drag(find.byType(Scrollable).last, const Offset(0, -300));
      await settle(t);
    }
    await t.ensureVisible(tile);
    await settle(t);
    await t.tap(tile);
    await _wait(t);
    expect(find.byType(AlertDialog), findsOneWidget);
    await t.tap(find.text('Huỷ'));
    await _wait(t);
    expect(api.upgrades, isEmpty, reason: 'cancelled: nothing changes');
    await t.tap(tile);
    await _wait(t);
    await t.tap(find.widgetWithText(FilledButton, 'Nâng cấp'));
    await _wait(t);
    expect(api.upgrades, [gid]);
    await _done(t, sv);
  });

  testWidgets('a Lumora invite link in a message is tappable and opens the join view in the app', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(
      services: sv,
      overlays: false,
      home: const Scaffold(body: Center(child: RichMessageText(text: 'Vào nhóm nhé: $_link', color: Colors.white, mine: false))),
    ));
    await _wait(t);
    final rich = t.widget<Text>(find.byType(Text).first);
    final spans = <InlineSpan>[];
    rich.textSpan!.visitChildren((s) {
      spans.add(s);
      return true;
    });
    expect(spans.whereType<TextSpan>().any((x) => x.text == _link && x.style?.decoration == TextDecoration.underline), isTrue, reason: 'shown as a link');
    expect(find.byIcon(AppIcons.link), findsNothing, reason: 'no web preview card for an app link');
    await t.tap(find.byType(RichMessageText));
    await _wait(t, 200);
    expect(find.byType(AlertDialog), findsNothing, reason: 'no "open in browser?" question');
    expect(find.text('Tham gia'), findsWidgets, reason: 'the join-group preview opened');
    await _wait(t, 200);
    expect(find.text('Lời mời vào cộng đồng'), findsOneWidget, reason: 'the link carries no member count: no "0 thành viên"');
    expect(find.textContaining(' thành viên'), findsNothing);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(t);
  });

  testWidgets('the framework\'s own texts (copy / paste menu, "Back") follow the app language', (t) async {
    for (final (lang, paste, back) in [('vi', 'Dán', 'Quay lại'), ('en', 'Paste', 'Back')]) {
      final sv = await makeServices(t, locale: lang);
      late BuildContext ctx;
      await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      await _wait(t);
      expect(MaterialLocalizations.of(ctx).pasteButtonLabel, paste);
      expect(MaterialLocalizations.of(ctx).backButtonTooltip, back);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 100));
      sv.dispose();
    }
  });

  testWidgets('Khoảnh khắc composer on a phone with the keyboard open: nothing overflows, "Đăng" stays on screen', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: const StoryComposer()));
    await _wait(t);
    await t.enterText(find.byType(TextField), 'Hoàng hôn Đà Lạt');
    t.view.viewInsets = const FakeViewPadding(bottom: 600); // a 300 dp keyboard
    await _wait(t);
    expect(t.takeException(), isNull, reason: 'no RenderFlex overflow');
    final post = t.getRect(find.ancestor(of: find.text('Đăng'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(post.right, lessThanOrEqualTo(390));
    expect(post.bottom, lessThanOrEqualTo(844 - 300));
    expect(t.getSize(find.byType(StoryComposer)).width, 390, reason: 'the card keeps the full width');
    t.view.resetViewInsets();
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(t);
  });

  testWidgets('a direct chat with someone not in my contacts: a short id as its name, not called a group', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    const stranger = 'strangerstrangerstrangerstrangerstrangerstrangerstra'; // 52 chars
    (sv.api as MockLumoraApi).debugEmit('conversation', {'id': 'd:$stranger', 'kind': 0, 'title': '', 'last_ts': DateTime.now().millisecondsSinceEpoch, 'unread': 1, 'muted': false, 'pinned': false, 'last_text': '📞 Missed call'});
    await _wait(t);
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: const ChatView(conv: 'd:$stranger')));
    await _wait(t);
    expect(find.text('stranger…'), findsWidgets, reason: 'named by a short id');
    expect(find.text('Nhóm mã hoá đầu cuối'), findsNothing);
    expect(find.text('Mã hoá đầu cuối'), findsOneWidget);
    await _done(t, sv);
  });
}

class _CountingApi extends MockLumoraApi {
  int calls = 0, inFlight = 0, maxInFlight = 0;
  Completer<void>? gate;
  bool extra = false;

  @override
  Future<List<Conversation>> conversations() async {
    calls++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      final g = gate;
      if (g != null && !g.isCompleted) await g.future;
      return [
        Conversation(id: 'd:old', kind: ConvKind.direct, title: 'Old', lastTs: 1),
        if (extra) Conversation(id: 'd:new', kind: ConvKind.direct, title: 'New', lastTs: 2),
      ];
    } finally {
      inFlight--;
    }
  }
}


class _LegacyRulesApi extends MockLumoraApi {
  _LegacyRulesApi() : super(timers: false);
  final legacy = <String>{};
  final upgrades = <String>[];
  @override
  Future<dynamic> request(String cmd, [Map<String, dynamic> args = const {}]) async {
    if (cmd == 'group_upgrade_rules') {
      upgrades.add('${args['gid']}');
      legacy.remove(args['gid']);
      return null;
    }
    final r = await super.request(cmd, args);
    if (cmd == 'group_info' && r is Map && legacy.contains(args['gid'])) return {...r, 'rules_v2': false};
    return r;
  }
}
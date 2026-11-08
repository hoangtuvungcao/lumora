// A friend request or a group invitation while the app is open: a banner slides in, the
// bell counts it and the tab shows a badge (Friends / Chats).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/group_invites.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/shell/home_shell.dart';
import 'package:lumora/ui/shell/invite_banner.dart';

import 'helpers.dart';

Future<void> _flush(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
  await settle(t);
}

Future<void> _done(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 100));
  sv.dispose();
  resetSize(t);
}

int _badge(WidgetTester t, String tab) {
  final dest = find.ancestor(of: find.text(tab).last, matching: find.byType(NavigationDestination));
  final badge = t.widget<Badge>(find.descendant(of: dest, matching: find.byType(Badge)).first);
  if (!badge.isLabelVisible) return 0;
  return int.parse((badge.label as Text).data!.replaceAll('+', ''));
}

void main() {
  setUpAll(loadFonts);

  testWidgets('friend request: banner, bell and the Friends badge', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv, home: const HomeShell()));
    await settle(t);
    final before = sv.contacts.pendingCount;
    final bell = sv.notices.unread;
    (sv.api as MockLumoraApi).emitForTest('friend_request', {'peer': 'zzstranger', 'name': 'Minh Anh', 'note': 'Mình gặp ở hội thảo'});
    await _flush(t);
    expect(find.byKey(const ValueKey('invite_banner')), findsOneWidget);
    expect(find.text('Minh Anh muốn kết bạn'), findsOneWidget);
    expect(find.text('Mình gặp ở hội thảo'), findsOneWidget);
    expect(sv.notices.unread, bell + 1);
    expect(sv.contacts.pendingCount, before + 1);
    expect(_badge(t, 'Bạn bè'), before + 1);
    // "Xem" → the Friends tab
    await t.tap(find.descendant(of: find.byKey(const ValueKey('invite_banner')), matching: find.text('Xem')));
    await settle(t);
    expect(sv.nav.section, Section.friends);
    expect(find.byKey(const ValueKey('invite_banner')), findsNothing);
    await _done(t, sv);
  });

  testWidgets('group invitation: banner and the Chats badge; it hides by itself', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv, home: const HomeShell()));
    await settle(t);
    final chats = _badge(t, 'Trò chuyện');
    InviteBannerLayer.shown = const Duration(milliseconds: 300);
    addTearDown(() => InviteBannerLayer.shown = const Duration(seconds: 6));
    final api = sv.api as MockLumoraApi;
    api.cmGroupInviteForTest(name: 'Team Hè', by: sv.contacts.friends.first.peer, byName: 'Alice');
    await _flush(t);
    expect(find.text('Alice mời bạn vào Team Hè'), findsOneWidget);
    expect(GroupInvitesStore.of(sv.api).invites, hasLength(1));
    expect(_badge(t, 'Trò chuyện'), chats + 1);
    // (the timer runs in real time: events reach the stores outside the fake clock)
    await t.runAsync(() => Future<void>.delayed(InviteBannerLayer.shown + const Duration(milliseconds: 200)));
    await settle(t);
    expect(find.byKey(const ValueKey('invite_banner')), findsNothing);
    expect(sv.notices.items.first.kind, NoticeKind.groupInvite, reason: 'stays in the bell');
    await _done(t, sv);
  });
}

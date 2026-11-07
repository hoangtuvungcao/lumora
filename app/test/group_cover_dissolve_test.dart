// Group / community covers (banner in the info screen, change / remove for
// those allowed) and deleting a group / community for everyone (owner only;
// members see a notice and it leaves their lists at once).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/groups/group_info.dart';
import 'package:lumora/ui/groups/server_view.dart';

import 'helpers.dart';

String _jpeg() {
  final im = img.Image(width: 48, height: 27);
  img.fill(im, color: img.ColorRgb8(90, 70, 200));
  return base64Encode(img.encodeJpg(im, quality: 80));
}

final _list = find.byType(Scrollable).first;

Future<void> _flush(WidgetTester t, {int ms = 20}) async {
  await t.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await settle(t);
}

Future<void> _end(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 100));
  sv.dispose();
  resetSize(t);
}

void main() {
  setUpAll(loadFonts);

  testWidgets('cover: banner in the group info, change/remove for the owner, hidden for a community member', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final api = MockLumoraApi(timers: false);
    final sv = await makeServices(t, api: api);
    late String gid, memberGid;
    await t.runAsync(() async {
      final r = await sv.api.request('create_group', {'name': 'Cộng đồng Bìa', 'members': <String>[], 'kind': 1}) as Map;
      gid = r['gid'] as String;
      await sv.api.groupMeta(gid, cover: _jpeg());
      final j = await sv.api.request('join_invite', {'link': 'lumora://join/cover-test'}) as Map;
      memberGid = j['gid'] as String;
    });
    final info = await t.runAsync(() => sv.api.groupInfo(gid));
    expect(info!.hasCover, isTrue);
    expect(info.coverRev, isNotEmpty);

    // owner: the banner shows the picture, with change + remove
    await t.pumpWidget(LumoraApp(services: sv, home: Scaffold(body: GroupInfoView(gid: gid)), overlays: false));
    await _flush(t);
    expect(find.byKey(const ValueKey('group_cover')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('group_cover')), matching: find.byType(Image)), findsOneWidget);
    expect(api.commandLog, contains('group_cover'));
    expect(find.byKey(const ValueKey('cover_change')), findsOneWidget);
    expect(find.text('Đổi ảnh bìa'), findsOneWidget);
    expect(find.byKey(const ValueKey('cover_remove')), findsOneWidget);
    await t.scrollUntilVisible(find.byKey(const ValueKey('dissolve_group')), 300, scrollable: _list);
    expect(find.text('Xoá cộng đồng'), findsOneWidget);
    // (the info page grew with the Community 2.0 sections: back to the very top, so the
    // buttons on the cover are on screen, not just the cover's lower edge)
    await t.scrollUntilVisible(find.byKey(const ValueKey('group_cover')), -300, scrollable: _list);
    await t.drag(_list, const Offset(0, 1200));
    await settle(t);

    // remove → confirm → the gradient placeholder, "add cover"
    await t.tap(find.byKey(const ValueKey('cover_remove')));
    await settle(t);
    expect(find.text('Gỡ ảnh bìa'), findsWidgets);
    await t.tap(find.widgetWithText(FilledButton, 'Xoá'));
    await _flush(t, ms: 200);
    expect((await t.runAsync(() => sv.api.groupInfo(gid)))!.hasCover, isFalse);
    expect(find.byKey(const ValueKey('cover_remove')), findsNothing);
    expect(find.text('Thêm ảnh bìa'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('group_cover')), matching: find.byType(Image)), findsNothing);

    // a plain member of a community: the banner, but no cover actions and no delete
    await t.pumpWidget(LumoraApp(services: sv, home: Scaffold(body: GroupInfoView(key: const ValueKey('m'), gid: memberGid)), overlays: false));
    await _flush(t);
    expect(find.byKey(const ValueKey('group_cover')), findsOneWidget);
    expect(find.byKey(const ValueKey('cover_change')), findsNothing);
    expect(find.byKey(const ValueKey('cover_remove')), findsNothing);
    await t.scrollUntilVisible(find.byKey(const ValueKey('leave_group')), 300, scrollable: _list);
    expect(find.byKey(const ValueKey('dissolve_group')), findsNothing);
    // the core refuses a community member too
    await t.runAsync(() async {
      await expectLater(sv.api.groupMeta(memberGid, cover: _jpeg()), throwsA(anything));
    });
    await _end(t, sv);
  });

  testWidgets('cover: shown on the community card and above the channel list', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    late String gid;
    await t.runAsync(() async {
      final r = await sv.api.request('create_group', {'name': 'Cộng đồng Có Bìa', 'members': <String>[], 'kind': 1}) as Map;
      gid = r['gid'] as String;
      await sv.api.groupMeta(gid, cover: _jpeg());
      await sv.spaces.load();
    });
    final sp = sv.spaces.byId(gid)!;
    expect(sp.hasCover, isTrue);
    expect(sp.myRole, 'owner');
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SpacesMobileScreen()), overlays: false));
    await _flush(t);
    expect(find.byKey(ValueKey('space_card_cover_$gid')), findsOneWidget);
    await t.tap(find.text('Cộng đồng Có Bìa'));
    await _flush(t);
    expect(find.byKey(const ValueKey('space_cover')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('space_cover')), matching: find.byType(Image)), findsOneWidget);
    await _end(t, sv);
  });

  testWidgets('delete: owner-only menu item, confirm, group_dissolve, gone from the list', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final api = MockLumoraApi(timers: false);
    final sv = await makeServices(t, api: api);
    late String gid;
    await t.runAsync(() async {
      final r = await sv.api.request('create_group', {'name': 'Cộng đồng Xoá', 'members': <String>[], 'kind': 1}) as Map;
      gid = r['gid'] as String;
      await sv.api.request('join_invite', {'link': 'lumora://join/delete-test'});
      await sv.spaces.load();
    });
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SpacesMobileScreen()), overlays: false));
    await settle(t);

    // a member's menu: no delete
    await t.longPress(find.text('Cộng đồng Rust Việt Nam'));
    await settle(t);
    expect(find.byKey(const ValueKey('space_menu_leave')), findsOneWidget);
    expect(find.byKey(const ValueKey('space_menu_delete')), findsNothing);
    await t.tapAt(const Offset(10, 10));
    await settle(t);

    // the owner's menu: delete → confirm → gone for everyone
    await t.longPress(find.text('Cộng đồng Xoá'));
    await settle(t);
    expect(find.byKey(const ValueKey('space_menu_delete')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('space_menu_delete')));
    await settle(t);
    expect(find.text('Xoá cộng đồng'), findsWidgets); // the dialog title
    expect(find.textContaining('Không thể hoàn tác'), findsOneWidget);
    expect(api.commandLog, isNot(contains('group_dissolve')));
    await t.tap(find.widgetWithText(FilledButton, 'Xoá vĩnh viễn'));
    await _flush(t, ms: 100);
    expect(api.commandLog, contains('group_dissolve'));
    expect(find.text('Cộng đồng Xoá'), findsNothing);
    expect(sv.spaces.byId(gid), isNull);
    expect(sv.chat.convs.containsKey('g:$gid'), isFalse);
    expect(find.text('Cộng đồng «Cộng đồng Xoá» đã bị xoá'), findsOneWidget); // said once, by the screen
    expect(sv.notices.items.where((n) => n.title.contains('Cộng đồng Xoá')), isEmpty);
    expect((await t.runAsync(() => sv.spaces.api.spaces()))!.any((s) => s.id == gid), isFalse);
    await _end(t, sv);
  });

  testWidgets('delete: a plain group from its info screen (owner)', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final api = MockLumoraApi(timers: false);
    final sv = await makeServices(t, api: api);
    late String gid;
    await t.runAsync(() async {
      final r = await sv.api.request('create_group', {'name': 'Nhóm Xoá', 'members': <String>[]}) as Map;
      gid = r['gid'] as String;
    });
    await _flush(t);
    expect(sv.chat.convs.containsKey('g:$gid'), isTrue);
    await t.pumpWidget(LumoraApp(services: sv, home: Scaffold(body: GroupInfoView(gid: gid)), overlays: false));
    await _flush(t);
    // a plain group: any member may change the cover
    expect(find.byKey(const ValueKey('cover_change')), findsOneWidget);
    await t.scrollUntilVisible(find.byKey(const ValueKey('dissolve_group')), 300, scrollable: _list);
    expect(find.text('Xoá nhóm'), findsOneWidget);
    await t.drag(_list, const Offset(0, -300));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('dissolve_group')));
    await settle(t);
    await t.tap(find.widgetWithText(FilledButton, 'Xoá vĩnh viễn'));
    await _flush(t, ms: 100);
    expect(api.commandLog, contains('group_dissolve'));
    expect(sv.chat.convs.containsKey('g:$gid'), isFalse);
    expect(find.text('Nhóm «Nhóm Xoá» đã bị xoá'), findsOneWidget);
    await _end(t, sv);
  });

  testWidgets('dissolved by the owner: a member sees the notice, the community leaves the list and its page closes', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final api = MockLumoraApi(timers: false);
    final sv = await makeServices(t, api: api);
    late String gid;
    await t.runAsync(() async {
      final j = await sv.api.request('join_invite', {'link': 'lumora://join/dissolved'}) as Map;
      gid = j['gid'] as String;
      await sv.spaces.load();
    });
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SpacesMobileScreen()), overlays: false));
    await settle(t);
    // the community is open (its channel list)
    await t.tap(find.text('Cộng đồng Rust Việt Nam'));
    await settle(t);
    expect(find.byKey(const ValueKey('space_settings')), findsOneWidget);
    sv.nav.openChannel(gid, 'g:$gid');

    await t.runAsync(() async => api.groupDissolvedByOwner(gid));
    await _flush(t);
    await _flush(t);
    expect(find.text('Cộng đồng «Cộng đồng Rust Việt Nam» đã bị xoá'), findsOneWidget);
    expect(find.byKey(const ValueKey('space_settings')), findsNothing, reason: 'its page closed');
    expect(find.text('Cộng đồng Rust Việt Nam'), findsNothing);
    expect(sv.spaces.byId(gid), isNull);
    expect(sv.chat.convs.containsKey('g:$gid'), isFalse);
    expect(sv.nav.section, isNot(Section.space));
    expect(sv.notices.items.first.title, 'Cộng đồng «Cộng đồng Rust Việt Nam» đã bị xoá');
    await t.runAsync(() async {
      await expectLater(sv.api.groupInfo(gid), throwsA(anything));
    });

    // English
    sv.settings.locale = 'en';
    await t.runAsync(() async {
      final r = await sv.api.request('create_group', {'name': 'Book club', 'members': <String>[]}) as Map;
      api.groupDissolvedByOwner(r['gid'] as String);
    });
    await _flush(t);
    expect(find.text('Group “Book club” was deleted'), findsOneWidget);
    await _end(t, sv);
  });
}

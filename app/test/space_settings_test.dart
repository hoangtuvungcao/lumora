// A community (space): settings (picture, name, description, members), a long-press menu,
// and leaving takes it off the list at once.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/ui/groups/server_view.dart';

import 'helpers.dart';

void main() {
  setUpAll(loadFonts);

  testWidgets('community: settings from the header, long-press menu, leave removes it', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    await t.runAsync(() async {
      await sv.api.request('create_group', {'name': 'Cộng đồng Thử', 'members': <String>[], 'kind': 1});
      await sv.spaces.load();
    });
    final sp = sv.spaces.spaces.firstWhere((x) => x.name == 'Cộng đồng Thử');

    // header → settings: rename, description (the group info of the community)
    await t.pumpWidget(LumoraApp(services: sv, home: Scaffold(body: ChannelList(space: sp, onOpen: (_) {})), overlays: false));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('space_settings')));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle(t);
    expect(find.text('Cài đặt cộng đồng'), findsOneWidget);
    expect(find.text('Đổi tên nhóm'), findsOneWidget);
    expect(find.text('Sửa mô tả'), findsOneWidget);
    // (pageBack() looks for the English "Back" tooltip; the app speaks Vietnamese)
    await t.tap(find.byType(BackButton));
    await settle(t);

    // mobile list: long-press → leave → gone
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SpacesMobileScreen()), overlays: false));
    await settle(t);
    expect(find.text('Cộng đồng Thử'), findsOneWidget);
    await t.longPress(find.text('Cộng đồng Thử'));
    await settle(t);
    expect(find.byKey(const ValueKey('space_menu_settings')), findsOneWidget);
    expect(find.byKey(const ValueKey('space_menu_invite')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('space_menu_leave')));
    await settle(t);
    await t.tap(find.widgetWithText(FilledButton, 'Rời'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle(t);
    expect(find.text('Cộng đồng Thử'), findsNothing);
    expect(sv.spaces.spaces.any((x) => x.id == sp.id), isFalse);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(t);
  });
}

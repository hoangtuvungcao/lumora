// Stories: photo flag survives the core's short `story` event, delete + archive; top toasts;
// a deleted chat comes back when a new message arrives.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/ui/chats/stories.dart';
import 'package:lumora/ui/widgets/common.dart';

import 'helpers.dart';

MockLumoraApi _mock(AppServices sv) => sv.api as MockLumoraApi;

void main() {
  setUpAll(loadFonts);

  testWidgets('a short `story` event reloads instead of showing a blank story', (t) async {
    final sv = await makeServices(t);
    await t.runAsync(() => sv.stories.load());
    final before = sv.stories.stories.where((s) => s.hasImage).length;
    expect(before, greaterThan(0));
    // the real core only names the story
    final st = sv.stories.stories.firstWhere((s) => s.hasImage);
    sv.stories.onStory({'id': st.id, 'author': st.author});
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(sv.stories.stories.firstWhere((s) => s.id == st.id).hasImage, isTrue);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
  });

  testWidgets('story archive lists mine; delete removes it everywhere', (t) async {
    setSize(t, const Size(390, 844));
    final sv = await makeServices(t);
    final me = sv.session.me!.peer;
    await t.runAsync(() async {
      await sv.stories.post(text: 'Hôm nay vui quá', bg: 'sunset');
    });
    final mine = sv.stories.mine(me);
    expect(mine, isNotEmpty);
    await t.pumpWidget(LumoraApp(services: sv, home: const StoryArchiveScreen(), overlays: false));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(t);
    expect(find.text('Hôm nay vui quá'), findsOneWidget);
    expect(find.text('Cuối tuần ở Đà Lạt 🌲'), findsOneWidget, reason: 'older stories stay in the archive');
    expect(find.text('Đang hiển thị'), findsWidgets);

    // someone else's story can't be deleted
    final other = sv.stories.stories.firstWhere((s) => s.author != me);
    final err = await t.runAsync(() async {
      try {
        await sv.api.storyDelete(other.id);
        return null;
      } on ApiException catch (e) {
        return e;
      }
    });
    expect(err?.code, 'err.story_not_yours');

    await t.tap(find.byTooltip('Xoá khoảnh khắc').first);
    await settle(t);
    expect(find.text('Xoá khoảnh khắc này?'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, 'Xoá'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(t);
    expect(find.text('Hôm nay vui quá'), findsNothing);
    expect(sv.stories.mine(me), isEmpty);
    expect(find.text('Đã xoá khoảnh khắc'), findsOneWidget, reason: 'toast at the top');
    final toastTop = t.getTopLeft(find.text('Đã xoá khoảnh khắc')).dy;
    expect(toastTop, lessThan(844 / 3), reason: 'notices slide in from the top, not over the composer');
    await t.pump(const Duration(seconds: 3));
    await settle(t);
    expect(find.text('Đã xoá khoảnh khắc'), findsNothing, reason: 'toast goes away by itself');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(t);
  });

  testWidgets('top toast: tap to dismiss, a new one replaces the old', (t) async {
    final sv = await makeServices(t);
    late BuildContext ctx;
    await t.pumpWidget(LumoraApp(services: sv, home: Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox.expand();
    })), overlays: false));
    await settle(t);
    showTopToast(ctx, 'Một');
    await settle(t);
    showTopToast(ctx, 'Hai');
    await settle(t);
    expect(find.text('Một'), findsNothing);
    expect(find.text('Hai'), findsOneWidget);
    await t.tap(find.text('Hai'));
    await settle(t);
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Hai'), findsNothing);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
  });

  testWidgets('a chat deleted earlier comes back when a message arrives', (t) async {
    final sv = await makeServices(t);
    await t.runAsync(() => sv.chat.load());
    final conv = sv.chat.convs.keys.firstWhere((c) => c.startsWith('d:'));
    sv.chat.onConversationRemoved(conv);
    expect(sv.chat.convs.containsKey(conv), isFalse);
    sv.chat.onMessage({'id': 'm_new', 'conv': conv, 'author': conv.substring(2), 'kind': 'text', 'body': 'nhắn lại nè', 'ts': DateTime.now().millisecondsSinceEpoch, 'hlc': 1}, myPeer: sv.session.me!.peer);
    await t.pump(const Duration(milliseconds: 200));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(sv.chat.convs.containsKey(conv), isTrue);
    expect(_mock(sv), isNotNull);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
  });
}

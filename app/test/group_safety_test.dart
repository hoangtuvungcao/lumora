// Group abuse protections in the app: the verified mark on public group
// search results, the "messages held back" banner (`group_flood`) with the
// admins' slow-mode button, and friendly text for the new `err.*` codes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/l10n/strings.dart';
import 'package:lumora/state/group_flood.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/groups/group_safety.dart';
import 'package:lumora/ui/shell/palette.dart';
import 'package:lumora/ui/widgets/common.dart';

import 'helpers.dart';

MockLumoraApi _mock(AppServices sv) => sv.api as MockLumoraApi;

/// Core events reach the stores in the real-async zone: let them through.
Future<void> _flush(WidgetTester t, {int frames = 4}) async {
  for (var i = 0; i < 2; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await settle(t, frames: frames);
  }
}

Future<void> _done(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 100));
  sv.dispose();
  resetSize(t);
}

String _group(AppServices sv, String prefix) => sv.chat.convs.values.firstWhere((c) => c.isGroup && c.title.startsWith(prefix)).id;

Future<void> _openChat(WidgetTester t, AppServices sv, String conv) async {
  setSize(t, const Size(900, 900));
  await t.pumpWidget(LumoraApp(services: sv, home: Scaffold(body: ChatView(conv: conv, embedded: true)), overlays: false));
  await settle(t);
}

void main() {
  setUpAll(loadFonts);

  test('flood notices: latest per chat, no repeats within 10 minutes', () {
    var now = DateTime(2026, 11, 6, 10);
    final f = FloodNotices(clock: () => now);
    Map<String, dynamic> ev({String author = 'a', String reason = 'rate'}) =>
        {'gid': 'g1', 'conv': 'g:g1', 'author': author, 'name': 'An', 'reason': reason, 'admin': true, 'suggest_slow_mode_s': 10, 'text': 'x'};
    f.onEvent(ev());
    expect(f.of('g:g1')!.canSlowDown, isTrue);
    f.dismiss('g:g1');
    f.onEvent(ev());
    expect(f.of('g:g1'), isNull, reason: 'same author + reason within 10 min is not shown again');
    f.onEvent(ev(author: 'b'));
    expect(f.of('g:g1')!.author, 'b');
    now = now.add(const Duration(minutes: 11));
    f.dismiss('g:g1');
    f.onEvent(ev());
    expect(f.of('g:g1')!.author, 'a', reason: 'shown again after the window');
    // Members never get the button, nor non-rate reasons.
    f.onEvent({...ev(author: 'c'), 'admin': false});
    expect(f.of('g:g1')!.canSlowDown, isFalse);
    f.onEvent({...ev(author: 'd', reason: 'group_quota'), 'suggest_slow_mode_s': 0});
    expect(f.of('g:g1')!.canSlowDown, isFalse);
  });

  testWidgets('public group search marks verified groups', (t) async {
    final sv = await makeServices(t);
    setSize(t, const Size(1200, 900));
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SizedBox.expand()), overlays: false));
    await settle(t);
    showCommandPalette(t.element(find.byType(Scaffold).first), initial: 'flutter rust');
    await settle(t);
    await _flush(t);

    expect(find.text('Flutter Việt Nam'), findsOneWidget);
    expect(find.text('Rust Việt Nam'), findsOneWidget);
    // Only the verified (signed by the group's admin) listing gets the mark.
    expect(find.byType(VerifiedGroupMark), findsOneWidget);
    final flutterRow = find.ancestor(of: find.text('Flutter Việt Nam'), matching: find.byType(Row)).first;
    expect(find.descendant(of: flutterRow, matching: find.byType(VerifiedGroupMark)), findsOneWidget);
    final sem = t.ensureSemantics();
    await t.pump();
    expect(find.bySemanticsLabel(RegExp('Đã xác minh')), findsOneWidget);
    sem.dispose();
    // The unverified one says so, quietly, where the user joins.
    expect(find.textContaining('Chưa xác minh'), findsOneWidget);
    expect(find.descendant(of: find.byType(CommandPalette), matching: find.textContaining('@rust_vn')).evaluate().single.widget, isA<Text>().having((w) => w.data, 'subtitle', contains('Chưa xác minh')));
    await _done(t, sv);
  });

  testWidgets('flood banner: admins can turn on the suggested slow mode', (t) async {
    final sv = await makeServices(t);
    final conv = _group(sv, 'Dự án Lumora'); // this account owns it
    await _openChat(t, sv, conv);
    expect(find.byType(GroupFloodBanner), findsOneWidget);
    expect(find.textContaining('đang gửi quá nhiều tin'), findsNothing);

    _mock(sv).simulateGroupFlood(conv, admin: true, suggest: 20);
    await _flush(t);
    expect(find.textContaining('đang gửi quá nhiều tin nên một số tin đã bị ẩn'), findsOneWidget);
    final button = find.ancestor(of: find.text('Bật chế độ chậm · 20 giây'), matching: find.byWidgetPredicate((w) => w is FilledButton));
    expect(button, findsOneWidget);

    await t.tap(button);
    await _flush(t);
    final info = await t.runAsync(() => sv.api.groupInfo(conv.substring(2)));
    expect(info!.slowModeS, 20, reason: 'the suggested value goes to group_settings');
    expect(find.textContaining('đang gửi quá nhiều tin'), findsNothing, reason: 'banner closes once done');
    expect(find.text('Đã bật chế độ chậm: 20 giây giữa hai tin'), findsOneWidget);

    // The core throttles per author; the app does not show a repeat either.
    _mock(sv).simulateGroupFlood(conv, admin: true, suggest: 20);
    await _flush(t);
    expect(find.textContaining('đang gửi quá nhiều tin'), findsNothing);
    await _done(t, sv);
  });

  testWidgets('flood banner: members see the notice without the button', (t) async {
    final sv = await makeServices(t);
    final conv = _group(sv, 'Gia đình'); // plain member here
    await _openChat(t, sv, conv);
    _mock(sv).simulateGroupFlood(conv, admin: false);
    await _flush(t);
    expect(find.textContaining('đang gửi quá nhiều tin nên một số tin đã bị ẩn'), findsOneWidget);
    expect(find.textContaining('Bật chế độ chậm'), findsNothing);
    expect(find.descendant(of: find.byType(GroupFloodBanner), matching: find.byWidgetPredicate((w) => w is FilledButton)), findsNothing);

    // Another group's notice is not shown here.
    _mock(sv).simulateGroupFlood(_group(sv, 'Dự án Lumora'), admin: true, reason: 'group_quota');
    await _flush(t);
    expect(find.textContaining('Hôm nay nhóm đã nhận quá nhiều tin'), findsNothing);

    await t.tap(find.descendant(of: find.byType(GroupFloodBanner), matching: find.byTooltip('Đóng')));
    await settle(t);
    expect(find.textContaining('đang gửi quá nhiều tin'), findsNothing);
    await _done(t, sv);
  });

  testWidgets('new group / story error codes read in the app language', (t) async {
    final sv = await makeServices(t, locale: 'en');
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SizedBox.expand()), overlays: false));
    await settle(t);
    final ctx = t.element(find.byType(Scaffold).first);
    final s = S.read(ctx);
    for (final code in ['group_too_fast', 'group_quota_you', 'group_quota', 'story_limit']) {
      expect(s.orElse('err_$code', ''), isNotEmpty);
      expect(S.vn.orElse('err_$code', ''), isNotEmpty);
    }
    // The core's text may be in another language; the code decides the words.
    final e = ApiException('Bạn đang gửi tin quá nhanh trong nhóm này.', cmd: 'send', code: 'err.group_too_fast');
    toast(ctx, '${s('send_failed')}: $e');
    await t.pump();
    expect(find.text('Failed to send: You’re sending messages too quickly in this group. Wait a moment, then try again.'), findsOneWidget);
    await t.pump(const Duration(seconds: 3));
    final st = ApiException('Bạn đang có 10 tin.', cmd: 'post_story', code: 'err.story_limit');
    toast(ctx, '$st');
    await settle(t);
    expect(find.text('You already have many stories up. Delete one before adding another.'), findsOneWidget);
    await _done(t, sv);
  });
}

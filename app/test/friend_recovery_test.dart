// Recovery from friends after a restore with the recovery phrase: the chat
// list banner, the review list (accept / decline), and the synced setting
// "Giúp bạn bè khôi phục lịch sử" (default on).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/l10n/strings_data.dart';
import 'package:lumora/ui/settings/friend_recovery.dart';

import 'helpers.dart';

const _bob = 'bobbobbobbobbobbobbobbobbobbobbobbobbobbobbobbobbobba';
const _carol = 'carolcarolcarolcarolcarolcarolcarolcarolcarolcarolcar';

Future<void> _wait(WidgetTester t, [int ms = 120]) async {
  await t.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await settle(t);
}

void main() {
  setUpAll(loadFonts);

  testWidgets('review list: banner while offers wait, accept receives history, decline drops it', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    final mock = sv.api as MockLumoraApi;
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: Column(children: [RecoveryBanner()])), overlays: false));
    await _wait(t);
    expect(find.byKey(const ValueKey('recovery_banner')), findsNothing, reason: 'nothing offered yet');

    mock.debugRecoveryOffer({'peer': _bob, 'name': 'Bình', 'messages': 42, 'groups': ['00' * 16], 'verified': true});
    mock.debugRecoveryOffer({'peer': _carol, 'name': 'Chi', 'messages': 1, 'groups': <String>[]});
    await _wait(t, 300);
    expect(find.byKey(const ValueKey('recovery_banner')), findsOneWidget);
    expect(find.text('Bạn bè muốn giúp bạn khôi phục lịch sử (2)'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('recovery_banner')));
    await _wait(t);
    expect(find.byKey(const ValueKey('recovery_sheet')), findsOneWidget);
    expect(find.text('Bình'), findsOneWidget);
    expect(find.text('42 tin nhắn · 1 nhóm chung'), findsOneWidget);
    expect(find.text('Đã xác minh'), findsOneWidget, reason: 'only Bình showed a message the account signed');
    expect(find.byKey(const ValueKey('recovery_unverified_$_carol')), findsOneWidget, reason: 'Chi is clearly unverified');
    expect(find.text('Chưa xác minh'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('recovery_accept_$_bob')));
    await _wait(t, 400);
    expect(mock.mockRecoveryOffers.firstWhere((o) => o['peer'] == _bob)['state'], 'done');
    expect(find.text('Đã khôi phục 42 tin nhắn'), findsOneWidget);
    expect(find.byKey(const ValueKey('recovery_accept_$_bob')), findsNothing);

    await t.tap(find.byKey(const ValueKey('recovery_decline_$_carol')));
    await _wait(t, 300);
    expect(mock.mockRecoveryOffers.firstWhere((o) => o['peer'] == _carol)['state'], 'declined');
    expect(find.text('Đã từ chối'), findsOneWidget);

    // nothing waits any more: the banner goes away; "stop asking" ends recovery
    await t.tap(find.byKey(const ValueKey('recovery_dismiss')));
    await _wait(t, 300);
    expect(mock.recovering, isFalse);
    expect(find.byKey(const ValueKey('recovery_banner')), findsNothing);

    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(t);
  });

  testWidgets('setting "Giúp bạn bè khôi phục lịch sử": on by default, writes help_restore, follows other devices', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    final mock = sv.api as MockLumoraApi;
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: Column(children: [HelpRestoreRow()])), overlays: false));
    await _wait(t);
    expect(find.text('Giúp bạn bè khôi phục lịch sử'), findsOneWidget);
    Switch sw() => t.widget<Switch>(find.descendant(of: find.byKey(const ValueKey('help_restore')), matching: find.byType(Switch)));
    expect(sw().value, isTrue, reason: 'default on');

    await t.tap(find.byKey(const ValueKey('help_restore')));
    await _wait(t);
    expect(sw().value, isFalse);
    expect((await t.runAsync(() => sv.api.settingsGet()))!['help_restore'], isFalse, reason: 'the core keeps it');

    // turned back on from another device of the account: the row follows
    await t.runAsync(() => sv.api.settingsSet({'help_restore': true}));
    mock.debugEmit('settings', {'key': 'privacy.help_restore'});
    await _wait(t, 400);
    expect(sw().value, isTrue);

    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(t);
  });

  test('copy exists in both languages', () {
    for (final k in ['help_restore', 'help_restore_hint', 'rc_title', 'rc_hint', 'rc_banner', 'rc_accept', 'rc_decline', 'rc_done']) {
      expect(kStrings[k]?.length, 2, reason: k);
    }
    expect(kStrings['help_restore']![1], 'Help friends restore their history');
  });
}

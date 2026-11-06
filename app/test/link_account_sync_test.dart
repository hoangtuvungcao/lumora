// Regression (v1.0.0, Android main device → new Linux laptop): the newly
// linked device read its profile once, right after the core restarted, i.e.
// before the account state arrived from the main device — so it kept showing
// the temporary "Lumora 123" name and no avatar although the core already had
// the account's; and a chat opened while the history was being copied never
// showed the older messages (they are imported without `message` events).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/core/mock_api.dart';

import 'helpers.dart';

Future<void> _flush(WidgetTester t) async {
  for (var i = 0; i < 3; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await t.pump();
  }
}

void main() {
  testWidgets('profile copied to (or changed on) another device reaches the screen', (t) async {
    final sv = await makeServices(t);
    final mock = sv.api as MockLumoraApi;
    await _flush(t);
    expect(sv.session.me?.name, isNot('Minh Android'));

    // the core imports the account's profile (bootstrap / self-sync) on its own
    await t.runAsync(() => mock.request('set_profile', {'name': 'Minh Android', 'avatar': 'AQID'}));
    mock.emitForTest('profile', {'key': 'profile.name', 'name': 'Minh Android'});
    await _flush(t);
    expect(sv.session.me?.name, 'Minh Android');
    expect(sv.session.profile.name, 'Minh Android');
    expect(sv.session.avatarBytes, isNotNull);

    // and once more when the whole account state is in
    await t.runAsync(() => mock.request('set_profile', {'name': 'Minh'}));
    mock.emitForTest('link_state', {'state': 'state_synced'});
    await _flush(t);
    expect(sv.session.me?.name, 'Minh');

    await t.pumpWidget(const SizedBox());
    sv.dispose();
  });

  testWidgets('an open chat shows history copied in after it was opened', (t) async {
    final sv = await makeServices(t);
    final mock = sv.api as MockLumoraApi;
    await _flush(t);
    const conv = 'd:copied-history-test';
    final th = sv.chat.thread(conv);
    await t.runAsync(() => th.loadInitial());
    final before = th.messages.length;
    expect(before, lessThan(40));
    expect(th.hasMore, isFalse);

    mock.importHistoryForTest(conv, 60);
    mock.emitForTest('history_sync', {'messages': 60, 'convs_done': 1, 'convs_total': 1, 'done': true});
    await _flush(t);
    expect(th.messages.length, greaterThanOrEqualTo(40));
    expect(th.hasMore, isTrue);
    for (var i = 0; i < 5 && th.hasMore; i++) {
      await t.runAsync(() => th.loadOlder());
    }
    expect(th.messages.length, before + 60);
    expect(th.messages.first.hlc, lessThan(th.messages.last.hlc));

    await t.pumpWidget(const SizedBox());
    sv.dispose();
  });
}

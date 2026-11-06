// Answer / Decline on the Android incoming-call notification reach the call
// they were posted for, and nothing else.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';

import 'helpers.dart';

void main() {
  void ring(AppServices sv, String id) =>
      sv.calls.onCall({'call_id': id, 'conv': 'd:bob', 'peer': 'bob', 'from': 'bob', 'state': 'incoming'});

  testWidgets('Decline declines the ringing call', (t) async {
    final sv = await makeServices(t);
    ring(sv, 'c1');
    expect(sv.calls.call?.phase, CallPhase.incoming);
    sv.onCallNotificationAction('decline', 'c1');
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(sv.calls.call, isNull);
    await t.pump(const Duration(minutes: 3));
    sv.dispose();
  });

  testWidgets('Answer answers it; a stale button (another call) does nothing', (t) async {
    final sv = await makeServices(t);
    ring(sv, 'c2');
    sv.onCallNotificationAction('answer', 'old-call');
    expect(sv.calls.call?.phase, CallPhase.incoming);
    sv.onCallNotificationAction('answer', 'c2');
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(sv.calls.call?.phase, CallPhase.active);
    await t.runAsync(() => sv.calls.hangup());
    await t.pump(const Duration(minutes: 3));
    sv.dispose();
  });
}

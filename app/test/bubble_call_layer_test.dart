// Android chat bubble: the bubble shows its own chat only — someone else's ringing call
// (or a call still on) is never drawn over it; back in the main window it shows again.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/platform/android_bridge.dart';
import 'package:lumora/ui/calls/call_layer.dart';
import 'package:lumora/ui/shell/home_shell.dart';

import 'helpers.dart';

void main() {
  setUpAll(loadFonts);

  testWidgets('incoming call: hidden in a chat bubble, shown in the main window', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    addTearDown(() => AndroidBridge.inBubble.value = false);
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv, home: const HomeShell()));
    await settle(t);
    AndroidBridge.inBubble.value = true;
    (sv.api as MockLumoraApi).simulateIncomingCall(video: true);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(t);
    expect(find.byType(IncomingCallOverlay), findsNothing, reason: 'not over the bubble’s chat');
    AndroidBridge.inBubble.value = false;
    await settle(t);
    expect(find.byType(IncomingCallOverlay), findsOneWidget, reason: 'the main window shows the call');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(t);
  });
}

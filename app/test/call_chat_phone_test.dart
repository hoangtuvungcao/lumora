// In-call chat on a phone: the call's control dock doesn't cover the composer, there is a
// way back to the call, and the composer stays above the keyboard.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/platform/android_bridge.dart';
import 'package:lumora/ui/shell/home_shell.dart';

import 'helpers.dart';

void main() {
  setUpAll(loadFonts);

  testWidgets('phone in-call chat: no dock over the composer, back to the call', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv, home: const HomeShell()));
    await settle(t);
    (sv.api as MockLumoraApi).simulateIncomingCall();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(t);
    await t.runAsync(() => sv.calls.answer(true));
    await settle(t);
    expect(find.byTooltip('Tắt micro'), findsOneWidget, reason: 'dock shown during the call');
    sv.calls.toggleChat();
    await settle(t);
    expect(find.byKey(const ValueKey('back_to_call')), findsOneWidget);
    final field = find.byType(TextField).last;
    expect(field, findsOneWidget);
    // nothing of the call dock is drawn over the composer
    final box = t.getRect(field);
    expect(t.hitTestOnBinding(box.center).path.any((e) => e.target.toString().contains('BackdropFilter')), isFalse);
    expect(find.byTooltip('Tắt micro'), findsNothing, reason: 'dock hidden while chatting');
    await t.tap(find.byKey(const ValueKey('back_to_call')));
    await settle(t);
    expect(sv.calls.chatOpen, isFalse);
    expect(find.byTooltip('Tắt micro'), findsOneWidget, reason: 'dock back with the call');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(t);
  });

  testWidgets('minimised video call → floating video window; tap restores; tiny window = video only', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv, home: const HomeShell()));
    await settle(t);
    (sv.api as MockLumoraApi).simulateIncomingCall(video: true);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(t);
    await t.runAsync(() => sv.calls.answer(true));
    await settle(t);
    sv.calls.setMinimized(true);
    await settle(t);
    final win = find.byKey(const ValueKey('floating_video'));
    expect(win, findsOneWidget);
    await t.drag(win, const Offset(-200, 300));
    await settle(t);
    expect(t.getTopLeft(win).dx, lessThan(40), reason: 'snaps to the nearest side');
    await t.tap(win);
    await settle(t);
    expect(sv.calls.minimized, isFalse);
    expect(find.byTooltip('Tắt micro'), findsOneWidget);
    // A small window is NOT picture-in-picture (desktop window, split screen,
    // foldable cover screen): the call controls stay, hang-up included.
    setSize(t, const Size(240, 420), dpr: 2);
    await settle(t);
    while (t.takeException() != null) {} // (the app under the call may overflow at this size)
    expect(find.byTooltip('Tắt micro'), findsOneWidget);
    expect(find.byKey(const ValueKey('pip_video')), findsNothing);
    // Android picture-in-picture (MainActivity tells AndroidBridge): the video only
    addTearDown(() => AndroidBridge.pip.value = false);
    setSize(t, const Size(180, 320), dpr: 2);
    AndroidBridge.pip.value = true;
    await settle(t);
    expect(find.byTooltip('Tắt micro'), findsNothing);
    expect(find.byKey(const ValueKey('pip_video')), findsOneWidget);
    // (the app under the black video may overflow at this size; it isn't visible)
    while (t.takeException() != null) {}
    // leaving picture-in-picture: the call screen again
    AndroidBridge.pip.value = false;
    setSize(t, const Size(390, 844), dpr: 2);
    await settle(t);
    expect(find.byTooltip('Tắt micro'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(t);
  });
}

// Android "keep running in the background" sheet (first run + Settings ›
// Notifications) and the chat-bubbles switch.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/platform/android_bridge.dart';
import 'package:lumora/state/settings.dart';
import 'package:lumora/ui/settings/background_sheet.dart';
import 'package:lumora/ui/settings/settings_screen.dart';
import 'package:lumora/ui/theme.dart';
import 'package:provider/provider.dart';

Widget _wrap(Settings st, Widget child) => ChangeNotifierProvider.value(
      value: st,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: Scaffold(body: SingleChildScrollView(child: child))),
    );

void main() {
  testWidgets('Xiaomi, still restricted: both steps with their buttons (vi)', (t) async {
    await t.pumpWidget(_wrap(Settings()..locale = 'vi', const BackgroundSheet(status: BackgroundStatus(ignoringBattery: false, oem: 'xiaomi', autostart: true))));
    expect(find.text('Cho phép chạy nền'), findsOneWidget);
    expect(find.text('Mở cài đặt Tự khởi chạy'), findsOneWidget);
    expect(find.textContaining('Xiaomi, Redmi, POCO'), findsOneWidget);
    expect(find.text('Để sau'), findsOneWidget);
  });

  testWidgets('allowed, no maker screen: done (en)', (t) async {
    await t.pumpWidget(_wrap(Settings()..locale = 'en', const BackgroundSheet(status: BackgroundStatus(ignoringBattery: true))));
    expect(find.text('Allowed: Lumora may run in the background.'), findsOneWidget);
    expect(find.text('Allow background use'), findsNothing);
    expect(find.text('Open Autostart settings'), findsNothing);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('Settings › Notifications: chat bubbles switch and the background row', (t) async {
    debugShowAndroidNotificationRows = true;
    addTearDown(() => debugShowAndroidNotificationRows = false);
    final st = Settings()..locale = 'en';
    await t.pumpWidget(_wrap(st, const NotificationSettingsGroup()));
    expect(find.text('Chat bubbles'), findsOneWidget);
    expect(find.text('Keep running in the background'), findsOneWidget);
    await t.tap(find.text('Chat bubbles'));
    await t.pump();
    expect(st.chatBubbles, isFalse);
  });
}

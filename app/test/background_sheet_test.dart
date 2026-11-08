// Android "keep running in the background" sheet (first run + Settings ›
// Notifications) and the chat-bubbles switch.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/platform/android_bridge.dart';
import 'package:lumora/state/settings.dart';
import 'package:lumora/ui/settings/background_sheet.dart';
import 'package:lumora/ui/settings/settings_screen.dart';
import 'package:lumora/ui/theme.dart';
import 'package:provider/provider.dart';

import 'helpers.dart';

Widget _wrap(Settings st, Widget child) => ChangeNotifierProvider.value(
      value: st,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: Scaffold(body: SingleChildScrollView(child: child))),
    );

void main() {
  setUpAll(loadFonts);

  testWidgets('Xiaomi, still restricted: both steps with their buttons (vi)', (t) async {
    await t.pumpWidget(_wrap(Settings()..locale = 'vi', const BackgroundSheet(status: BackgroundStatus(ignoringBattery: false, oem: 'xiaomi', autostart: true))));
    expect(find.text('Cho phép chạy nền'), findsOneWidget);
    expect(find.text('Mở cài đặt Tự khởi chạy'), findsOneWidget);
    expect(find.textContaining('Xiaomi, Redmi, POCO'), findsOneWidget);
    expect(find.text('Để sau'), findsOneWidget);
  });

  testWidgets('Xiaomi, calls + bubbles still blocked: one-tap "Cấp quyền" steps, then ticked (vi)', (t) async {
    t.view.physicalSize = const Size(1080, 2600);
    t.view.devicePixelRatio = 2.5;
    addTearDown(t.view.reset);
    final key = GlobalKey();
    await t.pumpWidget(_wrap(
      Settings()..locale = 'vi',
      RepaintBoundary(
        key: key,
        child: const BackgroundSheet(
          status: BackgroundStatus(ignoringBattery: false, oem: 'xiaomi', autostart: true),
          bubblesBlocked: (fullScreen: false, xiaomi: true, popups: false),
        ),
      ),
    ));
    expect(find.text('Cuộc gọi khi máy đang khoá'), findsOneWidget);
    expect(find.text('Bong bóng chat và màn hình khoá'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Cấp quyền'), findsNWidgets(2));
    expect(find.textContaining('Hiển thị trên màn hình khoá'), findsOneWidget);
    await t.runAsync(() async {
      final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 2);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File('screenshots/narrow/permissions_sheet_xiaomi.png')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    });
  });

  testWidgets('Xiaomi, live: autostart ticks once on; the pop-ups step names what is still off', (t) async {
    t.view.physicalSize = const Size(1080, 2600);
    t.view.devicePixelRatio = 2.5;
    addTearDown(t.view.reset);
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var details = {'autostart': false, 'overlay': true, 'bgPopups': false, 'lockScreen': false};
    m.setMockMethodCallHandler(const MethodChannel('lumora/service'), (c) async => c.method == 'background' ? {'ignoring': true, 'oem': 'xiaomi', 'autostart': true} : null);
    m.setMockMethodCallHandler(const MethodChannel('lumora/popups'), (c) async => switch (c.method) {
          'status' => {'fullScreen': true, 'xiaomi': true, 'popups': details.values.skip(1).every((v) => v)},
          'details' => details,
          _ => null,
        });
    AndroidBridge.debugIsAndroid = true;
    addTearDown(() {
      AndroidBridge.debugIsAndroid = null;
      m.setMockMethodCallHandler(const MethodChannel('lumora/service'), null);
      m.setMockMethodCallHandler(const MethodChannel('lumora/popups'), null);
    });
    // to the system settings and back (the lifecycle steps Flutter expects)
    void awayAndBack() {
      for (final st in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused, AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        t.binding.handleAppLifecycleStateChanged(st);
      }
    }

    await t.pumpWidget(_wrap(Settings()..locale = 'vi', const BackgroundSheet()));
    await t.pumpAndSettle();
    expect(find.text('Mở cài đặt Tự khởi chạy'), findsOneWidget);
    expect(find.textContaining('Còn tắt: "Hiển thị cửa sổ bật lên khi chạy trong nền", "Hiển thị trên màn hình khoá"'), findsOneWidget);
    // back from the settings with autostart and one more switch on
    details = {'autostart': true, 'overlay': true, 'bgPopups': true, 'lockScreen': false};
    awayAndBack();
    await t.pumpAndSettle();
    expect(find.text('Mở cài đặt Tự khởi chạy'), findsNothing);
    expect(find.textContaining('Lumora tự chạy lại'), findsOneWidget);
    expect(find.textContaining('Còn tắt: "Hiển thị trên màn hình khoá"'), findsOneWidget);
    // the last one: ticked
    details = {'autostart': true, 'overlay': true, 'bgPopups': true, 'lockScreen': true};
    awayAndBack();
    await t.pumpAndSettle();
    expect(find.textContaining('Bong bóng chat và cuộc gọi trên màn hình khoá đã sẵn sàng'), findsOneWidget);
    expect(find.text('Xong'), findsOneWidget);
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
    expect(st.chatBubbles, isTrue, reason: 'on by default');
    await t.tap(find.text('Chat bubbles'));
    await t.pump();
    expect(st.chatBubbles, isFalse);
    await t.tap(find.text('Chat bubbles'));
    await t.pump();
    expect(st.chatBubbles, isTrue);
  });

  test('chat bubbles: stored under chat_bubbles3 — the old stopgap "off" (chat_bubbles2) does not stick', () async {
    final dir = await Directory.systemTemp.createTemp('lumora_settings');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/settings.json');
    await f.writeAsString(jsonEncode({'chat_bubbles2': false}));
    final st = await Settings.load(f);
    expect(st.chatBubbles, isTrue);
    expect(st.toJson()['chat_bubbles3'], isTrue);
    expect(st.toJson().containsKey('chat_bubbles2'), isFalse);
    await f.writeAsString(jsonEncode({'chat_bubbles3': false}));
    expect((await Settings.load(f)).chatBubbles, isFalse);
  });
}

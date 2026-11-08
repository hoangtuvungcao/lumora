// Bot Studio → /mybots: the bot card opens the bot's chat (avatar / name / "Nhắn tin")
// and its @name·tag is copied on tap. Screenshot: screenshots/bot_card.png.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/ui/bots/botfather.dart';

import 'helpers.dart';

Future<void> _flush(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await settle(t);
}

void main() {
  setUpAll(loadFonts);

  testWidgets('bot card: tap @name copies it, "Nhắn tin" opens the bot chat', (t) async {
    setSize(t, const Size(520, 900));
    final sv = await makeServices(t, theme: ThemeMode.light);
    String? clip;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clip = (call.arguments as Map)['text'] as String?;
      return null;
    });
    final key = GlobalKey();
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: RepaintBoundary(key: key, child: const BotFatherChat(embedded: true))));
    await _flush(t);
    await t.enterText(find.byType(TextField).last, '/mybots');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await _flush(t);
    await _flush(t);

    final handle = find.text('@weather_bot·z5n7jy');
    expect(handle, findsOneWidget);
    await t.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      File('screenshots/bot_card.png')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    });

    await t.tap(handle);
    await _flush(t);
    expect(clip, '@weather_bot·z5n7jy');
    expect(sv.nav.conv ?? '', isNot(startsWith('d:')), reason: 'copying the @name does not open the chat');

    await t.tap(find.widgetWithText(ActionChip, 'Nhắn tin'));
    await _flush(t);
    final bot = sv.contacts.byPeer.values.firstWhere((c) => c.isBot && c.name == 'Thời tiết Bot');
    expect(sv.nav.conv, 'd:${bot.peer}');

    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(t);
  });
}

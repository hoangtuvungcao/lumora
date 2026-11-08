// The bundled 3D sticker pack: every image is there, Vietnamese/English search, the tab
// in the sticker panel sends the image file.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/settings.dart';
import 'package:lumora/ui/chats/builtin_sticker_pack.dart';
import 'package:lumora/ui/chats/stickers.dart';
import 'package:lumora/ui/theme.dart';
import 'package:provider/provider.dart';

import 'helpers.dart';

void main() {
  setUpAll(loadFonts);
  setUp(() {
    final tmp = Directory.systemTemp.createTempSync('lumora_st3d');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
  });

  test('500–1000 stickers, every image bundled', () {
    final all = BuiltinStickers.all;
    expect(all.length, inInclusiveRange(500, 1000));
    for (final s in all) {
      expect(File(s.asset).existsSync(), isTrue, reason: s.asset);
    }
    expect(all.first.emoji, '😀', reason: 'emoji picker order: smileys first');
    expect(all.map((s) => s.key).toSet().length, all.length);
  });

  test('search: Vietnamese (with or without marks) and English', () {
    List<String> top(String q, [int n = 8]) => BuiltinStickers.search(q).take(n).map((s) => s.emoji).toList();
    expect(top('cười'), contains('😂'));
    expect(top('cuoi'), contains('😂'));
    expect(top('mèo').any((e) => e.contains('🐱') || e.contains('🐈')), isTrue);
    expect(top('tim', 30), contains('❤️'));
    expect(top('laugh'), contains('😂'));
    expect(top('dog').any((e) => e.contains('🐶') || e.contains('🐕')), isTrue);
    expect(BuiltinStickers.search('zzzqqq'), isEmpty);
    expect(BuiltinStickers.search(''), hasLength(BuiltinStickers.all.length));
  });

  testWidgets('sticker panel: 3D tab first, search, tap sends the file', (t) async {
    final sent = <(String, String)>[];
    final api = MockLumoraApi();
    await t.pumpWidget(MultiProvider(
      providers: [Provider<LumoraApi>.value(value: api), ChangeNotifierProvider(create: (_) => Settings())],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            height: 420,
            child: StickerPanel(onSend: (_) {}, onSendFile: (path, emoji) async => sent.add((path, emoji))),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('pack_3d')), findsOneWidget);
    expect(find.byKey(const ValueKey('sticker_search')), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('sticker_search')), 'cười');
    await t.pump();
    final first = BuiltinStickers.search('cười').first;
    await t.runAsync(() async {
      await t.tap(find.byKey(ValueKey('sticker3d_${first.key}')));
      for (var i = 0; i < 50 && sent.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(sent, hasLength(1));
    expect(sent.single.$1, endsWith('${first.key}.webp'));
    expect(File(sent.single.$1).lengthSync(), greaterThan(500));
    expect(sent.single.$2, first.emoji);
  });

  testWidgets('my pack: "send this pack to the chat" exports it and hands the file over', (t) async {
    final api = MockLumoraApi();
    final shared = <String>[];
    await t.runAsync(() async {
      final id = await api.stickerPackCreate('Mèo nhà');
      await api.stickerAdd(id, '/tmp/cat.png');
    });
    await t.pumpWidget(MultiProvider(
      providers: [Provider<LumoraApi>.value(value: api), ChangeNotifierProvider(create: (_) => Settings())],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            height: 420,
            child: StickerPanel(onSend: (_) {}, onSendFile: (_, _) async {}, onSharePack: (path) async => shared.add(path)),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    await t.tap(find.text('Mèo nhà'));
    await t.pump(const Duration(milliseconds: 300)); // (its sticker keeps loading: no settle)
    await t.tap(find.byType(PopupMenuButton<String>));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100)); // the menu's opening animation
    }
    await t.tap(find.text('Gửi bộ này vào cuộc trò chuyện'));
    await t.pump(const Duration(milliseconds: 100));
    await t.runAsync(() async {
      for (var i = 0; i < 50 && shared.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(shared, hasLength(1));
    expect(shared.single, endsWith('Mèo nhà.lumora-stickers'));
  });
}

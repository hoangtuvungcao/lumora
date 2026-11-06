// Emoji catalog, search, picker UX and animated emoji (incl. perf numbers).
// Run: flutter test test/emoji_picker_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:lumora/state/settings.dart';
import 'package:lumora/ui/chats/animated_emoji.dart';
import 'package:lumora/ui/chats/animated_emoji_set.dart';
import 'package:lumora/ui/chats/emoji_catalog.dart';
import 'package:lumora/ui/chats/emoji_data.dart';
import 'package:lumora/ui/chats/emoji_picker.dart';
import 'package:lumora/ui/theme.dart';
import 'package:provider/provider.dart';

import 'helpers.dart';

Widget _host(Settings st, Widget child, {Size size = const Size(390, 700)}) => ChangeNotifierProvider.value(
      value: st,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: SizedBox(width: size.width, child: child))),
      ),
    );

List<String> _top(String q, [int n = 5]) => EmojiCatalog.instance.search(q).take(n).map((e) => e.char).toList();

void main() {
  setUpAll(loadFonts);

  group('catalog', () {
    test('full Unicode 15.1 set, lazily parsed', () {
      expect(EmojiCatalog.isLoaded, isFalse, reason: 'nothing parses the catalog before first use');
      final c = EmojiCatalog.instance;
      // ignore: avoid_print
      print('catalog parse: ${c.parseMicros} µs for ${c.all.length} emoji');
      expect(kEmojiUnicodeVersion, '15.1');
      expect(c.all.length, kEmojiCount);
      expect(c.all.length, greaterThan(1850));
      expect(c.groups.map((g) => g.key), [
        'emoji_smileys', 'emoji_people', 'emoji_animals', 'emoji_food', 'emoji_travel',
        'emoji_activity', 'emoji_objects', 'emoji_symbols', 'emoji_flags',
      ]);
      expect(c.all.where((e) => e.tones).length, greaterThan(300));
      expect(c.isEmoji('🇻🇳'), isTrue);
      expect(c.isEmoji('🫨'), isTrue); // 15.0
      expect(c.isEmoji('🙂‍↔️'), isTrue); // 15.1
      expect(c.isEmoji('a'), isFalse);
    });

    test('skin tones follow Unicode sequences', () {
      final c = EmojiCatalog.instance;
      expect(c.lookup('👋')!.withTone(3), '👋🏽');
      expect(c.lookup('✌️')!.withTone(1), '✌🏻'); // FE0F dropped
      expect(c.lookup('🕵️‍♂️')!.withTone(5), '🕵🏿‍♂️');
      expect(c.lookup('🧑‍🤝‍🧑')!.withTone(2), '🧑🏼‍🤝‍🧑🏼');
      expect(c.lookup('👩‍❤️‍👨')!.withTone(4), '👩🏾‍❤️‍👨🏾');
      expect(c.lookup('👍🏿')!.char, '👍');
      expect(EmojiCatalog.toneOf('👍🏾'), 4);
      expect(c.lookup('😀')!.tones, isFalse);
      // Every tone variant is itself a known emoji form.
      for (final e in c.all.where((e) => e.tones)) {
        for (var t = 1; t <= 5; t++) {
          expect(c.lookup(e.withTone(t)), same(e));
        }
      }
    });

    test('fold removes Vietnamese diacritics', () {
      expect(EmojiCatalog.fold('Cười'), 'cuoi');
      expect(EmojiCatalog.fold('  Đèn LỒNG!! '), 'den long');
      expect(EmojiCatalog.fold('trà sữa'), 'tra sua');
    });
  });

  group('search', () {
    test('Vietnamese with and without diacritics, English', () {
      expect(_top('cuoi'), contains('😂'));
      expect(_top('cười').first, '😂');
      expect(_top('cưới', 2), contains('💒'), reason: 'diacritics disambiguate laugh vs wedding');
      expect(_top('cuoi', 3), isNot(contains('💒')));
      expect(_top('chó', 2), contains('🐶'));
      expect(_top('tim').first, '❤️');
      expect(_top('yeu', 3), contains('😍'));
      expect(_top('buon', 3), contains('😢'));
      expect(_top('khoc', 2), contains('😭'));
      expect(_top('cam on').first, '🙏');
      expect(_top('chuc mung', 3), contains('🎉'));
      expect(_top('sinh nhật').first, '🎂');
      expect(_top('cà phê').first, '☕');
      expect(_top('tra sua').first, '🧋');
      expect(_top('pho').first, '🍜');
      expect(_top('banh mi').first, '🥖');
      expect(_top('meo', 3), contains('🐱'));
      expect(_top('cho', 8), contains('🐶'));
      expect(_top('mua', 3), contains('🌧️'));
      expect(_top('nang', 3), contains('☀️'));
      expect(_top('tet', 3), contains('🧧'));
      expect(_top('li xi').first, '🧧');
      expect(_top('den long').first, '🏮');
      expect(_top('hoa mai', 3), contains('🌼'));
      expect(_top('co viet nam').first, '🇻🇳');
      expect(_top('ok', 3), contains('👌'));
      expect(_top('like').first, '👍');
      expect(_top('thumbs up').first, '👍');
      expect(_top('grinning', 3), contains('😀'));
      expect(_top('rocket').first, '🚀');
      expect(EmojiCatalog.instance.search('zzqqxx'), isEmpty);
    });

    test('usage boosts favourites', () {
      final plain = _top('cuoi', 12);
      final boosted = EmojiCatalog.instance.search('cuoi', usage: {'😹': 40}).take(3).map((e) => e.char);
      expect(plain.indexOf('😹'), greaterThan(2));
      expect(boosted, contains('😹'));
    });

    test('names in both languages', () {
      final c = EmojiCatalog.instance;
      expect(c.nameOf(c.lookup('🧧')!, vi: true), 'bao lì xì');
      expect(c.nameOf(c.lookup('🧧')!, vi: false), 'red envelope');
      expect(c.nameOf(c.lookup('🇻🇳')!, vi: true), 'cờ: Việt Nam');
    });
  });

  group('jumbo', () {
    test('1-3 emoji only', () {
      expect(jumboEmojis('😂'), ['😂']);
      expect(jumboEmojis(' 😂 ❤️ '), ['😂', '❤️']);
      expect(jumboEmojis('👍🏽🇻🇳👨‍👩‍👧'), ['👍🏽', '🇻🇳', '👨‍👩‍👧']);
      expect(jumboEmojis('😂😂😂😂'), isNull);
      expect(jumboEmojis('haha 😂'), isNull);
      expect(jumboEmojis('©'), isNull);
      expect(jumboEmojis('1'), isNull);
      expect(jumboEmojis('你好'), isNull);
    });
  });

  group('picker', () {
    testWidgets('opens fast, scroll-synced tabs, search "cuoi"', (t) async {
      final st = Settings();
      final picked = <String>[];
      final sw = Stopwatch()..start();
      await t.pumpWidget(_host(st, EmojiPicker(height: 420, showStickers: false, onPick: picked.add)));
      final firstFrame = sw.elapsedMilliseconds;
      // ignore: avoid_print
      print('picker first open (catalog parse + first frame, debug mode): $firstFrame ms');
      expect(firstFrame, lessThan(3000));
      await t.pump();
      // Re-open (catalog cached, code warmed up): what users feel after the first time.
      await t.pumpWidget(const SizedBox());
      final warm = Stopwatch()..start();
      await t.pumpWidget(_host(st, EmojiPicker(height: 420, showStickers: false, onPick: picked.add)));
      // ignore: avoid_print
      print('picker re-open first frame: ${warm.elapsedMilliseconds} ms');
      expect(warm.elapsedMilliseconds, lessThan(400));
      await t.pump();

      // 8 columns on a phone, >= 44 px cells.
      expect(emojiColumns(390, desktop: false), 8);
      expect(emojiColumns(468, desktop: true), 10);
      expect(emojiColumns(420, desktop: true), 9);
      final cell = t.getSize(find.text('😀').first);
      expect(cell.width, greaterThanOrEqualTo(20));

      // Tab -> section.
      await t.tap(find.byTooltip('Cờ'));
      await t.pumpAndSettle();
      expect(find.text('🏁'), findsOneWidget);
      expect(find.text('CỜ'), findsOneWidget);

      // Search without diacritics.
      await t.enterText(find.byType(TextField), 'cuoi');
      await t.pump();
      expect(find.text('KẾT QUẢ'), findsOneWidget);
      expect(find.text('😂'), findsOneWidget);
      await t.tap(find.text('😂'));
      expect(picked, ['😂']);
      expect(st.recentEmojis.first, '😂');
      expect(st.emojiUsage['😂'], 1);
    });

    testWidgets('long-press shows skin tones and remembers the choice', (t) async {
      final st = Settings();
      final picked = <String>[];
      await t.pumpWidget(_host(st, EmojiPicker(height: 420, showStickers: false, onPick: picked.add)));
      await t.enterText(find.byType(TextField), 'waving hand');
      await t.pump();
      await t.longPress(find.text('👋'));
      await t.pumpAndSettle();
      for (final v in ['👋🏻', '👋🏼', '👋🏽', '👋🏾', '👋🏿']) {
        expect(find.text(v), findsOneWidget);
      }
      await t.tap(find.text('👋🏽'));
      await t.pumpAndSettle();
      expect(picked, ['👋🏽']);
      expect(st.emojiTone, 3);
      // The grid now shows the remembered tone.
      expect(find.text('👋🏽'), findsOneWidget);
    });

    testWidgets('recent: top 32, frequent ordering', (t) async {
      final st = Settings();
      for (var i = 0; i < 40; i++) {
        st.pushRecentEmoji(EmojiCatalog.instance.all[i].char);
      }
      expect(st.recentEmojis.length, kRecentEmojiMax);
      st.pushRecentEmoji('🔥');
      st.pushRecentEmoji('🔥');
      st.pushRecentEmoji('🔥');
      st.pushRecentEmoji('😀');
      st.emojiFrequentFirst = true;
      await t.pumpWidget(_host(st, EmojiPicker(height: 420, showStickers: false, onPick: (_) {})));
      await t.pump();
      expect(find.text('Hay dùng'), findsOneWidget);
      // First cell of the first section is the most used.
      final firstCell = find.descendant(of: find.byType(SliverGrid).first, matching: find.byType(Text)).first;
      expect((t.widget<Text>(firstCell)).data, '🔥');
    });

    testWidgets('keyboard navigation (desktop)', (t) async {
      final st = Settings()..recentEmojis = ['👍', '❤️', '😂'];
      final picked = <String>[];
      setSize(t, const Size(1200, 800));
      await t.pumpWidget(_host(st, EmojiPicker(height: 430, showStickers: false, autofocusSearch: true, onPick: picked.add), size: const Size(468, 430)));
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown); // into the grid
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      expect(find.text('Mặt cười với nước mắt vui sướng'), findsOneWidget, reason: 'preview bar shows the name');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(picked, ['😂']);
      // Down from the recent row lands in the smileys section, same column.
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(picked.last, EmojiCatalog.instance.groups.first.emojis[2].char);
      // Typing goes to search; Enter picks the best match.
      await t.sendKeyEvent(LogicalKeyboardKey.keyT);
      await t.pump();
      final field = t.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 't');
      expect(field.focusNode!.hasFocus, isTrue);
      await t.enterText(find.byType(TextField), 'tim');
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(picked.last, '❤️');
      resetSize(t);
    });
  });

  group('animated emoji', () {
    test('curated set is bundled', () {
      expect(kAnimatedEmojiKeys.length, inInclusiveRange(80, 130));
      for (final e in ['😂', '❤️', '👍', '🎉', '🔥', '😭', '🥳', '🙏', '🎆', '🐉']) {
        expect(AnimatedEmojiLibrary.has(e), isTrue, reason: e);
      }
      expect(AnimatedEmojiLibrary.has('👍🏽'), isFalse); // toned: static glyph
    });

    testWidgets('loads, loops while visible, caps concurrency; frame cost', (t) async {
      AnimatedEmojiLibrary.reset();
      final st = Settings();
      final emojis = ['😂', '❤️', '👍', '🎉', '🔥', '😭', '🥳', '🙏'];
      LottieComposition? c;
      final load = Stopwatch()..start();
      await t.runAsync(() async {
        for (final e in emojis) {
          c = await AnimatedEmojiLibrary.load(AnimatedEmojiLibrary.keyOf(e)!);
        }
      });
      // ignore: avoid_print
      print('decode + parse 8 animations: ${load.elapsedMilliseconds} ms');
      expect(c, isNotNull);
      expect(c!.duration, greaterThan(Duration.zero));

      await t.pumpWidget(_host(
        st,
        Wrap(children: [for (final e in emojis) JumboEmoji(emojis: [e])]),
        size: const Size(390, 700),
      ));
      await t.pump();
      await t.pump();
      // 8 visible, 6 allowed at once; the others stay as static glyphs.
      expect(AnimatedEmojiLibrary.playing, AnimatedEmojiLibrary.maxConcurrent);
      expect(find.byType(Lottie), findsNWidgets(AnimatedEmojiLibrary.maxConcurrent));

      // UI-thread cost of a frame with 6 animations running (build/layout/paint
      // recording; rasterisation happens on the raster thread).
      final frames = <int>[];
      for (var i = 0; i < 60; i++) {
        final f = Stopwatch()..start();
        await t.pump(const Duration(milliseconds: 16));
        frames.add(f.elapsedMicroseconds);
      }
      frames.sort();
      // ignore: avoid_print
      print('frame with 6 animations: median ${frames[30] / 1000} ms, p90 ${frames[54] / 1000} ms (debug, test renderer)');

      // Big emoji in messages keep moving while on screen...
      await t.pump(const Duration(seconds: 10));
      await t.pump(const Duration(milliseconds: 16));
      expect(AnimatedEmojiLibrary.playing, AnimatedEmojiLibrary.maxConcurrent);
      // ...and release their slots once they leave it.
      await t.pumpWidget(_host(st, const SizedBox(), size: const Size(390, 700)));
      await t.pump(const Duration(milliseconds: 16));
      expect(AnimatedEmojiLibrary.playing, 0);
      expect(find.byType(Lottie), findsNothing, reason: 'idle = static glyph, nothing to repaint');
      final idle = <int>[];
      for (var i = 0; i < 30; i++) {
        final f = Stopwatch()..start();
        await t.pump(const Duration(milliseconds: 16));
        idle.add(f.elapsedMicroseconds);
      }
      idle.sort();
      // ignore: avoid_print
      print('same screen idle: median ${idle[15] / 1000} ms');
    });

    // EMOJI_FRAMES=1 flutter test test/emoji_picker_test.dart --plain-name frames
    // writes build/emoji_frames/*.png (assembled into screenshots/94_animated_emoji.gif).
    testWidgets('frames', (t) async {
      if (!Platform.environment.containsKey('EMOJI_FRAMES')) return;
      AnimatedEmojiLibrary.reset();
      setSize(t, const Size(520, 150));
      final st = Settings();
      const row = ['😂', '🥳', '❤️', '🔥', '🎉'];
      await t.runAsync(() async {
        for (final e in row) {
          await AnimatedEmojiLibrary.load(AnimatedEmojiLibrary.keyOf(e)!);
        }
      });
      final key = GlobalKey();
      await t.pumpWidget(ChangeNotifierProvider.value(
        value: st,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: LC.darkBg,
              child: Center(child: Row(mainAxisSize: MainAxisSize.min, children: [for (final e in row) AnimatedEmoji(e, size: 96, loop: true)])),
            ),
          ),
        ),
      ));
      await t.pump();
      await t.pump();
      final dir = Directory('build/emoji_frames')..createSync(recursive: true);
      for (var i = 0; i < 36; i++) {
        await t.runAsync(() async {
          final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final img = await b.toImage();
          final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
          img.dispose();
          File('${dir.path}/f${i.toString().padLeft(3, '0')}.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        });
        await t.pump(const Duration(milliseconds: 66));
      }
      await t.pumpWidget(const SizedBox());
      resetSize(t);
    });

    testWidgets('off in settings or with reduced motion: static glyph', (t) async {
      final st = Settings()..animatedEmoji = false;
      await t.pumpWidget(_host(st, const JumboEmoji(emojis: ['😂'])));
      await t.pump();
      expect(find.byType(Lottie), findsNothing);
      expect(find.text('😂'), findsOneWidget);

      st.animatedEmoji = true;
      await t.pumpWidget(_host(
        st,
        const MediaQuery(data: MediaQueryData(disableAnimations: true), child: JumboEmoji(emojis: ['😂'])),
      ));
      await t.pump();
      expect(find.byType(Lottie), findsNothing);
    });
  });
}

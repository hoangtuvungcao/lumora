// The bundled 3D sticker pack (Fluent Emoji 3D, (c) Microsoft, MIT): ~880 stickers in
// assets/stickers3d/ (tool/fetch_fluent_stickers.py), searchable in Vietnamese and English
// through the emoji catalog's index plus Fluent's own English keywords.
//
// A sticker sent from here travels inside the message (core `send_sticker` with `path`)
// like a custom one, so every Lumora version shows it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import 'builtin_stickers.dart';
import 'emoji_catalog.dart';

class BuiltinSticker {
  const BuiltinSticker(this.key, this.emoji, this.group, this.words);
  final String key;
  final String emoji;
  final int group;

  /// English words, folded (lowercase, no marks).
  final List<String> words;

  String get asset => 'assets/stickers3d/$key.webp';

  bool get animated => kBuiltinStickerAnimated.contains(key);
}

abstract final class BuiltinStickers {
  static List<BuiltinSticker>? _all;

  /// Every sticker: the animated ones first, then the emoji picker's order (smileys first).
  static List<BuiltinSticker> get all => _all ??= () {
    final cat = EmojiCatalog.instance;
    final out = <BuiltinSticker>[];
    for (final line in kBuiltinStickerData.split('\n')) {
      final p = line.split('|');
      if (p.length < 4) continue;
      out.add(BuiltinSticker(p[1], p[2], int.tryParse(p[0]) ?? 0, [for (final w in p[3].split(',')) EmojiCatalog.fold(w)]));
    }
    int order(BuiltinSticker s) => (s.animated ? 0 : 1 << 21) + (cat.lookup(s.emoji)?.index ?? 1 << 20);
    out.sort((a, b) => order(a).compareTo(order(b)));
    return out;
  }();

  static String _bare(String e) => String.fromCharCodes(e.runes.where((r) => r != 0xFE0F));

  /// Stickers matching [query] (Vietnamese or English, with or without diacritics), best first.
  static List<BuiltinSticker> search(String query) {
    final q = EmojiCatalog.fold(query);
    if (q.isEmpty) return all;
    final byEmoji = {for (final s in all) _bare(s.emoji): s};
    final seen = <String>{};
    final out = <BuiltinSticker>[];
    // the emoji index knows the Vietnamese terms ("cười", "mèo", "cảm ơn")
    for (final e in EmojiCatalog.instance.search(query, limit: 400)) {
      final s = byEmoji[_bare(e.char)];
      if (s != null && seen.add(s.key)) out.add(s);
    }
    final tokens = q.split(' ');
    for (final s in all) {
      if (seen.contains(s.key)) continue;
      if (tokens.every((t) => s.words.any((w) => w.split(' ').any((x) => x.startsWith(t))))) {
        seen.add(s.key);
        out.add(s);
      }
    }
    return out;
  }

  /// The sticker's image as a file the core can read.
  static Future<String> fileOf(BuiltinSticker s) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}stickers3d');
    final f = File('${dir.path}${Platform.pathSeparator}${s.key}.webp');
    if (!f.existsSync()) {
      await dir.create(recursive: true);
      final data = await rootBundle.load(s.asset);
      await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return f.path;
  }
}

/// The 3D pack: a search field and the grid. [onSend] gets the image file and its emoji.
class BuiltinStickerGrid extends StatefulWidget {
  const BuiltinStickerGrid({super.key, required this.onSend});
  final Future<void> Function(String path, String emoji) onSend;

  @override
  State<BuiltinStickerGrid> createState() => _BuiltinStickerGridState();
}

class _BuiltinStickerGridState extends State<BuiltinStickerGrid> {
  final _q = TextEditingController();
  List<BuiltinSticker> _items = BuiltinStickers.all;
  bool _sending = false;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _send(BuiltinSticker s) async {
    if (_sending) return;
    _sending = true;
    try {
      await widget.onSend(await BuiltinStickers.fileOf(s), s.emoji);
    } finally {
      _sending = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
        child: SizedBox(
          height: 38,
          child: TextField(
            key: const ValueKey('sticker_search'),
            controller: _q,
            onChanged: (v) => setState(() => _items = BuiltinStickers.search(v)),
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              hintText: s('sticker_search_hint'),
              prefixIcon: Icon(AppIcons.search, size: 18, color: context.lc.muted),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ),
      ),
      Expanded(
        child: _items.isEmpty
            ? Center(child: Text(s('sticker_search_none'), style: TextStyle(color: context.lc.muted)))
            : GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 84, mainAxisSpacing: 6, crossAxisSpacing: 6),
                itemCount: _items.length,
                itemBuilder: (context, i) {
                  final st = _items[i];
                  return InkWell(
                    key: ValueKey('sticker3d_${st.key}'),
                    borderRadius: BorderRadius.circular(Radii.md),
                    onTap: () => _send(st),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Image.asset(st.asset, cacheWidth: 160, filterQuality: FilterQuality.medium, gaplessPlayback: true, errorBuilder: (_, _, _) => Center(child: Text(st.emoji, style: const TextStyle(fontSize: 40)))),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}

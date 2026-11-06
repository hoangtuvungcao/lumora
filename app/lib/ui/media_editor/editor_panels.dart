// Secondary editor panels: colour palette, size picker, the text entry
// overlay and the emoji / sticker picker.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../chats/emoji_data.dart';
import '../chats/stickers.dart' show StickerImage;
import '../theme.dart';
import 'edit_state.dart';
import 'editor_icons.dart';

const kEditorColors = <Color>[
  Color(0xFFFFFFFF),
  Color(0xFF111111),
  LC.primary,
  LC.accent,
  Color(0xFFEF4444),
  Color(0xFFF59E0B),
  Color(0xFFFACC15),
  LC.success,
  Color(0xFFEC4899),
];

class ColorPalette extends StatelessWidget {
  const ColorPalette({super.key, required this.value, required this.onChanged});
  final Color value;
  final ValueChanged<Color> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final c in kEditorColors)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: InkResponse(
              key: ValueKey('pe-color-${c.toARGB32().toRadixString(16)}'),
              onTap: () => onChanged(c),
              radius: 20,
              child: AnimatedContainer(
                duration: Motion.fast,
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(color: c.toARGB32() == value.toARGB32() ? Colors.white : Colors.white24, width: c.toARGB32() == value.toARGB32() ? 3 : 1.5),
                  boxShadow: c.toARGB32() == value.toARGB32() ? [BoxShadow(color: c.withValues(alpha: 0.6), blurRadius: kNoShadows ? 0 : 8)] : null,
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Three brush sizes shown as dots.
class SizeDots extends StatelessWidget {
  const SizeDots({super.key, required this.index, required this.onChanged, this.color = Colors.white});
  final int index;
  final ValueChanged<int> onChanged;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < 3; i++)
        Tooltip(
          message: '${s('pe_size')} ${i + 1}',
          child: InkResponse(
            onTap: () => onChanged(i),
            radius: 18,
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, color: i == index ? Colors.white.withValues(alpha: 0.16) : null),
              child: Container(
                width: 6.0 + i * 6,
                height: 6.0 + i * 6,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color == const Color(0xFF111111) ? Colors.white70 : color),
              ),
            ),
          ),
        ),
    ]);
  }
}

/// Segmented pill used for pen/highlighter, pixelate/blur.
class EditorSegment<T> extends StatelessWidget {
  const EditorSegment({super.key, required this.value, required this.options, required this.onChanged});
  final T value;
  final List<(T, IconData, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(Radii.xl)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final (v, icon, label) in options)
          InkWell(
            borderRadius: BorderRadius.circular(Radii.xl),
            onTap: () => onChanged(v),
            child: AnimatedContainer(
              duration: Motion.fast,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(color: v == value ? LC.primary : null, borderRadius: BorderRadius.circular(Radii.xl)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 16, color: Colors.white),
                const SizedBox(width: 6),
                Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ text entry

/// Full-screen text entry over the dimmed photo. Returns the edited item via
/// [onDone] (null text = delete).
class TextEntryOverlay extends StatefulWidget {
  const TextEntryOverlay({super.key, required this.item, required this.onDone});
  final OverlayItem item;
  final ValueChanged<OverlayItem> onDone;

  @override
  State<TextEntryOverlay> createState() => _TextEntryOverlayState();
}

class _TextEntryOverlayState extends State<TextEntryOverlay> {
  late final _c = TextEditingController(text: widget.item.text);
  late Color _color = widget.item.color;
  late TextBg _bg = widget.item.bg;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _done() => widget.onDone(widget.item.copyWith(text: _c.text.trim(), color: _color, bg: _bg));

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final solid = _bg == TextBg.solid, translucent = _bg == TextBg.translucent;
    final fg = solid ? (_color.computeLuminance() > 0.6 ? const Color(0xFF111111) : Colors.white) : _color;
    final style = TextStyle(
      fontFamily: kFontFamily,
      fontFamilyFallback: kFontFallback,
      fontWeight: FontWeight.w700,
      fontSize: 30,
      height: 1.22,
      color: fg,
      shadows: _bg == TextBg.plain ? [Shadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: 6)] : null,
    );
    final field = TextField(
      key: const ValueKey('pe-text-field'),
      controller: _c,
      autofocus: true,
      maxLines: null,
      textAlign: TextAlign.center,
      cursorColor: solid ? fg : LC.accent,
      style: style,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        isCollapsed: true,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        hintText: s('pe_text_hint'),
        hintStyle: style.copyWith(color: Colors.white38, shadows: const []),
      ),
    );
    return Material(
      color: Colors.black.withValues(alpha: 0.62),
      child: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 0),
            child: Row(children: [
              IconButton(
                tooltip: s('pe_text_style'),
                onPressed: () => setState(() => _bg = TextBg.values[(_bg.index + 1) % TextBg.values.length]),
                icon: _BgStyleIcon(bg: _bg),
              ),
              const Spacer(),
              FilledButton(key: const ValueKey('pe-text-done'), onPressed: _done, child: Text(s('done'))),
            ]),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _done,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: GestureDetector(
                    onTap: () {},
                    child: Container(
                      padding: solid || translucent ? const EdgeInsets.symmetric(horizontal: 16, vertical: 8) : EdgeInsets.zero,
                      decoration: solid || translucent
                          ? BoxDecoration(color: solid ? _color : Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(12))
                          : null,
                      child: IntrinsicWidth(child: ConstrainedBox(constraints: const BoxConstraints(minWidth: 40), child: field)),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: ColorPalette(value: _color, onChanged: (c) => setState(() => _color = c)),
          ),
        ]),
      ),
    );
  }
}

class _BgStyleIcon extends StatelessWidget {
  const _BgStyleIcon({required this.bg});
  final TextBg bg;
  @override
  Widget build(BuildContext context) {
    final box = switch (bg) {
      TextBg.plain => null,
      TextBg.outline => BoxDecoration(border: Border.all(color: Colors.white, width: 1.5), borderRadius: BorderRadius.circular(6)),
      TextBg.solid => BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6)),
      TextBg.translucent => BoxDecoration(color: Colors.white38, borderRadius: BorderRadius.circular(6)),
    };
    return Container(
      width: 28,
      height: 28,
      decoration: box,
      alignment: Alignment.center,
      child: Icon(EditorIcons.textBg, size: 18, color: bg == TextBg.solid ? Colors.black : Colors.white),
    );
  }
}

// ------------------------------------------------------------------ stickers

/// Emoji + the user's sticker packs. Returns (kind, emoji-or-hash).
Future<(OverlayKind, String)?> pickEditorSticker(BuildContext context) async {
  final api = context.read<LumoraApi>();
  List<StickerPack> packs = const [];
  try {
    packs = (await api.stickerPacks()).where((p) => p.stickers.isNotEmpty).toList();
  } catch (_) {}
  if (!context.mounted) return null;
  return showModalBottomSheet<(OverlayKind, String)>(
    context: context,
    isScrollControlled: true,
    backgroundColor: LC.darkSurface,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (c) => SizedBox(height: MediaQuery.sizeOf(c).height * 0.55, child: _StickerSheet(packs: packs)),
  );
}

class _StickerSheet extends StatelessWidget {
  const _StickerSheet({required this.packs});
  final List<StickerPack> packs;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final emojis = [
      for (final (key, raw) in kEmojiGroupData)
        if (key != 'emoji_flags')
          for (final e in raw.split(' '))
            if (e.isNotEmpty) e.endsWith('+') ? e.substring(0, e.length - 1) : e,
    ];
    return DefaultTabController(
      length: 1 + packs.length,
      child: Column(children: [
        TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          dividerColor: Colors.transparent,
          tabs: [
            Tab(icon: const Icon(EditorIcons.emoji, size: 20), text: s('emoji')),
            for (final p in packs) Tab(text: p.name),
          ],
        ),
        Expanded(
          child: TabBarView(children: [
            GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 52),
              itemCount: emojis.length,
              itemBuilder: (c, i) => InkWell(
                borderRadius: BorderRadius.circular(Radii.sm),
                onTap: () => Navigator.pop(c, (OverlayKind.emoji, emojis[i])),
                child: Center(child: Text(emojis[i], style: const TextStyle(fontSize: 30, fontFamilyFallback: kFontFallback))),
              ),
            ),
            for (final p in packs)
              GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 96, mainAxisSpacing: 8, crossAxisSpacing: 8),
                itemCount: p.stickers.length,
                itemBuilder: (c, i) => InkWell(
                  borderRadius: BorderRadius.circular(Radii.md),
                  onTap: () => Navigator.pop(c, (OverlayKind.sticker, p.stickers[i].hash)),
                  child: StickerImage(hash: p.stickers[i].hash, size: 88, fallbackEmoji: p.stickers[i].emoji),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}

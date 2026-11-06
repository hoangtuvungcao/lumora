// Sticker packs (custom images/GIF/WebP via sticker_get), sticker panel,
// "save to pack", import/export, and a meme maker.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/outgoing.dart';
import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// In-memory cache of decoded sticker blobs (bounded).
final Map<String, Future<Uint8List?>> _stickerCache = {};

Future<Uint8List?> _loadSticker(LumoraApi api, String hash) {
  if (_stickerCache.length > 200) _stickerCache.remove(_stickerCache.keys.first);
  return _stickerCache.putIfAbsent(hash, () async {
    try {
      final (_, data) = await api.stickerGet(hash);
      return data.isEmpty ? null : base64Decode(data);
    } catch (_) {
      return null;
    }
  });
}

/// Renders a sticker by hash; GIF/WebP animate automatically.
class StickerImage extends StatelessWidget {
  const StickerImage({super.key, required this.hash, this.size = 150, this.fallbackEmoji = ''});
  final String hash;
  final double size;
  final String fallbackEmoji;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return SizedBox(
      width: size,
      height: size,
      child: FutureBuilder<Uint8List?>(
        future: _loadSticker(context.read<LumoraApi>(), hash),
        builder: (context, snap) {
          final b = snap.data;
          if (b == null) {
            return Center(
              child: snap.connectionState == ConnectionState.done
                  ? (fallbackEmoji.isEmpty
                      ? Icon(AppIcons.imageBroken, size: size * 0.4, color: context.lc.muted)
                      : Text(fallbackEmoji, style: TextStyle(fontSize: size * 0.5)))
                  : const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          return ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(b, fit: BoxFit.contain, cacheWidth: (size * dpr).round(), gaplessPlayback: true),
          );
        },
      ),
    );
  }
}

/// Sticker message body: {hash, emoji, mime, pack, id, animated}.
class StickerBubble extends StatelessWidget {
  const StickerBubble({super.key, required this.message, required this.overlay});
  final Message message;
  final Widget overlay;

  @override
  Widget build(BuildContext context) {
    Map j = const {};
    try {
      final d = jsonDecode(message.body);
      if (d is Map) j = d;
    } catch (_) {}
    final hash = j['hash']?.toString() ?? '';
    final emoji = j['emoji']?.toString() ?? (message.body.length <= 8 ? message.body : '');
    final real = hash.isNotEmpty && hash.replaceAll('0', '').isNotEmpty;
    return Stack(children: [
      real ? StickerImage(hash: hash, fallbackEmoji: emoji) : SizedBox(
              width: 120,
              height: 120,
              child: Center(
                child: emoji.isEmpty
                    ? PhosphorIcon(AppIcons.duotone(AppIcons.sticker), size: 64, color: context.lc.muted)
                    : Text(emoji, style: const TextStyle(fontSize: 72)),
              ),
            ),
      Positioned(right: 4, bottom: 4, child: overlay),
    ]);
  }
}

String? stickerHashOf(Message m) {
  if (m.kind != 'sticker') return null;
  try {
    final d = jsonDecode(m.body);
    if (d is Map) return d['hash']?.toString();
  } catch (_) {}
  return null;
}

/// Long-press on a received sticker → save into one of my packs.
Future<void> saveStickerToPack(BuildContext context, String hash) async {
  final s = S.read(context);
  final api = context.read<LumoraApi>();
  var packs = await api.stickerPacks();
  if (!context.mounted) return;
  if (packs.isEmpty) {
    final name = await promptText(context, title: s('new_pack'), hint: s('pack_name_hint'), action: s('create'));
    if (name == null || name.isEmpty) return;
    await api.stickerPackCreate(name);
    packs = await api.stickerPacks();
    if (!context.mounted) return;
  }
  final id = packs.length == 1
      ? packs.first.id
      : await showModalBottomSheet<String>(
          context: context,
          builder: (c) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final p in packs) ListTile(leading: const Icon(AppIcons.sticker), title: Text(p.name), onTap: () => Navigator.pop(c, p.id)),
            ]),
          ),
        );
  if (id == null) return;
  try {
    await api.stickerSave(hash, id);
    if (context.mounted) toast(context, s('sticker_saved'));
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

/// Sticker tab content: my packs + manage actions; tap sends.
class StickerPanel extends StatefulWidget {
  const StickerPanel({super.key, required this.onSend});
  final void Function(Sticker s) onSend;
  @override
  State<StickerPanel> createState() => _StickerPanelState();
}

class _StickerPanelState extends State<StickerPanel> {
  List<StickerPack>? _packs;
  int _sel = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final p = await context.read<LumoraApi>().stickerPacks();
      if (mounted) setState(() => _packs = p);
    } catch (_) {
      if (mounted) setState(() => _packs = const []);
    }
  }

  Future<void> _create() async {
    final s = S.read(context);
    final api = context.read<LumoraApi>();
    final name = await promptText(context, title: s('new_pack'), hint: s('pack_name_hint'), action: s('create'));
    if (name == null || name.isEmpty) return;
    await api.stickerPackCreate(name);
    await _reload();
    if (mounted) setState(() => _sel = (_packs?.length ?? 1) - 1);
  }

  Future<void> _add(StickerPack p) async {
    final api = context.read<LumoraApi>();
    final r = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif']);
    for (final f in r) {
      if (f.path != null) {
        try {
          await api.stickerAdd(p.id, f.path!);
        } catch (e) {
          if (mounted) toastError(context, e);
        }
      }
    }
    await _reload();
  }

  Future<void> _import() async {
    final api = context.read<LumoraApi>();
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['lumora-stickers']);
    if (f?.path == null) return;
    try {
      await api.stickerPackImport(f!.path!);
      await _reload();
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  Future<void> _export(StickerPack p) async {
    final s = S.read(context);
    final api = context.read<LumoraApi>();
    try {
      // iOS: Documents is what the Files app shows (UIFileSharingEnabled); ~/Downloads is hidden there.
      final dir = Platform.isIOS ? await getApplicationDocumentsDirectory() : (await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory());
      final path = '${dir.path}${Platform.pathSeparator}${p.name}.lumora-stickers';
      await api.stickerPackExport(p.id, path);
      if (mounted) toast(context, s('saved_to', {'path': path}));
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final packs = _packs;
    if (packs == null) return const Center(child: CircularProgressIndicator());
    if (packs.isEmpty) {
      return EmptyState(
        icon: AppIcons.sticker,
        title: s('no_packs'),
        subtitle: s('no_packs_hint'),
        action: Wrap(spacing: 8, children: [
          FilledButton.icon(onPressed: _create, icon: const Icon(AppIcons.add, size: 16), label: Text(s('new_pack'))),
          OutlinedButton.icon(onPressed: _import, icon: const Icon(AppIcons.download, size: 16), label: Text(s('import_pack'))),
        ]),
      );
    }
    final p = packs[_sel.clamp(0, packs.length - 1)];
    return Column(children: [
      SizedBox(
        height: 40,
        child: Row(children: [
          Expanded(
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
              for (var i = 0; i < packs.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
                  child: ChoiceChip(label: Text(packs[i].name), selected: i == _sel, onSelected: (_) => setState(() => _sel = i)),
                ),
            ]),
          ),
          PopupMenuButton<String>(
            tooltip: s('more'),
            icon: Icon(AppIcons.moreVertical, size: 18, color: context.lc.muted),
            onSelected: (v) {
              switch (v) {
                case 'add':
                  _add(p);
                case 'new':
                  _create();
                case 'import':
                  _import();
                case 'export':
                  _export(p);
                case 'delete':
                  context.read<LumoraApi>().stickerPackDelete(p.id).then((_) => _reload());
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'add', child: Text(s('add_sticker'))),
              PopupMenuItem(value: 'new', child: Text(s('new_pack'))),
              PopupMenuItem(value: 'import', child: Text(s('import_pack'))),
              PopupMenuItem(value: 'export', child: Text(s('export_pack'))),
              PopupMenuItem(value: 'delete', child: Text(s('delete_pack'), style: const TextStyle(color: LC.danger))),
            ],
          ),
        ]),
      ),
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 84, mainAxisSpacing: 6, crossAxisSpacing: 6),
          itemCount: p.stickers.length + 1,
          itemBuilder: (context, i) {
            if (i == p.stickers.length) {
              return InkWell(
                borderRadius: BorderRadius.circular(Radii.md),
                onTap: () => _add(p),
                child: Container(
                  decoration: BoxDecoration(border: Border.all(color: context.lc.divider), borderRadius: BorderRadius.circular(Radii.md)),
                  child: Icon(AppIcons.add, color: context.lc.muted),
                ),
              );
            }
            final st = p.stickers[i];
            return InkWell(
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: () => widget.onSend(st),
              child: Padding(padding: const EdgeInsets.all(4), child: StickerImage(hash: st.hash, size: 76, fallbackEmoji: st.emoji)),
            );
          },
        ),
      ),
    ]);
  }
}

// --------------------------------------------------------------- meme maker

Future<String?> showMemeMaker(BuildContext context) async {
  final f = await FilePicker.pickFile(type: FileType.image);
  if (f?.path == null || !context.mounted) return null;
  final bytes = await File(f!.path!).readAsBytes();
  if (!context.mounted) return null;
  return Navigator.of(context, rootNavigator: true).push<String>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => MemeEditor(image: bytes)));
}

class MemeEditor extends StatefulWidget {
  const MemeEditor({super.key, required this.image});
  final Uint8List image;
  @override
  State<MemeEditor> createState() => _MemeEditorState();
}

class _MemeEditorState extends State<MemeEditor> {
  final _top = TextEditingController();
  final _bottom = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _top.dispose();
    _bottom.dispose();
    super.dispose();
  }

  static void _paintCaption(Canvas canvas, String text, double width, double y, double fontSize, {required bool bottom}) {
    if (text.trim().isEmpty) return;
    TextPainter tp(Paint? stroke) => TextPainter(
          text: TextSpan(
            text: text.toUpperCase(),
            style: TextStyle(
              fontFamily: kFontFamily,
              fontWeight: FontWeight.w900,
              fontSize: fontSize,
              height: 1.05,
              foreground: stroke,
              color: stroke == null ? Colors.white : null,
            ),
          ),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: width * 0.92);
    final outline = tp(Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = fontSize / 7
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.black);
    final fill = tp(null);
    final dy = bottom ? y - fill.height : y;
    final dx = (width - fill.width) / 2;
    outline.paint(canvas, Offset(dx, dy));
    fill.paint(canvas, Offset(dx, dy));
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final codec = await ui.instantiateImageCodec(widget.image, targetWidth: 1280);
      final img = (await codec.getNextFrame()).image;
      final w = img.width.toDouble(), h = img.height.toDouble();
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      canvas.drawImage(img, Offset.zero, Paint());
      final fs = w / 11;
      _paintCaption(canvas, _top.text, w, h * 0.04, fs, bottom: false);
      _paintCaption(canvas, _bottom.text, w, h * 0.96, fs, bottom: true);
      final out = await rec.endRecording().toImage(img.width, img.height);
      final png = await out.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      out.dispose();
      // Kept in app storage: the core serves the sent file from this path.
      final path = await outgoingPath('meme', 'png');
      await File(path).writeAsBytes(png!.buffer.asUint8List());
      if (mounted) Navigator.pop(context, path);
    } catch (e) {
      if (mounted) {
        toastError(context, e);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    Widget caption(TextEditingController c, Alignment a) => Align(
          alignment: a,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Stack(children: [
              Text(c.text.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    foreground: Paint()
                      ..style = PaintingStyle.stroke
                      ..strokeWidth = 5
                      ..color = Colors.black,
                  )),
              Text(c.text.toUpperCase(), textAlign: TextAlign.center, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: Colors.white)),
            ]),
          ),
        );
    return Scaffold(
      appBar: AppBar(
        title: Text(s('meme_maker')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(onPressed: _busy ? null : _export, icon: const Icon(AppIcons.sendTilted, size: 16), label: Text(s('send'))),
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Stack(children: [
                Image.memory(widget.image, fit: BoxFit.contain),
                Positioned.fill(child: caption(_top, Alignment.topCenter)),
                Positioned.fill(child: caption(_bottom, Alignment.bottomCenter)),
              ]),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            TextField(controller: _top, onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: s('meme_top'))),
            const SizedBox(height: 8),
            TextField(controller: _bottom, onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: s('meme_bottom'))),
          ]),
        ),
      ]),
    );
  }
}

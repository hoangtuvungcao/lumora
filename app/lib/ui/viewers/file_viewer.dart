// In-app file viewers: one entry point ([openFileViewer]) that picks the right
// viewer for a downloaded file (PDF, code/text, Markdown, CSV, JSON, images)
// plus the shared chrome every viewer uses (title, "Mở bằng ứng dụng khác",
// "Lưu về máy").
//
// Security: nothing is ever executed. HTML/SVG/XML open as highlighted text
// (no web view), Markdown renders without HTML or network images, PDFs go
// through pdfium (no JavaScript) and links always ask first.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/file_safety.dart';
import '../../l10n/strings.dart';
import '../chats/attachments.dart' show openFile, fileImage;
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import 'csv_viewer.dart';
import 'markdown_viewer.dart';
import 'pdf_viewer.dart';
import 'text_viewer.dart';

enum ViewerKind { pdf, code, markdown, csv, json, image, media, none }

/// Text/code extensions (mirrors `TEXT_EXTS` in core `file_preview.rs`).
const kCodeExts = {
  'txt', 'py', 'js', 'mjs', 'cjs', 'ts', 'tsx', 'jsx', 'dart', 'rs', 'go', 'java', 'kt', 'kts', 'swift', 'c', 'cc', //
  'cpp', 'cxx', 'h', 'hh', 'hpp', 'cs', 'rb', 'php', 'lua', 'yaml', 'yml', 'xml', 'html', 'htm', 'css', 'scss', 'log', //
  'sh', 'bash', 'zsh', 'ps1', 'bat', 'sql', 'ini', 'toml', 'cfg', 'conf', 'env', 'gradle', 'properties', 'svg', 'tex', //
  'srt', 'vtt',
};
const _imageExts = {'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'heic'};
const _mediaExts = {'mp4', 'mov', 'mkv', 'webm', 'avi', 'mp3', 'ogg', 'opus', 'wav', 'm4a', 'flac', 'aac'};
const _bareTextNames = {'makefile', 'dockerfile', 'readme', 'license', 'changelog'};

/// Lower-case extension of [name] ('' when none).
String fileExt(String name) {
  final n = name.toLowerCase();
  final i = n.lastIndexOf('.');
  return i < 0 || i == n.length - 1 ? '' : n.substring(i + 1);
}

ViewerKind viewerKindOf(String name, [String mime = '']) {
  final ext = fileExt(name);
  final m = mime.toLowerCase();
  if (ext == 'pdf' || m == 'application/pdf') return ViewerKind.pdf;
  if (ext == 'md' || ext == 'markdown' || m == 'text/markdown') return ViewerKind.markdown;
  if (ext == 'csv' || ext == 'tsv' || m == 'text/csv') return ViewerKind.csv;
  if (ext == 'json' || m == 'application/json') return ViewerKind.json;
  // SVG is an image type but is shown as text: it can carry scripts.
  if (kCodeExts.contains(ext)) return ViewerKind.code;
  if (_imageExts.contains(ext) || (m.startsWith('image/') && m != 'image/svg+xml')) return ViewerKind.image;
  if (_mediaExts.contains(ext) || m.startsWith('video/') || m.startsWith('audio/')) return ViewerKind.media;
  if (ext.isEmpty && _bareTextNames.contains(name.toLowerCase())) return ViewerKind.code;
  if (m.startsWith('text/')) return ViewerKind.code;
  return ViewerKind.none;
}

bool canViewInApp(String name, [String mime = '']) {
  final k = viewerKindOf(name, mime);
  return k != ViewerKind.media && k != ViewerKind.none;
}

/// Opens [path] in the matching in-app viewer (full screen), or in another
/// app when Lumora can't show it.
Future<void> openFileViewer(BuildContext context, {required String path, required String name, String mime = ''}) async {
  final kind = viewerKindOf(name, mime);
  if (kind == ViewerKind.media || kind == ViewerKind.none) {
    await openFile(context, path);
    return;
  }
  final src = ViewerSource(path, name);
  final Widget page = switch (kind) {
    ViewerKind.pdf => PdfFileViewer(source: src),
    ViewerKind.markdown => MarkdownFileViewer(source: src),
    ViewerKind.csv => CsvFileViewer(source: src),
    ViewerKind.json => TextFileViewer(source: src, json: true),
    ViewerKind.image => ImageFileViewer(source: src),
    _ => TextFileViewer(source: src),
  };
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
}

// ------------------------------------------------------------------ source

/// A file on disk, or a bundled demo asset (`asset:` prefix).
class ViewerSource {
  const ViewerSource(this.path, this.name);
  final String path;
  final String name;

  bool get isAsset => path.startsWith('asset:');
  String get assetKey => path.substring(6);

  Future<int> size() async => isAsset ? (await rootBundle.load(assetKey)).lengthInBytes : File(path).length();

  /// Up to [max] bytes from the start, plus the full size.
  Future<(Uint8List, int)> readHead(int max) async {
    if (isAsset) {
      final d = await rootBundle.load(assetKey);
      final all = d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
      return (all.length <= max ? all : Uint8List.sublistView(all, 0, max), all.length);
    }
    final f = await File(path).open();
    try {
      final total = await f.length();
      final want = total < max ? total : max;
      final out = Uint8List(want);
      var got = 0;
      while (got < want) {
        final n = await f.readInto(out, got, want);
        if (n <= 0) break;
        got += n;
      }
      return (got == want ? out : Uint8List.sublistView(out, 0, got), total);
    } finally {
      await f.close();
    }
  }

  /// Largest file ever loaded whole into memory; viewers read only the head
  /// ([readHead]) and bigger saves are copied on disk instead.
  static const int maxInMemory = 64 * 1024 * 1024;

  /// The whole file, refused above [max] bytes (a huge received file must not
  /// exhaust memory).
  Future<Uint8List> readAll({int max = maxInMemory}) async {
    if (await size() > max) throw FileSystemException('file too large to load in memory', path);
    if (isAsset) {
      final d = await rootBundle.load(assetKey);
      return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
    }
    return File(path).readAsBytes();
  }
}

// ------------------------------------------------------------------ actions

/// "Lưu về máy": system save dialog when available, else the Downloads folder.
Future<void> saveViewerFile(BuildContext context, ViewerSource src) async {
  final s = S.read(context);
  void say(String t) {
    if (context.mounted) toast(context, t);
  }

  try {
    final size = await src.size();
    if (size <= ViewerSource.maxInMemory) {
      try {
        final bytes = await src.readAll();
        final uri = await FilePicker.saveFile(fileName: saveNameFor(src.name, path: src.isAsset ? null : src.path), bytes: bytes, dialogTitle: s('viewer_save'));
        if (uri == null) return; // cancelled
        say(s('viewer_saved', {'path': uri.scheme == 'file' ? uri.toFilePath() : src.name}));
        return;
      } on UnimplementedError {
        // fall through: no save dialog on this platform
      } on MissingPluginException {
        // ditto
      }
    }
    final dir = Platform.isIOS ? await getApplicationDocumentsDirectory() : (await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory());
    await dir.create(recursive: true);
    // Sender-chosen name: one clean file name (no "../"), never overwriting.
    final target = createUniqueFile(dir.path, saveNameFor(src.name, path: src.isAsset ? null : src.path)).path;
    if (src.isAsset) {
      await File(target).writeAsBytes(await src.readAll());
    } else {
      await File(src.path).copy(target);
    }
    say(s('viewer_saved', {'path': target}));
  } catch (_) {
    say(s('viewer_save_failed'));
  }
}

/// Asks before opening a link found inside a document; only http(s)/mailto.
Future<void> confirmOpenLink(BuildContext context, String url) async {
  final s = S.read(context);
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !{'http', 'https', 'mailto'}.contains(uri.scheme.toLowerCase())) {
    toast(context, s('viewer_link_blocked'));
    return;
  }
  final ok = await confirm(context, title: s('viewer_open_link_title'), body: s('viewer_open_link_body', {'url': uri.toString()}), action: s('viewer_open_link'));
  if (!ok || !context.mounted) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
}

// ------------------------------------------------------------------ chrome

/// One action of a viewer: an icon button on desktop, a menu row on phones
/// (unless [pinned]).
class ViewerAction {
  const ViewerAction({required this.icon, required this.label, required this.onTap, this.active = false, this.pinned = false});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final bool pinned;
}

/// Full-screen viewer page: title + file info, actions (viewer-specific ones
/// first, then "Mở bằng ứng dụng khác" and "Lưu về máy"), optional bar under
/// the app bar (search, segmented toggles) and the body.
class ViewerScaffold extends StatelessWidget {
  const ViewerScaffold({
    super.key,
    required this.source,
    required this.body,
    this.subtitle,
    this.actions = const [],
    this.bottomBar,
    this.background,
  });
  final ViewerSource source;
  final Widget body;
  final String? subtitle;
  final List<ViewerAction> actions;
  final PreferredSizeWidget? bottomBar;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final desktop = isDesktop(context);
    final all = [
      ...actions,
      ViewerAction(icon: AppIcons.openExternal, label: s('viewer_open_external'), onTap: () => openFile(context, source.path)),
      ViewerAction(icon: AppIcons.download, label: s('viewer_save'), onTap: () => saveViewerFile(context, source)),
    ];
    final shown = desktop ? all : all.where((a) => a.pinned).toList();
    final menu = desktop ? const <ViewerAction>[] : all.where((a) => !a.pinned).toList();
    return Scaffold(
      backgroundColor: background ?? context.lc.bg,
      appBar: AppBar(
        backgroundColor: context.lc.surface,
        titleSpacing: 0,
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: const Icon(AppIcons.back),
          color: context.lc.text,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(source.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleMedium),
          if (subtitle != null && subtitle!.isNotEmpty)
            Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall),
        ]),
        actions: [
          for (final a in shown) ToolButton(icon: a.icon, tooltip: a.label, onPressed: a.onTap, active: a.active),
          if (menu.isNotEmpty)
            PopupMenuButton<int>(
              icon: Icon(AppIcons.moreVertical, color: context.lc.muted),
              tooltip: MaterialLocalizations.of(context).showMenuTooltip,
              onSelected: (i) => menu[i].onTap?.call(),
              itemBuilder: (_) => [
                for (var i = 0; i < menu.length; i++)
                  PopupMenuItem<int>(
                    value: i,
                    enabled: menu[i].onTap != null,
                    child: Row(children: [
                      Icon(menu[i].icon, size: 19, color: menu[i].active ? LC.primary : context.lc.muted),
                      const SizedBox(width: 12),
                      Expanded(child: Text(menu[i].label)),
                      if (menu[i].active) const Icon(AppIcons.check, size: 17, color: LC.primary),
                    ]),
                  ),
              ],
            ),
          SizedBox(width: desktop ? 12 : 4),
        ],
        bottom: bottomBar ?? PreferredSize(preferredSize: const Size.fromHeight(1), child: Divider(height: 1, color: context.lc.divider)),
      ),
      body: body,
    );
  }
}

/// "3 dòng · 12 KB" style subtitle pieces joined with a middle dot.
String joinInfo(Iterable<String?> parts) => parts.where((p) => p != null && p.isNotEmpty).join(' · ');

/// Friendly full-page state with "Mở bằng ứng dụng khác".
class ViewerMessage extends StatelessWidget {
  const ViewerMessage({super.key, required this.source, required this.icon, required this.title, this.body});
  final ViewerSource source;
  final IconData icon;
  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return EmptyState(
      icon: icon,
      title: title,
      subtitle: body,
      action: OutlinedButton.icon(
        onPressed: () => openFile(context, source.path),
        icon: const Icon(AppIcons.openExternal),
        label: Text(s('viewer_open_external')),
      ),
    );
  }
}

// ------------------------------------------------------------------ image

/// Simple zoomable image page (the chat media viewer needs message context).
class ImageFileViewer extends StatelessWidget {
  const ImageFileViewer({super.key, required this.source});
  final ViewerSource source;

  @override
  Widget build(BuildContext context) {
    final img = fileImage(source.path);
    return ViewerScaffold(
      source: source,
      background: Colors.black,
      body: img == null
          ? const SizedBox()
          : InteractiveViewer(
              maxScale: 8,
              child: Center(
                child: Image(
                  image: img,
                  fit: BoxFit.contain,
                  errorBuilder: (c, e, st) => ViewerMessage(source: source, icon: AppIcons.imageBroken, title: S.of(c)('viewer_load_failed')),
                ),
              ),
            ),
    );
  }
}

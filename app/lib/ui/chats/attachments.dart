// Inline media & file attachments:
// image bubbles (thumb → full crossfade, progress ring), albums, video
// poster cards, typed file cards, and a full-screen media viewer.

import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'forward_sheet.dart';
import '../media_editor/heic.dart' show HeicFileImage, isHeicPath;
import '../media_editor/media_editor.dart';
import '../media_editor/photo_fallback.dart';
import '../../core/file_safety.dart';
import '../viewers/file_viewer.dart' show canViewInApp, openFileViewer;
import '../viewers/preview_card.dart';

/// Progress line for a running transfer: "1,2 MB / 10,4 MB · 5,7 MB/s"
/// once bytes flow, "10,4 MB · Waiting…" before the first byte (a speed
/// with nothing sent yet would be misleading).
String transferDetail(S s, FileItem f) {
  if (f.state == FileState.paused) return '${s.bytes(f.progress)} / ${s.bytes(f.size)} · ${s('paused')}';
  if (f.progress <= 0) return '${s.bytes(f.size)} · ${s('file_starting')}';
  final speed = (f.speedBps ?? 0) > 0 ? ' · ${s.speed(f.speedBps!)}' : '';
  return '${s.bytes(f.progress)} / ${s.bytes(f.size)}$speed';
}

/// Whole percent shown everywhere for the same transfer (never rounds up to 100 early).
int transferPercent(FileItem f) => (f.fraction * 100).floor().clamp(0, 100);

/// Live file state: FilesStore (events) first, then the message's `file`.
FileItem? effectiveFile(BuildContext context, Message m, FileRef ref) {
  final f = context.select<FilesStore, FileItem?>((fs) => fs.byId[ref.id]);
  if (f != null) return f;
  final fi = m.fileInfo;
  if (fi == null) return null;
  return FileItem.fromJson({
    ...fi,
    'id': ref.id,
    'name': ref.name,
    'size': fi['size'] ?? ref.size,
    'conv': m.conv,
    'path': fi['path'] ?? '',
  });
}

/// Image provider for a local path (`asset:` prefix = bundled demo asset),
/// decoded at display size.
ImageProvider? fileImage(String? path, {int? cacheWidth}) {
  if (path == null || path.isEmpty) return null;
  // received pictures: a huge declared size would exhaust memory on decode
  if (!path.startsWith('asset:') && !isSafeImageFile(path)) return null;
  // iPhone photos: decoded by the platform / system libheif (see media_editor/heic.dart).
  if (!path.startsWith('asset:') && isHeicPath(path)) return HeicFileImage(path, maxSide: (cacheWidth ?? 2560).clamp(320, 4096));
  final ImageProvider p = path.startsWith('asset:') ? AssetImage(path.substring(6)) : FileImage(File(path));
  return cacheWidth == null ? p : ResizeImage(p, width: cacheWidth, allowUpscaling: false);
}

Future<void> openFile(BuildContext context, String path, {bool folder = false}) async {
  if (path.startsWith('asset:')) {
    toast(context, S.read(context)('demo_file'));
    return;
  }
  final target = folder ? File(path).parent.path : path;
  // Programs, scripts, installers, web pages: never open without a plain
  // warning (the system would run them right away, e.g. .exe / .bat / .apk).
  if (!folder && isDangerousFileName(path.split(RegExp(r'[/\\]')).last)) {
    final s = S.read(context);
    final go = await confirm(
      context,
      title: s('risky_file_title'),
      body: s('risky_file_body', {'name': safeDisplayName(path.split(RegExp(r'[/\\]')).last)}),
      action: s('risky_file_open'),
      danger: true,
    );
    if (!go || !context.mounted) return;
  }
  final ok = await launchUrl(Uri.file(target)).catchError((_) => false);
  if (!ok && context.mounted) copyText(context, target, message: S.read(context)('path_copied'));
}

// ------------------------------------------------------------------ colours

(IconData, Color) fileKind(String name, String mime) {
  final n = name.toLowerCase();
  bool ext(List<String> e) => e.any((x) => n.endsWith('.$x'));
  if (mime.startsWith('image/') || ext(['png', 'jpg', 'jpeg', 'webp', 'gif'])) return (AppIcons.image, const Color(0xFF14B8A6));
  if (mime.startsWith('video/') || ext(['mp4', 'mov', 'mkv', 'webm', 'avi'])) return (AppIcons.film, const Color(0xFFEC4899));
  if (mime.startsWith('audio/') || ext(['mp3', 'ogg', 'wav', 'm4a', 'flac'])) return (AppIcons.music, const Color(0xFFA855F7));
  if (ext(['pdf'])) return (AppIcons.fileText, const Color(0xFFEF4444));
  if (ext(['doc', 'docx', 'odt', 'rtf'])) return (AppIcons.fileText, const Color(0xFF3B82F6));
  if (ext(['xls', 'xlsx', 'csv', 'ods'])) return (AppIcons.spreadsheet, const Color(0xFF22C55E));
  if (ext(['ppt', 'pptx', 'odp'])) return (AppIcons.presentation, const Color(0xFFF97316));
  if (ext(['zip', 'rar', '7z', 'tar', 'gz', 'xz'])) return (AppIcons.fileArchive, const Color(0xFFF59E0B));
  if (ext(['apk', 'aab'])) return (AppIcons.mobile, const Color(0xFF22C55E));
  if (ext(['iso', 'img', 'dmg'])) return (AppIcons.diskImage, const Color(0xFF64748B));
  if (ext(['fig', 'sketch', 'psd', 'ai', 'svg'])) return (AppIcons.draw, const Color(0xFF8B5CF6));
  if (ext(['txt', 'md', 'log', 'json', 'yaml', 'dart', 'rs', 'py', 'js'])) return (AppIcons.fileCode, const Color(0xFF0EA5E9));
  return (AppIcons.file, const Color(0xFF6C5CE7));
}

// ------------------------------------------------------------------- image

class ImageBubble extends StatelessWidget {
  const ImageBubble({super.key, required this.message, required this.ref, this.width, this.height, this.overlay, this.onOpen});
  final Message message;
  final FileRef ref;
  final double? width;
  final double? height;

  /// Widget drawn bottom-right on top of the photo (time/ticks).
  final Widget? overlay;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final f = effectiveFile(context, message, ref);
    final maxW = width ?? mediaBubbleWidth(context);
    final aspect = ref.aspect.clamp(0.6, 2.0);
    final w = maxW;
    final h = height ?? (w / aspect);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final done = f?.state == FileState.done || (f == null && (message.fileInfo?['path'] != null));
    final full = done ? fileImage(f?.path ?? message.fileInfo?['path']?.toString(), cacheWidth: (w * dpr).round()) : null;
    final transferring = f != null && (f.state == FileState.transferring || f.state == FileState.paused);
    final offered = f != null && f.state == FileState.offered && f.incoming;

    return GestureDetector(
      onTap: done ? onOpen : null,
      child: SizedBox(
        width: w,
        height: h,
        child: Stack(fit: StackFit.expand, children: [
          // Blurred thumbnail placeholder (or neutral tile).
          if (ref.thumb != null)
            ImageFiltered(
              imageFilter: kNoShadows ? ColorFilter.mode(Colors.transparent, BlendMode.dst) : _blur,
              child: Image.memory(ref.thumb!, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.low),
            )
          else
            ColoredBox(color: context.lc.surface2),
          if (full != null)
            Image(
              image: full,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              frameBuilder: (_, child, frame, sync) => AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: sync ? Duration.zero : Motion.slow,
                curve: Curves.easeOut,
                child: child,
              ),
              errorBuilder: (_, _, _) => ref.thumb != null
                  ? const SizedBox.shrink()
                  : Center(child: Icon(AppIcons.imageBroken, color: context.lc.muted, size: 32)),
            ),
          if (transferring || offered)
            Center(
              child: _RoundProgress(
                value: f.fraction,
                paused: f.state == FileState.paused,
                icon: offered ? AppIcons.download : AppIcons.close,
                label: offered ? s.bytes(f.size) : null,
                onTap: () => offered ? context.read<FilesStore>().accept(f.id) : context.read<FilesStore>().cancel(f.id),
              ),
            ),
          if (f?.state == FileState.failed)
            Center(
              child: _RoundProgress(value: 0, icon: AppIcons.refresh, onTap: () => retryFile(context, message, f!)),
            ),
          if (overlay != null) Positioned(right: 6, bottom: 6, child: _GlassChip(child: overlay!)),
        ]),
      ),
    );
  }
}

final _blur = ImageFilter.blur(sigmaX: 8, sigmaY: 8);

class _GlassChip extends StatelessWidget {
  const _GlassChip({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(10)),
        child: DefaultTextStyle.merge(style: const TextStyle(color: Colors.white), child: IconTheme(data: const IconThemeData(color: Colors.white), child: child)),
      );
}

class _RoundProgress extends StatelessWidget {
  const _RoundProgress({required this.value, required this.icon, required this.onTap, this.paused = false, this.label});
  final double value;
  final IconData icon;
  final VoidCallback onTap;
  final bool paused;
  final String? label;
  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), shape: BoxShape.circle),
          child: Stack(alignment: Alignment.center, children: [
            if (value > 0)
              SizedBox(
                width: 44,
                height: 44,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: value),
                  duration: Motion.slow,
                  builder: (_, v, _) => CircularProgressIndicator(value: v, strokeWidth: 3, color: paused ? LC.warning : Colors.white, backgroundColor: Colors.white24),
                ),
              ),
            Icon(icon, color: Colors.white, size: 22),
          ]),
        ),
      ),
      if (label != null) ...[const SizedBox(height: 6), _GlassChip(child: Text(label!, style: const TextStyle(fontSize: 11.5)))],
    ]);
  }
}

/// 2–4 (or more) photos sent together.
/// Width of photo / video bubbles: 280 on phones, less on small phones so
/// it always fits the bubble (78% of the screen, minus its padding).
double mediaBubbleWidth(BuildContext context) {
  if (isDesktop(context)) return 360.0;
  final screen = MediaQuery.sizeOf(context).width;
  return screen * 0.78 - 24 < 280.0 ? (screen * 0.78 - 24).clamp(160.0, 280.0) : 280.0;
}

class AlbumGrid extends StatelessWidget {
  const AlbumGrid({super.key, required this.items, required this.overlay, required this.onOpen});
  final List<(Message, FileRef)> items;
  final Widget overlay;
  final void Function(Message m) onOpen;

  @override
  Widget build(BuildContext context) {
    final w = mediaBubbleWidth(context);
    const gap = 3.0;
    final n = items.length;
    Widget tile(int i, double tw, double th, {Widget? extra}) {
      final it = items[i];
      return SizedBox(
        width: tw,
        height: th,
        child: Stack(fit: StackFit.expand, children: [
          ImageBubble(message: it.$1, ref: it.$2, width: tw, height: th, onOpen: () => onOpen(it.$1)),
          ?extra,
        ]),
      );
    }

    if (n == 2) {
      final tw = (w - gap) / 2;
      return Stack(children: [
        Row(mainAxisSize: MainAxisSize.min, children: [tile(0, tw, tw * 1.2), const SizedBox(width: gap), tile(1, tw, tw * 1.2)]),
        Positioned(right: 6, bottom: 6, child: _GlassChip(child: overlay)),
      ]);
    }
    if (n == 3) {
      final big = w * 0.62;
      final small = w - big - gap;
      final hh = (big * 1.1 - gap) / 2;
      return Stack(children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          tile(0, big, big * 1.1),
          const SizedBox(width: gap),
          Column(mainAxisSize: MainAxisSize.min, children: [tile(1, small, hh), const SizedBox(height: gap), tile(2, small, hh)]),
        ]),
        Positioned(right: 6, bottom: 6, child: _GlassChip(child: overlay)),
      ]);
    }
    final tw = (w - gap) / 2;
    final more = n - 4;
    return Stack(children: [
      Column(mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [tile(0, tw, tw), const SizedBox(width: gap), tile(1, tw, tw)]),
        const SizedBox(height: gap),
        Row(mainAxisSize: MainAxisSize.min, children: [
          tile(2, tw, tw),
          const SizedBox(width: gap),
          tile(3, tw, tw,
              extra: more > 0
                  ? IgnorePointer(
                      child: ColoredBox(
                        color: Colors.black45,
                        child: Center(child: Text('+$more', style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700))),
                      ),
                    )
                  : null),
        ]),
      ]),
      Positioned(right: 6, bottom: 6, child: _GlassChip(child: overlay)),
    ]);
  }
}

// ------------------------------------------------------------------- video

class VideoCard extends StatelessWidget {
  const VideoCard({super.key, required this.message, required this.ref, required this.overlay});
  final Message message;
  final FileRef ref;
  final Widget overlay;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final f = effectiveFile(context, message, ref);
    final w = mediaBubbleWidth(context);
    final h = w / ref.aspect.clamp(1.0, 2.0);
    final done = f?.state == FileState.done;
    final transferring = f != null && (f.state == FileState.transferring || f.state == FileState.paused);
    final offered = f != null && f.state == FileState.offered && f.incoming;
    final dur = message.meta['duration'];
    return GestureDetector(
      onTap: done && f!.path.isNotEmpty ? () => openFile(context, f.path) : null,
      child: SizedBox(
        width: w,
        height: h,
        child: Stack(fit: StackFit.expand, children: [
          if (ref.thumb != null)
            Image.memory(ref.thumb!, fit: BoxFit.cover, gaplessPlayback: true)
          else
            const DecoratedBox(
              decoration: BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF1F2340), Color(0xFF2D2670)], begin: Alignment.topLeft, end: Alignment.bottomRight)),
            ),
          const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black54]))),
          Center(
            child: transferring || offered
                ? _RoundProgress(
                    value: f.fraction,
                    paused: f.state == FileState.paused,
                    icon: offered ? AppIcons.download : AppIcons.close,
                    onTap: () => offered ? context.read<FilesStore>().accept(f.id) : context.read<FilesStore>().cancel(f.id),
                  )
                : Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), shape: BoxShape.circle),
                    child: const Icon(AppIcons.play, color: Colors.white, size: 34),
                  ),
          ),
          Positioned(
            left: 8,
            top: 8,
            child: _GlassChip(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(AppIcons.video, size: 13),
                const SizedBox(width: 4),
                Text(dur is num ? s.duration(Duration(seconds: dur.toInt())) : s.bytes(ref.size), style: const TextStyle(fontSize: 11.5)),
              ]),
            ),
          ),
          if (transferring)
            Positioned(
              left: 8,
              bottom: 8,
              child: _GlassChip(child: Text('${s.bytes(f.progress)} / ${s.bytes(f.size)}', style: const TextStyle(fontSize: 11.5))),
            ),
          Positioned(right: 6, bottom: 6, child: _GlassChip(child: overlay)),
        ]),
      ),
    );
  }
}

// -------------------------------------------------------------------- file

Future<void> retryFile(BuildContext context, Message m, FileItem f) async {
  final files = context.read<FilesStore>();
  try {
    if (f.incoming) {
      await files.accept(f.id);
    } else if (f.path.isNotEmpty) {
      await files.send(m.conv, f.path);
    }
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

class FileCard extends StatelessWidget {
  const FileCard({super.key, required this.message, required this.ref});
  final Message message;
  final FileRef ref;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final f = effectiveFile(context, message, ref);
    final mine = message.mine;
    final (icon, color) = fileKind(ref.name, ref.mime);
    final fg = mine ? Colors.white : context.lc.text;
    final sub = mine ? Colors.white.withValues(alpha: 0.78) : context.lc.muted;
    final size = f?.size ?? ref.size;
    final store = context.read<FilesStore>();
    final transferring = f != null && (f.state == FileState.transferring || f.state == FileState.paused);
    final preview = hasFilePreview(ref);
    final viewable = canViewInApp(ref.name, ref.mime);

    String status;
    if (f == null) {
      status = s.bytes(size);
    } else {
      status = switch (f.state) {
        FileState.offered => '${s.bytes(size)} · ${f.incoming ? s('file_offered') : s('file_waiting')}',
        FileState.transferring || FileState.paused => transferDetail(s, f),
        FileState.done => s.bytes(size),
        FileState.failed => s('file_failed'),
        FileState.cancelled => s('file_cancelled'),
      };
    }

    Widget btn(IconData i, String tip, VoidCallback onTap, {Color? c}) => Tooltip(
          message: tip,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(padding: const EdgeInsets.all(6), child: Icon(i, size: 20, color: c ?? sub)),
          ),
        );

    final actions = <Widget>[
      if (f != null && f.state == FileState.offered && f.incoming) btn(AppIcons.download, s('download'), () => store.accept(f.id), c: mine ? Colors.white : LC.accent),
      if (transferring) ...[
        btn(f.state == FileState.paused ? AppIcons.play : AppIcons.pause, f.state == FileState.paused ? s('resume') : s('pause'), () => store.togglePause(f.id)),
        btn(AppIcons.close, s('cancel'), () => store.cancel(f.id)),
      ],
      if (f?.state == FileState.done && f!.path.isNotEmpty) ...[
        viewable
            ? btn(AppIcons.show, s('fpv_view'), () => openFileViewer(context, path: f.path, name: ref.name, mime: ref.mime))
            : btn(AppIcons.openExternal, s('open'), () => openFile(context, f.path)),
        btn(AppIcons.folder, s('open_folder'), () => openFile(context, f.path, folder: true)),
      ],
      if (f?.state == FileState.failed) btn(AppIcons.refresh, s('retry'), () => retryFile(context, message, f!), c: LC.warning),
    ];

    return Container(
      width: preview ? 340 : 290,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: mine ? Colors.white.withValues(alpha: 0.12) : context.lc.surface2.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        // PDF first page / first lines of code, before download
        if (preview) ...[FilePreviewPane(message: message, ref: ref, file: f), const SizedBox(height: 8)],
        Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: mine ? Colors.white.withValues(alpha: 0.95) : color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // name tap: in-app viewer when the file is here, else the preview
              onTap: preview || (viewable && localPathOf(f) != null) ? () => openFileOrPreview(context, message, ref, f) : null,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(ref.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 2),
                Text(status, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: f?.state == FileState.failed ? LC.danger : sub, fontSize: 12)),
              ]),
            ),
          ),
          ...actions,
          if (f?.state == FileState.done && actions.isEmpty) Icon(AppIcons.checkCircle, size: 20, color: mine ? Colors.white : LC.success),
        ]),
        if (f != null && f.state == FileState.done && f.incoming && f.path.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (viewable) _Suggest(icon: AppIcons.show, label: s('fpv_view'), onTap: () => openFileViewer(context, path: f.path, name: ref.name, mime: ref.mime)),
            // in-app files: "Mở bằng ứng dụng khác" lives in the viewer
            if (!viewable) _Suggest(icon: AppIcons.openExternal, label: s('open'), onTap: () => openFile(context, f.path)),
            // self-destructing: no copies (save / forward)
            if (!message.selfDestructs) _Suggest(icon: AppIcons.download, label: s('save'), onTap: () => saveCopy(context, f)),
            if (!message.selfDestructs)
              _Suggest(icon: AppIcons.forward, label: s('forward'), onTap: () async {
                final chat = context.read<ChatStore>();
                final to = await pickForwardTarget(context, title: s('forward_to'));
                if (to != null) await chat.forward(message, to.conv, hideSender: to.hideSender);
              }),
          ]),
        ],
        if (transferring) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: f.fraction),
              duration: Motion.slow,
              builder: (_, v, _) => LinearProgressIndicator(
                value: v,
                minHeight: 5,
                backgroundColor: mine ? Colors.white.withValues(alpha: 0.2) : context.lc.surface2,
                color: mine ? Colors.white : (f.state == FileState.paused ? LC.warning : color),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

// ------------------------------------------------------------------ viewer

/// Full-screen viewer: swipe between all photos of the conversation,
/// pinch-zoom, save / forward / open.
Future<void> openMediaViewer(BuildContext context, {required String conv, required String initialId}) {
  final thread = context.read<ChatStore>().thread(conv);
  final items = <(Message, FileRef)>[];
  for (final m in thread.messages) {
    if (!m.isFile || m.deleted) continue;
    final r = FileRef.parse(m.body);
    if (r != null && r.isImage) items.add((m, r));
  }
  final start = items.indexWhere((e) => e.$1.id == initialId);
  if (items.isEmpty) return Future.value();
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.black,
    transitionDuration: Motion.normal,
    pageBuilder: (_, _, _) => MediaViewer(items: items, initial: start < 0 ? 0 : start),
    transitionsBuilder: (_, a, _, c) => FadeTransition(opacity: a, child: c),
  ));
}

class MediaViewer extends StatefulWidget {
  const MediaViewer({super.key, required this.items, required this.initial});
  final List<(Message, FileRef)> items;
  final int initial;
  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> {
  late final PageController _page = PageController(initialPage: widget.initial);
  late int _index = widget.initial;
  bool _chrome = true;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  String? _pathOf(BuildContext context, Message m, FileRef r) {
    final f = context.read<FilesStore>().byId[r.id];
    return (f?.path.isNotEmpty ?? false) ? f!.path : m.fileInfo?['path']?.toString();
  }

  Future<void> _save(BuildContext context) async {
    final s = S.read(context);
    final (m, r) = widget.items[_index];
    final path = _pathOf(context, m, r);
    if (path == null) return;
    try {
      // Still photos → gallery (mobile) / save dialog in Pictures (desktop), metadata stripped.
      if (isEditablePhoto(r.name)) {
        await saveExistingPhotoToDevice(context, path);
        return;
      }
      final shown = await saveToPublicDownloads(path, r.name);
      if (shown != null) {
        if (context.mounted) toast(context, s('saved_to', {'path': shown}));
        return;
      }
      // iOS: Documents is what the Files app shows (UIFileSharingEnabled); ~/Downloads is hidden there.
      final dir = Platform.isIOS ? await getApplicationDocumentsDirectory() : (await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory());
      await dir.create(recursive: true);
      // The name comes from the sender: one clean file name, never a path,
      // and never an existing file.
      final out = createUniqueFile(dir.path, saveNameFor(r.name, path: path));
      if (path.startsWith('asset:')) {
        final data = await rootBundle.load(path.substring(6));
        await out.writeAsBytes(data.buffer.asUint8List());
      } else {
        await File(path).copy(out.path);
      }
      if (context.mounted) toast(context, s('saved_to', {'path': out.path}));
    } catch (e) {
      if (context.mounted) toastError(context, e, fallbackKey: 'viewer_save_failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final (m, r) = widget.items[_index];
    final contacts = context.read<ContactsStore>();
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      backgroundColor: Colors.black,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _page.nextPage(duration: Motion.normal, curve: Motion.curve),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _page.previousPage(duration: Motion.normal, curve: Motion.curve),
        },
        child: Focus(
          autofocus: true,
          child: Stack(children: [
            PageView.builder(
              controller: _page,
              itemCount: widget.items.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) {
                final (mm, rr) = widget.items[i];
                final img = fileImage(_pathOf(context, mm, rr), cacheWidth: (width * dpr).round().clamp(320, 2560));
                return GestureDetector(
                  onTap: () => setState(() => _chrome = !_chrome),
                  child: InteractiveViewer(
                    maxScale: 5,
                    child: Center(
                      child: img != null
                          ? Image(
                              image: img,
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                              errorBuilder: (_, _, _) => PhotoDecodeFallback(path: _pathOf(context, mm, rr), thumb: rr.thumb),
                            )
                          : (rr.thumb != null ? Image.memory(rr.thumb!, fit: BoxFit.contain) : const Icon(AppIcons.image, color: Colors.white38, size: 64)),
                    ),
                  ),
                );
              },
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: AnimatedOpacity(
              duration: Motion.fast,
              opacity: _chrome ? 1 : 0,
              child: IgnorePointer(
                ignoring: !_chrome,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                  decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black87, Colors.transparent])),
                  child: SafeArea(
                    bottom: false,
                    child: Row(children: [
                      IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(AppIcons.close, color: Colors.white), tooltip: s('close')),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(m.mine ? s('you') : contacts.nameOf(m.author), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                          Text('${s.dayLabel(DateTime.fromMillisecondsSinceEpoch(m.ts), DateTime.now())} · ${s.hhmm(DateTime.fromMillisecondsSinceEpoch(m.ts))}',
                              style: const TextStyle(color: Colors.white70, fontSize: 12)),
                        ]),
                      ),
                      Text('${_index + 1} / ${widget.items.length}', style: const TextStyle(color: Colors.white70)),
                      const SizedBox(width: 8),
                      if (!m.selfDestructs) IconButton(onPressed: () => _save(context), icon: const Icon(AppIcons.download, color: Colors.white), tooltip: s('pe_save_device')),
                      if (!m.selfDestructs)
                        IconButton(
                          onPressed: () async {
                            final chat = context.read<ChatStore>();
                            final to = await pickForwardTarget(context, title: s('forward_to'));
                            if (to != null) await chat.forward(m, to.conv, hideSender: to.hideSender);
                          },
                          icon: const Icon(AppIcons.forward, color: Colors.white),
                          tooltip: s('forward'),
                        ),
                      IconButton(
                        onPressed: () {
                          final p = _pathOf(context, m, r);
                          if (p != null) openFile(context, p);
                        },
                        icon: const Icon(AppIcons.openExternal, color: Colors.white),
                        tooltip: s('open'),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
            ),
            if (isEditablePhoto(r.name) && _pathOf(context, m, r) != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: AnimatedOpacity(
                  duration: Motion.fast,
                  opacity: _chrome ? 1 : 0,
                  child: IgnorePointer(ignoring: !_chrome, child: _ViewerEditBar(onEdit: () => _edit(context))),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  /// "Chỉnh sửa": edit a copy; the result is sent as a new message.
  Future<void> _edit(BuildContext context) async {
    final (m, r) = widget.items[_index];
    final path = _pathOf(context, m, r);
    if (path == null) return;
    final res = await openPhotoEditorFromViewer(context, conv: m.conv, path: path);
    if (res == PhotoEditorResult.sent && context.mounted) Navigator.pop(context);
  }
}

class _ViewerEditBar extends StatelessWidget {
  const _ViewerEditBar({required this.onEdit});
  final VoidCallback onEdit;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 16),
      decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black87, Colors.transparent])),
      child: SafeArea(
        top: false,
        child: Center(
          child: FilledButton.icon(
            key: const ValueKey('viewer-edit'),
            onPressed: onEdit,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.14),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.xl)),
            ),
            icon: const Icon(AppIcons.edit, size: 18),
            label: Text(s('edit')),
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------- send preview

/// Preview before sending files: thumbnails, remove, optional caption
/// (sent as a text message after the files).
Future<void> showSendFiles(BuildContext context, {required String conv, required List<String> paths, VoidCallback? onSent}) async {
  if (paths.isEmpty) return;
  // Only still photos → full-screen preview with caption and "Chỉnh sửa".
  if (canPreviewPhotos(paths)) return showPhotoSendPreview(context, conv: conv, paths: paths, onSent: onSent);
  final r = await showModalBottomSheet<(List<String>, String)>(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => _SendFilesSheet(paths: paths),
  );
  if (r == null || !context.mounted) return;
  final files = context.read<FilesStore>();
  final chat = context.read<ChatStore>();
  try {
    for (final p in r.$1) {
      await files.send(conv, p);
    }
    if (r.$2.trim().isNotEmpty) await chat.send(conv, r.$2.trim());
    onSent?.call();
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

/// Clipboard text → local file paths (file:// URIs or plain paths).
Future<List<String>> clipboardFilePaths() async {
  final d = await Clipboard.getData('text/plain');
  final t = d?.text?.trim() ?? '';
  if (t.isEmpty) return const [];
  final out = <String>[];
  for (final line in t.split(RegExp(r'[\r\n]+'))) {
    var p = line.trim();
    if (p.startsWith('file://')) p = Uri.parse(p).toFilePath();
    if (p.isNotEmpty && (p.startsWith('/') || RegExp(r'^[A-Za-z]:\\').hasMatch(p)) && File(p).existsSync()) out.add(p);
  }
  return out;
}

class _SendFilesSheet extends StatefulWidget {
  const _SendFilesSheet({required this.paths});
  final List<String> paths;
  @override
  State<_SendFilesSheet> createState() => _SendFilesSheetState();
}

class _SendFilesSheetState extends State<_SendFilesSheet> {
  late final List<String> _paths = List.of(widget.paths);
  final _caption = TextEditingController();

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  static String _name(String p) => p.split(RegExp(r'[/\\]')).last;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(s('send_n_files', {'n': _paths.length}), style: context.tt.titleMedium),
          ),
          SizedBox(
            height: 128,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _paths.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final p = _paths[i];
                final ref = FileRef('', _name(p), 0);
                final (icon, color) = fileKind(ref.name, '');
                return Stack(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.md),
                    child: SizedBox(
                      width: 112,
                      height: 128,
                      child: ref.isImage
                          ? Image.file(File(p), fit: BoxFit.cover, cacheWidth: (112 * dpr).round(), errorBuilder: (_, _, _) => const SizedBox())
                          : ColoredBox(
                              color: color.withValues(alpha: 0.14),
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                  Icon(icon, color: color, size: 34),
                                  const SizedBox(height: 6),
                                  Text(ref.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: context.tt.bodySmall),
                                ]),
                              ),
                            ),
                    ),
                  ),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: InkWell(
                      onTap: () => setState(() => _paths.removeAt(i)),
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                        child: const Icon(AppIcons.close, size: 16, color: Colors.white),
                      ),
                    ),
                  ),
                ]);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _caption,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(hintText: s('add_caption')),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _paths.isEmpty ? null : () => Navigator.pop(context, (_paths, _caption.text)),
                icon: const Icon(AppIcons.send, size: 18),
                label: Text(s('send')),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}


class _Suggest extends StatelessWidget {
  const _Suggest({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ActionChip(
        avatar: Icon(icon, size: 15, color: LC.primary),
        label: Text(label),
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
      );
}

/// Copies a received file to the Downloads folder ("Lưu").
/// Android: path_provider's "downloads" is the app's own Android/data folder
/// (where received files already are) — invisible in the Files app on
/// Android 11+. "Save" copies into the public Download/Lumora instead and
/// returns where (`Download/Lumora/<name>`). Null elsewhere, and on Android
/// 8–9 (no permission for that folder): the caller keeps its own folder.
Future<String?> saveToPublicDownloads(String path, String declaredName) async {
  if (!Platform.isAndroid || path.startsWith('asset:') || !File(path).existsSync()) return null;
  return const MethodChannel('lumora/media')
      .invokeMethod<String>('saveToDownloads', {'path': path, 'name': saveNameFor(declaredName, path: path)});
}

Future<void> saveCopy(BuildContext context, FileItem f) async {
  final s = S.read(context);
  try {
    final shown = await saveToPublicDownloads(f.path, f.name);
    if (shown != null) {
      if (context.mounted) toast(context, s('saved_to', {'path': shown}));
      return;
    }
    // iOS: Documents is what the Files app shows (UIFileSharingEnabled); ~/Downloads is hidden there.
    final dir = Platform.isIOS ? await getApplicationDocumentsDirectory() : (await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory());
    // Already in that folder (the core downloads there): nothing to copy.
    if (!f.path.startsWith('asset:') && File(f.path).parent.absolute.path == Directory(dir.path).absolute.path && File(f.path).existsSync()) {
      if (context.mounted) toast(context, s('saved_to', {'path': f.path}));
      return;
    }
    await dir.create(recursive: true);
    final out = createUniqueFile(dir.path, saveNameFor(f.name, path: f.path));
    if (f.path.startsWith('asset:')) {
      final data = await rootBundle.load(f.path.substring(6));
      await out.writeAsBytes(data.buffer.asUint8List());
    } else {
      await File(f.path).copy(out.path);
    }
    if (context.mounted) toast(context, s('saved_to', {'path': out.path}));
  } catch (e) {
    if (context.mounted) toastError(context, e, fallbackKey: 'viewer_save_failed');
  }
}

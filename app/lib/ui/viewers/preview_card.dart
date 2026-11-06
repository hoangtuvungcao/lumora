// Previews in file bubbles, before the file is downloaded:
//  · PDF: the sender-rendered first page with a "3 trang" chip;
//  · text/code: the first lines in monospace (syntax colours, line numbers)
//    fading out, with "Python · 42 dòng".
// Tapping opens the in-app viewer when the file is on this device, otherwise
// a "Xem trước" sheet with the whole snippet and "Tải về để xem đầy đủ".

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/file_preview.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../chats/attachments.dart' show effectiveFile, fileKind, openFile, retryFile, transferDetail, transferPercent;
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import 'file_viewer.dart';
import 'text_viewer.dart';

/// Lines of code shown inside the bubble.
const kBubbleSnippetLines = 6;

/// "1.200" (vi) / "1,200" (en).
String groupDigits(int n, bool vi) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(vi ? '.' : ',');
    b.write(s[i]);
  }
  return b.toString();
}

/// Whether [ref] carries something worth drawing above the file row.
bool hasFilePreview(FileRef ref) {
  if (ref.isImage || ref.isVideo) return false;
  return ref.thumb != null || (ref.preview?.text.isNotEmpty ?? false);
}

/// "3 trang" / "42 dòng" for a preview (null when unknown).
String? previewCount(S s, FilePreview? p) {
  if (p == null) return null;
  if (p.pages > 0) return p.pages == 1 ? s('fpv_pages_one') : s('fpv_pages', {'n': groupDigits(p.pages, s.vi)});
  if (p.lines > 0) return p.lines == 1 ? s('fpv_lines_one') : s('fpv_lines', {'n': groupDigits(p.lines, s.vi)});
  return null;
}

/// Local copy of the file, when it is on this device.
String? localPathOf(FileItem? f) {
  if (f == null || f.path.isEmpty) return null;
  if (f.state == FileState.done || !f.incoming) return f.path;
  return null;
}

/// Tap on a previewable file: the in-app viewer when the file is here,
/// otherwise the preview sheet (or another app for files Lumora can't show).
Future<void> openFileOrPreview(BuildContext context, Message message, FileRef ref, FileItem? f) async {
  final path = localPathOf(f);
  if (path != null && canViewInApp(ref.name, ref.mime)) {
    return openFileViewer(context, path: path, name: ref.name, mime: ref.mime);
  }
  if (hasFilePreview(ref)) return showFilePreviewSheet(context, message: message, ref: ref);
  if (path != null) return openFile(context, path);
}

// ------------------------------------------------------------------ bubble

/// The preview drawn at the top of a file card (see [hasFilePreview]).
class FilePreviewPane extends StatelessWidget {
  const FilePreviewPane({super.key, required this.message, required this.ref, required this.file});
  final Message message;
  final FileRef ref;
  final FileItem? file;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final tip = localPathOf(file) != null && canViewInApp(ref.name, ref.mime) ? s('fpv_view') : s('fpv_preview');
    final Widget body = ref.thumb != null ? _PagePeek(ref: ref, mine: message.mine) : _CodePeek(ref: ref, mine: message.mine);
    return Semantics(
      button: true,
      label: '$tip: ${ref.name}',
      child: Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 600),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: ValueKey('fpv_${ref.id}'),
            borderRadius: BorderRadius.circular(10),
            onTap: () => openFileOrPreview(context, message, ref, file),
            child: body,
          ),
        ),
      ),
    );
  }
}

/// Small translucent label over a preview.
class _PreviewChip extends StatelessWidget {
  const _PreviewChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    const fg = Colors.white;
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 3, 9, 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: fg),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(color: fg, fontSize: 11.5, fontWeight: FontWeight.w600, height: 1.2)),
      ]),
    );
  }
}

/// Top of the first PDF page, like a sheet of paper peeking out.
class _PagePeek extends StatelessWidget {
  const _PagePeek({required this.ref, required this.mine});
  final FileRef ref;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final count = previewCount(s, ref.preview);
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth.isFinite ? c.maxWidth : 320.0;
      // show the upper part of the page; tall enough to read the title
      final h = (w * 0.58).clamp(132.0, 210.0);
      return ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: SizedBox(
          width: w,
          height: h,
          child: Stack(fit: StackFit.expand, children: [
            const ColoredBox(color: Colors.white),
            Image.memory(
              ref.thumb!,
              fit: BoxFit.fitWidth,
              alignment: Alignment.topCenter,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => Center(child: Icon(AppIcons.fileText, size: 40, color: Colors.black.withValues(alpha: 0.2))),
            ),
            // fold into the card
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: h * 0.42,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black.withValues(alpha: 0), Colors.black.withValues(alpha: 0.32)],
                  ),
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: Colors.black.withValues(alpha: mine ? 0.0 : 0.08)),
              ),
            ),
            if (count != null) Positioned(left: 8, bottom: 8, child: _PreviewChip(icon: AppIcons.fileText, label: count)),
            Positioned(right: 8, bottom: 8, child: _PreviewChip(icon: AppIcons.show, label: s('fpv_preview'))),
          ]),
        ),
      );
    });
  }
}

/// Memoised highlighting of snippets (per file id): bubbles rebuild often.
final Map<String, List<List<HlTok>>> _hlCache = {};

List<List<HlTok>> _snippetLines(FileRef ref) {
  final key = '${ref.id}:${ref.name}:${ref.preview?.text.length}';
  final hit = _hlCache[key];
  if (hit != null) return hit;
  final text = ref.preview?.text ?? '';
  final lang = languageFor(ref.name);
  List<List<HlTok>> lines;
  try {
    lines = lang == null ? _plain(text) : highlightLines(text, lang);
  } catch (_) {
    lines = _plain(text);
  }
  if (_hlCache.length > 200) _hlCache.clear();
  return _hlCache[key] = lines;
}

List<List<HlTok>> _plain(String text) => [
      for (final l in text.split('\n')) [HlTok(l, null)],
    ];

/// One highlighted line.
TextSpan _lineSpan(List<HlTok> toks, CodePalette pal, TextStyle base) => TextSpan(
      style: base,
      children: [for (final t in toks) TextSpan(text: t.text.replaceAll('\t', '    '), style: pal.style(t.scope))],
    );

/// Dark code palette inside my (purple) bubbles, app theme elsewhere.
Widget _codeTheme(BuildContext context, bool forceDark, WidgetBuilder builder) {
  if (!forceDark || Theme.of(context).brightness == Brightness.dark) return Builder(builder: builder);
  final t = Theme.of(context);
  return Theme(data: t.copyWith(colorScheme: t.colorScheme.copyWith(brightness: Brightness.dark)), child: Builder(builder: builder));
}

/// First lines of a text/code file, fading out.
class _CodePeek extends StatelessWidget {
  const _CodePeek({required this.ref, required this.mine});
  final FileRef ref;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = ref.preview!;
    final all = _snippetLines(ref);
    // skip leading blank lines so the bubble starts with content
    var first = 0;
    while (first < all.length - 1 && all[first].every((t) => t.text.trim().isEmpty)) {
      first++;
    }
    final lines = all.skip(first).take(kBubbleSnippetLines).toList();
    final more = all.length - first > lines.length || p.lines > all.length;
    final count = previewCount(s, p);
    final label = [languageLabel(ref.name), ?count].join(' · ');
    return _codeTheme(context, mine, (context) {
      final pal = CodePalette.of(context);
      final bg = mine ? const Color(0xFF15162E).withValues(alpha: 0.92) : pal.bg;
      final base = kMonoStyle.copyWith(fontSize: 12, height: 1.5, color: pal.text);
      final numStyle = kMonoStyle.copyWith(fontSize: 11, height: 1.5 * 12 / 11, color: pal.gutterText);
      final digits = math.max(2, '${first + lines.length}'.length);
      final headFg = mine ? Colors.white.withValues(alpha: 0.72) : pal.gutterText;
      return Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: mine ? Colors.white.withValues(alpha: 0.10) : context.lc.divider.withValues(alpha: 0.9)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          // title strip: language · line count
          Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: mine ? Colors.white.withValues(alpha: 0.08) : context.lc.divider.withValues(alpha: 0.7))),
            ),
            child: Row(children: [
              Icon(AppIcons.fileCode, size: 13, color: headFg),
              const SizedBox(width: 6),
              Expanded(
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: headFg, fontSize: 11.5, fontWeight: FontWeight.w600)),
              ),
              Icon(AppIcons.show, size: 13, color: headFg),
              const SizedBox(width: 4),
              Text(s('fpv_preview'), style: TextStyle(color: headFg, fontSize: 11.5, fontWeight: FontWeight.w500)),
            ]),
          ),
          Stack(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 10, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (var i = 0; i < lines.length; i++)
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(
                      width: digits * 7.4,
                      child: Text('${first + i + 1}', textAlign: TextAlign.right, style: numStyle),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text.rich(
                        _lineSpan(lines[i], pal, base),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.clip,
                      ),
                    ),
                  ]),
              ]),
            ),
            if (more)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 40,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [bg.withValues(alpha: 0), bg],
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ]),
      );
    });
  }
}

// ------------------------------------------------------------------ sheet

/// "Xem trước": the whole sender-made preview with the download action.
Future<void> showFilePreviewSheet(BuildContext context, {required Message message, required FileRef ref}) {
  if (isDesktop(context)) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(32),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.lg)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 760, maxHeight: MediaQuery.sizeOf(context).height * 0.86),
          child: FilePreviewSheet(message: message, ref: ref),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    clipBehavior: Clip.antiAlias,
    builder: (_) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.88),
      child: FilePreviewSheet(message: message, ref: ref),
    ),
  );
}

class FilePreviewSheet extends StatelessWidget {
  const FilePreviewSheet({super.key, required this.message, required this.ref});
  final Message message;
  final FileRef ref;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final f = effectiveFile(context, message, ref);
    final p = ref.preview;
    final (icon, color) = fileKind(ref.name, ref.mime);
    final isPage = ref.thumb != null;
    final count = previewCount(s, p);
    final kind = isPage ? (fileExt(ref.name).isEmpty ? '' : fileExt(ref.name).toUpperCase()) : languageLabel(ref.name);
    final sub = [if (kind.isNotEmpty) kind, s.bytes(f?.size ?? ref.size), ?count].join(' · ');
    final desktop = isDesktop(context);

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // header
      Padding(
        padding: EdgeInsets.fromLTRB(20, desktop ? 18 : 2, 12, 12),
        child: Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(11)),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(ref.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: context.lc.muted, fontSize: 12.5)),
            ]),
          ),
          if (desktop) IconButton(tooltip: s('close'), icon: const Icon(AppIcons.close), onPressed: () => Navigator.pop(context)),
        ]),
      ),
      Divider(height: 1, color: context.lc.divider),
      // body
      Flexible(child: isPage ? _PageBody(ref: ref) : _SnippetBody(ref: ref)),
      Divider(height: 1, color: context.lc.divider),
      _SheetFooter(message: message, ref: ref, file: f),
    ]);
  }
}

class _PageBody extends StatelessWidget {
  const _PageBody({required this.ref});
  final FileRef ref;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final pages = ref.preview?.pages ?? 0;
    final aspect = ref.width > 0 && ref.height > 0 ? ref.width / ref.height : 1 / 1.414;
    return ColoredBox(
      color: context.lc.surface2.withValues(alpha: 0.55),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
                  boxShadow: kNoShadows ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 18, offset: const Offset(0, 6))],
                ),
                clipBehavior: Clip.antiAlias,
                child: AspectRatio(
                  aspectRatio: aspect,
                  child: Image.memory(ref.thumb!, fit: BoxFit.cover, alignment: Alignment.topCenter, filterQuality: FilterQuality.medium),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            pages > 1 ? s('fpv_page_one_of', {'n': groupDigits(pages, s.vi)}) : s('fpv_first_page'),
            style: TextStyle(color: context.lc.muted, fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ]),
      ),
    );
  }
}

class _SnippetBody extends StatelessWidget {
  const _SnippetBody({required this.ref});
  final FileRef ref;

  @override
  Widget build(BuildContext context) {
    final lines = _snippetLines(ref);
    final pal = CodePalette.of(context);
    final base = kMonoStyle.copyWith(fontSize: 13, color: pal.text);
    final numStyle = kMonoStyle.copyWith(fontSize: 13, color: pal.gutterText);
    final digits = math.max(2, '${lines.length}'.length);
    final strut = StrutStyle(fontFamily: kMonoStyle.fontFamily, fontSize: 13, height: kMonoStyle.height, forceStrutHeight: true);
    return ColoredBox(
      color: pal.bg,
      child: Scrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(left: 12, right: 20),
            child: SelectionArea(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // one row per line: number and code always share a baseline
                for (var i = 0; i < lines.length; i++)
                  Row(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    SelectionContainer.disabled(
                      child: SizedBox(width: digits * 8.2, child: Text('${i + 1}', textAlign: TextAlign.right, style: numStyle, strutStyle: strut)),
                    ),
                    const SizedBox(width: 14),
                    Text.rich(_lineSpan(lines[i], pal, base), softWrap: false, strutStyle: strut),
                  ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetFooter extends StatelessWidget {
  const _SheetFooter({required this.message, required this.ref, required this.file});
  final Message message;
  final FileRef ref;
  final FileItem? file;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final f = file;
    final p = ref.preview;
    final store = context.read<FilesStore>();
    final path = localPathOf(f);
    final viewable = canViewInApp(ref.name, ref.mime);

    // what the preview covers
    String note;
    if (ref.thumb != null) {
      note = (p?.pages ?? 0) > 1 ? s('fpv_note_pdf', {'n': groupDigits(p!.pages, s.vi)}) : s('fpv_note_page');
    } else {
      final shown = _snippetLines(ref).length;
      final total = p?.lines ?? 0;
      note = total > shown
          ? s('fpv_note_lines', {'shown': groupDigits(shown, s.vi), 'n': groupDigits(total, s.vi)})
          : s('fpv_note_all');
    }

    Widget primary;
    if (path != null) {
      primary = FilledButton.icon(
        onPressed: () {
          Navigator.pop(context);
          viewable ? openFileViewer(context, path: path, name: ref.name, mime: ref.mime) : openFile(context, path);
        },
        icon: Icon(viewable ? AppIcons.show : AppIcons.openExternal, size: 18),
        label: Text(viewable ? s('fpv_view_full') : s('viewer_open_external')),
      );
    } else if (f != null && (f.state == FileState.transferring || f.state == FileState.paused)) {
      primary = Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2.4, value: f.fraction > 0 ? f.fraction : null),
        ),
        const SizedBox(width: 10),
        Flexible(child: Text('${transferPercent(f)}% · ${transferDetail(s, f)}', overflow: TextOverflow.ellipsis, style: TextStyle(color: context.lc.muted, fontSize: 13))),
      ]);
    } else if (f != null && f.state == FileState.failed) {
      primary = FilledButton.icon(onPressed: () => retryFile(context, message, f), icon: const Icon(AppIcons.retry, size: 18), label: Text(s('retry')));
    } else if (f != null && f.incoming) {
      primary = FilledButton.icon(
        key: const ValueKey('fpv_download'),
        onPressed: () => store.accept(f.id),
        icon: const Icon(AppIcons.download, size: 18),
        label: Text(s('fpv_download_full')),
      );
    } else {
      primary = const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 14),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 10,
        spacing: 12,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(AppIcons.info, size: 15, color: context.lc.muted),
            const SizedBox(width: 6),
            Flexible(child: Text(note, style: TextStyle(color: context.lc.muted, fontSize: 12.5))),
          ]),
          primary,
        ],
      ),
    );
  }
}

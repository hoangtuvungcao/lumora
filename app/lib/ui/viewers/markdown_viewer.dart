// Markdown viewer: rendered (GitHub-flavoured) or source.
//
// Safe by construction: no HTML rendering, no image is fetched (local or
// remote) — a placeholder with the alt text is shown — and links only open
// after a confirmation, and only for http(s)/mailto.

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import 'file_viewer.dart';
import 'text_viewer.dart';

class MarkdownFileViewer extends StatefulWidget {
  const MarkdownFileViewer({super.key, required this.source, this.initialSource = false});
  final ViewerSource source;
  final bool initialSource;

  @override
  State<MarkdownFileViewer> createState() => _MarkdownFileViewerState();
}

class _MarkdownFileViewerState extends State<MarkdownFileViewer> {
  TextLoad? _load;
  Object? _error;
  late bool _source = widget.initialSource;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    try {
      final (head, total) = await widget.source.readHead(kViewerMaxBytes);
      final load = decodeTextHead(head, total);
      if (mounted) setState(() => _load = load);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final load = _load;
    final ok = load != null && !load.binary && _error == null;
    Widget body;
    if (_error != null) {
      body = ViewerMessage(source: widget.source, icon: AppIcons.fileText, title: s('viewer_load_failed'), body: s('viewer_load_failed_body'));
    } else if (load == null) {
      body = const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    } else if (load.binary) {
      body = ViewerMessage(source: widget.source, icon: AppIcons.shieldWarning, title: s('viewer_binary_title'), body: s('viewer_binary_body'));
    } else if (_source) {
      body = CodeView(text: load.text, language: 'markdown', wrap: true);
    } else {
      body = SafeMarkdown(data: load.text);
    }
    final lines = load == null ? 0 : '\n'.allMatches(load.text.trimRight()).length + 1;
    return ViewerScaffold(
      source: widget.source,
      subtitle: load == null || load.binary ? null : joinInfo(['Markdown', s('viewer_lines', {'n': lines}), s.bytes(load.totalBytes)]),
      background: _source && ok ? CodePalette.of(context).bg : context.lc.surface,
      actions: [
        if (ok) ViewerAction(icon: AppIcons.copy, label: s('viewer_copy_all'), onTap: () => copyText(context, load.text, message: s('viewer_copied_all'))),
      ],
      bottomBar: ok
          ? PreferredSize(
              preferredSize: const Size.fromHeight(53),
              child: Container(
                height: 53,
                decoration: BoxDecoration(
                  color: context.lc.surface,
                  border: Border(top: BorderSide(color: context.lc.divider), bottom: BorderSide(color: context.lc.divider)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                alignment: Alignment.centerLeft,
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: [
                    ButtonSegment(value: false, icon: const Icon(AppIcons.show, size: 17), label: Text(s('viewer_rendered'))),
                    ButtonSegment(value: true, icon: const Icon(AppIcons.code, size: 17), label: Text(s('viewer_source'))),
                  ],
                  selected: {_source},
                  onSelectionChanged: (v) => setState(() => _source = v.first),
                ),
              ),
            )
          : null,
      body: body,
    );
  }
}

/// Rendered Markdown with the app's typography and the safety rules above.
class SafeMarkdown extends StatelessWidget {
  const SafeMarkdown({super.key, required this.data});
  final String data;

  @override
  Widget build(BuildContext context) {
    final pal = CodePalette.of(context);
    final theme = Theme.of(context);
    final lc = context.lc;
    final mono = kMonoStyle.copyWith(fontSize: 13, color: pal.text);
    final base = MarkdownStyleSheet.fromTheme(theme);
    final sheet = base.copyWith(
      p: context.tt.bodyMedium?.copyWith(fontSize: 15, height: 1.6),
      h1: context.tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700, fontSize: 26, height: 1.3),
      h2: context.tt.titleLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: 20, height: 1.35),
      h3: context.tt.titleMedium?.copyWith(fontWeight: FontWeight.w700, fontSize: 17),
      h1Padding: const EdgeInsets.only(bottom: 6),
      h2Padding: const EdgeInsets.only(top: 18, bottom: 4),
      h3Padding: const EdgeInsets.only(top: 12, bottom: 2),
      blockSpacing: 12,
      listBullet: context.tt.bodyMedium?.copyWith(fontSize: 15, color: LC.primary),
      listIndent: 22,
      a: const TextStyle(color: LC.primary, fontWeight: FontWeight.w600, decoration: TextDecoration.underline, decorationColor: Color(0x666C5CE7)),
      code: mono.copyWith(backgroundColor: theme.brightness == Brightness.dark ? const Color(0xFF262A4A) : const Color(0xFFEEF0F8), fontSize: 13),
      codeblockPadding: const EdgeInsets.all(14),
      codeblockDecoration: BoxDecoration(color: pal.bg, borderRadius: BorderRadius.circular(Radii.md), border: Border.all(color: lc.divider)),
      blockquote: context.tt.bodyMedium?.copyWith(fontSize: 15, color: lc.muted, height: 1.55),
      blockquotePadding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      blockquoteDecoration: BoxDecoration(
        color: LC.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: const Border(left: BorderSide(color: LC.primary, width: 3)),
      ),
      tableHead: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
      tableBody: context.tt.bodyMedium,
      tableBorder: TableBorder.all(color: lc.divider, borderRadius: BorderRadius.circular(Radii.sm)),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      tableHeadAlign: TextAlign.left,
      horizontalRuleDecoration: BoxDecoration(border: Border(top: BorderSide(color: lc.divider))),
    );
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: Markdown(
          data: data,
          selectable: true,
          padding: EdgeInsets.symmetric(horizontal: isDesktop(context) ? 40 : 20, vertical: 24),
          styleSheet: sheet,
          extensionSet: md.ExtensionSet.gitHubFlavored,
          syntaxHighlighter: _MdHighlighter(pal, mono),
          onTapLink: (text, href, title) {
            if (href != null) confirmOpenLink(context, href);
          },
          imageBuilder: (uri, title, alt) => _ImagePlaceholder(alt: (alt ?? '').isNotEmpty ? alt! : uri.toString()),
        ),
      ),
    );
  }
}

class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({required this.alt});
  final String alt;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.lc.surface2,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: context.lc.divider),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(AppIcons.imageBroken, size: 18, color: context.lc.muted),
        const SizedBox(width: 10),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(alt, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            Text(s('viewer_remote_image'), style: context.tt.bodySmall),
          ]),
        ),
      ]),
    );
  }
}

/// Code blocks: auto-detected among the common languages.
class _MdHighlighter extends SyntaxHighlighter {
  _MdHighlighter(this.pal, this.mono);
  final CodePalette pal;
  final TextStyle mono;

  static const _langs = ['bash', 'python', 'javascript', 'typescript', 'json', 'yaml', 'dart', 'rust', 'go', 'java', 'cpp', 'sql', 'css', 'xml', 'ini'];

  @override
  TextSpan format(String source) {
    List<List<HlTok>>? lines;
    if (source.length < 32 * 1024) {
      try {
        lines = highlightAuto(source, _langs);
      } catch (_) {}
    }
    if (lines == null) return TextSpan(text: source, style: mono);
    final spans = <TextSpan>[];
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) spans.add(const TextSpan(text: '\n'));
      for (final t in lines[i]) {
        spans.add(TextSpan(text: t.text, style: pal.style(t.scope)));
      }
    }
    return TextSpan(style: mono, children: spans);
  }
}

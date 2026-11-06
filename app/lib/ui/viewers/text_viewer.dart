// Code / text viewer: syntax colours (re_highlight, a Dart port of
// highlight.js), line numbers, wrap toggle, copy, in-file search and a
// large-file guard (only the first 1.5 MB is read; binary files are refused).
// Also used for JSON (pretty-printed) and as the Markdown "source" view.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/github-dark.dart';
import 'package:re_highlight/styles/github.dart';

import '../../l10n/strings.dart';
import '../chats/attachments.dart' show openFile;
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import 'file_viewer.dart';

/// At most this much of a file is read and shown.
const kViewerMaxBytes = 1536 * 1024;

/// Above this, colours are skipped so scrolling stays smooth.
const kHighlightMaxChars = 300 * 1024;

/// Lines longer than this are cut in the no-wrap view (layout cost).
const _maxLineChars = 4000;

/// Monospace text. The primary families cover all Vietnamese letters: some
/// common mono fonts (DejaVu Sans Mono = Linux "monospace", Menlo) lack a few
/// precomposed ones (ỗ, ẫ…) and the shaper then stacks combining marks badly.
const kMonoStyle = TextStyle(
  fontFamily: 'Noto Sans Mono',
  fontFamilyFallback: [
    'Cascadia Mono', 'Consolas', 'SF Mono', 'Liberation Mono', 'Ubuntu Mono', 'Roboto Mono', 'Droid Sans Mono', //
    'Courier New', 'Menlo', 'DejaVu Sans Mono', 'monospace', 'BeVietnamPro',
  ],
  fontSize: 13.5,
  height: 1.55,
);

// ------------------------------------------------------------------ decoding

/// Result of reading the start of a text file.
class TextLoad {
  const TextLoad(this.text, {this.truncated = false, this.binary = false, this.totalBytes = 0});
  final String text;
  final bool truncated;
  final bool binary;
  final int totalBytes;
}

/// End index ≤ [end] that doesn't split a UTF-8 sequence.
int utf8SafeEnd(List<int> b, int end) {
  var i = end;
  var k = 0;
  while (i > 0 && k < 3 && (b[i - 1] & 0xC0) == 0x80) {
    i--;
    k++;
  }
  if (i == 0) return end;
  final lead = b[i - 1];
  if (lead < 0x80) return end;
  final need = lead >= 0xF0 ? 4 : (lead >= 0xE0 ? 3 : 2);
  return need == k + 1 ? end : i - 1;
}

/// NUL bytes, invalid UTF-8 or > 2 % control characters in the first 8 KB.
bool looksBinary(List<int> b) {
  final n = math.min(b.length, 8192);
  for (var i = 0; i < n; i++) {
    if (b[i] == 0) return true;
  }
  String s;
  try {
    s = const Utf8Decoder().convert(b, 0, utf8SafeEnd(b, n));
  } on FormatException {
    return true;
  }
  var ctrl = 0;
  for (final c in s.codeUnits) {
    if ((c < 0x20 && c != 9 && c != 10 && c != 13 && c != 12 && c != 27) || c == 0x7F) ctrl++;
  }
  return s.isNotEmpty && ctrl * 50 > s.length;
}

/// Decodes the first bytes of a file ([total] = full size) for display.
TextLoad decodeTextHead(Uint8List head, int total) {
  var b = head;
  if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) b = Uint8List.sublistView(b, 3);
  if (looksBinary(b)) return TextLoad('', binary: true, totalBytes: total);
  final truncated = total > head.length;
  final end = truncated ? utf8SafeEnd(b, b.length) : b.length;
  final text = utf8.decode(Uint8List.sublistView(b, 0, end), allowMalformed: true).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return TextLoad(text, truncated: truncated, totalBytes: total);
}

// ------------------------------------------------------------------ languages

/// highlight.js language for a file name (null = plain text).
String? languageFor(String name) {
  final ext = fileExt(name);
  return switch (ext) {
    'py' => 'python',
    'js' || 'mjs' || 'cjs' || 'jsx' => 'javascript',
    'ts' || 'tsx' => 'typescript',
    'dart' => 'dart',
    'rs' => 'rust',
    'go' => 'go',
    'java' || 'kt' || 'kts' || 'gradle' => 'java',
    'c' || 'h' => 'c',
    'cc' || 'cpp' || 'cxx' || 'hh' || 'hpp' || 'cs' => 'cpp',
    'json' => 'json',
    'yaml' || 'yml' => 'yaml',
    'xml' || 'html' || 'htm' || 'svg' => 'xml',
    'css' || 'scss' => 'css',
    'sh' || 'bash' || 'zsh' => 'bash',
    'sql' => 'sql',
    'ini' || 'toml' || 'cfg' || 'conf' || 'env' || 'properties' => 'ini',
    'md' || 'markdown' => 'markdown',
    _ => null,
  };
}

/// Short human label of the file type ("Python", "JSON", "TXT").
String languageLabel(String name) {
  const labels = {
    'python': 'Python', 'javascript': 'JavaScript', 'typescript': 'TypeScript', 'dart': 'Dart', 'rust': 'Rust', 'go': 'Go', //
    'java': 'Java', 'c': 'C', 'cpp': 'C++', 'json': 'JSON', 'yaml': 'YAML', 'css': 'CSS', 'bash': 'Shell', 'sql': 'SQL', //
    'ini': 'Config', 'markdown': 'Markdown',
  };
  final ext = fileExt(name);
  if (ext == 'html' || ext == 'htm') return 'HTML';
  if (ext == 'svg') return 'SVG';
  if (ext == 'xml') return 'XML';
  if (ext == 'toml') return 'TOML';
  return labels[languageFor(name)] ?? (ext.isEmpty ? 'TXT' : ext.toUpperCase());
}

Highlight? _hl;
Highlight _highlighter() => _hl ??= Highlight()
  ..registerLanguages({
    'python': langPython,
    'javascript': langJavascript,
    'typescript': langTypescript,
    'dart': langDart,
    'rust': langRust,
    'go': langGo,
    'java': langJava,
    'c': langC,
    'cpp': langCpp,
    'json': langJson,
    'yaml': langYaml,
    'xml': langXml,
    'css': langCss,
    'bash': langBash,
    'sql': langSql,
    'ini': langIni,
    'markdown': langMarkdown,
  });

/// One coloured run inside a line; [scope] is the highlight.js scope chain
/// ("outer|inner"), null for plain text.
@immutable
class HlTok {
  const HlTok(this.text, this.scope);
  final String text;
  final String? scope;
}

class _LineRenderer implements HighlightRenderer {
  final lines = <List<HlTok>>[<HlTok>[]];
  final _stack = <String?>[];
  String? _key;

  void _recompute() {
    final sc = _stack.whereType<String>();
    _key = sc.isEmpty ? null : sc.join('|');
  }

  @override
  void addText(String text) {
    final parts = text.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) lines.add(<HlTok>[]);
      if (parts[i].isNotEmpty) lines.last.add(HlTok(parts[i], _key));
    }
  }

  @override
  void openNode(DataNode node) {
    _stack.add(node.scope);
    _recompute();
  }

  @override
  void closeNode(DataNode node) {
    if (_stack.isNotEmpty) _stack.removeLast();
    _recompute();
  }
}

/// Splits [code] into coloured lines (one list per `\n`-separated line).
List<List<HlTok>> highlightLines(String code, String language) {
  final r = _highlighter().highlight(code: code, language: language);
  final rd = _LineRenderer();
  r.render(rd);
  return rd.lines;
}

/// Like [highlightLines] but guesses the language among [languages].
List<List<HlTok>> highlightAuto(String code, List<String> languages) {
  final r = _highlighter().highlightAuto(code, languages);
  final rd = _LineRenderer();
  r.render(rd);
  return rd.lines;
}

List<List<HlTok>> _hlEntry((String, String) a) => highlightLines(a.$1, a.$2);

/// Highlights off the UI thread for bigger inputs.
Future<List<List<HlTok>>?> highlightAsync(String code, String? language) async {
  if (language == null || code.isEmpty || code.length > kHighlightMaxChars) return null;
  try {
    if (code.length < 48 * 1024) return highlightLines(code, language);
    return await compute(_hlEntry, (code, language));
  } catch (_) {
    return null;
  }
}

/// Colours for scopes, following the app theme (GitHub light / dark).
class CodePalette {
  CodePalette._(this.dark, this.theme, this.text, this.bg, this.gutterBg, this.gutterText, this.match, this.currentMatch);

  factory CodePalette.of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark ? _dark : _light;
  }

  static final _dark = CodePalette._(
    true,
    githubDarkTheme,
    const Color(0xFFD6DAF0),
    const Color(0xFF12142A),
    const Color(0xFF12142A),
    const Color(0xFF555B82),
    const Color(0x55F5B83D),
    const Color(0xFFF59E0B),
  );
  static final _light = CodePalette._(
    false,
    githubTheme,
    const Color(0xFF1F2340),
    const Color(0xFFFFFFFF),
    const Color(0xFFFFFFFF),
    const Color(0xFFA3A8C3),
    const Color(0x66FFD54F),
    const Color(0xFFFFB020),
  );

  final bool dark;
  final Map<String, TextStyle> theme;
  final Color text;
  final Color bg;
  final Color gutterBg;
  final Color gutterText;
  final Color match;
  final Color currentMatch;
  final _cache = <String, TextStyle?>{};

  /// Style of a scope chain (outer to inner, inner wins), null = plain.
  TextStyle? style(String? key) {
    if (key == null) return null;
    return _cache.putIfAbsent(key, () {
      TextStyle? out;
      for (final scope in key.split('|')) {
        var k = scope;
        TextStyle? st;
        while (true) {
          st = theme[k];
          if (st != null) break;
          final dot = k.lastIndexOf('.');
          if (dot < 0) break;
          k = k.substring(0, dot);
        }
        if (st != null) out = (out ?? const TextStyle()).merge(st.copyWith(backgroundColor: null));
      }
      // drop the theme's backgrounds: ours is the app surface
      return out?.copyWith(backgroundColor: Colors.transparent);
    });
  }
}

// ------------------------------------------------------------------ search

@immutable
class TextMatch {
  const TextMatch(this.line, this.start, this.end);
  final int line;
  final int start;
  final int end;
}

/// Case-insensitive matches of [query] in [lines] (capped).
List<TextMatch> findMatches(List<String> lines, String query, {int max = 5000}) {
  final q = query.toLowerCase();
  if (q.isEmpty) return const [];
  final out = <TextMatch>[];
  for (var i = 0; i < lines.length && out.length < max; i++) {
    final l = lines[i].toLowerCase();
    var from = 0;
    while (out.length < max) {
      final j = l.indexOf(q, from);
      if (j < 0) break;
      out.add(TextMatch(i, j, j + q.length));
      from = j + math.max(1, q.length);
    }
  }
  return out;
}

/// Search state shared by the search bar and the code view.
class CodeSearch extends ChangeNotifier {
  CodeSearch(this._lines);
  final List<String> _lines;
  String query = '';
  List<TextMatch> matches = const [];
  int current = -1;

  void set(String q) {
    query = q;
    matches = findMatches(_lines, q);
    current = matches.isEmpty ? -1 : 0;
    notifyListeners();
  }

  void step(int d) {
    if (matches.isEmpty) return;
    current = (current + d) % matches.length;
    if (current < 0) current += matches.length;
    notifyListeners();
  }

  TextMatch? get currentMatch => current >= 0 && current < matches.length ? matches[current] : null;
}

// ------------------------------------------------------------------ view

/// Lazily built, line-numbered code view.
class CodeView extends StatefulWidget {
  const CodeView({super.key, required this.text, this.language, this.wrap = false, this.search, this.highlight = true});
  final String text;
  final String? language;
  final bool wrap;
  final CodeSearch? search;
  final bool highlight;

  @override
  State<CodeView> createState() => _CodeViewState();
}

class _CodeViewState extends State<CodeView> {
  late List<String> _lines;
  List<List<HlTok>>? _tokens;
  final _v = ScrollController();
  final _h = ScrollController();
  final _rowKeys = <int, GlobalKey>{};
  double? _maxLineWidth;
  TextMatch? _lastJump;

  @override
  void initState() {
    super.initState();
    _prepare();
    widget.search?.addListener(_onSearch);
  }

  @override
  void didUpdateWidget(CodeView old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.language != widget.language) _prepare();
    if (old.search != widget.search) {
      old.search?.removeListener(_onSearch);
      widget.search?.addListener(_onSearch);
    }
  }

  @override
  void dispose() {
    widget.search?.removeListener(_onSearch);
    _v.dispose();
    _h.dispose();
    super.dispose();
  }

  void _prepare() {
    _lines = widget.text.split('\n');
    if (_lines.length > 1 && _lines.last.isEmpty) _lines.removeLast();
    _tokens = null;
    _maxLineWidth = null;
    if (widget.highlight) {
      final text = widget.text;
      highlightAsync(text, widget.language).then((t) {
        if (mounted && identical(text, widget.text) && t != null) setState(() => _tokens = t);
      });
    }
  }

  static const _lineH = 13.5 * 1.55;
  static const _strut = StrutStyle(fontSize: 13.5, height: 1.55, forceStrutHeight: true);

  double _charW(BuildContext context) {
    final tp = TextPainter(text: const TextSpan(text: '0000000000', style: kMonoStyle), textDirection: TextDirection.ltr, textScaler: MediaQuery.textScalerOf(context))..layout();
    return tp.width / 10;
  }

  double _measureMaxLine(BuildContext context) {
    if (_maxLineWidth != null) return _maxLineWidth!;
    // the 3 longest lines by length, measured for real (wide glyphs, tabs)
    final idx = List<int>.generate(_lines.length, (i) => i)..sort((a, b) => _lines[b].length.compareTo(_lines[a].length));
    var w = 0.0;
    for (final i in idx.take(3)) {
      final l = _display(_lines[i]);
      final tp = TextPainter(text: TextSpan(text: l, style: kMonoStyle), textDirection: TextDirection.ltr, maxLines: 1, textScaler: MediaQuery.textScalerOf(context))..layout();
      w = math.max(w, tp.width);
    }
    return _maxLineWidth = w;
  }

  String _display(String l) {
    final t = l.replaceAll('\t', '    ');
    return !widget.wrap && t.length > _maxLineChars ? '${t.substring(0, _maxLineChars)} …' : t;
  }

  void _onSearch() {
    setState(() {});
    final m = widget.search?.currentMatch;
    if (m == null || m == _lastJump) return;
    _lastJump = m;
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpTo(m));
  }

  void _jumpTo(TextMatch m) {
    if (!_v.hasClients) return;
    final pos = _v.position;
    if (!widget.wrap) {
      final y = (m.line * _lineH - pos.viewportDimension * 0.35).clamp(0.0, pos.maxScrollExtent);
      _v.animateTo(y, duration: Motion.normal, curve: Motion.curve);
      if (_h.hasClients) {
        final cw = _charW(context);
        final x = m.start * cw;
        final hp = _h.position;
        if (x < hp.pixels || x > hp.pixels + hp.viewportDimension - 80) {
          _h.animateTo((x - hp.viewportDimension * 0.3).clamp(0.0, hp.maxScrollExtent), duration: Motion.normal, curve: Motion.curve);
        }
      }
      return;
    }
    // wrapped rows have different heights: jump near, then reveal precisely
    final key = _rowKeys[m.line];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(key!.currentContext!, alignment: 0.35, duration: Motion.normal, curve: Motion.curve);
      return;
    }
    final avg = pos.maxScrollExtent > 0 && _lines.length > 1 ? (pos.maxScrollExtent + pos.viewportDimension) / _lines.length : _lineH;
    _v.jumpTo((m.line * avg - pos.viewportDimension * 0.35).clamp(0.0, pos.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _rowKeys[m.line]?.currentContext;
      if (c != null && c.mounted) Scrollable.ensureVisible(c, alignment: 0.35);
    });
  }

  List<InlineSpan> _lineSpans(int i, CodePalette pal) {
    final raw = _lines[i];
    final toks = _tokens != null && i < _tokens!.length ? _tokens![i] : [HlTok(raw, null)];
    final search = widget.search;
    final marks = <(int, int, bool)>[];
    if (search != null && search.matches.isNotEmpty) {
      final cur = search.currentMatch;
      // matches are sorted by line: binary search the first one on this line
      var lo = 0, hi = search.matches.length;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (search.matches[mid].line < i) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      for (var k = lo; k < search.matches.length && search.matches[k].line == i; k++) {
        final m = search.matches[k];
        marks.add((m.start, m.end, identical(m, cur)));
      }
    }
    final spans = <InlineSpan>[];
    var off = 0;
    var budget = widget.wrap ? 1 << 30 : _maxLineChars;
    for (final t in toks) {
      if (budget <= 0) break;
      var text = t.text;
      if (text.length > budget) text = text.substring(0, budget);
      budget -= text.length;
      final base = pal.style(t.scope);
      final start = off;
      final end = off + text.length;
      off = end;
      // split the run where search marks begin/end
      var p = start;
      for (final (ms, me, isCur) in marks) {
        if (me <= p || ms >= end) continue;
        final a = math.max(ms, p);
        final b = math.min(me, end);
        if (a > p) spans.add(TextSpan(text: _tabs(text.substring(p - start, a - start)), style: base));
        spans.add(TextSpan(
          text: _tabs(text.substring(a - start, b - start)),
          style: (base ?? const TextStyle()).copyWith(
            backgroundColor: isCur ? pal.currentMatch : pal.match,
            color: isCur ? Colors.black : null,
          ),
        ));
        p = b;
      }
      if (p < end) spans.add(TextSpan(text: _tabs(text.substring(p - start)), style: base));
    }
    if (!widget.wrap && raw.length > _maxLineChars) spans.add(TextSpan(text: ' …', style: TextStyle(color: pal.gutterText)));
    return spans;
  }

  static String _tabs(String s) => s.contains('\t') ? s.replaceAll('\t', '    ') : s;

  @override
  Widget build(BuildContext context) {
    final pal = CodePalette.of(context);
    final digits = math.max(2, '${_lines.length}'.length);
    final cw = _charW(context);
    final gutterW = digits * cw + 32;
    final mono = kMonoStyle.copyWith(color: pal.text);
    final cur = widget.search?.currentMatch;

    Widget gutter(int i) => Container(
          width: gutterW,
          color: pal.gutterBg,
          padding: const EdgeInsets.only(right: 16),
          alignment: Alignment.topRight,
          child: Text(
            '${i + 1}',
            style: mono.copyWith(color: cur?.line == i ? pal.text : pal.gutterText),
            strutStyle: _strut,
            textAlign: TextAlign.right,
          ),
        );

    Widget line(int i) => Text.rich(
          TextSpan(children: _lineSpans(i, pal)),
          style: mono,
          strutStyle: _strut,
          softWrap: widget.wrap,
          maxLines: widget.wrap ? null : 1,
          overflow: TextOverflow.clip,
        );

    final divider = Container(width: 1, color: context.lc.divider);

    return ColoredBox(
      color: pal.bg,
      child: LayoutBuilder(builder: (context, box) {
        if (widget.wrap) {
          return Scrollbar(
            controller: _v,
            child: SelectionArea(
              child: ListView.builder(
                controller: _v,
                padding: const EdgeInsets.symmetric(vertical: 12),
                itemCount: _lines.length,
                itemBuilder: (c, i) => IntrinsicHeight(
                  key: _rowKeys.putIfAbsent(i, GlobalKey.new),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    SelectionContainer.disabled(child: gutter(i)),
                    divider,
                    const SizedBox(width: 16),
                    Expanded(child: Padding(padding: const EdgeInsets.only(right: 16), child: line(i))),
                  ]),
                ),
              ),
            ),
          );
        }
        final contentW = math.max(box.maxWidth, gutterW + 1 + 16 + _measureMaxLine(context) + 32);
        return Scrollbar(
          controller: _v,
          notificationPredicate: (n) => n.depth == 1,
          child: Scrollbar(
            controller: _h,
            child: SingleChildScrollView(
              controller: _h,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: contentW,
                child: SelectionArea(
                  child: ListView.builder(
                    controller: _v,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    itemExtent: _lineH,
                    itemCount: _lines.length,
                    itemBuilder: (c, i) => Stack(children: [
                      Positioned.fill(left: gutterW + 17, child: Align(alignment: Alignment.centerLeft, child: line(i))),
                      // sticky gutter: follows the horizontal scroll
                      AnimatedBuilder(
                        animation: _h,
                        builder: (c, child) => Transform.translate(offset: Offset(_h.hasClients ? _h.offset : 0, 0), child: child),
                        child: SelectionContainer.disabled(child: Row(mainAxisSize: MainAxisSize.min, children: [SizedBox(height: _lineH, child: gutter(i)), divider])),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

// ------------------------------------------------------------------ search bar

/// Search field + "3 / 12" + previous / next + close, shown under the app bar.
class SearchStrip extends StatefulWidget implements PreferredSizeWidget {
  const SearchStrip({super.key, required this.onQuery, required this.onStep, required this.onClose, required this.count, required this.index, this.busy = false, this.hint});
  final ValueChanged<String> onQuery;
  final ValueChanged<int> onStep;
  final VoidCallback onClose;
  final int count;
  final int index;
  final bool busy;
  final String? hint;

  @override
  Size get preferredSize => const Size.fromHeight(57);

  @override
  State<SearchStrip> createState() => _SearchStripState();
}

class _SearchStripState extends State<SearchStrip> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final has = _ctrl.text.isNotEmpty;
    final label = !has
        ? ''
        : widget.busy && widget.count == 0
            ? s('viewer_searching')
            : widget.count == 0
                ? s('viewer_no_match')
                : '${widget.index + 1} / ${widget.count}';
    return Container(
      height: 57,
      decoration: BoxDecoration(
        color: context.lc.surface,
        border: Border(top: BorderSide(color: context.lc.divider), bottom: BorderSide(color: context.lc.divider)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        Expanded(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
              const SingleActivator(LogicalKeyboardKey.enter, shift: true): () => widget.onStep(-1),
            },
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              onChanged: (v) {
                setState(() {});
                widget.onQuery(v);
              },
              onSubmitted: (_) {
                widget.onStep(1);
                _focus.requestFocus();
              },
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: widget.hint ?? s('viewer_search_hint'),
                prefixIcon: Icon(AppIcons.search, size: 18, color: context.lc.muted),
                prefixIconConstraints: const BoxConstraints(minWidth: 40),
                suffixIcon: label.isEmpty
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Text(label, style: context.tt.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                      ),
                suffixIconConstraints: const BoxConstraints(minHeight: 20),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        ToolButton(icon: AppIcons.chevronDown, tooltip: s('viewer_next'), onPressed: widget.count > 0 ? () => widget.onStep(1) : null),
        RotatedBox(
          quarterTurns: 2,
          child: ToolButton(icon: AppIcons.chevronDown, tooltip: s('viewer_prev'), onPressed: widget.count > 0 ? () => widget.onStep(-1) : null),
        ),
        ToolButton(icon: AppIcons.close, tooltip: s('close'), onPressed: widget.onClose),
      ]),
    );
  }
}

// ------------------------------------------------------------------ page

/// Full-screen viewer for text, code and JSON files.
class TextFileViewer extends StatefulWidget {
  const TextFileViewer({super.key, required this.source, this.json = false});
  final ViewerSource source;
  final bool json;

  @override
  State<TextFileViewer> createState() => _TextFileViewerState();
}

class _TextFileViewerState extends State<TextFileViewer> {
  TextLoad? _load;
  Object? _error;
  String _text = '';
  String? _pretty;
  bool _formatted = true;
  bool _wrap = false;
  bool _searching = false;
  CodeSearch? _search;

  @override
  void initState() {
    super.initState();
    _wrap = !_isCode;
    _read();
  }

  bool get _isCode => languageFor(widget.source.name) != null && !const {'markdown'}.contains(languageFor(widget.source.name));

  Future<void> _read() async {
    try {
      final (head, total) = await widget.source.readHead(kViewerMaxBytes);
      final load = decodeTextHead(head, total);
      String? pretty;
      if (widget.json && !load.binary && !load.truncated && load.text.length < 2 * 1024 * 1024) {
        try {
          pretty = const JsonEncoder.withIndent('  ').convert(jsonDecode(load.text));
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _load = load;
        _pretty = pretty;
        _setText();
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _setText() {
    _text = (_formatted ? _pretty : null) ?? _load?.text ?? '';
    final lines = _text.split('\n');
    if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
    _search?.dispose();
    _search = CodeSearch(lines)..addListener(_onSearchChanged);
  }

  void _onSearchChanged() => setState(() {});

  @override
  void dispose() {
    _search?.dispose();
    super.dispose();
  }

  void _toggleSearch() => setState(() {
        _searching = !_searching;
        if (!_searching) _search?.set('');
      });

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final load = _load;
    final lineCount = _search == null ? 0 : '\n'.allMatches(_text.endsWith('\n') ? _text.substring(0, _text.length - 1) : _text).length + 1;
    final subtitle = load == null || load.binary
        ? null
        : joinInfo([
            languageLabel(widget.source.name),
            if (_text.isNotEmpty) s('viewer_lines', {'n': _fmtInt(lineCount)}),
            S.of(context).bytes(load.totalBytes),
          ]);
    final ok = load != null && !load.binary && _error == null;
    final actions = <ViewerAction>[
      if (ok) ViewerAction(icon: AppIcons.search, label: s('viewer_search'), onTap: _toggleSearch, active: _searching, pinned: true),
      if (ok && _pretty != null)
        ViewerAction(icon: AppIcons.codeBlock, label: _formatted ? s('viewer_formatted') : s('viewer_raw'), active: _formatted, onTap: () => setState(() {
              _formatted = !_formatted;
              _setText();
              _searching = false;
            })),
      if (ok) ViewerAction(icon: AppIcons.density, label: s('viewer_wrap'), active: _wrap, onTap: () => setState(() => _wrap = !_wrap)),
      if (ok) ViewerAction(icon: AppIcons.copy, label: s('viewer_copy_all'), onTap: () => copyText(context, _text, message: s('viewer_copied_all'))),
    ];

    Widget body;
    if (_error != null) {
      body = ViewerMessage(source: widget.source, icon: AppIcons.fileText, title: s('viewer_load_failed'), body: s('viewer_load_failed_body'));
    } else if (load == null) {
      body = const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    } else if (load.binary) {
      body = ViewerMessage(source: widget.source, icon: AppIcons.shieldWarning, title: s('viewer_binary_title'), body: s('viewer_binary_body'));
    } else if (_text.isEmpty) {
      body = ViewerMessage(source: widget.source, icon: AppIcons.fileText, title: s('viewer_empty_file'));
    } else {
      final lang = widget.json && _pretty != null ? 'json' : languageFor(widget.source.name);
      final tooBig = _text.length > kHighlightMaxChars && lang != null;
      body = Column(children: [
        if (load.truncated)
          ViewerNotice(
            icon: AppIcons.info,
            text: s('viewer_truncated', {'size': S.of(context).bytes(kViewerMaxBytes)}),
            action: s('viewer_open_external'),
            onAction: () => openFile(context, widget.source.path),
          )
        else if (tooBig)
          ViewerNotice(icon: AppIcons.info, text: s('viewer_no_highlight')),
        Expanded(child: CodeView(text: _text, language: lang, wrap: _wrap, search: _search)),
      ]);
    }

    return ViewerScaffold(
      source: widget.source,
      subtitle: subtitle,
      actions: actions,
      background: ok ? CodePalette.of(context).bg : null,
      bottomBar: _searching && _search != null
          ? SearchStrip(
              onQuery: _search!.set,
              onStep: _search!.step,
              onClose: _toggleSearch,
              count: _search!.matches.length,
              index: _search!.current,
            )
          : null,
      body: body,
    );
  }

}

String _fmtInt(int n) {
  final s = '$n';
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return b.toString();
}

/// Thin info strip at the top of a viewer body.
class ViewerNotice extends StatelessWidget {
  const ViewerNotice({super.key, required this.icon, required this.text, this.action, this.onAction});
  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: LC.warning.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.12 : 0.10),
        border: Border(bottom: BorderSide(color: context.lc.divider)),
      ),
      child: Row(children: [
        Icon(icon, size: 17, color: LC.warning),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: context.tt.bodySmall?.copyWith(color: context.lc.text))),
        if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
      ]),
    );
  }
}

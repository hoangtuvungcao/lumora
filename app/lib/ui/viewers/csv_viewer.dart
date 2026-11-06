// CSV / TSV viewer: RFC 4180 parsing (quotes, "" escapes, newlines inside
// quotes), delimiter auto-detection (, ; tab), sticky header, row numbers.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../chats/attachments.dart' show openFile;
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import 'file_viewer.dart';
import 'text_viewer.dart';

/// Rows shown at most (the rest: "Mở bằng ứng dụng khác").
const kCsvMaxRows = 5000;

class CsvTable {
  const CsvTable(this.rows, this.totalRows, this.delimiter);
  final List<List<String>> rows;
  final int totalRows;
  final String delimiter;
  int get columns => rows.fold(0, (m, r) => math.max(m, r.length));
}

/// Most frequent of `,` `;` tab outside quotes in the first lines.
String detectDelimiter(String text) {
  const cands = [',', ';', '\t'];
  final counts = {for (final c in cands) c: 0};
  var inQ = false;
  var lines = 0;
  for (var i = 0; i < text.length && lines < 5; i++) {
    final ch = text[i];
    if (ch == '"') {
      inQ = !inQ;
    } else if (!inQ) {
      if (ch == '\n') {
        lines++;
      } else if (counts.containsKey(ch)) {
        counts[ch] = counts[ch]! + 1;
      }
    }
  }
  var best = ',';
  for (final c in cands) {
    if (counts[c]! > counts[best]!) best = c;
  }
  return best;
}

/// RFC 4180 parser; keeps at most [maxRows] rows but counts them all.
CsvTable parseCsv(String text, {String? delimiter, int maxRows = kCsvMaxRows}) {
  if (text.startsWith('﻿')) text = text.substring(1);
  final d = delimiter ?? detectDelimiter(text);
  final rows = <List<String>>[];
  var total = 0;
  var row = <String>[];
  final field = StringBuffer();
  var inQ = false;
  var any = false; // current row has content

  void endField() {
    row.add(field.toString());
    field.clear();
  }

  void endRow() {
    endField();
    if (row.length > 1 || row.first.isNotEmpty || any) {
      total++;
      if (rows.length < maxRows) rows.add(row);
    }
    row = <String>[];
    any = false;
  }

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inQ) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQ = false;
        }
      } else {
        field.write(ch);
      }
      continue;
    }
    if (ch == '"' && field.isEmpty) {
      inQ = true;
      any = true;
    } else if (ch == d) {
      endField();
      any = true;
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      endRow();
    } else {
      field.write(ch);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty || any) endRow();
  return CsvTable(rows, total, d);
}

class CsvFileViewer extends StatefulWidget {
  const CsvFileViewer({super.key, required this.source});
  final ViewerSource source;

  @override
  State<CsvFileViewer> createState() => _CsvFileViewerState();
}

class _CsvFileViewerState extends State<CsvFileViewer> {
  TextLoad? _load;
  CsvTable? _table;
  Object? _error;
  final _v = ScrollController();
  final _h = ScrollController();

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void dispose() {
    _v.dispose();
    _h.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    try {
      final (head, total) = await widget.source.readHead(kViewerMaxBytes);
      final load = decodeTextHead(head, total);
      final table = load.binary ? null : parseCsv(load.text, delimiter: fileExt(widget.source.name) == 'tsv' ? '\t' : null);
      if (mounted) {
        setState(() {
          _load = load;
          _table = table;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  static final _num = RegExp(r'^[-+]?[\d.,\s]+%?$');
  static const _blank = {'-', '—', '–', 'N/A', 'n/a', 'NA', '?'};

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final t = _table;
    final load = _load;
    Widget body;
    if (_error != null) {
      body = ViewerMessage(source: widget.source, icon: AppIcons.spreadsheet, title: s('viewer_load_failed'), body: s('viewer_load_failed_body'));
    } else if (load == null) {
      body = const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    } else if (load.binary || t == null) {
      body = ViewerMessage(source: widget.source, icon: AppIcons.shieldWarning, title: s('viewer_binary_title'), body: s('viewer_binary_body'));
    } else if (t.rows.isEmpty) {
      body = ViewerMessage(source: widget.source, icon: AppIcons.spreadsheet, title: s('viewer_empty_file'));
    } else {
      body = Column(children: [
        if (t.totalRows > t.rows.length || load.truncated)
          ViewerNotice(
            icon: AppIcons.info,
            text: load.truncated
                ? s('viewer_truncated', {'size': s.bytes(kViewerMaxBytes)})
                : s('viewer_rows_capped', {'shown': t.rows.length, 'n': t.totalRows}),
            action: s('viewer_open_external'),
            onAction: () => openFile(context, widget.source.path),
          ),
        Expanded(child: _grid(context, t)),
      ]);
    }
    return ViewerScaffold(
      source: widget.source,
      subtitle: t == null ? null : joinInfo([s('viewer_rows', {'n': t.totalRows > 0 ? t.totalRows - 1 : 0, 'c': t.columns}), if (load != null) s.bytes(load.totalBytes)]),
      actions: [
        if (t != null && t.rows.isNotEmpty) ViewerAction(icon: AppIcons.copy, label: s('viewer_copy_all'), onTap: () => copyText(context, load!.text, message: s('viewer_copied_all'))),
      ],
      body: body,
    );
  }

  Widget _grid(BuildContext context, CsvTable t) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cols = t.columns;
    final header = t.rows.first;
    final data = t.rows.sublist(1);
    // column widths from the header and a sample of rows
    final widths = List<double>.filled(cols, 72);
    final sample = t.rows.take(200);
    for (final r in sample) {
      for (var c = 0; c < r.length; c++) {
        final len = r[c].split('\n').first.length;
        widths[c] = math.max(widths[c], math.min(340, len * 7.7 + 32));
      }
    }
    for (var c = 0; c < header.length; c++) {
      widths[c] = math.max(widths[c], math.min(340, header[c].length * 8.2 + 36));
    }
    final numberW = math.max(48.0, '${data.length}'.length * 9.0 + 28);
    final totalW = numberW + widths.fold<double>(0, (a, b) => a + b);
    final numeric = List<bool>.generate(cols, (c) {
      var n = 0, all = 0;
      for (final r in data.take(100)) {
        final v = c < r.length ? r[c].trim() : '';
        if (v.contains(RegExp(r'\d'))) {
          all++;
          if (_num.hasMatch(v)) n++;
        } else if (v.isNotEmpty && !_blank.contains(v)) {
          all++;
        }
      }
      return all > 0 && n * 10 >= all * 8;
    });
    final textStyle = context.tt.bodyMedium?.copyWith(fontSize: 13.5);
    final headStyle = context.tt.bodyMedium?.copyWith(fontSize: 13, fontWeight: FontWeight.w600);
    final muted = context.tt.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final line = BorderSide(color: context.lc.divider);
    final zebra = dark ? Colors.white.withValues(alpha: 0.025) : const Color(0xFFF6F7FB);

    Widget cell(String v, double w, {TextStyle? style, bool right = false}) => Container(
          width: w,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: right ? Alignment.centerRight : Alignment.centerLeft,
          decoration: BoxDecoration(border: Border(right: line)),
          child: Text(v.replaceAll('\n', ' ⏎ '), maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
        );

    Widget rowOf(List<String> r, List<double> ws, {required String index, TextStyle? style, Color? bg, bool head = false}) => Container(
          height: head ? 40 : 36,
          decoration: BoxDecoration(color: bg, border: Border(bottom: line)),
          child: Row(children: [
            cell(index, numberW, style: muted, right: true),
            for (var c = 0; c < cols; c++) cell(c < r.length ? r[c] : '', ws[c], style: style, right: numeric[c]),
          ]),
        );

    return LayoutBuilder(builder: (context, box) {
      // a narrow table: the last column takes the rest of the width
      final ws = List<double>.of(widths);
      if (totalW < box.maxWidth && cols > 0) ws[cols - 1] += box.maxWidth - totalW;
      final w = math.max(box.maxWidth, totalW);
      return Scrollbar(
        controller: _v,
        notificationPredicate: (n) => n.depth == 1,
        child: Scrollbar(
          controller: _h,
          child: SingleChildScrollView(
            controller: _h,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: w,
              child: Column(children: [
                rowOf(header, ws, index: '#', style: headStyle, bg: context.lc.surface2, head: true),
                Expanded(
                  child: SelectionArea(
                    child: ListView.builder(
                      controller: _v,
                      itemExtent: 36,
                      itemCount: data.length,
                      itemBuilder: (c, i) => rowOf(data[i], ws, index: '${i + 1}', style: textStyle, bg: i.isOdd ? zebra : context.lc.surface),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
    });
  }
}

// PDF viewer on pdfrx (PDFium, the non-V8 build: no JavaScript ever runs).
// Page thumbnails (sidebar on desktop, sheet on phones), zoom, text search,
// page jump; links inside the PDF always ask before opening.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart' show PhosphorIconsRegular;

import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import 'file_viewer.dart';
import 'text_viewer.dart' show SearchStrip;

Future<void>? _pdfInit;

/// Loads PDFium once (safe to call many times, from anywhere).
Future<void> ensurePdfium() => _pdfInit ??= pdfrxFlutterInitialize(dismissPdfiumWasmWarnings: true);

class PdfFileViewer extends StatefulWidget {
  const PdfFileViewer({super.key, required this.source});
  final ViewerSource source;

  @override
  State<PdfFileViewer> createState() => _PdfFileViewerState();
}

class _PdfFileViewerState extends State<PdfFileViewer> {
  final _ctrl = PdfViewerController();
  /// Created once the viewer is attached (it needs the loaded document).
  PdfTextSearcher? _searcher;
  late final Future<void> _init = ensurePdfium();
  bool _ready = false;
  bool _failed = false;
  int _pages = 0;
  int _page = 1;
  int _size = 0;
  bool _searching = false;
  bool? _sidebar;

  @override
  void initState() {
    super.initState();
    widget.source.size().then((v) {
      if (mounted) setState(() => _size = v);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _searcher?.removeListener(_changed);
    _searcher?.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<String?> _askPassword() async {
    if (!mounted) return null;
    final s = S.read(context);
    final ctrl = TextEditingController();
    final r = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(s('viewer_pdf_password')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          decoration: InputDecoration(hintText: s('viewer_pdf_password_hint')),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(s('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: Text(s('open'))),
        ],
      ),
    );
    ctrl.dispose();
    return r;
  }

  Future<void> _jump() async {
    if (!_ready || _pages <= 1) return;
    final s = S.read(context);
    final v = await promptText(context, title: s('viewer_go_to_page'), hint: s('viewer_page_hint', {'n': _pages}), action: s('viewer_go'));
    final n = int.tryParse(v?.trim() ?? '');
    if (n != null) await _goTo(n.clamp(1, _pages));
  }

  Future<void> _goTo(int n) => _ctrl.goToPage(pageNumber: n, anchor: PdfPageAnchor.top);

  void _toggleSearch() => setState(() {
        _searching = !_searching;
        if (!_searching) _searcher?.resetTextSearch();
      });

  void _showThumbSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => SizedBox(
        height: MediaQuery.sizeOf(c).height * 0.72,
        child: _Thumbnails(controller: _ctrl, pages: _pages, current: _page, grid: true, onTap: (n) {
          Navigator.pop(c);
          _goTo(n);
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final desktop = isDesktop(context);
    final sidebar = _sidebar ?? desktop;
    final bg = dark ? const Color(0xFF0B0C18) : const Color(0xFFE4E7F2);

    final params = PdfViewerParams(
      backgroundColor: bg,
      margin: desktop ? 20 : 10,
      maxScale: 8,
      // fit the width, but no wider than a comfortable reading width
      calculateInitialZoom: (doc, c, fitZoom, coverZoom) {
        final w = doc.pages.isEmpty ? 0.0 : doc.pages.first.width + 2 * (desktop ? 20 : 10);
        return w <= 0 ? null : math.min(coverZoom, 920 / w);
      },
      pageDropShadow: kNoShadows ? null : BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.5 : 0.14), blurRadius: 14, offset: const Offset(0, 3)),
      matchTextColor: const Color(0x66FFD54F),
      activeMatchTextColor: const Color(0xAAFF9800),
      pagePaintCallbacks: [(canvas, rect, page) => _searcher?.pageTextMatchPaintCallback(canvas, rect, page)],
      linkHandlerParams: PdfLinkHandlerParams(
        linkColor: LC.primary.withValues(alpha: 0.08),
        onLinkTap: (link) {
          if (link.url != null) {
            confirmOpenLink(context, link.url.toString());
          } else if (link.dest != null) {
            _ctrl.goToDest(link.dest);
          }
        },
      ),
      onViewerReady: (doc, c) => setState(() {
        _ready = true;
        _pages = doc.pages.length;
        _searcher ??= PdfTextSearcher(_ctrl)..addListener(_changed);
      }),
      onPageChanged: (n) {
        if (n != null && n != _page) setState(() => _page = n);
      },
      loadingBannerBuilder: (c, got, total) => const Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
      errorBannerBuilder: (c, error, st, ref) {
        if (!_failed) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _failed = true);
          });
        }
        return const SizedBox();
      },
      viewerOverlayBuilder: (c, size, handleLinkTap) => [
        if (_ready)
          Positioned(
            bottom: 16,
            left: 0,
            right: 0,
            child: Center(child: _PagePill(page: _page, pages: _pages, onTap: _jump)),
          ),
        if (_ready && desktop)
          Positioned(
            right: 16,
            bottom: 16,
            child: _ZoomButtons(onIn: () => _ctrl.zoomUp(), onOut: () => _ctrl.zoomDown()),
          ),
      ],
    );

    final viewer = widget.source.isAsset
        ? PdfViewer.asset(widget.source.assetKey, controller: _ctrl, params: params)
        : PdfViewer.file(widget.source.path, controller: _ctrl, params: params, passwordProvider: _askPassword);

    Widget body = FutureBuilder<void>(
      future: _init,
      builder: (c, snap) {
        if (snap.hasError || _failed) {
          return ViewerMessage(source: widget.source, icon: AppIcons.fileText, title: s('viewer_pdf_failed'), body: s('viewer_load_failed_body'));
        }
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
        return Row(children: [
          // laid out from the start so the page zoom doesn't jump when it fills in
          if (sidebar) ...[
            SizedBox(
              width: 176,
              child: _ready && _pages > 0 ? _Thumbnails(controller: _ctrl, pages: _pages, current: _page, onTap: _goTo) : ColoredBox(color: context.lc.surface),
            ),
            VerticalDivider(width: 1, color: context.lc.divider),
          ],
          Expanded(child: viewer),
        ]);
      },
    );

    return ViewerScaffold(
      source: widget.source,
      background: bg,
      subtitle: joinInfo([
        'PDF',
        if (_pages > 0) s('viewer_pages_n', {'n': _pages}),
        if (_size > 0) s.bytes(_size),
      ]),
      actions: [
        if (_ready) ViewerAction(icon: AppIcons.search, label: s('viewer_search'), active: _searching, pinned: true, onTap: _toggleSearch),
        if (_ready)
          ViewerAction(
            icon: AppIcons.gallery,
            label: s('viewer_thumbnails'),
            active: desktop && sidebar,
            pinned: true,
            onTap: desktop ? () => setState(() => _sidebar = !sidebar) : _showThumbSheet,
          ),
        if (_ready && !desktop) ViewerAction(icon: AppIcons.bookmark, label: s('viewer_go_to_page'), onTap: _jump),
      ],
      bottomBar: _searching && _searcher != null
          ? SearchStrip(
              onQuery: (q) => _searcher!.startTextSearch(q, caseInsensitive: true, goToFirstMatch: true),
              onStep: (d) => d > 0 ? _searcher!.goToNextMatch() : _searcher!.goToPrevMatch(),
              onClose: _toggleSearch,
              count: _searcher!.matches.length,
              index: _searcher!.currentIndex ?? 0,
              busy: _searcher!.isSearching,
            )
          : null,
      body: body,
    );
  }
}

class _PagePill extends StatelessWidget {
  const _PagePill({required this.page, required this.pages, required this.onTap});
  final int page;
  final int pages;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Tooltip(
      message: s('viewer_go_to_page'),
      child: Material(
        color: Colors.black.withValues(alpha: 0.72),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              s('viewer_page_of', {'i': page, 'n': pages}),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
        ),
      ),
    );
  }
}

class _ZoomButtons extends StatelessWidget {
  const _ZoomButtons({required this.onIn, required this.onOut});
  final VoidCallback onIn;
  final VoidCallback onOut;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    Widget b(IconData i, String tip, VoidCallback f) => Tooltip(
          message: tip,
          child: InkWell(
            onTap: f,
            child: SizedBox(width: 40, height: 40, child: Icon(i, size: 20, color: context.lc.text)),
          ),
        );
    return Material(
      color: context.lc.surface,
      elevation: kNoShadows ? 0 : 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md), side: BorderSide(color: context.lc.divider)),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        b(PhosphorIconsRegular.magnifyingGlassPlus, s('viewer_zoom_in'), onIn),
        Container(height: 1, width: 40, color: context.lc.divider),
        b(PhosphorIconsRegular.magnifyingGlassMinus, s('viewer_zoom_out'), onOut),
      ]),
    );
  }
}

/// Page thumbnails: a column (sidebar) or a grid (phone sheet).
class _Thumbnails extends StatelessWidget {
  const _Thumbnails({required this.controller, required this.pages, required this.current, required this.onTap, this.grid = false});
  final PdfViewerController controller;
  final int pages;
  final int current;
  final ValueChanged<int> onTap;
  final bool grid;

  @override
  Widget build(BuildContext context) {
    final doc = controller.isReady ? controller.document : null;
    if (doc == null) return const SizedBox();
    Widget tile(int n) {
      final on = n == current;
      return InkWell(
        onTap: () => onTap(n),
        borderRadius: BorderRadius.circular(Radii.md),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(children: [
            Expanded(
              child: AnimatedContainer(
                duration: Motion.fast,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: on ? LC.primary : context.lc.divider, width: on ? 2 : 1),
                ),
                padding: const EdgeInsets.all(2),
                child: PdfPageView(
                  document: doc,
                  pageNumber: n,
                  maximumDpi: 72,
                  decoration: const BoxDecoration(color: Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text('$n', style: context.tt.bodySmall?.copyWith(color: on ? LC.primary : context.lc.muted, fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
          ]),
        ),
      );
    }

    if (grid) {
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 140, childAspectRatio: 0.62, mainAxisSpacing: 4, crossAxisSpacing: 4),
        itemCount: pages,
        itemBuilder: (c, i) => tile(i + 1),
      );
    }
    return ColoredBox(
      color: context.lc.surface,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemExtent: 214,
        itemCount: pages,
        itemBuilder: (c, i) => tile(i + 1),
      ),
    );
  }
}

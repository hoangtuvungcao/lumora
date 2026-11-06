// Makes the previews the sender attaches to a file (see file_preview.dart):
// PDF first page rendered with pdfium, text snippet + line count.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

import '../ui/viewers/pdf_viewer.dart' show ensurePdfium;
import 'file_preview.dart';

// ------------------------------------------------------------------ PDF

/// Encodes BGRA pixels as a JPEG ≤ [kTargetPreviewImage] (lower quality, then
/// smaller, until it fits). Runs in an isolate.
Uint8List? encodePreviewJpeg((Uint8List, int, int) a) {
  final (bgra, w, h) = a;
  var im = img.Image.fromBytes(width: w, height: h, bytes: bgra.buffer, order: img.ChannelOrder.bgra, numChannels: 4);
  for (var attempt = 0; attempt < 6; attempt++) {
    for (final q in const [74, 62, 50]) {
      final jpg = img.encodeJpg(im, quality: q);
      if (jpg.length <= kTargetPreviewImage) return jpg;
    }
    if (im.width <= 160) break;
    im = img.copyResize(im, width: (im.width * 0.8).round(), interpolation: img.Interpolation.average);
  }
  return null;
}

/// First page (~480 px wide JPEG) + page count. Null when the PDF can't be
/// opened (encrypted, damaged…).
Future<LocalPreview?> pdfPreview(String path, {int width = 480}) async {
  await ensurePdfium();
  final doc = await PdfDocument.openFile(path);
  try {
    final pages = doc.pages.length;
    if (pages == 0) return null;
    final page = doc.pages.first;
    final aspect = page.height / math.max(1, page.width);
    final w = width;
    // very tall pages (receipts) are cropped to the top 2:1
    final fullH = (w * aspect).round();
    final h = math.min(fullH, w * 2);
    final pi = await page.render(width: w, height: h, fullWidth: w.toDouble(), fullHeight: fullH.toDouble(), backgroundColor: 0xFFFFFFFF);
    if (pi == null) return LocalPreview(preview: FilePreview(kind: 'pdf', pages: pages));
    final px = Uint8List.fromList(pi.pixels);
    final (pw, ph) = (pi.width, pi.height);
    pi.dispose();
    final jpg = await compute(encodePreviewJpeg, (px, pw, ph));
    return LocalPreview(preview: FilePreview(kind: 'pdf', pages: pages), image: jpg, width: pw, height: ph);
  } finally {
    await doc.dispose();
  }
}

// ------------------------------------------------------------------ entry

/// Preview to send with [path], or null (never throws, gives up after
/// [timeout] so sending is never held up).
Future<LocalPreview?> buildFilePreview(String path, {Duration timeout = const Duration(seconds: 6)}) async {
  final name = path.split(RegExp(r'[/\\]')).last;
  try {
    if (isPdfName(name)) return await pdfPreview(path).timeout(timeout);
    if (isTextPreviewable(name)) return await textPreview(path).timeout(timeout);
  } catch (e) {
    debugPrint('file preview for $name skipped: $e');
  }
  return null;
}

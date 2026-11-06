// Public entry points of the photo editor.
//
//  * [showPhotoSendPreview] — picked / pasted / dropped photos: preview with
//    caption + "Chỉnh sửa" before sending.
//  * [openPhotoEditorFromViewer] — "Chỉnh sửa" in the media viewer: edit, then
//    send to this chat, forward, or save to the device. The original message
//    is never touched; the result is a new message.

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../widgets/common.dart';
import 'photo_editor_screen.dart';
import 'photo_io.dart';

export 'photo_editor_screen.dart' show PhotoEditorResult, PhotoEditorScreen, PhotoEditorPurpose;
export 'photo_io.dart' show isEditablePhoto, saveExistingPhotoToDevice;

Route<PhotoEditorResult> _route(Widget child) => PageRouteBuilder<PhotoEditorResult>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (_, _, _) => child,
      transitionsBuilder: (_, a, _, c) => FadeTransition(
        opacity: CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
        child: ScaleTransition(scale: Tween(begin: 0.98, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: c),
      ),
    );

/// True when every path is a still photo the editor can open.
bool canPreviewPhotos(List<String> paths) => paths.isNotEmpty && paths.every(isEditablePhoto);

Future<void> showPhotoSendPreview(BuildContext context, {required String conv, required List<String> paths, VoidCallback? onSent}) async {
  final r = await Navigator.of(context, rootNavigator: true).push(_route(PhotoEditorScreen(conv: conv, paths: paths)));
  if (r != null) onSent?.call();
}

Future<PhotoEditorResult?> openPhotoEditorFromViewer(BuildContext context, {required String conv, required String path}) async {
  final s = S.read(context);
  final r = await Navigator.of(context, rootNavigator: true).push(_route(
    PhotoEditorScreen(conv: conv, paths: [path], purpose: PhotoEditorPurpose.fromViewer, startEditing: true),
  ));
  if (r == PhotoEditorResult.forwarded && context.mounted) toast(context, s('pe_forwarded'));
  return r;
}

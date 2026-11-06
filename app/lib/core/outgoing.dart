// Files the app makes for sending (voice notes, memes). The core keeps
// serving a sent file from its path (peers download it later, the sender's
// own bubble plays/shows it), so they live in app support — never in a temp
// folder the system may empty.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Overrides the base folder (tests).
Directory? debugOutgoingBase;

/// `<app support>/outgoing`, created if needed.
Future<Directory> outgoingDir() async {
  Directory base;
  if (debugOutgoingBase != null) {
    base = debugOutgoingBase!;
  } else {
    try {
      base = await getApplicationSupportDirectory();
    } catch (_) {
      base = Directory.systemTemp; // unsupported platform
    }
  }
  final d = Directory('${base.path}${Platform.pathSeparator}outgoing');
  await d.create(recursive: true);
  return d;
}

/// A fresh path in [outgoingDir] named `<prefix>_<time>.<ext>`.
Future<String> outgoingPath(String prefix, String ext) async {
  final d = await outgoingDir();
  return '${d.path}${Platform.pathSeparator}${prefix}_${DateTime.now().microsecondsSinceEpoch}.$ext';
}

/// Deletes a file the app made for sending but that was not sent.
Future<void> discardOutgoing(String? path) async {
  if (path == null) return;
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } catch (_) {}
}

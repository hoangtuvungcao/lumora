// "Forgot the data password": the old data folder is moved aside — never
// deleted — and the account is restored fresh from the recovery phrase or a
// backup file. The user can later try the old password on the folder that
// was kept aside ("Try old password"), which swaps the folders back.

import 'dart:io';

import '../app.dart';
import '../core/api.dart';
import 'stores.dart';

/// A data folder kept aside.
class AsideData {
  AsideData(this.path);
  final String path;

  /// true = moved aside because the password was forgotten (still locked).
  bool get locked => path.contains('.locked-');

  /// Moment it was set aside, parsed from the `-yyyyMMdd-HHmmss` suffix.
  DateTime? get when {
    final m = RegExp(r'-(\d{8})-(\d{6})$').firstMatch(path);
    if (m == null) return null;
    final d = m.group(1)!, t = m.group(2)!;
    return DateTime(int.parse(d.substring(0, 4)), int.parse(d.substring(4, 6)), int.parse(d.substring(6, 8)),
        int.parse(t.substring(0, 2)), int.parse(t.substring(2, 4)), int.parse(t.substring(4, 6)));
  }
}

/// Plain error codes shown with `err_<code>` strings.
class RescueException implements Exception {
  RescueException(this.code);
  final String code;
  @override
  String toString() => code;
}

class DataRescue {
  DataRescue(this.sv);
  final AppServices sv;

  bool get _fs => !sv.api.isMock && sv.dataDir.isNotEmpty;

  static String stamp(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}-${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  /// Folders kept aside that still exist, newest first.
  List<AsideData> get aside => [
        for (final p in sv.settings.asideData)
          if (!_fs || Directory(p).existsSync()) AsideData(p),
      ];

  /// Moves the current data aside and restores the account from [phrase]
  /// or [backup] (file, password). Undone if the restore fails.
  Future<void> restoreFresh({String? phrase, (String, String)? backup}) async {
    final dir = sv.dataDir;
    // The phrase must belong to the locked account: any valid phrase would
    // otherwise silently replace it with a different account.
    if (phrase != null && (!_fs || Directory(dir).existsSync())) {
      final same = await sv.api.phraseMatches(dir, phrase).catchError((_) => null);
      if (same == false) throw RescueException('rescue_wrong_phrase');
    }
    final kept = '$dir.locked-${stamp(DateTime.now())}';
    if (_fs && Directory(dir).existsSync()) {
      try {
        await Directory(dir).rename(kept);
      } on FileSystemException {
        // Windows: the folder is still in use after a failed password try.
        throw RescueException('rescue_restart_needed');
      }
    }
    sv.settings.update((s) => s.asideData = [kept, ...s.asideData]);
    try {
      await sv.createIdentity(name: sv.settings.name, restorePhrase: phrase, restoreBackup: backup);
    } catch (_) {
      await _undo(kept);
      rethrow;
    }
  }

  Future<void> _undo(String kept) async {
    sv.settings.update((s) => s.asideData = s.asideData.where((p) => p != kept).toList());
    if (!_fs) return;
    try {
      final fresh = Directory(sv.dataDir);
      if (fresh.existsSync()) {
        // The failed start only created an empty shell (lock file); keep
        // anything else, just in case.
        final names = fresh.listSync().map((e) => e.uri.pathSegments.where((x) => x.isNotEmpty).last).toSet();
        if (names.difference({'.lock'}).isEmpty) {
          await fresh.delete(recursive: true);
        } else {
          await fresh.rename('${sv.dataDir}.failed-${stamp(DateTime.now())}');
        }
      }
      if (Directory(kept).existsSync()) await Directory(kept).rename(sv.dataDir);
    } catch (_) {}
  }

  /// Puts [target] (kept aside) back in use and keeps the current data
  /// aside, then opens it like a fresh launch (asks for its password).
  /// Returns false when Lumora has to be reopened to finish.
  Future<bool> switchTo(String target) async {
    final dir = sv.dataDir;
    final kept = '$dir.kept-${stamp(DateTime.now())}';
    if (!_fs) {
      // Demo mode: no folders, just the visible flow.
      sv.settings.update((s) {
        s.asideData = [kept, ...s.asideData.where((p) => p != target)];
        s.hasPassphrase = AsideData(target).locked;
      });
      sv.session.setPhase(AsideData(target).locked ? SessionPhase.locked : SessionPhase.ready);
      return true;
    }
    final running = sv.session.phase == SessionPhase.ready;
    // halt, not stop: stop() closes the event stream for good and the app
    // would never hear from the core again after [AppServices.boot].
    if (running) await sv.api.halt().catchError((_) {});
    try {
      await Directory(dir).rename(kept);
    } on FileSystemException {
      // In use (Windows keeps the folder locked until Lumora closes): do it
      // at the next launch instead.
      sv.settings.update((s) => s.pendingDataSwitch = target);
      if (running) await sv.boot();
      return false;
    }
    try {
      await Directory(target).rename(dir);
    } on FileSystemException {
      await Directory(kept).rename(dir).catchError((_) => Directory(kept));
      if (running) await sv.boot();
      throw RescueException('rescue_move_failed');
    }
    sv.settings.update((s) => s.asideData = [kept, ...s.asideData.where((p) => p != target)]);
    await sv.boot();
    return true;
  }

  /// Called before the core starts: finishes a switch that had to wait.
  static Future<void> finishPending(AppServices sv) async {
    final target = sv.settings.pendingDataSwitch;
    if (target.isEmpty || sv.api.isMock) return;
    sv.settings.update((s) => s.pendingDataSwitch = '');
    final dir = sv.dataDir;
    if (!Directory(target).existsSync()) return;
    final kept = '$dir.kept-${stamp(DateTime.now())}';
    try {
      if (Directory(dir).existsSync()) await Directory(dir).rename(kept);
      await Directory(target).rename(dir);
      sv.settings.update((s) => s.asideData = [kept, ...s.asideData.where((p) => p != target)]);
    } on FileSystemException {
      if (!Directory(dir).existsSync() && Directory(kept).existsSync()) await Directory(kept).rename(dir).catchError((_) => Directory(kept));
    }
  }

  /// Friendly message for a failed restore.
  /// Anything that isn't a known code (file system, platform) is `internal`:
  /// raw exception text is never shown.
  static String errorCode(Object e) => e is RescueException
      ? e.code
      : (e is ApiException ? e.message : 'internal');
}

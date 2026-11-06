// Account backup file: save one (Settings › Security) and pick one to
// restore from (onboarding). The core encrypts the file with a password.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../widgets/sensitive_gate.dart';
import '../widgets/app_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/settings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/secure_input.dart';
import '../../state/password_policy.dart';

const kBackupExt = 'lumora-backup';

/// Plain sentence for an error (bare codes like "internal" become friendly text).
String friendlyError(S s, Object e) => errorMessage(s, e);
const kBackupMinPassword = 8;

/// Lets the user pick a backup file; returns its local path.
Future<String?> pickBackupFile() async {
  try {
    final f = await FilePicker.pickFile(type: FileType.any);
    return f?.path;
  } catch (_) {
    return null;
  }
}

/// File chooser row used by the restore screen.
class BackupFileTile extends StatelessWidget {
  const BackupFileTile({super.key, required this.path, required this.onTap});
  final String? path;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = path;
    final name = p?.split(RegExp(r'[\\/]')).last;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(14);
    return Semantics(
      button: true,
      label: name ?? s('bk_pick'),
      child: Material(
        color: p == null ? LC.primary.withValues(alpha: dark ? 0.10 : 0.06) : (dark ? const Color(0xFF1B1F3A) : const Color(0xFFF2F3FA)),
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: p == null ? LC.primary.withValues(alpha: 0.45) : (dark ? const Color(0xFF2A2F55) : const Color(0xFFE1E4F0)),
              ),
            ),
            child: Row(children: [
              IconTile(p == null ? AppIcons.folder : AppIcons.fileArchive, color: p == null ? LC.primary : LC.success),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name ?? s('bk_pick'), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 14.5)),
                  const SizedBox(height: 2),
                  Text(p == null ? s('bk_pick_hint') : File(p).parent.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall),
                ]),
              ),
              const SizedBox(width: 10),
              if (p == null)
                Icon(AppIcons.chevronRight, size: 18, color: LC.primary)
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(color: LC.primary.withValues(alpha: dark ? 0.18 : 0.10), borderRadius: BorderRadius.circular(20)),
                  child: Text(s('bk_change'), style: context.tt.bodySmall?.copyWith(color: dark ? const Color(0xFFB4AAFF) : LC.primary, fontWeight: FontWeight.w600)),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Settings › Security row.
class BackupRow extends StatelessWidget {
  const BackupRow({super.key});
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final last = context.select<Settings, int>((x) => x.lastBackupAt);
    final sub = last == 0 ? s('bk_row_hint') : s('bk_last', {'date': s.dayLabel(DateTime.fromMillisecondsSinceEpoch(last), DateTime.now())});
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: const RowIcon(AppIcons.backup),
      title: Text(s('bk_title')),
      subtitle: Text(sub),
      trailing: const Icon(AppIcons.chevronRight, size: 18),
      onTap: () => showBackupDialog(context),
    );
  }
}

/// Password (twice) → save location → encrypted backup file.
Future<void> showBackupDialog(BuildContext context, {bool previewFilled = false}) async {
  // A backup file opens the account anywhere: owner check, never while the
  // screen is shared, never in screenshots.
  if (!previewFilled && !await confirmOwner(context, title: S.read(context)('bk_title'))) return;
  if (!context.mounted) return;
  final saved = await showSecureDialog<String>(context, builder: (_) => SensitiveScreen(child: _BackupDialog(previewFilled: previewFilled)));
  if (saved == null || !context.mounted) return;
  final s = S.read(context);
  await showSecureDialog<void>(
    context,
    builder: (c) => SecureDialogFrame(
      onEscape: () => Navigator.pop(c),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SecureHero(icon: AppIcons.shieldCheck, tone: LC.success, title: s('bk_done_title'), subtitle: s('bk_done_body'), compact: true),
        if (saved.isNotEmpty) ...[
          const SizedBox(height: 24),
          SecureLabel(s('bk_saved_at')),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: c.lc.surface2, borderRadius: BorderRadius.circular(Radii.md)),
            child: Row(children: [
              const Icon(AppIcons.fileArchive, size: 18, color: LC.success),
              const SizedBox(width: 10),
              Expanded(child: SelectableText(saved, style: c.tt.bodySmall?.copyWith(color: c.lc.text, height: 1.4))),
            ]),
          ),
        ],
        const SizedBox(height: 28),
        SecurePrimaryButton(label: s('done'), icon: AppIcons.check, onPressed: () => Navigator.pop(c)),
      ]),
    ),
  );
}

class _BackupDialog extends StatefulWidget {
  const _BackupDialog({this.previewFilled = false});
  final bool previewFilled;
  @override
  State<_BackupDialog> createState() => _BackupDialogState();
}

class _BackupDialogState extends State<_BackupDialog> {
  late final _pw = TextEditingController(text: widget.previewFilled ? 'mây-trôi-2026' : '');
  late final _pw2 = TextEditingController(text: widget.previewFilled ? 'mây-trôi-2026' : '');
  final _current = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    _pw2.dispose();
    _current.dispose();
    super.dispose();
  }

  bool get _lenOk => _pw.text.characters.length >= kBackupMinPassword;
  bool get _strongOk => _lenOk && passwordProblem(_pw.text, minLength: kBackupMinPassword) == null;
  bool get _matchOk => _pw.text.isNotEmpty && _pw.text == _pw2.text;

  Future<void> _save() async {
    if (!_strongOk || !_matchOk || _busy || (_needsPass(context) && _current.text.isEmpty)) return;
    final s = S.read(context);
    final api = context.read<LumoraApi>();
    final settings = context.read<Settings>();
    final needsPass = _needsPass(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    File? tmp;
    try {
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final name = 'lumora-${now.year}-${two(now.month)}-${two(now.day)}.$kBackupExt';
      final dir = await getTemporaryDirectory();
      tmp = File('${dir.path}${Platform.pathSeparator}$name');
      await api.exportBackup(tmp.path, _pw.text, passphrase: needsPass ? _current.text : null);
      final bytes = await tmp.readAsBytes();
      final uri = await FilePicker.saveFile(fileName: name, bytes: bytes, dialogTitle: s('bk_save'));
      if (uri == null) return; // cancelled: keep the dialog open
      settings.update((x) => x
        ..lastBackupAt = DateTime.now().millisecondsSinceEpoch
        ..phraseBackedUp = true);
      if (mounted) Navigator.pop(context, uri.scheme == 'file' ? uri.toFilePath() : (uri.pathSegments.isEmpty ? name : Uri.decodeComponent(uri.pathSegments.last)));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = friendlyError(s, e));
    } catch (e) {
      if (mounted) setState(() => _error = s('bk_save_failed'));
    } finally {
      try {
        if (tmp != null && tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      if (mounted) setState(() => _busy = false);
    }
  }

  static bool _needsPass(BuildContext context) {
    final p = context.read<SessionStore>().me?.protection ?? '';
    return p.isNotEmpty ? p == 'passphrase' : context.read<Settings>().hasPassphrase;
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final needsPass = _needsPass(context);
    final ready = _strongOk && _matchOk && (!needsPass || _current.text.isNotEmpty) && !_busy;
    void close() => Navigator.pop(context);
    return SecureDialogFrame(
      trailing: SecureNavButton.close(context, close),
      onEscape: _busy ? () {} : close,
      child: AutofillGroup(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SecureHero(icon: AppIcons.backup, title: s('bk_title'), subtitle: s('sec_bk_sub'), compact: true),
          const SizedBox(height: 24),
          PasswordField(
            controller: _pw,
            label: s('backup_password'),
            autofocus: !widget.previewFilled,
            newPassword: true,
            showStrength: true,
            minLength: kBackupMinPassword,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          PasswordField(
            controller: _pw2,
            label: s('bk_password_repeat'),
            newPassword: true,
            matchWith: _pw,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => needsPass ? null : _save(),
          ),
          if (needsPass) ...[
            const SizedBox(height: 16),
            PasswordField(
              controller: _current,
              label: s('bk_current_pass'),
              icon: AppIcons.key,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _save(),
            ),
          ],
          const SizedBox(height: 20),
          SecureNote(s('bk_pw_note'), icon: AppIcons.warning, color: LC.warning),
          const SizedBox(height: 12),
          SecureMessage(s('bk_intro'), tone: SecureTone.info, icon: AppIcons.package),
          if (_error != null) ...[const SizedBox(height: 12), SecureMessage(_error!)],
          const SizedBox(height: 24),
          SecurePrimaryButton(label: s('bk_save'), icon: AppIcons.save, busy: _busy, onPressed: ready ? _save : null),
          const SizedBox(height: 8),
          Center(child: TextButton(onPressed: _busy ? null : close, child: Text(s('cancel')))),
        ]),
      ),
    );
  }
}

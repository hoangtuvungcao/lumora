// "Forgot password?" for the data password (startup lock screen) and the
// "old data kept aside" rows in Settings › Security.

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../app.dart';
import '../../l10n/strings.dart';
import '../../state/data_rescue.dart';
import '../../state/settings.dart';
import '../settings/backup_file.dart';
import '../settings/security_checkup.dart' show showPassphraseDialog;
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/secure_input.dart';

Future<void> showForgotPassphrase(BuildContext context, {bool previewFile = false, String? previewPath}) async {
  final nav = Navigator.of(context);
  final ok = await showSecureDialog<bool>(
    context,
    builder: (_) => _ForgotPassphraseDialog(previewFile: previewFile, previewPath: previewPath),
  );
  if (ok != true) return;
  // Account is back: offer a new password for this device.
  final c = nav.context;
  if (!c.mounted) return;
  final s = S.read(c);
  final set = await showSecureDialog<bool>(
    c,
    builder: (d) => SecureDialogFrame(
      onEscape: () => Navigator.pop(d, false),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SecureHero(icon: AppIcons.checkCircle, tone: LC.success, title: s('fp_done_title'), subtitle: s('fp_done_body'), compact: true),
        const SizedBox(height: 28),
        SecurePrimaryButton(label: s('set_passphrase'), icon: AppIcons.lockKey, onPressed: () => Navigator.pop(d, true)),
        const SizedBox(height: 8),
        Center(child: TextButton(onPressed: () => Navigator.pop(d, false), child: Text(s('later')))),
      ]),
    ),
  );
  if (set == true && c.mounted) await showPassphraseDialog(c);
}

class _ForgotPassphraseDialog extends StatefulWidget {
  const _ForgotPassphraseDialog({this.previewFile = false, this.previewPath});
  final bool previewFile;
  final String? previewPath;
  @override
  State<_ForgotPassphraseDialog> createState() => _ForgotPassphraseDialogState();
}

class _ForgotPassphraseDialogState extends State<_ForgotPassphraseDialog> {
  late bool _fromFile = widget.previewFile;

  /// A way back has been picked (false: the three options are shown).
  late bool _chosen = widget.previewFile;
  bool _more = false;
  final _phrase = TextEditingController();
  final _pw = TextEditingController();
  String? _path;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phrase.dispose();
    _pw.dispose();
    super.dispose();
  }

  bool get _ready => _fromFile ? (_path != null && _pw.text.isNotEmpty) : RecoveryPhraseInput.isReady(_phrase.text);

  Future<void> _go() async {
    final s = S.read(context);
    final sv = context.read<AppServices>();
    final ok = await confirm(context, title: s('fp_confirm_title'), body: s('fp_confirm_body'), action: s('restore_identity'));
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await DataRescue(sv).restoreFresh(
        phrase: _fromFile ? null : _phrase.text.trim(),
        backup: _fromFile ? (_path!, _pw.text) : null,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      final code = DataRescue.errorCode(e);
      setState(() => _error = s.orElse('err_$code', code));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _choose(bool fromFile) => setState(() {
        _fromFile = fromFile;
        _chosen = true;
        _error = null;
      });

  void _back() => setState(() {
        _chosen = false;
        _error = null;
      });

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    void close() => Navigator.pop(context);
    return SecureDialogFrame(
      leading: _chosen && !_busy ? SecureNavButton.back(context, _back) : null,
      trailing: SecureNavButton.close(context, close),
      onEscape: _chosen ? (_busy ? () {} : _back) : close,
      child: AnimatedSwitcher(
        duration: Motion.normal,
        switchInCurve: Motion.curve,
        transitionBuilder: (w, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(position: Tween(begin: const Offset(0.03, 0), end: Offset.zero).animate(a), child: w),
        ),
        child: KeyedSubtree(
          key: ValueKey(_chosen ? (_fromFile ? 'file' : 'phrase') : 'options'),
          child: !_chosen ? _options(s, close) : (_fromFile ? _file(s) : _phraseStep(s)),
        ),
      ),
    );
  }

  Widget _options(S s, VoidCallback close) {
    Widget point(IconData icon, Color color, String text) => Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 17, color: color)),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: context.tt.bodySmall?.copyWith(color: context.lc.text.withValues(alpha: 0.85), height: 1.45, fontSize: 13))),
          ]),
        );
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SecureHero(icon: AppIcons.key, tone: LC.warning, title: s('fp_title'), subtitle: s('sec_fp_sub'), compact: true),
      const SizedBox(height: 24),
      SecureOptionCard(icon: AppIcons.recoveryPhrase, title: s('sec_fp_phrase'), subtitle: s('sec_fp_phrase_sub'), onTap: () => _choose(false)),
      const SizedBox(height: 10),
      SecureOptionCard(icon: AppIcons.fileArchive, color: LC.accent, title: s('sec_fp_file'), subtitle: s('sec_fp_file_sub'), onTap: () => _choose(true)),
      const SizedBox(height: 10),
      SecureOptionCard(icon: AppIcons.retry, color: LC.success, title: s('sec_fp_retry'), subtitle: s('sec_fp_retry_sub'), onTap: close),
      const SizedBox(height: 16),
      Center(
        child: TextButton.icon(
          onPressed: () => setState(() => _more = !_more),
          icon: AnimatedRotation(turns: _more ? 0.25 : 0, duration: Motion.normal, child: const Icon(AppIcons.chevronRight, size: 16)),
          label: Text(s('sec_fp_more')),
          style: TextButton.styleFrom(foregroundColor: context.lc.muted),
        ),
      ),
      AnimatedSize(
        duration: Motion.normal,
        curve: Motion.curve,
        alignment: Alignment.topCenter,
        child: !_more
            ? const SizedBox(width: double.infinity)
            : Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 14),
                decoration: BoxDecoration(color: context.lc.surface2.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(Radii.md)),
                child: Column(children: [
                  point(AppIcons.archive, context.lc.muted, s('fp_point_kept')),
                  point(AppIcons.refresh, LC.success, s('fp_point_resend')),
                ]),
              ),
      ),
    ]);
  }

  Widget _phraseStep(S s) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SecureHero(icon: AppIcons.recoveryPhrase, title: s('sec_fp_phrase_title'), subtitle: s('sec_fp_phrase_head'), compact: true),
        const SizedBox(height: 24),
        RecoveryPhraseInput(
          controller: _phrase,
          autofocus: true,
          enabled: !_busy,
          onChanged: () => setState(() => _error = null),
          onSubmitted: () => _ready && !_busy ? _go() : null,
        ),
        if (_error != null) ...[const SizedBox(height: 12), SecureMessage(_error!)],
        const SizedBox(height: 24),
        SecurePrimaryButton(label: s('restore_identity'), icon: AppIcons.reset, busy: _busy, onPressed: _ready ? _go : null),
      ]);

  Widget _file(S s) {
    final path = _path ?? widget.previewPath;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SecureHero(icon: AppIcons.fileArchive, tone: LC.accent, title: s('sec_fp_file_title'), subtitle: s('restore_file_sub'), compact: true),
      const SizedBox(height: 24),
      BackupFileTile(
        path: path,
        onTap: () async {
          final p = await pickBackupFile();
          if (p != null && mounted) setState(() => _path = p);
        },
      ),
      const SizedBox(height: 16),
      PasswordField(
        controller: _pw,
        label: s('backup_password'),
        onChanged: (_) => setState(() => _error = null),
        onSubmitted: (_) => _ready && !_busy ? _go() : null,
      ),
      if (_error != null) ...[const SizedBox(height: 12), SecureMessage(_error!)],
      const SizedBox(height: 24),
      SecurePrimaryButton(label: s('restore_identity'), icon: AppIcons.reset, busy: _busy, onPressed: _ready ? _go : null),
    ]);
  }
}

/// Settings › Security: data folders kept aside after "forgot password".
class AsideDataGroup extends StatelessWidget {
  const AsideDataGroup({super.key});

  Future<void> _open(BuildContext context, AsideData a) async {
    final s = S.read(context);
    final sv = context.read<AppServices>();
    final ok = await confirm(
      context,
      title: a.locked ? s('aside_try_title') : s('aside_open_title'),
      body: a.locked ? s('aside_try_body') : s('aside_open_body'),
      action: a.locked ? s('aside_try') : s('aside_open'),
    );
    if (!ok || !context.mounted) return;
    try {
      final done = await DataRescue(sv).switchTo(a.path);
      if (!done && context.mounted) toast(context, s('aside_reopen'));
    } catch (e) {
      if (context.mounted) toast(context, s.orElse('err_${DataRescue.errorCode(e)}', DataRescue.errorCode(e)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    context.select<Settings, int>((x) => x.asideData.length);
    final list = DataRescue(context.read<AppServices>()).aside;
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(s('aside_section'), padding: const EdgeInsets.fromLTRB(4, 8, 4, 8)),
      LCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(children: [
          for (final a in list)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: Row(children: [
                IconTile(a.locked ? AppIcons.lockKey : AppIcons.archive, color: a.locked ? LC.warning : const Color(0xFF64748B)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(a.locked ? s('aside_locked') : s('aside_kept'), style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      s('aside_since', {'date': a.when == null ? '' : s.dayLabel(a.when!, DateTime.now())}),
                      style: context.tt.bodySmall,
                    ),
                  ]),
                ),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: () => _open(context, a), child: Text(a.locked ? s('aside_try') : s('aside_open'))),
              ]),
            ),
        ]),
      ),
      const SizedBox(height: 16),
    ]);
  }
}

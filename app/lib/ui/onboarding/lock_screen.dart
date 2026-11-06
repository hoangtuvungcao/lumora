import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../app.dart';
import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/data_rescue.dart';
import '../../state/settings.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/secure_input.dart';
import 'forgot_passphrase.dart';

class LockScreen extends StatefulWidget {
  const LockScreen({super.key});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _pass = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  /// A failure that wasn't the password (for "Technical details").
  Object? _failure;

  Future<void> _unlock() async {
    if (_pass.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppServices>().unlock(_pass.text);
    } catch (e) {
      if (!mounted) return;
      // Only a refusal of the password itself is "wrong password". Already
      // open in another window, damaged data, or a failure after the data
      // was opened → its own plain explanation (with details).
      final s = S.read(context);
      final api = e is ApiException ? e : null;
      final wrong = api != null &&
          (api.code == 'err.wrong_passphrase' || api.code == 'err.passphrase_required' || (api.cmd == 'start' && (api.code == null || api.code == 'internal')));
      setState(() {
        _failure = wrong ? null : e;
        _error = wrong
            ? s('wrong_passphrase')
            : (api?.code == 'err.already_running' ? s.orElse('err_already_running', api!.message) : errorMessage(s, e));
      });
      debugPrint('unlock failed: ${e is ApiException ? '${e.code} ${e.detail ?? e.message}' : e}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final desktop = isDesktop(context);
    final secure = Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(AppIcons.shieldCheck, size: 16, color: LC.success),
      const SizedBox(width: 8),
      Flexible(child: Text(s('local_encrypted'), style: context.tt.bodySmall)),
    ]);
    return Scaffold(
      body: SecureFrame(
        footer: secure,
        child: AutofillGroup(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SecureHero(title: s('locked_title'), subtitle: s('sec_locked_sub')),
            SizedBox(height: desktop ? 28 : 32),
            PasswordField(
              controller: _pass,
              autofocus: true,
              hint: s('sec_password_hint'),
              icon: AppIcons.lock,
              errorText: _error,
              onChanged: (_) => _error != null ? setState(() => _error = null) : null,
              onSubmitted: (_) => _unlock(),
            ),
            ErrorDetailsLink(_failure),
            const SizedBox(height: 24),
            SecurePrimaryButton(label: s('unlock'), icon: AppIcons.unlock, busy: _busy, onPressed: _unlock),
            const SizedBox(height: 12),
            Center(child: TextButton(onPressed: _busy ? null : () => showForgotPassphrase(context), child: Text(s('fp_forgot')))),
            Builder(builder: (context) {
              // Came here via "Try old password": a way straight back.
              context.select<Settings, int>((x) => x.asideData.length);
              final sv = context.read<AppServices>();
              final back = DataRescue(sv).aside.where((a) => !a.locked).firstOrNull;
              if (back == null) return const SizedBox.shrink();
              return Center(
                child: TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          try {
                            await DataRescue(sv).switchTo(back.path);
                          } catch (e) {
                            if (mounted) setState(() => _error = S.read(this.context).orElse('err_${DataRescue.errorCode(e)}', DataRescue.errorCode(e)));
                          } finally {
                            if (mounted) setState(() => _busy = false);
                          }
                        },
                  icon: const Icon(AppIcons.undo, size: 16),
                  label: Text(s('fp_back_current')),
                ),
              );
            }),
          ]),
        ),
      ),
    );
  }
}

// Screens that reveal what can take over the account — the recovery phrase,
// a backup file, the link-a-device QR/code — are:
//  * blocked while someone is watching or controlling this device (remote
//    desktop, this device as host), also if a session starts while one is open;
//  * opened only after the owner proves it's them: the app PIN, else the data
//    password (when the account has one);
//  * kept out of screenshots / screen recording (Android FLAG_SECURE).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../platform/android_bridge.dart';
import '../../state/app_lock.dart';
import '../../state/settings.dart';
import '../../state/stores.dart';
import '../lock/app_lock_screen.dart' show askCurrentPin;
import 'app_icons.dart';
import 'common.dart';
import 'secure_input.dart';

/// Someone is connected to this device's screen right now (we are the host).
bool isRemoteHosting(RemoteStore remote) {
  final h = remote.host;
  return h != null && (h.phase == RemotePhase.active || h.phase == RemotePhase.connecting);
}

/// Plain notice: "can't open while someone controls this device".
Future<void> showBlockedWhileControlled(BuildContext context) {
  final s = S.read(context);
  return showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(AppIcons.shield),
      title: Text(s('sensitive_blocked_title')),
      content: Text(s('sensitive_blocked_body')),
      actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(s('close')))],
    ),
  );
}

/// Asks the owner to prove it's them before a secret is shown. Returns true
/// when allowed. [title]: what is about to open (shown on the PIN prompt).
Future<bool> confirmOwner(BuildContext context, {required String title}) async {
  final remote = context.read<RemoteStore>();
  if (isRemoteHosting(remote)) {
    await showBlockedWhileControlled(context);
    return false;
  }
  final lock = context.read<AppLock>();
  if (lock.hasPin) {
    return askCurrentPin(context, title: title);
  }
  final settings = context.read<Settings>();
  final me = context.read<SessionStore>().me;
  final hasPass = (me?.protection ?? '').isNotEmpty ? me!.protection == 'passphrase' : settings.hasPassphrase;
  if (hasPass) {
    return await showSecureDialog<bool>(context, builder: (_) => _PassphraseCheck(title: title)) ?? false;
  }
  // Nothing set up to check against: the explicit warning before showing is
  // the gate (and the screen stays blocked for remote viewers).
  return true;
}

/// Wraps a sensitive screen: screenshots blocked while it is open, and its
/// content replaced by a plain notice as soon as a remote session starts.
class SensitiveScreen extends StatefulWidget {
  const SensitiveScreen({super.key, required this.child});
  final Widget child;
  @override
  State<SensitiveScreen> createState() => _SensitiveScreenState();
}

class _SensitiveScreenState extends State<SensitiveScreen> {
  @override
  void initState() {
    super.initState();
    AndroidBridge.pushSecure();
  }

  @override
  void dispose() {
    AndroidBridge.popSecure();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hosting = context.select<RemoteStore, bool>(isRemoteHosting);
    if (!hosting) return widget.child;
    final s = S.of(context);
    return SecureDialogFrame(
      trailing: SecureNavButton.close(context, () => Navigator.of(context).maybePop()),
      onEscape: () => Navigator.of(context).maybePop(),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SecureHero(icon: AppIcons.shield, title: s('sensitive_blocked_title'), subtitle: s('sensitive_blocked_body'), compact: true),
        const SizedBox(height: 20),
        SecurePrimaryButton(label: s('close'), onPressed: () => Navigator.of(context).maybePop()),
      ]),
    );
  }
}

class _PassphraseCheck extends StatefulWidget {
  const _PassphraseCheck({required this.title});
  final String title;
  @override
  State<_PassphraseCheck> createState() => _PassphraseCheckState();
}

class _PassphraseCheckState extends State<_PassphraseCheck> {
  final _ctl = TextEditingController();
  bool _busy = false;
  String? _error;
  Object? _failure;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_ctl.text.isEmpty || _busy) return;
    final s = S.read(context);
    setState(() {
      _busy = true;
      _error = null;
      _failure = null;
    });
    try {
      final ok = await context.read<LumoraApi>().checkPassphrase(_ctl.text);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() => _error = s('sensitive_wrong_pass'));
    } catch (e) {
      if (!mounted) return;
      final wrong = e is ApiException && (e.code == 'err.wrong_passphrase' || e.message == 'wrong_passphrase');
      setState(() {
        _error = wrong ? s('sensitive_wrong_pass') : errorMessage(s, e);
        _failure = wrong ? null : e;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    void close() => Navigator.of(context).pop(false);
    return SecureDialogFrame(
      trailing: SecureNavButton.close(context, close),
      onEscape: close,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SecureHero(icon: AppIcons.lockKey, title: widget.title, subtitle: s('sensitive_pass_sub'), compact: true),
        const SizedBox(height: 20),
        PasswordField(
          controller: _ctl,
          label: s('passphrase'),
          autofocus: true,
          policy: false,
          onSubmitted: (_) => _check(),
          onChanged: (_) => _error != null ? setState(() => _error = null) : null,
        ),
        if (_error != null) ...[const SizedBox(height: 12), SecureMessage(_error!), ErrorDetailsLink(_failure)],
        const SizedBox(height: 20),
        SecurePrimaryButton(label: s('continue'), busy: _busy, onPressed: _busy ? null : _check),
        const SizedBox(height: 8),
        Center(child: TextButton(onPressed: close, child: Text(s('cancel')))),
      ]),
    );
  }
}

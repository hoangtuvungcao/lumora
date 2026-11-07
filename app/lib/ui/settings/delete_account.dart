// Settings › Security › "Xoá tài khoản" / "Delete account" (required by Google Play; matches
// the public page branding/tools/legal_content.py DELETE_ACCOUNT).
//
// * Main device: after the account password (if any) is checked, every other device is signed
//   out with its downloads wiped, then this device signs out with its downloads wiped.
// * Linked device: only this device's copy is deleted (it asks the main device to revoke it
//   with a wipe); deleting the whole account has to be done on the main device.
//
// `device_revoked {by_self, wipe}` then shows the signed-out notice and, after it, the welcome
// screen (the core wipes the keystore, database and downloads at its next start).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/devices_store.dart';
import '../../state/settings.dart';
import '../../state/stores.dart' show SessionStore;
import '../devices/device_ui.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/secure_input.dart';

Future<void> showDeleteAccountDialog(BuildContext context) async {
  final devices = context.read<DevicesStore>();
  await devices.load().catchError((_) {});
  if (!context.mounted) return;
  final protection = context.read<SessionStore>().me?.protection ?? '';
  final needsPass = protection.isNotEmpty ? protection == 'passphrase' : context.read<Settings>().hasPassphrase;
  await showDialog<bool>(
    context: context,
    builder: (_) => DeleteAccountDialog(needsPass: needsPass, api: context.read<LumoraApi>(), devices: devices),
  );
}

class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({super.key, required this.needsPass, required this.api, required this.devices});
  final bool needsPass;
  final LumoraApi api;
  final DevicesStore devices;

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  final _pass = TextEditingController();
  var _understood = false;
  var _busy = false;
  String? _error;
  String? _progress;

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  bool get _primary => widget.devices.isPrimary;

  /// The other devices of the account (main device only).
  List<DeviceInfo> get _others {
    final l = widget.devices.list;
    if (l == null) return const [];
    return [for (final d in l.devices) if (!d.isThis && d.device != l.device) d];
  }

  bool get _ready => _understood && !_busy && (!widget.needsPass || _pass.text.isNotEmpty);

  Future<void> _go() async {
    if (!_ready) return;
    final s = S.read(context);
    final pass = widget.needsPass ? _pass.text : null;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // the password first: a wrong one must leave every device as it is
      if (pass != null) await widget.api.checkPassphrase(pass);
      if (_primary) {
        final others = _others;
        for (var i = 0; i < others.length; i++) {
          if (mounted) setState(() => _progress = s('da_progress', {'done': '${i + 1}', 'n': '${others.length}'}));
          await widget.devices.revoke(others[i].device, wipeMedia: true);
        }
      }
      await widget.api.deviceLogout(primaryOk: _primary, passphrase: pass, wipe: true);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
        _error = e is ApiException && e.code == 'err.wrong_passphrase' ? s('err_wrong_passphrase') : deviceError(s, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final primary = _primary;
    final others = primary ? _others : const <DeviceInfo>[];
    final main = widget.devices.list?.mainDevice;
    final muted = context.tt.bodyMedium?.copyWith(height: 1.5, color: context.lc.muted);
    Widget warn(String text) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(padding: EdgeInsets.only(top: 2), child: Icon(AppIcons.warning, size: 16, color: LC.danger)),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: context.tt.bodyMedium?.copyWith(fontSize: 13.5, height: 1.4))),
          ]),
        );
    // no dismissing (barrier tap, back) while devices are being signed out
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        icon: const IconTile(AppIcons.delete, color: LC.danger, size: IconTileSize.lg, circle: true),
        title: Text(s(primary ? 'da_title' : 'da_title_linked'), textAlign: TextAlign.center),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(s(primary ? 'da_body' : 'da_body_linked'), style: muted),
              if (primary && others.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  others.length == 1 ? s('da_body_devices_one', {'name': deviceTitle(s, others.single)}) : s('da_body_devices', {'n': '${others.length}'}),
                  style: muted,
                ),
              ],
              if (!primary) ...[
                const SizedBox(height: 8),
                Text(main == null ? s('da_main_unknown') : s('da_main_is', {'name': deviceTitle(s, main)}),
                    style: context.tt.bodyMedium?.copyWith(height: 1.5, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                decoration: BoxDecoration(
                  color: LC.danger.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(Radii.md),
                  border: Border.all(color: LC.danger.withValues(alpha: 0.35)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  warn(s('da_warn_undo')),
                  warn(s('da_warn_sent')),
                  if (primary) warn(s('da_warn_phrase')),
                ]),
              ),
              if (widget.needsPass) ...[
                const SizedBox(height: 14),
                PasswordField(
                  controller: _pass,
                  label: s('dv_logout_password'),
                  autofocus: true,
                  policy: false,
                  errorText: _error,
                  onChanged: (_) => setState(() => _error = null),
                  onSubmitted: (_) => _go(),
                ),
              ],
              const SizedBox(height: 8),
              Material(
                color: context.lc.surface2.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(Radii.md),
                child: CheckboxListTile(
                  key: const ValueKey('da_understand'),
                  value: _understood,
                  onChanged: _busy ? null : (v) => setState(() => _understood = v ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
                  title: Text(s('da_understand'), style: context.tt.bodyMedium?.copyWith(fontSize: 13.5)),
                ),
              ),
              if (_error != null && !widget.needsPass) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: LC.danger)),
              ],
              if (_progress != null) ...[
                const SizedBox(height: 10),
                Text(_progress!, style: muted),
              ],
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: Text(s('cancel'))),
          FilledButton(
            key: const ValueKey('da_confirm'),
            style: FilledButton.styleFrom(backgroundColor: LC.danger),
            onPressed: _ready ? _go : null,
            child: Text(s(primary ? 'da_action' : 'da_action_linked')),
          ),
        ],
      ),
    );
  }
}

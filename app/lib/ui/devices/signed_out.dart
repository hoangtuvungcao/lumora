// Calm full-screen notice when this device was signed out of the account
// (from the main device, or by itself). "Start over" opens the welcome
// screen: the device can be linked again or start a new account.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../state/devices_store.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/secure_input.dart';

class DeviceSignedOutScreen extends StatelessWidget {
  const DeviceSignedOutScreen({super.key, required this.onStartOver});
  final VoidCallback onStartOver;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final out = context.select<DevicesStore, DeviceSignOut?>((d) => d.signedOut) ?? const DeviceSignOut();
    final body = out.bySelf
        ? s('dv_out_self')
        : out.kept
            ? s('dv_out_auto')
            : '${s('dv_out_remote')}${out.wipe ? ' ${s('dv_out_wipe')}' : ''}';
    return Scaffold(
      body: SecureFrame(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SecureHero(icon: AppIcons.signOut, tone: LC.accent, title: s('dv_out_title'), subtitle: body),
          const SizedBox(height: 22),
          SecureNote(s('dv_out_hint'), icon: AppIcons.info),
          if (out.kept) ...[
            const SizedBox(height: 10),
            SecureNote(s('dv_out_kept'), icon: AppIcons.lock),
          ],
          const SizedBox(height: 24),
          SecurePrimaryButton(label: s('dv_out_continue'), icon: AppIcons.next, onPressed: onStartOver),
        ]),
      ),
    );
  }
}

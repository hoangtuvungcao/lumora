// Android: keep Lumora reachable in the background. Lumora has no push
// server, so Android's battery optimisation (and the phone maker's own
// battery saver / autostart lock on Xiaomi, OPPO, vivo, Huawei…) decides
// whether messages and calls arrive while it is closed. Shown once after
// sign-in (HomeShell) and from Settings › Notifications.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../platform/android_bridge.dart';
import '../../state/settings.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';

/// First run on Android: ask once, only when something is still restricted.
Future<void> maybeAskBackground(BuildContext context) async {
  final st = context.read<Settings>();
  if (!AndroidBridge.isAndroid || st.backgroundAsked) return;
  final status = await AndroidBridge.backgroundStatus();
  if (status == null || !context.mounted) return;
  st.update((s) => s.backgroundAsked = true);
  if (status.ignoringBattery && !status.autostart) return;
  await showBackgroundSheet(context);
}

Future<void> showBackgroundSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (_) => const BackgroundSheet(),
    );

class BackgroundSheet extends StatefulWidget {
  const BackgroundSheet({super.key, this.status});

  /// Tests / screenshots: a fixed status instead of asking Android.
  final BackgroundStatus? status;

  @override
  State<BackgroundSheet> createState() => _BackgroundSheetState();
}

class _BackgroundSheetState extends State<BackgroundSheet> {
  BackgroundStatus? _status;
  AppLifecycleListener? _life;

  @override
  void initState() {
    super.initState();
    _status = widget.status;
    if (_status == null) unawaited(_refresh());
    // back from the system dialog / the maker's settings: show the new state
    try {
      _life = AppLifecycleListener(onResume: _refresh);
    } catch (_) {}
  }

  @override
  void dispose() {
    _life?.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (widget.status != null) return;
    final s = await AndroidBridge.backgroundStatus();
    if (mounted) setState(() => _status = s);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final st = _status;
    final ok = st?.ignoringBattery ?? false;
    final muted = TextStyle(color: context.lc.muted, fontSize: 13.5, height: 1.4);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const IconTile(AppIcons.power, duotone: false),
            const SizedBox(width: 14),
            Expanded(child: Text(s('bg_title'), style: context.tt.titleMedium)),
          ]),
          const SizedBox(height: 12),
          Text(s('bg_body'), style: muted),
          const SizedBox(height: 18),
          _Step(
            done: ok,
            title: s('bg_battery'),
            body: ok ? s('bg_battery_ok') : s('bg_battery_hint'),
            action: ok ? null : s('bg_battery_allow'),
            onAction: () async {
              await AndroidBridge.requestIgnoreBattery();
              await _refresh();
            },
          ),
          if (st?.autostart ?? false) ...[
            const SizedBox(height: 12),
            _Step(
              title: s('bg_autostart'),
              body: s(st!.oem == 'xiaomi' ? 'bg_autostart_xiaomi' : 'bg_autostart_hint'),
              action: s('bg_autostart_open'),
              onAction: AndroidBridge.openAutostart,
            ),
          ],
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => Navigator.of(context).maybePop(), child: Text(ok ? s('done') : s('bg_later'))),
          ),
        ]),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.title, required this.body, this.action, this.onAction, this.done = false});
  final String title, body;
  final String? action;
  final VoidCallback? onAction;
  final bool done;

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF22C55E);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: done ? green.withValues(alpha: 0.5) : context.lc.divider),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(done ? AppIcons.checkCircle : AppIcons.settings, size: 20, color: done ? green : context.lc.muted),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 6),
        Text(body, style: TextStyle(color: context.lc.muted, fontSize: 13, height: 1.4)),
        if (action != null) ...[
          const SizedBox(height: 10),
          FilledButton.tonal(onPressed: onAction, child: Text(action!)),
        ],
      ]),
    );
  }
}

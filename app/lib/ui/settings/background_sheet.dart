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
  if (!AndroidBridge.isAndroid) return;
  // Xiaomi / HyperOS: chat bubbles stay off until Lumora may show pop-ups — asked once too
  // (also by people who saw this sheet before bubbles needed it)
  final perms = await AndroidBridge.permissionStatus();
  final missing = !perms.fullScreen || !perms.popups;
  final bubbles = !st.bubblesAsked && missing;
  if (st.backgroundAsked && !bubbles) return;
  final status = await AndroidBridge.backgroundStatus();
  if (status == null || !context.mounted) return;
  final first = !st.backgroundAsked;
  st.update((s) {
    s.backgroundAsked = true;
    s.bubblesAsked = true;
  });
  if (!bubbles && (!first || (status.ignoringBattery && !status.autostart))) return;
  await showBackgroundSheet(context);
}

Future<void> showBackgroundSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (_) => const BackgroundSheet(),
    );

class BackgroundSheet extends StatefulWidget {
  const BackgroundSheet({super.key, this.status, this.bubblesBlocked});

  /// Tests / screenshots: a fixed status instead of asking Android.
  final BackgroundStatus? status;

  /// Tests / screenshots: fixed permission states instead of asking Android.
  final ({bool fullScreen, bool xiaomi, bool popups})? bubblesBlocked;

  @override
  State<BackgroundSheet> createState() => _BackgroundSheetState();
}

class _BackgroundSheetState extends State<BackgroundSheet> {
  BackgroundStatus? _status;
  AppLifecycleListener? _life;

  /// Calls over the lock screen (Android 14+) / Xiaomi pop-ups: missing now, and missing at
  /// some point while the sheet was open (the step stays, ticked, once it is allowed).
  ({bool fullScreen, bool xiaomi, bool popups}) _perms = (fullScreen: true, xiaomi: false, popups: true);
  bool _fullScreenStep = false, _popupsStep = false;

  @override
  void initState() {
    super.initState();
    _status = widget.status;
    if (widget.bubblesBlocked case final p?) {
      _perms = p;
      _fullScreenStep = !p.fullScreen;
      _popupsStep = !p.popups;
    }
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
    final p = await AndroidBridge.permissionStatus();
    if (!mounted) return;
    final fixed = (!_perms.popups && p.popups) || (!_perms.fullScreen && p.fullScreen);
    setState(() {
      _status = s;
      _perms = p;
      _fullScreenStep |= !p.fullScreen;
      _popupsStep |= !p.popups;
    });
    if (fixed) toast(context, S.read(context)('bg_perm_done'));
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
          if (_fullScreenStep) ...[
            const SizedBox(height: 12),
            _Step(
              done: _perms.fullScreen,
              title: s('bg_fullscreen'),
              body: _perms.fullScreen ? s('bg_fullscreen_ok') : s('bg_fullscreen_hint'),
              action: _perms.fullScreen ? null : s('bg_perm_allow'),
              onAction: AndroidBridge.openFullScreenPermission,
            ),
          ],
          if (_popupsStep) ...[
            const SizedBox(height: 12),
            _Step(
              done: _perms.popups,
              title: s('bg_popups'),
              body: _perms.popups ? s('bg_popups_ok') : s('bg_popups_hint'),
              action: _perms.popups ? null : s('bg_perm_allow'),
              onAction: AndroidBridge.openPopupPermissions,
            ),
          ],
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => Navigator.of(context).maybePop(), child: Text(ok && _perms.fullScreen && _perms.popups ? s('done') : s('bg_later'))),
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

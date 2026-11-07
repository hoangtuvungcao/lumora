import 'dart:io';

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../network/network_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/secure_input.dart';
import '../devices/device_picker.dart';
import '../devices/qr_scan.dart' show lumoraQrScanner;
import '../../core/links.dart';
import '../flows.dart' show Flows;
import 'wake_device.dart';
import '../../platform/apple_services.dart';

class RemoteHomeScreen extends StatelessWidget {
  const RemoteHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final desktop = isDesktop(context);
    // iPhone/iPad host view-only: iOS lets no app inject input; the screen comes from the
    // ReplayKit broadcast extension (docs/src/platforms/apple.md).
    final cards = [const _AllowCard(), const _ConnectCard()];
    return Material(
      color: context.lc.bg,
      child: Column(
        children: [
          PaneHeader(
            leading: const Icon(AppIcons.remote, color: LC.primary),
            title: Text(s('remote')),
            subtitle: Text(s('remote_subtitle')),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.all(desktop ? 24 : 16),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1000),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (desktop)
                          IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: cards[0]),
                                const SizedBox(width: 20),
                                Expanded(child: cards[1]),
                              ],
                            ),
                          )
                        else
                          for (final (i, c) in cards.indexed) ...[
                            if (i > 0) const SizedBox(height: 16),
                            c,
                          ],
                        const SizedBox(height: 20),
                        const _RecentDevices(),
                        const SizedBox(height: 20),
                        const _PermissionHint(),
                        const SizedBox(height: 20),
                        const _HowItWorks(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AllowCard extends StatefulWidget {
  const _AllowCard();
  @override
  State<_AllowCard> createState() => _AllowCardState();
}

class _AllowCardState extends State<_AllowCard> {
  bool _show = true;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final st = context.select<RemoteStore, RemoteStatus>((r) => r.status);
    final me = context.select<SessionStore, Me?>((x) => x.me);
    final remote = context.read<RemoteStore>();
    final id = st.myShortId.isNotEmpty ? st.myShortId : (me?.shortId ?? '');
    return LCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(AppIcons.download, color: LC.accent),
              const SizedBox(width: 10),
              Text(s('allow_remote'), style: context.tt.titleMedium),
            ],
          ),
          const SizedBox(height: 4),
          Text(s('allow_remote_hint'), style: context.tt.bodySmall),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(gradient: LC.gradient, borderRadius: BorderRadius.circular(Radii.lg)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s('your_id').toUpperCase(),
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 11.5, letterSpacing: 1, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          id,
                          style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w700, letterSpacing: 2, fontFeatures: [FontFeature.tabularFigures()]),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: s('copy_id'),
                      onPressed: () => copyText(context, id),
                      icon: const Icon(AppIcons.copy, color: Colors.white),
                    ),
                    IconButton(
                      tooltip: s('copy_link'),
                      onPressed: () => copyText(context, LumoraLink.remoteLink(id)),
                      icon: const Icon(AppIcons.link, color: Colors.white),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Divider(color: Colors.white.withValues(alpha: 0.25)),
                const SizedBox(height: 6),
                Text(
                  s('temp_password').toUpperCase(),
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 11.5, letterSpacing: 1, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _show ? st.password : '•' * (st.password.length.clamp(6, 10)),
                          maxLines: 1,
                          softWrap: false,
                          style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: 2, fontFamily: 'monospace'),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: _show ? s('hide') : s('show'),
                      onPressed: () => setState(() => _show = !_show),
                      icon: Icon(_show ? AppIcons.hide : AppIcons.show, color: Colors.white),
                    ),
                    IconButton(
                      key: const ValueKey('new_remote_password'),
                      tooltip: s('new_password'),
                      onPressed: () => newRemotePassword(context),
                      icon: const Icon(AppIcons.refresh, color: Colors.white),
                    ),
                    IconButton(
                      tooltip: s('copy'),
                      onPressed: () => copyText(context, st.password),
                      icon: const Icon(AppIcons.copy, color: Colors.white),
                    ),
                  ],
                ),
                const MyDeviceIds(),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (Platform.isIOS) ...[
            Text(s('ios_share_screen_hint'), style: context.tt.bodySmall),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: AppleServices.showBroadcastPicker,
              icon: const Icon(AppIcons.screenShare),
              label: Text(s('ios_start_broadcast')),
            ),
          ] else ...[
          SwitchRow(icon: AppIcons.mouse, title: s('allow_control'), subtitle: s('allow_control_hint'), value: st.allowControl, onChanged: remote.setAllowControl),
          SwitchRow(
            icon: AppIcons.lockKey,
            title: s('unattended'),
            subtitle: s('unattended_hint'),
            value: st.unattended,
            onChanged: (v) async {
              if (v && !await confirm(context, title: s('unattended'), body: s('unattended_confirm'), action: s('enable'))) {
                return;
              }
              remote.setUnattended(v);
            },
          ),
          ],
          // Phones can't be restarted/logged out remotely.
          if (!Platform.isAndroid && !Platform.isIOS)
            SwitchRow(icon: AppIcons.power, title: s('allow_power'), subtitle: s('allow_power_hint'), value: st.allowPower, onChanged: remote.setAllowPower),
        ],
      ),
    );
  }
}

class _ConnectCard extends StatefulWidget {
  const _ConnectCard();
  @override
  State<_ConnectCard> createState() => _ConnectCardState();
}

class _ConnectCardState extends State<_ConnectCard> {
  final _id = TextEditingController();
  final _pw = TextEditingController();
  bool _viewOnly = false;
  bool _busy = false;

  @override
  void dispose() {
    _prefillId.removeListener(_prefill);
    _id.dispose();
    _pw.dispose();
    super.dispose();
  }

  bool get _valid => _id.text.replaceAll(RegExp(r'\D'), '').length == 9 && _pw.text.isNotEmpty;

  /// Takes a pre-filled ID (a link, a profile's Remote button, a recent
  /// device) — also one set before this card was built.
  void _prefill() {
    final v = _prefillId.value;
    if (v.isEmpty) return;
    _id.text = v;
    _prefillId.value = '';
    if (mounted) setState(() {});
  }

  Future<void> _scan() async {
    final l = await Flows.scanQr(context);
    if (l == null || !mounted) return;
    if (l.kind != LinkKind.remote) return Flows.openLink(context, l);
    _id.text = formatShortId(l.shortId!);
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _prefillId.addListener(_prefill);
    final v = _prefillId.value;
    if (v.isNotEmpty) {
      _id.text = v;
      _prefillId.value = '';
    }
  }

  Future<void> _connect() async {
    setState(() => _busy = true);
    try {
      final remote = context.read<RemoteStore>();
      await connectChoosingDevice(context, (device) => remote.connect(formatShortId(_id.text), _pw.text, viewOnly: _viewOnly, device: device));
    } catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final err = context.select<RemoteStore, String?>((r) => r.lastError);
    return LCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(AppIcons.upload, color: LC.primary),
              const SizedBox(width: 10),
              Text(s('control_partner'), style: context.tt.titleMedium),
            ],
          ),
          const SizedBox(height: 4),
          Text(s('control_partner_hint'), style: context.tt.bodySmall),
          const SizedBox(height: 18),
          SecureLabel(s('partner_id')),
          TextField(
            controller: _id,
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')), LengthLimitingTextInputFormatter(11), _ShortIdFormatter()],
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, letterSpacing: 2, color: context.lc.text),
            decoration: secureInputDecoration(context, hint: '123 456 789', icon: AppIcons.channel),
          ),
          if (lumoraQrScanner != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: _scan, icon: const Icon(AppIcons.scan, size: 18), label: Text(s('scan_qr'))),
            ),
          const SizedBox(height: 16),
          PasswordField(
            controller: _pw,
            label: s('password'),
            icon: AppIcons.key,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _valid ? _connect() : null,
          ),
          const SizedBox(height: 4),
          SwitchRow(icon: AppIcons.show, title: s('view_only'), subtitle: s('view_only_hint'), value: _viewOnly, onChanged: (v) => setState(() => _viewOnly = v)),
          if (err != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: LC.danger.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(Radii.sm)),
              child: Row(
                children: [
                  const Icon(AppIcons.error, color: LC.danger, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(err == 'timeout' ? s('remote_timeout') : err == 'denied' ? s('remote_denied') : err, style: const TextStyle(color: LC.danger)),
                  ),
                  InkWell(onTap: context.read<RemoteStore>().clearError, child: const Icon(AppIcons.close, size: 16)),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (isDesktop(context)) const Spacer(),
          const SizedBox(height: 12),
          SecurePrimaryButton(label: s('connect'), icon: AppIcons.cast, busy: _busy, onPressed: _valid ? _connect : null),
        ],
      ),
    );
  }
}

class _ShortIdFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final d = newValue.text.replaceAll(RegExp(r'\D'), '');
    final b = StringBuffer();
    for (var i = 0; i < d.length && i < 9; i++) {
      if (i == 3 || i == 6) b.write(' ');
      b.write(d[i]);
    }
    final t = b.toString();
    return TextEditingValue(
      text: t,
      selection: TextSelection.collapsed(offset: t.length),
    );
  }
}

/// Friendly hint when screen-capture/input permissions are missing (no internals).
class _PermissionHint extends StatelessWidget {
  const _PermissionHint();
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final w = context.select<RemoteStore, Map<String, dynamic>>((r) => r.status.wayland);
    final checks = w['checks'];
    final missing = checks is List ? checks.any((c) => c is Map && c['ok'] == false && c['severity'] != 'info') : w.values.any((v) => v == false);
    if (!missing) return const SizedBox.shrink();
    return LCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          const Icon(AppIcons.warning, color: LC.warning),
          const SizedBox(width: 12),
          Expanded(child: Text(s('remote_permission_needed'), style: context.tt.bodyMedium)),
          TextButton(onPressed: () => openDiagnostics(context), child: Text(s('fix_now'))),
        ],
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    Widget step(IconData i, String t, String d) => Expanded(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconTile(i),
            const SizedBox(height: 10),
            Text(t, style: context.tt.titleSmall),
            const SizedBox(height: 4),
            Text(d, style: context.tt.bodySmall?.copyWith(height: 1.45)),
          ],
        ),
      ),
    );
    final steps = [step(AppIcons.lock, s('how_e2e'), s('how_e2e_body')), step(AppIcons.direct, s('how_p2p'), s('how_p2p_body')), step(AppIcons.raiseHand, s('how_consent'), s('how_consent_body'))];
    return LCard(
      padding: const EdgeInsets.all(16),
      child: isDesktop(context)
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: steps)
          : Column(
              children: [
                for (final st in steps) Row(children: [st]),
              ],
            ),
    );
  }
}

final _prefillId = ValueNotifier<String>('');

/// Pre-fills the partner ID field (e.g. from a profile's Remote button).
void prefillRemoteId(String id) => _prefillId.value = id;

/// "Thiết bị gần đây" (remote_recent) with remove / clear; falls back to
/// friends when there is no history yet.
class _RecentDevices extends StatefulWidget {
  const _RecentDevices();
  @override
  State<_RecentDevices> createState() => _RecentDevicesState();
}

class _RecentDevicesState extends State<_RecentDevices> {
  List<Map<String, dynamic>>? _recent;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<LumoraApi>().remoteRecent();
      if (mounted) setState(() => _recent = r);
    } catch (_) {
      if (mounted) setState(() => _recent = const []);
    }
  }

  Future<void> _remove([String? peer]) async {
    await context.read<LumoraApi>().remoteRecentRemove(peer);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final friends = context.select<ContactsStore, List<Contact>>((c) => c.friends.where((f) => !f.isBot).take(6).toList());
    final recent = _recent ?? const [];
    final items = recent.isNotEmpty
        ? [for (final r in recent) (r['peer']?.toString() ?? '', r['name']?.toString() ?? '', r['short_id']?.toString() ?? '', r['trusted'] == true, true)]
        : [for (final c in friends) (c.peer, c.displayName, c.shortId, false, false)];
    if (items.isEmpty) return const SizedBox.shrink();
    return LCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(AppIcons.devices, color: LC.accent),
              const SizedBox(width: 10),
              Expanded(child: Text(recent.isNotEmpty ? s('recent_devices') : s('friends'), style: context.tt.titleMedium)),
              if (recent.isNotEmpty) TextButton(onPressed: () => _remove(), child: Text(s('clear_all'))),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final it in items)
                SizedBox(
                  width: 240,
                  child: Material(
                    color: context.lc.surface2.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(Radii.md),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(Radii.md),
                      onTap: () => _prefillId.value = it.$3,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                        child: Row(
                          children: [
                            const IconTile(AppIcons.laptop, size: IconTileSize.sm),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(it.$2, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleSmall),
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(it.$3, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall),
                                      ),
                                      if (it.$4) ...[const SizedBox(width: 6), Pill(s('trusted'), color: LC.success)],
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            if (it.$5) WakeDeviceButton(entry: recent.firstWhere((r) => r['peer'] == it.$1, orElse: () => const {})),
                            if (it.$5)
                              IconButton(
                                tooltip: s('remove'),
                                onPressed: () => _remove(it.$1),
                                icon: Icon(AppIcons.close, size: 16, color: context.lc.muted),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

/// "New password" (Remote screen, Settings › Remote access): the core makes
/// a new temporary password; the old one stops working.
Future<void> newRemotePassword(BuildContext context) async {
  final s = S.read(context);
  try {
    await context.read<RemoteStore>().refreshPassword();
    if (context.mounted) toast(context, s('remote_password_new_done'));
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

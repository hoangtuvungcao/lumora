// Settings → Advanced → Diagnostics. Detailed network internals live ONLY
// here (collapsed by default), never on the main screens.

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/common.dart';

void openDiagnostics(BuildContext context) {
  if (isDesktop(context)) {
    context.read<NavStore>().go(Section.network);
  } else {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: SafeArea(child: NetworkScreen()))));
  }
}

class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});
  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  @override
  void initState() {
    super.initState();
    final n = context.read<NetStore>();
    if (n.diagnostics == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => n.runDiagnostics().catchError((_) {}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final store = context.watch<NetStore>();
    final net = store.net;
    final diag = store.diagnostics;
    final desktop = isDesktop(context);
    return Material(
      color: context.lc.bg,
      child: Column(children: [
        PaneHeader(
          onBack: desktop ? () => context.read<NavStore>().go(Section.settings) : null,
          leading: const Icon(AppIcons.shieldPlus, color: LC.primary),
          title: Text(s('diagnostics')),
          subtitle: Text(s('advanced')),
          actions: [
            ToolButton(icon: AppIcons.refresh, tooltip: s('run_again'), onPressed: store.loadingDiag ? null : () => store.runDiagnostics()),
          ],
        ),
        Expanded(
          child: ListView(padding: EdgeInsets.all(desktop ? 24 : 16), children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _Summary(net: net),
                  const SizedBox(height: 20),
                  Text(s('troubleshooter'), style: context.tt.titleMedium),
                  const SizedBox(height: 4),
                  Text(s('troubleshooter_hint'), style: context.tt.bodySmall),
                  const SizedBox(height: 12),
                  if (store.loadingDiag && diag == null)
                    const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
                  else if (diag != null) ...[
                    for (final c in [...diag.checks.where((c) => !c.ok), ...diag.checks.where((c) => c.ok)])
                      Padding(padding: const EdgeInsets.only(bottom: 8), child: _CheckCard(check: c)),
                  ],
                  const SizedBox(height: 16),
                  _AdvancedDetails(net: net),
                ]),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.net});
  final NetStatus? net;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final q = connectionQuality(net);
    final failing = context.select<NetStore, int>((n) => n.diagnostics?.checks.where((c) => !c.ok).length ?? 0);
    final color = q >= 3 ? LC.success : (q >= 1 ? LC.warning : LC.danger);
    final wide = MediaQuery.sizeOf(context).width >= 600;
    return LCard(
      padding: const EdgeInsets.all(18),
      child: Row(children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
          child: Center(child: SignalBars(level: q, color: color, height: 22)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(q >= 3 ? s('conn_direct') : (q >= 1 ? s('conn_ok') : s('connecting')), style: context.tt.titleMedium),
            const SizedBox(height: 4),
            Text(failing == 0 ? s('all_checks_ok') : s('n_issues', {'n': failing}),
                style: context.tt.bodySmall?.copyWith(color: failing == 0 ? LC.success : LC.warning)),
            if (!wide) ...[const SizedBox(height: 8), Pill(s('e2e_short'), color: LC.success, icon: AppIcons.lock)],
          ]),
        ),
        if (wide) Pill(s('e2e_short'), color: LC.success, icon: AppIcons.lock),
      ]),
    );
  }
}

/// One troubleshooter item: a plain-language summary and fix (localized by
/// check id); the core's raw text and any commands stay in a collapsed
/// "Technical details" section with a copy button.
class _CheckCard extends StatelessWidget {
  const _CheckCard({required this.check});
  final DiagCheck check;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = check;
    final color = c.ok ? LC.success : LC.warning;
    final summary = c.ok ? s.orElse('diag_${c.id}_ok', s('diag_generic_ok')) : s.orElse('diag_${c.id}_fail', s('diag_generic_fail'));
    final fixKey = 'diag_${c.id}_fix';
    final fix = c.ok ? const <String>[] : s.orElse(fixKey, c.fixSteps.isEmpty && c.commands.isEmpty && c.detail.isEmpty ? '' : s('diag_generic_fix')).split('\n').where((l) => l.trim().isNotEmpty).toList();
    final header = Row(children: [
      Icon(c.ok ? AppIcons.checkCircle : AppIcons.error, color: color, size: 22),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.orElse('diag_${c.id}', s('diag_generic_title')), style: context.tt.titleSmall),
          const SizedBox(height: 2),
          Text(summary, style: context.tt.bodySmall?.copyWith(height: 1.4)),
        ]),
      ),
    ]);
    final tech = _TechDetails(detail: c.detail, steps: c.fixSteps, commands: c.commands);
    if (c.ok) {
      return LCard(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, if (tech.hasContent) tech else const SizedBox(height: 10)]),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
      decoration: BoxDecoration(
        color: context.lc.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: LC.warning.withValues(alpha: 0.45)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        if (fix.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(s('how_to_fix'), style: context.tt.labelLarge?.copyWith(color: LC.warning)),
          const SizedBox(height: 8),
          for (var i = 0; i < fix.length; i++) _Step(n: i + 1, text: fix[i]),
        ],
        if (tech.hasContent) tech else const SizedBox(height: 10),
      ]),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 24,
          height: 24,
          margin: const EdgeInsets.only(top: 1),
          decoration: BoxDecoration(color: LC.primary.withValues(alpha: 0.16), shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Text('$n', style: const TextStyle(color: LC.primary, fontWeight: FontWeight.w700, fontSize: 12)),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text.trim(), style: context.tt.bodyMedium?.copyWith(height: 1.45))),
      ]),
    );
  }
}

/// Raw core text + commands, collapsed, with one copy button.
class _TechDetails extends StatelessWidget {
  const _TechDetails({required this.detail, required this.steps, this.commands = const []});
  final String detail;
  final List<String> steps;
  final List<String> commands;

  bool get hasContent => detail.trim().isNotEmpty || steps.isNotEmpty || commands.isNotEmpty;

  String get _plain => [
        if (detail.trim().isNotEmpty) detail.trim(),
        for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i].trim()}',
        for (final c in commands) '\$ ${c.trim()}',
      ].join('\n');

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    const mono = TextStyle(color: Color(0xFFE8EAF6), fontFamily: 'monospace', fontSize: 12.5, height: 1.45);
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 10),
        visualDensity: VisualDensity.compact,
        dense: true,
        leading: Icon(AppIcons.code, size: 16, color: context.lc.muted),
        title: Text(s('technical_details'), style: context.tt.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            decoration: BoxDecoration(color: const Color(0xFF0B0C18), borderRadius: BorderRadius.circular(Radii.sm)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: SelectableText(_plain, style: mono)),
              IconButton(
                tooltip: s('copy'),
                onPressed: () => copyText(context, _plain.replaceAll(RegExp(r'^\$ ', multiLine: true), '')),
                icon: const Icon(AppIcons.copy, size: 16, color: LC.darkMuted),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

/// Collapsed technical details for power users.
class _AdvancedDetails extends StatelessWidget {
  const _AdvancedDetails({required this.net});
  final NetStatus? net;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final n = net;
    final contacts = context.read<ContactsStore>();
    Widget kv(String k, Widget v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 160, child: Text(k, style: context.tt.bodySmall)),
            Expanded(child: v),
          ]),
        );
    Widget dot(bool ok) => Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(right: 8, top: 5),
          decoration: BoxDecoration(color: ok ? LC.success : LC.danger, shape: BoxShape.circle),
        );
    return Container(
      decoration: BoxDecoration(
        color: context.lc.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: context.lc.divider),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          leading: const RowIcon(AppIcons.code),
          title: Text(s('technical_details')),
          subtitle: Text(s('technical_details_hint'), style: context.tt.bodySmall),
          children: n == null
              ? [Text(s('no_data'))]
              : [
                  kv(s('nat_type'), Align(alignment: Alignment.centerLeft, child: _NatBadge(nat: n.nat))),
                  kv(s('public_address'), SelectableText('${n.publicIp ?? '—'}${n.port > 0 ? ':${n.port}' : ''}', style: const TextStyle(fontFamily: 'monospace', fontSize: 13))),
                  kv(s('local_addresses'),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        for (final a in n.addrs) SelectableText(a, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                      ])),
                  kv(s('tech_ports'), Text(n.upnp ? s('mapped') : s('off'))),
                  kv(s('tech_peer_search'), Text(n.dht ? s('on') : s('off'))),
                  kv(s('lan_peers'), Text('${n.lanPeers}')),
                  kv(s('relays'),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        for (final r in n.relays) Row(crossAxisAlignment: CrossAxisAlignment.start, children: [dot(r.connected), Expanded(child: Text(r.url, style: const TextStyle(fontSize: 13)))]),
                      ])),
                  kv(s('tech_directory'),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        for (final r in n.nostr) Row(crossAxisAlignment: CrossAxisAlignment.start, children: [dot(r.connected), Expanded(child: Text(r.url, style: const TextStyle(fontSize: 13)))]),
                      ])),
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerLeft, child: Text(s('peer_paths'), style: context.tt.labelLarge)),
                  const SizedBox(height: 6),
                  for (final p in n.peers)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(children: [
                        PeerAvatar(peer: p.peer, size: 28, presence: false),
                        const SizedBox(width: 10),
                        Expanded(child: Text(contacts.nameOf(p.peer), maxLines: 1, overflow: TextOverflow.ellipsis)),
                        Pill(s('path_${p.path}'), color: pathColor(p.path), icon: pathIcon(p.path)),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 64,
                          child: Text(p.rttMs == null ? '—' : '${p.rttMs} ms', textAlign: TextAlign.right, style: context.tt.bodySmall),
                        ),
                      ]),
                    ),
                ],
        ),
      ),
    );
  }
}

class _NatBadge extends StatelessWidget {
  const _NatBadge({required this.nat});
  final String nat;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final k = switch (nat) {
      'open' || 'none' => 'open',
      'easy' || 'cone' || 'full_cone' || 'restricted' || 'port_restricted' => 'easy',
      'symmetric' || 'hard' => 'symmetric',
      'blocked' || 'udp_blocked' => 'blocked',
      _ => 'unknown',
    };
    final color = switch (k) {
      'open' => LC.success,
      'easy' => LC.accent,
      'symmetric' => LC.warning,
      'blocked' => LC.danger,
      _ => context.lc.muted,
    };
    return Pill(s('nat_$k'), color: color, icon: AppIcons.router);
  }
}

// Recovery from friends after a restore with the recovery phrase:
// * a banner at the top of the chat list while friends' offers wait,
// * the review list (accept / decline each friend's offer),
// * Settings › Privacy "Help friends restore their history" (core
//   `help_restore`, default on, the same on every device of the account).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/friend_recovery.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/core_events.dart';
import '../widgets/peer_avatar.dart';

/// "Friends offer to restore your history (n)" — only while offers wait.
class RecoveryBanner extends StatefulWidget {
  const RecoveryBanner({super.key});
  @override
  State<RecoveryBanner> createState() => _RecoveryBannerState();
}

class _RecoveryBannerState extends State<RecoveryBanner> {
  @override
  void initState() {
    super.initState();
    RecoveryStore.of(context.read<LumoraApi>()).load().catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final store = RecoveryStore.of(context.read<LumoraApi>());
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final n = store.waiting.length;
        // (not while my own linked device restored the history, or after "stop asking")
        if (n == 0 || !store.recovering) return const SizedBox.shrink();
        final s = S.of(context);
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Material(
            color: LC.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(Radii.md),
            child: ListTile(
              key: const ValueKey('recovery_banner'),
              dense: true,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(gradient: LinearGradient(colors: [LC.primary, LC.accent.withValues(alpha: 0.9)]), shape: BoxShape.circle),
                child: const Icon(AppIcons.history, color: Colors.white, size: 20),
              ),
              title: Text(s('rc_banner', {'n': n}), style: context.tt.titleSmall),
              subtitle: Text(s('rc_banner_hint'), style: context.tt.bodySmall),
              trailing: const Icon(AppIcons.chevronRight, size: 18),
              onTap: () => showRecoveryOffers(context),
            ),
          ),
        );
      },
    );
  }
}

Future<void> showRecoveryOffers(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => const RecoveryOffersSheet(),
    );

/// The review list: which friends offered our history back.
class RecoveryOffersSheet extends StatefulWidget {
  const RecoveryOffersSheet({super.key});
  @override
  State<RecoveryOffersSheet> createState() => _RecoveryOffersSheetState();
}

class _RecoveryOffersSheetState extends State<RecoveryOffersSheet> {
  final Set<String> _busy = {};

  Future<void> _answer(RecoveryOffer o, bool accept) async {
    final s = S.read(context);
    final api = context.read<LumoraApi>();
    final store = RecoveryStore.of(api);
    final chat = context.read<ChatStore>();
    final contacts = context.read<ContactsStore>();
    setState(() => _busy.add(o.peer));
    try {
      if (accept) {
        await store.accept(o.peer);
        if (!mounted) return;
        toast(context, s('rc_accepted_toast', {'name': o.name}));
        await contacts.load().catchError((_) {});
        await chat.load().catchError((_) {});
      } else {
        await store.decline(o.peer);
      }
    } catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => _busy.remove(o.peer));
    }
  }

  Widget _status(BuildContext context, RecoveryOffer o) {
    final s = S.of(context);
    final (text, color) = switch (o.state) {
      'accepted' => (s('rc_receiving', {'n': o.received}), LC.primary),
      'done' => (s('rc_done', {'n': o.received}), LC.success),
      _ => (s('rc_declined'), context.lc.muted),
    };
    return Text(text, key: ValueKey('recovery_state_${o.peer}'), style: context.tt.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w600));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final store = RecoveryStore.of(context.read<LumoraApi>());
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
          child: Column(key: const ValueKey('recovery_sheet'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 4), child: Text(s('rc_title'), style: context.tt.titleMedium)),
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 10), child: Text(s('rc_hint'), style: context.tt.bodySmall)),
            if (store.offers.isEmpty)
              Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(s('rc_empty'), textAlign: TextAlign.center, style: context.tt.bodySmall))),
            Flexible(
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(12, 0, 12, 4), children: [
                for (final o in store.offers)
                  Padding(
                    key: ValueKey('recovery_offer_${o.peer}'),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: LCard(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          PeerAvatar(peer: o.peer, size: 46, presence: false, fallbackName: o.name),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                Flexible(child: Text(o.name.isEmpty ? '?' : o.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleSmall)),
                                if (o.verified) ...[
                                  const SizedBox(width: 6),
                                  Tooltip(message: s('rc_verified_hint'), child: Pill(s('rc_verified'), color: LC.success, icon: AppIcons.shieldCheck)),
                                ] else ...[
                                  const SizedBox(width: 6),
                                  Tooltip(
                                    message: s('rc_unverified_hint'),
                                    child: Pill(s('rc_unverified'), key: ValueKey('recovery_unverified_${o.peer}'), color: LC.warning, icon: AppIcons.warning),
                                  ),
                                ],
                              ]),
                              const SizedBox(height: 2),
                              Text(s('rc_detail', {'n': o.messages, 'g': o.groups}), style: context.tt.bodySmall),
                              if (o.state != 'offered') ...[const SizedBox(height: 2), _status(context, o)],
                            ]),
                          ),
                        ]),
                        if (o.state == 'offered') ...[
                          const SizedBox(height: 10),
                          Row(children: [
                            Expanded(
                              child: OutlinedButton(
                                key: ValueKey('recovery_decline_${o.peer}'),
                                onPressed: _busy.contains(o.peer) ? null : () => _answer(o, false),
                                child: Text(s('rc_decline')),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton(
                                key: ValueKey('recovery_accept_${o.peer}'),
                                onPressed: _busy.contains(o.peer) ? null : () => _answer(o, true),
                                child: Text(s('rc_accept')),
                              ),
                            ),
                          ]),
                        ],
                      ]),
                    ),
                  ),
              ]),
            ),
            if (store.recovering)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: TextButton(
                  key: const ValueKey('recovery_dismiss'),
                  onPressed: () async {
                    await store.dismiss().catchError((_) {});
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: Text(s('rc_dismiss')),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Settings › Privacy: "Help friends restore their history". An account
/// setting kept by the core: a change made on another of my devices
/// (`settings` event) shows here at once. Hidden with an older core.
class HelpRestoreRow extends StatefulWidget {
  const HelpRestoreRow({super.key});
  @override
  State<HelpRestoreRow> createState() => _HelpRestoreRowState();
}

class _HelpRestoreRowState extends State<HelpRestoreRow> {
  bool? _on;
  CoreEventWatch? _synced;

  @override
  void initState() {
    super.initState();
    _load();
    _synced = CoreEventWatch.settings(context.read<LumoraApi>(), {'privacy.help_restore'}, _load);
  }

  @override
  void dispose() {
    _synced?.cancel();
    super.dispose();
  }

  void _load() {
    context.read<LumoraApi>().settingsGet().then((v) {
      if (mounted && v['help_restore'] is bool) setState(() => _on = v['help_restore'] as bool);
    }).catchError((_) {});
  }

  Future<void> _set(bool v) async {
    final s = S.read(context);
    final old = _on;
    setState(() => _on = v);
    try {
      await context.read<LumoraApi>().settingsSet({'help_restore': v});
    } catch (_) {
      if (!mounted) return;
      setState(() => _on = old);
      toast(context, s('err_internal'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = _on;
    if (on == null) return const SizedBox.shrink();
    final s = S.of(context);
    return SwitchRow(key: const ValueKey('help_restore'), icon: AppIcons.history, title: s('help_restore'), subtitle: s('help_restore_hint'), value: on, onChanged: _set);
  }
}

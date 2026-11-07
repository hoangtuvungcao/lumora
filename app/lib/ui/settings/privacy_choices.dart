// Settings › Privacy › "Who can reach you": who may call me, add me to groups
// and see that I'm online. Account settings kept by the core
// (`settings_get` / `settings_set`), the same on every device of the account:
// a change made on another device (`settings` event) shows here at once.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/core_events.dart';

/// One choice: its core setting, `settings` event key, the values offered,
/// the default, and its row's copy.
typedef PrivacyChoice = ({String name, String event, List<String> values, String fallback, IconData icon, String title, String hint});

const List<PrivacyChoice> kPrivacyChoices = [
  (name: 'who_can_call', event: 'privacy.calls', values: ['everyone', 'friends', 'nobody'], fallback: 'friends', icon: AppIcons.call, title: 'pc_calls', hint: 'pc_calls_hint'),
  (name: 'who_can_add', event: 'privacy.group_add', values: ['friends', 'nobody'], fallback: 'friends', icon: AppIcons.people, title: 'pc_group_add', hint: 'pc_group_add_hint'),
  (name: 'who_sees_online', event: 'privacy.online', values: ['friends', 'nobody'], fallback: 'friends', icon: AppIcons.activity, title: 'pc_online', hint: 'pc_online_hint'),
];

IconData _valueIcon(String v) => switch (v) {
      'everyone' => AppIcons.globe,
      'friends' => AppIcons.friends,
      _ => AppIcons.block,
    };

class PrivacyChoicesGroup extends StatefulWidget {
  const PrivacyChoicesGroup({super.key});
  @override
  State<PrivacyChoicesGroup> createState() => _PrivacyChoicesGroupState();
}

class _PrivacyChoicesGroupState extends State<PrivacyChoicesGroup> {
  /// name → value; empty until the core answered (an older core: hidden).
  Map<String, String> _values = const {};
  CoreEventWatch? _synced;

  @override
  void initState() {
    super.initState();
    _load();
    _synced = CoreEventWatch.settings(context.read<LumoraApi>(), {for (final c in kPrivacyChoices) c.event}, _load);
  }

  @override
  void dispose() {
    _synced?.cancel();
    super.dispose();
  }

  void _load() {
    context.read<LumoraApi>().settingsGet().then((v) {
      if (!mounted) return;
      final got = <String, String>{
        for (final c in kPrivacyChoices)
          if (v[c.name] is String) c.name: c.values.contains(v[c.name]) ? v[c.name] as String : c.fallback,
      };
      setState(() => _values = got);
    }).catchError((_) {});
  }

  Future<void> _set(PrivacyChoice c, String v) async {
    final s = S.read(context);
    final api = context.read<LumoraApi>();
    final old = _values[c.name];
    setState(() => _values = {..._values, c.name: v});
    try {
      await api.settingsSet({c.name: v});
    } catch (_) {
      if (!mounted) return;
      setState(() => _values = {..._values, c.name: ?old});
      toast(context, s('err_internal'));
    }
  }

  Future<void> _pick(PrivacyChoice c) async {
    final s = S.read(context);
    final current = _values[c.name] ?? c.fallback;
    final v = await showModalBottomSheet<String>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(24, 16, 24, 4), child: Text(s(c.title), style: ctx.tt.titleMedium)),
          Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Text('${s(c.hint)}. ${s('pc_synced')}.', style: ctx.tt.bodySmall)),
          for (final o in c.values)
            ListTile(
              key: ValueKey('privacy_opt_$o'),
              leading: Icon(_valueIcon(o)),
              title: Text(s('pc_$o')),
              trailing: o == current ? const Icon(AppIcons.check, color: LC.primary) : null,
              onTap: () => Navigator.pop(ctx, o),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (v != null && v != current && mounted) await _set(c, v);
  }

  @override
  Widget build(BuildContext context) {
    if (_values.isEmpty) return const SizedBox.shrink();
    final s = S.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(s('pc_title'), padding: const EdgeInsets.fromLTRB(4, 8, 4, 8)),
      LCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(children: [
          for (final c in kPrivacyChoices)
            if (_values[c.name] case final v?)
              ListTile(
                key: ValueKey('privacy_${c.name}'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: RowIcon(c.icon),
                title: Text(s(c.title), style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                subtitle: Text(s(c.hint), style: context.tt.bodySmall),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(s('pc_$v'), key: ValueKey('privacy_value_${c.name}'), style: context.tt.bodyMedium?.copyWith(color: LC.primary, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 4),
                  Icon(AppIcons.chevronRight, size: 18, color: context.lc.muted),
                ]),
                onTap: () => _pick(c),
              ),
        ]),
      ),
      const SizedBox(height: 16),
    ]);
  }
}

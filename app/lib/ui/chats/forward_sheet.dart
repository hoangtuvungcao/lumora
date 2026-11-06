import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/peer_avatar.dart';
import '../../state/app_lock.dart';
import '../../core/text_fold.dart';

/// Chat picker used by "Forward" (returns the chosen conversation id).
Future<String?> pickConversation(BuildContext context, {required String title, String? exclude}) {
  final body = _ConvPicker(title: title, exclude: exclude);
  if (isDesktop(context)) {
    return showDialog<String>(context: context, builder: (_) => Dialog(child: SizedBox(width: 420, height: 560, child: body)));
  }
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (c) => SizedBox(height: MediaQuery.sizeOf(c).height * 0.8, child: body),
  );
}

class _ConvPicker extends StatefulWidget {
  const _ConvPicker({required this.title, this.exclude});
  final String title;
  final String? exclude;
  @override
  State<_ConvPicker> createState() => _ConvPickerState();
}

class _ConvPickerState extends State<_ConvPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final chat = context.watch<ChatStore>();
    final lock = context.watch<AppLock>();
    final list = chat.sorted
        .where((c) => c.id != widget.exclude && !c.archived && !lock.isChatHidden(c.id))
        .where((c) => _q.isEmpty || foldText(c.title).contains(_q) || (c.isSaved && foldText(s('saved_messages')).contains(_q)))
        .toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 8, 4),
        child: Row(children: [
          Expanded(child: Text(widget.title, style: context.tt.titleMedium)),
          IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(AppIcons.close), tooltip: s('close')),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: TextField(
          autofocus: isDesktop(context),
          onChanged: (v) => setState(() => _q = foldText(v.trim())),
          decoration: InputDecoration(hintText: s('search_chats'), prefixIcon: const Icon(AppIcons.search, size: 20)),
        ),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: list.length,
          itemBuilder: (_, i) {
            final c = list[i];
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: c.isSaved
                  ? const SavedAvatar(size: 40)
                  : (c.peer != null ? PeerAvatar(peer: c.peer!, fallbackName: c.title, size: 40) : GroupAvatar(gid: c.gid ?? c.id, name: c.title, size: 40)),
              title: Text(c.isSaved ? s('saved_messages') : c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(context, c.id),
            );
          },
        ),
      ),
    ]);
  }
}

/// Scheduled messages list (for the current conversation, or all).
Future<void> showScheduled(BuildContext context, {String? conv}) async {
  final chat = context.read<ChatStore>();
  await chat.loadScheduled();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (c) => Consumer<ChatStore>(builder: (c, chat, _) {
      final s = S.of(c);
      final items = chat.scheduled.where((x) => conv == null || x.conv == conv).toList()..sort((a, b) => a.at.compareTo(b.at));
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Text(s('scheduled_messages'), style: c.tt.titleMedium)),
          if (items.isEmpty)
            Padding(padding: const EdgeInsets.all(24), child: Text(s('no_scheduled'), textAlign: TextAlign.center, style: c.tt.bodySmall)),
          for (final it in items)
            ListTile(
              leading: const Icon(AppIcons.schedule, color: LC.primary),
              title: Text(it.text, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(_fmt(s, DateTime.fromMillisecondsSinceEpoch(it.at))),
              trailing: IconButton(
                tooltip: s('cancel'),
                icon: const Icon(AppIcons.delete, color: LC.danger),
                onPressed: () => chat.cancelScheduled(it.id),
              ),
            ),
          const SizedBox(height: 8),
        ]),
      );
    }),
  );
}

String _fmt(S s, DateTime d) => '${s.dayLabel(d, DateTime.now())} · ${s.hhmm(d)}';

/// Date + time picker for "Schedule send".
Future<DateTime?> pickScheduleTime(BuildContext context) async {
  final now = DateTime.now();
  final s = S.read(context);
  final quick = <(String, DateTime)>[
    (s('in_1_hour'), now.add(const Duration(hours: 1))),
    (s('tonight_20'), DateTime(now.year, now.month, now.day, 20)),
    (s('tomorrow_9'), DateTime(now.year, now.month, now.day + 1, 9)),
  ].where((e) => e.$2.isAfter(now)).toList();
  final r = await showModalBottomSheet<Object>(
    context: context,
    constraints: const BoxConstraints(maxWidth: 480),
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Text(s('schedule_send'), style: c.tt.titleMedium)),
        for (final q in quick)
          ListTile(
            leading: const Icon(AppIcons.clock),
            title: Text(q.$1),
            subtitle: Text(_fmt(s, q.$2)),
            onTap: () => Navigator.pop(c, q.$2),
          ),
        ListTile(
          leading: const Icon(AppIcons.scheduled),
          title: Text(s('pick_date_time')),
          onTap: () => Navigator.pop(c, 'custom'),
        ),
      ]),
    ),
  );
  if (r is DateTime) return r;
  if (r != 'custom' || !context.mounted) return null;
  final d = await showDatePicker(context: context, firstDate: now, lastDate: now.add(const Duration(days: 365)), initialDate: now);
  if (d == null || !context.mounted) return null;
  final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))));
  if (t == null) return null;
  final at = DateTime(d.year, d.month, d.day, t.hour, t.minute);
  return at.isAfter(now) ? at : null;
}

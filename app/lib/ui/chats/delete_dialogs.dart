// Telegram-style destructive actions with clear choices.

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/settings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// "Delete message": only for me / for both sides (or everyone in groups).
Future<void> askDeleteMessage(BuildContext context, String conv, Message m) async {
  final s = S.read(context);
  final chat = context.read<ChatStore>();
  final group = conv.startsWith('g:');
  final canEveryone = m.mine || !group;
  final r = await showDialog<String>(
    context: context,
    builder: (c) => SimpleDialog(
      title: Text(s('delete_message_q')),
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Text(s('delete_message_hint'), style: c.tt.bodySmall)),
        if (canEveryone)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: const Icon(AppIcons.friends, color: LC.danger),
            title: Text(group ? s('delete_for_everyone') : s('delete_for_both'), style: const TextStyle(color: LC.danger)),
            onTap: () => Navigator.pop(c, 'all'),
          ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 24),
          leading: const Icon(AppIcons.user),
          title: Text(s('delete_for_me')),
          onTap: () => Navigator.pop(c, 'me'),
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 24),
          leading: const Icon(AppIcons.close),
          title: Text(s('cancel')),
          onTap: () => Navigator.pop(c),
        ),
      ],
    ),
  );
  if (r == null) return;
  try {
    await chat.deleteFor(conv, m.id, forEveryone: r == 'all');
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

/// Clear history / delete chat with an optional "also for the other side".
Future<void> askClearChat(BuildContext context, String conv, {required bool deleteChat}) async {
  final s = S.read(context);
  final chat = context.read<ChatStore>();
  final nav = context.read<NavStore>();
  var everyone = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text(deleteChat ? s('delete_chat') : s('clear_history')),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(deleteChat ? s('delete_chat_body') : s('clear_history_body')),
            if (conv.startsWith('d:')) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                value: everyone,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(s('also_for_other')),
                onChanged: (v) => set(() => everyone = v ?? false),
              ),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s('cancel'))),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: LC.danger), onPressed: () => Navigator.pop(c, true), child: Text(s('delete'))),
        ],
      ),
    ),
  );
  if (ok != true) return;
  try {
    if (deleteChat) {
      await chat.deleteConversationFor(conv, forEveryone: everyone);
      if (nav.conv == conv) nav.openConv(null);
    } else {
      await chat.clearHistory(conv, forEveryone: everyone);
    }
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

/// Mute for 1 h / 8 h / 1 day / always, "only when I'm mentioned" (groups),
/// or unmute.
Future<void> pickMute(BuildContext context, String conv) async {
  final s = S.read(context);
  final chat = context.read<ChatStore>();
  final settings = context.read<Settings>();
  final muted = chat.convs[conv]?.muted ?? false;
  final mentionsOnly = settings.mentionsOnlyChats.contains(conv);
  final group = conv.startsWith('g:') || conv.contains('#');
  final now = DateTime.now().millisecondsSinceEpoch;
  const forever = 9007199254740991; // max safe JSON integer ≈ "always"
  const onlyMentions = -1;
  final r = await showModalBottomSheet<int>(
    context: context,
    constraints: const BoxConstraints(maxWidth: 480),
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Text(s('mute_for'), style: c.tt.titleMedium)),
        for (final (label, until) in [
          (s('mute_1h'), now + 3600000),
          (s('mute_8h'), now + 8 * 3600000),
          (s('mute_1d'), now + 86400000),
          (s('mute_always'), forever),
        ])
          ListTile(leading: const Icon(AppIcons.mute), title: Text(label), onTap: () => Navigator.pop(c, until)),
        if (group)
          ListTile(
            leading: const Icon(AppIcons.mention),
            title: Text(s('mute_mentions_only')),
            subtitle: Text(s('mute_mentions_only_hint')),
            trailing: mentionsOnly ? const Icon(AppIcons.check, color: LC.primary) : null,
            onTap: () => Navigator.pop(c, onlyMentions),
          ),
        if (muted) ListTile(leading: const Icon(AppIcons.bellRinging, color: LC.primary), title: Text(s('unmute')), onTap: () => Navigator.pop(c, 0)),
      ]),
    ),
  );
  if (r == null) return;
  // "Mentions only" = muted for good, plus a local exception for @mentions of me
  final only = r == onlyMentions;
  if (only != mentionsOnly) {
    settings.update((x) => x.mentionsOnlyChats = only ? [...x.mentionsOnlyChats, conv] : x.mentionsOnlyChats.where((c) => c != conv).toList());
  }
  await chat.muteUntil(conv, only ? forever : r);
}

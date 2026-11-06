// "Báo cáo / Report". Lumora has no server and no moderation team, so a report
// goes to the people who can act on it:
//  * a group message / member → the group's owner and admins (they get it in
//    the bell with the actions they already have);
//  * a whole group → leave it and block it on all my devices;
//  * a 1-1 chat → block the person (and optionally delete the chat).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/moderation.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';

const kReportReasons = ['spam', 'harassment', 'adult', 'other'];

/// Report a group message ([message]) or a member ([peer]) to the group's admins.
Future<void> reportGroupContent(BuildContext context, {required String gid, required String peer, required String name, Message? message}) async {
  final s = S.read(context);
  final moderation = context.read<ModerationStore>();
  final r = await showDialog<_ReportChoice>(context: context, builder: (_) => _ReportDialog(name: name, message: message != null));
  if (r == null) return;
  try {
    await moderation.report(gid, msgId: message?.id, peer: peer, reason: r.reason, note: r.note, hide: r.hide);
    if (context.mounted) toast(context, s('report_sent'));
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

typedef _ReportChoice = ({String reason, String note, bool hide});

class _ReportDialog extends StatefulWidget {
  const _ReportDialog({required this.name, required this.message});
  final String name;
  final bool message;
  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  final _note = TextEditingController();
  String? _reason;
  bool _hide = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return AlertDialog(
      title: Text(widget.message ? s('report_message') : s('report_member_title', {'name': widget.name})),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s('report_to_admins_hint', {'name': widget.name}), style: context.tt.bodySmall),
            const SizedBox(height: 12),
            Text(s('report_why'), style: context.tt.titleSmall),
            RadioGroup<String>(
              groupValue: _reason,
              onChanged: (v) => setState(() => _reason = v),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final r in kReportReasons)
                  RadioListTile<String>(
                    key: ValueKey('report_reason_$r'),
                    value: r,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(s('report_reason_$r')),
                  ),
              ]),
            ),
            TextField(
              controller: _note,
              maxLength: 300,
              maxLines: 2,
              minLines: 1,
              decoration: InputDecoration(labelText: s('report_note')),
            ),
            CheckboxListTile(
              value: _hide,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(s('report_hide_member', {'name': widget.name})),
              subtitle: Text(s('report_hide_member_hint')),
              onChanged: (v) => setState(() => _hide = v ?? false),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s('cancel'))),
        FilledButton(
          onPressed: _reason == null ? null : () => Navigator.pop(context, (reason: _reason!, note: _note.text.trim(), hide: _hide)),
          child: Text(s('report_send')),
        ),
      ],
    );
  }
}

/// Report a whole group: leave it and block it on all my devices. Returns true when done.
Future<bool> reportGroup(BuildContext context, {required String gid, required String name}) async {
  final s = S.read(context);
  final moderation = context.read<ModerationStore>();
  final chat = context.read<ChatStore>();
  final nav = context.read<NavStore>();
  final ok = await confirm(
    context,
    title: s('report_group_title', {'name': name}),
    body: s('report_group_body'),
    action: s('report_group_action'),
    danger: true,
  );
  if (!ok) return false;
  try {
    await moderation.blockGroup(gid, name: name);
    final conv = 'g:$gid';
    chat.onGroupRemoved(conv, left: true);
    if (nav.conv == conv) nav.openConv(null);
    if (context.mounted) toast(context, s('report_group_done'));
    return true;
  } catch (e) {
    if (context.mounted) toastError(context, e);
    return false;
  }
}

/// Report a 1-1 chat: block the person, optionally delete the chat. One dialog.
Future<bool> reportContact(BuildContext context, {required String peer, required String name, String? conv}) async {
  final s = S.read(context);
  final contacts = context.read<ContactsStore>();
  final chat = context.read<ChatStore>();
  final nav = context.read<NavStore>();
  var delete = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text(s('report_contact_title', {'name': name})),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s('report_contact_body', {'name': name})),
            if (conv != null) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                value: delete,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(s('report_contact_delete')),
                onChanged: (v) => set(() => delete = v ?? false),
              ),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s('cancel'))),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: LC.danger), onPressed: () => Navigator.pop(c, true), child: Text(s('block'))),
        ],
      ),
    ),
  );
  if (ok != true) return false;
  try {
    await contacts.block(peer);
    if (delete && conv != null) {
      await chat.deleteConversationFor(conv);
      if (nav.conv == conv) nav.openConv(null);
    }
    if (context.mounted) toast(context, s('report_contact_done', {'name': name}));
    return true;
  } catch (e) {
    if (context.mounted) toastError(context, e);
    return false;
  }
}

/// Admin: a report from the bell, with the actions an admin already has.
Future<void> showReportReview(BuildContext context, GroupReport r) {
  return showDialog<void>(context: context, builder: (_) => ReportReview(report: r));
}

class ReportReview extends StatelessWidget {
  const ReportReview({super.key, required this.report});
  final GroupReport report;

  Future<void> _act(BuildContext context, Future<void> Function() f) async {
    final moderation = context.read<ModerationStore>();
    final navigator = Navigator.of(context);
    final s = S.read(context);
    try {
      await f();
      await moderation.handled(report.id);
      navigator.pop();
      if (context.mounted) toast(context, s('report_handled'));
    } catch (e) {
      if (context.mounted) toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final r = report;
    final api = context.read<LumoraApi>();
    final chat = context.read<ChatStore>();
    // handled on another device meanwhile: nothing left to do here
    final open = context.select<ModerationStore, bool>((m) => m.byId(r.id) != null);
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: context.tt.bodySmall),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
        );
    return AlertDialog(
      title: Text(s('report_review')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(r.groupName, style: context.tt.titleSmall),
            const SizedBox(height: 10),
            row(s('report_reported'), r.memberName),
            row(s('report_reason_label'), s('report_reason_${kReportReasons.contains(r.reason) ? r.reason : 'other'}')),
            if (r.note.isNotEmpty) row(s('report_note_label'), r.note),
            row(s('report_by'), r.reporterName),
            if (r.msgId != null)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: context.lc.surface, borderRadius: BorderRadius.circular(Radii.md), border: Border.all(color: context.lc.divider)),
                child: Text(
                  r.msgExists ? (r.excerpt.isNotEmpty ? '“${r.excerpt}”' : s('report_message')) : s('report_msg_gone'),
                  style: context.tt.bodyMedium?.copyWith(fontStyle: r.msgExists ? FontStyle.normal : FontStyle.italic),
                ),
              ),
            const SizedBox(height: 8),
            if (open) ...[
              if (r.msgId != null && r.msgExists)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(AppIcons.delete, color: LC.danger),
                  title: Text(s('report_delete_msg'), style: const TextStyle(color: LC.danger)),
                  onTap: () => _act(context, () => chat.deleteFor(r.conv, r.msgId!, forEveryone: true)),
                ),
              if (r.memberInGroup) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(AppIcons.signOut, color: LC.danger),
                  title: Text(s('remove_member'), style: const TextStyle(color: LC.danger)),
                  onTap: () => _act(context, () => api.groupRemove(r.gid, r.member)),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(AppIcons.block, color: LC.danger),
                  title: Text(s('ban_member'), style: const TextStyle(color: LC.danger)),
                  onTap: () => _act(context, () => api.groupBan(r.gid, r.member, true)),
                ),
              ],
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            final nav = context.read<NavStore>();
            Navigator.pop(context);
            nav.openConv(r.conv.split('#').first);
          },
          child: Text(s('report_open_chat')),
        ),
        if (open) FilledButton.tonal(onPressed: () => _act(context, () async {}), child: Text(s('report_dismiss'))) else TextButton(onPressed: () => Navigator.pop(context), child: Text(s('close'))),
      ],
    );
  }
}

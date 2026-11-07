import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../devices/contact_devices.dart';
import '../friends/safety_number.dart';
import '../groups/group_info.dart';
import '../calls/group_call.dart' show startCallIn;
import '../theme.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/common.dart';
import '../profile/profile_screen.dart';
import '../settings/blocked_screen.dart';
import '../settings/storage_screen.dart';
import 'attachments.dart';
import 'delete_dialogs.dart';
import 'report_dialogs.dart';
import 'message_bubble.dart';
import 'wallpaper.dart';
import '../../state/app_lock.dart';

/// Right-hand info panel (desktop) / info page (mobile).
class ChatInfoPanel extends StatelessWidget {
  const ChatInfoPanel({super.key, required this.conv, this.embedded = false});
  final String conv;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    if (conv.startsWith('g:')) return GroupInfoView(gid: conv.substring(2), embedded: embedded);
    return _DirectInfo(conv: conv, embedded: embedded);
  }
}

class _DirectInfo extends StatelessWidget {
  const _DirectInfo({required this.conv, required this.embedded});
  final String conv;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final peer = conv.substring(2);
    final c = context.select<ContactsStore, Contact?>((x) => x[peer]);
    final convo = context.select<ChatStore, Conversation?>((x) => x.convs[conv]);
    final ttl = context.select<ChatStore, int>((x) => x.ttlByConv[conv] ?? 0);
    final files = context.select<FilesStore, List<FileItem>>((f) => f.sorted.where((x) => x.conv == conv).toList());
    final chat = context.read<ChatStore>();
    if (c == null) return EmptyState(icon: AppIcons.removeUser, title: s('unknown_contact'));
    return Column(children: [
      PaneHeader(
        title: Text(s('conversation_info')),
        onBack: embedded ? null : () => Navigator.of(context).maybePop(),
        actions: [
          if (embedded)
            ToolButton(icon: AppIcons.close, tooltip: s('close'), onPressed: () => context.read<NavStore>().toggleInfo(false)),
        ],
      ),
      Expanded(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Center(child: InkWell(customBorder: const CircleBorder(), onTap: () => openProfile(context, c.peer), child: PeerAvatar(peer: c.peer, size: 88))),
          const SizedBox(height: 12),
          Center(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: Text(c.displayName, style: context.tt.titleLarge, overflow: TextOverflow.ellipsis)),
              if (c.verified) ...[const SizedBox(width: 6), const Icon(AppIcons.verifiedFill, color: LC.accent, size: 20)],
            ]),
          ),
          const SizedBox(height: 4),
          Center(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => copyText(context, c.shortId),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('ID ${c.shortId}', style: context.tt.bodySmall),
                  const SizedBox(width: 6),
                  Icon(AppIcons.copy, size: 13, color: context.lc.muted),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _Action(icon: AppIcons.call, label: s('call'), onTap: () => startCallIn(context, conv)),
            _Action(icon: AppIcons.video, label: s('video'), onTap: () => startCallIn(context, conv, video: true)),
            _Action(
              icon: (convo?.muted ?? false) ? AppIcons.mute : AppIcons.bell,
              label: (convo?.muted ?? false) ? s('unmute') : s('mute'),
              onTap: () => pickMute(context, conv),
            ),
            _Action(
              icon: AppIcons.pin,
              label: (convo?.pinned ?? false) ? s('unpin') : s('pin'),
              onTap: () => chat.setFlag(conv, 'pinned', !(convo?.pinned ?? false)),
            ),
          ]),
          const SizedBox(height: 20),
          LCard(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Column(children: [
              ListTile(
                leading: Icon(c.verified ? AppIcons.shieldCheck : AppIcons.shield, color: c.verified ? LC.success : null),
                title: Text(c.verified ? s('verified') : s('verify_safety')),
                subtitle: Text(s('verify_hint'), maxLines: 2),
                onTap: () => openSafetyNumber(context, c),
              ),
              ContactDevicesTile(peer: c.peer),
              ListTile(
                leading: Icon(ttl > 0 ? AppIcons.timer : AppIcons.timer, color: ttl > 0 ? LC.warning : null),
                title: Text(s('self_destruct')),
                trailing: Text(s.ttlLabel(ttl), style: context.tt.bodySmall),
                onTap: () => _ttl(context),
              ),
              RetentionTile(conv: conv),
              ClearMediaTile(conv: conv, title: c.displayName),
              ListTile(
                leading: const RowIcon(AppIcons.wallpaper),
                title: Text(s('wallpaper')),
                trailing: const Icon(AppIcons.chevronRight, size: 18),
                onTap: () => showWallpaperPicker(context, conv),
              ),
              ListTile(
                leading: const RowIcon(AppIcons.edit),
                title: Text(s('set_nickname')),
                onTap: () async {
                  final v = await promptText(context, title: s('set_nickname'), initial: c.alias ?? c.name, action: s('save'));
                  if (v != null && context.mounted) context.read<ContactsStore>().rename(c.peer, v);
                },
              ),
            ]),
          ),
          SectionLabel(s('media_files'), padding: const EdgeInsets.fromLTRB(4, 20, 4, 8)),
          MediaSection(conv: conv, files: files),
          const SizedBox(height: 16),
          LCard(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Column(children: [
              if (c.status == ContactStatus.blocked)
                ListTile(
                  leading: const Icon(AppIcons.checkCircle, color: LC.success),
                  title: Text(s('unblock'), style: const TextStyle(color: LC.success)),
                  onTap: () => unblockContact(context, c),
                )
              else
                ListTile(
                  leading: const Icon(AppIcons.block, color: LC.danger),
                  title: Text(s('block'), style: const TextStyle(color: LC.danger)),
                  onTap: () async {
                    if (await confirm(context, title: s('block_title', {'name': c.displayName}), body: s('block_body'), action: s('block'), danger: true)) {
                      if (context.mounted) context.read<ContactsStore>().block(c.peer);
                    }
                  },
                ),
              if (c.status != ContactStatus.blocked)
                ListTile(
                  leading: const Icon(AppIcons.report, color: LC.danger),
                  title: Text(s('report'), style: const TextStyle(color: LC.danger)),
                  onTap: () async {
                    final nav = context.read<NavStore>();
                    final chats = context.read<ChatStore>();
                    final done = await reportContact(context, peer: c.peer, name: c.displayName, conv: conv);
                    if (done && !chats.convs.containsKey(conv)) {
                      nav.toggleInfo(false);
                      if (!embedded && context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                    }
                  },
                ),
              ListTile(
                leading: const Icon(AppIcons.delete, color: LC.danger),
                title: Text(s('delete_chat'), style: const TextStyle(color: LC.danger)),
                onTap: () async {
                  if (await confirm(context, title: s('delete_chat'), body: s('delete_chat_body'), action: s('delete'), danger: true)) {
                    if (!context.mounted) return;
                    chat.deleteConversation(conv);
                    context.read<NavStore>().openConv(null);
                    if (!embedded) Navigator.of(context).popUntil((r) => r.isFirst);
                  }
                },
              ),
            ]),
          ),
        ]),
      ),
    ]);
  }

  Future<void> _ttl(BuildContext context) async {
    final s = S.read(context);
    const opts = [0, 300000, 3600000, 86400000, 604800000];
    final r = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(s('self_destruct')),
        children: [for (final o in opts) SimpleDialogOption(onPressed: () => Navigator.pop(c, o), child: Text(s.ttlLabel(o)))],
      ),
    );
    if (r != null && context.mounted) context.read<ChatStore>().setTtl(conv, r);
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(children: [
            IconTile(icon, circle: true),
            const SizedBox(height: 6),
            Text(label, style: context.tt.bodySmall),
          ]),
        ),
      );
}

const kRetentionModes = ['forever', 'session', '24h', '7d', '30d'];

String retentionLabel(S s, String mode) => s('retention_$mode');

/// "Message history" setting row (forever / no history / auto-delete).
class RetentionTile extends StatelessWidget {
  const RetentionTile({super.key, required this.conv});
  final String conv;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final mode = context.select<ChatStore, String>((c) => c.retention[conv] ?? 'forever');
    return ListTile(
      leading: Icon(mode == 'forever' ? AppIcons.history : AppIcons.timerReset, color: mode == 'forever' ? null : LC.accent),
      title: Text(s('message_history')),
      subtitle: Text(retentionLabel(s, mode), style: context.tt.bodySmall),
      trailing: const Icon(AppIcons.chevronRight, size: 18),
      onTap: () => pickRetention(context, conv),
    );
  }
}

Future<void> pickRetention(BuildContext context, String conv) async {
  final s = S.read(context);
  final chat = context.read<ChatStore>();
  final cur = chat.retention[conv] ?? 'forever';
  final r = await showDialog<String>(
    context: context,
    builder: (c) => SimpleDialog(
      title: Text(s('message_history')),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(s('retention_hint'), style: c.tt.bodySmall),
        ),
        for (final m in kRetentionModes)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: Icon(m == cur ? AppIcons.radioOn : AppIcons.radioOff, color: m == cur ? LC.primary : null),
            title: Text(retentionLabel(s, m)),
            subtitle: m == 'session' ? Text(s('retention_session_hint'), style: c.tt.bodySmall) : null,
            onTap: () => Navigator.pop(c, m),
          ),
      ],
    ),
  );
  if (r != null && r != cur) await chat.setRetention(conv, r);
}

/// Small badge shown in chat headers when history is not kept forever.
class RetentionBadge extends StatelessWidget {
  const RetentionBadge({super.key, required this.conv});
  final String conv;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final mode = context.select<ChatStore, String>((c) => c.retention[conv] ?? 'forever');
    if (mode == 'forever') return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Tooltip(
        message: '${s('message_history')}: ${retentionLabel(s, mode)}',
        child: Pill(mode == 'session' ? s('no_history_short') : mode, color: LC.accent, icon: mode == 'session' ? AppIcons.hide : AppIcons.timerReset),
      ),
    );
  }
}


/// "Media & files" tabs: photo grid, file list, links.
class MediaSection extends StatefulWidget {
  const MediaSection({super.key, required this.conv, required this.files});
  final String conv;
  final List<FileItem> files;
  @override
  State<MediaSection> createState() => _MediaSectionState();
}

class _MediaSectionState extends State<MediaSection> {
  int _tab = 0;
  static final _url = RegExp(r'https?://[^\s]+');

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    // Profile / group pages can be opened without the chat: a locked chat's
    // photos, files and links stay hidden until the folder is opened.
    if (context.select<AppLock, bool>((l) => l.isChatHidden(widget.conv))) return const SizedBox.shrink();
    final thread = context.read<ChatStore>().thread(widget.conv);
    return ListenableBuilder(
      listenable: thread,
      builder: (context, _) {
        final photos = <Message>[];
        final links = <(Message, String)>[];
        for (final m in thread.messages.reversed) {
          if (m.deleted) continue;
          if (m.isFile && (FileRef.parse(m.body)?.isImage ?? false)) photos.add(m);
          if (m.kind == 'text') {
            for (final u in _url.allMatches(m.body)) {
              links.add((m, u.group(0)!));
            }
          }
        }
        final files = widget.files.where((f) => !f.isImage).toList();
        Widget body;
        switch (_tab) {
          case 0:
            body = photos.isEmpty
                ? Padding(padding: const EdgeInsets.all(12), child: Text(s('no_media'), style: context.tt.bodySmall))
                : GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 3,
                    crossAxisSpacing: 3,
                    children: [
                      for (final m in photos.take(12))
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LayoutBuilder(builder: (context, c) {
                            final ref = FileRef.parse(m.body)!;
                            return ImageBubble(
                              message: m,
                              ref: ref,
                              width: c.maxWidth,
                              height: c.maxWidth,
                              onOpen: () => openMediaViewer(context, conv: widget.conv, initialId: m.id),
                            );
                          }),
                        ),
                    ],
                  );
          case 1:
            body = files.isEmpty
                ? Padding(padding: const EdgeInsets.all(12), child: Text(s('no_shared_files'), style: context.tt.bodySmall))
                : Column(children: [
                    for (final f in files.take(8))
                      Builder(builder: (context) {
                        final (icon, color) = fileKind(f.name, '');
                        return ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                          leading: Icon(icon, color: color),
                          title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(s.bytes(f.size)),
                          onTap: f.state == FileState.done && f.path.isNotEmpty ? () => openFile(context, f.path) : null,
                        );
                      }),
                  ]);
          default:
            body = links.isEmpty
                ? Padding(padding: const EdgeInsets.all(12), child: Text(s('no_links'), style: context.tt.bodySmall))
                : Column(children: [
                    for (final l in links.take(8))
                      ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                        leading: const Icon(AppIcons.link, color: LC.accent),
                        title: Text(Uri.tryParse(l.$2)?.host ?? l.$2, maxLines: 1),
                        subtitle: Text(l.$2, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => openLink(context, l.$2),
                      ),
                  ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 0, label: Text('${s('media')} ${photos.length}')),
              ButtonSegment(value: 1, label: Text('${s('files')} ${files.length}')),
              ButtonSegment(value: 2, label: Text('${s('links')} ${links.length}')),
            ],
            selected: {_tab},
            onSelectionChanged: (v) => setState(() => _tab = v.first),
          ),
          const SizedBox(height: 8),
          AnimatedSize(duration: Motion.normal, curve: Motion.curve, child: body),
        ]);
      },
    );
  }
}

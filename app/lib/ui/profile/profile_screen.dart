import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../chats/chat_info.dart' show MediaSection;
import '../flows.dart';
import '../friends/safety_number.dart';
import '../settings/blocked_screen.dart';
import '../settings/profile_editor.dart';
import '../chats/delete_dialogs.dart';
import '../bots/botfather.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/peer_avatar.dart';

Future<void> openProfile(BuildContext context, String peer) {
  final page = ProfileScreen(peer: peer);
  if (isDesktop(context)) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(clipBehavior: Clip.antiAlias, child: SizedBox(width: 520, height: 640, child: page)),
    );
  }
  return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => Scaffold(body: page)));
}

/// Own or contact profile: cover photo, overlapping avatar, name, bio,
/// status and quick actions.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key, required this.peer});
  final String peer;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final me = context.select<SessionStore, String?>((x) => x.me?.peer);
    final mine = peer == me;
    final session = context.watch<SessionStore>();
    final contact = context.select<ContactsStore, Contact?>((c) => c[peer]);
    context.watch<AvatarStore>();
    final Uint8List? cover = mine ? session.coverBytes : context.read<AvatarStore>().cover(peer);
    final name = mine ? (session.me?.name ?? '') : (contact?.displayName ?? '');
    final bio = mine ? session.profile.bio : (contact?.bio ?? '');
    final shortId = mine ? (session.me?.shortId ?? '') : (contact?.shortId ?? '');
    final status = mine ? statusLabel(s, session.profile.status) : (contact?.online ?? false ? statusLabel(s, contact!.presenceKey == 'offline' ? 'online' : contact.presenceKey) : s.lastSeen(contact?.lastSeen ?? 0, DateTime.now()));
    final dpr = MediaQuery.devicePixelRatioOf(context);
    const coverH = 200.0;
    const avatar = 112.0;

    final conv = 'd:$peer';
    final actions = mine
        ? [
            _Action(icon: AppIcons.edit, label: s('edit_profile'), primary: true, onTap: () => showProfileEditor(context)),
            _Action(icon: AppIcons.share, label: s('share_profile'), onTap: () => showShareProfile(context, peer, shortId, name)),
            _Action(icon: AppIcons.copy, label: s('copy_id'), onTap: () => copyText(context, shortId)),
          ]
        : [
            _Action(icon: AppIcons.chat, label: s('message'), primary: true, onTap: () => Flows.openChat(context, peer, pop: true)),
            _Action(icon: AppIcons.call, label: s('call'), onTap: () => Flows.call(context, conv)),
            _Action(icon: AppIcons.video, label: s('video'), onTap: () => Flows.call(context, conv, video: true)),
            _Action(icon: AppIcons.remote, label: s('ctl_control'), onTap: () => Flows.requestControl(context, peer)),
            _Action(icon: AppIcons.attach, label: s('ctl_file'), onTap: () => Flows.sendFile(context, conv)),
            _Action(icon: AppIcons.location, label: s('location'), onTap: () => Flows.shareLocation(context, conv)),
            _Action(icon: AppIcons.screenShare, label: s('ctl_share'), onTap: () => Flows.shareScreen(context, conv)),
          ];

    return Material(
      color: context.lc.bg,
      child: ListView(padding: EdgeInsets.zero, children: [
        SizedBox(
          height: coverH + avatar / 2 + 8,
          child: Stack(clipBehavior: Clip.none, children: [
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: coverH,
              child: cover != null
                  ? Image.memory(cover, fit: BoxFit.cover, cacheWidth: (520 * dpr).round(), gaplessPlayback: true)
                  : const DecoratedBox(decoration: BoxDecoration(gradient: LC.gradient)),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 64,
              child: const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black45, Colors.transparent]))),
            ),
            Positioned(
              left: 8,
              top: 8,
              child: IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(AppIcons.back, color: Colors.white),
                tooltip: s('back'),
              ),
            ),
            if (mine)
              Positioned(
                right: 12,
                top: coverH - 48,
                child: FilledButton.tonalIcon(
                  onPressed: () => pickCover(context),
                  style: FilledButton.styleFrom(backgroundColor: Colors.black45, foregroundColor: Colors.white, minimumSize: const Size(0, 36)),
                  icon: const Icon(AppIcons.camera, size: 18),
                  label: Text(s('change_cover')),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              top: coverH - avatar / 2,
              child: Center(
                child: Stack(children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(color: context.lc.bg, shape: BoxShape.circle),
                    child: PeerAvatar(peer: peer, size: avatar, fallbackName: name),
                  ),
                  if (mine)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Material(
                        color: LC.primary,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => pickAvatar(context),
                          child: const Padding(padding: EdgeInsets.all(8), child: Icon(AppIcons.camera, size: 18, color: Colors.white)),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          ]),
        ),
        Center(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(name, style: context.tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            if (contact?.verified ?? false) ...[const SizedBox(width: 6), const Icon(AppIcons.verifiedFill, color: LC.accent)],
            if (contact?.isBot ?? false) const BotBadge(),
          ]),
        ),
        const SizedBox(height: 4),
        Center(child: Text(status, style: context.tt.bodySmall)),
        if ((mine ? session.me?.handle : contact?.handle) case final h? when h.isNotEmpty)
          Center(
            child: InkWell(
              onTap: () => copyText(context, h),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 6),
                child: Text(h, style: context.tt.bodySmall?.copyWith(color: LC.accent, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        if (contact?.bot case final b?)
          Center(
            child: Text(
              b.owner != null ? s('bot_of', {'name': context.read<ContactsStore>().nameOf(b.owner!)}) : s('bot_account'),
              style: context.tt.bodySmall,
            ),
          ),
        if (bio.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 10, 32, 0),
            child: Text(bio, textAlign: TextAlign.center, style: context.tt.bodyMedium),
          ),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(alignment: WrapAlignment.center, spacing: 2, runSpacing: 4, children: [for (final a in actions) SizedBox(width: 74, child: a)]),
        ),
        const SizedBox(height: 18),
        if (!mine && contact != null) ...[
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _CommonGroups(peer: peer)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: MediaSection(conv: conv, files: context.select<FilesStore, List<FileItem>>((f) => f.sorted.where((x) => x.conv == conv).toList())),
          ),
          const SizedBox(height: 16),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(children: [
              ListTile(
                leading: const RowIcon(AppIcons.channel),
                title: Text('ID $shortId'),
                trailing: const Icon(AppIcons.copy, size: 18),
                onTap: () => copyText(context, shortId),
              ),
              if (!mine && contact != null) ...[
                ListTile(
                  leading: const RowIcon(AppIcons.edit),
                  title: Text(s('set_nickname')),
                  subtitle: contact.alias != null && contact.alias!.isNotEmpty ? Text(contact.alias!) : null,
                  onTap: () async {
                    final store = context.read<ContactsStore>();
                    final v = await promptText(context, title: s('set_nickname'), initial: contact.alias ?? contact.name, action: s('save'));
                    if (v != null) store.rename(peer, v);
                  },
                ),
                Builder(builder: (context) {
                  final muted = context.select<ChatStore, bool>((c) => c.convs[conv]?.muted ?? false);
                  return SwitchListTile(
                    secondary: Icon(muted ? AppIcons.mute : AppIcons.bell),
                    title: Text(s('mute')),
                    value: muted,
                    onChanged: (v) => v ? pickMute(context, conv) : context.read<ChatStore>().muteUntil(conv, 0),
                  );
                }),
                ListTile(
                  leading: Icon(contact.verified ? AppIcons.shieldCheck : AppIcons.shield, color: contact.verified ? LC.success : null),
                  title: Text(contact.verified ? s('verified') : s('verify_safety')),
                  onTap: () => openSafetyNumber(context, contact),
                ),
                ListTile(
                  leading: const RowIcon(AppIcons.share),
                  title: Text(s('share_contact')),
                  onTap: () => showShareProfile(context, peer, shortId, name),
                ),
                if (contact.status == ContactStatus.blocked)
                  ListTile(
                    leading: const Icon(AppIcons.checkCircle, color: LC.success),
                    title: Text(s('unblock'), style: const TextStyle(color: LC.success)),
                    onTap: () => unblockContact(context, contact),
                  )
                else
                  ListTile(
                    leading: const Icon(AppIcons.block, color: LC.danger),
                    title: Text(s('block'), style: const TextStyle(color: LC.danger)),
                    onTap: () async {
                      final store = context.read<ContactsStore>();
                      if (await confirm(context, title: s('block_title', {'name': name}), body: s('block_body'), action: s('block'), danger: true)) {
                        store.block(peer);
                      }
                    },
                  ),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 24),
      ]),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap, this.primary = false});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(children: [
            if (primary)
              SizedBox.square(
                dimension: IconTileSize.lg.box,
                child: DecoratedBox(
                  decoration: const BoxDecoration(gradient: LC.gradient, shape: BoxShape.circle),
                  child: Center(child: SizedBox.square(dimension: IconTileSize.lg.glyph, child: Icon(AppIcons.fill(icon), color: Colors.white, size: IconTileSize.lg.glyph))),
                ),
              )
            else
              IconTile(icon, size: IconTileSize.lg, circle: true),
            const SizedBox(height: 6),
            // Same size for every label; a long one ("Chỉnh sửa hồ sơ") wraps to a second line
            // instead of shrinking next to its neighbours.
            Text(label, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall?.copyWith(color: context.lc.text, height: 1.2)),
          ]),
        ),
      );
}


/// Groups/communities we share with this person (from group_info).
class _CommonGroups extends StatefulWidget {
  const _CommonGroups({required this.peer});
  final String peer;
  @override
  State<_CommonGroups> createState() => _CommonGroupsState();
}

class _CommonGroupsState extends State<_CommonGroups> {
  List<GroupInfo>? _groups;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<LumoraApi>();
    final convs = context.read<ChatStore>().convs.values.where((c) => c.isGroup && !c.id.contains('#')).take(30).toList();
    final out = <GroupInfo>[];
    for (final c in convs) {
      try {
        final g = await api.groupInfo(c.gid!);
        if (g.members.any((m) => m.peer == widget.peer)) out.add(g);
      } catch (_) {}
    }
    if (mounted) setState(() => _groups = out);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final g = _groups;
    if (g == null || g.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(s('common_groups', {'n': g.length}), padding: const EdgeInsets.fromLTRB(4, 0, 4, 8)),
      for (final x in g)
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: GroupAvatar(gid: x.gid, name: x.name, size: 36),
          title: Text(x.name),
          subtitle: Text(s('n_members', {'n': x.members.length})),
          onTap: () {
            Navigator.of(context).maybePop();
            Flows.openConv(context, 'g:${x.gid}');
          },
        ),
      const SizedBox(height: 12),
    ]);
  }
}

/// "Share my profile": https add link + QR, with the 9-digit ID to type by hand.
Future<void> showShareProfile(BuildContext context, String peer, String shortId, String name) {
  final s = S.read(context);
  final link = Flows.addLink(peer, shortId: shortId);
  return showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(s('share_profile_of', {'name': name})),
      content: SizedBox(
        width: 340,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(Radii.lg)),
            child: QrImageView(key: ValueKey('qr:$link'), data: link, size: 200, padding: EdgeInsets.zero),
          ),
          const SizedBox(height: 12),
          Text(shortId, style: c.tt.titleLarge?.copyWith(letterSpacing: 2, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          SelectableText(link, maxLines: 2, style: c.tt.bodySmall),
        ]),
      ),
      actions: [
        TextButton.icon(onPressed: () => copyText(c, link), icon: const Icon(AppIcons.link, size: 16), label: Text(s('copy_link'))),
        FilledButton(onPressed: () => Navigator.pop(c), child: Text(s('done'))),
      ],
    ),
  );
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../chats/chat_info.dart';
import '../chats/delete_dialogs.dart';
import '../chats/report_dialogs.dart';
import '../theme.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/common.dart';
import '../profile/profile_screen.dart';
import 'create_group.dart';
import 'group_cover.dart';
import 'invite.dart';
import 'group_rights.dart';
import 'group_membership.dart';
import '../calls/group_call.dart' show startCallIn;
import 'community/community_members.dart' show timeoutMember, canModerate;
import 'community/community_common.dart' show timeLabel, memberRoleLabel;
import '../widgets/image_crop.dart';
import '../chats/wallpaper.dart';
import '../settings/storage_screen.dart';

class GroupInfoView extends StatefulWidget {
  const GroupInfoView({super.key, required this.gid, this.embedded = false, this.inSettings = false});
  final String gid;
  final bool embedded;

  /// The Overview of the community settings: no header of its own and no
  /// channel list (the Channels section has it).
  final bool inSettings;

  @override
  State<GroupInfoView> createState() => _GroupInfoViewState();
}

class _GroupInfoViewState extends State<GroupInfoView> {
  GroupInfo? _info;
  String? _error;

  String get conv => 'g:${widget.gid}';
  final _mediaKey = GlobalKey();
  final _membersKey = GlobalKey();

  void _scrollTo(GlobalKey k) {
    final c = k.currentContext;
    if (c != null) Scrollable.ensureVisible(c, duration: Motion.normal, curve: Motion.curve);
  }

  StreamSubscription<Map<String, dynamic>>? _events;

  @override
  void initState() {
    super.initState();
    _load();
    // Changes made elsewhere (another admin, my other device, being removed)
    // show at once: no admin buttons left after a kick, a rename, new members…
    _events = context.read<LumoraApi>().events.listen((raw) {
      final e = ApiEvent.parse(raw);
      if ((e.name == 'group' || e.name == 'group_removed') && e.data['gid']?.toString() == widget.gid) {
        if (e.name == 'group_removed' && e.data['dissolved'] == true) {
          _close(); // deleted by its owner: nothing left to show
        } else {
          _scheduleLoad();
        }
      }
    });
  }

  bool _closing = false;

  /// The group is gone (deleted): close this pane / page.
  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    _reload?.cancel();
    if (widget.embedded) {
      context.read<NavStore>().toggleInfo(false);
      return;
    }
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(context);
    navigator.popUntil((r) => r == route || r.isFirst);
    if (route.isCurrent && !route.isFirst) navigator.pop();
  }

  Timer? _reload;
  void _scheduleLoad() {
    _reload?.cancel();
    _reload = Timer(const Duration(milliseconds: 150), () {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    _reload?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final g = await context.read<LumoraApi>().groupInfo(widget.gid);
      if (mounted) setState(() => _info = g);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(S.read(context), e));
    }
  }

  Future<void> _run(Future<void> Function(LumoraApi api) f) async {
    try {
      await f(context.read<LumoraApi>());
      await _load();
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  Future<void> _pickGroupAvatar(GroupInfo g) async {
    final avatars = context.read<AvatarStore>();
    final bytes = await pickAndCropImage(context, CropSpec.groupAvatar);
    if (bytes == null) return;
    await _run((api) => api.groupMeta(g.gid, avatar: base64Encode(bytes)));
    avatars.setGroup(g.gid, bytes);
  }

  Future<void> _addChannel(GroupInfo g) async {
    final s = S.read(context);
    var voice = false;
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(s('add_channel')),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: false, icon: const Icon(AppIcons.channel, size: 18), label: Text(s('text_channel'))),
                  ButtonSegment(value: true, icon: const Icon(AppIcons.speaker, size: 18), label: Text(s('voice_channel'))),
                ],
                selected: {voice},
                onSelectionChanged: (v) => set(() => voice = v.first),
              ),
              const SizedBox(height: 12),
              TextField(controller: name, autofocus: true, decoration: InputDecoration(labelText: s('channel_name'))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(s('add'))),
          ],
        ),
      ),
    );
    final n = name.text.trim().toLowerCase().replaceAll(' ', '-');
    name.dispose();
    if (ok == true && n.isNotEmpty) await _run((api) => api.groupChannel(g.gid, n, voice: voice));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final g = _info;
    final convo = context.select<ChatStore, Conversation?>((x) => x.convs[conv]);
    final me = context.select<SessionStore, String>((x) => x.me?.peer ?? '');
    final contacts = context.watch<ContactsStore>();
    final header = PaneHeader(
      title: Text(s('group_info')),
      onBack: widget.embedded ? null : () => Navigator.of(context).maybePop(),
      actions: [
        if (widget.embedded)
          ToolButton(icon: AppIcons.close, tooltip: s('close'), onPressed: () => context.read<NavStore>().toggleInfo(false)),
      ],
    );
    if (g == null) {
      return Column(children: [
        if (!widget.inSettings) header,
        Expanded(
          child: _error != null
              ? EmptyState(icon: AppIcons.error, title: s('load_failed'), subtitle: _error)
              : const Center(child: CircularProgressIndicator()),
        ),
      ]);
    }
    final roleOrder = {'owner': 0, 'admin': 1, 'member': 2};
    final members = [...g.members]..sort((a, b) => (roleOrder[a.role] ?? 3).compareTo(roleOrder[b.role] ?? 3));
    return Column(children: [
      if (!widget.inSettings) header,
      Expanded(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          _CoverHeader(
            info: g,
            ring: widget.embedded ? context.lc.surface : context.lc.bg,
            onPickAvatar: () => _pickGroupAvatar(g),
            onPickCover: () async {
              if (await pickGroupCover(context, g.gid)) await _load();
            },
            onRemoveCover: () async {
              if (await removeGroupCover(context, g.gid, g.name)) await _load();
            },
          ),
          const SizedBox(height: 10),
          Center(child: Text(g.name, style: context.tt.titleLarge, textAlign: TextAlign.center)),
          const SizedBox(height: 4),
          Center(child: Text(s('n_members', {'n': g.members.length}), style: context.tt.bodySmall)),
          if (g.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Center(child: Text(g.description, textAlign: TextAlign.center, style: context.tt.bodyMedium?.copyWith(color: context.lc.muted))),
          ],
          const SizedBox(height: 8),
          Center(child: Pill(s('group_e2e'), color: LC.success, icon: AppIcons.lock)),
          const SizedBox(height: 16),
          // Group hub: Chat · Voice · Invite · Media · Members.
          Row(children: [
            for (final (icon, label, onTap) in <(IconData, String, VoidCallback)>[
              (AppIcons.chat, s('chat'), () {
                context.read<NavStore>().toggleInfo(false);
                if (!widget.embedded) Navigator.of(context).maybePop();
              }),
              (AppIcons.call, s('ctl_voice'), () => startCallIn(context, conv)),
              if (g.can(Perm.invite)) (AppIcons.addFriend, s('invite'), () => showInvite(context, gid: g.gid, name: g.name)),
              (AppIcons.gallery, s('media'), () => _scrollTo(_mediaKey)),
              (AppIcons.friends, s('members_short'), () => _scrollTo(_membersKey)),
            ])
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(Radii.md),
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(children: [
                      IconTile(icon, circle: true),
                      const SizedBox(height: 4),
                      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall?.copyWith(color: context.lc.text)),
                    ]),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 8),
          KeyedSubtree(key: _mediaKey, child: MediaSection(conv: conv, files: context.select<FilesStore, List<FileItem>>((f) => f.sorted.where((x) => x.conv == conv).toList()))),
          const SizedBox(height: 16),
          LCard(
            padding: const EdgeInsets.all(4),
            child: Column(children: [
              if (g.can(Perm.manageCommunity))
                ListTile(
                  leading: const RowIcon(AppIcons.notes),
                  title: Text(s('edit_description')),
                  onTap: () async {
                    final v = await promptText(context, title: s('edit_description'), initial: g.description, action: s('save'));
                    if (v != null) _run((api) => api.groupMeta(g.gid, description: v));
                  },
                ),
              if (g.can(Perm.manageCommunity))
                ListTile(
                  leading: const RowIcon(AppIcons.edit),
                  title: Text(s('rename_group')),
                  onTap: () async {
                    final v = await promptText(context, title: s('rename_group'), initial: g.name, action: s('save'));
                    if (v != null && v.isNotEmpty) _run((api) => api.groupRename(g.gid, v));
                  },
                ),
              if (g.can(Perm.invite))
              ListTile(
                key: const ValueKey('group_invite_link'),
                leading: const RowIcon(AppIcons.link),
                title: Text(s('invite_link')),
                onTap: () => showInvite(context, gid: g.gid, name: g.name),
              ),
              RetentionTile(conv: conv),
              ClearMediaTile(conv: conv, title: g.name),
              ListTile(
                leading: const RowIcon(AppIcons.wallpaper),
                title: Text(s('wallpaper')),
                trailing: const Icon(AppIcons.chevronRight, size: 18),
                onTap: () => showWallpaperPicker(context, conv),
              ),
              ListTile(
                leading: Icon((convo?.muted ?? false) ? AppIcons.mute : AppIcons.bell),
                title: Text((convo?.muted ?? false) ? s('unmute') : s('mute')),
                onTap: () => pickMute(context, conv),
              ),
            ]),
          ),
          if (g.canManage) _AdminSection(info: g, run: _run),
          if (!widget.inSettings && (g.community || g.channels.isNotEmpty)) ...[
            SectionLabel(
              s('channels'),
              padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
              trailing: g.can(Perm.manageChannels)
                  ? TextButton.icon(
                      onPressed: () => _addChannel(g),
                      icon: const Icon(AppIcons.add, size: 18),
                      label: Text(s('add_channel')),
                    )
                  : null,
            ),
            for (final ch in g.channels)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: Icon(ch.voice ? AppIcons.speaker : AppIcons.channel, size: 20),
                title: Text(ch.name),
                trailing: g.can(Perm.manageChannels)
                    ? IconButton(
                        tooltip: s('remove'),
                        icon: const Icon(AppIcons.delete, size: 18),
                        onPressed: () => _run((api) => api.groupChannel(g.gid, ch.name, voice: ch.voice, remove: true)),
                      )
                    : null,
              ),
          ],
          if (g.can(Perm.invite) && g.joinRequests.isNotEmpty) JoinRequestsSection(info: g, run: _run),
          SectionLabel(
            key: _membersKey,
            s('members_count', {'n': g.members.length}),
            padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
            trailing: g.can(Perm.invite)
                ? TextButton.icon(
                    onPressed: () async {
                      final picked = await pickMembers(context, exclude: g.members.map((m) => m.peer).toSet());
                      if (picked == null) return;
                      for (final p in picked) {
                        await _run((api) => api.groupAdd(g.gid, p));
                      }
                    },
                    key: const ValueKey('group_add_members'),
                    icon: const Icon(AppIcons.addFriend, size: 18),
                    label: Text(s('add')),
                  )
                : null,
          ),
          for (final m in members)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: PeerAvatar(peer: m.peer, fallbackName: m.name, size: 38),
              onTap: m.peer == me ? null : () => openProfile(context, m.peer),
              title: Text(m.peer == me ? '${m.name} (${s('you')})' : (contacts[m.peer]?.displayName ?? m.name),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                  m.timedOut() ? '${memberRoleLabel(s, m.role, community: g.community)} · ${s('cm_timed_out_until_short', {'time': timeLabel(m.timeoutUntil)})}' : memberRoleLabel(s, m.role, community: g.community),
                  style: context.tt.bodySmall?.copyWith(color: m.timedOut() ? LC.warning : null)),
              trailing: m.peer == me
                  ? (m.role == 'owner'
                      ? const Icon(AppIcons.owner, color: LC.warning, size: 20)
                      : (m.role == 'admin' ? const Icon(AppIcons.shield, color: LC.accent, size: 18) : null))
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      if (m.role == 'owner') const Icon(AppIcons.owner, color: LC.warning, size: 20),
                      if (m.role == 'admin' && !g.canManage) const Icon(AppIcons.shield, color: LC.accent, size: 18),
                      PopupMenuButton<String>(
                        key: ValueKey('group_member_more_${m.peer}'),
                        tooltip: s('more'),
                        icon: const Icon(AppIcons.moreVertical),
                        onSelected: (v) async {
                          switch (v) {
                            case 'admin':
                              if (!g.community && m.role != 'admin') {
                                await editAdminRights(context, g, m.peer, contacts[m.peer]?.displayName ?? m.name);
                                await _load();
                              } else if (!g.community) {
                                await revokeAdmin(context, g, m.peer);
                                await _load();
                              } else {
                                _run((api) => api.groupSetRole(g.gid, m.peer, m.role == 'admin' ? 'member' : 'admin'));
                              }
                            case 'rights':
                              await editAdminRights(context, g, m.peer, contacts[m.peer]?.displayName ?? m.name);
                              await _load();
                            case 'owner':
                              if (await transferOwnership(context, g, m.peer, contacts[m.peer]?.displayName ?? m.name)) await _load();
                            case 'timeout':
                              await timeoutMember(context, g, m, contacts[m.peer]?.displayName ?? m.name);
                              await _load();
                            case 'remove':
                              if (await confirm(context, title: s('remove_member'), body: s('remove_member_body', {'name': m.name}), action: s('remove'), danger: true)) {
                                _run((api) => api.groupRemove(g.gid, m.peer));
                              }
                            case 'ban':
                              if (await confirm(context, title: s('ban_member'), body: s('ban_member_body', {'name': m.name}), action: s('ban'), danger: true)) {
                                _run((api) => api.groupBan(g.gid, m.peer, true));
                              }
                            case 'purge':
                              if (await confirm(context, title: s('purge_member'), body: s('purge_member_body', {'name': m.name}), action: s('delete'), danger: true)) {
                                _run((api) => api.groupPurgeMember(g.gid, m.peer));
                              }
                            case 'report':
                              if (context.mounted) await reportGroupContent(context, gid: g.gid, peer: m.peer, name: contacts[m.peer]?.displayName ?? m.name);
                          }
                        },
                        itemBuilder: (_) => [
                          // making / unmaking admins and their `admin:<peer>` rights: owner only (core)
                          if (g.myRole == 'owner' && m.role != 'owner') ...[
                            if (!g.community && m.role == 'admin') PopupMenuItem(value: 'rights', child: Text(s('gr_admin_rights'))),
                            PopupMenuItem(value: 'admin', child: Text(m.role == 'admin' ? s('revoke_admin') : s('make_admin'))),
                          ],
                          if (g.can(Perm.timeout) && canModerate(g, m, me))
                            PopupMenuItem(value: 'timeout', child: Text(m.timedOut() ? s('cm_timeout_lift') : s('cm_timeout'))),
                          if (canModerate(g, m, me)) ...[
                            if (g.can(Perm.kick)) PopupMenuItem(value: 'remove', child: Text(s('remove_member'), style: const TextStyle(color: LC.danger))),
                            if (g.can(Perm.ban)) PopupMenuItem(value: 'ban', child: Text(s('ban_member'), style: const TextStyle(color: LC.danger))),
                            if (g.can(Perm.manageMessages)) PopupMenuItem(value: 'purge', child: Text(s('purge_member'), style: const TextStyle(color: LC.danger))),
                          ],
                          if (g.myRole == 'owner' && m.role != 'owner' && !g.bots.any((b) => b.$1 == m.peer))
                            PopupMenuItem(key: ValueKey('group_member_owner_${m.peer}'), value: 'owner', child: Text(s('go_transfer_owner'))),
                          if (g.myRole != 'none') PopupMenuItem(value: 'report', child: Text(s('report_member'))),
                        ],
                      ),
                    ]),
            ),
          const SizedBox(height: 16),
          if (g.myRole == 'none')
            Center(child: Text(s('group_removed_banner'), style: context.tt.bodySmall?.copyWith(color: context.lc.muted)))
          else
          LCard(
            padding: const EdgeInsets.all(4),
            child: ListTile(
              key: const ValueKey('leave_group'),
              leading: const Icon(AppIcons.signOut, color: LC.danger),
              title: Text(s('leave_group'), style: const TextStyle(color: LC.danger)),
              onTap: () async {
                final chat = context.read<ChatStore>();
                final nav = context.read<NavStore>();
                // the owner first hands the group over (pick the new owner)
                if (!await leaveGroupFlow(context, g.gid, title: s('leave_group'), body: s('leave_group_body'), info: g)) return;
                // the core deletes the chat (`conversation_removed`); no reload —
                // a reload racing that would only bring it back for a moment
                chat.onGroupRemoved(conv, left: true);
                nav.openConv(null);
                nav.toggleInfo(false);
                if (!widget.embedded && context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
          ),
          if (g.myRole == 'owner') ...[
            const SizedBox(height: 8),
            LCard(
              padding: const EdgeInsets.all(4),
              child: ListTile(
                key: const ValueKey('dissolve_group'),
                leading: const Icon(AppIcons.delete, color: LC.danger),
                title: Text(s(g.community ? 'delete_space' : 'delete_group_all'), style: const TextStyle(color: LC.danger, fontWeight: FontWeight.w600)),
                onTap: () async {
                  if (!await dissolveGroup(context, gid: g.gid, name: g.name, community: g.community)) return;
                  if (!context.mounted) return;
                  _closing = true;
                  if (!widget.embedded) Navigator.of(context).popUntil((r) => r.isFirst);
                },
              ),
            ),
          ],
          const SizedBox(height: 8),
          LCard(
            padding: const EdgeInsets.all(4),
            child: ListTile(
              leading: const Icon(AppIcons.report, color: LC.danger),
              title: Text(s('report_group'), style: const TextStyle(color: LC.danger)),
              onTap: () async {
                final nav = context.read<NavStore>();
                if (!await reportGroup(context, gid: g.gid, name: g.name)) return;
                nav.toggleInfo(false);
                if (!widget.embedded && context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
          ),
        ]),
      ),
    ]);
  }
}


/// The cover banner with the group picture overlapping its bottom edge, and
/// change / remove buttons for those allowed (`manage_community`).
class _CoverHeader extends StatelessWidget {
  const _CoverHeader({required this.info, required this.ring, required this.onPickAvatar, required this.onPickCover, required this.onRemoveCover});
  final GroupInfo info;

  /// The page colour around the avatar (it cuts into the banner).
  final Color ring;
  final VoidCallback onPickAvatar;
  final VoidCallback onPickCover;
  final VoidCallback onRemoveCover;

  static const coverH = 136.0;
  static const avatar = 88.0;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final g = info;
    // owner, admins, and whoever else holds manage_community ("change group info")
    final canCover = g.myRole != 'none' && g.can(Perm.manageCommunity);
    return SizedBox(
      height: coverH + avatar / 2 + 4,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: coverH,
          child: ClipRRect(
            key: const ValueKey('group_cover'),
            borderRadius: BorderRadius.circular(Radii.lg),
            child: Stack(fit: StackFit.expand, children: [
              GroupCoverImage(gid: g.gid, hasCover: g.hasCover, rev: g.coverRev),
              // a light scrim keeps the buttons and the avatar ring readable
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x33000000), Color(0x00000000), Color(0x40000000)], stops: [0, 0.45, 1]),
                ),
              ),
            ]),
          ),
        ),
        if (canCover)
          Positioned(
            right: 10,
            top: 10,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _GlassButton(
                key: const ValueKey('cover_change'),
                icon: AppIcons.image,
                label: g.hasCover ? s('change_cover') : s('add_cover'),
                onTap: onPickCover,
              ),
              if (g.hasCover) ...[
                const SizedBox(width: 6),
                _GlassButton(key: const ValueKey('cover_remove'), icon: AppIcons.delete, tooltip: s('remove_cover'), onTap: onRemoveCover),
              ],
            ]),
          ),
        Positioned(
          left: 0,
          right: 0,
          top: coverH - avatar / 2,
          child: Center(
            child: Stack(clipBehavior: Clip.none, children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: ring,
                  shape: BoxShape.circle,
                  boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 14, offset: Offset(0, 4))],
                ),
                child: GroupAvatar(gid: g.gid, name: g.name, size: avatar),
              ),
              if (g.can(Perm.manageCommunity))
                Positioned(
                  right: 2,
                  bottom: 2,
                  child: Material(
                    color: LC.primary,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: onPickAvatar,
                      child: const Padding(padding: EdgeInsets.all(7), child: Icon(AppIcons.camera, size: 16, color: Colors.white)),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// A small frosted button on top of a cover picture.
class _GlassButton extends StatelessWidget {
  const _GlassButton({super.key, required this.icon, required this.onTap, this.label, this.tooltip});
  final IconData icon;
  final String? label;
  final String? tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final child = Material(
      color: Colors.black.withValues(alpha: 0.42),
      shape: StadiumBorder(side: BorderSide(color: Colors.white.withValues(alpha: 0.18))),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: label == null ? 8 : 12, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: Colors.white),
            if (label != null) ...[
              const SizedBox(width: 6),
              Text(label!, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
            ],
          ]),
        ),
      ),
    );
    return tooltip == null ? child : Tooltip(message: tooltip!, child: child);
  }
}

const _slowModes = [0, 10, 30, 60, 300, 900, 3600];

/// Admin-only settings: visibility, slow mode, posting, bots, bans, history.
class _AdminSection extends StatelessWidget {
  const _AdminSection({required this.info, required this.run});
  final GroupInfo info;
  final Future<void> Function(Future<void> Function(LumoraApi api) f) run;

  String _slowLabel(S s, int v) => v == 0 ? s('off') : (v < 60 ? s('ttl_sec', {'n': v}) : (v < 3600 ? s('ttl_min', {'n': v ~/ 60}) : s('ttl_hour', {'n': v ~/ 3600})));

  Future<void> _visibility(BuildContext context) async {
    final s = S.read(context);
    var public = info.isPublic;
    final handle = TextEditingController(text: info.handle?.replaceAll('@', '').split('·').first ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(s('group_type')),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: false, icon: const Icon(AppIcons.lock, size: 16), label: Text(s('group_private'))),
                  ButtonSegment(value: true, icon: const Icon(AppIcons.globe, size: 16), label: Text(s('group_public'))),
                ],
                selected: {public},
                onSelectionChanged: (v) => set(() => public = v.first),
              ),
              const SizedBox(height: 10),
              Text(public ? s('group_public_hint') : s('group_private_hint'), style: c.tt.bodySmall),
              if (public) ...[
                const SizedBox(height: 12),
                TextField(controller: handle, decoration: InputDecoration(labelText: s('group_handle'), prefixText: '@')),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(s('save'))),
          ],
        ),
      ),
    );
    final h = handle.text.trim();
    handle.dispose();
    if (ok == true) await run((api) => api.groupVisibility(info.gid, public: public, handle: public ? h : ''));
  }

  Future<void> _addBot(BuildContext context) async {
    if (await showAddBotDialog(context, info.gid)) await run((api) async {});
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final contacts = context.watch<ContactsStore>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(s('group_admin'), padding: const EdgeInsets.fromLTRB(4, 20, 4, 6)),
      LCard(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: [
          if (!info.community && info.can(Perm.manageRoles))
            ListTile(
              key: const ValueKey('gr_member_perms'),
              leading: const RowIcon(AppIcons.people),
              title: Text(s('gr_member_perms')),
              subtitle: Text(s('gr_member_perms_hint')),
              trailing: const Icon(AppIcons.chevronRight),
              onTap: () async {
                await editMemberPermissions(context, info);
                await run((api) async {});
              },
            ),
          ListTile(
            leading: Icon(info.isPublic ? AppIcons.globe : AppIcons.lock),
            title: Text(s('group_type')),
            subtitle: Text(info.isPublic ? '${s('group_public')} · ${info.handle}' : s('group_private')),
            trailing: info.isPublic ? IconButton(tooltip: S.of(context)('copy'), onPressed: () => copyText(context, info.handle!), icon: const Icon(AppIcons.copy, size: 16)) : const Icon(AppIcons.chevronRight),
            onTap: () => _visibility(context),
          ),
          ListTile(
            leading: const RowIcon(AppIcons.timer),
            title: Text(s('slow_mode')),
            subtitle: Text(s('slow_mode_hint')),
            trailing: DropdownButton<int>(
              value: info.slowModeS < 0 ? 0 : info.slowModeS,
              underline: const SizedBox.shrink(),
              borderRadius: BorderRadius.circular(Radii.md),
              // Values set elsewhere (e.g. the flood banner's suggestion) are listed too.
              items: [for (final v in ({..._slowModes, if (info.slowModeS > 0) info.slowModeS}.toList()..sort())) DropdownMenuItem(value: v, child: Text(_slowLabel(s, v)))],
              onChanged: (v) => run((api) => api.groupSettings(info.gid, slowModeS: v ?? 0)),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(AppIcons.announce),
            title: Text(s('admins_only')),
            subtitle: Text(s('admins_only_hint')),
            value: info.adminsOnly,
            onChanged: (v) => run((api) => api.groupSettings(info.gid, adminsOnly: v)),
          ),
          if (info.can(Perm.manageCommunity)) ApproveJoinsSwitch(info: info, run: run),
          if (!info.rulesV2 && (info.myRole == 'owner' || info.myRole == 'admin')) RulesUpgradeTile(info: info, run: run),
        ]),
      ),
      SectionLabel(
        s('bots_in_group', {'n': info.bots.length}),
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
        trailing: TextButton.icon(onPressed: () => _addBot(context), icon: const Icon(AppIcons.bot, size: 16), label: Text(s('add_bot'))),
      ),
      for (final b in info.bots)
        SwitchListTile(
          secondary: Avatar(name: contacts.nameOf(b.$1), seed: b.$1, size: 34),
          title: Text(contacts.nameOf(b.$1)),
          subtitle: Text(b.$2 ? s('bot_reads_all') : s('bot_reads_commands')),
          value: b.$2,
          onChanged: (v) => run((api) => api.groupBotPolicy(info.gid, b.$1, v)),
        ),
      if (info.banned.isNotEmpty) ...[
        SectionLabel(s('banned_members', {'n': info.banned.length}), padding: const EdgeInsets.fromLTRB(4, 16, 4, 6)),
        for (final p in info.banned)
          ListTile(
            leading: Avatar(name: contacts.nameOf(p), seed: p, size: 34),
            title: Text(contacts.nameOf(p)),
            trailing: TextButton(onPressed: () => run((api) => api.groupBan(info.gid, p, false)), child: Text(s('unban'))),
          ),
      ],
      const SizedBox(height: 8),
      LCard(
        padding: const EdgeInsets.all(4),
        child: ListTile(
          leading: const Icon(AppIcons.eraser, color: LC.danger),
          title: Text(s('clear_group_history'), style: const TextStyle(color: LC.danger)),
          subtitle: Text(s('clear_group_history_hint')),
          onTap: () async {
            final chat = context.read<ChatStore>();
            if (!await confirm(context, title: s('clear_group_history'), body: s('clear_group_history_hint'), action: s('delete'), danger: true)) return;
            await run((api) => api.groupClearHistory(info.gid));
            chat.clearHistory('g:${info.gid}').catchError((_) {});
          },
        ),
      ),
    ]);
  }
}

/// Add a bot to group [gid] by its username (asks whether it reads every
/// message). True when one was added.
Future<bool> showAddBotDialog(BuildContext context, String gid) async {
  final s = S.read(context);
  final target = TextEditingController();
  var readAll = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text(s('add_bot')),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(key: const ValueKey('add_bot_username'), controller: target, autofocus: true, decoration: InputDecoration(labelText: s('bot_username'), hintText: '@weather_bot')),
            const SizedBox(height: 8),
            SwitchRow(title: s('bot_read_all'), subtitle: s('bot_read_all_hint'), value: readAll, onChanged: (v) => set(() => readAll = v)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s('cancel'))),
          FilledButton(key: const ValueKey('add_bot_ok'), onPressed: () => Navigator.pop(c, true), child: Text(s('add'))),
        ],
      ),
    ),
  );
  final t = target.text.trim();
  target.dispose();
  if (ok != true || t.isEmpty || !context.mounted) return false;
  try {
    await context.read<LumoraApi>().groupAddBot(gid, t, readAll: readAll);
    return true;
  } catch (e) {
    if (context.mounted) toastError(context, e);
    return false;
  }
}

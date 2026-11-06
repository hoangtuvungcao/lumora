// Cross-feature flows: one place for "do X with this person/group" so every
// screen offers the same actions in the same order with the fewest clicks.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../core/api.dart';
import '../core/links.dart';
import '../l10n/strings.dart';
import '../state/stores.dart';
import 'chats/attachments.dart';
import 'chats/chat_view.dart';
import 'chats/rich_bubbles.dart';
import 'chats/stories.dart';
import 'devices/device_picker.dart';
import 'devices/qr_scan.dart';
import 'friends/add_friend.dart';
import 'groups/create_group.dart';
import 'groups/invite.dart';
import 'remote/remote_home.dart' show prefillRemoteId;
import 'theme.dart';
import 'widgets/common.dart';

/// Deep link received from the OS / command line, handled once the home
/// screen is up (onboarding finished, account and app lock unlocked — see
/// [canOpenPendingLink]). Put links here through [acceptIncomingLink].
final pendingDeepLink = ValueNotifier<String?>(null);

abstract final class Flows {
  /// Opens (or creates) the direct chat with [peer] in the right place.
  static String openChat(BuildContext context, String peer, {bool pop = false}) {
    final contacts = context.read<ContactsStore>();
    final chat = context.read<ChatStore>();
    final nav = context.read<NavStore>();
    final c = contacts[peer];
    final conv = c != null ? chat.ensureDirect(c) : 'd:$peer';
    if (pop) Navigator.of(context).maybePop();
    nav.openConv(conv);
    if (!isDesktop(context)) {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatView(conv: conv)));
    }
    return conv;
  }

  static void openConv(BuildContext context, String conv) {
    context.read<NavStore>().openConv(conv);
    if (!isDesktop(context)) Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatView(conv: conv)));
  }

  static Future<void> call(BuildContext context, String conv, {bool video = false}) async {
    try {
      await context.read<CallStore>().start(conv, video: video);
    } catch (e) {
      if (context.mounted) toastError(context, e);
    }
  }

  /// Escalation step: share my screen with this person (starts a video call
  /// if none is running, then enables screen sharing).
  static Future<void> shareScreen(BuildContext context, String conv) async {
    final calls = context.read<CallStore>();
    try {
      if (calls.call?.conv != conv) await calls.start(conv, video: true);
      await calls.toggle(screen: true);
    } catch (e) {
      if (context.mounted) toastError(context, e);
    }
  }

  /// "Xin điều khiển": remote_connect to a friend; the trusted-friend flow
  /// lets the host approve without a password.
  static Future<void> requestControl(BuildContext context, String peer, {bool viewOnly = false}) async {
    final s = S.read(context);
    final remote = context.read<RemoteStore>();
    final calls = context.read<CallStore>();
    final contacts = context.read<ContactsStore>();
    final nav = context.read<NavStore>();
    final name = contacts.nameOf(peer);
    if (calls.inCall) calls.setMinimized(true);
    try {
      final sent = await connectChoosingDevice(context, (device) => remote.connect(peer, '', viewOnly: viewOnly, peerName: name, device: device));
      if (sent && context.mounted) toast(context, s('control_requested', {'name': name}));
    } catch (e) {
      // Fall back to the classic ID + password form.
      prefillRemoteId(contacts[peer]?.shortId ?? '');
      nav.go(Section.remote);
      if (context.mounted) {
        toastError(context, e);
      }
    }
  }

  static Future<void> sendFile(BuildContext context, String conv) async {
    final r = await FilePicker.pickFiles();
    final paths = [for (final f in r) ?f.path];
    if (paths.isEmpty || !context.mounted) return;
    await showSendFiles(context, conv: conv, paths: paths);
  }

  static Future<void> shareLocation(BuildContext context, String conv) => showSendLocation(context, conv);

  // --------------------------------------------------------------- links

  /// Shared "add me" link (https on Lumora's site, see core/links.dart).
  static String addLink(String peer, {String? shortId}) => LumoraLink.addLink(peer, shortId: shortId);
  static String remoteLink(String shortId) => LumoraLink.remoteLink(shortId);

  static bool isDeepLink(String s) => LumoraLink.looksLikeLink(s);

  /// One handler for every Lumora link: from another app, the command line,
  /// the in-app scanner or pasted text. Nothing is sent without a tap:
  ///  * add → Add friend, filled in, waiting for "Send request"
  ///    (an existing friend → their chat);
  ///  * join → the join-group preview with its "Join" button;
  ///  * remote → Remote control with the partner ID filled in;
  ///  * a device-link code → how to use it (never acted on here).
  static Future<void> openDeepLink(BuildContext context, String link) async {
    final l = LumoraLink.find(link);
    if (l == null) {
      toast(context, S.read(context)('link_broken'));
      return;
    }
    await openLink(context, l);
  }

  static Future<void> openLink(BuildContext context, LumoraLink l) async {
    final s = S.read(context);
    switch (l.kind) {
      case LinkKind.join:
        await showJoinByLink(context, initial: l.https);
      case LinkKind.add:
        final me = context.read<SessionStore>().me;
        final myId = me?.shortId.replaceAll(RegExp(r'\D'), '');
        if (me != null && (l.peer == me.peer || (l.peer == null && l.shortId == myId))) {
          toast(context, s('link_is_you'));
          return;
        }
        final known = l.peer == null ? null : context.read<ContactsStore>()[l.peer!];
        if (known != null && known.status == ContactStatus.friend) {
          openChat(context, l.peer!);
          return;
        }
        await showAddFriend(context, initial: l);
      case LinkKind.remote:
        prefillRemoteId(formatShortId(l.shortId!));
        // the Remote screen must be the one in front (phones push chats etc.)
        Navigator.of(context).popUntil((r) => r.isFirst);
        context.read<NavStore>().go(Section.remote);
      case LinkKind.device:
        toast(context, s('qr_device_link_code'));
    }
  }

  /// Camera scan of any Lumora QR code (phones). Returns the link, or null when
  /// cancelled / not usable (the reason is already shown).
  static Future<LumoraLink?> scanQr(BuildContext context) async {
    final scan = lumoraQrScanner;
    if (scan == null) return null;
    final s = S.read(context);
    String? raw;
    try {
      raw = await scan(context);
    } catch (_) {
      if (context.mounted) toast(context, s('qr_camera_off'));
      return null;
    }
    if (raw == null || !context.mounted) return null;
    final l = LumoraLink.find(raw);
    if (l == null) {
      toast(context, s(LumoraLink.looksLikeLink(raw) ? 'link_broken' : 'qr_any_not_lumora'));
      return null;
    }
    if (l.kind == LinkKind.device) {
      toast(context, s('qr_device_link_code'));
      return null;
    }
    return l;
  }

  /// "Scan QR code" from the "+" menu: scan, then do what the code is for.
  static Future<void> scanAndOpen(BuildContext context) async {
    final l = await scanQr(context);
    if (l != null && context.mounted) await openLink(context, l);
  }

  /// A screen scanned a code meant for another screen (e.g. a group invite
  /// in Add friend): close [context]'s screen and let the home screen open it.
  static Future<void> openElsewhere(BuildContext context, LumoraLink l) async {
    // closed first: the next screen must not be the one popped
    await Navigator.of(context).maybePop();
    pendingDeepLink.value = l.https;
  }

  // ------------------------------------------------------------ create menu

  static Future<void> showCreateMenu(BuildContext context, {Offset? at}) async {
    final s = S.read(context);
    final items = <(String, IconData, String, Color)>[
      ('chat', AppIcons.newChat, s('new_chat_with'), LC.primary),
      ('group', AppIcons.people, s('new_group'), const Color(0xFF3B82F6)),
      ('community', AppIcons.community, s('new_community'), const Color(0xFF8B5CF6)),
      ('join', AppIcons.explore, s('join_by_link'), const Color(0xFF22C55E)),
      ('friend', AppIcons.addFriend, s('add_friend_qr'), const Color(0xFFF59E0B)),
      ('remote', AppIcons.remote, s('remote_connect'), const Color(0xFF0EA5E9)),
      if (lumoraQrScanner != null) ('scan', AppIcons.scan, s('scan_qr'), const Color(0xFF14B8A6)),
      ('story', AppIcons.story, s('new_story'), const Color(0xFFEC4899)),
    ];
    String? r;
    if (at != null && isDesktop(context)) {
      r = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
        items: [
          for (final it in items)
            PopupMenuItem(
              value: it.$1,
              child: Row(children: [IconTile(it.$2, color: it.$4, size: IconTileSize.sm), const SizedBox(width: 12), Text(it.$3)]),
            ),
        ],
      );
    } else {
      r = await showModalBottomSheet<String>(
        context: context,
        constraints: const BoxConstraints(maxWidth: 520),
        isScrollControlled: true,
        builder: (c) => SafeArea(
          // Scrolls on short screens (small phones, landscape) instead of overflowing.
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.85),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Text(s('create_new'), style: c.tt.titleMedium)),
                for (final it in items)
                  ListTile(
                    leading: IconTile(it.$2, color: it.$4),
                    title: Text(it.$3, maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(c, it.$1),
                  ),
              ]),
            ),
          ),
        ),
      );
    }
    if (r == null || !context.mounted) return;
    switch (r) {
      case 'chat':
        final peer = await pickFriend(context, title: s('new_chat_with'));
        if (peer != null && context.mounted) openChat(context, peer);
      case 'group':
        showCreateGroup(context);
      case 'community':
        showCreateGroup(context, community: true);
      case 'join':
        showJoinByLink(context);
      case 'friend':
        showAddFriend(context);
      case 'remote':
        context.read<NavStore>().go(Section.remote);
      case 'scan':
        scanAndOpen(context);
      case 'story':
        showStoryComposer(context);
    }
  }

  static Future<String?> pickFriend(BuildContext context, {required String title}) {
    final friends = context.read<ContactsStore>().friends;
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (c) => SizedBox(
        height: MediaQuery.sizeOf(c).height * 0.6,
        child: Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Align(alignment: Alignment.centerLeft, child: Text(title, style: c.tt.titleMedium))),
          Expanded(
            child: friends.isEmpty
                ? EmptyState(icon: AppIcons.friends, title: S.of(c)('no_friends'))
                : ListView.builder(
                    itemCount: friends.length,
                    itemBuilder: (_, i) => ListTile(
                      leading: Avatar(name: friends[i].displayName, seed: friends[i].peer, size: 36, presence: friends[i].presenceKey),
                      title: Text(friends[i].displayName),
                      subtitle: Text('ID ${friends[i].shortId}'),
                      onTap: () => Navigator.pop(c, friends[i].peer),
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}

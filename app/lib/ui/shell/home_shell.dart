import 'dart:async';

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../state/app_lock.dart';

import '../../core/api.dart';
import '../../core/links.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../chats/chat_list.dart';
import '../settings/background_sheet.dart';
import '../chats/chat_view.dart';
import '../files/files_screen.dart';
import '../friends/friends_screen.dart';
import '../groups/invite.dart';
import '../groups/server_view.dart';
import '../network/network_screen.dart';
import '../remote/remote_home.dart';
import '../settings/profile_editor.dart';
import '../settings/settings_screen.dart';
import '../flows.dart';
import '../../state/settings.dart';
import 'tour.dart';
import '../bots/botfather.dart';
import '../theme.dart';
import 'palette.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/common.dart';
import '../widgets/logo.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final AppLock _lock = context.read<AppLock>();

  @override
  void initState() {
    super.initState();
    pendingDeepLink.addListener(_handleLink);
    // Links that arrive while the app lock shows wait until it is unlocked.
    _lock.addListener(_handleLink);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleLink();
      _maybeTour();
    });
  }

  @override
  void dispose() {
    pendingDeepLink.removeListener(_handleLink);
    _lock.removeListener(_handleLink);
    super.dispose();
  }

  void _handleLink() {
    final l = pendingDeepLink.value;
    // HomeShell only exists once onboarding is done and the account is
    // unlocked; links that came earlier wait in pendingDeepLink until then.
    if (l == null || !mounted || !canOpenPendingLink(homeReady: true, lockShown: _lock.locked && _lock.enabled)) return;
    pendingDeepLink.value = null;
    Flows.openDeepLink(context, l);
  }

  void _maybeTour() {
    final st = context.read<Settings>();
    if (st.showTour && mounted) {
      st.update((x) => x.showTour = false);
      showWelcomeTour(context);
      return; // the background prompt waits for the next launch
    }
    // Android, once: let Lumora run in the background (no push server)
    if (mounted) unawaited(maybeAskBackground(context));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      return AppShortcuts(child: c.maxWidth >= kDesktopBreakpoint ? const _DesktopShell() : const _MobileShell());
    });
  }
}

// ---------------------------------------------------------------- desktop

class _DesktopShell extends StatelessWidget {
  const _DesktopShell();

  @override
  Widget build(BuildContext context) {
    final section = context.select<NavStore, Section>((n) => n.section);
    final width = MediaQuery.sizeOf(context).width;
    final listWidth = width >= 1280 ? 340.0 : 300.0;
    Widget? list;
    Widget content;
    switch (section) {
      case Section.chats:
        list = ChatListPane(onOpen: (id) => context.read<NavStore>().openConv(id));
        content = const _DesktopChatContent();
      case Section.space:
        list = const SpaceChannelsPane();
        content = const SpaceContent();
      case Section.friends:
        content = const FriendsScreen();
      case Section.remote:
        content = const RemoteHomeScreen();
      case Section.files:
        content = const FilesScreen();
      case Section.network:
        content = const NetworkScreen();
      case Section.settings:
        content = const SettingsScreen();
    }
    return Scaffold(
      body: Row(children: [
        const _Rail(),
        if (list != null)
          Container(
            width: listWidth,
            decoration: BoxDecoration(
              color: context.lc.surface,
              border: Border(right: BorderSide(color: context.lc.divider)),
            ),
            child: Column(children: [
              Expanded(child: list),
              const _UserPanel(),
            ]),
          ),
        Expanded(
          child: AnimatedSwitcher(
            duration: Motion.fast,
            child: KeyedSubtree(key: ValueKey(section), child: content),
          ),
        ),
      ]),
    );
  }
}

class _DesktopChatContent extends StatelessWidget {
  const _DesktopChatContent();
  @override
  Widget build(BuildContext context) {
    final conv = context.select<NavStore, String?>((n) => n.conv);
    if (conv == null) return const _Welcome();
    if (conv == kBotFatherConv) return const BotFatherChat(key: ValueKey(kBotFatherConv), embedded: true);
    return ChatView(key: ValueKey(conv), conv: conv, embedded: true);
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome();
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Container(
      color: context.lc.bg,
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const LumoraLogo(size: 84),
          const SizedBox(height: 20),
          Text(s('welcome_title'), style: context.tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(s('welcome_body'), textAlign: TextAlign.center, style: TextStyle(color: context.lc.muted, height: 1.5)),
          ),
          const SizedBox(height: 20),
          Pill(s('e2e_short'), color: LC.success, icon: AppIcons.lock),
        ]),
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail();

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nav = context.watch<NavStore>();
    // locked chats never count (rebuild when the locked list changes)
    context.select<Settings, List<String>>((x) => x.lockedChats);
    final unread = context.select<ChatStore, int>((c) => c.totalUnread);
    final pending = context.select<ContactsStore, int>((c) => c.pendingCount);
    final spaces = context.select<SpacesStore, List<Space>>((sp) => sp.spaces);
    final activeFiles = context.select<FilesStore, int>((f) => f.activeCount);
    Widget item(Section sec, IconData icon, String tip, {int badge = 0, IconData? activeIcon}) => _RailButton(
          selected: nav.section == sec,
          tooltip: tip,
          badge: badge,
          onTap: () => nav.go(sec),
          child: Icon(nav.section == sec ? (activeIcon ?? icon) : icon, size: 24),
        );
    return Container(
      width: 72,
      color: context.lc.rail,
      child: Column(children: [
        const SizedBox(height: 12),
        _RailButton(
          selected: nav.section == Section.chats,
          tooltip: s('chats'),
          badge: unread,
          onTap: () => nav.go(Section.chats),
          plain: true,
          child: const LumoraLogo(size: 44),
        ),
        const SizedBox(height: 4),
        item(Section.friends, AppIcons.friends, s('friends'), badge: pending, activeIcon: AppIcons.friendsActive),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 22),
          child: Divider(color: context.lc.divider, thickness: 2),
        ),
        Expanded(
          child: ListView(padding: EdgeInsets.zero, children: [
            for (final sp in spaces)
              _RailButton(
                selected: nav.section == Section.space && nav.spaceId == sp.id,
                tooltip: sp.name,
                badge: sp.channels.fold(0, (a, c) => a + c.unread) > 0 ? -1 : 0,
                onTap: () => nav.go(Section.space, space: sp.id),
                plain: true,
                child: GroupAvatar(gid: sp.id, name: sp.name, size: 46),
              ),
            Builder(
              builder: (bctx) => _RailButton(
                selected: false,
                tooltip: s('create_new'),
                onTap: () {
                  final box = bctx.findRenderObject() as RenderBox?;
                  Flows.showCreateMenu(bctx, at: box?.localToGlobal(box.size.centerRight(Offset.zero)));
                },
                child: const Icon(AppIcons.add, color: LC.success, size: 26),
              ),
            ),
            _RailButton(
              selected: false,
              tooltip: s('join_by_link'),
              onTap: () => showJoinByLink(context),
              child: const Icon(AppIcons.explore, color: LC.success, size: 24),
            ),
          ]),
        ),
        item(Section.remote, AppIcons.remote, s('remote'), activeIcon: AppIcons.remoteActive),
        item(Section.files, AppIcons.transfers, s('files'), badge: activeFiles > 0 ? -1 : 0, activeIcon: AppIcons.transfersActive),
        item(Section.settings, AppIcons.settings, s('settings'), activeIcon: AppIcons.settingsActive),
        const SizedBox(height: 10),
      ]),
    );
  }
}

class _RailButton extends StatefulWidget {
  const _RailButton({required this.selected, required this.tooltip, required this.onTap, required this.child, this.badge = 0, this.plain = false});
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;
  final Widget child;

  /// >0 count, -1 dot, 0 none.
  final int badge;
  final bool plain;

  @override
  State<_RailButton> createState() => _RailButtonState();
}

class _RailButtonState extends State<_RailButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    return Tooltip(
      message: widget.tooltip,
      preferBelow: false,
      verticalOffset: 0,
      margin: const EdgeInsets.only(left: 64),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: SizedBox(
            height: 56,
            child: Stack(alignment: Alignment.center, children: [
              Positioned(
                left: 0,
                child: AnimatedContainer(
                  duration: Motion.normal,
                  curve: Motion.curve,
                  width: 4,
                  height: sel ? 36 : (_hover ? 18 : (widget.badge != 0 ? 8 : 0)),
                  // brand-coloured marker (was the text colour: a black notch on light themes)
                  decoration: BoxDecoration(
                    gradient: sel ? LC.gradient : null,
                    color: sel ? null : LC.primary.withValues(alpha: 0.45),
                    borderRadius: const BorderRadius.horizontal(right: Radius.circular(4)),
                  ),
                ),
              ),
              AnimatedContainer(
                duration: Motion.normal,
                curve: Motion.curve,
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: widget.plain ? Colors.transparent : (sel ? LC.primary : (_hover ? LC.primary.withValues(alpha: 0.18) : context.lc.surface2)),
                  borderRadius: BorderRadius.circular(sel || _hover ? 16 : 24),
                ),
                alignment: Alignment.center,
                child: IconTheme(
                  data: IconThemeData(color: sel && !widget.plain ? Colors.white : context.lc.text),
                  child: widget.child,
                ),
              ),
              if (widget.badge > 0)
                Positioned(right: 8, bottom: 4, child: CountBadge(widget.badge))
              else if (widget.badge < 0)
                Positioned(
                  right: 12,
                  bottom: 6,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(color: LC.accent, shape: BoxShape.circle, border: Border.all(color: context.lc.rail, width: 2.5)),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Discord-like bottom-left user panel.
class _UserPanel extends StatelessWidget {
  const _UserPanel();

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final me = context.select<SessionStore, Me?>((x) => x.me);
    final status = context.select<SessionStore, String>((x) => x.profile.status);
    final nav = context.read<NavStore>();
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: context.lc.surface2.withValues(alpha: 0.6),
        border: Border(top: BorderSide(color: context.lc.divider)),
      ),
      child: Row(children: [
        Expanded(
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.sm),
              onTapDown: (d) => showProfileMenu(context, at: d.globalPosition - const Offset(0, 340)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: Row(children: [
                  PeerAvatar(peer: me?.peer ?? '', size: 36),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(me?.name ?? '', style: context.tt.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(statusLabel(s, status), style: context.tt.bodySmall, maxLines: 1),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
        ToolButton(
          icon: AppIcons.copy,
          size: 18,
          tooltip: s('copy_id'),
          onPressed: () => copyText(context, me?.shortId ?? ''),
        ),
        ToolButton(icon: AppIcons.settings, size: 19, tooltip: s('settings'), onPressed: () => nav.go(Section.settings)),
      ]),
    );
  }
}

// ----------------------------------------------------------------- mobile

class _MobileShell extends StatefulWidget {
  const _MobileShell();
  @override
  State<_MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<_MobileShell> {
  late int _tab = switch (context.read<NavStore>().section) {
    Section.friends => 1,
    Section.space => 2,
    Section.remote => 3,
    Section.settings => 4,
    _ => 0,
  };

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    // locked chats never count (rebuild when the locked list changes)
    context.select<Settings, List<String>>((x) => x.lockedChats);
    final unread = context.select<ChatStore, int>((c) => c.totalUnread);
    final pending = context.select<ContactsStore, int>((c) => c.pendingCount);
    final pages = [
      ChatListPane(
        mobile: true,
        onOpen: (id) {
          context.read<NavStore>().openConv(id);
          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => id == kBotFatherConv ? const BotFatherChat() : ChatView(conv: id)));
        },
      ),
      const FriendsScreen(),
      const SpacesMobileScreen(),
      const RemoteHomeScreen(),
      const SettingsScreen(),
    ];
    // Every destination gets the same Badge wrapper (shown or not) so the
    // regular and filled glyphs, and the badges, share one baseline.
    NavigationDestination dest(IconData icon, IconData active, String label, {int count = 0}) {
      Widget wrap(IconData i) => Badge(
            isLabelVisible: count > 0,
            label: Text(count > 99 ? '99+' : '$count'),
            child: SizedBox.square(dimension: 24, child: Icon(i, size: 24)),
          );
      return NavigationDestination(icon: wrap(icon), selectedIcon: wrap(active), label: label);
    }

    return Scaffold(
      body: SafeArea(bottom: false, child: IndexedStack(index: _tab, children: pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: [
          dest(AppIcons.chat, AppIcons.chatActive, s('chats'), count: unread),
          dest(AppIcons.friends, AppIcons.friendsActive, s('friends'), count: pending),
          dest(AppIcons.community, AppIcons.communityActive, s('spaces')),
          dest(AppIcons.remote, AppIcons.remoteActive, s('remote_short')),
          dest(AppIcons.settings, AppIcons.settingsActive, s('settings')),
        ],
      ),
    );
  }
}

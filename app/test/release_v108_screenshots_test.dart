// Screenshots of the v1.0.8 screens: privacy choices (who can call / add me /
// see me online) and their picker, "Giúp bạn bè khôi phục lịch sử", the
// recovery review list (verified + "Chưa xác minh"), invitations waiting for my
// answer, community settings (overview, roles, members, channels), group info
// with join requests + the upgrade-rules tile, choosing a new owner, the group
// call "Join" banner and the delete-account dialog — desktop (1440x900) and
// mobile (390x844 @2x) in dark + light, written to app/screenshots/.
// Run: flutter test test/release_v108_screenshots_test.dart
// Optional: SHOT_FILTER=r05 / SHOT_THEME=dark / SHOT_LANGS=vi,en.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/chats/delete_dialogs.dart';
import 'package:lumora/ui/groups/community/community_settings.dart';
import 'package:lumora/ui/groups/group_info.dart';
import 'package:lumora/ui/groups/group_invites_ui.dart';
import 'package:lumora/ui/groups/group_membership.dart';
import 'package:lumora/ui/settings/delete_account.dart';
import 'package:lumora/ui/settings/friend_recovery.dart';
import 'package:lumora/ui/settings/settings_screen.dart';

import 'helpers.dart';

/// The mock with what its plain groups lack: a pending join request and the
/// old (pre-RulesV2) rules on groups created here.
class _V108Mock extends MockLumoraApi {
  _V108Mock() : super(timers: false);
  final legacy = <String>{};
  @override
  Future<dynamic> request(String cmd, [Map<String, dynamic> args = const {}]) async {
    final r = await super.request(cmd, args);
    if (cmd == 'group_info' && r is Map && legacy.contains(args['gid'])) {
      return {
        ...r,
        'rules_v2': false,
        'join_requests': [
          {'peer': 'joinjoinjoinjoinjoinjoinjoinjoinjoinjoinjoinjoinjoinj', 'name': 'Lê Thu Hà', 'at': DateTime.now().millisecondsSinceEpoch - 600000},
          {'peer': 'joinbjoinbjoinbjoinbjoinbjoinbjoinbjoinbjoinbjoinbjoi', 'name': 'Phạm Quốc Bảo', 'at': DateTime.now().millisecondsSinceEpoch - 3600000},
        ],
      };
    }
    return r;
  }
}

typedef Setup = Future<Widget?> Function(WidgetTester t, AppServices sv, bool desktop);
typedef After = Future<void> Function(WidgetTester t, AppServices sv, bool desktop);

class Shot {
  const Shot(this.name, this.setup, {this.after});
  final String name;
  final Setup setup;
  final After? after;
}

Widget _settings(bool desktop, SettingsPage page) =>
    Scaffold(body: SafeArea(child: desktop ? SettingsScreen(initial: page) : SettingsSubPage(page: page)));

Future<void> _flush(WidgetTester t, [int ms = 80]) async {
  await t.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await settle(t, frames: 8);
}

Future<void> _show(WidgetTester t, Finder f) async {
  await _flush(t);
  // lists build lazily: scroll down until the row exists, then bring it in
  for (var i = 0; i < 40 && f.evaluate().isEmpty; i++) {
    await t.drag(find.byType(Scrollable).last, const Offset(0, -300));
    await settle(t, frames: 4);
  }
  await t.ensureVisible(f);
  await settle(t, frames: 4);
  await t.drag(find.byType(Scrollable).last, const Offset(0, 120));
  await settle(t, frames: 6);
}

/// A group I own with three friends (`kind` 1 = community); returns its gid.
Future<String> _group(WidgetTester t, AppServices sv, {int kind = 0, String name = 'Nhóm Đà Lạt 2026'}) async {
  late String gid;
  await t.runAsync(() async {
    final friends = sv.contacts.friends.take(3).map((c) => c.peer).toList();
    final g = await sv.api.request('create_group', {'name': name, 'members': friends, 'kind': kind}) as Map;
    gid = g['gid'] as String;
    await sv.spaces.load();
    await sv.chat.load();
  });
  return gid;
}

/// A button that opens [open] — tapped in `after` (sheets need a context).
Widget _opener(void Function(BuildContext) open) => Scaffold(
      body: Builder(builder: (c) => Center(child: TextButton(key: const ValueKey('opener'), onPressed: () => open(c), child: const Text('·')))),
    );

Future<void> _tapOpener(WidgetTester t, AppServices sv, bool d) async {
  await _flush(t);
  await t.tap(find.byKey(const ValueKey('opener')));
  await _flush(t, 150);
}

final shots = <Shot>[
  Shot('r01_privacy_choices', (t, sv, d) async => _settings(d, SettingsPage.privacy),
      after: (t, sv, d) => _show(t, find.byKey(const ValueKey('privacy_who_can_call')))),
  Shot('r02_privacy_call_picker', (t, sv, d) async => _settings(d, SettingsPage.privacy), after: (t, sv, d) async {
    await _show(t, find.byKey(const ValueKey('privacy_who_can_call')));
    await t.tap(find.byKey(const ValueKey('privacy_who_can_call')));
    await _flush(t);
  }),
  Shot('r03_help_restore', (t, sv, d) async => _settings(d, SettingsPage.privacy),
      after: (t, sv, d) => _show(t, find.byKey(const ValueKey('help_restore')))),
  Shot('r04_recovery_review', (t, sv, d) async => _opener((c) => showRecoveryOffers(c)), after: (t, sv, d) async {
    await _tapOpener(t, sv, d);
    final mock = sv.api as MockLumoraApi;
    final f = sv.contacts.friends;
    mock.debugRecoveryOffer({'peer': f[0].peer, 'name': f[0].name, 'messages': 1240, 'groups': ['00' * 16, '11' * 16], 'verified': true});
    mock.debugRecoveryOffer({'peer': 'carolcarolcarolcarolcarolcarolcarolcarolcarolcarolcar', 'name': 'Người lạ tên rất dài để thử xuống dòng', 'messages': 3, 'groups': <String>[]});
    await _flush(t, 300);
  }),
  Shot('r05_group_invites', (t, sv, d) async {
    final mock = sv.api as MockLumoraApi;
    final f = sv.contacts.friends;
    mock.debugEmit('group_invite', {'gid': 'ab' * 16, 'name': 'Lớp 12A1 — họp lớp', 'kind': 0, 'by': f[1].peer, 'by_name': f[1].name, 'at': DateTime.now().millisecondsSinceEpoch - 900000, 'members': 34});
    mock.debugEmit('group_invite', {'gid': 'cd' * 16, 'name': 'Cộng đồng Nhiếp ảnh Sài Gòn', 'kind': 1, 'by': f[2].peer, 'by_name': f[2].name, 'at': DateTime.now().millisecondsSinceEpoch - 7200000, 'members': 1280});
    await _flush(t, 300);
    return Scaffold(body: SafeArea(child: Column(children: const [GroupInvitesBanner(), Spacer()])));
  }, after: (t, sv, d) async {
    await _flush(t);
    await t.tap(find.byType(GroupInvitesBanner));
    await _flush(t, 150);
  }),
  for (final sec in CommunitySection.values.where((s) => s != CommunitySection.bots))
    Shot('r06_community_${sec.name}', (t, sv, d) async {
      final gid = await _group(t, sv, kind: 1, name: 'Cộng đồng Lumora Việt Nam');
      return _opener((c) => showCommunitySettings(c, gid, open: sec));
    }, after: _tapOpener),
  Shot('r07_group_join_requests', (t, sv, d) async {
    final gid = await _group(t, sv);
    (sv.api as _V108Mock).legacy.add(gid);
    return Scaffold(body: SafeArea(child: GroupInfoView(gid: gid)));
  }, after: (t, sv, d) => _show(t, find.byType(JoinRequestsSection))),
  Shot('r08_group_upgrade_rules', (t, sv, d) async {
    final gid = await _group(t, sv);
    (sv.api as _V108Mock).legacy.add(gid);
    return Scaffold(body: SafeArea(child: GroupInfoView(gid: gid)));
  }, after: (t, sv, d) => _show(t, find.byType(RulesUpgradeTile))),
  Shot('r09_pick_new_owner', (t, sv, d) async {
    final gid = await _group(t, sv);
    late GroupInfo g;
    await t.runAsync(() async => g = await sv.api.groupInfo(gid));
    return _opener((c) => pickNewOwner(c, g));
  }, after: _tapOpener),
  Shot('r10_group_call_banner', (t, sv, d) async {
    final gid = await _group(t, sv);
    final conv = 'g:$gid';
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, after: (t, sv, d) async {
    await _flush(t);
    final f = sv.contacts.friends;
    (sv.api as MockLumoraApi).debugEmit('call', {
      'call_id': 'ca11' * 8, 'conv': sv.nav.conv, 'state': 'available', 'video': true, 'room': false,
      'from': f[0].peer, 'participants': [f[0].peer, f[1].peer], 'started_at': DateTime.now().millisecondsSinceEpoch - 120000,
    });
    await _flush(t, 200);
  }),
  Shot('r12_mute_mentions_only', (t, sv, d) async {
    final gid = await _group(t, sv);
    return _opener((c) => pickMute(c, 'g:$gid'));
  }, after: _tapOpener),
  // desktop: the minimised call pill has its own strip — it never covers the voice
  // channel's "N in voice" line at the top of the community view
  Shot('r13_voice_room_pill', (t, sv, d) async {
    final gid = await _group(t, sv, kind: 1, name: 'Cộng đồng Lumora Việt Nam');
    final sp = sv.spaces.spaces.firstWhere((x) => x.id == gid);
    sv.nav.openChannel(sp.id, sp.channels.firstWhere((c) => !c.voice).conv);
    await t.runAsync(() => sv.spaces.joinVoice(sp.channels.firstWhere((c) => c.voice).conv));
    return null;
  }, after: (t, sv, d) async {
    await _flush(t, 200);
    if (!d) return;
    // the pill's strip ends where the voice stage starts: nothing of it is covered
    final strip = t.getRect(find.byKey(const ValueKey('call_pill_strip')));
    final stage = t.getRect(find.byKey(const ValueKey('voice_stage')));
    expect(strip.bottom, lessThanOrEqualTo(stage.top));
    expect(t.getRect(find.byKey(const ValueKey('call_pill'))).bottom, lessThanOrEqualTo(stage.top));
  }),
  Shot('r11_delete_account', (t, sv, d) async => _opener((c) => showDeleteAccountDialog(c)), after: _tapOpener),
];

Future<void> _capture(WidgetTester tester, GlobalKey key, String path) async {
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final f = File(path);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  final filter = Platform.environment['SHOT_FILTER'];
  final themeFilter = Platform.environment['SHOT_THEME'];
  final langs = (Platform.environment['SHOT_LANGS'] ?? 'vi').split(',');

  setUpAll(loadFonts);

  for (final shot in shots) {
    if (filter != null && !shot.name.contains(filter)) continue;
    for (final desktop in [true, false]) {
      for (final theme in [ThemeMode.dark, ThemeMode.light]) {
        if (themeFilter != null && theme.name != themeFilter) continue;
        for (final lang in langs) {
          final name = '${shot.name}_${desktop ? 'desktop' : 'mobile'}_${theme.name}${lang == 'vi' ? '' : '_$lang'}';
          testWidgets(name, (tester) async {
            if (desktop) {
              setSize(tester, const Size(1440, 900));
            } else {
              setSize(tester, const Size(390, 844), dpr: 2);
            }
            final sv = await makeServices(tester, locale: lang, theme: theme, api: _V108Mock());
            final home = await shot.setup(tester, sv, desktop);
            final key = GlobalKey();
            await tester.pumpWidget(RepaintBoundary(key: key, child: LumoraApp(services: sv, home: home)));
            await settle(tester);
            if (shot.after != null) {
              await shot.after!(tester, sv, desktop);
              await settle(tester, frames: 6);
            }
            for (var i = 0; i < 2; i++) {
              await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
              await tester.pump(const Duration(milliseconds: 40));
            }
            await _capture(tester, key, 'screenshots/$name.png');
            await tester.pumpWidget(const SizedBox());
            await tester.pump(const Duration(seconds: 100));
            sv.dispose();
            resetSize(tester);
          });
        }
      }
    }
  }
}

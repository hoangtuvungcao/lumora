// Screenshots of the multi-device screens (My devices, linking on both sides,
// approval, history copy, signed out, friends' devices, calls, remote) at
// desktop (1440x900) and mobile (390x844 @2x) sizes in dark + light, written
// to app/screenshots/. Run: flutter test test/devices_screenshots_test.dart
// Optional: SHOT_FILTER=d05 / SHOT_THEME=dark / SHOT_LANGS=vi,en.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/chats/chat_info.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/devices/approve_sheet.dart';
import 'package:lumora/ui/devices/device_picker.dart';
import 'package:lumora/ui/devices/history_sync.dart';
import 'package:lumora/ui/devices/link_device.dart';
import 'package:lumora/ui/devices/link_join.dart';
import 'package:lumora/ui/devices/my_devices.dart';
import 'package:lumora/ui/devices/qr_scan.dart';
import 'package:lumora/ui/devices/signed_out.dart';
import 'package:lumora/ui/onboarding/onboarding_screen.dart';
import 'package:lumora/ui/settings/settings_screen.dart';
import 'package:lumora/ui/shell/palette.dart' show showCommandPalette;
import 'package:lumora/ui/widgets/secure_input.dart';

import 'helpers.dart';

typedef Setup = Future<Widget?> Function(WidgetTester t, AppServices sv, bool desktop);
typedef After = Future<void> Function(WidgetTester t, AppServices sv, bool desktop);

class Shot {
  const Shot(this.name, this.setup, {this.after});
  final String name;
  final Setup setup;
  final After? after;
}

MockLumoraApi _mock(AppServices sv) => sv.api as MockLumoraApi;

Widget _settings(bool desktop) =>
    Scaffold(body: SafeArea(child: desktop ? const SettingsScreen(initial: SettingsPage.devices) : const SettingsSubPage(page: SettingsPage.devices)));

/// A context below the app's Navigator.
BuildContext _ctx(WidgetTester t) => t.element(find.byType(Scaffold).first);

Future<void> _linked(WidgetTester t, AppServices sv) async {
  _mock(sv).debugMakeLinkedDevice();
  await t.runAsync(() => sv.devices.load());
}

/// Core events are delivered in the zone that subscribed (a real-async one
/// in these tests): let them through.
Future<void> _flushEvents(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await settle(t, frames: 2);
}

Widget _secure(Widget child) => Scaffold(body: SecureFrame(child: child));

const _target = LinkRequest(device: 'x', name: 'Điện thoại của Lan', kind: 1, state: 'awaiting_approval');

final shots = <Shot>[
  Shot('d01_my_devices', (t, sv, d) async {
    await t.runAsync(() => sv.devices.load());
    return _settings(d);
  }),
  Shot('d02_my_devices_linked', (t, sv, d) async {
    await _linked(t, sv);
    _mock(sv).simulateHistorySync(1284, convsDone: 5, convsTotal: 12);
    await _flushEvents(t);
    return _settings(d);
  }),
  Shot('d03_device_sheet', (t, sv, d) async {
    await t.runAsync(() => sv.devices.load());
    return _settings(d);
  }, after: (t, sv, d) async {
    showDeviceSheet(_ctx(t), sv.devices.list!.devices[1]);
  }),
  Shot('d04_revoke_confirm', (t, sv, d) async {
    await t.runAsync(() => sv.devices.load());
    return _settings(d);
  }, after: (t, sv, d) async {
    confirmRevoke(_ctx(t), sv.devices.list!.devices[1]);
  }),
  Shot('d05_link_qr', (t, sv, d) async {
    await t.runAsync(() => sv.devices.load());
    return _settings(d);
  }, after: (t, sv, d) async {
    openLinkDevice(_ctx(t));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  }),
  Shot('d06_link_code', (t, sv, d) async {
    await t.runAsync(() => sv.devices.load());
    return _settings(d);
  }, after: (t, sv, d) async {
    showSecureDialog<void>(_ctx(t), builder: (_) => const LinkDeviceScreen(showCode: true));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  }),
  Shot('d07_link_approval', (t, sv, d) async {
    await t.runAsync(() => sv.devices.load());
    return _settings(d);
  }, after: (t, sv, d) async {
    openLinkDevice(_ctx(t));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(t, frames: 4);
    _mock(sv).simulateLinkRequest();
    await _flushEvents(t);
  }),
  Shot('d08_link_done', (t, sv, d) async {
    await t.runAsync(() => sv.devices.load());
    return _settings(d);
  }, after: (t, sv, d) async {
    showSecureDialog<void>(_ctx(t), builder: (_) => const LinkDeviceScreen(previewDone: 'Laptop ở nhà'));
  }),
  Shot('d09_onboarding_welcome', (t, sv, d) async => const OnboardingScreen(initialStep: 0)),
  Shot('d10_join_enter', (t, sv, d) async => const OnboardingScreen(initialStep: 7)),
  Shot('d11_join_code_error', (t, sv, d) async => _secure(const LinkJoinView(previewCode: '000000000000', previewError: 'Mã chưa đúng. Hãy kiểm tra lại trên thiết bị kia.'))),
  Shot('d12_join_waiting', (t, sv, d) async => _secure(const LinkJoinView(initialPhase: JoinPhase.waiting, previewTarget: _target))),
  Shot('d13_join_approved', (t, sv, d) async => _secure(const LinkJoinView(initialPhase: JoinPhase.approved))),
  Shot('d14_join_failed', (t, sv, d) async => _secure(LinkJoinView(initialPhase: JoinPhase.failed, previewError: sv.settings.locale == 'en' ? 'The request was declined on the other device.' : 'Yêu cầu đã bị từ chối trên thiết bị kia.'))),
  Shot('d15_history', (t, sv, d) async {
    _mock(sv).simulateLinkApproved();
    await _flushEvents(t);
    _mock(sv).simulateHistorySync(1284, convsDone: 5, convsTotal: 12);
    await _flushEvents(t);
    return const HistorySyncScreen();
  }),
  Shot('d16_history_done', (t, sv, d) async {
    _mock(sv).simulateLinkApproved();
    await _flushEvents(t);
    _mock(sv).simulateHistorySync(3517, convsDone: 12, convsTotal: 12, done: true);
    await _flushEvents(t);
    return const HistorySyncScreen();
  }),
  Shot('d17_signed_out', (t, sv, d) async {
    _mock(sv).simulateDeviceRevoked(wipe: true);
    await _flushEvents(t);
    return DeviceSignedOutScreen(onStartOver: () {});
  }),
  Shot('d18_promote', (t, sv, d) async {
    await _linked(t, sv);
    return _settings(d);
  }, after: (t, sv, d) async {
    showPromoteDialog(_ctx(t));
  }),
  Shot('d19_contact_devices', (t, sv, d) async {
    var peer = sv.contacts.friends.first.peer;
    for (final f in sv.contacts.friends) {
      if ((await t.runAsync(() => sv.devices.loadContact(f.peer)))!.length == 3) {
        peer = f.peer;
        break;
      }
    }
    sv.nav.openConv('d:$peer');
    return Scaffold(body: SafeArea(child: Center(child: SizedBox(width: d ? 400 : null, child: ChatInfoPanel(conv: 'd:$peer')))));
  }, after: (t, sv, d) async {
    await t.tap(find.text(sv.settings.locale == 'en' ? '3 devices' : '3 thiết bị'));
    await settle(t, frames: 4);
    await t.tap(find.text(sv.settings.locale == 'en' ? 'Security code' : 'Mã bảo mật').first);
  }),
  Shot('d20_answered_elsewhere', (t, sv, d) async {
    final p = sv.contacts.friends.first.peer;
    sv.calls.onCall({'call_id': 'c9', 'conv': 'd:$p', 'peer': p, 'state': 'incoming', 'video': true, 'participants': [p]});
    sv.calls.onCall({'call_id': 'c9', 'conv': 'd:$p', 'peer': p, 'state': 'ended', 'reason': 'answered_elsewhere', 'device_name': 'Laptop văn phòng'});
    return null;
  }),
  Shot('d21_remote_picker', (t, sv, d) async {
    sv.nav.go(Section.remote);
    return null;
  }, after: (t, sv, d) async {
    pickRemoteDevice(_ctx(t), const [
      RemoteDeviceChoice(device: 'a', name: 'Laptop', kind: 3, shortId: '715 204 389'),
      RemoteDeviceChoice(device: 'b', name: 'Máy tính ở nhà', kind: 3, shortId: '306 558 112'),
    ]);
  }),
  Shot('d22_remote_id_card', (t, sv, d) async {
    await t.runAsync(() => sv.devices.load());
    sv.nav.go(Section.remote);
    return null;
  }),
  Shot('d23_approval_sheet_en_long', (t, sv, d) async {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: LinkApprovalCard(
              request: const LinkRequest(device: 'z', name: 'MacBook Pro của Lan (văn phòng)', kind: 3, os: 'macos', path: 'direct'),
              onResult: (_) {},
            ),
          ),
        ),
      ),
    );
  }),
  Shot('d24_privacy_ip', (t, sv, d) async {
    return Scaffold(body: SafeArea(child: d ? const SettingsScreen(initial: SettingsPage.privacy) : const SettingsSubPage(page: SettingsPage.privacy)));
  }),
  Shot('d25_join_scan', (t, sv, d) async {
    // phones get the camera scanner (desktop keeps the code)
    linkQrScanner = (_) async => null;
    addTearDown(() => linkQrScanner = null);
    return const OnboardingScreen(initialStep: 7);
  }),
  Shot('d26_scan_camera_denied', (t, sv, d) async => const Scaffold(body: QrCameraIssue(denied: true))),
  Shot('d27_promote_passphrase', (t, sv, d) async {
    await _linked(t, sv);
    await t.runAsync(() async {
      await sv.api.request('change_passphrase', {'old': '', 'new': 'hoa-sen-2026'});
      await sv.session.reloadMe();
    });
    return _settings(d);
  }, after: (t, sv, d) async {
    showPromoteDialog(_ctx(t));
    await settle(t, frames: 4);
    await t.ensureVisible(find.byType(PasswordField));
  }),
  Shot('d28_bridged_chat', (t, sv, d) async {
    final f = sv.contacts.friends.first.peer;
    sv.nav.openConv('d:$f');
    _mock(sv).simulateBridgedFriend(f);
    _mock(sv).simulateContactDeviceAdded(f);
    await _flushEvents(t);
    return d ? null : Scaffold(body: SafeArea(child: ChatView(conv: 'd:$f')));
  }),
  // Group abuse protections: someone flooded a group this account manages,
  // and public group search with one verified listing.
  Shot('d29_group_flood', (t, sv, d) async {
    final g = sv.chat.convs.values.firstWhere((c) => c.isGroup && c.title.startsWith('Dự án')).id;
    sv.nav.openConv(g);
    _mock(sv).simulateGroupFlood(g, admin: true);
    await _flushEvents(t);
    return d ? null : Scaffold(body: SafeArea(child: ChatView(conv: g)));
  }),
  Shot('d30_public_groups', (t, sv, d) async => null, after: (t, sv, d) async {
    showCommandPalette(_ctx(t), initial: 'flutter rust');
    await settle(t, frames: 6);
    await _flushEvents(t);
  }),
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
            final sv = await makeServices(tester, locale: lang, theme: theme);
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

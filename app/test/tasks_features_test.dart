// Checklists, reminders, silent send, call noise suppression and
// "wake up" for remote devices: model parsing + screenshots with the mock API.
// Screenshots: SHOT=1 flutter test test/tasks_features_test.dart
// (written to app/screenshots/8x_*.png).

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/calls/call_layer.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/chats/task_sheets.dart';

import 'helpers.dart';

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

String _project(AppServices sv) => sv.chat.sorted.firstWhere((c) => c.title.startsWith('Dự án')).id;

typedef _Setup = Future<Widget?> Function(WidgetTester t, AppServices sv, bool desktop);
typedef _After = Future<void> Function(WidgetTester t, AppServices sv, bool desktop);

final _shots = <(String, _Setup, _After?)>[
  ('80_chat_checklist_reminder', (t, sv, d) async {
    final conv = _project(sv);
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, null),
  ('81_checklist_composer', (t, sv, d) async {
    final conv = _project(sv);
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, (t, sv, d) async {
    showChecklistComposer(t.element(find.byType(ChatView).first), _project(sv));
  }),
  ('82_reminder_composer', (t, sv, d) async {
    final conv = _project(sv);
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, (t, sv, d) async {
    showReminderComposer(t.element(find.byType(ChatView).first), _project(sv));
  }),
  ('83_send_options', (t, sv, d) async {
    final conv = _project(sv);
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, (t, sv, d) async {
    await t.enterText(find.byType(TextField).last, 'Mọi người nghỉ sớm nhé');
    await settle(t, frames: 3);
    final send = find.byTooltip('Gửi').last;
    if (d) {
      await t.tap(send, buttons: kSecondaryButton);
    } else {
      await t.longPress(send);
    }
  }),
  ('84_reminder_banner', (t, sv, d) async {
    final conv = _project(sv);
    sv.chat.onReminderDue({'conv': conv, 'msg_id': 'r1', 'title': 'Họp sprint review', 'note': 'Phòng họp online, nhớ mang bản demo', 'at_ms': DateTime.now().millisecondsSinceEpoch, 'author': '', 'late': false});
    return null;
  }, null),
  ('85_wake_device', (t, sv, d) async {
    sv.nav.go(Section.remote);
    return null;
  }, (t, sv, d) async {
    // The button only shows for offline recent devices that can be woken.
    await t.ensureVisible(find.byTooltip('Đánh thức').first);
    await settle(t, frames: 2);
    await t.tap(find.byTooltip('Đánh thức').first);
    await settle(t, frames: 4);
    await t.tap(find.text('Cách bật'));
  }),
  ('86_call_audio', (t, sv, d) async => null, (t, sv, d) async {
    showCallAudioSettings(t.element(find.byType(Scaffold).first));
  }),
];

void main() {
  group('model', () {
    test('state keys are not emoji reactions; silent flag', () {
      final m = Message.fromJson({
        'id': 'a', 'conv': 'd:x', 'author': 'p', 'ts': 1, 'kind': 'checklist', 'silent': true,
        'body': {'title': 'Đi chợ', 'items': [{'id': 0, 'text': 'Rau'}, {'id': 1, 'text': 'Cá'}]},
        'reactions': {
          '👍': ['p'],
          '__votes': {'p': 1},
          '__checks': {'1': {'done': true, 'by': 'q', 'at': 5}},
        },
      });
      expect(m.reactions.keys, ['👍']);
      expect(m.silent, isTrue);
      expect(m.votes, {'p': 1});
      final c = ChecklistData.parse(m)!;
      expect(c.title, 'Đi chợ');
      expect(c.doneCount, 1);
      expect(c.items[1].by, 'q');
      final u = m.applyUpdate({'reactions': {'__checks': {'0': {'done': true, 'by': 'p', 'at': 9}}}});
      expect(ChecklistData.parse(u)!.items[0].done, isTrue);
      expect(u.reactions, isEmpty);
      final body = u.applyUpdate({'body': {'title': 'Đi chợ', 'items': [{'id': 0, 'text': 'Rau'}, {'id': 1, 'text': 'Cá'}, {'id': 2, 'text': 'Thịt'}]}});
      expect(ChecklistData.parse(body)!.items.length, 3);
    });

    test('reminder state', () {
      final m = Message.fromJson({
        'id': 'b', 'conv': 'd:x', 'author': 'p', 'ts': 1, 'kind': 'reminder',
        'body': {'title': 'Họp', 'at_ms': 1000, 'note': 'n'},
        'reactions': {'__seen': {'q': 7}, '__cancelled': {'by': 'p', 'at': 8}},
      });
      final r = ReminderData.parse(m)!;
      expect(r.title, 'Họp');
      expect(r.atMs, 1000);
      expect(r.seen, {'q': 7});
      expect(r.cancelled, isTrue);
      expect(m.silent, isFalse);
    });
  });

  if (Platform.environment['SHOT'] == null) return;
  setUpAll(loadFonts);
  for (final shot in _shots) {
    for (final desktop in [true, false]) {
      for (final theme in [ThemeMode.dark, ThemeMode.light]) {
        final name = '${shot.$1}_${desktop ? 'desktop' : 'mobile'}_${theme.name}';
        testWidgets(name, (tester) async {
          desktop ? setSize(tester, const Size(1440, 900)) : setSize(tester, const Size(390, 844), dpr: 2);
          final sv = await makeServices(tester, theme: theme);
          final home = await shot.$2(tester, sv, desktop);
          final key = GlobalKey();
          await tester.pumpWidget(RepaintBoundary(key: key, child: LumoraApp(services: sv, home: home)));
          await settle(tester);
          if (shot.$3 != null) {
            await shot.$3!(tester, sv, desktop);
            await settle(tester, frames: 6);
          }
          for (var i = 0; i < 2; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
            await tester.pump(const Duration(milliseconds: 40));
          }
          await _capture(tester, key, 'screenshots/$name.png');
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 300));
          sv.dispose();
          resetSize(tester);
        });
      }
    }
  }
}

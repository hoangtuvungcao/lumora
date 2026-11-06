// Remote control from a phone: touch acts like a laptop touchpad (relative cursor,
// tap = click, two-finger tap = right-click, two-finger drag = scroll, long press =
// right-click, tap-then-hold = drag), a real mouse still acts where it points.

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/ui/remote/remote_layer.dart';

import 'helpers.dart';

class _Spy extends MockLumoraApi {
  _Spy() : super(timers: false);
  final inputs = <Map<String, dynamic>>[];
  @override
  Future<dynamic> request(String cmd, [Map<String, dynamic> args = const {}]) async {
    if (cmd == 'remote_input') inputs.add(Map<String, dynamic>.from(args['ev'] as Map));
    return super.request(cmd, args);
  }
}

void main() {
  setUpAll(loadFonts);

  Future<(AppServices, _Spy)> open(WidgetTester t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final api = _Spy();
    final sv = await makeServices(t, api: api);
    setSize(t, const Size(400, 800));
    api.emitForTest('remote_state', {'session': 'rs1', 'peer': '', 'state': 'active', 'role': 'viewer', 'width': 1920, 'height': 1080, 'stream': 0, 'control': true});
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: const Scaffold(body: RemoteViewerScreen())));
    await t.pump(const Duration(milliseconds: 100));
    return (sv, api);
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    resetSize(t);
    debugDefaultTargetPlatformOverride = null;
  }

  // the remote input calls are async: let them land
  Future<void> drain(WidgetTester t) => t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));

  Iterable<Map<String, dynamic>> of(_Spy a, String type) => a.inputs.where((e) => e['t'] == type);

  testWidgets('one finger moves the cursor relatively; a tap clicks where the cursor is', (t) async {
    final (_, api) = await open(t);
    final c = t.getCenter(find.byType(RemoteViewerScreen));
    // drag right: the cursor moves right of the middle (not to where the finger is)
    final g = await t.startGesture(c + const Offset(-100, 100));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(8, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await t.pump(const Duration(milliseconds: 400));
    await drain(t);
    final moves = of(api, 'move').toList();
    expect(moves, isNotEmpty);
    expect((moves.last['x'] as num) > 0.5, isTrue, reason: 'relative: started at the middle, moved right');
    expect(of(api, 'button'), isEmpty, reason: 'a drag is not a click');
    // a tap: left down + up, no movement of the cursor
    api.inputs.clear();
    await t.tapAt(c + const Offset(120, -200));
    await t.pump(const Duration(milliseconds: 400));
    await drain(t);
    final b = of(api, 'button').toList();
    expect(b.map((e) => '${e['b']}:${e['down']}'), ['left:true', 'left:false']);
    await close(t);
  });

  testWidgets('two-finger tap = right-click, two-finger drag = scroll, long press = right-click', (t) async {
    final (_, api) = await open(t);
    final c = t.getCenter(find.byType(RemoteViewerScreen));
    final a = await t.startGesture(c - const Offset(40, 0), pointer: 1);
    final b = await t.startGesture(c + const Offset(40, 0), pointer: 2);
    await t.pump(const Duration(milliseconds: 50));
    await a.up();
    await b.up();
    await t.pump(const Duration(milliseconds: 100));
    await drain(t);
    expect(of(api, 'button').map((e) => '${e['b']}:${e['down']}'), ['right:true', 'right:false']);

    api.inputs.clear();
    final a2 = await t.startGesture(c - const Offset(40, 100), pointer: 3);
    final b2 = await t.startGesture(c + const Offset(40, -100), pointer: 4);
    for (var i = 0; i < 12; i++) {
      await a2.moveBy(const Offset(0, 10));
      await b2.moveBy(const Offset(0, 10));
      await t.pump(const Duration(milliseconds: 16));
    }
    await a2.up();
    await b2.up();
    await t.pump(const Duration(milliseconds: 100));
    await drain(t);
    final wheel = of(api, 'wheel').toList();
    expect(wheel, isNotEmpty, reason: 'two fingers dragging scroll');
    expect(wheel.every((e) => e['dy'] == -1), isTrue, reason: 'fingers down = content follows = scroll up');
    expect(of(api, 'button'), isEmpty);

    api.inputs.clear();
    final l = await t.startGesture(c, pointer: 5);
    await t.pump(const Duration(milliseconds: 700));
    await l.up();
    await t.pump(const Duration(milliseconds: 100));
    await drain(t);
    expect(of(api, 'button').map((e) => '${e['b']}:${e['down']}'), ['right:true', 'right:false']);
    await close(t);
  });

  testWidgets('tap, then touch again and hold: drag with the left button held', (t) async {
    final (_, api) = await open(t);
    final c = t.getCenter(find.byType(RemoteViewerScreen));
    await t.tapAt(c);
    await t.pump(const Duration(milliseconds: 120));
    final g = await t.startGesture(c);
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(10, 6));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await t.pump(const Duration(milliseconds: 100));
    await drain(t);
    expect(of(api, 'button').map((e) => '${e['b']}:${e['down']}'), ['left:true', 'left:false', 'left:true', 'left:false']);
    // the second press stays down while moving
    final i = api.inputs.indexWhere((e) => e['t'] == 'button' && e['down'] == true && api.inputs.indexOf(e) > 1);
    expect(api.inputs.skip(i).takeWhile((e) => e['t'] != 'button' || e['down'] == true).where((e) => e['t'] == 'move'), isNotEmpty);
    await close(t);
  });

  testWidgets('a real mouse still acts where it points (absolute)', (t) async {
    final (_, api) = await open(t);
    final c = t.getCenter(find.byType(RemoteViewerScreen));
    // a real mouse click at the right edge of the image goes there
    final m = await t.startGesture(c + const Offset(150, 0), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await m.up();
    await t.pump(const Duration(milliseconds: 50));
    await drain(t);
    final mv = of(api, 'move').toList();
    expect(mv, isNotEmpty);
    expect((mv.last['x'] as num) > 0.8, isTrue, reason: 'mouse: absolute');
    await close(t);
  });
}

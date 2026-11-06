// #5 / #23: voice notes on phones — hold, slide, lock and release must keep
// working while the recording bar is shown; the microphone always stops; the
// note is recorded into app storage (not temp) and removed when cancelled.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/core/outgoing.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/chats/composer.dart';
import 'package:record/record.dart';

import 'helpers.dart';

class _FakeRecorder implements AudioRecorder {
  static final all = <_FakeRecorder>[];
  _FakeRecorder() {
    all.add(this);
  }
  int starts = 0, stops = 0, disposes = 0;
  String? path;
  bool get recording => starts > stops;
  final _amp = StreamController<Amplitude>.broadcast();
  @override
  Future<bool> hasPermission({bool request = true}) async => true;
  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    starts++;
    this.path = path;
    File(path).writeAsBytesSync(List.filled(64, 1));
  }

  @override
  Future<String?> stop() async {
    stops++;
    return path;
  }

  @override
  Future<void> dispose() async {
    disposes++;
    await _amp.close();
  }

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) => _amp.stream;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _VoiceSpy extends MockLumoraApi {
  _VoiceSpy() : super(timers: false);
  final voices = <String>[];
  @override
  Future<dynamic> request(String cmd, [Map<String, dynamic> args = const {}]) {
    if (cmd == 'send_voice') voices.add('${args['path']}');
    return super.request(cmd, args);
  }
}

Future<void> _shot(WidgetTester t, String path) async {
  await t.runAsync(() async {
    RenderObject? ro = t.renderObject(find.byType(ChatView));
    while (ro != null && ro is! RenderRepaintBoundary) {
      ro = ro.parent;
    }
    final image = await (ro! as RenderRepaintBoundary).toImage(pixelRatio: t.view.devicePixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  late Directory base;
  final shots = Platform.environment['SHOT_VOICE'] == '1';
  setUpAll(() async {
    if (shots) await loadFonts();
  });
  setUp(() {
    _FakeRecorder.all.clear();
    composerRecorderFactory = _FakeRecorder.new;
    base = Directory.systemTemp.createTempSync('lumora-voice');
    debugOutgoingBase = base;
  });
  tearDown(() {
    composerRecorderFactory = AudioRecorder.new;
    debugOutgoingBase = null;
    try {
      base.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<(AppServices, _VoiceSpy, String)> open(WidgetTester t) async {
    // SHOT_VOICE=1: a small phone, for the screenshot of the recording bar
    setSize(t, Platform.environment['SHOT_VOICE'] == '1' ? const Size(320, 640) : const Size(390, 844), dpr: 2);
    final api = _VoiceSpy();
    final sv = await makeServices(t, api: api);
    await t.pumpWidget(LumoraApp(services: sv));
    await settle(t);
    final conv = sv.chat.sorted.firstWhere((c) => !c.isGroup && !c.isSaved).id;
    sv.nav.openConv(conv);
    Navigator.of(t.element(find.byType(Scaffold).first)).push(MaterialPageRoute<void>(builder: (_) => ChatView(conv: conv)));
    await settle(t);
    return (sv, api, conv);
  }

  Future<void> close(WidgetTester t, AppServices sv) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(t);
  }

  /// Lets file I/O (real async) and the widget's futures (fake async) run.
  Future<void> real(WidgetTester t, [int ms = 30]) async {
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms ~/ 3 + 1)));
      await t.pump();
    }
  }

  Finder mic() => find.byWidgetPredicate((w) => w is Tooltip && (w.message == 'Nhấn giữ để ghi âm' || w.message == 'Đang ghi âm…'));

  testWidgets('hold → bar shows → release sends; mic stays mounted', (t) async {
    final (sv, api, _) = await open(t);
    expect(mic(), findsOneWidget);
    final g = await t.startGesture(t.getCenter(mic()));
    await t.pump(const Duration(milliseconds: 600)); // long press
    await real(t);
    await t.pump();
    final rec = _FakeRecorder.all.single;
    expect(rec.recording, isTrue);
    expect(rec.path, startsWith(base.path), reason: 'recorded into app storage, not temp');
    expect(find.byKey(const ValueKey('voice_send')), findsOneWidget);
    expect(mic(), findsOneWidget, reason: 'the gesture target survives the swap');
    // hold long enough to count as a note
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
    await g.up();
    await real(t, 60);
    await t.pump();
    expect(rec.stops, 1);
    expect(rec.disposes, 1);
    expect(api.voices, [rec.path]);
    expect(File(rec.path!).existsSync(), isTrue, reason: 'the core serves the sent note from this file');
    await close(t, sv);
  });

  testWidgets('slide left cancels and deletes the clip', (t) async {
    final (sv, api, _) = await open(t);
    final g = await t.startGesture(t.getCenter(mic()));
    await t.pump(const Duration(milliseconds: 600));
    await real(t);
    final rec = _FakeRecorder.all.single;
    await g.moveBy(const Offset(-140, 0));
    await t.pump();
    await g.up();
    await real(t, 60);
    expect(rec.stops, 1);
    expect(api.voices, isEmpty);
    expect(File(rec.path!).existsSync(), isFalse);
    await close(t, sv);
  });

  testWidgets('slide up locks; explicit send button sends', (t) async {
    final (sv, api, _) = await open(t);
    final g = await t.startGesture(t.getCenter(mic()));
    await t.pump(const Duration(milliseconds: 600));
    await real(t);
    await g.moveBy(const Offset(0, -120));
    await t.pump();
    await g.up();
    await real(t);
    final rec = _FakeRecorder.all.single;
    expect(rec.recording, isTrue, reason: 'locked: keeps recording after release');
    if (Platform.environment['SHOT_VOICE'] == '1') await _shot(t, 'screenshots/narrow/voice_recording_locked.png');
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
    await t.tap(find.byKey(const ValueKey('voice_send')));
    await real(t, 60);
    expect(rec.stops, 1);
    expect(api.voices.length, 1);
    await close(t, sv);
  });

  testWidgets('leaving the chat or the app going to background stops the mic', (t) async {
    final (sv, _, _) = await open(t);
    final g = await t.startGesture(t.getCenter(mic()));
    await t.pump(const Duration(milliseconds: 600));
    await real(t);
    await g.moveBy(const Offset(0, -120));
    await g.up();
    await real(t);
    final rec = _FakeRecorder.all.single;
    expect(rec.recording, isTrue);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await real(t, 60);
    expect(rec.recording, isFalse);
    expect(File(rec.path!).existsSync(), isFalse);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    // second recording, then back
    final g2 = await t.startGesture(t.getCenter(mic()));
    await t.pump(const Duration(milliseconds: 600));
    await real(t);
    await g2.moveBy(const Offset(0, -120));
    await g2.up();
    await real(t);
    final rec2 = _FakeRecorder.all.last;
    expect(rec2, isNot(same(rec)));
    expect(rec2.recording, isTrue);
    Navigator.of(t.element(find.byType(ChatView))).pop();
    await settle(t);
    await real(t, 60);
    expect(rec2.recording, isFalse);
    expect(rec2.disposes, 1);
    await close(t, sv);
  });

  testWidgets('release before the microphone opened: no stuck recording', (t) async {
    final (sv, api, _) = await open(t);
    final g = await t.startGesture(t.getCenter(mic()));
    await t.pump(const Duration(milliseconds: 600)); // start begins (async)
    await g.up(); // released before the recorder answered
    await real(t, 60);
    for (final r in _FakeRecorder.all) {
      expect(r.recording, isFalse);
    }
    expect(api.voices, isEmpty);
    await close(t, sv);
  });
}

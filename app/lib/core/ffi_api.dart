// Real implementation of [LumoraApi] on top of the `lumora-ffi` C ABI.
//
//   int32_t lumora_start(const char* config_json)
//   char*   lumora_request(const char* request_json)      (blocking)
//   char*   lumora_next_event(int32_t timeout_ms)         (NULL on timeout)
//   int64_t lumora_frame(uint32_t stream, uint64_t last_seq, uint8_t* dst,
//                        uint32_t cap, uint32_t* w, uint32_t* h, uint64_t* seq)
//           → bytes written, 0 = nothing newer than last_seq, -needed = cap too small
//   int32_t lumora_needs_passphrase(const char* data_dir) → 1 / 0 / -1 (no identity)
//   int32_t lumora_phrase_matches(const char* data_dir, const char* phrase)
//           → 1 / 0 / -1 (can't tell); optional
//   void    lumora_free(char*)
//   const char* lumora_last_error()          (plain text for the user)
//   const char* lumora_last_error_json()     ({"error","code","detail"?}; optional)
//   void    lumora_stop()
//
// Blocking calls (`lumora_start`, `lumora_request`, `lumora_next_event`) run
// in background isolates so the UI thread never blocks. `lumora_frame` is a
// cheap memcpy and is called on the UI isolate into a reusable native buffer.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show debugPrint, kReleaseMode, visibleForTesting;

import '../platform/android_bridge.dart';
import 'api.dart';
import '../platform/apple_services.dart';

typedef _StartC = Int32 Function(Pointer<Utf8>);
typedef _StartD = int Function(Pointer<Utf8>);
typedef _RequestC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _RequestD = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NextEventC = Pointer<Utf8> Function(Int32);
typedef _NextEventD = Pointer<Utf8> Function(int);
typedef _FrameC = Int64 Function(Uint32, Uint64, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint64>);
typedef _FrameD = int Function(int, int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint64>);
typedef _NeedsPassC = Int32 Function(Pointer<Utf8>);
typedef _NeedsPassD = int Function(Pointer<Utf8>);
typedef _PhraseMatchC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _PhraseMatchD = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeD = void Function(Pointer<Utf8>);
typedef _LastErrC = Pointer<Utf8> Function();
typedef _LastErrD = Pointer<Utf8> Function();
typedef _StopC = Void Function();
typedef _StopD = void Function();

/// Library file name for the current platform.
String lumoraLibraryName() {
  if (Platform.isWindows) return 'lumora_ffi.dll';
  if (Platform.isMacOS) return 'liblumora_ffi.dylib';
  return 'liblumora_ffi.so'; // Linux + Android (jniLibs)
}

/// Opens the native library, trying next to the executable first.
///
/// iOS: the core is a static library (`liblumora_ffi.a`) force-loaded into the
/// Runner executable (see ios/Flutter/Lumora.xcconfig), so its symbols are
/// looked up in the running process. macOS: `liblumora_ffi.dylib` is embedded in
/// `Lumora.app/Contents/Frameworks` by an Xcode build phase.
/// Path of the core library this process loaded (null on iOS, where it is
/// linked in, and before loading). Native camera capture on macOS/Windows
/// resolves `lumora_push_camera_yuv` from the same image.
String? lumoraLoadedLibraryPath;

DynamicLibrary openLumoraLibrary([String? override]) {
  if (Platform.isIOS && override == null) {
    final lib = DynamicLibrary.process();
    if (!lib.providesSymbol('lumora_start')) {
      throw ArgumentError(
        'Cannot load the Lumora core: liblumora_ffi.a is not linked into the app '
        '(run app/tool/apple/build_core.sh ios before building)',
      );
    }
    return lib;
  }
  final name = override ?? lumoraLibraryName();
  final candidates = <String>[name];
  if (!Platform.isAndroid && override == null) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    // Development only: an explicit override and the Rust build folders.
    // Release builds load nothing but the library shipped with the app.
    final env = kReleaseMode ? null : Platform.environment['LUMORA_FFI_LIB'];
    candidates.insertAll(0, [
      ?env,
      // macOS: Lumora.app/Contents/MacOS/Lumora → Contents/Frameworks (embedded,
      // signed with the app; the only location the hardened runtime should load from).
      if (Platform.isMacOS) '$exeDir/../Frameworks/$name',
      '$exeDir${Platform.pathSeparator}$name',
      '$exeDir${Platform.pathSeparator}lib${Platform.pathSeparator}$name',
    ]);
    if (!kReleaseMode) {
      // Walk up from the working directory to core/target/*.
      var dir = Directory.current;
      for (var i = 0; i < 4; i++) {
        for (final prof in ['release', 'debug']) {
          candidates.add('${dir.path}/core/target/$prof/$name');
        }
        dir = dir.parent;
      }
    }
  }
  Object? lastError;
  for (final c in candidates) {
    try {
      final lib = DynamicLibrary.open(c);
      lumoraLoadedLibraryPath ??= c.contains(Platform.pathSeparator) || c.contains('/') ? File(c).absolute.path : c;
      return lib;
    } catch (e) {
      lastError = e;
    }
  }
  throw ArgumentError('Cannot load $name: $lastError');
}

class _Bindings {
  _Bindings(DynamicLibrary lib)
      : start = lib.lookupFunction<_StartC, _StartD>('lumora_start'),
        request = lib.lookupFunction<_RequestC, _RequestD>('lumora_request'),
        nextEvent = lib.lookupFunction<_NextEventC, _NextEventD>('lumora_next_event'),
        frame = lib.lookupFunction<_FrameC, _FrameD>('lumora_frame'),
        free = lib.lookupFunction<_FreeC, _FreeD>('lumora_free'),
        lastError = lib.lookupFunction<_LastErrC, _LastErrD>('lumora_last_error'),
        lastErrorJson = lib.providesSymbol('lumora_last_error_json') ? lib.lookupFunction<_LastErrC, _LastErrD>('lumora_last_error_json') : null,
        stop = lib.lookupFunction<_StopC, _StopD>('lumora_stop'),
        needsPassphrase = _lookupNeedsPass(lib),
        phraseMatches = lib.providesSymbol('lumora_phrase_matches')
            ? lib.lookupFunction<_PhraseMatchC, _PhraseMatchD>('lumora_phrase_matches')
            : null;

  static _NeedsPassD? _lookupNeedsPass(DynamicLibrary lib) {
    if (!lib.providesSymbol('lumora_needs_passphrase')) return null;
    return lib.lookupFunction<_NeedsPassC, _NeedsPassD>('lumora_needs_passphrase');
  }

  final _StartD start;
  final _RequestD request;
  final _NextEventD nextEvent;
  final _FrameD frame;
  final _FreeD free;
  final _LastErrD lastError;
  final _LastErrD? lastErrorJson;
  final _StopD stop;
  final _NeedsPassD? needsPassphrase;
  final _PhraseMatchD? phraseMatches;

  String takeString(Pointer<Utf8> p) {
    if (p == nullptr) return '';
    try {
      return p.toDartString();
    } finally {
      free(p);
    }
  }

  /// JSON `{"error","code","detail"}` when the library provides it, else the plain text.
  String lastErrorString() {
    final j = lastErrorJson;
    if (j != null) {
      final p = j();
      if (p != nullptr) return p.toDartString();
    }
    final p = lastError();
    return p == nullptr ? 'internal' : p.toDartString();
  }
}

// ---------------------------------------------------------------------------
// Worker isolate protocol
// ---------------------------------------------------------------------------

class _WorkerInit {
  _WorkerInit(this.libPath, this.reply, this.pollEvents);
  final String? libPath;
  final SendPort reply;
  final bool pollEvents;
}

/// Entry point of a request worker or the event pump.
void _workerMain(_WorkerInit init) {
  final b = _Bindings(openLumoraLibrary(init.libPath));
  if (init.pollEvents) {
    final control = ReceivePort();
    init.reply.send(control.sendPort);
    var running = true;
    control.listen((msg) {
      if (msg == 'stop') running = false;
    });
    // Poll loop. Each call blocks ≤200ms in native code, then we yield to the
    // event loop so the 'stop' message can be processed.
    Future<void> loop() async {
      while (running) {
        final p = b.nextEvent(200);
        if (p != nullptr) {
          init.reply.send(b.takeString(p));
        } else {
          await Future<void>.delayed(Duration.zero);
        }
      }
      control.close();
      Isolate.exit();
    }

    loop();
    return;
  }

  final port = ReceivePort();
  init.reply.send(port.sendPort);
  port.listen((msg) {
    if (msg is List && msg.length == 3) {
      final kind = msg[0] as String;
      final payload = msg[1] as String;
      final SendPort out = msg[2] as SendPort;
      final arg = payload.toNativeUtf8();
      try {
        if (kind == 'start') {
          final rc = b.start(arg);
          // 1 = already running. On Android the node lives in the process,
          // which the foreground service keeps alive after the Activity (and
          // its Flutter engine) is destroyed; a re-created UI just re-attaches.
          final ok = rc == 0 || (rc == 1 && Platform.isAndroid);
          out.send(ok ? '' : '!${b.lastErrorString()}');
        } else if (kind == 'stop') {
          b.stop();
          out.send('');
        } else {
          out.send(b.takeString(b.request(arg)));
        }
      } catch (e) {
        out.send('!$e');
      } finally {
        malloc.free(arg);
      }
    } else if (msg == 'exit') {
      port.close();
    }
  });
}

/// One request worker isolate and the calls waiting on it.
class _Worker {
  _Worker(this.isolate, this.port, this.exitPort);
  final Isolate isolate;
  final SendPort port;
  final ReceivePort exitPort;
  final Set<Completer<String>> pending = {};

  /// Native calls running on this worker right now — including ones whose
  /// Dart caller already gave up (timeout): the isolate stays blocked in the
  /// core until the call returns, so it is busy until then.
  int inFlight = 0;

  /// Fails every waiting call (the worker died or the core stopped).
  void fail(String code) {
    for (final c in pending.toList()) {
      if (!c.isCompleted) c.complete('!$code');
    }
    pending.clear();
    inFlight = 0;
  }
}

class FfiLumoraApi extends LumoraApi {
  FfiLumoraApi._(this._lib, this._libPath) : _b = _Bindings(_lib);

  /// Loads the native library synchronously (throws if it is missing) so
  /// callers can fall back to the mock.
  factory FfiLumoraApi.load({String? libPath}) {
    final lib = openLumoraLibrary(libPath);
    return FfiLumoraApi._(lib, libPath);
  }

  // ignore: unused_field
  final DynamicLibrary _lib;
  final String? _libPath;
  final _Bindings _b;

  // Two lanes of request workers so slow commands (sending files, exports,
  // look-ups over the network…) never starve quick ones (messages, UI data).
  static const _fastWorkers = 2;
  static const _slowWorkers = 1;
  final List<_Worker> _fast = [];
  final List<_Worker> _slow = [];
  Future<void>? _spawning;
  bool _stopping = false;
  Isolate? _eventIsolate;
  SendPort? _eventControl;
  ReceivePort? _eventPort;
  ReceivePort? _eventExitPort;
  int _nextId = 1;
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  /// Default per-command timeout.
  static const defaultTimeout = Duration(seconds: 30);

  /// Commands that legitimately take long; they run on the slow lane.
  static const _longCommands = {
    'send_file': Duration(minutes: 5),
    // multi-device: finding + authenticating the new device, then signing its certificate
    'link_scan': Duration(minutes: 1),
    'link_approve': Duration(minutes: 1),
    'link_start': Duration(seconds: 30),
    'link_invite': Duration(seconds: 30),
    'device_promote': Duration(minutes: 1),
    'device_revoke': Duration(minutes: 1),
    'device_logout': Duration(seconds: 30),
    'send_voice': Duration(minutes: 2),
    'accept_file': Duration(minutes: 2),
    'sticker_pack_export': Duration(minutes: 5),
    'sticker_pack_import': Duration(minutes: 5),
    'sticker_pack_create': Duration(minutes: 2),
    'sticker_add': Duration(minutes: 2),
    'maintain': Duration(minutes: 5),
    'clear_media': Duration(minutes: 2),
    'set_storage_policy': Duration(minutes: 2),
    'export_backup': Duration(minutes: 5),
    'change_passphrase': Duration(minutes: 5),
    'clear_history': Duration(minutes: 2),
    'group_clear_history': Duration(minutes: 2),
    'delete_conversation': Duration(minutes: 2),
    'storage_stats': Duration(minutes: 2),
    'diagnostics': Duration(minutes: 2),
    'search': Duration(minutes: 1),
    'search_groups': Duration(minutes: 1),
    'lookup': Duration(minutes: 1),
    'resolve_username': Duration(minutes: 1),
    'join_invite': Duration(minutes: 1),
    'join_public': Duration(minutes: 1),
    'remote_connect': Duration(minutes: 1),
    'post_story': Duration(minutes: 2),
  };

  final Pointer<Uint32> _fw = calloc<Uint32>();
  final Pointer<Uint32> _fh = calloc<Uint32>();
  final Pointer<Uint64> _fseq = calloc<Uint64>();
  final Map<int, int> _lastSeq = {};

  @override
  bool get isMock => false;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  Future<_Worker> _spawnWorker(List<_Worker> lane) async {
    final rp = ReceivePort();
    final exit = ReceivePort();
    final iso = await Isolate.spawn(_workerMain, _WorkerInit(_libPath, rp.sendPort, false),
        onExit: exit.sendPort, onError: exit.sendPort, errorsAreFatal: true);
    final port = await rp.first as SendPort;
    final w = _Worker(iso, port, exit);
    exit.listen((msg) {
      // onError delivers [error, stack]; onExit delivers null.
      if (msg is List && msg.isNotEmpty) debugPrint('Lumora: core worker error: ${msg.first}');
      w.fail(msg is List && msg.isNotEmpty ? 'worker_crashed' : 'worker_exited');
      lane.remove(w);
      exit.close();
    });
    lane.add(w);
    return w;
  }

  /// Spawns missing workers (also replaces ones that died).
  Future<void> _ensureWorkers() {
    if (_fast.length >= _fastWorkers && _slow.length >= _slowWorkers) return Future.value();
    return _spawning ??= () async {
      try {
        while (_fast.length < _fastWorkers) {
          await _spawnWorker(_fast);
        }
        while (_slow.length < _slowWorkers) {
          await _spawnWorker(_slow);
        }
      } finally {
        _spawning = null;
      }
    }();
  }

  /// Runs one blocking core call on a worker. [timeout] null = wait forever.
  Future<String> _call(String kind, String payload, {String cmd = '', bool slow = false, Duration? timeout = defaultTimeout}) async {
    if (_stopping && kind != 'stop') throw ApiException('core_stopped', cmd: cmd.isEmpty ? kind : cmd);
    await _ensureWorkers();
    final lane = slow ? _slow : _fast;
    if (lane.isEmpty) throw ApiException('worker_exited', cmd: cmd.isEmpty ? kind : cmd);
    // Least busy worker by native calls still running (a call that timed out
    // keeps its worker blocked): a stuck call doesn't hold up the next ones.
    final w = pickWorker(lane);
    final rp = ReceivePort();
    final c = Completer<String>();
    w.pending.add(c);
    w.inFlight++;
    var replied = false;
    rp.listen((m) {
      if (!replied) {
        replied = true;
        w.inFlight--;
      }
      if (!c.isCompleted) c.complete(m is String ? m : '!bad_reply');
      rp.close();
    });
    w.port.send([kind, payload, rp.sendPort]);
    try {
      return await (timeout == null ? c.future : c.future.timeout(timeout));
    } on TimeoutException {
      // The port stays open: the late reply marks the worker free again.
      throw ApiException('timeout', cmd: cmd.isEmpty ? kind : cmd);
    } finally {
      w.pending.remove(c);
      if (c.isCompleted) rp.close(); // timed out: kept open for the late reply
    }
  }

  /// The worker with the fewest native calls still running (ties: the first).
  @visibleForTesting
  static T pickWorker<T extends Object>(List<T> lane, [int Function(T w)? load]) {
    final f = load ?? (T w) => (w as _Worker).inFlight;
    return lane.reduce((a, b) => f(b) < f(a) ? b : a);
  }

  /// Config of the last successful [start] (for [restart]). It holds the data
  /// password for as long as the app runs, like the session that typed it.
  Map<String, dynamic>? _config;
  bool _restarting = false;

  @override
  Future<void> start(Map<String, dynamic> config) async {
    final original = Map<String, dynamic>.of(config);
    if (Platform.isAndroid) config = {...config, ...await AndroidBridge.configOverrides(config)};
    _stopping = false;
    // Opening an encrypted database can take a while on slow devices.
    final res = await _call('start', jsonEncode(config), cmd: 'start', timeout: const Duration(minutes: 2));
    if (res.startsWith('!')) throw _failure(res.substring(1), 'start');
    _config = original;
    await _startEventPump();
    // Android: foreground service, multicast lock, screen/input bridge.
    if (Platform.isAndroid) await AndroidBridge.instance.attach(this);
    if (Platform.isIOS) await AppleServices.instance.attach(this);
  }

  Future<void> _startEventPump() async {
    if (_eventIsolate != null) return;
    final rp = ReceivePort();
    _eventPort = rp;
    final exit = ReceivePort();
    _eventExitPort = exit;
    _eventIsolate = await Isolate.spawn(_workerMain, _WorkerInit(_libPath, rp.sendPort, true), onExit: exit.sendPort, onError: exit.sendPort);
    exit.listen((msg) {
      if (msg is List && msg.isNotEmpty) debugPrint('Lumora: event pump error: ${msg.first}');
      if (msg != null && msg is! List) return;
      exit.close();
      rp.close();
      _eventIsolate = null;
      _eventControl = null;
      // Unexpected exit (not stop()): restart the pump so events keep flowing.
      if (!_stopping) _startEventPump();
    });
    rp.listen((msg) {
      if (msg is SendPort) {
        _eventControl = msg;
      } else if (msg is String && msg.isNotEmpty) {
        Map<String, dynamic>? ev;
        try {
          final j = jsonDecode(msg);
          if (j is Map) ev = j.cast<String, dynamic>();
        } catch (_) {
          // Malformed event: ignore.
        }
        if (ev == null || _events.isClosed) return;
        _events.add(ev);
        // Multi-device: the device now belongs to an account (linked, or made
        // the main device). The core asks to be started again so it comes up
        // with its new identity.
        final data = ev['data'] is Map ? (ev['data'] as Map) : ev;
        if (ev['event'] == 'link_state' && data['state'] == 'restart') {
          unawaited(restart(overrides: const {'link_pending': false}, reason: '${data['reason'] ?? 'linked'}'));
        }
      }
    });
  }

  @override
  Future<dynamic> request(String cmd, [Map<String, dynamic> args = const {}]) async {
    final id = _nextId++;
    final req = <String, dynamic>{'id': id, 'cmd': cmd, ...args};
    final long = _longCommands[cmd];
    final res = await _call('request', jsonEncode(req), cmd: cmd, slow: long != null, timeout: long ?? defaultTimeout);
    if (res.startsWith('!')) throw _failure(res.substring(1), cmd);
    if (res.isEmpty) throw ApiException('internal', cmd: cmd, code: 'internal', detail: 'empty response');
    final j = jsonDecode(res);
    if (j is! Map) throw ApiException('internal', cmd: cmd, code: 'internal', detail: 'malformed response');
    if (j['ok'] != true) throw ApiException.fromJson(j, cmd: cmd);
    return j['data'];
  }

  /// A worker failure: the core's error JSON, or a raw (technical) message
  /// that is only kept as detail.
  static ApiException _failure(String raw, String cmd) {
    if (raw.startsWith('{')) {
      try {
        final j = jsonDecode(raw);
        if (j is Map) return ApiException.fromJson(j, cmd: cmd);
      } catch (_) {}
    }
    return ApiException('internal', cmd: cmd, code: 'internal', detail: raw);
  }

  @override
  Future<FrameData?> frame(int stream) async {
    // One copy only: the core writes the frame straight into a fresh native
    // buffer that the returned bytes own (freed by a finalizer when the
    // frame is dropped) — no second copy into the Dart heap on the UI thread.
    var cap = _frameCaps[stream] ?? 1280 * 720 * 4;
    var buf = malloc<Uint8>(cap);
    final last = _lastSeq[stream] ?? 0;
    var n = _b.frame(stream, last, buf, cap, _fw, _fh, _fseq);
    if (n < 0) {
      // Buffer too small: -n bytes needed.
      malloc.free(buf);
      cap = -n;
      buf = malloc<Uint8>(cap);
      n = _b.frame(stream, last, buf, cap, _fw, _fh, _fseq);
    }
    if (n <= 0) {
      malloc.free(buf);
      return null;
    }
    _frameCaps[stream] = cap;
    _lastSeq[stream] = _fseq.value;
    return FrameData(_fw.value, _fh.value, buf.asTypedList(n, finalizer: malloc.nativeFree));
  }

  /// Last buffer size per stream (frames keep their size).
  final Map<int, int> _frameCaps = {};

  @override
  Future<int?> needsPassphrase(String dataDir) async {
    final f = _b.needsPassphrase;
    if (f == null) return null;
    final p = dataDir.toNativeUtf8();
    try {
      return f(p);
    } finally {
      malloc.free(p);
    }
  }

  @override
  Future<bool?> phraseMatches(String dataDir, String phrase) async {
    final f = _b.phraseMatches;
    if (f == null) return null;
    final d = dataDir.toNativeUtf8();
    final p = phrase.toNativeUtf8();
    try {
      final r = f(d, p);
      return r < 0 ? null : r == 1;
    } finally {
      // wipe the phrase from native memory before freeing it
      final n = p.length;
      p.cast<Uint8>().asTypedList(n).fillRange(0, n, 0);
      malloc.free(d);
      malloc.free(p);
    }
  }

  @override
  Future<void> restart({Map<String, dynamic> overrides = const {}, String reason = ''}) async {
    final cfg = _config;
    if (cfg == null || _restarting) return;
    _restarting = true;
    try {
      await _shutdown();
      await start({...cfg, ...overrides});
      if (!_events.isClosed) _events.add({'event': 'core_restarted', 'reason': reason});
    } catch (e) {
      debugPrint('Lumora: core restart failed: $e');
      final err = e is ApiException ? e : ApiException('internal', code: 'internal', detail: '$e');
      if (!_events.isClosed) {
        _events.add({'event': 'core_restarted', 'reason': reason, 'ok': false, 'error': err.message, 'code': err.code});
      }
    } finally {
      _restarting = false;
    }
  }

  @override
  Future<void> halt() => _shutdown();

  /// Stops the node, the event pump and the workers; [events] stays open so
  /// the core can be started again.
  Future<void> _shutdown() async {
    if (Platform.isAndroid) await AndroidBridge.instance.detach();
    if (Platform.isIOS) await AppleServices.instance.detach();
    _stopping = true;
    try {
      await _call('stop', '', cmd: 'stop', timeout: const Duration(seconds: 10));
    } catch (_) {}
    // Wait for the event pump to leave its poll loop so it can't take an
    // event meant for the next start.
    final pumpExit = _eventExitPort;
    final exited = Completer<void>();
    if (pumpExit != null && _eventIsolate != null) {
      _eventIsolate!.addOnExitListener(_exitSignal(exited));
    } else {
      exited.complete();
    }
    _eventControl?.send('stop');
    await exited.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    _eventPort?.close();
    _eventExitPort?.close();
    _eventIsolate = null;
    _eventControl = null;
    for (final w in [..._fast, ..._slow]) {
      w.fail('core_stopped');
      w.exitPort.close();
      w.port.send('exit');
      w.isolate.kill(priority: Isolate.beforeNextEvent);
    }
    _fast.clear();
    _slow.clear();
  }

  static SendPort _exitSignal(Completer<void> done) {
    final rp = ReceivePort();
    rp.listen((_) {
      if (!done.isCompleted) done.complete();
      rp.close();
    });
    return rp.sendPort;
  }

  @override
  Future<void> stop() async {
    await _shutdown();
    await _events.close();
  }
}

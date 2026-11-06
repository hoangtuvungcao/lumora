import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HardwareKeyboard, KeyEvent;
import 'package:flutter/widgets.dart';

import '../core/api.dart';
import 'settings.dart';

/// App lock (PIN). Only a salted PBKDF2-HMAC-SHA256 hash of the PIN is kept,
/// together with the wrong-PIN counters, in the core's encrypted database
/// (`ui_secret` "ui.pin"); [Settings] holds them in memory and only stores the
/// non-secret "a PIN exists" flag. The lock screen covers the UI on start and
/// when the app comes back after the chosen auto-lock delay.
class AppLock extends ChangeNotifier with WidgetsBindingObserver {
  AppLock(this.settings, {DateTime Function()? clock, Duration Function()? uptime, this.api}) : _clock = clock ?? DateTime.now {
    // Monotonic time for the wrong-PIN wait: changing the system clock must
    // not end it early. Tests with a fake clock get a matching fake uptime.
    if (uptime != null) {
      _uptime = uptime;
    } else if (clock != null) {
      final t0 = clock();
      _uptime = () => clock().difference(t0);
    } else {
      final sw = Stopwatch()..start();
      _uptime = () => sw.elapsed;
    }
    locked = settings.appLock;
    // without a core (tests) the in-memory values are all there is
    _secretsReady = api == null || settings.legacyPinSecrets || !settings.pinSet;
    _migrateCounters();
    _armWait();
  }

  /// Older versions counted rounds of 5 (`level`) plus tries in the round.
  void _migrateCounters() {
    if (settings.pinLockLevel > 0) {
      settings.pinFails += settings.pinLockLevel * maxTries;
      settings.pinLockLevel = 0;
    }
  }

  /// A wait saved by an earlier run (wall-clock deadline): it kept running
  /// while the app was closed. From now on it is also tracked on the
  /// monotonic clock, so moving the clock forward can't end it early; a
  /// clock moved back can't stretch it past this step's wait.
  void _armWait() {
    final left = settings.pinLockUntil - _clock().millisecondsSinceEpoch;
    if (left <= 0) return;
    _waitEnd = _uptime() + Duration(milliseconds: math.min(left, _currentWaitSec * 1000));
  }

  final Settings settings;
  final DateTime Function() _clock;
  late final Duration Function() _uptime;

  /// End of the current wait on the monotonic clock (this process only).
  Duration? _waitEnd;

  /// The owner proved who they are in this run (PIN, passphrase, new PIN).
  bool _proven = false;

  /// Key of the locked-chats list in the core (kept apart from the PIN so a
  /// long list never pushes the PIN record over the 4 KB value limit).
  static const String chatsKey = 'ui.locked_chats';

  /// Where the PIN secrets are kept (null: memory only, e.g. tests).
  final LumoraApi? api;

  static const String secretKey = 'ui.pin';

  /// The PIN hash is known (read from the core, or nothing to read).
  bool get ready => _secretsReady;
  bool _secretsReady = true;

  /// Reads the PIN secrets from the core once it runs; moves secrets that an
  /// older version left in the plain settings file into the core (and drops
  /// them from the file).
  Future<void> loadSecrets() async {
    final a = api;
    if (a == null) return;
    String? raw, chatsRaw;
    try {
      raw = await a.uiSecretGet(secretKey);
      chatsRaw = await a.uiSecretGet(chatsKey);
    } catch (_) {
      // older core without ui_secret: keep the file-based values
      _secretsReady = true;
      notifyListeners();
      return;
    }
    final wasLegacy = settings.legacyPinSecrets;
    final fileHash = settings.pinHash;
    var saveChats = false;
    // The core's encrypted copy wins over the plain settings file, which
    // anyone with access to the folder can edit (lock switch, locked chats).
    if (chatsRaw != null) {
      try {
        final list = (jsonDecode(chatsRaw) as List).map((e) => '$e').toList();
        settings.lockedChats = list;
      } catch (_) {}
    } else if (settings.lockedChats.isNotEmpty) {
      saveChats = true; // first run with this version: move the list in
    }
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        settings.pinHash = j['hash'] as String? ?? '';
        final len = j['len'];
        if (len is int && len >= 4 && len <= 12) settings.pinLength = len;
        settings.pinFails = j['fails'] as int? ?? 0;
        settings.pinLockUntil = j['until'] as int? ?? 0;
        settings.pinLockLevel = j['level'] as int? ?? 0;
        if (j['on'] is bool) settings.appLockEnabled = j['on'] as bool;
        _tryKey = j['k'] as String? ?? '';
        _wrong = ((j['wrong'] as List?) ?? const []).map((e) => '$e').toList();
        _pending = j['pending'] as String?;
      } catch (_) {}
      // A hash planted in the old file format is not the real one: anything
      // it unlocked before the core answered is locked again.
      if (wasLegacy && fileHash != settings.pinHash) _proven = false;
    } else if (settings.legacyPinSecrets && settings.pinHash.isNotEmpty) {
      try {
        await a.uiSecretSet(secretKey, _secretsJson());
      } catch (_) {
        return; // try again next start; the file keeps them meanwhile
      }
    } else {
      settings.pinHash = '';
    }
    _secretsReady = true;
    _migrateCounters();
    _armWait();
    settings.update((s) {
      s.legacyPinSecrets = false;
      s.pinSet = s.pinHash.isNotEmpty;
    });
    if (saveChats) _saveChats();
    if (!settings.appLock && locked) locked = false;
    // Lock unless the owner already proved who they are in this run.
    if (settings.appLock && !_proven) {
      locked = true;
      chatsOpen = false;
    }
    if (waitSeconds > 0) _startTick();
    notifyListeners();
  }

  String _secretsJson() => jsonEncode({
        'v': 2,
        'hash': settings.pinHash,
        // the length travels with the hash (one record): the pad never
        // expects a length that doesn't match the stored PIN
        'len': settings.pinLength,
        // different wrong PINs so far (since the last right one)
        'fails': settings.pinFails,
        // wall-clock end of the current wait (keeps running while closed)
        'until': settings.pinLockUntil,
        'on': settings.appLockEnabled,
        if (_tryKey.isNotEmpty) 'k': _tryKey,
        if (_wrong.isNotEmpty) 'wrong': _wrong,
        if (_pending != null) 'pending': _pending,
      });

  /// Per-install random key for the try fingerprints below (base64).
  String _tryKey = '';

  /// Fingerprints (keyed HMAC, never the PIN) of the last few different
  /// wrong PINs: typing the same wrong PIN again doesn't count again.
  List<String> _wrong = [];
  static const int _wrongKept = 8;

  /// Fingerprint of the try being checked right now. Saved (and counted)
  /// before the slow check: if the app dies meanwhile the try stays counted
  /// (no free guesses by killing the app), but typing that same PIN again
  /// doesn't count it twice, and a right PIN clears everything.
  String? _pending;

  String _fingerprint(String pin) {
    if (_tryKey.isEmpty) _tryKey = base64.encode(_salt());
    final mac = Hmac(sha256, base64.decode(_tryKey)).convert(utf8.encode('lumora-pin-try:$pin'));
    return base64.encode(mac.bytes.sublist(0, 16));
  }

  void _clearTries() {
    _wrong = [];
    _pending = null;
  }

  /// Persists the PIN secrets in the core (best effort).
  void _saveSecrets() => unawaited(_saveSecretsNow());

  /// Same, but the caller can wait until the core has it.
  Future<void> _saveSecretsNow() async {
    try {
      await _writeSecrets();
    } catch (_) {}
  }

  /// Writes the PIN record (hash, length, counters) to the core; throws when
  /// the core couldn't save it.
  Future<void> _writeSecrets() async {
    final a = api;
    if (a == null || settings.legacyPinSecrets) return;
    await a.uiSecretSet(secretKey, settings.pinHash.isEmpty ? null : _secretsJson());
  }

  /// Persists the locked-chats list in the core (best effort; the file keeps
  /// a copy for older cores).
  void _saveChats() {
    final a = api;
    if (a == null) return;
    a.uiSecretSet(chatsKey, settings.lockedChats.isEmpty ? null : jsonEncode(settings.lockedChats)).catchError((_) {});
  }

  /// Tries without any wait.
  static const int maxTries = 5;
  static const int baseWaitSec = 30;

  /// Waits after the 6th, 7th … different wrong PIN; then 1 hour each.
  static const List<int> _waits = [30, 60, 300, 900];
  static const int maxWaitSec = 3600;

  /// Different wrong PINs after which only the recovery phrase unlocks.
  static const int maxWrong = 50;

  /// Wait (seconds) after [fails] different wrong PINs.
  static int waitAfter(int fails) => fails < maxTries ? 0 : (fails - maxTries < _waits.length ? _waits[fails - maxTries] : maxWaitSec);


  /// Rounds for new PIN hashes: PBKDF2-HMAC-SHA512 × 210 000 (OWASP's figure
  /// for SHA-512), computed in a background isolate. A 4–6 digit PIN can't be
  /// made strong by any KDF alone; this slows offline guessing of a stolen
  /// record, the 50-try cap and the encrypted store do the rest. Tests lower
  /// it (test/flutter_test_config.dart).
  static int kdfIterations = 210000;
  static const String kdfAlg = 'pbkdf2-sha512';

  /// Up to this many rounds a hash is computed inline (old 12k records, tests).
  static const int _inlineMax = 20000;

  /// A PIN is being checked or hashed right now (screens show a small
  /// progress line and take no input).
  bool verifying = false;

  /// A PIN being set (its hash still computing): checks wait for it.
  Future<void>? _pinWrite;

  /// The lock screen is showing.
  bool locked = false;

  /// The "Locked" chats folder has been opened with the PIN (until the app
  /// is left or locked again).
  bool chatsOpen = false;
  DateTime? _leftAt;
  Duration? _leftUp;
  bool _observing = false;

  /// Mobile: the app is in the app switcher / covered; the lock layer draws a
  /// plain cover so the recent-apps preview shows no chats.
  bool obscured = false;
  Timer? _tick;

  bool get enabled => settings.appLock;

  void attach() {
    if (_observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
    if (isDesktopPlatform) {
      HardwareKeyboard.instance.addHandler(_onKey);
      settings.addListener(_armIdle);
      _armIdle();
    }
  }

  /// Stops observing the app lifecycle (services shut down).
  void detach() {
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      if (isDesktopPlatform) {
        HardwareKeyboard.instance.removeHandler(_onKey);
        settings.removeListener(_armIdle);
      }
    }
    _observing = false;
    _tick?.cancel();
    _tick = null;
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  // ------------------------------------------------ desktop idle lock

  /// Windows, macOS, Linux: the window usually stays open, so "left the app"
  /// never happens — lock after [Settings.idleLockMin] idle minutes instead.
  static bool get isDesktopPlatform => !kIsWeb &&
      (debugDesktopOverride ??
          (defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.macOS));
  @visibleForTesting
  static bool? debugDesktopOverride;

  Duration _lastActive = Duration.zero;
  Timer? _idleTimer;

  /// Mouse or keyboard use (the app reports pointer events, see LumoraApp).
  void noteActivity() => _lastActive = _uptime();

  bool _onKey(KeyEvent e) {
    noteActivity();
    return false; // never consumes the key
  }

  void _armIdle() {
    final want = isDesktopPlatform && enabled && settings.idleLockMin > 0;
    if (want && _idleTimer == null) {
      noteActivity();
      _idleTimer = Timer.periodic(const Duration(seconds: 15), (_) => checkIdle());
    } else if (!want && _idleTimer != null) {
      _idleTimer!.cancel();
      _idleTimer = null;
    }
  }

  /// Locks when idle for longer than the setting (called by the timer).
  @visibleForTesting
  void checkIdle() {
    if (!enabled || locked || settings.idleLockMin <= 0) return;
    if (_uptime() - _lastActive >= Duration(minutes: settings.idleLockMin)) lock();
  }

  /// "Khoá ngay" (Ctrl+L): false when there is no app lock to engage.
  bool lockNow() {
    if (!enabled) return false;
    lock();
    return true;
  }

  @override
  void dispose() {
    detach();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.hidden || state == AppLifecycleState.paused) && chatsOpen) {
      chatsOpen = false;
      notifyListeners();
    }
    if (!enabled) {
      _setObscured(false);
      return;
    }
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _leftAt ??= _clock();
        _leftUp ??= _uptime();
        _setObscured(_mobile);
        // "Immediately": lock right away so the app switcher / next resume
        // never shows content.
        if (settings.autoLockSec == 0) lock();
      case AppLifecycleState.resumed:
        final left = _leftAt, leftUp = _leftUp;
        _leftAt = null;
        _leftUp = null;
        if (left != null) {
          final wall = _clock().difference(left);
          final up = _uptime() - (leftUp ?? Duration.zero);
          // The monotonic time can't be wound back; a wall clock that went
          // backwards while away is treated as "long enough".
          if (wall.isNegative || wall.inSeconds >= settings.autoLockSec || up.inSeconds >= settings.autoLockSec) lock();
        }
        _setObscured(false);
      case AppLifecycleState.inactive:
        _setObscured(_mobile);
      case AppLifecycleState.detached:
        break;
    }
  }

  static bool get _mobile => defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

  void _setObscured(bool v) {
    if (obscured == v) return;
    obscured = v;
    notifyListeners();
  }

  /// The user just proved who they are another way (passphrase at start).
  void markUnlocked() {
    _proven = true;
    if (!locked) return;
    locked = false;
    notifyListeners();
  }

  void lock() {
    if (!enabled || locked) return;
    locked = true;
    chatsOpen = false;
    notifyListeners();
  }

  // ------------------------------------------------------------ chat lock

  bool get hasPin => settings.hasPin;
  bool isChatLocked(String conv) => settings.lockedChats.contains(conv);

  /// Hidden right now (locked and the folder not opened).
  bool isChatHidden(String conv) => !chatsOpen && settings.lockedChats.contains(conv);

  void setChatLocked(String conv, bool on) {
    settings.update((s) {
      s.lockedChats = on ? {...s.lockedChats, conv}.toList() : s.lockedChats.where((c) => c != conv).toList();
    });
    _saveChats();
    notifyListeners();
  }

  void openLockedChats() {
    chatsOpen = true;
    notifyListeners();
  }

  void hideLockedChats() {
    chatsOpen = false;
    notifyListeners();
  }

  // ------------------------------------------------------------ PIN checks

  /// Seconds left before another try is allowed (0 = may try now). The
  /// longer of the saved wall-clock end (survives restarts) and the
  /// monotonic end (immune to clock changes in this run); a clock moved far
  /// back can't stretch it past the length of the current wait.
  int get waitSeconds {
    var left = settings.pinLockUntil - _clock().millisecondsSinceEpoch;
    if (left > 0) left = math.min(left, _currentWaitSec * 1000);
    final end = _waitEnd;
    if (end != null) left = math.max(left, (end - _uptime()).inMilliseconds);
    return left <= 0 ? 0 : (left / 1000).ceil();
  }

  /// Length of the current wait (for the countdown ring).
  int get currentWaitSec => _currentWaitSec;
  int get _currentWaitSec => waitAfter(settings.pinFails);

  int get triesLeft => math.max(0, maxTries - settings.pinFails);

  /// Too many wrong PINs: the PIN no longer unlocks, only the recovery phrase.
  bool get exhausted => settings.pinFails >= maxWrong;

  /// Checks a submitted [pin]; unlocks on success. Only submitted PINs count,
  /// each different wrong PIN once: tries 1–5 are free, then the wait is
  /// 30 s, 1 min, 5 min, 15 min and 1 hour from then on; after [maxWrong]
  /// different wrong PINs only the recovery phrase unlocks. Nothing is ever
  /// deleted because of wrong PINs.
  ///
  /// A new try is counted and saved in the core BEFORE the (slow) check runs
  /// and cleared when the PIN was right: killing the app while the check runs
  /// can't give a free guess.
  Future<bool> tryUnlock(String pin) async {
    final busy = _pinWrite;
    if (busy != null) await busy.catchError((_) {});
    // the PIN hash is still being read from the core: not a wrong try
    if (!_secretsReady || waitSeconds > 0 || exhausted || verifying) return false;
    final stored = settings.pinHash;
    final fp = _fingerprint(pin);
    // the same wrong PIN again: still wrong, not counted again
    if (_wrong.contains(fp)) return false;
    verifying = true;
    if (_pending != fp) {
      // (a different try left pending by a crash stays counted)
      _pending = fp;
      _countWrongTry();
    }
    notifyListeners();
    await _saveSecretsNow();
    bool ok;
    try {
      ok = await checkPinAsync(pin, stored);
    } catch (_) {
      ok = false;
    }
    verifying = false;
    _pending = null;
    if (ok) {
      _proven = true;
      _waitEnd = null;
      _clearTries();
      settings.update((s) {
        s.pinFails = 0;
        s.pinLockLevel = 0;
        s.pinLockUntil = 0;
      });
      _saveSecrets();
      locked = false;
      notifyListeners();
      // older / weaker record: re-hash with today's KDF now that the PIN is known
      if (needsRehash(stored)) unawaited(_rehash(pin, stored));
      return true;
    }
    _wrong = [..._wrong.where((x) => x != fp), fp];
    if (_wrong.length > _wrongKept) _wrong = _wrong.sublist(_wrong.length - _wrongKept);
    _saveSecrets();
    _startTick();
    notifyListeners();
    return false;
  }

  void _countWrongTry() {
    settings.update((s) {
      s.pinFails++;
      s.pinLockLevel = 0;
      final wait = waitAfter(s.pinFails);
      if (wait > 0 && s.pinFails < maxWrong) {
        s.pinLockUntil = _clock().millisecondsSinceEpoch + wait * 1000;
        _waitEnd = _uptime() + Duration(seconds: wait);
      }
    });
  }

  Future<void> _rehash(String pin, String old) async {
    try {
      final h = await hashPinAsync(pin);
      if (settings.pinHash != old) return; // changed meanwhile
      settings.update((s) => s.pinHash = h);
      _saveSecrets();
    } catch (_) {}
  }

  void _startTick() {
    _tick?.cancel();
    if (waitSeconds <= 0) return;
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (waitSeconds <= 0) t.cancel();
      notifyListeners();
    });
  }

  /// Re-arms the countdown (lock screen shown while a wait is running).
  void resumeCountdown() => _startTick();

  Future<bool> verify(String pin) => checkPinAsync(pin, settings.pinHash);

  /// Sets (or changes) the PIN. [appLock] null keeps the app-lock switch as is.
  /// Everything but the hash applies at once; the hash is computed in the
  /// background (PIN checks wait for it) and then saved in the core.
  ///
  /// The new hash and its length are written to the core as one record; the
  /// returned future completes once it is saved. If saving fails the old PIN
  /// (hash, length, lock switch) is put back and the future throws — callers
  /// must not lock anything with a PIN that wasn't saved.
  Future<void> setPin(String pin, {bool? appLock = true}) {
    final old = (set: settings.pinSet, len: settings.pinLength, hash: settings.pinHash, on: settings.appLockEnabled,
        fails: settings.pinFails, level: settings.pinLockLevel, until: settings.pinLockUntil);
    settings.update((s) {
      s.pinSet = true;
      s.pinLength = pin.length;
      if (appLock != null) s.appLockEnabled = appLock;
      s.pinFails = 0;
      s.pinLockLevel = 0;
      s.pinLockUntil = 0;
    });
    _clearTries();
    _proven = true;
    _waitEnd = null;
    _secretsReady = true;
    locked = false;
    verifying = true;
    notifyListeners();
    late final Future<void> f;
    f = () async {
      try {
        final h = await hashPinAsync(pin);
        settings.update((s) => s.pinHash = h);
        try {
          await _writeSecrets();
        } catch (_) {
          // Not saved: the core still holds the old record — keep using it.
          settings.update((s) {
            s.pinSet = old.set;
            s.pinLength = old.len;
            s.pinHash = old.hash;
            s.appLockEnabled = old.on;
            s.pinFails = old.fails;
            s.pinLockLevel = old.level;
            s.pinLockUntil = old.until;
          });
          rethrow;
        }
      } finally {
        verifying = false;
        if (identical(_pinWrite, f)) _pinWrite = null;
        notifyListeners();
      }
    }();
    _pinWrite = f;
    // Callers that don't wait still get a consistent state; don't surface
    // the error as unhandled.
    f.catchError((_) {});
    return f;
  }

  /// Turns the whole-app lock on with the existing PIN.
  void enableAppLock() {
    settings.update((s) => s.appLockEnabled = true);
    _saveSecrets();
    notifyListeners();
  }

  /// Turns the whole-app lock off; the PIN stays while chats are locked.
  void disableAppLock() {
    settings.update((s) {
      s.appLockEnabled = false;
      if (s.lockedChats.isEmpty) {
        s.pinHash = '';
        s.pinSet = false;
      }
    });
    _saveSecrets();
    locked = false;
    notifyListeners();
  }

  /// Forgot PIN (recovery phrase checked): removes the PIN and unlocks
  /// every locked chat.
  void removePin() {
    chatsOpen = false;
    _proven = true;
    _waitEnd = null;
    _clearTries();
    settings.update((s) {
      s.pinHash = '';
      s.pinSet = false;
      s.appLockEnabled = true;
      s.lockedChats = [];
      s.pinFails = 0;
      s.pinLockLevel = 0;
      s.pinLockUntil = 0;
    });
    _saveSecrets();
    _saveChats();
    locked = false;
    notifyListeners();
  }

  // ------------------------------------------------------------ hashing

  static bool isValidPin(String pin) => RegExp(r'^\d{4,6}$').hasMatch(pin);

  static Uint8List _salt() {
    final r = math.Random.secure();
    return Uint8List.fromList(List.generate(16, (_) => r.nextInt(256)));
  }

  /// Synchronous hash (tests, small round counts). The app uses [hashPinAsync].
  static String hashPin(String pin, {Uint8List? salt, int? iterations, String alg = kdfAlg}) {
    final n = iterations ?? kdfIterations;
    final sl = salt ?? _salt();
    final h = pbkdf2(utf8.encode(pin), sl, n, 32, hash: alg == 'pbkdf2-sha256' ? sha256 : sha512);
    return '$alg\$$n\$${base64.encode(sl)}\$${base64.encode(h)}';
  }

  /// Hash for a new PIN with today's KDF, off the UI isolate.
  static Future<String> hashPinAsync(String pin) async {
    final n = kdfIterations;
    final sl = _salt();
    final h = await _derive(utf8.encode(pin), sl, n, 32, true);
    return '$kdfAlg\$$n\$${base64.encode(sl)}\$${base64.encode(h)}';
  }

  /// (sha512?, rounds, salt, digest) of a stored record; null if damaged.
  static (bool, int, Uint8List, Uint8List)? _parse(String stored) {
    final p = stored.split('\$');
    if (p.length != 4 || (p[0] != 'pbkdf2-sha256' && p[0] != 'pbkdf2-sha512')) return null;
    final iter = int.tryParse(p[1]) ?? 0;
    if (iter <= 0 || iter > 10000000) return null;
    final Uint8List salt, want;
    try {
      salt = base64.decode(p[2]);
      want = base64.decode(p[3]);
    } catch (_) {
      return null;
    }
    // A damaged or tampered record (no salt, empty/short digest) must never
    // match: with an empty digest the compare would accept any PIN.
    if (salt.length < 8 || want.length < 16 || want.length > 64) return null;
    return (p[0] == 'pbkdf2-sha512', iter, salt, want);
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static bool checkPin(String pin, String stored) {
    final r = _parse(stored);
    if (r == null) return false;
    final (wide, iter, salt, want) = r;
    return _same(want, pbkdf2(utf8.encode(pin), salt, iter, want.length, hash: wide ? sha512 : sha256));
  }

  /// [checkPin] off the UI isolate (large round counts).
  static Future<bool> checkPinAsync(String pin, String stored) async {
    final r = _parse(stored);
    if (r == null) return false;
    final (wide, iter, salt, want) = r;
    return _same(want, await _derive(utf8.encode(pin), salt, iter, want.length, wide));
  }

  /// The record was made with an older / weaker KDF than today's.
  static bool needsRehash(String stored) {
    final r = _parse(stored);
    return r != null && (!r.$1 || r.$2 < kdfIterations);
  }

  static Future<Uint8List> _derive(List<int> pw, List<int> salt, int iter, int len, bool wide) {
    if (iter <= _inlineMax) return Future.value(pbkdf2(pw, salt, iter, len, hash: wide ? sha512 : sha256));
    return compute(_kdfEntry, [pw, salt, iter, len, wide]);
  }

  static Uint8List _kdfEntry(List<Object> a) =>
      pbkdf2(a[0] as List<int>, a[1] as List<int>, a[2] as int, a[3] as int, hash: (a[4] as bool) ? sha512 : sha256);

  /// PBKDF2 with HMAC-SHA256 (default) or HMAC-SHA512 (RFC 8018).
  static Uint8List pbkdf2(List<int> password, List<int> salt, int iterations, int length, {Hash hash = sha256}) {
    final hmac = Hmac(hash, password);
    final out = BytesBuilder();
    for (var block = 1; out.length < length; block++) {
      var u = hmac.convert([...salt, block >> 24 & 0xff, block >> 16 & 0xff, block >> 8 & 0xff, block & 0xff]).bytes;
      final t = Uint8List.fromList(u);
      for (var i = 1; i < iterations; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      out.add(t);
    }
    return Uint8List.fromList(out.toBytes().sublist(0, length));
  }

  /// Recovery phrases compare case-, accent-spacing- and separator-insensitively.
  static String normalizePhrase(String s) =>
      s.toLowerCase().split(RegExp(r'[\s\-,.;]+')).where((w) => w.isNotEmpty).join(' ');
}

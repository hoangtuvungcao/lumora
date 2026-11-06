import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/api.dart';
import 'platform/android_bridge.dart';
import 'platform/apple_services.dart';
import 'platform/camera_bridge.dart';
import 'state/app_lock.dart';
import 'state/data_rescue.dart';
import 'state/devices_store.dart';
import 'state/moderation.dart';
import 'state/settings.dart';
import 'state/stores.dart';
import 'ui/calls/call_layer.dart';
import 'ui/devices/history_sync.dart';
import 'ui/devices/signed_out.dart';
import 'ui/lock/app_lock_screen.dart';
import 'ui/onboarding/lock_screen.dart';
import 'ui/onboarding/onboarding_screen.dart';
import 'ui/remote/remote_layer.dart';
import 'ui/shell/home_shell.dart';
import 'ui/theme.dart';
import 'l10n/strings.dart';
import 'ui/widgets/common.dart';
import 'ui/widgets/app_icons.dart';
import 'ui/widgets/logo.dart';
import 'ui/shell/reminder_banner.dart';

/// All long-lived objects of a running app instance.
class AppServices {
  AppServices({required this.api, required this.settings, this.dataDir = ''})
    : session = SessionStore(api),
      contacts = ContactsStore(api),
      chat = ChatStore(api),
      files = FilesStore(api),
      calls = CallStore(api),
      remote = RemoteStore(api),
      net = NetStore(api),
      spaces = SpacesStore(api),
      avatars = AvatarStore(api),
      notices = NotificationStore(),
      stories = StoryStore(api),
      devices = DevicesStore(api),
      moderation = ModerationStore(api),
      nav = NavStore() {
    camera = CameraBridge(calls);
    // The in-memory demo never asks for the camera (and tests run without a binding).
    if (!api.isMock) camera.attach();
    calls.onMissed = (c) => notices.add(Notice(kind: NoticeKind.missedCall, title: contacts.nameOf(c.peer), conv: c.conv, peer: c.peer));
    hub = EventHub(
      avatars: avatars,
      notices: notices,
      stories: stories,
      api: api,
      session: session,
      contacts: contacts,
      chat: chat,
      files: files,
      calls: calls,
      remote: remote,
      net: net,
      spaces: spaces,
      nav: nav,
    );
    hub.listeners.add(devices.onEvent);
    // reports / blocked groups / hidden members (synced between my devices)
    hub.listeners.add(moderation.onEvent);
    hub.loaders.add(moderation.load);
    hub.isHiddenMember = moderation.isHidden;
    moderation.onReport = (r) => notices.add(Notice(kind: NoticeKind.report, title: r.groupName, body: r.excerpt.isNotEmpty ? r.excerpt : r.memberName, conv: r.conv, peer: r.member, ref: r.id));
    moderation.onHandled = notices.removeRefs;
    moderation.onGroupBlocked = (gid) {
      final conv = 'g:$gid';
      if (chat.convs.containsKey(conv)) chat.onGroupRemoved(conv, left: true);
      if (nav.conv == conv) nav.openConv(null);
    };
    hub.listeners.add(_onDeviceEvent);
    appLock = AppLock(settings, api: api)..attach();
    hub.listeners.add(appLock.onCoreEvent); // locked chats changed on another device
    chat.lockedConvs = () => settings.lockedChats;
    nav.canRead = (conv) {
      final life = WidgetsBinding.instance.lifecycleState; // null: not reported yet
      final front = life == null || life == AppLifecycleState.resumed;
      return front && !appLock.locked && !appLock.isChatHidden(conv);
    };
    // Back in front / unlocked: the chat on screen reads what came meanwhile.
    try {
      _life = AppLifecycleListener(onResume: _readVisible);
    } catch (_) {} // no Flutter binding (plain unit tests)
    appLock.addListener(_readVisible);
    notices.filter = (n) => n.conv != null && settings.lockedChats.contains(n.conv) ? Notice(kind: NoticeKind.system, title: S(settings.locale != 'en')('locked_message'), conv: n.conv, ref: n.ref, ts: n.ts) : n;
    _syncPrivacy();
    settings.addListener(_syncPrivacy);
  }

  late final AppLock appLock;
  AppLifecycleListener? _life;

  void _readVisible() {
    final c = nav.readingConv;
    if (c != null && (chat.convs[c]?.unread ?? 0) > 0) chat.markRead(c);
  }

  /// Native video-call camera (Android/iOS/macOS/Windows), see camera_bridge.dart.
  late final CameraBridge camera;

  bool? _secure;
  bool? _hideRecents;

  /// Applies privacy preferences that live outside the widget tree: the
  /// Android screenshot block, notification privacy, copy & paste sync.
  void _syncPrivacy() {
    AndroidBridge.notificationsOn = settings.notifications;
    AndroidBridge.hideContent = settings.hideNotificationContent;
    AndroidBridge.lockedConvs = settings.lockedChats.toSet();
    AppleServices.lockedConvs = settings.lockedChats.toSet(); // CallKit / iOS notifications: no name
    AndroidBridge.isMuted = (c) => chat.convs[c]?.muted ?? false;
    AndroidBridge.convTitle = (c) => chat.convs[c]?.title;
    // Notifications in the app's language, not the phone's (no-op if unchanged).
    AndroidBridge.setLanguage(settings.locale);
    remote.setClipboardSync(settings.remoteClipboard);
    if (_secure != settings.blockScreenshots) {
      _secure = settings.blockScreenshots;
      AndroidBridge.setSecure(settings.blockScreenshots);
    }
    // App lock on: the recent-apps preview stays blank (Android 13+), while
    // screenshots and screen sharing keep working.
    if (_hideRecents != settings.appLock) {
      _hideRecents = settings.appLock;
      AndroidBridge.setRecentsHidden(settings.appLock);
    }
  }

  final LumoraApi api;
  final Settings settings;
  final String dataDir;
  final SessionStore session;
  final ContactsStore contacts;
  final ChatStore chat;
  final FilesStore files;
  final CallStore calls;
  final RemoteStore remote;
  final NetStore net;
  final SpacesStore spaces;
  final NavStore nav;
  final AvatarStore avatars;
  final NotificationStore notices;
  final StoryStore stories;
  final DevicesStore devices;
  final ModerationStore moderation;
  late final EventHub hub;

  /// The exception behind [SessionPhase.error] (technical details).
  Object? startupError;

  void dispose() {
    _loadRetry?.cancel();
    _historyReload?.cancel();
    settings.removeListener(_syncPrivacy);
    _life?.dispose();
    appLock.removeListener(_readVisible);
    remote.stopClipboardSync();
    appLock.detach();
    camera.dispose();
    hub.dispose();
    chat.dispose();
    devices.dispose();
    api.stop();
  }

  // ------------------------------------------------------------ multi-device

  /// The core is running in "waiting to be linked" mode (onboarding).
  bool linkCoreRunning = false;

  /// Onboarding "I already use Lumora on another device": starts the core with
  /// `link_pending: true` (once) so it can scan the other device's code.
  Future<void> startForLink() async {
    if (linkCoreRunning) return;
    settings.update((s) => s.linkPending = true);
    // Before anything is created: a half-made identity left by a crash or
    // a forced close is wiped at the next launch (see [boot]).
    _markOnboarding();
    await unlock(null, extra: const {'link_pending': true}, enter: false);
    linkCoreRunning = true;
  }

  // ------------------------------------------- unfinished onboarding

  /// Next to the data folder while an identity is being made (new account,
  /// restore, waiting to be linked); removed once it is complete.
  File? get _onboardingMarker => api.isMock || dataDir.isEmpty ? null : File('$dataDir.onboarding');

  void _markOnboarding() {
    try {
      final f = _onboardingMarker;
      if (f == null) return;
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('${DateTime.now().toIso8601String()}\n', flush: true);
    } catch (_) {}
  }

  void _clearOnboardingMarker() {
    try {
      final f = _onboardingMarker;
      if (f != null && f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Deletes an identity that was never completed (keystore + database), so
  /// the next create / restore starts from nothing — the core refuses to
  /// restore over existing data.
  void _wipeHalfMade() {
    if (api.isMock || dataDir.isEmpty) return;
    for (final f in ['keystore.json', 'lumora.db', 'lumora.db-wal', 'lumora.db-shm']) {
      try {
        final file = File('$dataDir${Platform.pathSeparator}$f');
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
  }

  /// At launch: an onboarding that never finished left a half-made identity.
  void _cleanUnfinishedOnboarding() {
    final f = _onboardingMarker;
    if (f == null || !f.existsSync()) return;
    _wipeHalfMade();
    _clearOnboardingMarker();
    settings.onboarded = false;
    settings.hasPassphrase = false;
  }

  /// Leaves the link step for "create" / "restore": the identity made while
  /// waiting to be linked is discarded so the next start is a fresh one.
  Future<void> abandonLink() async {
    final wasPending = settings.linkPending;
    settings.update((s) => s.linkPending = false);
    if (linkCoreRunning) {
      linkCoreRunning = false;
      await api.linkCancel().catchError((_) {});
      await api.halt().catchError((_) {});
      session.me = null;
    } else if (!wasPending) {
      return;
    }
    // Also when the link core isn't running (Lumora was reopened on the link
    // step): the identity made for linking must never become the account.
    _wipeHalfMade();
    _clearOnboardingMarker();
  }

  void _onDeviceEvent(String name, Map<String, dynamic> d) {
    if (name == 'core_restarted') {
      _afterCoreRestart(d['reason']?.toString() ?? '', ok: d['ok'] != false, error: d['error']?.toString());
    } else if (name == 'device_revoked') {
      _afterSignedOut();
    } else if (name == 'profile') {
      // the account profile changed underneath us: copied to a newly linked
      // device (it starts before the copy arrives) or edited on another device
      _reloadProfile();
    } else if (name == 'link_state' && d['state'] == 'state_synced') {
      // the account state arrived on this new device: name, avatar, devices
      _reloadProfile();
      unawaited(devices.load().catchError((_) {}));
    } else if (name == 'history_sync') {
      // older messages were imported without `message` events: chats that are
      // open read them (at most every 2 s while copying, and once when done)
      _historyReload?.cancel();
      _historyReload = Timer(d['done'] == true ? Duration.zero : const Duration(seconds: 2), () {
        unawaited(chat.reloadThreadsAfterImport());
      });
    }
  }

  Timer? _historyReload;

  void _reloadProfile() {
    unawaited(session.reloadMe().catchError((_) {}));
    unawaited(session.loadProfile());
  }

  /// The core came back after `link_state: restart` (now part of an account,
  /// or now the main device): reload everything as on a fresh unlock.
  Future<void> _afterCoreRestart(String reason, {bool ok = true, String? error}) async {
    if (!ok) {
      session.setPhase(SessionPhase.error, err: error ?? 'internal');
      return;
    }
    linkCoreRunning = false;
    try {
      await session.reloadMe();
      await appLock.loadSecrets();
    } catch (_) {}
    settings.update((s) {
      s.linkPending = false;
      s.onboarded = true;
      // the recovery phrase belongs to the account (shown on the main device)
      if (reason == 'linked' || reason == 'promoted') s.phraseBackedUp = true;
    });
    if (reason == 'linked' || reason == 'promoted') _clearOnboardingMarker();
    if (reason == 'linked') devices.historyDismissed = false;
    // the language is this device's own choice (the account's data was just reset)
    _lang = null;
    _syncLang();
    await devices.loadHistory();
    unawaited(devices.load());
    session.loadProfile();
    if (session.phase != SessionPhase.ready) session.setPhase(SessionPhase.ready);
    await hub.loadAll().catchError((_) {});
  }

  /// This device was signed out of the account: stop the core (its data is
  /// gone) and show the notice; "Start over" goes back to the welcome screen.
  Future<void> _afterSignedOut() async {
    // let the core finish telling the main device and wiping
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await api.halt().catchError((_) {});
    settings.update((s) {
      s.onboarded = false;
      s.hasPassphrase = false;
      s.phraseBackedUp = false;
      s.linkPending = false;
      s.lockedChats = [];
    });
  }

  /// "Start over" on the signed-out notice.
  void startOver() {
    devices.reset();
    session.me = null;
    session.setPhase(SessionPhase.onboarding);
  }

  /// Decides the first screen.
  Future<void> boot() async {
    // Finish a "switch data folder" that had to wait for a restart.
    await DataRescue.finishPending(this);
    _cleanUnfinishedOnboarding();
    // Ask the core whether an identity exists / is passphrase-protected.
    final np = await api.needsPassphrase(dataDir).catchError((_) => null);
    if (np != null) {
      settings.onboarded = np >= 0;
      settings.hasPassphrase = np == 1;
    }
    // "I already use Lumora on another device" was not finished: go on with it.
    if (settings.linkPending) settings.onboarded = false;
    if (!settings.onboarded) {
      session.setPhase(SessionPhase.onboarding);
    } else if (settings.hasPassphrase) {
      session.setPhase(SessionPhase.locked);
    } else {
      try {
        await unlock(null);
      } catch (e) {
        // plain code for the error screen; the raw text only as details
        session.setPhase(SessionPhase.error, err: e is ApiException ? e.message : 'internal');
        startupError = e;
      }
    }
  }

  /// Starts the core (throws [ApiException] on wrong passphrase etc.).
  Future<void> unlock(String? passphrase, {Map<String, dynamic> extra = const {}, bool enter = true}) async {
    hub.attach();
    // Don't show the home screen yet: the lock state (PIN, lock switch,
    // locked chats) is read from the core first, so a tampered settings file
    // can't flash chats before the lock engages.
    await session.start({...settings.coreConfig(dataDir: dataDir, passphrase: passphrase), ...extra}, enter: false);
    // the PIN hash lives in the core's encrypted database: read it now
    await appLock.loadSecrets();
    // The passphrase was just typed: don't ask for the PIN right after it.
    if (passphrase != null && passphrase.isNotEmpty) appLock.markUnlocked();
    if (enter) session.setPhase(SessionPhase.ready);
    _syncLang();
    settings.removeListener(_syncLang);
    settings.addListener(_syncLang);
    await _reconcileCoreSettings(adoptCore: extra.containsKey('restore_backup'));
    _coreSettings = _coreSettingsSnapshot();
    settings.removeListener(_syncCoreSettings);
    settings.addListener(_syncCoreSettings);
    // a newly linked device that was closed while copying history shows the
    // progress again
    // From here the core runs and the password was right: a list that fails
    // to load must not throw the session away — it is retried in the
    // background while a small banner says so.
    try {
      if (extra['link_pending'] != true) {
        unawaited(devices.load());
        await devices.loadHistory();
      }
      await hub.loadAll();
      loadProblem.value = null;
    } catch (e) {
      debugPrint('Lumora: loading after start failed: $e');
      loadProblem.value = e;
      _retryLoad();
    }
  }

  /// Set while the lists (chats, friends…) could not be loaded after start;
  /// cleared once a background retry succeeds.
  final ValueNotifier<Object?> loadProblem = ValueNotifier(null);
  Timer? _loadRetry;
  int _loadTries = 0;

  void _retryLoad() {
    _loadRetry?.cancel();
    final wait = Duration(seconds: math.min(60, 2 << math.min(_loadTries, 5)));
    _loadTries++;
    _loadRetry = Timer(wait, () async {
      if (session.phase != SessionPhase.ready) return;
      await retryLoadNow();
    });
  }

  /// "Try again" on the banner (and the background retry).
  Future<void> retryLoadNow() async {
    _loadRetry?.cancel();
    try {
      await hub.loadAll();
      loadProblem.value = null;
      _loadTries = 0;
    } catch (e) {
      loadProblem.value = e;
      _retryLoad();
    }
  }

  Map<String, Object?> _coreSettings = const {};
  Map<String, Object?> _coreSettingsSnapshot() => {
    'relay_delay_ms': settings.relayDelayMs,
    'read_receipts': settings.readReceipts,
    'typing': settings.typingIndicators,
    'store_forward': settings.storeForward,
    'help_friends': settings.helpFriends,
    'lan': settings.lanDiscovery,
    'relays': List<String>.of(settings.relays),
    'echo_cancel': settings.echoCancel,
    'noise_suppression': settings.noiseSuppression,
    'video_beauty': settings.videoBeauty,
    'video_lowlight': settings.videoLowlight,
    'video_mirror_send': settings.videoMirrorSend,
  };

  /// Makes the core match what Settings shows (it keeps its own copy of these
  /// values). After restoring a backup file the core's values win instead,
  /// so the restored preferences show up in the app.
  Future<void> _reconcileCoreSettings({bool adoptCore = false}) async {
    final Map<String, dynamic> core;
    try {
      core = await api.settingsGet();
    } catch (_) {
      return; // older core / mock without settings_get
    }
    if (adoptCore) {
      bool? b(String k) => core[k] is bool ? core[k] as bool : null;
      settings.update((s) {
        s.readReceipts = b('read_receipts') ?? s.readReceipts;
        s.typingIndicators = b('typing') ?? s.typingIndicators;
        s.storeForward = b('store_forward') ?? s.storeForward;
        s.helpFriends = b('help_friends') ?? s.helpFriends;
        s.echoCancel = b('echo_cancel') ?? s.echoCancel;
        s.noiseSuppression = b('noise_suppression') ?? s.noiseSuppression;
        s.videoLowlight = b('video_lowlight') ?? s.videoLowlight;
        s.videoMirrorSend = b('video_mirror_send') ?? s.videoMirrorSend;
        if (core['video_beauty'] is num) s.videoBeauty = (core['video_beauty'] as num).toInt().clamp(0, 3);
        final relays = core['relays'];
        if (relays is List && relays.isNotEmpty) s.relays = relays.map((e) => '$e').toList();
      });
      return;
    }
    final diff = <String, dynamic>{};
    _coreSettingsSnapshot().forEach((k, v) {
      if (!core.containsKey(k)) return;
      // "Direct only" mode keeps its own delay; don't override it.
      if (k == 'relay_delay_ms' && core['p2p_only'] == true) return;
      final c = core[k];
      final same = v is List && c is List ? v.join('\n') == c.join('\n') : v == c;
      if (!same) diff[k] = v;
    });
    if (diff.isNotEmpty) await api.settingsSet(diff).catchError((_) {});
  }

  /// Pushes changed core-relevant preferences with `settings_set`.
  void _syncCoreSettings() {
    final now = _coreSettingsSnapshot();
    final diff = <String, dynamic>{};
    now.forEach((k, v) {
      final old = _coreSettings[k];
      final same = v is List && old is List ? v.join('\n') == old.join('\n') : v == old;
      if (!same) diff[k] = v;
    });
    if (diff.isEmpty) return;
    _coreSettings = now;
    api.settingsSet(diff).catchError((_) {});
  }

  String? _lang;
  void _syncLang() {
    if (_lang == settings.locale || session.me == null) return;
    _lang = settings.locale;
    api.setLang(settings.locale).catchError((_) {});
  }

  /// Onboarding finished: persist flags and start.
  /// The session is started but the UI stays on onboarding ([enter] false)
  /// until the recovery phrase has been confirmed.
  /// [restoreBackup]: (backup file, its password) to restore an account from a file.
  Future<void> createIdentity({required String name, String? passphrase, String? restorePhrase, (String, String)? restoreBackup, bool enter = true}) async {
    settings.update((s) {
      s.name = name;
      s.hasPassphrase = passphrase != null && passphrase.isNotEmpty;
    });
    _markOnboarding();
    try {
      await unlock(
        passphrase,
        extra: {
          'recovery_phrase': ?restorePhrase,
          if (restoreBackup != null) 'restore_backup': [restoreBackup.$1, restoreBackup.$2],
        },
        enter: enter,
      );
    } catch (_) {
      // A wrong password / phrase / file: nothing half-made stays behind.
      await api.halt().catchError((_) {});
      _wipeHalfMade();
      _clearOnboardingMarker();
      rethrow;
    }
    // The phrase must really be this account's (an older core silently
    // kept existing data instead of restoring).
    var phraseUsed = false;
    if (restorePhrase != null) {
      phraseUsed = await api.phraseCheck(restorePhrase).catchError((_) => null) ?? false;
      if (!phraseUsed && !api.isMock) {
        await api.halt().catchError((_) {});
        _wipeHalfMade();
        _clearOnboardingMarker();
        session.me = null;
        throw ApiException('restore_mismatch', code: 'err.restore_mismatch');
      }
    }
    _clearOnboardingMarker();
    settings.update((s) {
      s.onboarded = true;
      // They already hold their phrase — only when it was the phrase that
      // brought the account back (a backup file is not the phrase).
      if (phraseUsed) s.phraseBackedUp = true;
    });
  }
}

class LumoraApp extends StatelessWidget {
  const LumoraApp({super.key, required this.services, this.home, this.overlays = true});
  final AppServices services;

  /// Overrides the root screen (tests/screenshots).
  final Widget? home;

  /// Show the global call / remote-desktop layers.
  final bool overlays;

  @override
  Widget build(BuildContext context) {
    final sv = services;
    return MultiProvider(
      providers: [
        Provider<AppServices>.value(value: sv),
        Provider<LumoraApi>.value(value: sv.api),
        ChangeNotifierProvider.value(value: sv.settings),
        ChangeNotifierProvider.value(value: sv.session),
        ChangeNotifierProvider.value(value: sv.contacts),
        ChangeNotifierProvider.value(value: sv.chat),
        ChangeNotifierProvider.value(value: sv.files),
        ChangeNotifierProvider.value(value: sv.calls),
        ChangeNotifierProvider.value(value: sv.remote),
        ChangeNotifierProvider.value(value: sv.net),
        ChangeNotifierProvider.value(value: sv.spaces),
        ChangeNotifierProvider.value(value: sv.nav),
        ChangeNotifierProvider.value(value: sv.avatars),
        ChangeNotifierProvider.value(value: sv.notices),
        ChangeNotifierProvider.value(value: sv.stories),
        ChangeNotifierProvider.value(value: sv.appLock),
        ChangeNotifierProvider.value(value: sv.camera),
        ChangeNotifierProvider.value(value: sv.devices),
        ChangeNotifierProvider.value(value: sv.moderation),
      ],
      child: Builder(
        builder: (context) {
          final mode = context.select<Settings, ThemeMode>((s) => s.themeMode);
          final compact = context.select<Settings, bool>((s) => s.compact);
          final scale = context.select<Settings, double>((s) => s.textScale);
          final locale = context.select<Settings, String>((s) => s.locale);
          return MaterialApp(
            navigatorKey: appNavigatorKey,
            title: 'Lumora',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.light, compact: compact),
            darkTheme: buildTheme(Brightness.dark, compact: compact),
            themeMode: mode,
            locale: Locale(locale),
            themeAnimationDuration: Motion.normal,
            builder: (context, child) {
              final mq = MediaQuery.of(context);
              return MediaQuery(
                data: mq.copyWith(textScaler: TextScaler.linear(scale)),
                child: Stack(
                  children: [
                    // Behind the lock screen the app can't take keyboard focus
                    // (shortcuts like Ctrl+K, text fields, a remote-desktop viewer
                    // that would forward the typed PIN) and screen readers can't
                    // read it out.
                    Positioned.fill(
                      // Mouse / touch use keeps the desktop idle lock from engaging.
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: (_) => sv.appLock.noteActivity(),
                        onPointerHover: (_) => sv.appLock.noteActivity(),
                        onPointerSignal: (_) => sv.appLock.noteActivity(),
                        child: LockShield(
                          child: Stack(
                            children: [
                              if (overlays) HostBannerFrame(child: child!) else child!,
                              if (overlays) const RemoteLayer(),
                              if (overlays) const CallLayer(),
                              if (overlays) const ReminderBannerLayer(),
                              if (overlays) const _LoadProblemBanner(),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // Topmost: nothing (chats, calls, remote screens) shows through the app lock.
                    if (overlays) const AppLockLayer(),
                  ],
                ),
              );
            },
            home: home ?? const RootGate(),
          );
        },
      ),
    );
  }
}

class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    final phase = context.select<SessionStore, SessionPhase>((s) => s.phase);
    final signedOut = context.select<DevicesStore, bool>((d) => d.signedOut != null);
    final history = context.select<DevicesStore, bool>((d) => d.showHistory);
    if (signedOut) {
      return AnimatedSwitcher(
        duration: Motion.slow,
        child: KeyedSubtree(
          key: const ValueKey('signed_out'),
          child: DeviceSignedOutScreen(onStartOver: context.read<AppServices>().startOver),
        ),
      );
    }
    final child = switch (phase) {
      SessionPhase.loading => const _Splash(),
      SessionPhase.onboarding => const OnboardingScreen(),
      SessionPhase.locked => const LockScreen(),
      SessionPhase.ready when history => const HistorySyncScreen(),
      SessionPhase.ready => const HomeShell(),
      SessionPhase.error => _ErrorScreen(error: context.read<SessionStore>().error ?? ''),
    };
    return AnimatedSwitcher(
      duration: Motion.slow,
      child: KeyedSubtree(key: ValueKey(phase == SessionPhase.ready && history ? 'history' : phase), child: child),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: LumoraLogo(size: 72)));
}

/// "Some data couldn't be loaded — retrying" (the session keeps running).
class _LoadProblemBanner extends StatelessWidget {
  const _LoadProblemBanner();
  @override
  Widget build(BuildContext context) {
    final sv = context.read<AppServices>();
    return ValueListenableBuilder<Object?>(
      valueListenable: sv.loadProblem,
      builder: (context, problem, _) {
        if (problem == null) return const SizedBox.shrink();
        final s = S.of(context);
        return Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Material(
                color: context.lc.surface,
                elevation: 6,
                borderRadius: BorderRadius.circular(Radii.md),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                  child: Row(
                    children: [
                      const Icon(AppIcons.warning, color: LC.warning, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(s('load_problem'), style: TextStyle(color: context.lc.text)),
                      ),
                      TextButton(onPressed: sv.retryLoadNow, child: Text(s('retry'))),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ErrorScreen extends StatefulWidget {
  const _ErrorScreen({required this.error});
  final String error;
  @override
  State<_ErrorScreen> createState() => _ErrorScreenState();
}

class _ErrorScreenState extends State<_ErrorScreen> {
  bool _busy = false;

  /// Not a dead end: starts again (boot decides onboarding / lock / home).
  Future<void> _retry() async {
    setState(() => _busy = true);
    final sv = context.read<AppServices>();
    try {
      await sv.api.halt().catchError((_) {});
      sv.session.setPhase(SessionPhase.loading);
      await sv.boot();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final error = widget.error;
    final raw = context.read<AppServices>().startupError;
    final detail = ApiException.detailFor(error) ?? (raw == null ? null : errorDetails(raw));
    // Known codes become plain sentences; core messages are already plain.
    final text = RegExp(r'^[a-z_]+$').hasMatch(error) ? s.orElse('err_$error', s('err_internal')) : (error.isEmpty ? s('err_internal') : error);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LumoraLogo(size: 56),
              const SizedBox(height: 16),
              Text('Lumora', style: context.tt.titleLarge),
              const SizedBox(height: 8),
              Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.lc.muted),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _busy ? null : _retry,
                icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(AppIcons.refresh, size: 18),
                label: Text(s('retry')),
              ),
              if (detail != null) ...[const SizedBox(height: 8), TextButton(onPressed: () => showTechnicalDetails(context, detail), child: Text(s('technical_details')))],
            ],
          ),
        ),
      ),
    );
  }
}

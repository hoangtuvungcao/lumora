import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import '../platform/apple_services.dart';

/// Size of the picker's "recently used" section.
const kRecentEmojiMax = 32;

/// User preferences (persisted as JSON next to the core's data dir).
class Settings extends ChangeNotifier {
  Settings({this.file});

  /// Persistence target; null = in-memory only (tests).
  final File? file;

  ThemeMode themeMode = ThemeMode.dark;
  String locale = 'vi';
  bool compact = false;
  double textScale = 1.0;

  bool readReceipts = true;
  bool typingIndicators = true;
  bool lanDiscovery = true;
  bool storeForward = true;

  /// Pass encrypted data along for two friends who can't connect directly
  /// (core `help_friends`, capped at 1 MB/s).
  bool helpFriends = true;
  bool notifications = true;

  /// Incoming calls ring (Lumora's own tone on computers, the phone's
  /// ringtone on Android, CallKit / our tone on iPhone).
  bool callRingtone = true;

  /// A short sound for a new message in a chat that is not open or muted.
  bool messageSound = true;

  /// The reminder alarm sound when a reminder is due.
  bool reminderSound = true;

  /// Phones: vibrate for incoming calls, new messages and reminders.
  bool vibrate = true;

  /// Android 11+: message notifications can open the chat as a bubble.
  bool chatBubbles = true;

  /// Android: the "keep Lumora running in the background" prompt was shown
  /// once (it is in Settings › Notifications afterwards).
  bool backgroundAsked = false;

  /// Muted chats that still alert for @mentions of me (mute sheet: "Mentions only").
  List<String> mentionsOnlyChats = [];

  /// Reminders snoozed on this device ("Hoãn 10 phút"): the `reminder_due`
  /// data plus `snooze_until` (ms). Fired again then, also after a restart.
  List<Map<String, dynamic>> snoozedReminders = [];
  bool linkPreviews = false;

  // No relay by default: pure P2P. Users (or their organisation) may add their own bridge.
  List<String> relays = [];
  int relayDelayMs = 3500;
  bool upnp = true;
  bool dht = true;
  bool nostr = true;

  /// Onboarding / identity flags (the identity itself lives in the core).
  bool onboarded = false;
  bool hasPassphrase = false;
  String name = '';

  /// The user confirmed they wrote down the recovery phrase.
  bool phraseBackedUp = false;

  /// Onboarding "I already use Lumora on another device" is in progress: the
  /// core must start with `link_pending: true` until the device is linked.
  bool linkPending = false;

  /// Last time an account backup file was saved (ms since epoch, 0 = never).
  int lastBackupAt = 0;

  /// Default self-destruct timer for new messages (0 = off).
  int defaultTtlMs = 0;

  /// Echo cancellation (on by default; can be turned off with headphones).
  bool echoCancel = true;

  /// Noise suppression in calls ("Lọc tiếng ồn", on by default).
  bool noiseSuppression = true;

  /// Camera "Làm đẹp" level: 0 = off, 1 = Nhẹ, 2 = Vừa, 3 = Mạnh (applied by
  /// the core before encoding, so the other side sees it).
  int videoBeauty = 0;

  /// Automatic low-light boost for the camera ("Tăng sáng").
  bool videoLowlight = true;

  /// Mirror the video that is sent ("Lật hình"); the self-view is always mirrored.
  bool videoMirrorSend = false;

  /// Show the 3-step welcome tour on next home screen (set after onboarding).
  bool showTour = false;

  /// Default history retention for new communities/groups.
  String communityRetention = 'forever';

  /// App lock: salted PIN hash (`pbkdf2-sha256$iter$salt$hash`), empty = off.
  /// Kept in the core's encrypted database (`ui_secret` "ui.pin", see
  /// [AppLock.loadSecrets]); only held in memory here. Older versions wrote it
  /// (and the wrong-PIN counters) into this file: [legacyPinSecrets].
  String pinHash = '';

  /// A PIN exists (not secret): lets the lock cover the UI at start-up,
  /// before the core is running and the hash can be read.
  bool pinSet = false;

  /// The file still holds PIN secrets from an older version; they are written
  /// back until [AppLock.loadSecrets] has moved them into the core.
  bool legacyPinSecrets = false;

  /// Digits in the PIN (4–6), so the lock screen can check it as soon as
  /// the last digit is typed.
  int pinLength = 4;

  /// Auto-lock after leaving the app: 0 = immediately, else seconds.
  int autoLockSec = 0;

  /// Desktop: lock after this many minutes without mouse/keyboard use while
  /// Lumora stays open (0 = never). Only with the app lock on.
  int idleLockMin = 15;

  /// Wrong-PIN state survives restarts so quitting doesn't skip the wait.
  int pinFails = 0;
  int pinLockUntil = 0;
  int pinLockLevel = 0;

  /// Android: FLAG_SECURE (no screenshots, blank in recent apps).
  bool blockScreenshots = false;

  /// Show who wrote and what in system notifications (forced off while
  /// the app lock is on).
  bool notifyPreview = true;

  /// iPhone: wake this device through the publisher's push bridge (opt-in; only
  /// offered when the build has one, see platform/apple_services.dart).
  bool instantPush = false;

  /// Two-way copy & paste sync during remote sessions.
  bool remoteClipboard = true;

  /// Data folders kept aside (never deleted), newest first: `<core>.locked-*`
  /// after "forgot password", `<core>.kept-*` when switching back.
  List<String> asideData = [];

  /// Folder to swap in at next launch (when it could not be moved live).
  String pendingDataSwitch = '';

  /// Chats hidden in the "Locked" folder (opened with the app PIN).
  List<String> lockedChats = [];

  /// The PIN also guards locked chats; the whole-app lock can be off.
  bool appLockEnabled = true;

  bool get hasPin => pinHash.isNotEmpty || pinSet;
  bool get appLock => hasPin && appLockEnabled;

  /// Notifications must not reveal message content.
  bool get hideNotificationContent => appLock || !notifyPreview;

  List<String> recentEmojis = ['👍', '❤️', '😂', '🔥', '🎉', '😮', '😢', '🙏'];

  /// How often each emoji was picked ("Hay dùng" ordering, search boost).
  Map<String, int> emojiUsage = {};

  /// Default skin tone for emoji that take one (0 = yellow, 1..5 = light..dark).
  int emojiTone = 0;

  /// Picker's first section ordered by frequency instead of recency.
  bool emojiFrequentFirst = false;

  /// Play Noto animated emoji (big emoji messages, reactions, picker preview).
  bool animatedEmoji = true;

  static Future<Settings> load(File? file) async {
    final s = Settings(file: file);
    if (file != null && await file.exists()) {
      try {
        s._fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
      } catch (_) {
        // Corrupt settings: keep defaults.
      }
    }
    return s;
  }

  void _fromJson(Map<String, dynamic> j) {
    themeMode = ThemeMode.values.firstWhere((m) => m.name == j['theme'], orElse: () => ThemeMode.dark);
    locale = j['locale'] as String? ?? locale;
    compact = j['compact'] as bool? ?? compact;
    textScale = (j['text_scale'] as num?)?.toDouble() ?? textScale;
    readReceipts = j['read_receipts'] as bool? ?? readReceipts;
    typingIndicators = j['typing'] as bool? ?? typingIndicators;
    lanDiscovery = j['lan'] as bool? ?? lanDiscovery;
    storeForward = j['store_forward'] as bool? ?? storeForward;
    helpFriends = j['help_friends'] as bool? ?? helpFriends;
    notifications = j['notifications'] as bool? ?? notifications;
    callRingtone = j['call_ringtone'] as bool? ?? callRingtone;
    messageSound = j['message_sound'] as bool? ?? messageSound;
    vibrate = j['vibrate'] as bool? ?? vibrate;
    reminderSound = j['reminder_sound'] as bool? ?? reminderSound;
    chatBubbles = j['chat_bubbles'] as bool? ?? chatBubbles;
    backgroundAsked = j['background_asked'] as bool? ?? backgroundAsked;
    mentionsOnlyChats = (j['mentions_only_chats'] as List?)?.cast<String>() ?? mentionsOnlyChats;
    snoozedReminders = (j['snoozed_reminders'] as List?)?.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList() ?? snoozedReminders;
    linkPreviews = j['link_previews'] as bool? ?? linkPreviews;
    relays = (j['relays'] as List?)?.cast<String>() ?? relays;
    relayDelayMs = j['relay_delay_ms'] as int? ?? relayDelayMs;
    upnp = j['upnp'] as bool? ?? upnp;
    dht = j['dht'] as bool? ?? dht;
    nostr = j['nostr'] as bool? ?? nostr;
    onboarded = j['onboarded'] as bool? ?? onboarded;
    hasPassphrase = j['has_passphrase'] as bool? ?? hasPassphrase;
    name = j['name'] as String? ?? name;
    phraseBackedUp = j['phrase_backed_up'] as bool? ?? phraseBackedUp;
    linkPending = j['link_pending'] as bool? ?? linkPending;
    lastBackupAt = j['last_backup_at'] as int? ?? lastBackupAt;
    defaultTtlMs = j['default_ttl_ms'] as int? ?? defaultTtlMs;
    communityRetention = j['community_retention'] as String? ?? communityRetention;
    echoCancel = j['echo_cancel'] as bool? ?? echoCancel;
    noiseSuppression = j['noise_suppression'] as bool? ?? noiseSuppression;
    videoBeauty = ((j['video_beauty'] as num?)?.toInt() ?? videoBeauty).clamp(0, 3);
    videoLowlight = j['video_lowlight'] as bool? ?? videoLowlight;
    videoMirrorSend = j['video_mirror_send'] as bool? ?? videoMirrorSend;
    recentEmojis = (j['recent_emojis'] as List?)?.cast<String>() ?? recentEmojis;
    emojiUsage = (j['emoji_usage'] as Map?)?.map((k, v) => MapEntry(k as String, (v as num).toInt())) ?? emojiUsage;
    emojiTone = j['emoji_tone'] as int? ?? emojiTone;
    emojiFrequentFirst = j['emoji_frequent_first'] as bool? ?? emojiFrequentFirst;
    animatedEmoji = j['animated_emoji'] as bool? ?? animatedEmoji;
    pinHash = j['pin_hash'] as String? ?? pinHash;
    pinSet = j['pin_set'] as bool? ?? pinHash.isNotEmpty;
    legacyPinSecrets = j.containsKey('pin_hash') || j.containsKey('pin_fails') || j.containsKey('pin_lock_until') || j.containsKey('pin_lock_level');
    pinLength = j['pin_len'] as int? ?? pinLength;
    appLockEnabled = j['app_lock_on'] as bool? ?? appLockEnabled;
    autoLockSec = j['auto_lock_sec'] as int? ?? autoLockSec;
    idleLockMin = j['idle_lock_min'] as int? ?? idleLockMin;
    pinFails = j['pin_fails'] as int? ?? pinFails;
    pinLockUntil = j['pin_lock_until'] as int? ?? pinLockUntil;
    pinLockLevel = j['pin_lock_level'] as int? ?? pinLockLevel;
    blockScreenshots = j['block_screenshots'] as bool? ?? blockScreenshots;
    notifyPreview = j['notify_preview'] as bool? ?? notifyPreview;
    instantPush = j['instant_push'] as bool? ?? instantPush;
    remoteClipboard = j['remote_clipboard'] as bool? ?? remoteClipboard;
    asideData = (j['aside_data'] as List?)?.cast<String>() ?? asideData;
    pendingDataSwitch = j['pending_data_switch'] as String? ?? pendingDataSwitch;
    lockedChats = (j['locked_chats'] as List?)?.cast<String>() ?? lockedChats;
  }

  Map<String, dynamic> toJson() => {
        'theme': themeMode.name,
        'locale': locale,
        'compact': compact,
        'text_scale': textScale,
        'read_receipts': readReceipts,
        'typing': typingIndicators,
        'lan': lanDiscovery,
        'store_forward': storeForward,
        'help_friends': helpFriends,
        'notifications': notifications,
        'call_ringtone': callRingtone,
        'message_sound': messageSound,
        'vibrate': vibrate,
        'reminder_sound': reminderSound,
        'chat_bubbles': chatBubbles,
        'background_asked': backgroundAsked,
        'mentions_only_chats': mentionsOnlyChats,
        'snoozed_reminders': snoozedReminders,
        'link_previews': linkPreviews,
        'relays': relays,
        'relay_delay_ms': relayDelayMs,
        'upnp': upnp,
        'dht': dht,
        'nostr': nostr,
        'onboarded': onboarded,
        'has_passphrase': hasPassphrase,
        'name': name,
        'phrase_backed_up': phraseBackedUp,
        'link_pending': linkPending,
        'last_backup_at': lastBackupAt,
        'default_ttl_ms': defaultTtlMs,
        'community_retention': communityRetention,
        'echo_cancel': echoCancel,
        'noise_suppression': noiseSuppression,
        'video_beauty': videoBeauty,
        'video_lowlight': videoLowlight,
        'video_mirror_send': videoMirrorSend,
        'recent_emojis': recentEmojis,
        'emoji_usage': emojiUsage,
        'emoji_tone': emojiTone,
        'emoji_frequent_first': emojiFrequentFirst,
        'animated_emoji': animatedEmoji,
        // secrets live in the core; written here only until migrated
        if (legacyPinSecrets) 'pin_hash': pinHash,
        'pin_set': hasPin,
        'pin_len': pinLength,
        'app_lock_on': appLockEnabled,
        'auto_lock_sec': autoLockSec,
        'idle_lock_min': idleLockMin,
        if (legacyPinSecrets) 'pin_fails': pinFails,
        if (legacyPinSecrets) 'pin_lock_until': pinLockUntil,
        if (legacyPinSecrets) 'pin_lock_level': pinLockLevel,
        'block_screenshots': blockScreenshots,
        'notify_preview': notifyPreview,
        'instant_push': instantPush,
        'remote_clipboard': remoteClipboard,
        'aside_data': asideData,
        'pending_data_switch': pendingDataSwitch,
        'locked_chats': lockedChats,
      };

  /// Core config for `lumora_start`.
  Map<String, dynamic> coreConfig({required String dataDir, String? passphrase, String? downloadsDir}) => {
        'data_dir': dataDir,
        'downloads_dir': downloadsDir,
        'passphrase': passphrase,
        'port': 0,
        'name': name.isEmpty ? null : name,
        'relays': relays,
        'nostr': null,
        'stun': null,
        'enable_lan': lanDiscovery,
        'enable_upnp': upnp,
        'enable_dht': dht,
        'enable_nostr': nostr,
        'relay_delay_ms': relayDelayMs,
        'log': 'info',
        // language for messages the core produces before its own setting loads
        'lang': locale,
      };

  /// First launch: the language follows the system (Vietnamese system →
  /// Vietnamese, anything else → English) and the theme follows the
  /// system's light/dark setting. The welcome step lets the user change both.
  void adoptSystemDefaults(Locale system) {
    locale = system.languageCode == 'vi' ? 'vi' : 'en';
    themeMode = ThemeMode.system;
  }

  /// Writes the settings file now (e.g. right after [adoptSystemDefaults],
  /// before the core starts).
  Future<void> save() => _save();

  /// Mutate + notify + persist.
  void update(void Function(Settings s) f) {
    f(this);
    AppleServices.syncHideContent(hideNotificationContent); // iOS notification extension
    notifyListeners();
    _save();
  }

  void pushRecentEmoji(String e) {
    recentEmojis = [e, ...recentEmojis.where((x) => x != e)].take(kRecentEmojiMax).toList();
    emojiUsage[e] = (emojiUsage[e] ?? 0) + 1;
    if (emojiUsage.length > 200) {
      // Forget the least used (keeping anything still in the recent list).
      final drop = emojiUsage.entries.where((x) => !recentEmojis.contains(x.key)).toList()..sort((a, b) => a.value.compareTo(b.value));
      for (final x in drop.take(emojiUsage.length - 200)) {
        emojiUsage.remove(x.key);
      }
    }
    _save();
  }

  bool _saving = false;
  bool _dirty = false;
  Completer<void>? _idle;

  /// Completes once every pending change is on disk.
  Future<void> flushed() async {
    while (_saving) {
      await (_idle ??= Completer<void>()).future;
    }
  }

  Future<void> _save() async {
    final f = file;
    if (f == null) return;
    if (_saving) {
      _dirty = true;
      return;
    }
    _saving = true;
    try {
      do {
        _dirty = false;
        await f.parent.create(recursive: true);
        // Atomic replace: a crash mid-write must never leave a cut file — load() would fall
        // back to defaults and forget `pin_set`, i.e. drop the lock screen.
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(jsonEncode(toJson()), flush: true);
        await tmp.rename(f.path);
      } while (_dirty);
    } catch (_) {
      // Non-fatal.
    } finally {
      _saving = false;
      final idle = _idle;
      _idle = null;
      idle?.complete();
    }
  }
}

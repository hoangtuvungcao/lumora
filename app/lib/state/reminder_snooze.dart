// "Hoãn 10 phút" for a reminder that went off (banner, Android notification
// action, Linux notification action). The core has no snooze: the reminder
// fires once per device, so the snooze lives here — the `reminder_due` data
// is kept in Settings with `snooze_until` and fired again as a local
// `reminder_due` (banner, alarm sound, system notification), also after a
// restart (a snooze that came due while Lumora was closed fires at launch,
// marked late). Local to this device, like the alarm itself.

import 'dart:async';

import 'settings.dart';

class ReminderSnoozer {
  ReminderSnoozer({required this.settings, required this.fire, this.delay = const Duration(minutes: 10), DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Settings settings;

  /// Raises the reminder again (AppServices: as a `reminder_due` event).
  final void Function(Map<String, dynamic> d) fire;
  final Duration delay;
  final DateTime Function() _now;
  final Map<String, Timer> _timers = {};

  static String _id(Map<String, dynamic> d) => d['msg_id']?.toString() ?? '';

  /// Re-arms the snoozes saved before a restart.
  void restore() {
    for (final d in List.of(settings.snoozedReminders)) {
      _arm(d);
    }
  }

  /// Fires [d] again after [delay] (replaces an earlier snooze of the same reminder).
  void snooze(Map<String, dynamic> d) {
    final id = _id(d);
    if (id.isEmpty) return;
    final until = _now().add(delay).millisecondsSinceEpoch;
    final copy = {...d, 'snooze_until': until, 'late': false}..remove('event');
    settings.update((s) => s.snoozedReminders = [...s.snoozedReminders.where((x) => _id(x) != id), copy]);
    _arm(copy);
  }

  /// The reminder was dealt with ("Đã xem", cancelled): no snooze left.
  void cancel(String msgId) {
    _timers.remove(msgId)?.cancel();
    if (settings.snoozedReminders.any((x) => _id(x) == msgId)) {
      settings.update((s) => s.snoozedReminders = s.snoozedReminders.where((x) => _id(x) != msgId).toList());
    }
  }

  bool isSnoozed(String msgId) => _timers.containsKey(msgId);

  void _arm(Map<String, dynamic> d) {
    final id = _id(d);
    final until = (d['snooze_until'] as num?)?.toInt() ?? 0;
    final wait = until - _now().millisecondsSinceEpoch;
    _timers.remove(id)?.cancel();
    _timers[id] = Timer(Duration(milliseconds: wait < 0 ? 0 : wait), () {
      _timers.remove(id);
      settings.update((s) => s.snoozedReminders = s.snoozedReminders.where((x) => _id(x) != id).toList());
      fire({...d, 'snoozed': true, 'late': wait < -60000}..remove('snooze_until'));
    });
  }

  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }
}

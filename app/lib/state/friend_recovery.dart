// Recovery from friends after a restore with the recovery phrase: friends who
// still have our 1-1 chats and shared groups offer them back; the user reviews
// each offer (`recovery_offers`, event `recovery` when the list changed) and
// accepts or declines it. One per LumoraApi.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api.dart';

class RecoveryOffer {
  RecoveryOffer({required this.peer, required this.name, required this.messages, required this.groups, required this.since, required this.verified, required this.state, required this.received});

  factory RecoveryOffer.fromJson(Map<String, dynamic> j) => RecoveryOffer(
        peer: '${j['peer'] ?? ''}',
        name: '${j['name'] ?? ''}',
        messages: (j['messages'] as num?)?.toInt() ?? 0,
        groups: (j['groups'] as List?)?.length ?? 0,
        since: (j['since'] as num?)?.toInt() ?? 0,
        verified: j['verified'] == true,
        state: '${j['state'] ?? 'offered'}',
        received: (j['received'] as num?)?.toInt() ?? 0,
      );

  final String peer;
  final String name;
  final int messages;
  final int groups;
  final int since;

  /// The friend showed a message this account signed in their chat.
  final bool verified;

  /// offered | accepted | done | declined
  final String state;
  final int received;
}

class RecoveryStore extends ChangeNotifier {
  RecoveryStore._(this.api) {
    _sub = api.events.listen(_onEvent);
  }

  static final _byApi = Expando<RecoveryStore>();

  /// The store of [api] (made on first use).
  static RecoveryStore of(LumoraApi api) => _byApi[api] ??= RecoveryStore._(api);

  final LumoraApi api;
  StreamSubscription<Map<String, dynamic>>? _sub;
  bool recovering = false;
  List<RecoveryOffer> offers = const [];
  Timer? _reload;

  /// Offers still waiting for an answer.
  List<RecoveryOffer> get waiting => offers.where((o) => o.state == 'offered').toList();

  void _apply(Map<String, dynamic> j) {
    if (j['recovering'] is bool) recovering = j['recovering'] as bool;
    final list = j['offers'];
    if (list is List) offers = list.whereType<Map>().map((m) => RecoveryOffer.fromJson(m.cast<String, dynamic>())).toList();
    notifyListeners();
  }

  Future<void> load() async {
    try {
      _apply(await api.recoveryOffers());
    } on ApiException catch (e) {
      // an older core: nothing to recover
      if (e.code != 'err.unknown_command' && !e.message.startsWith('unknown command')) rethrow;
    }
  }

  void _onEvent(Map<String, dynamic> raw) {
    final e = ApiEvent.parse(raw);
    if (e.name != 'recovery') return;
    _reload?.cancel();
    _reload = Timer(const Duration(milliseconds: 150), () => load().catchError((_) {}));
  }

  Future<void> accept(String peer) async => _apply(await api.recoveryAccept(peer));
  Future<void> decline(String peer) async => _apply(await api.recoveryDecline(peer));
  Future<void> dismiss() async => _apply(await api.recoveryDismiss());

  @override
  void dispose() {
    _reload?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}

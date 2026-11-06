// Lumora links and QR codes: one parser for everything that can carry them
// (a QR scanned in the app, a link opened from another app, a command-line
// argument, pasted text).
//
// Shared form (what QR codes and "Copy link" produce): https on Lumora's own
// site, so any camera / chat app / browser can open it. With Lumora installed,
// Android opens the app directly (App Links, landing/.well-known/assetlinks.json);
// otherwise the site shows a page with "Open with Lumora" and the downloads.
//
//   https://getlumora.pages.dev/add/<peer>?id=<9-digit id>   add a friend
//   https://getlumora.pages.dev/join/<invite token>          join a group
//   https://getlumora.pages.dev/remote/<9-digit id>          remote control
//
// The app-only form `lumora://add/…`, `lumora://join/…`, `lumora://remote/…`
// is accepted everywhere too (older QR codes, desktop URL protocol).
//
// `lumora://link/…` (linking a new device) is a different thing: it is only
// ever scanned inside the device-linking flow and never acted on when it comes
// from outside the app.

/// Host of the shared links (the project's website).
const kLinkHost = 'getlumora.pages.dev';
const kLinkBase = 'https://$kLinkHost';

enum LinkKind { add, join, remote, device }

final _peerRe = RegExp(r'^[a-z2-7]{52}$');
final _idRe = RegExp(r'^\d{9}$');
final _tokenRe = RegExp(r'^[a-z0-9]{8,4096}$');
final _findRe = RegExp(r'(?:lumora://|https?://(?:www\.)?getlumora\.pages\.dev/)\S+', caseSensitive: false);

/// Digits of a 9-digit Lumora ID ("123 456 789", "123-456-789" …), or null.
String? _digits9(String s) {
  final d = s.replaceAll(RegExp(r'[\s\-.·]'), '');
  return _idRe.hasMatch(d) ? d : null;
}

class LumoraLink {
  const LumoraLink._(this.kind, {this.peer, this.shortId, this.token, this.raw = ''});

  final LinkKind kind;

  /// add: the friend's full ID (52 characters), when the link has it.
  final String? peer;

  /// add (optional with [peer]) / remote: 9 digits, no spaces.
  final String? shortId;

  /// join: the invite token.
  final String? token;

  /// device: the original `lumora://link/…` text.
  final String raw;

  /// Parses one link (surrounding spaces allowed, nothing else). Null when it
  /// isn't a well-formed Lumora link.
  static LumoraLink? parse(String text) {
    final t = text.trim();
    if (t.isEmpty || t.length > 4200 || t.contains(RegExp(r'\s'))) return null;
    final uri = Uri.tryParse(t);
    if (uri == null) return null;
    final scheme = uri.scheme.toLowerCase();
    String kind;
    List<String> args;
    if (scheme == 'lumora') {
      kind = uri.host.toLowerCase();
      args = [for (final p in uri.pathSegments) if (p.isNotEmpty) p];
      if (kind == 'link') {
        return args.isEmpty ? null : LumoraLink._(LinkKind.device, raw: t);
      }
    } else if (scheme == 'https' || scheme == 'http') {
      final host = uri.host.toLowerCase();
      if (host != kLinkHost && host != 'www.$kLinkHost') return null;
      if (uri.hasPort && uri.port != (scheme == 'https' ? 443 : 80)) return null;
      final segs = [for (final p in uri.pathSegments) if (p.isNotEmpty) p];
      if (segs.isEmpty) return null;
      kind = segs.first.toLowerCase();
      args = segs.sublist(1);
    } else {
      return null;
    }
    if (args.length != 1) return null;
    final arg = args.single;
    switch (kind) {
      case 'add':
        final q = uri.queryParameters['id'];
        final qId = q == null ? null : _digits9(q);
        if (q != null && qId == null) return null;
        final a = arg.toLowerCase();
        if (_peerRe.hasMatch(a)) return LumoraLink._(LinkKind.add, peer: a, shortId: qId);
        final id = _digits9(arg);
        if (id == null || (qId != null && qId != id)) return null;
        return LumoraLink._(LinkKind.add, shortId: id);
      case 'join':
        final tok = arg.toLowerCase();
        return _tokenRe.hasMatch(tok) ? LumoraLink._(LinkKind.join, token: tok) : null;
      case 'remote':
        final id = _digits9(arg);
        return id == null ? null : LumoraLink._(LinkKind.remote, shortId: id);
      default:
        return null;
    }
  }

  /// The first Lumora link inside [text] (a pasted message, a QR payload), or null.
  static LumoraLink? find(String text) {
    final whole = parse(text);
    if (whole != null) return whole;
    for (final m in _findRe.allMatches(text)) {
      // trailing punctuation of a sentence is not part of the link
      final l = parse(m.group(0)!.replaceFirst(RegExp(r'[.,;:!?)\]>"”’]+$'), ''));
      if (l != null) return l;
    }
    return null;
  }

  /// True when [text] looks like a Lumora link at all (well-formed or not):
  /// such text gets a "this link is broken" answer instead of being ignored.
  static bool looksLikeLink(String text) => _findRe.hasMatch(text.trim());

  /// The shared https form (QR codes, "Copy link").
  String get https => switch (kind) {
        LinkKind.add => '$kLinkBase/add/${peer ?? shortId}${peer != null && shortId != null ? '?id=$shortId' : ''}',
        LinkKind.join => '$kLinkBase/join/$token',
        LinkKind.remote => '$kLinkBase/remote/$shortId',
        LinkKind.device => raw,
      };

  /// The app form (`lumora://…`): what the core understands for invites.
  String get app => switch (kind) {
        LinkKind.add => 'lumora://add/${peer ?? shortId}${peer != null && shortId != null ? '?id=$shortId' : ''}',
        LinkKind.join => 'lumora://join/$token',
        LinkKind.remote => 'lumora://remote/$shortId',
        LinkKind.device => raw,
      };

  // ------------------------------------------------------------- builders

  /// "Add me as a friend" link for [peer] (with the 9-digit ID when known).
  static String addLink(String peer, {String? shortId}) {
    final id = shortId == null ? null : _digits9(shortId);
    return '$kLinkBase/add/$peer${id != null ? '?id=$id' : ''}';
  }

  /// Remote-control link for a 9-digit ID.
  static String remoteLink(String shortId) => '$kLinkBase/remote/${shortId.replaceAll(RegExp(r'\D'), '')}';

  /// The shared form of a group invite made by the core (`lumora://join/…`);
  /// anything unexpected is returned unchanged.
  static String shareInvite(String coreLink) {
    final l = parse(coreLink);
    return l != null && l.kind == LinkKind.join ? l.https : coreLink;
  }

  @override
  bool operator ==(Object other) => other is LumoraLink && other.kind == kind && other.peer == peer && other.shortId == shortId && other.token == token && other.raw == raw;

  @override
  int get hashCode => Object.hash(kind, peer, shortId, token, raw);

  @override
  String toString() => 'LumoraLink($app)';
}

/// A link handed to Lumora by the OS (another app, the browser, the command
/// line). Returns the text to queue for the home screen, or null to ignore it:
/// device-link codes are never acted on from outside the app, and anything
/// that isn't a Lumora address at all is dropped. Malformed Lumora links are
/// kept so the user gets a friendly "this link doesn't work" message.
String? acceptIncomingLink(String? text) {
  if (text == null) return null;
  final t = text.trim();
  if (t.isEmpty || t.length > 4200) return null;
  final l = LumoraLink.parse(t);
  if (l != null) return l.kind == LinkKind.device ? null : t;
  final uri = Uri.tryParse(t);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'lumora') return uri.host.toLowerCase() == 'link' ? null : t;
  if ((scheme == 'https' || scheme == 'http') && uri.host.toLowerCase() == kLinkHost) return t;
  return null;
}

/// When a queued link may be acted on: only on the home screen (onboarding
/// finished, account unlocked) and never behind the app lock.
bool canOpenPendingLink({required bool homeReady, required bool lockShown}) => homeReady && !lockShown;

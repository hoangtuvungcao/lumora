import 'dart:io' show Platform;
// Location (static + live), voice message and contact-card bubbles.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/app_icons.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:just_audio/just_audio.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/peer_avatar.dart';
import 'attachments.dart';
import 'chat_view.dart';
import 'task_sheets.dart';

// ---------------------------------------------------------------- location

/// Live-location sharing loop (sender side): pushes a fix every ~10 s until
/// `live_until` or the user stops.
class LiveLocation {
  static final Map<String, Timer> _active = {};
  static bool isSharing(String msgId) => _active.containsKey(msgId);

  static void start(LumoraApi api, String conv, String msgId, DateTime until) {
    _active[msgId]?.cancel();
    _active[msgId] = Timer.periodic(const Duration(seconds: 10), (t) async {
      if (DateTime.now().isAfter(until)) {
        t.cancel();
        _active.remove(msgId);
        return;
      }
      try {
        final p = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 8));
        await api.updateLiveLocation(conv, msgId, p.latitude, p.longitude, accuracyM: p.accuracy);
      } catch (_) {
        // No GPS on this device (e.g. desktop) – keep the last fix.
      }
    });
  }

  static Future<void> stop(LumoraApi api, String conv, String msgId, LocationData loc) async {
    _active.remove(msgId)?.cancel();
    await api.updateLiveLocation(conv, msgId, loc.lat, loc.lon, stop: true);
  }
}

class LocationBubble extends StatelessWidget {
  const LocationBubble({super.key, required this.message, required this.overlay});
  final Message message;
  final Widget overlay;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final loc = LocationData.parse(message.body);
    if (loc == null) return Text(message.body);
    final now = DateTime.now().millisecondsSinceEpoch;
    final live = loc.isLive(now);
    final w = isDesktop(context) ? 320.0 : 260.0;
    final mins = ((loc.liveUntil - now) / 60000).ceil();
    return GestureDetector(
      onTap: () => openLocation(context, message),
      child: SizedBox(
        width: w,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
            child: SizedBox(
              height: 140,
              child: Stack(fit: StackFit.expand, children: [
                RepaintBoundary(child: CustomPaint(painter: MapSketchPainter(seed: (loc.lat * 1000 + loc.lon * 1000).round(), dark: Theme.of(context).brightness == Brightness.dark))),
                Center(child: live ? const _PulsingPin() : const Icon(AppIcons.location, color: LC.danger, size: 40)),
                if (live)
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Pill(s('live_left', {'n': mins}), color: LC.danger, solid: true, icon: AppIcons.live),
                  ),
                Positioned(right: 6, bottom: 6, child: overlay),
              ]),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              color: message.mine ? Colors.white.withValues(alpha: 0.12) : context.lc.surface2.withValues(alpha: 0.6),
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
            ),
            child: Row(children: [
              Icon(live ? AppIcons.navigate : AppIcons.location, size: 18, color: message.mine ? Colors.white : LC.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    loc.label.isNotEmpty ? loc.label : (live ? s('live_location') : s('location')),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w600, color: message.mine ? Colors.white : context.lc.text),
                  ),
                  Text('${loc.lat.toStringAsFixed(5)}, ${loc.lon.toStringAsFixed(5)}',
                      style: TextStyle(fontSize: 11.5, color: message.mine ? Colors.white70 : context.lc.muted)),
                ]),
              ),
              if (live && message.mine)
                TextButton(
                  onPressed: () => LiveLocation.stop(context.read<LumoraApi>(), message.conv, message.id, loc),
                  style: TextButton.styleFrom(foregroundColor: message.mine ? Colors.white : LC.danger, visualDensity: VisualDensity.compact),
                  child: Text(s('stop')),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _PulsingPin extends StatefulWidget {
  const _PulsingPin();
  @override
  State<_PulsingPin> createState() => _PulsingPinState();
}

class _PulsingPinState extends State<_PulsingPin> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Stack(alignment: Alignment.center, children: [
          Container(
            width: 18 + 44 * _c.value,
            height: 18 + 44 * _c.value,
            decoration: BoxDecoration(shape: BoxShape.circle, color: LC.primary.withValues(alpha: 0.35 * (1 - _c.value))),
          ),
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(shape: BoxShape.circle, color: LC.primary, border: Border.all(color: Colors.white, width: 3)),
          ),
        ]),
      );
}

/// Offline "map" sketch: no tiles are fetched for previews (privacy).
class MapSketchPainter extends CustomPainter {
  MapSketchPainter({required this.seed, required this.dark});
  final int seed;
  final bool dark;
  @override
  void paint(Canvas canvas, Size size) {
    final bg = dark ? const Color(0xFF1B2036) : const Color(0xFFEFF1F6);
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    final r = math.Random(seed);
    final park = Paint()..color = (dark ? const Color(0xFF1E3A2E) : const Color(0xFFD4EFD9));
    final water = Paint()..color = (dark ? const Color(0xFF16304A) : const Color(0xFFCFE6FA));
    for (var i = 0; i < 3; i++) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(r.nextDouble() * size.width, r.nextDouble() * size.height, 40 + r.nextDouble() * 60, 30 + r.nextDouble() * 40), const Radius.circular(8)),
          i == 0 ? water : park);
    }
    final road = Paint()
      ..color = dark ? const Color(0xFF2C3354) : Colors.white
      ..strokeWidth = 6;
    final minor = Paint()
      ..color = dark ? const Color(0xFF252B48) : const Color(0xFFFFFFFF)
      ..strokeWidth = 3;
    for (var i = 0; i < 6; i++) {
      final y = r.nextDouble() * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y + r.nextDouble() * 40 - 20), i < 2 ? road : minor);
      final x = r.nextDouble() * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x + r.nextDouble() * 40 - 20, size.height), i < 2 ? road : minor);
    }
  }

  @override
  bool shouldRepaint(covariant MapSketchPainter old) => old.seed != seed || old.dark != dark;
}

/// Hands the place to the phone's maps app (geo: on Android, Apple Maps on iOS/macOS),
/// falling back to OpenStreetMap in the browser; says so if nothing can open it.
Future<void> openInMaps(BuildContext context, LocationData loc) async {
  final s = S.read(context);
  final label = Uri.encodeComponent(loc.label.isNotEmpty ? loc.label : 'Lumora');
  final tries = <Uri>[
    if (Platform.isAndroid) Uri.parse('geo:${loc.lat},${loc.lon}?q=${loc.lat},${loc.lon}($label)'),
    if (Platform.isIOS || Platform.isMacOS) Uri.parse('https://maps.apple.com/?ll=${loc.lat},${loc.lon}&q=$label'),
    // Google Maps opens its app when installed, else the web page; works where openstreetmap.org
    // doesn't resolve (owner saw a DNS error on their network)
    Uri.parse('https://www.google.com/maps/search/?api=1&query=${loc.lat},${loc.lon}'),
    Uri.parse('https://www.openstreetmap.org/?mlat=${loc.lat}&mlon=${loc.lon}#map=16/${loc.lat}/${loc.lon}'),
  ];
  for (final u in tries) {
    try {
      if (await launchUrl(u, mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
  }
  if (context.mounted) toast(context, s('no_maps_app'));
}

Future<void> openLocation(BuildContext context, Message m) {
  return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LocationScreen(message: m)));
}

class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key, required this.message});
  final Message message;
  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  bool _showMap = false;
  bool _tileError = false;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    // Follow live updates.
    final m = context.select<ChatStore, Message>((c) => c.thread(widget.message.conv).byId(widget.message.id) ?? widget.message);
    final loc = LocationData.parse(m.body);
    if (loc == null) {
      // never a red screen: an unreadable location says so
      return Scaffold(body: SafeArea(child: Column(children: [PaneHeader(title: Text(s('location'))), Expanded(child: Center(child: Text(s('location_unreadable'))))])));
    }
    final point = LatLng(loc.lat, loc.lon);
    final name = m.mine ? s('you') : context.read<ContactsStore>().nameOf(m.author);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          PaneHeader(
            title: Text(loc.label.isNotEmpty ? loc.label : s('location')),
            subtitle: Text(loc.isLive(DateTime.now().millisecondsSinceEpoch) ? s('live_by', {'name': name}) : s('shared_by', {'name': name})),
          ),
          Expanded(
            child: _showMap
                ? FlutterMap(
                    options: MapOptions(initialCenter: point, initialZoom: 16),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'vn.lumora.lumora',
                        // tiles that can't load (offline, blocked) stay blank instead of erroring
                        errorTileCallback: (tile, error, stack) {
                          // every failed tile reports: rebuild once, never after the screen closed
                          if (mounted && !_tileError) setState(() => _tileError = true);
                        },
                      ),
                      MarkerLayer(markers: [
                        Marker(point: point, width: 60, height: 60, child: const Icon(AppIcons.location, color: LC.danger, size: 44)),
                      ]),
                      const RichAttributionWidget(attributions: [TextSourceAttribution('OpenStreetMap contributors')]),
                      if (_tileError)
                        Align(
                          alignment: Alignment.topCenter,
                          child: Card(
                            margin: const EdgeInsets.all(12),
                            child: Padding(padding: const EdgeInsets.all(12), child: Text(s('map_tiles_failed'), textAlign: TextAlign.center)),
                          ),
                        ),
                    ],
                  )
                : Stack(fit: StackFit.expand, children: [
                    CustomPaint(painter: MapSketchPainter(seed: (loc.lat * 1000 + loc.lon * 1000).round(), dark: Theme.of(context).brightness == Brightness.dark)),
                    const Center(child: Icon(AppIcons.location, color: LC.danger, size: 52)),
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 140),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          FilledButton.icon(onPressed: () => setState(() => _showMap = true), icon: const Icon(AppIcons.map), label: Text(s('view_map'))),
                          const SizedBox(height: 8),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 360),
                            child: Text(s('map_privacy'), textAlign: TextAlign.center, style: context.tt.bodySmall),
                          ),
                        ]),
                      ),
                    ),
                  ]),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Expanded(
                child: Text('${loc.lat.toStringAsFixed(6)}, ${loc.lon.toStringAsFixed(6)}${loc.accuracy > 0 ? ' · ±${loc.accuracy.round()} m' : ''}',
                    style: context.tt.bodySmall),
              ),
              TextButton.icon(
                onPressed: () => copyText(context, '${loc.lat},${loc.lon}'),
                icon: const Icon(AppIcons.copy, size: 18),
                label: Text(s('copy')),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => openInMaps(context, loc),
                icon: const Icon(AppIcons.openExternal, size: 18),
                label: Text(s('open_in_maps')),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Attach → Location: permission explanation, current position, live 15/60/480.
Future<void> showSendLocation(BuildContext context, String conv) async {
  final s = S.read(context);
  final api = context.read<LumoraApi>();
  final chat = context.read<ChatStore>();
  final lat = TextEditingController(text: '10.7769');
  final lon = TextEditingController(text: '106.7009');
  final label = TextEditingController();
  String? gpsError;
  double? acc;
  try {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) throw Exception('denied');
    final p = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 8));
    lat.text = p.latitude.toStringAsFixed(6);
    lon.text = p.longitude.toStringAsFixed(6);
    acc = p.accuracy;
  } catch (e) {
    gpsError = s('gps_unavailable');
  }
  if (!context.mounted) return;
  final r = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 520),
    builder: (c) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(s('location'), style: c.tt.titleMedium),
            const SizedBox(height: 4),
            Text(s('location_privacy'), style: c.tt.bodySmall),
            if (gpsError != null) ...[
              const SizedBox(height: 10),
              Text(gpsError, style: const TextStyle(color: LC.warning)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: lat, decoration: InputDecoration(labelText: s('loc_lat')))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: lon, decoration: InputDecoration(labelText: s('loc_lon')))),
              ]),
            ],
            const SizedBox(height: 8),
            TextField(controller: label, decoration: InputDecoration(labelText: s('location_label'), hintText: s('location_label_hint'))),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(AppIcons.locate, color: LC.primary),
              title: Text(s('send_current_location')),
              onTap: () => Navigator.pop(c, 0),
            ),
            for (final (mins, key) in [(15, 'live_15'), (60, 'live_60'), (480, 'live_480')])
              ListTile(
                leading: const Icon(AppIcons.navigate, color: LC.danger),
                title: Text(s(key)),
                onTap: () => Navigator.pop(c, mins),
              ),
          ]),
        ),
      ),
    ),
  );
  final la = double.tryParse(lat.text.trim()), lo = double.tryParse(lon.text.trim());
  final lbl = label.text.trim();
  lat.dispose();
  lon.dispose();
  label.dispose();
  if (r == null || la == null || lo == null) return;
  try {
    final m = await api.sendLocation(conv, la, lo, accuracyM: acc, label: lbl.isEmpty ? null : lbl, liveMinutes: r);
    chat.thread(conv).add(m);
    if (r > 0) LiveLocation.start(api, conv, m.id, DateTime.now().add(Duration(minutes: r)));
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

// ------------------------------------------------------------------ voice

class VoiceBubble extends StatefulWidget {
  const VoiceBubble({super.key, required this.message, required this.overlay});
  final Message message;
  final Widget overlay;
  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble> {
  AudioPlayer? _player;
  StreamSubscription<Duration>? _pos;
  StreamSubscription<PlayerState>? _st;
  Duration _position = Duration.zero;
  bool _playing = false;
  double _speed = 1;

  @override
  void dispose() {
    _pos?.cancel();
    _st?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle(String? path) async {
    final s = S.read(context);
    if (path == null || path.isEmpty) {
      toast(context, s('voice_not_downloaded'));
      return;
    }
    try {
      if (_player == null) {
        final p = AudioPlayer();
        _player = p;
        if (path.startsWith('asset:')) {
          await p.setAsset(path.substring(6));
        } else {
          await p.setFilePath(path);
        }
        _pos = p.positionStream.listen((d) => setState(() => _position = d));
        _st = p.playerStateStream.listen((st) {
          if (st.processingState == ProcessingState.completed) {
            p.seek(Duration.zero);
            p.pause();
          }
          setState(() => _playing = st.playing && st.processingState != ProcessingState.completed);
        });
      }
      await _setSpeed(_speed);
      _playing ? await _player!.pause() : await _player!.play();
    } catch (_) {
      // No audio backend on this platform (e.g. Linux) → system player.
      if (mounted) openFile(context, path);
    }
  }

  Future<void> _setSpeed(double v) async => _player?.setSpeed(v);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final m = widget.message;
    final v = VoiceData.parse(m.body);
    final ref = FileRef.parse(m.body);
    final f = ref == null ? null : effectiveFile(context, m, ref);
    final path = (f?.path.isNotEmpty ?? false) ? f!.path : m.fileInfo?['path']?.toString();
    final dur = Duration(milliseconds: v?.durationMs ?? 0);
    final frac = dur.inMilliseconds == 0 ? 0.0 : (_position.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
    final mine = m.mine;
    final fg = mine ? Colors.white : LC.primary;
    final wave = v?.wave.isNotEmpty == true ? v!.wave : List.filled(32, 60);
    return SizedBox(
      width: 250,
      child: Row(children: [
        Material(
          color: mine ? Colors.white : LC.primary,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _toggle(path),
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(_playing ? AppIcons.pause : AppIcons.play, color: mine ? LC.primary : Colors.white),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              height: 28,
              width: double.infinity,
              child: CustomPaint(painter: _WavePainter(wave, frac, fg, mine ? Colors.white38 : context.lc.muted.withValues(alpha: 0.45))),
            ),
            const SizedBox(height: 2),
            Row(children: [
              Text(s.duration(_playing || _position > Duration.zero ? _position : dur),
                  style: TextStyle(fontSize: 11.5, color: mine ? Colors.white70 : context.lc.muted, fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(width: 6),
              InkWell(
                onTap: () {
                  setState(() => _speed = _speed == 1 ? 1.5 : (_speed == 1.5 ? 2 : 1));
                  _setSpeed(_speed);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: (mine ? Colors.white : LC.primary).withValues(alpha: 0.18), borderRadius: BorderRadius.circular(6)),
                  child: Text('${_speed == 1 ? 1 : _speed}x', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
                ),
              ),
              const Spacer(),
              widget.overlay,
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.wave, this.progress, this.on, this.off);
  final List<int> wave;
  final double progress;
  final Color on;
  final Color off;
  @override
  void paint(Canvas canvas, Size size) {
    final n = wave.length;
    final bw = size.width / n;
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < n; i++) {
      final h = math.max(3.0, size.height * (wave[i] / 255));
      paint
        ..color = (i + 0.5) / n <= progress ? on : off
        ..strokeWidth = math.max(2, bw * 0.55);
      final x = i * bw + bw / 2;
      canvas.drawLine(Offset(x, (size.height - h) / 2), Offset(x, (size.height + h) / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) => old.progress != progress || old.on != on;
}

// ---------------------------------------------------------------- contact

class ContactCardBubble extends StatelessWidget {
  const ContactCardBubble({super.key, required this.message});
  final Message message;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final card = ContactCard.parse(message.body);
    if (card == null) return Text(message.body);
    final mine = message.mine;
    final known = context.select<ContactsStore, Contact?>((c) => c[card.peer]);
    final me = context.read<SessionStore>().me?.peer;
    final isFriend = known?.status == ContactStatus.friend;
    return Container(
      width: 260,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: mine ? Colors.white.withValues(alpha: 0.12) : context.lc.surface2.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          PeerAvatar(peer: card.peer, fallbackName: card.name, size: 44, presence: false),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(card.name, style: TextStyle(fontWeight: FontWeight.w700, color: mine ? Colors.white : context.lc.text)),
              Text('ID ${card.shortId}', style: TextStyle(fontSize: 12, color: mine ? Colors.white70 : context.lc.muted)),
            ]),
          ),
          Icon(AppIcons.contactCard, color: mine ? Colors.white70 : context.lc.muted, size: 20),
        ]),
        const SizedBox(height: 8),
        Divider(height: 1, color: mine ? Colors.white24 : context.lc.divider),
        const SizedBox(height: 4),
        if (card.peer != me)
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: mine ? Colors.white : LC.primary),
            onPressed: () async {
              if (isFriend) {
                final conv = context.read<ChatStore>().ensureDirect(known!);
                context.read<NavStore>().openConv(conv);
                if (!isDesktop(context)) Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatView(conv: conv)));
              } else {
                try {
                  await context.read<ContactsStore>().add(card.peer);
                  if (context.mounted) toast(context, s('request_sent_toast'));
                } catch (e) {
                  if (context.mounted) toastError(context, e);
                }
              }
            },
            icon: Icon(isFriend ? AppIcons.chat : AppIcons.addFriend, size: 18),
            label: Text(isFriend ? s('message') : s('add_friend')),
          ),
      ]),
    );
  }
}

/// Pick a friend and send their contact card.
Future<void> showSendContact(BuildContext context, String conv) async {
  final s = S.read(context);
  final api = context.read<LumoraApi>();
  final chat = context.read<ChatStore>();
  final friends = context.read<ContactsStore>().friends;
  final peer = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 480),
    builder: (c) => SizedBox(
      height: MediaQuery.sizeOf(c).height * 0.6,
      child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Align(alignment: Alignment.centerLeft, child: Text(s('share_contact'), style: c.tt.titleMedium))),
        Expanded(
          child: ListView.builder(
            itemCount: friends.length,
            itemBuilder: (_, i) => ListTile(
              leading: PeerAvatar(peer: friends[i].peer, size: 38),
              title: Text(friends[i].displayName),
              subtitle: Text('ID ${friends[i].shortId}'),
              onTap: () => Navigator.pop(c, friends[i].peer),
            ),
          ),
        ),
      ]),
    ),
  );
  if (peer == null) return;
  try {
    chat.thread(conv).add(await api.sendContact(conv, peer));
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

// --------------------------------------------------------------- checklist

String _who(BuildContext context, String peer, String myPeer, S s) =>
    peer == myPeer ? s('you') : context.read<ContactsStore>().nameOf(peer);

/// "Danh sách việc": title, a progress bar ("3/5 xong") and one checkbox per
/// item with who ticked it. Anyone in the chat can tick; the sender can add.
class ChecklistBubble extends StatelessWidget {
  const ChecklistBubble({super.key, required this.message, required this.myPeer});
  final Message message;
  final String myPeer;

  Future<void> _toggle(BuildContext context, ChecklistItem it) async {
    HapticFeedback.selectionClick();
    try {
      await context.read<ChatStore>().toggleCheck(message.conv, message, it.id, !it.done, myPeer);
    } catch (e) {
      if (context.mounted) toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final data = ChecklistData.parse(message);
    if (data == null) return Text(message.body);
    final mine = message.mine;
    final fg = mine ? Colors.white : context.lc.text;
    final sub = mine ? Colors.white70 : context.lc.muted;
    final accent = mine ? Colors.white : LC.success;
    final total = data.items.length;
    final done = data.doneCount;
    final frac = total == 0 ? 0.0 : done / total;
    final all = total > 0 && done == total;
    return SizedBox(
      width: 290,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Icon(AppIcons.tasks, size: 16, color: sub),
          const SizedBox(width: 6),
          Text(s('checklist'), style: TextStyle(fontSize: 12, color: sub, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 4),
        Text(data.title, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Container(
                height: 6,
                color: (mine ? Colors.white : context.lc.text).withValues(alpha: 0.12),
                alignment: Alignment.centerLeft,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: frac),
                  duration: Motion.slow,
                  curve: Motion.curve,
                  builder: (_, v, _) => FractionallySizedBox(
                    widthFactor: v.clamp(0.0, 1.0),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: mine ? null : const LinearGradient(colors: [LC.success, Color(0xFF14B8A6)]),
                        color: mine ? Colors.white : null,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (all) ...[Icon(AppIcons.celebrate, size: 14, color: accent), const SizedBox(width: 4)],
          Text(s('checklist_progress', {'done': done, 'total': total}),
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: all ? accent : sub, fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
        const SizedBox(height: 6),
        for (final it in data.items)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _toggle(context, it),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AnimatedContainer(
                  duration: Motion.normal,
                  curve: Motion.curve,
                  width: 20,
                  height: 20,
                  margin: const EdgeInsets.only(top: 1),
                  decoration: BoxDecoration(
                    color: it.done ? (mine ? Colors.white : LC.success) : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: it.done ? (mine ? Colors.white : LC.success) : sub.withValues(alpha: 0.6), width: 1.6),
                  ),
                  child: it.done ? Icon(AppIcons.check, size: 14, color: mine ? LC.primary : Colors.white) : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    AnimatedDefaultTextStyle(
                      duration: Motion.normal,
                      style: TextStyle(
                        fontFamily: DefaultTextStyle.of(context).style.fontFamily,
                        fontSize: 14,
                        height: 1.3,
                        color: it.done ? sub : fg,
                        decoration: it.done ? TextDecoration.lineThrough : null,
                        decorationColor: sub,
                      ),
                      child: Text(it.text),
                    ),
                    if (it.done && it.by != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          it.at > 0
                              ? s('checked_by_at', {'name': _who(context, it.by!, myPeer, s), 't': s.hhmm(DateTime.fromMillisecondsSinceEpoch(it.at))})
                              : s('checked_by', {'name': _who(context, it.by!, myPeer, s)}),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: sub),
                        ),
                      ),
                  ]),
                ),
              ]),
            ),
          ),
        if (mine && total < 100)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: fg, visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
              onPressed: () => showChecklistAddItems(context, message),
              icon: const Icon(AppIcons.addToList, size: 16),
              label: Text(s('checklist_add_items')),
            ),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- reminder

/// "còn 2 giờ 15 phút" / "in 2 h 15 min".
String reminderCountdown(S s, Duration d) {
  if (d.inSeconds < 60) return s('rem_soon');
  if (d.inHours < 1) return s('rem_in_min', {'m': d.inMinutes});
  if (d.inDays < 1) {
    final m = d.inMinutes.remainder(60);
    return m == 0 ? s('rem_in_hours_only', {'h': d.inHours}) : s('rem_in_hours', {'h': d.inHours, 'm': m});
  }
  return s('rem_in_days', {'d': d.inDays, 'h': d.inHours.remainder(24)});
}

/// "Hôm nay · 14:30", "Ngày mai · 09:00", "Thứ 6, 7 tháng 11 · 20:00".
String reminderWhen(S s, DateTime at) {
  final now = DateTime.now();
  final day = DateTime(at.year, at.month, at.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = day.difference(today).inDays;
  final label = diff == 1 ? s('rem_tomorrow') : s.dayLabel(at, now);
  return '$label · ${s.hhmm(at)}';
}

/// "Nhắc hẹn": title, when, live countdown, note, who has seen it,
/// "Đã xem" for everyone and "Huỷ nhắc hẹn" for the sender.
class ReminderBubble extends StatefulWidget {
  const ReminderBubble({super.key, required this.message, required this.myPeer});
  final Message message;
  final String myPeer;
  @override
  State<ReminderBubble> createState() => _ReminderBubbleState();
}

class _ReminderBubbleState extends State<ReminderBubble> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  void _schedule() {
    _tick?.cancel();
    final r = ReminderData.parse(widget.message);
    if (r == null || r.cancelled) return;
    final left = r.at.difference(DateTime.now());
    if (left.isNegative) return;
    // Refresh often near the time, rarely otherwise.
    final every = left.inMinutes < 2 ? const Duration(seconds: 1) : const Duration(seconds: 20);
    _tick = Timer(every, () {
      if (!mounted) return;
      setState(() {});
      _schedule();
    });
  }

  @override
  void didUpdateWidget(ReminderBubble old) {
    super.didUpdateWidget(old);
    if (old.message != widget.message) _schedule();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _seen() async {
    try {
      await context.read<ChatStore>().markReminderSeen(widget.message.conv, widget.message, widget.myPeer);
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  Future<void> _cancel() async {
    final s = S.read(context);
    final ok = await confirm(context, title: s('rem_cancel_q'), body: s('rem_cancel_body'), action: s('rem_cancel'), danger: true);
    if (!ok || !mounted) return;
    try {
      await context.read<ChatStore>().cancelReminder(widget.message.conv, widget.message);
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final m = widget.message;
    final r = ReminderData.parse(m);
    if (r == null) return Text(m.body);
    final mine = m.mine;
    final fg = mine ? Colors.white : context.lc.text;
    final sub = mine ? Colors.white70 : context.lc.muted;
    final left = r.at.difference(DateTime.now());
    final passed = left.isNegative;
    final (stateText, stateColor, stateIcon) = r.cancelled
        ? (s('rem_cancelled'), mine ? Colors.white : LC.danger, AppIcons.reminderOff)
        : passed
            ? (s('rem_passed'), mine ? Colors.white : LC.success, AppIcons.reminderDone)
            : (reminderCountdown(s, left), mine ? Colors.white : LC.warning, AppIcons.hourglass);
    final seenBy = r.seen.keys.toList();
    final iSaw = r.seen.containsKey(widget.myPeer);
    return SizedBox(
      width: 280,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconTile(r.cancelled ? AppIcons.reminderOff : AppIcons.reminder, color: mine ? Colors.white : (r.cancelled ? sub : LC.warning)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s('reminder'), style: TextStyle(fontSize: 12, color: sub, fontWeight: FontWeight.w600)),
              const SizedBox(height: 1),
              Text(
                r.title,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  decoration: r.cancelled ? TextDecoration.lineThrough : null,
                  decorationColor: sub,
                ),
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Icon(AppIcons.schedule, size: 15, color: sub),
          const SizedBox(width: 6),
          Expanded(child: Text(reminderWhen(s, r.at), style: TextStyle(color: fg, fontSize: 13.5, fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(color: stateColor.withValues(alpha: mine ? 0.18 : 0.12), borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(stateIcon, size: 13, color: stateColor),
            const SizedBox(width: 5),
            Text(stateText, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: stateColor, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        ),
        if (r.note.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(r.note, style: TextStyle(color: fg.withValues(alpha: 0.9), fontSize: 13.5, height: 1.35)),
        ],
        if (seenBy.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            Icon(AppIcons.show, size: 13, color: sub),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                s('rem_seen_by', {'names': seenBy.map((p) => _who(context, p, widget.myPeer, s)).join(', ')}),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: sub),
              ),
            ),
          ]),
        ],
        if (!r.cancelled && (!iSaw || mine)) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            if (!iSaw && !mine)
              _ReminderAction(icon: AppIcons.check, label: s('rem_seen'), filled: true, mine: mine, onTap: _seen),
            if (mine && !passed) _ReminderAction(icon: AppIcons.close, label: s('rem_cancel'), mine: mine, onTap: _cancel),
          ]),
        ],
      ]),
    );
  }
}

class _ReminderAction extends StatelessWidget {
  const _ReminderAction({required this.icon, required this.label, required this.onTap, required this.mine, this.filled = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool mine;
  final bool filled;
  @override
  Widget build(BuildContext context) {
    final c = mine ? Colors.white : LC.primary;
    return Material(
      color: filled ? c.withValues(alpha: mine ? 0.22 : 0.12) : Colors.transparent,
      shape: StadiumBorder(side: BorderSide(color: c.withValues(alpha: filled ? 0 : 0.5))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: c),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: c, fontWeight: FontWeight.w600, fontSize: 13)),
          ]),
        ),
      ),
    );
  }
}

// Settings › Nâng cao › Mã hoá video: what this device can use for video
// calls and what the last call used. Read-only — Lumora chooses by itself.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';

class VideoCodecInfo extends StatefulWidget {
  const VideoCodecInfo({super.key});

  @override
  State<VideoCodecInfo> createState() => _VideoCodecInfoState();
}

class _VideoCodecInfoState extends State<VideoCodecInfo> {
  Map<String, dynamic>? _st;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<LumoraApi>().request('video_codec');
      if (mounted && r is Map) setState(() => _st = Map<String, dynamic>.from(r));
      // the first probe on a new device takes a moment
      if (mounted && r is Map && r['h264'] == null && r['os_codec'] != null) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (mounted) _load();
      }
    } catch (_) {
      // older core without the command: show nothing
    }
  }

  static String _name(String? c) => switch (c) { 'h264' => 'H.264', 'vp8' => 'VP8', 'vp9' => 'VP9', _ => c ?? '' };

  String _caps(S s) {
    final st = _st!;
    final h = st['h264'];
    if (st['os_codec'] != null && h == null) return s('vc_checking');
    final caps = (st['caps'] as Map?) ?? const {};
    final hwEnc = (caps['hw_enc'] as List?)?.contains('h264') ?? false;
    final enc = (caps['enc'] as List?)?.contains('h264') ?? false;
    if (hwEnc) return s('vc_caps_hw');
    if (enc && st['os_codec'] != null) return s('vc_caps_os');
    return s('vc_caps_vpx');
  }

  String? _used(S s, Object? a) {
    if (a is! Map) return null;
    return '${_name(a['format']?.toString())} · ${s(a['hardware'] == true ? 'vc_hw' : 'vc_sw')}';
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final st = _st;
    if (st == null) return const SizedBox.shrink();
    final enc = _used(s, st['encoder']);
    final dec = _used(s, st['decoder']);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: const RowIcon(AppIcons.video),
        title: Text(s('vc_this_device')),
        subtitle: Text(_caps(s)),
      ),
      if (enc != null || dec != null)
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: const RowIcon(AppIcons.call),
          title: Text(s('vc_last_call')),
          subtitle: Text([if (enc != null) '${s('vc_send')}: $enc', if (dec != null) '${s('vc_receive')}: $dec'].join('   ')),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
        child: Text(s('vc_hint'), style: context.tt.bodySmall?.copyWith(height: 1.4)),
      ),
    ]);
  }
}

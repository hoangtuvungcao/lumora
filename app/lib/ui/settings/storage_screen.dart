// Settings › Storage & data: what Lumora keeps on disk, how much room is
// left, the core's storage policy and one-tap clean-up actions.

import 'dart:io';

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../app.dart';
import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../chats/chat_info.dart' show RetentionTile;
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/peer_avatar.dart';

/// "Always download" sentinel for the auto-download limits (1 PiB).
const kAutoAlways = kAutoDownloadAlways;

const _gb = 1 << 30;
const _mb = 1 << 20;
const _maxCacheOptions = [1 * _gb, 2 * _gb, 5 * _gb, 10 * _gb, 20 * _gb, 0];
const _mediaDayOptions = [7, 30, 90, 0];

/// Auto-download choices per kind of media.
const _autoOptions = {
  'photo': [0, 1 * _mb, 5 * _mb, 10 * _mb, 25 * _mb, kAutoAlways],
  'video': [0, 5 * _mb, 10 * _mb, 25 * _mb, 50 * _mb, 100 * _mb, kAutoAlways],
  'file': [0, 1 * _mb, 5 * _mb, 10 * _mb, 25 * _mb, 50 * _mb, 100 * _mb, kAutoAlways],
  'voice': [0, 1 * _mb, 5 * _mb, 25 * _mb, kAutoAlways],
};
const _communityDayOptions = [7, 30, 90, 0];

/// Free and total bytes of the disk holding [dir] (desktop only; null if unknown).
Future<(int, int)?> diskSpace(String dir) async {
  if (!(Platform.isLinux || Platform.isMacOS)) return null;
  try {
    var d = Directory(dir.isEmpty ? Directory.systemTemp.path : dir);
    while (!d.existsSync() && d.parent.path != d.path) {
      d = d.parent;
    }
    final r = await Process.run('df', ['-Pk', d.path]);
    final line = '${r.stdout}'.trim().split('\n').last.split(RegExp(r'\s+'));
    final total = int.parse(line[1]) * 1024, free = int.parse(line[3]) * 1024;
    return (free, total);
  } catch (_) {
    return null;
  }
}

/// Confirms, then removes downloaded media (all chats, or one when [conv] is set).
Future<void> confirmClearMedia(BuildContext context, {String? conv, String? title}) async {
  final s = S.read(context);
  final net = context.read<NetStore>();
  final ok = await confirm(
    context,
    title: conv == null ? s('st_clear_media_title') : s('st_clear_media_title_chat', {'name': title ?? ''}),
    body: s('st_clear_media_body'),
    action: s('delete'),
    danger: true,
  );
  if (!ok || !context.mounted) return;
  try {
    final freed = await net.clearMedia(conv: conv);
    if (context.mounted) toast(context, freed > 0 ? s('st_media_cleared', {'size': s.bytes(freed)}) : s('st_no_files'));
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

class StorageSettings extends StatefulWidget {
  const StorageSettings({super.key});
  @override
  State<StorageSettings> createState() => _StorageSettingsState();
}

class _StorageSettingsState extends State<StorageSettings> {
  bool _cleaning = false;
  bool _allChats = false;
  (int, int)? _disk;

  @override
  void initState() {
    super.initState();
    final net = context.read<NetStore>();
    net.loadStorage().catchError((_) {});
    diskSpace(context.read<AppServices>().dataDir).then((d) {
      if (mounted && d != null) setState(() => _disk = d);
    });
  }

  Future<void> _cleanUp() async {
    final s = S.read(context);
    setState(() => _cleaning = true);
    try {
      final freed = await context.read<NetStore>().cleanUp();
      if (mounted) toast(context, freed > 0 ? s('st_cleaned', {'size': s.bytes(freed)}) : s('st_cleaned_none'));
    } catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => _cleaning = false);
    }
  }

  Future<void> _set(String key, int value) async {
    try {
      await context.read<NetStore>().setStoragePolicy({key: value});
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final st = context.select<NetStore, Map<String, dynamic>?>((n) => n.storage);
    if (st == null) return const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()));
    int v(String k) => (st[k] as num?)?.toInt() ?? 0;
    final db = v('db_bytes'), media = v('media_bytes');
    // The core may report the disk itself; otherwise ask the OS (desktop).
    final free = st['free_bytes'] is num ? v('free_bytes') : _disk?.$1;
    final total = st['disk_bytes'] is num ? v('disk_bytes') : _disk?.$2;
    final low = st['low_disk'] == true || (free != null && free < _gb);
    final policy = StoragePolicy.fromJson((st['policy'] as Map?)?.cast<String, dynamic>() ?? const {});
    final byConv = ((st['by_conv'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .where((e) => ((e['media_bytes'] as num?) ?? 0) + ((e['message_bytes'] as num?) ?? 0) > 0)
        .toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (low) ...[_LowDiskBanner(onClean: _cleaning ? null : _cleanUp), const SizedBox(height: 16)],
      _UsageCard(db: db, media: media, free: free, total: total),
      const SizedBox(height: 16),
      LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 560;
        final clean = _ActionCard(
          fill: wide,
          icon: AppIcons.sparkle,
          color: LC.primary,
          title: s('st_clean_now'),
          body: s('st_clean_hint'),
          button: GradientButton(label: s('st_clean_now'), icon: AppIcons.clean, busy: _cleaning, onPressed: _cleanUp),
        );
        final clear = _ActionCard(
          fill: wide,
          icon: AppIcons.imageBroken,
          color: LC.danger,
          title: s('st_clear_media'),
          body: s('st_clear_media_hint', {'size': s.bytes(media)}),
          button: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: LC.danger, side: BorderSide(color: LC.danger.withValues(alpha: 0.5)), minimumSize: const Size(0, 46)),
            onPressed: media > 0 ? () => confirmClearMedia(context) : null,
            icon: const Icon(AppIcons.delete, size: 18),
            label: Text(s('st_clear_media')),
          ),
        );
        if (!wide) return Column(children: [clean, const SizedBox(height: 12), clear]);
        return IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: clean),
            const SizedBox(width: 12),
            Expanded(child: clear),
          ]),
        );
      }),
      const SizedBox(height: 16),
      _Section(title: s('st_limits'), children: [
        _PickRow<int>(
          icon: AppIcons.storage,
          title: s('st_max_cache'),
          hint: s('st_max_cache_hint'),
          value: policy.maxCache,
          options: _maxCacheOptions,
          label: (x) => x == 0 ? s('st_unlimited') : '${x ~/ _gb} GB',
          onChanged: (x) => _set('max_cache', x),
        ),
        _PickRow<int>(
          icon: AppIcons.schedule,
          title: s('st_media_days'),
          hint: s('st_media_days_hint'),
          value: policy.mediaDays,
          options: _mediaDayOptions,
          label: (x) => x == 0 ? s('st_never') : s('st_after_days', {'n': x}),
          onChanged: (x) => _set('media_days', x),
        ),
      ]),
      _Section(title: s('st_auto_download'), footer: s('ad_hint'), children: [_AutoDownloadRows(policy: policy.autoDownload)]),
      _Section(title: s('st_history'), children: [
        _PickRow<int>(
          icon: AppIcons.timerReset,
          title: s('st_community_days'),
          hint: s('st_community_days_hint'),
          value: policy.communityDays,
          options: _communityDayOptions,
          label: (x) => x == 0 ? s('st_forever') : s('st_keep_days', {'n': x}),
          onChanged: (x) => _set('community_days', x),
        ),
      ]),
      if (byConv.isNotEmpty)
        _Section(title: s('st_by_chat'), footer: s('st_by_chat_hint'), children: [
          for (final e in byConv.take(_allChats ? byConv.length : 6)) _ConvUsageTile(row: e),
          if (byConv.length > 6 && !_allChats)
            TextButton(onPressed: () => setState(() => _allChats = true), child: Text(s('st_show_all', {'n': byConv.length}))),
        ]),
    ]);
  }

}

String _autoLabel(S s, int x) {
  if (x <= 0) return s('st_auto_off');
  if (x >= kAutoAlways) return s('st_auto_always');
  return s('st_auto_upto', {'size': x % _mb == 0 ? '${x ~/ _mb} MB' : s.bytes(x)});
}

/// "Automatic downloads": Wi-Fi / mobile data / roaming, then a limit per kind of media.
class _AutoDownloadRows extends StatefulWidget {
  const _AutoDownloadRows({required this.policy});
  final AutoDownload policy;
  @override
  State<_AutoDownloadRows> createState() => _AutoDownloadRowsState();
}

class _AutoDownloadRowsState extends State<_AutoDownloadRows> {
  String _net = 'wifi';

  Future<void> _set(String kind, int bytes) async {
    try {
      await context.read<NetStore>().setAutoDownload(_net, kind, bytes);
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final l = widget.policy.of(_net);
    Widget row(String kind, IconData icon) => _PickRow<int>(
          key: ValueKey('auto_${_net}_$kind'),
          icon: icon,
          title: s('ad_$kind'),
          hint: kind == 'file' && l.fileGroup < l.file ? s('ad_file_group_hint', {'size': _autoLabel(s, l.fileGroup)}) : null,
          value: l[kind],
          options: _autoOptions[kind]!,
          label: (x) => _autoLabel(s, x),
          onChanged: (x) => _set(kind, x),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: SegmentedButton<String>(
          key: const ValueKey('auto_network'),
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: 'wifi', label: _SegLabel(s('ad_wifi'))),
            ButtonSegment(value: 'cell', label: _SegLabel(s('ad_cell_short'))),
            ButtonSegment(value: 'roaming', label: _SegLabel(s('ad_roaming'))),
          ],
          selected: {_net},
          onSelectionChanged: (v) => setState(() => _net = v.first),
        ),
      ),
      Padding(
        key: const ValueKey('auto_net_hint'),
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 2),
        child: Text(s('ad_${_net}_hint'), style: context.tt.bodySmall?.copyWith(color: context.lc.muted)),
      ),
      row('photo', AppIcons.image),
      row('video', AppIcons.video),
      row('voice', AppIcons.voiceWave),
      row('file', AppIcons.file),
    ]);
  }
}

// ---------------------------------------------------------------- pieces

/// One segment label: a single line that shrinks rather than wraps on a narrow phone.
class _SegLabel extends StatelessWidget {
  const _SegLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1, softWrap: false));
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.footer});
  final String title;
  final String? footer;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionLabel(title, padding: const EdgeInsets.fromLTRB(4, 8, 4, 8)),
        LCard(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)),
        if (footer != null) Padding(padding: const EdgeInsets.fromLTRB(6, 8, 6, 0), child: Text(footer!, style: context.tt.bodySmall)),
        const SizedBox(height: 16),
      ]);
}

class _LowDiskBanner extends StatelessWidget {
  const _LowDiskBanner({required this.onClean});
  final VoidCallback? onClean;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: LC.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: LC.warning.withValues(alpha: 0.45)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(padding: EdgeInsets.only(top: 2), child: Icon(AppIcons.warning, color: LC.warning, size: 22)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s('st_low_title'), style: context.tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(s('st_low_body'), style: context.tt.bodySmall?.copyWith(color: context.lc.text, height: 1.45)),
            const SizedBox(height: 8),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: LC.warning, padding: const EdgeInsets.symmetric(horizontal: 8), visualDensity: VisualDensity.compact),
              onPressed: onClean,
              icon: const Icon(AppIcons.sparkle, size: 16),
              label: Text(s('st_clean_now'), style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.db, required this.media, this.free, this.total});
  final int db, media;
  final int? free, total;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final used = db + media;
    final sum = used <= 0 ? 1 : used;
    Widget legend(Color c, IconData icon, String label, int b) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(children: [
            IconTile(icon, color: c, size: IconTileSize.sm),
            const SizedBox(width: 12),
            Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500))),
            const SizedBox(width: 8),
            Text(s.bytes(b), style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            SizedBox(
              width: 48,
              child: Text('${(b * 100 / sum).round()}%', textAlign: TextAlign.right, style: context.tt.bodySmall),
            ),
          ]),
        );
    final f = free, t = total;
    return LCard(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(s('st_used_by'), style: context.tt.bodySmall),
        const SizedBox(height: 2),
        Text(s.bytes(used), style: context.tt.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5)),
        const SizedBox(height: 14),
        _Bar(parts: [(db, LC.primary), (media, LC.accent)], total: sum),
        const SizedBox(height: 8),
        legend(LC.primary, AppIcons.community, s('storage_db'), db),
        legend(LC.accent, AppIcons.image, s('st_media'), media),
        if (f != null) ...[
          Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Divider(height: 1, color: context.lc.divider)),
          Row(children: [
            Icon(AppIcons.storage, size: 18, color: f < _gb ? LC.warning : context.lc.muted),
            const SizedBox(width: 10),
            Expanded(child: Text(s('st_free'), style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500))),
            Text(s.bytes(f), style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w700, color: f < _gb ? LC.warning : null)),
          ]),
          if (t != null && t > 0) ...[
            const SizedBox(height: 10),
            // The whole disk: Lumora, everything else, and what's left.
            _Bar(parts: [(used, LC.primary), ((t - f - used).clamp(0, t), context.lc.muted.withValues(alpha: 0.28))], total: t, minPart: 0.006),
            const SizedBox(height: 8),
            Wrap(spacing: 14, runSpacing: 4, children: [
              _Dot(color: LC.primary, label: 'Lumora'),
              _Dot(color: context.lc.muted.withValues(alpha: 0.5), label: s('st_other_apps')),
              _Dot(color: context.lc.surface2, label: s('st_free_of', {'free': s.bytes(f), 'total': s.bytes(t)}), border: true),
            ]),
          ],
          const SizedBox(height: 4),
        ],
      ]),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.label, this.border = false});
  final Color color;
  final String label;
  final bool border;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
            border: border ? Border.all(color: context.lc.muted.withValues(alpha: 0.6)) : null,
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: context.tt.bodySmall),
      ]);
}

/// Rounded stacked bar; [parts] are (bytes, color), the rest is empty track.
class _Bar extends StatelessWidget {
  const _Bar({required this.parts, required this.total, this.minPart = 0.02});
  final List<(int, Color)> parts;
  final int total;
  final double minPart;
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(7),
      child: SizedBox(
        height: 12,
        child: LayoutBuilder(builder: (context, c) {
          var x = 0.0;
          final kids = <Widget>[];
          for (final (b, color) in parts) {
            if (b <= 0) continue;
            final w = (b / total).clamp(minPart, 1.0) * c.maxWidth;
            kids.add(Positioned(left: x, top: 0, bottom: 0, width: (w).clamp(0, c.maxWidth - x), child: ColoredBox(color: color)));
            x += w + 2; // hairline gap between parts
          }
          return Stack(children: [Positioned.fill(child: ColoredBox(color: context.lc.surface2)), ...kids]);
        }),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.icon, required this.color, required this.title, required this.body, required this.button, this.fill = false});
  final IconData icon;

  /// Pushes the button to the bottom (side-by-side cards of equal height).
  final bool fill;
  final Color color;
  final String title, body;
  final Widget button;
  @override
  Widget build(BuildContext context) => LCard(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            IconTile(icon, color: color),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: context.tt.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: 10),
          Text(body, style: context.tt.bodySmall?.copyWith(height: 1.45)),
          const SizedBox(height: 14),
          if (fill) const Spacer(),
          button,
        ]),
      );
}

/// Title + hint with a dropdown (beside it on wide layouts, below on phones).
class _PickRow<T> extends StatelessWidget {
  const _PickRow({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
    required this.value,
    required this.options,
    required this.label,
    required this.onChanged,
  });
  final IconData icon;
  final String title;
  final String? hint;
  final T value;
  final List<T> options;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final opts = options.contains(value) ? options : [...options, value];
    // (stacked under the title on a phone: starts where the title starts)
    DropdownButton<T> dropdown(bool wide) => DropdownButton<T>(
      value: value,
      isDense: true,
      alignment: wide ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
      underline: const SizedBox.shrink(),
      borderRadius: BorderRadius.circular(Radii.md),
      icon: const Padding(padding: EdgeInsets.only(left: 4), child: Icon(AppIcons.chevronDown, size: 16, color: LC.primary)),
      style: context.tt.bodyMedium?.copyWith(color: LC.primary, fontWeight: FontWeight.w600),
      items: [for (final o in opts) DropdownMenuItem(value: o, child: Text(label(o)))],
      onChanged: (v) {
        if (v != null && v != value) onChanged(v);
      },
    );
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
      if (hint != null) ...[const SizedBox(height: 2), Text(hint!, style: context.tt.bodySmall)],
    ]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 10),
      child: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 480;
        final drop = dropdown(wide);
        return Row(crossAxisAlignment: wide ? CrossAxisAlignment.center : CrossAxisAlignment.start, children: [
          Padding(padding: EdgeInsets.only(top: wide ? 0 : 2, right: 14), child: Icon(icon, size: 20, color: context.lc.muted)),
          Expanded(
            child: wide
                ? Row(children: [Expanded(child: text), const SizedBox(width: 12), drop])
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [text, const SizedBox(height: 6), drop]),
          ),
        ]);
      }),
    );
  }
}

Widget _convAvatar(String conv, String title, double size) {
  if (conv.startsWith('d:')) return PeerAvatar(peer: conv.substring(2), fallbackName: title, size: size, presence: false);
  if (conv.startsWith('s:')) return SavedAvatar(size: size);
  return GroupAvatar(gid: conv.startsWith('g:') ? conv.substring(2) : conv, name: title, size: size);
}

class _ConvUsageTile extends StatelessWidget {
  const _ConvUsageTile({required this.row});
  final Map<String, dynamic> row;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final conv = row['conv'] as String? ?? '';
    final title = context.select<ChatStore, String?>((c) => c.convs[conv]?.title) ?? row['title'] as String? ?? '';
    final media = (row['media_bytes'] as num?)?.toInt() ?? 0;
    final msgs = (row['message_bytes'] as num?)?.toInt() ?? 0;
    final n = (row['messages'] as num?)?.toInt() ?? 0;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: _convAvatar(conv, title, 38),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(s('st_chat_usage', {'n': n}), style: context.tt.bodySmall),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(s.bytes(media + msgs), style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(width: 6),
        Icon(AppIcons.chevronRight, size: 18, color: context.lc.muted),
      ]),
      onTap: () => showChatStorage(context, conv: conv, title: title, media: media, messages: n),
    );
  }
}

/// Per-conversation storage sheet: remove its media, auto-delete messages.
Future<void> showChatStorage(BuildContext context, {required String conv, required String title, required int media, required int messages}) {
  context.read<ChatStore>().loadRetention(conv);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (c) {
      final s = S.of(c);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              _convAvatar(conv, title, 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: c.tt.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text('${s('st_chat_usage', {'n': messages})} · ${s.bytes(media)}', style: c.tt.bodySmall),
                ]),
              ),
            ]),
            const SizedBox(height: 12),
            LCard(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Column(children: [
                RetentionTile(conv: conv),
                ListTile(
                  enabled: media > 0,
                  leading: const Icon(AppIcons.imageBroken, color: LC.danger),
                  title: Text(s('st_clear_media_chat'), style: TextStyle(color: media > 0 ? LC.danger : null)),
                  subtitle: Text(media > 0 ? s('st_clear_media_hint', {'size': s.bytes(media)}) : s('st_no_files'), style: c.tt.bodySmall),
                  onTap: () async {
                    Navigator.pop(c);
                    await confirmClearMedia(context, conv: conv, title: title);
                  },
                ),
              ]),
            ),
          ]),
        ),
      );
    },
  );
}

/// Chat info row: remove this conversation's downloaded media.
class ClearMediaTile extends StatelessWidget {
  const ClearMediaTile({super.key, required this.conv, required this.title});
  final String conv;
  final String title;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ListTile(
      leading: const RowIcon(AppIcons.imageBroken),
      title: Text(s('st_clear_media_chat')),
      subtitle: Text(s('st_clear_media_chat_hint'), style: context.tt.bodySmall),
      onTap: () => confirmClearMedia(context, conv: conv, title: title),
    );
  }
}

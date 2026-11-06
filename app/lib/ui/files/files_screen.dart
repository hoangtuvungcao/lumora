import 'dart:io';

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../chats/message_bubble.dart';
import '../chats/attachments.dart' show transferDetail;
import '../theme.dart';
import '../widgets/common.dart';
import '../../state/app_lock.dart';

class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});
  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  int _filter = 0; // 0 all, 1 active, 2 incoming, 3 outgoing

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    // Files of locked chats stay out until the "Locked" folder is opened.
    final lock = context.watch<AppLock>();
    final all = context.watch<FilesStore>().sorted.where((f) => !lock.isChatHidden(f.conv)).toList();
    final list = all.where((f) {
      return switch (_filter) {
        1 => f.active,
        2 => f.incoming,
        3 => !f.incoming,
        _ => true,
      };
    }).toList();
    final active = all.where((f) => f.state == FileState.transferring).toList();
    final totalSpeed = active.fold<int>(0, (a, f) => a + (f.speedBps ?? 0));
    final content = Column(children: [
      PaneHeader(
        leading: const Icon(AppIcons.transfers, color: LC.primary),
        title: Text(s('files')),
        subtitle: Text(active.isEmpty ? s('no_active_transfers') : s('n_active_transfers', {'n': active.length, 'speed': s.speed(totalSpeed)})),
      ),
      SizedBox(
        height: 52,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          children: [
            for (final (i, k) in [(0, 'filter_all'), (1, 'in_progress'), (2, 'received'), (3, 'sent')])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(label: Text(s(k)), selected: _filter == i, onSelected: (_) => setState(() => _filter = i)),
              ),
          ],
        ),
      ),
      Expanded(
        child: list.isEmpty
            ? EmptyState(icon: AppIcons.folder, title: s('no_files'), subtitle: s('no_files_hint'))
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _TransferTile(file: list[i]),
              ),
      ),
    ]);
    return Material(color: context.lc.bg, child: isDesktop(context) ? content : Scaffold(body: SafeArea(child: content)));
  }
}

class _TransferTile extends StatelessWidget {
  const _TransferTile({required this.file});
  final FileItem file;

  Future<void> _openFolder(BuildContext context) async {
    final path = file.path.replaceFirst('~', Platform.environment['HOME'] ?? '~');
    final dir = File(path).parent.path;
    final ok = await launchUrl(Uri.file(dir)).catchError((_) => false);
    if (!ok && context.mounted) copyText(context, dir, message: S.read(context)('path_copied'));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final f = file;
    final store = context.read<FilesStore>();
    final peer = context.select<ContactsStore, String>((c) => c.nameOf(f.peer));
    final (color, label) = switch (f.state) {
      FileState.offered => (LC.accent, f.incoming ? s('file_offered') : s('file_waiting')),
      FileState.transferring => (LC.primary, '${(f.fraction * 100).toStringAsFixed(0)}%'),
      FileState.paused => (LC.warning, s('paused')),
      FileState.done => (LC.success, s('done')),
      FileState.failed => (LC.danger, s('file_failed')),
      FileState.cancelled => (context.lc.muted, s('file_cancelled')),
    };
    final narrow = MediaQuery.sizeOf(context).width < 600;
    String detail;
    if (f.state == FileState.transferring || f.state == FileState.paused) {
      final remain = (f.speedBps ?? 0) > 0 ? Duration(seconds: ((f.size - f.progress) / f.speedBps!).round()) : null;
      detail = transferDetail(s, f) +
          (remain != null && f.progress > 0 && f.state == FileState.transferring ? ' · ${s('time_left', {'t': s.duration(remain)})}' : '');
    } else {
      detail = s.bytes(f.size);
    }
    return LCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Column(children: [
        Row(children: [
          IconTile(fileIcon(f.name), color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleSmall),
              const SizedBox(height: 2),
              Row(children: [
                // Small phones: the status may take the row, never more.
                if (narrow) ...[Flexible(flex: 3, child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Pill(label, color: color))), const SizedBox(width: 6)],
                Icon(f.incoming ? AppIcons.incoming : AppIcons.outgoing, size: 13, color: context.lc.muted),
                const SizedBox(width: 4),
                Flexible(
                  flex: 2,
                  child: Text('${f.incoming ? s('from_x', {'name': peer}) : s('to_x', {'name': peer})} · $detail',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall),
                ),
              ]),
            ]),
          ),
          if (!narrow) ...[const SizedBox(width: 8), Pill(label, color: color)],
          const SizedBox(width: 4),
          if (f.state == FileState.offered && f.incoming)
            ToolButton(icon: AppIcons.download, tooltip: s('download'), color: LC.accent, onPressed: () => store.accept(f.id)),
          if (f.state == FileState.transferring || f.state == FileState.paused)
            ToolButton(
              icon: f.state == FileState.paused ? AppIcons.play : AppIcons.pause,
              tooltip: f.state == FileState.paused ? s('resume') : s('pause'),
              onPressed: () => store.togglePause(f.id),
            ),
          if (f.active) ToolButton(icon: AppIcons.close, tooltip: s('cancel'), onPressed: () => store.cancel(f.id)),
          if (f.state == FileState.done) ToolButton(icon: AppIcons.folder, tooltip: s('open_folder'), onPressed: () => _openFolder(context)),
        ]),
        if (f.state == FileState.transferring || f.state == FileState.paused) ...[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: f.fraction),
                duration: Motion.slow,
                builder: (_, v, _) => LinearProgressIndicator(value: v, minHeight: 6, color: color),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

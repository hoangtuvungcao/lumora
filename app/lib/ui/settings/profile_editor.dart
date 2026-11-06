import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../profile/profile_screen.dart';
import '../widgets/image_crop.dart';
import '../widgets/peer_avatar.dart';

const kStatuses = ['online', 'away', 'dnd', 'invisible'];

/// Center-crops and resizes an image to a square PNG ≤ [maxBytes]
/// (tries 256 → 128 px).
Future<Uint8List?> resizeAvatar(Uint8List input, {int maxBytes = 96 * 1024}) async {
  for (final size in [256, 224, 192, 160, 128]) {
    final codec = await ui.instantiateImageCodec(input);
    final frame = await codec.getNextFrame();
    final src = frame.image;
    final side = src.width < src.height ? src.width : src.height;
    final rect = Rect.fromLTWH((src.width - side) / 2, (src.height - side) / 2, side.toDouble(), side.toDouble());
    final rec = ui.PictureRecorder();
    Canvas(rec).drawImageRect(src, rect, Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
        Paint()..filterQuality = FilterQuality.high);
    final out = await rec.endRecording().toImage(size, size);
    final png = await out.toByteData(format: ui.ImageByteFormat.png);
    src.dispose();
    out.dispose();
    codec.dispose();
    if (png != null && png.lengthInBytes <= maxBytes) return png.buffer.asUint8List();
  }
  return null;
}

Future<void> pickAvatar(BuildContext context) async {
  final session = context.read<SessionStore>();
  final bytes = await pickAndCropImage(context, CropSpec.avatar);
  if (bytes == null) return;
  try {
    await session.saveProfile(avatar: bytes);
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

Future<void> pickCover(BuildContext context) async {
  final session = context.read<SessionStore>();
  final bytes = await pickAndCropImage(context, CropSpec.cover);
  if (bytes == null) return;
  try {
    await session.saveCover(bytes);
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

String statusLabel(S s, String st) => s('status_$st');

/// Profile popover opened from the user panel / avatar.
Future<void> showProfileMenu(BuildContext context, {Offset? at}) async {
  final s = S.read(context);
  final session = context.read<SessionStore>();
  final r = await showMenu<String>(
    context: context,
    position: at == null ? const RelativeRect.fromLTRB(80, 600, 80, 0) : RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
    constraints: const BoxConstraints(minWidth: 280, maxWidth: 300),
    items: [
      PopupMenuItem<String>(
        enabled: false,
        child: Builder(builder: (context) {
          final me = session.me;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              PeerAvatar(peer: me?.peer ?? '', size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(me?.name ?? '', style: context.tt.titleMedium),
                  if (session.profile.bio.isNotEmpty)
                    Text(session.profile.bio, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall),
                ]),
              ),
            ]),
          );
        }),
      ),
      const PopupMenuDivider(),
      for (final st in kStatuses)
        PopupMenuItem<String>(
          value: 'status:$st',
          height: 40,
          child: Row(children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: st == 'invisible' ? Colors.transparent : presenceColor(st),
                shape: BoxShape.circle,
                border: st == 'invisible' ? Border.all(color: const Color(0xFF9AA0C3), width: 2.5) : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(statusLabel(s, st))),
            if (session.profile.status == st) const Icon(AppIcons.check, size: 18, color: LC.primary),
          ]),
        ),
      const PopupMenuDivider(),
      PopupMenuItem<String>(
        value: 'profile',
        child: Row(children: [const Icon(AppIcons.profile, size: 18), const SizedBox(width: 12), Text(s('my_profile'))]),
      ),
      PopupMenuItem<String>(
        value: 'edit',
        child: Row(children: [const Icon(AppIcons.edit, size: 18), const SizedBox(width: 12), Text(s('edit_profile'))]),
      ),
      PopupMenuItem<String>(
        value: 'copy',
        child: Row(children: [const Icon(AppIcons.copy, size: 18), const SizedBox(width: 12), Text(s('copy_id'))]),
      ),
    ],
  );
  if (r == null || !context.mounted) return;
  if (r.startsWith('status:')) {
    session.setStatus(r.substring(7));
  } else if (r == 'profile') {
    openProfile(context, session.me?.peer ?? '');
  } else if (r == 'edit') {
    showProfileEditor(context);
  } else if (r == 'copy') {
    copyText(context, session.me?.shortId ?? '');
  }
}

Future<void> showProfileEditor(BuildContext context) {
  return showDialog<void>(context: context, builder: (_) => const Dialog(child: SizedBox(width: 440, child: SingleChildScrollView(child: ProfileEditor()))));
}

class ProfileEditor extends StatefulWidget {
  const ProfileEditor({super.key, this.inline = false});
  final bool inline;
  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  late final SessionStore _session = context.read<SessionStore>();
  late String _shownName = _session.me?.name ?? '';
  late String _shownBio = _session.profile.bio;
  late final _name = TextEditingController(text: _shownName);
  late final _bio = TextEditingController(text: _shownBio);
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _session.addListener(_follow);
  }

  /// Name / bio changed on another of my devices: the fields show it, unless
  /// they are being edited here.
  void _follow() {
    final name = _session.me?.name ?? '';
    final bio = _session.profile.bio;
    if (name != _shownName) {
      if (_name.text == _shownName) _name.text = name;
      _shownName = name;
    }
    if (bio != _shownBio) {
      if (_bio.text == _shownBio) _bio.text = bio;
      _shownBio = bio;
    }
  }

  @override
  void dispose() {
    _session.removeListener(_follow);
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await _session.saveProfile(name: _name.text.trim(), bio: _bio.text.trim());
      if (mounted && !widget.inline) Navigator.pop(context);
      if (mounted && widget.inline) toast(context, S.read(context)('saved'));
    } catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final me = context.select<SessionStore, String>((x) => x.me?.peer ?? '');
    final status = context.select<SessionStore, String>((x) => x.profile.status);
    return Padding(
      padding: EdgeInsets.all(widget.inline ? 0 : 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!widget.inline) ...[Text(s('edit_profile'), style: context.tt.titleLarge), const SizedBox(height: 20)],
        Center(
          child: Stack(children: [
            PeerAvatar(peer: me, size: 96, presence: false),
            Positioned(
              right: 0,
              bottom: 0,
              child: Material(
                color: LC.primary,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => pickAvatar(context),
                  child: const Padding(padding: EdgeInsets.all(8), child: Icon(AppIcons.camera, size: 18, color: Colors.white)),
                ),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 6),
        Center(child: Text(s('avatar_hint'), style: context.tt.bodySmall)),
        const SizedBox(height: 14),
        // Live preview: how friends see you.
        ListenableBuilder(
          listenable: Listenable.merge([_name, _bio]),
          builder: (context, _) => Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [LC.primary.withValues(alpha: 0.16), LC.accent.withValues(alpha: 0.10)]),
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
            child: Row(children: [
              PeerAvatar(peer: me, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_name.text.isEmpty ? '…' : _name.text, style: context.tt.titleSmall),
                  Text(
                    _bio.text.isEmpty ? statusLabel(s, status) : _bio.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.tt.bodySmall,
                  ),
                ]),
              ),
              Pill(s('preview'), color: LC.primary),
            ]),
          ),
        ),
        const SizedBox(height: 18),
        TextField(controller: _name, maxLength: 40, decoration: InputDecoration(labelText: s('display_name'), counterText: '')),
        const SizedBox(height: 12),
        TextField(
          controller: _bio,
          maxLength: 140,
          minLines: 2,
          maxLines: 3,
          decoration: InputDecoration(labelText: s('bio'), hintText: s('bio_hint'), alignLabelWithHint: true),
        ),
        const SizedBox(height: 4),
        _UsernameField(session: _session),
        const SizedBox(height: 8),
        Text(s('status'), style: context.tt.labelLarge),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final st in kStatuses)
            ChoiceChip(
              selected: status == st,
              onSelected: (_) => _session.setStatus(st),
              avatar: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: st == 'invisible' ? Colors.transparent : presenceColor(st),
                  shape: BoxShape.circle,
                  border: st == 'invisible' ? Border.all(color: const Color(0xFF9AA0C3), width: 2) : null,
                ),
              ),
              label: Text(statusLabel(s, st)),
            ),
        ]),
        const SizedBox(height: 20),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          if (!widget.inline) TextButton(onPressed: () => Navigator.pop(context), child: Text(s('cancel'))),
          const SizedBox(width: 8),
          FilledButton(onPressed: _busy ? null : _save, child: Text(s('save'))),
        ]),
      ]),
    );
  }
}


/// "Tên người dùng": @name·tag with copy/share.
class _UsernameField extends StatefulWidget {
  const _UsernameField({required this.session});
  final SessionStore session;
  @override
  State<_UsernameField> createState() => _UsernameFieldState();
}

class _UsernameFieldState extends State<_UsernameField> {
  late String _shown = widget.session.me?.username ?? '';
  late final _c = TextEditingController(text: _shown);
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_follow);
  }

  /// Set on another of my devices: shown here unless being edited.
  void _follow() {
    final u = widget.session.me?.username ?? '';
    if (u == _shown) return;
    if (_c.text == _shown) _c.text = u;
    _shown = u;
  }

  @override
  void dispose() {
    widget.session.removeListener(_follow);
    _c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.setUsername(_c.text.trim().replaceAll('@', ''));
    } catch (e) {
      setState(() => _error = errorMessage(S.read(context), e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final handle = context.select<SessionStore, String?>((x) => x.me?.handle);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _c,
        decoration: InputDecoration(
          labelText: s('username'),
          prefixText: '@',
          helperText: s('username_hint'),
          errorText: _error,
          suffixIcon: IconButton(onPressed: _busy ? null : _save, icon: const Icon(AppIcons.check, size: 18), tooltip: s('save')),
        ),
        onSubmitted: (_) => _save(),
      ),
      if (handle != null && handle.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(children: [
            Icon(AppIcons.mention, size: 15, color: context.lc.muted),
            const SizedBox(width: 6),
            Expanded(child: SelectableText(handle, style: const TextStyle(fontWeight: FontWeight.w600))),
            IconButton(tooltip: s('copy'), onPressed: () => copyText(context, handle), icon: const Icon(AppIcons.copy, size: 16)),
          ]),
        ),
    ]);
  }
}

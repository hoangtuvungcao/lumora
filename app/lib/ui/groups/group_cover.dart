// Group / community cover banner (the picture, a seeded gradient when there
// is none) and the flows around it: pick → crop → compress → upload, remove,
// and deleting a group / community for everyone (owner only).

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app.dart';
import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/image_crop.dart';

/// The cover of [gid], filling its box: the picture (fetched again when
/// [rev] changes) or a soft gradient seeded by the group id.
class GroupCoverImage extends StatelessWidget {
  const GroupCoverImage({super.key, required this.gid, required this.hasCover, this.rev = ''});
  final String gid;
  final bool hasCover;
  final String rev;

  @override
  Widget build(BuildContext context) {
    context.watch<AvatarStore>();
    final Uint8List? bytes = context.read<AvatarStore>().groupCover(gid, hasCover: hasCover, rev: rev);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return AnimatedSwitcher(
      duration: Motion.slow,
      child: bytes != null
          ? Image.memory(
              bytes,
              key: ValueKey(identityHashCode(bytes)),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              cacheWidth: (720 * dpr).round(),
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => GroupCoverPlaceholder(seed: gid),
            )
          : GroupCoverPlaceholder(key: const ValueKey('cover_placeholder'), seed: gid),
    );
  }
}

/// No cover yet: a two-tone gradient in the group's own hue with a soft glow,
/// so every community looks a little different.
class GroupCoverPlaceholder extends StatelessWidget {
  const GroupCoverPlaceholder({super.key, required this.seed});
  final String seed;

  @override
  Widget build(BuildContext context) {
    var h = 0;
    for (final c in seed.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    final hue = (h % 360).toDouble();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final a = HSLColor.fromAHSL(1, hue, 0.62, dark ? 0.42 : 0.56).toColor();
    final b = HSLColor.fromAHSL(1, (hue + 48) % 360, 0.70, dark ? 0.30 : 0.46).toColor();
    return SizedBox.expand(
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [a, b])),
        child: Stack(fit: StackFit.expand, children: [
          // a soft light from the top right
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.8, -0.9),
                radius: 1.1,
                colors: [Colors.white.withValues(alpha: 0.28), Colors.white.withValues(alpha: 0)],
              ),
            ),
          ),
          CustomPaint(painter: _Rings(Colors.white.withValues(alpha: 0.10))),
        ]),
      ),
    );
  }
}

class _Rings extends CustomPainter {
  _Rings(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color;
    final c = Offset(size.width * 0.86, size.height * 0.1);
    final r = math.max(size.width, size.height) * 0.22;
    for (var i = 1; i <= 4; i++) {
      canvas.drawCircle(c, r * i, p);
    }
  }

  @override
  bool shouldRepaint(_Rings old) => old.color != color;
}

/// Pick → crop (16:9) → JPEG ≤ 300 KB → `group_meta` cover. True when set.
Future<bool> pickGroupCover(BuildContext context, String gid) async {
  final s = S.read(context);
  final api = context.read<LumoraApi>();
  final avatars = context.read<AvatarStore>();
  final bytes = await pickAndCropImage(context, CropSpec.groupCover);
  if (bytes == null || !context.mounted) return false;
  if (bytes.length > kGroupCoverMaxBytes) {
    toast(context, s('cover_too_big'));
    return false;
  }
  try {
    await api.groupMeta(gid, cover: base64Encode(bytes));
    avatars.setGroupCover(gid, bytes);
    if (context.mounted) showTopToast(context, s('cover_updated'));
    return true;
  } catch (e) {
    if (context.mounted) toastError(context, e);
    return false;
  }
}

/// Removes the cover (confirmed). True when removed.
Future<bool> removeGroupCover(BuildContext context, String gid, String name) async {
  final s = S.read(context);
  final api = context.read<LumoraApi>();
  final avatars = context.read<AvatarStore>();
  if (!await confirm(context, title: s('remove_cover'), body: s('remove_cover_body', {'name': name}), action: s('remove'), danger: true)) return false;
  try {
    await api.groupMeta(gid, cover: '');
    avatars.setGroupCover(gid, null);
    return true;
  } catch (e) {
    if (context.mounted) toastError(context, e);
    return false;
  }
}

/// Owner only: deletes the group / community for everyone (confirmed). Its
/// chats, rail icon and open panes go at once. True when deleted — the
/// caller closes its own page.
Future<bool> dissolveGroup(BuildContext context, {required String gid, required String name, required bool community}) async {
  final s = S.read(context);
  final ok = await confirm(
    context,
    title: s(community ? 'delete_space' : 'delete_group_all'),
    body: s(community ? 'delete_space_body' : 'delete_group_all_body', {'name': name}),
    action: s('delete_for_everyone_short'),
    danger: true,
  );
  if (!ok || !context.mounted) return false;
  final api = context.read<LumoraApi>();
  final hub = context.read<AppServices>().hub;
  final chat = context.read<ChatStore>();
  final spaces = context.read<SpacesStore>();
  final nav = context.read<NavStore>();
  final conv = 'g:$gid';
  hub.dissolvedHere.add(gid); // this screen says so, not a second notice
  try {
    await api.groupDissolve(gid);
  } catch (e) {
    hub.dissolvedHere.remove(gid);
    if (context.mounted) toastError(context, e);
    return false;
  }
  chat.onGroupRemoved(conv, left: true);
  spaces.forget(gid);
  final open = nav.conv;
  if (open != null && (open == conv || open.startsWith('$conv#'))) nav.openConv(null);
  nav.toggleInfo(false);
  if (nav.section == Section.space && nav.spaceId == gid) {
    nav.spaceId = null;
    nav.channelConv = null;
    nav.go(Section.chats);
  }
  if (context.mounted) showTopToast(context, s(community ? 'space_deleted' : 'group_deleted', {'name': name}), duration: const Duration(seconds: 3));
  return true;
}

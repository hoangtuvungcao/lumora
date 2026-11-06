import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../state/stores.dart';
import 'common.dart';

/// Avatar for a contact (or me): real picture when available, gradient
/// initials otherwise, with an optional presence dot.
class PeerAvatar extends StatelessWidget {
  const PeerAvatar({super.key, required this.peer, this.size = 40, this.presence = true, this.fallbackName, this.ringColor});
  final String peer;
  final double size;
  final bool presence;
  final String? fallbackName;
  final Color? ringColor;

  @override
  Widget build(BuildContext context) {
    final me = context.select<SessionStore, String?>((s) => s.me?.peer);
    if (peer == me) {
      final name = context.select<SessionStore, String>((s) => s.me?.name ?? '');
      final img = context.select<SessionStore, Uint8List?>((s) => s.avatarBytes);
      final status = context.select<SessionStore, String>((s) => s.profile.status);
      return Avatar(
        name: name,
        seed: peer,
        size: size,
        image: img,
        ringColor: ringColor,
        presence: presence ? (status == 'invisible' ? 'offline' : status) : null,
      );
    }
    final c = context.select<ContactsStore, Contact?>((x) => x[peer]);
    context.watch<AvatarStore>();
    final img = context.read<AvatarStore>().of(peer, hasAvatar: c?.hasAvatar ?? false);
    return Avatar(
      name: c?.displayName ?? fallbackName ?? '?',
      seed: peer,
      size: size,
      image: img,
      ringColor: ringColor,
      presence: presence && c != null ? c.presenceKey : null,
    );
  }
}

/// Bookmark avatar for "Saved messages".
class SavedAvatar extends StatelessWidget {
  const SavedAvatar({super.key, this.size = 40});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF3B82F6), Color(0xFF00C2D1)]),
        ),
        child: Icon(AppIcons.bookmark, color: Colors.white, size: size * 0.5),
      );
}

/// Group / community avatar: uploaded picture or emoji/initials tile.
class GroupAvatar extends StatelessWidget {
  const GroupAvatar({super.key, required this.gid, required this.name, this.size = 40});
  final String gid;
  final String name;
  final double size;
  @override
  Widget build(BuildContext context) {
    context.watch<AvatarStore>();
    final img = context.read<AvatarStore>().group(gid);
    return Avatar(name: name, seed: 'g:$gid', size: size, group: true, image: img);
  }
}

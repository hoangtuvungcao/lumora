import 'dart:async';

import 'package:flutter/material.dart';

import 'app_icons.dart';
import '../../core/api.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import '../theme.dart';

const kDesktopBreakpoint = 900.0;

bool isDesktop(BuildContext context) => MediaQuery.sizeOf(context).width >= kDesktopBreakpoint;

// ------------------------------------------------------------------ avatar

const _avatarPalette = [
  [Color(0xFF6C5CE7), Color(0xFF00C2D1)],
  [Color(0xFFEC4899), Color(0xFFF59E0B)],
  [Color(0xFF22C55E), Color(0xFF00C2D1)],
  [Color(0xFF3B82F6), Color(0xFF6C5CE7)],
  [Color(0xFFF97316), Color(0xFFEF4444)],
  [Color(0xFF14B8A6), Color(0xFF3B82F6)],
  [Color(0xFFA855F7), Color(0xFFEC4899)],
  [Color(0xFF0EA5E9), Color(0xFF22C55E)],
];

String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  String first(String p) {
    final r = p.runes.first;
    return String.fromCharCode(r).toUpperCase();
  }

  // Vietnamese names: family name first, given name last.
  if (parts.length == 1) return first(parts[0]);
  return first(parts[parts.length - 2]) + first(parts.last);
}

class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.name,
    this.seed,
    this.size = 40,
    this.online,
    this.group = false,
    this.ringColor,
    this.image,
    this.presence,
  });

  final String name;
  final String? seed;
  final double size;
  final bool? online;
  final bool group;
  final Color? ringColor;

  /// Decoded avatar bytes (PNG/JPEG); decoded at display size.
  final Uint8List? image;

  /// online | away | dnd | offline — overrides [online] for the dot colour.
  final String? presence;

  @override
  Widget build(BuildContext context) {
    final key = (seed ?? name).codeUnits.fold<int>(0, (a, c) => (a * 31 + c) & 0x7fffffff);
    final pal = _avatarPalette[key % _avatarPalette.length];
    final initials = initialsOf(name);
    final emoji = _leadingEmoji(name);
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    Widget circle = image != null
        ? Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: group ? BoxShape.rectangle : BoxShape.circle,
              borderRadius: group ? BorderRadius.circular(size * 0.32) : null,
              border: ringColor != null ? Border.all(color: ringColor!, width: 2.5) : null,
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.memory(
              image!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheWidth: (size * dpr).round(),
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
            ),
          )
        : Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: group ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: group ? BorderRadius.circular(size * 0.32) : null,
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: pal),
        border: ringColor != null ? Border.all(color: ringColor!, width: 2.5) : null,
      ),
      alignment: Alignment.center,
      child: emoji != null && group
          ? Text(emoji, style: TextStyle(fontSize: size * 0.46))
          : Text(
              initials,
              style: TextStyle(
                fontFamily: kFontFamily,
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: size * (initials.length > 1 ? 0.36 : 0.42),
                letterSpacing: 0.2,
              ),
            ),
    );
    final pres = presence ?? (online == null ? null : (online! ? 'online' : 'offline'));
    if (pres == null) return circle;
    final show = pres != 'offline';
    final dotColor = presenceColor(pres);
    final dot = size * 0.3;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        circle,
        Positioned(
          right: -1,
          bottom: -1,
          child: AnimatedContainer(
            duration: Motion.normal,
            width: dot,
            height: dot,
            decoration: BoxDecoration(
              color: show ? dotColor : Colors.transparent,
              shape: BoxShape.circle,
              border: Border.all(color: show ? context.lc.surface : Colors.transparent, width: size * 0.06),
            ),
            child: pres == 'dnd' && size >= 32
                ? Center(child: Container(width: dot * 0.45, height: dot * 0.12, color: context.lc.surface))
                : null,
          ),
        ),
      ]),
    );
  }

  static String? _leadingEmoji(String name) {
    final runes = name.runes.toList();
    if (runes.isEmpty) return null;
    final last = runes.last;
    if (last > 0x2600) {
      // Trailing emoji in group names ("Gia đình 🏡") → use it as icon.
      var i = runes.length - 1;
      while (i > 0 && runes[i - 1] > 0x2600) {
        i--;
      }
      return String.fromCharCodes(runes.sublist(i));
    }
    return null;
  }
}

Color presenceColor(String p) => switch (p) {
      'online' => LC.success,
      'away' => LC.warning,
      'dnd' => LC.danger,
      _ => const Color(0xFF9AA0C3),
    };

// ------------------------------------------------------------------ badges

class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key, this.muted = false});
  final int count;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: muted ? context.lc.muted.withValues(alpha: 0.5) : LC.primary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        textAlign: TextAlign.center,
        count > 99 ? '99+' : '$count',
        style: const TextStyle(fontFamily: kFontFamily, color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700, height: 1.1),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, required this.color, this.icon, this.solid = false});
  final String label;
  final Color color;
  final IconData? icon;
  final bool solid;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: solid ? color : color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.xl),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: solid ? Colors.white : color),
          const SizedBox(width: 4),
        ],
        Text(label,
            style: TextStyle(
                fontFamily: kFontFamily, fontSize: 11.5, fontWeight: FontWeight.w600, color: solid ? Colors.white : color)),
      ]),
    );
  }
}

// ----------------------------------------------------------------- buttons

class GradientButton extends StatelessWidget {
  const GradientButton({super.key, required this.label, this.onPressed, this.icon, this.expand = false, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return AnimatedOpacity(
      duration: Motion.fast,
      opacity: enabled ? 1 : 0.55,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LC.gradient,
          borderRadius: BorderRadius.circular(Radii.md),
          boxShadow: kNoShadows ? null : [BoxShadow(color: LC.primary.withValues(alpha: 0.28), blurRadius: 16, offset: const Offset(0, 6))],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.md),
            onTap: enabled ? onPressed : null,
            child: Container(
              height: 46,
              width: expand ? double.infinity : null,
              padding: const EdgeInsets.symmetric(horizontal: 22),
              alignment: Alignment.center,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (busy)
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                else if (icon != null)
                  Icon(icon, color: Colors.white, size: 19),
                if (busy || icon != null) const SizedBox(width: 8),
                Text(label,
                    style: const TextStyle(fontFamily: kFontFamily, color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Square icon button with tooltip and hover background (desktop toolbars).
class ToolButton extends StatelessWidget {
  const ToolButton({super.key, required this.icon, required this.tooltip, this.onPressed, this.active = false, this.color, this.size = 20});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: size),
        color: color ?? (active ? LC.primary : context.lc.muted),
        style: IconButton.styleFrom(
          backgroundColor: active ? LC.primary.withValues(alpha: 0.14) : null,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sm)),
          minimumSize: const Size(38, 38),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- sections

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.padding = const EdgeInsets.fromLTRB(16, 18, 16, 8)});
  final String text;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(children: [
        Expanded(child: Text(text.toUpperCase(), style: context.tt.labelSmall)),
        ?trailing,
      ]),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.subtitle, this.action});
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          IconTile(icon, size: IconTileSize.lg),
          const SizedBox(height: 16),
          Text(title, style: context.tt.titleMedium, textAlign: TextAlign.center),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(subtitle!, style: context.tt.bodyMedium?.copyWith(color: context.lc.muted), textAlign: TextAlign.center),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 18), action!],
        ]),
      ),
    );
  }
}

/// Card with a title row, used throughout settings/network/remote.
class LCard extends StatelessWidget {
  const LCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.gradient = false});
  final Widget child;
  final EdgeInsets padding;
  final bool gradient;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: gradient ? null : context.lc.surface,
        gradient: gradient ? LC.gradient : null,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: gradient ? null : Border.all(color: context.lc.divider),
      ),
      child: child,
    );
  }
}

/// Header bar used at the top of content panes.
class PaneHeader extends StatelessWidget {
  const PaneHeader({super.key, required this.title, this.subtitle, this.leading, this.actions = const [], this.onBack});
  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    // Only pages that were pushed (not the root tabs) get a back arrow. Using
    // the enclosing route keeps this correct when other routes come and go.
    final canPop = onBack != null || (ModalRoute.of(context)?.canPop ?? false);
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: context.lc.bg,
        border: Border(bottom: BorderSide(color: context.lc.divider)),
      ),
      child: Row(children: [
        if (canPop)
          IconButton(
            icon: const Icon(AppIcons.back),
            tooltip: S.of(context)('back'),
            onPressed: onBack ?? () => Navigator.of(context).maybePop(),
          )
        else
          const SizedBox(width: 8),
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DefaultTextStyle(style: context.tt.titleMedium!, maxLines: 1, overflow: TextOverflow.ellipsis, child: title),
              if (subtitle != null)
                DefaultTextStyle(style: context.tt.bodySmall!, maxLines: 1, overflow: TextOverflow.ellipsis, child: subtitle!),
            ],
          ),
        ),
        ...actions,
        const SizedBox(width: 4),
      ]),
    );
  }
}

class SwitchRow extends StatelessWidget {
  const SwitchRow({super.key, required this.title, this.subtitle, required this.value, required this.onChanged, this.icon});
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(children: [
          if (icon != null) ...[RowIcon(icon!, size: 20, color: context.lc.muted), const SizedBox(width: 14)],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: context.tt.bodySmall),
              ],
            ]),
          ),
          const SizedBox(width: 12),
          Switch(value: value, onChanged: onChanged),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- helpers

Future<void> copyText(BuildContext context, String text, {String? message}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message ?? S.read(context)('copied')), duration: const Duration(seconds: 2)));
}

void toast(BuildContext context, String text) {
  // Technical details of the core error being shown (never in the toast itself).
  final detail = ApiException.detailFor(text) ?? (text.contains(': ') ? ApiException.detailFor(text.substring(text.indexOf(': ') + 2)) : null);
  // Known error codes from the app/core ("timeout", "send_file: timeout", …)
  // become friendly sentences.
  final code = text.contains(': ') ? text.substring(text.lastIndexOf(': ') + 2) : text;
  if (RegExp(r'^[a-z_]+$').hasMatch(code)) {
    try {
      text = S.read(context).orElse('err_$code', text);
    } catch (_) {}
  } else {
    // Core errors with a stable `err.*` code use the app's wording (same
    // language as the rest of the UI), keeping any "Send failed: " prefix.
    final cut = text.indexOf(': ');
    final whole = ApiException.codeFor(text);
    final tail = whole == null && cut > 0 ? ApiException.codeFor(text.substring(cut + 2)) : null;
    final c = whole ?? tail;
    if (c != null) {
      try {
        final t = S.read(context).orElse('err_${c.substring(4)}', '');
        if (t.isNotEmpty) text = whole != null ? t : '${text.substring(0, cut + 2)}$t';
      } catch (_) {}
    }
  }
  final s = S.read(context);
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(text),
      duration: Duration(seconds: detail == null ? 2 : 5),
      action: detail == null ? null : SnackBarAction(label: s('technical_details'), onPressed: () => showTechnicalDetails(context, detail)),
    ));
}

/// An error whose message is already a plain sentence for the user.
class UserMessageException implements Exception {
  const UserMessageException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Plain, translated sentence for any error: core errors keep their own
/// (already user-facing) message or use the app's wording for their code;
/// anything else (file system, platform, Dart exceptions) becomes
/// [fallbackKey] — the raw text is only reachable as technical details.
String errorMessage(S s, Object e, {String fallbackKey = 'err_internal'}) {
  if (e is ApiException) {
    final code = e.code;
    if (code != null && code.startsWith('err.')) {
      final t = s.orElse('err_${code.substring(4)}', '');
      if (t.isNotEmpty) return t;
    }
    final m = e.message;
    if (RegExp(r'^[a-z_]+$').hasMatch(m)) return s.orElse('err_$m', s(fallbackKey));
    return m;
  }
  if (e is UserMessageException) return e.message;
  if (e is TimeoutException) return s('err_timeout');
  return s(fallbackKey);
}

/// Raw details of [e] for the "Technical details" dialog (null = nothing
/// beyond the message).
String? errorDetails(Object e) {
  if (e is ApiException) {
    final cmd = e.cmd == null ? '' : '${e.cmd}: ';
    final d = e.detail;
    return d == null || d.isEmpty ? (RegExp(r'^[a-z_]+$').hasMatch(e.message) ? '$cmd${e.message}' : null) : '$cmd${e.code == null ? '' : '[${e.code}] '}$d';
  }
  if (e is UserMessageException) return null;
  final t = '$e'.trim();
  return t.isEmpty ? null : t;
}

/// Shows [e] as a friendly toast with a "Technical details" action.
void toastError(BuildContext context, Object e, {String fallbackKey = 'err_internal', String? prefix}) {
  final s = S.read(context);
  final msg = errorMessage(s, e, fallbackKey: fallbackKey);
  final detail = errorDetails(e);
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(prefix == null ? msg : '$prefix$msg'),
      duration: Duration(seconds: detail == null ? 3 : 5),
      action: detail == null ? null : SnackBarAction(label: s('technical_details'), onPressed: () => showTechnicalDetails(context, detail)),
    ));
}

/// Small "Technical details" link under an inline error message.
class ErrorDetailsLink extends StatelessWidget {
  const ErrorDetailsLink(this.error, {super.key});
  final Object? error;
  @override
  Widget build(BuildContext context) {
    final e = error;
    final d = e == null ? null : errorDetails(e);
    if (d == null) return const SizedBox.shrink();
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton(
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 4)),
        onPressed: () => showTechnicalDetails(context, d),
        child: Text(S.of(context)('technical_details')),
      ),
    );
  }
}

/// Dialog with raw technical information (selectable + copy), for support.
Future<void> showTechnicalDetails(BuildContext context, String detail) {
  final s = S.read(context);
  return showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(s('technical_details')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 320),
        child: SingleChildScrollView(
          child: SelectableText(detail, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.45)),
        ),
      ),
      actions: [
        TextButton(onPressed: () => copyText(c, detail), child: Text(s('copy'))),
        FilledButton(onPressed: () => Navigator.pop(c), child: Text(s('close'))),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, {required String title, String? body, required String action, bool danger = false}) async {
  final s = S.read(context);
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: body == null ? null : Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s('cancel'))),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: LC.danger) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return r ?? false;
}

Future<String?> promptText(BuildContext context, {required String title, String? initial, String? hint, required String action}) {
  final ctrl = TextEditingController(text: initial);
  final s = S.read(context);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(c, v.trim()),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(s('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: Text(action)),
      ],
    ),
  );
}

/// Formats "482913076" → "482 913 076".
String formatShortId(String id) {
  final d = id.replaceAll(RegExp(r'\D'), '');
  if (d.length != 9) return id;
  return '${d.substring(0, 3)} ${d.substring(3, 6)} ${d.substring(6)}';
}

Color pathColor(String? path) => switch (path) {
      'lan' => LC.success,
      'direct' => LC.accent,
      'relay' => LC.warning,
      _ => const Color(0xFF9AA0C3),
    };

IconData pathIcon(String? path) => switch (path) {
      'lan' => AppIcons.lan,
      'direct' => AppIcons.direct,
      'relay' => AppIcons.relay,
      _ => AppIcons.offline,
    };

/// Hosts a self-listening, full-screen layer above the app's Navigator with
/// its own Navigator/Overlay so tooltips, menus and dialogs work inside it.
class LayerHost extends StatelessWidget {
  const LayerHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return HeroControllerScope.none(
      child: Navigator(
        onGenerateRoute: (_) => PageRouteBuilder<void>(
          opaque: false,
          transitionDuration: Motion.normal,
          pageBuilder: (_, _, _) => child,
          transitionsBuilder: (_, a, _, c) => FadeTransition(opacity: CurvedAnimation(parent: a, curve: Motion.curve), child: c),
        ),
      ),
    );
  }
}

/// 0 = offline, 1-2 = connected via fallback, 3 = direct peer-to-peer.
int connectionQuality(NetStatus? n) {
  if (n == null) return 0;
  final direct = n.peers.any((p) => p.path == 'direct' || p.path == 'lan');
  if (direct) return 3;
  if (n.online || n.lanPeers > 0) return n.lanPeers > 0 ? 3 : 2;
  return 0;
}

class SignalBars extends StatelessWidget {
  const SignalBars({super.key, required this.level, this.color, this.max = 3, this.height = 14});
  final int level;
  final int max;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = color ?? LC.success;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < max; i++)
          AnimatedContainer(
            duration: Motion.normal,
            margin: const EdgeInsets.only(right: 2),
            width: height * 0.26,
            height: height * (0.4 + 0.6 * (i + 1) / max),
            decoration: BoxDecoration(
              color: i < level ? c : context.lc.muted.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
      ],
    );
  }
}


/// Leading glyph for rows in settings-style cards: the duotone cut, sized
/// exactly and coloured like the surrounding ListTile icon.
class RowIcon extends StatelessWidget {
  const RowIcon(this.icon, {super.key, this.color, this.size = 22});
  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: PhosphorIcon(AppIcons.duotone(icon), size: size, color: color ?? IconTheme.of(context).color, duotoneSecondaryOpacity: 0.22),
      );
}

/// Icon tile sizes: outer box / glyph size, in logical pixels.
enum IconTileSize {
  sm(32, 18),
  md(40, 22),
  lg(56, 28);

  const IconTileSize(this.box, this.glyph);
  final double box;
  final double glyph;
}

/// The one container used behind feature icons (settings groups, attach menu,
/// empty states, onboarding points…): a quiet tinted surface - the accent at
/// 12% with a 20% hairline - and the glyph in the accent colour, optically
/// centred. Gradients are reserved for the brand mark and primary actions.
class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, this.color, this.size = IconTileSize.md, this.circle = false, this.duotone = true});
  final IconData icon;

  /// Accent colour; defaults to the brand primary.
  final Color? color;
  final IconTileSize size;
  final bool circle;

  /// Use the two-tone cut of [icon] (feature spots). Off for plain glyphs.
  final bool duotone;

  @override
  Widget build(BuildContext context) {
    final c = color ?? LC.primary;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox.square(
      dimension: size.box,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.withValues(alpha: dark ? 0.14 : 0.10),
          shape: circle ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: circle ? null : BorderRadius.circular(size.box * 0.3),
          border: Border.all(color: c.withValues(alpha: dark ? 0.24 : 0.20)),
        ),
        child: Center(
          child: SizedBox.square(
            dimension: size.glyph,
            child: PhosphorIcon(
              duotone ? AppIcons.duotone(icon) : icon,
              size: size.glyph,
              // A touch lighter on dark surfaces so saturated accents keep contrast.
              color: dark ? Color.lerp(c, Colors.white, 0.22) : c,
              duotoneSecondaryOpacity: dark ? 0.32 : 0.24,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- previews

/// Icon for a non-text message preview (chat list, reply quotes, pins…).
IconData previewIcon(PreviewKind k) => switch (k) {
      PreviewKind.photo => AppIcons.camera,
      PreviewKind.video => AppIcons.film,
      PreviewKind.voice => AppIcons.mic,
      PreviewKind.liveLocation => AppIcons.navigate,
      PreviewKind.location => AppIcons.location,
      PreviewKind.call => AppIcons.call,
      PreviewKind.videoCall => AppIcons.video,
      PreviewKind.missedCall => AppIcons.callMissed,
      PreviewKind.missedVideoCall => AppIcons.video,
      PreviewKind.sticker => AppIcons.sticker,
      PreviewKind.file => AppIcons.attach,
      PreviewKind.contact => AppIcons.contactCard,
      PreviewKind.poll => AppIcons.poll,
      PreviewKind.checklist => AppIcons.tasks,
      PreviewKind.reminder => AppIcons.reminder,
    };

/// One-line message preview: plain text as is; non-text messages ("🖼️ Photo",
/// "📞 Missed call", …) as a small inline icon plus a plain word, e.g.
/// [camera] "Ảnh", [phone-x] "Cuộc gọi thoại nhỡ" in red.
class PreviewLine extends StatelessWidget {
  const PreviewLine(this.raw, {super.key, this.style, this.lead = '', this.maxLines = 1, this.iconColor});
  final String raw;
  final TextStyle? style;

  /// Text before everything else, e.g. "Bạn: ".
  final String lead;
  final int maxLines;

  /// Icon colour; defaults to the muted text colour (red for missed calls).
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final p = S.of(context).previewParts(raw);
    final base = DefaultTextStyle.of(context).style.merge(style);
    if (p.kind == null) {
      return Text('$lead$raw', maxLines: maxLines, overflow: TextOverflow.ellipsis, style: base);
    }
    final fs = base.fontSize ?? 14;
    final glyph = (fs + 1.5).clamp(13.0, 16.0);
    final color = p.missed ? LC.danger : (iconColor ?? context.lc.muted);
    return Text.rich(
      TextSpan(children: [
        if (lead.isNotEmpty || p.prefix.isNotEmpty) TextSpan(text: '$lead${p.prefix}'),
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: SizedBox.square(dimension: glyph, child: Icon(previewIcon(p.kind!), size: glyph, color: color)),
          ),
        ),
        TextSpan(text: p.text, style: p.missed ? const TextStyle(color: LC.danger) : null),
      ]),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: base,
    );
  }
}

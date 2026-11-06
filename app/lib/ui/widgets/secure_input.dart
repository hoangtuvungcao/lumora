// One visual system for every screen that asks for a secret: the data
// password, the app PIN, the recovery phrase, backup-file passwords and the
// remote-control password.
//
//  * [SecureFrame] / [showSecureDialog]: centred card on desktop (max 420),
//    full-screen, SafeArea- and keyboard-aware page on phones.
//  * [SecureHero]: brand mark (or a feature icon) in a soft glow, a title and
//    one plain line.
//  * [PasswordField]: large rounded field, show/hide, Caps Lock warning,
//    strength meter with plain hints, match indicator.
//  * [PinPad]: PIN dots, calm error line, lockout ring and a keypad that
//    scales from 320 dp phones to a compact desktop card.
//  * [RecoveryPhraseInput]: 24 numbered word boxes with BIP39 suggestions,
//    paste support, per-word and checksum checks, and a field for the
//    older-style code.
//
// Nothing in here logs, stores or prints what is typed.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/bip39.dart';
import '../../l10n/strings.dart';
import '../../state/password_policy.dart';
import '../theme.dart';
import 'app_icons.dart';
import 'common.dart';
import 'logo.dart';

/// Content width of a secure card / page.
const kSecureMaxWidth = 420.0;

bool get _desktopPlatform =>
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows;

bool _isDark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

// ================================================================== layout

/// Soft brand glow behind full-screen secure pages.
class SecureBackdrop extends StatelessWidget {
  const SecureBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    return ColoredBox(
      color: context.lc.bg,
      child: Stack(children: [
        Positioned(
          top: -260,
          left: 0,
          right: 0,
          child: Center(
            child: _Glow(size: 640, color: LC.primary, alpha: dark ? 0.20 : 0.12),
          ),
        ),
        Positioned(
          bottom: -300,
          right: -200,
          child: _Glow(size: 560, color: LC.accent, alpha: dark ? 0.10 : 0.08),
        ),
        Positioned.fill(child: child),
      ]),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.size, required this.color, required this.alpha});
  final double size;
  final Color color;
  final double alpha;
  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [color.withValues(alpha: alpha), color.withValues(alpha: 0)]),
          ),
        ),
      );
}

/// Raised card used on desktop.
class SecureCard extends StatelessWidget {
  const SecureCard({super.key, required this.child, this.padding = const EdgeInsets.fromLTRB(32, 32, 32, 28)});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: context.lc.surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: dark ? const Color(0xFF2A2F55) : context.lc.divider),
        boxShadow: kNoShadows
            ? null
            : [BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.35 : 0.10), blurRadius: 48, offset: const Offset(0, 24))],
      ),
      child: child,
    );
  }
}

/// Small round icon button for the top corners of a secure card / page.
class SecureNavButton extends StatelessWidget {
  const SecureNavButton({super.key, required this.icon, required this.tooltip, required this.onPressed});
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  /// "Back" arrow.
  factory SecureNavButton.back(BuildContext context, VoidCallback onPressed) =>
      SecureNavButton(icon: AppIcons.back, tooltip: S.of(context)('back'), onPressed: onPressed);

  /// "Close" cross.
  factory SecureNavButton.close(BuildContext context, VoidCallback onPressed) =>
      SecureNavButton(icon: AppIcons.close, tooltip: S.of(context)('close'), onPressed: onPressed);

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          foregroundColor: context.lc.muted,
          backgroundColor: context.lc.surface2.withValues(alpha: 0.7),
          fixedSize: const Size(40, 40),
          minimumSize: const Size(40, 40),
        ),
        icon: Icon(icon, size: 20),
      );
}

/// Lays out a secure screen: a centred card on desktop, a full-screen page on
/// phones. [leading]/[trailing] sit in the top corners (back / close). Esc
/// runs [onEscape] (falls back to the leading/trailing action's route pop).
class SecureFrame extends StatelessWidget {
  const SecureFrame({
    super.key,
    required this.child,
    this.leading,
    this.trailing,
    this.footer,
    this.onEscape,
    this.backdrop = true,
    this.cardPadding,
    this.maxWidth = kSecureMaxWidth,
    this.forceCard,
    this.fillHeight = true,
  });

  final Widget child;
  final Widget? leading;
  final Widget? trailing;

  /// Shown under the card (desktop) / at the end of the page (phones).
  final Widget? footer;
  final VoidCallback? onEscape;

  /// Paint the glow background (off inside desktop dialogs: the barrier is
  /// behind them).
  final bool backdrop;
  final EdgeInsets? cardPadding;
  final double maxWidth;

  /// Override the desktop/phone decision (dialogs decide it themselves).
  final bool? forceCard;

  /// Card mode: centre the card in the full height (pages). Dialogs size to
  /// the card instead so a click beside it reaches the barrier.
  final bool fillHeight;

  @override
  Widget build(BuildContext context) {
    final card = forceCard ?? isDesktop(context);
    Widget content;
    if (card) {
      content = Column(mainAxisSize: MainAxisSize.min, children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: SecureCard(
            padding: cardPadding ?? const EdgeInsets.fromLTRB(32, 32, 32, 28),
            child: Stack(clipBehavior: Clip.none, children: [
              child,
              if (leading != null) Positioned(top: -16, left: -16, child: leading!),
              if (trailing != null) Positioned(top: -16, right: -16, child: trailing!),
            ]),
          ),
        ),
        if (footer != null) ...[const SizedBox(height: 24), footer!],
      ]);
      final inner = content;
      content = fillHeight
          ? LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: math.max(0, box.maxHeight - 64)),
                  child: Center(child: inner),
                ),
              ),
            )
          : SingleChildScrollView(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24), child: inner);
    } else {
      final hasBar = leading != null || trailing != null;
      content = SafeArea(
        child: Column(children: [
          if (hasBar)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(children: [
                ?leading,
                const Spacer(),
                ?trailing,
              ]),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: EdgeInsets.fromLTRB(box.maxWidth < 360 ? 16 : 24, hasBar ? 8 : 24, box.maxWidth < 360 ? 16 : 24, 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: math.max(0, box.maxHeight - (hasBar ? 32 : 48))),
                  // A little above centre: the keyboard comes up from below.
                  child: Align(
                    alignment: const Alignment(0, -0.35),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxWidth),
                      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        child,
                        if (footer != null) ...[const SizedBox(height: 24), Center(child: footer!)],
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      );
    }
    if (backdrop) content = SecureBackdrop(child: content);
    if (onEscape != null) {
      content = CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): onEscape!},
        child: content,
      );
    }
    return content;
  }
}

/// Opens a secure screen as a dialog: a centred card on desktop and a
/// full-screen sheet on phones. Pop it with `Navigator.pop(context, value)`.
Future<T?> showSecureDialog<T>(BuildContext context, {required WidgetBuilder builder, bool barrierDismissible = true}) {
  final desktop = isDesktop(context);
  return showDialog<T>(
    context: context,
    useSafeArea: false,
    barrierDismissible: barrierDismissible,
    barrierColor: Colors.black.withValues(alpha: _isDark(context) ? 0.6 : 0.4),
    builder: (c) => desktop
        ? Dialog(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            insetPadding: EdgeInsets.zero,
            child: builder(c),
          )
        : Dialog.fullscreen(backgroundColor: c.lc.bg, child: builder(c)),
  );
}

/// [SecureFrame] for content opened with [showSecureDialog].
class SecureDialogFrame extends StatelessWidget {
  const SecureDialogFrame({super.key, required this.child, this.leading, this.trailing, this.onEscape, this.footer});
  final Widget child;
  final Widget? leading, trailing, footer;
  final VoidCallback? onEscape;

  @override
  Widget build(BuildContext context) {
    final desktop = isDesktop(context);
    return SecureFrame(
      forceCard: desktop,
      fillHeight: false,
      backdrop: !desktop,
      leading: leading,
      trailing: trailing,
      footer: footer,
      onEscape: onEscape,
      child: child,
    );
  }
}

// ==================================================================== hero

/// Brand mark (or [icon]) in a soft glow, a title and one plain line.
class SecureHero extends StatelessWidget {
  const SecureHero({super.key, required this.title, this.subtitle, this.icon, this.tone, this.compact = false, this.below, this.showMark = true});
  final String title;
  final String? subtitle;

  /// Feature icon instead of the Lumora mark.
  final IconData? icon;
  final Color? tone;
  final bool compact;

  /// Extra line under the subtitle (e.g. a pill).
  final Widget? below;

  /// Off where the page already shows the brand (onboarding header).
  final bool showMark;

  @override
  Widget build(BuildContext context) {
    final mark = compact ? 52.0 : 64.0;
    return Semantics(
      header: true,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (showMark) ...[
          Center(child: _HeroMark(size: mark, icon: icon, tone: tone ?? LC.primary)),
          SizedBox(height: compact ? 16 : 20),
        ],
        Text(
          title,
          textAlign: TextAlign.center,
          style: context.tt.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            fontSize: compact ? 21 : 24,
            height: 1.25,
            letterSpacing: -0.3,
            color: context.lc.text,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(
            subtitle!,
            textAlign: TextAlign.center,
            style: context.tt.bodyMedium?.copyWith(color: context.lc.muted, height: 1.5, fontSize: 14.5),
          ),
        ],
        if (below != null) ...[const SizedBox(height: 16), Center(child: below!)],
      ]),
    );
  }
}

class _HeroMark extends StatelessWidget {
  const _HeroMark({required this.size, required this.icon, required this.tone});
  final double size;
  final IconData? icon;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    final glow = size * 2.6;
    final Widget mark;
    if (icon == null) {
      mark = ExcludeSemantics(child: LumoraLogo(size: size));
    } else {
      mark = Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [tone.withValues(alpha: dark ? 0.26 : 0.16), tone.withValues(alpha: dark ? 0.12 : 0.07)],
          ),
          border: Border.all(color: tone.withValues(alpha: dark ? 0.38 : 0.26)),
        ),
        child: Center(
          child: PhosphorIcon(AppIcons.duotone(icon!), size: size * 0.46, color: tone, duotoneSecondaryOpacity: dark ? 0.34 : 0.24),
        ),
      );
    }
    return SizedBox(
      width: size * 1.6,
      height: size * 1.25,
      child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
        Positioned(
          left: (size * 1.6 - glow) / 2,
          top: (size * 1.25 - glow) / 2,
          child: _Glow(size: glow, color: tone, alpha: dark ? 0.30 : 0.16),
        ),
        mark,
      ]),
    );
  }
}

// ============================================================ small pieces

/// "Step 1 of 2" pill.
class SecureSteps extends StatelessWidget {
  const SecureSteps({super.key, required this.index, this.count = 2, required this.label});
  final int index;
  final int count;
  final String label;
  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 12, 5),
      decoration: BoxDecoration(color: LC.primary.withValues(alpha: dark ? 0.16 : 0.08), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: Motion.normal,
            margin: const EdgeInsets.only(right: 4),
            width: i == index ? 14 : 6,
            height: 6,
            decoration: BoxDecoration(
              gradient: i <= index ? LC.gradient : null,
              color: i <= index ? null : LC.primary.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontFamily: kFontFamily, fontSize: 12, fontWeight: FontWeight.w600, color: dark ? const Color(0xFFB4AAFF) : LC.primary)),
      ]),
    );
  }
}

// ---------------------------------------------------------------- labels

/// Field label above an input.
class SecureLabel extends StatelessWidget {
  const SecureLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 8),
        child: Row(children: [
          Expanded(
            child: Text(text, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 13.5, color: context.lc.text.withValues(alpha: 0.9))),
          ),
          ?trailing,
        ]),
      );
}

/// Calm one-line status under an input (error / warning / ok / info).
enum SecureTone { error, warning, ok, info }

class SecureMessage extends StatelessWidget {
  const SecureMessage(this.text, {super.key, this.tone = SecureTone.error, this.icon, this.center = false});
  final String text;
  final SecureTone tone;
  final IconData? icon;
  final bool center;

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    final c = switch (tone) {
      SecureTone.error => dark ? const Color(0xFFF87171) : const Color(0xFFDC2626),
      SecureTone.warning => dark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
      SecureTone.ok => dark ? const Color(0xFF4ADE80) : const Color(0xFF16A34A),
      SecureTone.info => context.lc.muted,
    };
    final i = icon ??
        switch (tone) {
          SecureTone.error => AppIcons.error,
          SecureTone.warning => AppIcons.warning,
          SecureTone.ok => AppIcons.checkCircle,
          SecureTone.info => AppIcons.info,
        };
    return Semantics(
      liveRegion: tone == SecureTone.error,
      child: Row(mainAxisSize: center ? MainAxisSize.min : MainAxisSize.max, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(i, size: 16, color: c)),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            textAlign: center ? TextAlign.center : TextAlign.start,
            style: context.tt.bodySmall?.copyWith(color: tone == SecureTone.info ? context.lc.muted : c, fontSize: 13, height: 1.4, fontWeight: FontWeight.w500),
          ),
        ),
      ]),
    );
  }
}

/// Tinted note box (what's in a backup, what a password protects…).
class SecureNote extends StatelessWidget {
  const SecureNote(this.text, {super.key, this.icon = AppIcons.info, this.color});
  final String text;
  final IconData icon;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = color ?? LC.primary;
    final dark = _isDark(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: c.withValues(alpha: dark ? 0.10 : 0.07),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: c.withValues(alpha: dark ? 0.18 : 0.14)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 18, color: c)),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: context.tt.bodySmall?.copyWith(color: context.lc.text.withValues(alpha: 0.85), height: 1.45, fontSize: 13))),
      ]),
    );
  }
}

/// Full-width primary action: brand gradient, 52 px, calm disabled state.
class SecurePrimaryButton extends StatefulWidget {
  const SecurePrimaryButton({super.key, required this.label, required this.onPressed, this.icon, this.busy = false, this.danger = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final bool danger;

  @override
  State<SecurePrimaryButton> createState() => _SecurePrimaryButtonState();
}

class _SecurePrimaryButtonState extends State<SecurePrimaryButton> {
  bool _focused = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.busy;
    final dark = _isDark(context);
    final fg = enabled || widget.busy ? Colors.white : context.lc.muted.withValues(alpha: 0.8);
    final gradient = widget.danger
        ? const LinearGradient(colors: [Color(0xFFEF4444), Color(0xFFDC2626)])
        : LC.gradient;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      excludeSemantics: true,
      child: AnimatedScale(
        scale: _down ? 0.98 : 1,
        duration: Motion.fast,
        child: AnimatedContainer(
          duration: Motion.normal,
          height: 52,
          decoration: BoxDecoration(
            gradient: enabled || widget.busy ? gradient : null,
            color: enabled || widget.busy ? null : (dark ? context.lc.surface2 : const Color(0xFFE4E7F2)),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              if (_focused) BoxShadow(color: LC.primary.withValues(alpha: 0.45), spreadRadius: 3),
              if (enabled && !kNoShadows) BoxShadow(color: LC.primary.withValues(alpha: dark ? 0.35 : 0.25), blurRadius: 18, offset: const Offset(0, 8)),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: enabled ? widget.onPressed : null,
              onHighlightChanged: (v) => setState(() => _down = v),
              onFocusChange: (v) => setState(() => _focused = v),
              child: Center(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (widget.busy)
                    const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                  else if (widget.icon != null)
                    Icon(widget.icon, color: fg, size: 19),
                  if (widget.busy || widget.icon != null) const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: kFontFamily, color: fg, fontWeight: FontWeight.w600, fontSize: 15.5, letterSpacing: 0.1),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Two-option pill switch (recovery phrase / backup file).
class SecureSegmented<T> extends StatelessWidget {
  const SecureSegmented({super.key, required this.value, required this.options, required this.onChanged});
  final T value;
  final List<(T, IconData, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    final index = options.indexWhere((o) => o.$1 == value);
    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: context.lc.surface2, borderRadius: BorderRadius.circular(14)),
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth / options.length;
        return Stack(children: [
          AnimatedPositioned(
            duration: Motion.normal,
            curve: Motion.curve,
            left: w * index,
            top: 0,
            bottom: 0,
            width: w,
            child: Container(
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF2E3360) : Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: dark ? const Color(0xFF3A4078) : context.lc.divider),
              ),
            ),
          ),
          Row(children: [
            for (final o in options)
              Expanded(
                child: Semantics(
                  selected: o.$1 == value,
                  button: true,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => onChanged(o.$1),
                    child: Center(
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(o.$2, size: 17, color: o.$1 == value ? LC.primary : context.lc.muted),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            o.$3,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: kFontFamily,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: o.$1 == value ? context.lc.text : context.lc.muted,
                            ),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ]);
      }),
    );
  }
}

/// Tappable option card (icon, title, one line, chevron).
class SecureOptionCard extends StatefulWidget {
  const SecureOptionCard({super.key, required this.icon, required this.title, required this.subtitle, required this.onTap, this.color});
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  final Color? color;
  @override
  State<SecureOptionCard> createState() => _SecureOptionCardState();
}

class _SecureOptionCardState extends State<SecureOptionCard> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    final c = widget.color ?? LC.primary;
    final active = _hover || _focus;
    return AnimatedContainer(
      duration: Motion.fast,
      decoration: BoxDecoration(
        color: active ? (dark ? const Color(0xFF242950) : const Color(0xFFF1F2FA)) : (dark ? context.lc.surface2.withValues(alpha: 0.6) : context.lc.surface),
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: _focus ? LC.primary : (active ? c.withValues(alpha: 0.4) : (dark ? const Color(0xFF2A2F55) : context.lc.divider)), width: _focus ? 1.6 : 1),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.lg),
          onTap: widget.onTap,
          onHover: (v) => setState(() => _hover = v),
          onFocusChange: (v) => setState(() => _focus = v),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
            child: Row(children: [
              IconTile(widget.icon, color: c),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.title, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(widget.subtitle, style: context.tt.bodySmall?.copyWith(height: 1.4, fontSize: 12.5)),
                ]),
              ),
              const SizedBox(width: 8),
              AnimatedSlide(
                duration: Motion.fast,
                offset: Offset(active ? 0.15 : 0, 0),
                child: Icon(AppIcons.chevronRight, size: 18, color: active ? c : context.lc.muted),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ========================================================= text inputs

/// Shared decoration for the large rounded secure inputs.
InputDecoration secureInputDecoration(BuildContext context, {String? hint, IconData? icon, Widget? suffix, bool error = false, bool focused = false}) {
  final dark = _isDark(context);
  final radius = BorderRadius.circular(14);
  OutlineInputBorder b(Color c, [double w = 1]) => OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: c, width: w));
  return InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: context.lc.muted.withValues(alpha: 0.75), fontSize: 15.5, letterSpacing: 0),
    filled: true,
    fillColor: dark ? const Color(0xFF1B1F3A) : const Color(0xFFF2F3FA),
    isDense: false,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
    prefixIcon: icon == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(left: 16, right: 10),
            child: Icon(icon, size: 20, color: error ? LC.danger : (focused ? LC.primary : context.lc.muted)),
          ),
    prefixIconConstraints: const BoxConstraints(minWidth: 46, minHeight: 0),
    suffixIcon: suffix,
    suffixIconConstraints: const BoxConstraints(minWidth: 44, minHeight: 0),
    border: b(Colors.transparent),
    enabledBorder: b(error ? LC.danger.withValues(alpha: 0.7) : (dark ? const Color(0xFF2A2F55) : const Color(0xFFE1E4F0))),
    focusedBorder: b(error ? LC.danger : LC.primary, 1.6),
    disabledBorder: b(Colors.transparent),
    errorBorder: b(LC.danger.withValues(alpha: 0.7)),
    focusedErrorBorder: b(LC.danger, 1.6),
    counterText: '',
  );
}

/// Plain (non-secret) text input in the same style (display name…).
class SecureTextField extends StatefulWidget {
  const SecureTextField({super.key, required this.controller, this.label, this.hint, this.icon, this.onChanged, this.onSubmitted, this.maxLength, this.autofocus = false, this.textInputAction});
  final TextEditingController controller;
  final String? label, hint;
  final IconData? icon;
  final ValueChanged<String>? onChanged, onSubmitted;
  final int? maxLength;
  final bool autofocus;
  final TextInputAction? textInputAction;
  @override
  State<SecureTextField> createState() => _SecureTextFieldState();
}

class _SecureTextFieldState extends State<SecureTextField> {
  final _focus = FocusNode();
  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        if (widget.label != null) SecureLabel(widget.label!),
        _FocusRing(
          focused: _focus.hasFocus,
          child: TextField(
            controller: widget.controller,
            focusNode: _focus,
            autofocus: widget.autofocus,
            maxLength: widget.maxLength,
            onChanged: widget.onChanged,
            onSubmitted: widget.onSubmitted,
            textInputAction: widget.textInputAction,
            style: TextStyle(fontSize: 16, color: context.lc.text),
            decoration: secureInputDecoration(context, hint: widget.hint, icon: widget.icon, focused: _focus.hasFocus),
          ),
        ),
      ]);
}

/// Soft halo around a focused input (no blur: crisp everywhere).
class _FocusRing extends StatelessWidget {
  const _FocusRing({required this.focused, required this.child, this.error = false});
  final bool focused;
  final bool error;
  final Widget child;
  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: Motion.fast,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: focused ? [BoxShadow(color: (error ? LC.danger : LC.primary).withValues(alpha: _isDark(context) ? 0.22 : 0.14), spreadRadius: 4)] : const [],
        ),
        child: child,
      );
}

// ------------------------------------------------------------- strength

/// Result of [estimatePasswordStrength]: 0 (easy to guess) … 4 (very strong)
/// and a plain hint key (+ params) for the user.
@immutable
class PasswordStrength {
  const PasswordStrength(this.score, this.hint, [this.params = const {}]);
  final int score;
  final String hint;
  final Map<String, Object> params;
}

const _commonPasswords = {
  'password', 'passw0rd', 'password1', 'password123', '123456', '1234567', '12345678', '123456789', '1234567890', '12345', '1234',
  '111111', '000000', '123123', '112233', '654321', '666666', '888888', '999999', '159753', '147258369', '123321', 'abc123', 'abcd1234',
  'qwerty', 'qwerty123', 'qwertyuiop', 'asdfgh', 'asdfghjkl', 'zxcvbnm', '1q2w3e', '1q2w3e4r', '1qaz2wsx', 'iloveyou', 'iloveu', 'admin',
  'welcome', 'letmein', 'monkey', 'dragon', 'football', 'sunshine', 'princess', 'baseball', 'master', 'superman', 'matkhau', 'matkhau123',
  'anhyeuem', 'emyeuanh', 'yeuem', 'saigon', 'hanoi', 'vietnam', 'lumora', 'lumora123', 'trustno1', 'secret', 'changeme',
};

const _keyboardRows = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm', '1234567890', '1qaz2wsx3edc4rfv', 'qazwsxedc'];

/// zxcvbn-like estimate without the dictionary weight: character pool ×
/// length, minus the parts that are easy to guess (common passwords, runs
/// like "abcd"/"4321", repeats, keyboard rows, years). Pure function.
///
/// With [policy] the app's password rules ([passwordProblem]) cap the score,
/// so the meter never calls a password strong that saving would refuse.
PasswordStrength estimatePasswordStrength(String pw, {int minLength = 0, bool policy = false}) {
  if (pw.isEmpty) return const PasswordStrength(0, '');
  if (policy) {
    final problem = passwordProblem(pw, minLength: minLength > 0 ? minLength : kMinPasswordLength);
    if (problem == 'pass_too_short') {
      final n = minLength > 0 ? minLength : kMinPasswordLength;
      return PasswordStrength(pw.characters.length >= n - 2 ? 1 : 0, 'sec_hint_min', {'n': n});
    }
    if (problem != null) return const PasswordStrength(0, 'sec_hint_common');
  }
  final chars = pw.characters.toList();
  final n = chars.length;
  final lower = pw.toLowerCase();
  final bare = lower.replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (_commonPasswords.contains(lower) || _commonPasswords.contains(bare) || _commonPasswords.contains(bare.replaceAll(RegExp(r'\d+$'), ''))) {
    return const PasswordStrength(0, 'sec_hint_common');
  }
  if (minLength > 0 && n < minLength) {
    return PasswordStrength(n >= minLength - 2 ? 1 : 0, 'sec_hint_min', {'n': minLength});
  }

  var pool = 0;
  if (RegExp(r'[a-z]').hasMatch(pw)) pool += 26;
  if (RegExp(r'[A-Z]').hasMatch(pw)) pool += 26;
  if (RegExp(r'[0-9]').hasMatch(pw)) pool += 10;
  if (RegExp(r'[ -/:-@\[-`{-~]').hasMatch(pw)) pool += 33;
  if (RegExp(r'[^\x00-\x7F]').hasMatch(pw)) pool += 40; // Vietnamese letters, emoji…
  pool = math.max(pool, 10);

  // Characters that add (almost) nothing.
  var weak = 0.0;
  var repeat = false, sequence = false, keyboard = false, year = false;

  // Repeats: "aaa", "1111".
  for (var i = 2; i < n; i++) {
    if (chars[i] == chars[i - 1] && chars[i] == chars[i - 2]) {
      weak += 1;
      repeat = true;
    }
  }
  // Runs: "abc", "345", "cba".
  for (var i = 2; i < n; i++) {
    final a = lower.codeUnitAt(i - 2), b = lower.codeUnitAt(i - 1), c = lower.codeUnitAt(i);
    final alnum = RegExp(r'[a-z0-9]');
    if (!alnum.hasMatch(lower[i]) || !alnum.hasMatch(lower[i - 1]) || !alnum.hasMatch(lower[i - 2])) continue;
    if ((b - a == 1 && c - b == 1) || (a - b == 1 && b - c == 1)) {
      weak += 1;
      sequence = true;
    }
  }
  // Keyboard rows: "qwer", "asdf", "1qaz".
  for (final row in _keyboardRows) {
    for (var len = row.length; len >= 4; len--) {
      var hit = false;
      for (var s = 0; s + len <= row.length; s++) {
        if (lower.contains(row.substring(s, s + len))) {
          weak += len - 1;
          keyboard = true;
          hit = true;
          break;
        }
      }
      if (hit) break;
    }
  }
  // Years and dates.
  final years = RegExp(r'(19[5-9]\d|20[0-4]\d)').allMatches(pw).length;
  if (years > 0) {
    weak += years * 3;
    year = true;
  }
  // Very few distinct characters.
  final distinct = chars.toSet().length;
  if (distinct < n / 2) weak += (n / 2 - distinct);

  final effective = math.max(0.0, n - weak);
  var bits = effective * (math.log(pool) / math.ln2);
  // Several words ("mây tím ăn phở") are much harder than their letters suggest.
  final words = pw.trim().split(RegExp(r'[\s\-_.]+')).where((w) => w.characters.length >= 3).length;
  if (words >= 3) bits += 10;

  final score = bits < 28 ? 0 : bits < 40 ? 1 : bits < 56 ? 2 : bits < 72 ? 3 : 4;
  final String hint;
  if (score >= 4) {
    hint = 'sec_hint_great';
  } else if (repeat) {
    hint = 'sec_hint_repeat';
  } else if (sequence || keyboard) {
    hint = 'sec_hint_sequence';
  } else if (year) {
    hint = 'sec_hint_year';
  } else if (n < 12) {
    hint = 'sec_hint_longer';
  } else if (words < 3) {
    hint = 'sec_hint_words';
  } else {
    hint = 'sec_hint_longer';
  }
  return PasswordStrength(score, hint);
}

const _strengthColors = [LC.danger, Color(0xFFF97316), LC.warning, Color(0xFF34C759), LC.success];

class _StrengthMeter extends StatelessWidget {
  const _StrengthMeter({required this.strength});
  final PasswordStrength strength;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final filled = const [1, 1, 2, 3, 4][strength.score];
    final color = _strengthColors[strength.score];
    final label = s('sec_strength_${strength.score}');
    return Semantics(
      label: s('sec_strength_label', {'v': label}),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          for (var i = 0; i < 4; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              child: AnimatedContainer(
                duration: Motion.normal,
                curve: Motion.curve,
                height: 4,
                decoration: BoxDecoration(
                  color: i < filled ? color : context.lc.surface2,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        ]),
        const SizedBox(height: 8),
        ExcludeSemantics(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
              if (strength.hint.isNotEmpty) TextSpan(text: '  ·  ${s(strength.hint, strength.params)}'),
            ]),
            style: context.tt.bodySmall?.copyWith(fontSize: 12.5, height: 1.4),
          ),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------ password

/// Large rounded password input: show/hide, Caps Lock warning (desktop),
/// optional strength meter and "matches" indicator for a confirm field.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.icon = AppIcons.lockKey,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
    this.errorText,
    this.showStrength = false,
    this.minLength = 0,
    this.policy = true,
    this.matchWith,
    this.newPassword = false,
    this.textInputAction,
    this.focusNode,
    this.enabled = true,
  });

  final TextEditingController controller;

  /// Shown above the field (and read by screen readers).
  final String? label;
  final String? hint;
  final IconData? icon;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String? errorText;

  /// Strength meter + plain hint under the field (choosing a new password).
  final bool showStrength;
  final int minLength;

  /// Apply the app's password rules to the meter (see [passwordProblem]).
  final bool policy;

  /// Confirm field: shows whether it matches this controller's text.
  final TextEditingController? matchWith;
  final bool newPassword;
  final TextInputAction? textInputAction;
  final FocusNode? focusNode;
  final bool enabled;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  late final FocusNode _focus = widget.focusNode ?? FocusNode(debugLabel: 'password');
  bool _obscure = true;
  bool _caps = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    widget.controller.addListener(_rebuild);
    widget.matchWith?.addListener(_rebuild);
    if (_desktopPlatform) HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didUpdateWidget(PasswordField old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_rebuild);
      widget.controller.addListener(_rebuild);
    }
    if (old.matchWith != widget.matchWith) {
      old.matchWith?.removeListener(_rebuild);
      widget.matchWith?.addListener(_rebuild);
    }
  }

  @override
  void dispose() {
    if (_desktopPlatform) HardwareKeyboard.instance.removeHandler(_onKey);
    widget.controller.removeListener(_rebuild);
    widget.matchWith?.removeListener(_rebuild);
    _focus.removeListener(_onFocus);
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  bool get _capsOn => HardwareKeyboard.instance.lockModesEnabled.contains(KeyboardLockMode.capsLock);

  void _onFocus() {
    if (!mounted) return;
    setState(() => _caps = _desktopPlatform && _focus.hasFocus && _capsOn);
  }

  bool _onKey(KeyEvent e) {
    // Only looks at the Caps Lock state; never at what was typed.
    final on = _focus.hasFocus && _capsOn;
    if (on != _caps && mounted) setState(() => _caps = on);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final text = widget.controller.text;
    final match = widget.matchWith;
    final matches = match != null && text.isNotEmpty && text == match.text;
    final error = widget.errorText != null;
    final eye = Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (match != null && text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: AnimatedSwitcher(
              duration: Motion.fast,
              child: Icon(
                matches ? AppIcons.checkCircle : AppIcons.close,
                key: ValueKey(matches),
                size: 18,
                color: matches ? LC.success : context.lc.muted.withValues(alpha: 0.7),
              ),
            ),
          ),
        // The eye never takes keyboard focus (Tab goes field → field →
        // button); screen readers can still press it.
        ExcludeFocus(
          child: IconButton(
            tooltip: _obscure ? s('sec_show') : s('sec_hide'),
            onPressed: () => setState(() => _obscure = !_obscure),
            icon: Icon(_obscure ? AppIcons.show : AppIcons.hide, size: 20, color: context.lc.muted),
          ),
        ),
      ]),
    );

    final below = <Widget>[];
    if (error) {
      below.add(SecureMessage(widget.errorText!));
    } else if (_caps) {
      below.add(SecureMessage(s('sec_caps'), tone: SecureTone.warning, icon: AppIcons.keyboard));
    }
    if (widget.showStrength && text.isNotEmpty) {
      below.add(_StrengthMeter(strength: estimatePasswordStrength(text, minLength: widget.minLength, policy: widget.policy)));
    } else if (widget.showStrength && widget.minLength > 0 && !error) {
      below.add(SecureMessage(s('sec_hint_min', {'n': widget.minLength}), tone: SecureTone.info));
    }
    if (match != null && text.isNotEmpty && !error) {
      below.add(SecureMessage(matches ? s('sec_match') : s('sec_no_match'), tone: matches ? SecureTone.ok : SecureTone.info, icon: matches ? AppIcons.checkCircle : AppIcons.info));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (widget.label != null) SecureLabel(widget.label!),
      _FocusRing(
        focused: _focus.hasFocus,
        error: error,
        child: TextField(
          controller: widget.controller,
          focusNode: _focus,
          enabled: widget.enabled,
          autofocus: widget.autofocus,
          obscureText: _obscure,
          obscuringCharacter: '•',
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          keyboardType: TextInputType.visiblePassword,
          autofillHints: [widget.newPassword ? AutofillHints.newPassword : AutofillHints.password],
          textInputAction: widget.textInputAction ?? (widget.onSubmitted != null ? TextInputAction.done : TextInputAction.next),
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          style: TextStyle(fontSize: 16.5, color: context.lc.text, letterSpacing: _obscure && text.isNotEmpty ? 2.5 : 0.2, fontWeight: FontWeight.w500),
          decoration: secureInputDecoration(
            context,
            hint: widget.hint ?? (widget.label == null ? null : ''),
            icon: widget.icon,
            suffix: eye,
            error: error,
            focused: _focus.hasFocus,
          ).copyWith(semanticCounterText: '', labelText: null),
        ),
      ),
      AnimatedSize(
        duration: Motion.normal,
        curve: Motion.curve,
        alignment: Alignment.topCenter,
        child: below.isEmpty
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.only(top: 10, left: 2, right: 2),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final (i, w) in below.indexed) ...[if (i > 0) const SizedBox(height: 8), w],
                ]),
              ),
      ),
    ]);
  }
}

// ===================================================================== PIN

String formatWait(int sec) => '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';

/// PIN dots + numeric keypad. With [length] the PIN is checked as soon as the
/// last digit is typed; without it (choosing a new PIN) 4–6 digits are
/// accepted and confirmed with the ✓ key or Enter.
///
/// [message] is the calm line under the dots (wrong PIN, mismatch…);
/// [lockoutSeconds] > 0 swaps the dots for a countdown ring.
class PinPad extends StatefulWidget {
  const PinPad({
    super.key,
    this.length,
    required this.onSubmit,
    this.enabled = true,
    this.onChanged,
    this.captureKeyboard = false,
    this.hideTaps = false,
    this.message,
    this.messageTone = SecureTone.error,
    this.lockoutSeconds = 0,
    this.lockoutTotal = 0,
    this.compact,
  });
  final int? length;

  /// No press / hover highlight on the keys (the screen is being shared:
  /// a lit key would give the PIN away).
  final bool hideTaps;

  /// Lock screen: every hardware key goes to the pad, so nothing typed can
  /// reach (or trigger shortcuts in) the app underneath.
  final bool captureKeyboard;

  /// Returns false to shake and clear the dots.
  final FutureOr<bool> Function(String pin) onSubmit;
  final bool enabled;
  final VoidCallback? onChanged;

  final String? message;
  final SecureTone messageTone;
  final int lockoutSeconds;
  final int lockoutTotal;

  /// Smaller keys (desktop card). Defaults to [isDesktop].
  final bool? compact;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> with SingleTickerProviderStateMixin {
  static const _min = 4, _max = 6;
  String _pin = '';
  bool _busy = false;
  bool _error = false;
  final _focus = FocusNode(debugLabel: 'pin');
  late final AnimationController _shake;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
    if (widget.captureKeyboard) HardwareKeyboard.instance.addHandler(_onGlobalKey);
    // Take the keyboard even when another screen had focus underneath.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  bool _onGlobalKey(KeyEvent e) {
    // A dialog on top (forgot PIN) gets the keyboard for its text field.
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    _onKey(_focus, e);
    return true;
  }

  @override
  void dispose() {
    if (widget.captureKeyboard) HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    _focus.dispose();
    _shake.dispose();
    super.dispose();
  }

  int get _max0 => widget.length ?? _max;
  bool get _canConfirm => widget.length == null && _pin.length >= _min && !_busy;

  void _add(String d) {
    if (!widget.enabled || _busy || _pin.length >= _max0) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += d;
      _error = false;
    });
    widget.onChanged?.call();
    if (_pin.length == _max0) _submit();
  }

  void _back() {
    if (_pin.isEmpty || _busy) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _error = false;
    });
  }

  Future<void> _submit() async {
    if (_pin.length < _min || _busy) return;
    setState(() => _busy = true);
    // Let the last dot fill in before checking.
    await Future<void>.delayed(const Duration(milliseconds: 90));
    final ok = await widget.onSubmit(_pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) {
        _error = true;
        _pin = '';
      }
    });
    if (!ok) {
      HapticFeedback.heavyImpact();
      _shake.forward(from: 0);
    }
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.backspace || k == LogicalKeyboardKey.delete) {
      _back();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      if (_canConfirm) _submit();
      return KeyEventResult.handled;
    }
    final ch = e.character ?? k.keyLabel;
    if (ch.length == 1 && RegExp(r'\d').hasMatch(ch) && !HardwareKeyboard.instance.isControlPressed && !HardwareKeyboard.instance.isAltPressed) {
      _add(ch);
      return KeyEventResult.handled;
    }
    const numpad = [
      LogicalKeyboardKey.numpad0, LogicalKeyboardKey.numpad1, LogicalKeyboardKey.numpad2, LogicalKeyboardKey.numpad3, LogicalKeyboardKey.numpad4,
      LogicalKeyboardKey.numpad5, LogicalKeyboardKey.numpad6, LogicalKeyboardKey.numpad7, LogicalKeyboardKey.numpad8, LogicalKeyboardKey.numpad9,
    ];
    final i = numpad.indexOf(k);
    if (i >= 0) {
      _add('$i');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final compact = widget.compact ?? isDesktop(context);
    final dots = widget.length ?? math.max(_min, _pin.length);
    final locked = widget.lockoutSeconds > 0;
    final enabled = widget.enabled && !_busy && !locked;
    final media = MediaQuery.sizeOf(context);

    return Focus(
      focusNode: _focus,
      autofocus: true,
      // With captureKeyboard the global handler already took the key; the
      // focus system still delivers it here, so don't count it twice.
      onKeyEvent: widget.captureKeyboard ? (_, _) => KeyEventResult.handled : _onKey,
      child: GestureDetector(
        onTap: _focus.requestFocus,
        behavior: HitTestBehavior.translucent,
        child: LayoutBuilder(builder: (context, box) {
          final gap = compact ? 14.0 : 18.0;
          final width = math.min(box.maxWidth, compact ? 252.0 : 312.0);
          var key = ((width - 2 * gap) / 3).clamp(52.0, compact ? 64.0 : 78.0);
          if (!compact && media.height < 720) key = math.min(key, 64);
          final rowGap = compact ? 12.0 : (key > 70 ? 16.0 : 12.0);

          Widget digit(String d) => _PinKey(
                size: key,
                quiet: widget.hideTaps,
                label: d,
                onTap: enabled ? () => _add(d) : null,
                child: Text(
                  d,
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: key * 0.36,
                    fontWeight: FontWeight.w500,
                    height: 1,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: enabled ? context.lc.text : context.lc.muted.withValues(alpha: 0.45),
                  ),
                ),
              );
          Widget row(List<Widget> c) => SizedBox(
                width: key * 3 + gap * 2,
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: c),
              );

          final confirm = widget.length == null
              ? _PinKey(
                  size: key,
                  quiet: widget.hideTaps,
                  label: s('continue'),
                  filled: false,
                  accent: _canConfirm,
                  onTap: _canConfirm && enabled ? _submit : null,
                  child: Icon(AppIcons.check, size: key * 0.34, color: _canConfirm ? Colors.white : context.lc.muted.withValues(alpha: 0.35)),
                )
              : SizedBox(width: key, height: key);
          final back = _PinKey(
            size: key,
            quiet: widget.hideTaps,
            label: s('pin_delete'),
            filled: false,
            onTap: _pin.isEmpty || !enabled ? null : _back,
            child: Icon(AppIcons.backspace, size: key * 0.32, color: _pin.isEmpty || !enabled ? context.lc.muted.withValues(alpha: 0.35) : context.lc.text),
          );

          return Column(mainAxisSize: MainAxisSize.min, children: [
            // Dots, or the countdown ring while a wait is running.
            AnimatedSize(
              duration: Motion.normal,
              curve: Motion.curve,
              child: AnimatedSwitcher(
                duration: Motion.normal,
                child: locked
                    ? _LockoutRing(key: const ValueKey('ring'), seconds: widget.lockoutSeconds, total: widget.lockoutTotal)
                    : AnimatedBuilder(
                        key: const ValueKey('dots'),
                        animation: _shake,
                        builder: (context, child) => Transform.translate(
                          offset: Offset(math.sin(_shake.value * math.pi * 5) * 12 * (1 - _shake.value), 0),
                          child: child,
                        ),
                        child: Semantics(
                          label: s('pin_dots', {'n': _pin.length}),
                          liveRegion: true,
                          child: SizedBox(
                            height: 24,
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              for (var i = 0; i < dots; i++) _PinDot(filled: i < _pin.length, error: _error),
                            ]),
                          ),
                        ),
                      ),
              ),
            ),
            // Calm status line (never a toast).
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: compact ? 44 : 52),
              child: Center(
                child: AnimatedSwitcher(
                  duration: Motion.normal,
                  child: widget.message == null
                      ? const SizedBox.shrink()
                      : Padding(
                          key: ValueKey(widget.messageTone),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                          child: SecureMessage(widget.message!, tone: widget.messageTone, center: true),
                        ),
                ),
              ),
            ),
            AnimatedOpacity(
              duration: Motion.normal,
              opacity: locked ? 0.45 : 1,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                row([digit('1'), digit('2'), digit('3')]),
                SizedBox(height: rowGap),
                row([digit('4'), digit('5'), digit('6')]),
                SizedBox(height: rowGap),
                row([digit('7'), digit('8'), digit('9')]),
                SizedBox(height: rowGap),
                row([confirm, digit('0'), back]),
              ]),
            ),
          ]);
        }),
      ),
    );
  }
}

class _PinDot extends StatelessWidget {
  const _PinDot({required this.filled, required this.error});
  final bool filled;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9),
      child: AnimatedScale(
        scale: filled ? 1 : 0.82,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        child: AnimatedContainer(
          duration: Motion.normal,
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: filled && !error ? LC.gradient : null,
            color: error ? LC.danger.withValues(alpha: dark ? 0.22 : 0.14) : (filled ? null : (dark ? const Color(0xFF262B4D) : const Color(0xFFE3E6F2))),
            border: filled && !error ? null : Border.all(color: error ? LC.danger.withValues(alpha: 0.8) : (dark ? const Color(0xFF3A4070) : const Color(0xFFCDD1E4)), width: 1.5),
          ),
        ),
      ),
    );
  }
}

class _PinKey extends StatefulWidget {
  const _PinKey({required this.size, required this.child, required this.label, this.onTap, this.filled = true, this.accent = false, this.quiet = false});
  final double size;
  final bool quiet;
  final Widget child;
  final String label;
  final VoidCallback? onTap;
  final bool filled;
  final bool accent;
  @override
  State<_PinKey> createState() => _PinKeyState();
}

class _PinKeyState extends State<_PinKey> {
  bool _down = false;
  bool _hover = false;

  void _set({bool? down, bool? hover}) {
    if (widget.quiet) return;
    setState(() {
      _down = down ?? _down;
      _hover = hover ?? _hover;
    });
  }

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    final on = widget.onTap != null;
    final base = widget.filled ? (dark ? const Color(0xFF1D2140) : Colors.white) : Colors.transparent;
    final hover = widget.filled ? (dark ? const Color(0xFF252A50) : const Color(0xFFF1F2FA)) : context.lc.surface2.withValues(alpha: 0.6);
    final pressed = dark ? LC.primary.withValues(alpha: 0.30) : LC.primary.withValues(alpha: 0.14);
    final color = !on ? base : (_down ? pressed : (_hover ? hover : base));
    return Semantics(
      button: true,
      enabled: on,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => _set(hover: true),
        onExit: (_) => _set(hover: false, down: false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: on ? (_) => _set(down: true) : null,
          onTapUp: on ? (_) => _set(down: false) : null,
          onTapCancel: on ? () => _set(down: false) : null,
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _down ? 0.92 : 1,
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 110),
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.accent ? null : color,
                gradient: widget.accent ? LC.gradient : null,
                border: widget.filled && !widget.accent
                    ? Border.all(color: _down ? LC.primary.withValues(alpha: 0.6) : (dark ? const Color(0xFF2A2F55) : const Color(0xFFE1E4F0)))
                    : null,
              ),
              child: Center(child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Try again in 0:28" ring shown while wrong tries are on hold.
class _LockoutRing extends StatelessWidget {
  const _LockoutRing({super.key, required this.seconds, required this.total});
  final int seconds;
  final int total;

  @override
  Widget build(BuildContext context) {
    final t = math.max(total, seconds);
    final progress = t == 0 ? 0.0 : seconds / t;
    return Semantics(
      label: S.of(context)('pin_wait', {'t': formatWait(seconds)}),
      excludeSemantics: true,
      child: SizedBox(
        width: 84,
        height: 84,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: progress),
          duration: const Duration(milliseconds: 900),
          builder: (context, v, child) => CustomPaint(
            painter: _RingPainter(progress: v, color: LC.warning, track: context.lc.surface2),
            child: child,
          ),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(AppIcons.timer, size: 16, color: LC.warning),
              const SizedBox(height: 2),
              Text(
                formatWait(seconds),
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: context.lc.text,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.color, required this.track});
  final double progress;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 5.0;
    final rect = Offset.zero & size;
    final r = rect.deflate(stroke / 2);
    canvas.drawArc(r, 0, math.pi * 2, false, Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke);
    if (progress > 0) {
      canvas.drawArc(r, -math.pi / 2, math.pi * 2 * progress.clamp(0.0, 1.0), false, Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = stroke);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress || old.color != color || old.track != track;
}

// ========================================================= recovery phrase

final _legacyStart = RegExp(r'^[a-z2-7]{1,5}(-[a-z2-7]{0,5})*$');
final _hasLegacyMark = RegExp(r'[-2-7]');
final _phraseSep = RegExp(r'[\s,;]');

/// How a word box looks.
enum PhraseBoxState { neutral, ok, bad }

/// One numbered word box: used by [RecoveryPhraseInput] and by the
/// "Check your copy" step.
class PhraseWordBox extends StatelessWidget {
  const PhraseWordBox({
    super.key,
    required this.number,
    required this.controller,
    required this.focusNode,
    this.state = PhraseBoxState.neutral,
    this.enabled = true,
    this.autofocus = false,
    this.last = false,
    this.onChanged,
    this.onSubmitted,
    this.large = false,
    this.compact = false,
  });
  final int number;
  final TextEditingController controller;
  final FocusNode focusNode;
  final PhraseBoxState state;
  final bool enabled, autofocus, last, large;

  /// Narrow box (3 columns in a dialog): tighter number column and type.
  final bool compact;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final dark = _isDark(context);
    final focused = focusNode.hasFocus;
    final bad = state == PhraseBoxState.bad;
    final ok = state == PhraseBoxState.ok;
    final border = bad
        ? LC.danger.withValues(alpha: 0.75)
        : focused
            ? LC.primary
            : (dark ? const Color(0xFF2A2F55) : const Color(0xFFE1E4F0));
    final numColor = bad ? LC.danger : (ok ? LC.primary : context.lc.muted.withValues(alpha: 0.8));
    return AnimatedContainer(
      duration: Motion.fast,
      height: large ? 52 : 46,
      padding: EdgeInsets.only(left: compact ? 8 : 10, right: compact ? 4 : 6),
      decoration: BoxDecoration(
        color: bad ? LC.danger.withValues(alpha: dark ? 0.10 : 0.06) : (dark ? const Color(0xFF1B1F3A) : const Color(0xFFF2F3FA)),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border, width: focused || bad ? 1.5 : 1),
        boxShadow: focused ? [BoxShadow(color: LC.primary.withValues(alpha: dark ? 0.2 : 0.12), spreadRadius: 3)] : const [],
      ),
      child: Row(children: [
        Container(
          width: large ? 30 : (compact ? 20 : 24),
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '$number',
            style: TextStyle(fontFamily: kFontFamily, fontSize: large ? 13 : 12, fontWeight: FontWeight.w700, color: numColor, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
        Expanded(
          child: Semantics(
            label: s('sec_phrase_word', {'n': number}),
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: enabled,
              autofocus: autofocus,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              keyboardType: TextInputType.visiblePassword,
              textCapitalization: TextCapitalization.none,
              // Not single-line: a single-line field drops the line breaks of a
              // pasted phrase and glues its words together. A line break is
              // handled like a space instead.
              minLines: 1,
              maxLines: 2,
              textInputAction: last ? TextInputAction.done : TextInputAction.next,
              onChanged: onChanged,
              onSubmitted: (_) => onSubmitted?.call(),
              style: TextStyle(fontFamily: kFontFamily, fontSize: large ? 16 : (compact ? 14 : 15), fontWeight: FontWeight.w600, letterSpacing: compact ? 0 : 0.2, color: bad ? LC.danger : context.lc.text),
              decoration: const InputDecoration(
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ),
        if (ok && large) Icon(AppIcons.check, size: 16, color: LC.primary.withValues(alpha: 0.8)),
      ]),
    );
  }
}

/// Word suggestions floating just under the box linked to [link] (so they
/// stay next to the box being typed in, even on phones where the keyboard
/// covers the bottom of the page). The first one is what Tab / Enter picks.
class PhraseSuggestPortal extends StatefulWidget {
  const PhraseSuggestPortal({super.key, required this.link, required this.words, required this.onPick, required this.child, this.alignRight = false, this.number});
  final LayerLink? link;
  final List<String> words;
  final ValueChanged<String> onPick;
  final bool alignRight;

  /// Position of the word being typed (for screen readers).
  final int? number;
  final Widget child;

  @override
  State<PhraseSuggestPortal> createState() => _PhraseSuggestPortalState();
}

class _PhraseSuggestPortalState extends State<PhraseSuggestPortal> {
  final _portal = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _portal.show();
    });
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(controller: _portal, overlayChildBuilder: _overlay, child: widget.child);

  Widget _overlay(BuildContext context) {
    final link = widget.link;
    if (link == null || widget.words.isEmpty) return const SizedBox.shrink();
    final s = S.of(context);
    final dark = _isDark(context);
    final right = widget.alignRight;
    return CompositedTransformFollower(
      link: link,
      showWhenUnlinked: false,
      targetAnchor: right ? Alignment.bottomRight : Alignment.bottomLeft,
      followerAnchor: right ? Alignment.topRight : Alignment.topLeft,
      offset: const Offset(0, 6),
      child: Align(
        alignment: right ? Alignment.topRight : Alignment.topLeft,
        child: TextFieldTapRegion(
          child: Semantics(
            container: true,
            label: widget.number == null ? null : s('sec_phrase_suggestions', {'n': widget.number!}),
            child: Material(
              color: dark ? const Color(0xFF232849) : Colors.white,
              elevation: kNoShadows ? 0 : 8,
              shadowColor: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: LC.primary.withValues(alpha: dark ? 0.35 : 0.25))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  for (final (i, w) in widget.words.indexed) _SuggestChip(word: w, primary: i == 0, onTap: () => widget.onPick(w)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SuggestChip extends StatelessWidget {
  const _SuggestChip({required this.word, required this.primary, required this.onTap});
  final String word;
  final bool primary;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: primary ? LC.primary.withValues(alpha: dark ? 0.28 : 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(
                word,
                style: TextStyle(fontFamily: kFontFamily, fontSize: 14, fontWeight: primary ? FontWeight.w700 : FontWeight.w500, color: primary ? (dark ? const Color(0xFFC9C1FF) : LC.primary) : context.lc.text),
              ),
              if (primary && _desktopPlatform) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: context.lc.muted.withValues(alpha: 0.45))),
                  child: Text('Tab', style: TextStyle(fontFamily: kFontFamily, fontSize: 10, fontWeight: FontWeight.w600, color: context.lc.muted)),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// What to suggest for a box holding [text] (nothing once it is a full word
/// that no longer word begins with).
List<String> phraseSuggestionsFor(String text) {
  final t = text.trim().toLowerCase();
  final list = bip39Suggest(t);
  if (list.isEmpty || (list.length == 1 && list.first == t)) return const [];
  return list;
}

/// Recovery phrase entry: 24 numbered word boxes with suggestions from the
/// BIP39 word list (after 2 letters; Tab or Enter picks the first), per-word
/// checks (an unknown word turns red), paste-the-whole-phrase and a checksum
/// check once all 24 words are in. A phrase from an older version (base32
/// groups) switches to a single "older-style code" field.
///
/// [controller] holds the 24 full words joined by spaces, or the older-style
/// code as typed. Use [RecoveryPhraseInput.isReady] to enable the submit
/// button.
class RecoveryPhraseInput extends StatefulWidget {
  const RecoveryPhraseInput({super.key, required this.controller, this.onChanged, this.onSubmitted, this.autofocus = false, this.enabled = true});
  final TextEditingController controller;
  final VoidCallback? onChanged;
  final VoidCallback? onSubmitted;
  final bool autofocus;
  final bool enabled;

  /// Can [text] (this widget's controller value) be submitted: 24 known words
  /// with a matching checksum, or a complete older-style code (the core
  /// checks its check digits).
  static bool isReady(String text) => legacyPhraseComplete(text) || checkPhraseWords(phraseTokens(text)).ok;

  @override
  State<RecoveryPhraseInput> createState() => _RecoveryPhraseInputState();
}

class _RecoveryPhraseInputState extends State<RecoveryPhraseInput> {
  static const _n = kPhraseWords;
  late final List<TextEditingController> _slots = List.generate(_n, (_) => TextEditingController());
  late final List<FocusNode> _nodes = List.generate(_n, (i) => FocusNode(debugLabel: 'phrase-$i', onKeyEvent: (n, e) => _onKey(i, e)));
  late final List<LayerLink> _links = List.generate(_n, (_) => LayerLink());
  final _legacyCtl = TextEditingController();
  final _legacyNode = FocusNode(debugLabel: 'phrase-legacy');
  final Set<int> _touched = {};
  bool _legacy = false;
  bool _syncing = false;
  int _cols = 3;

  @override
  void initState() {
    super.initState();
    for (final (i, n) in _nodes.indexed) {
      n.addListener(() => _focusChanged(i));
    }
    _legacyNode.addListener(() => mounted ? setState(() {}) : null);
    widget.controller.addListener(_fromOutside);
    final t = widget.controller.text;
    if (t.trim().isNotEmpty) _load(t, focus: false);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_fromOutside);
    for (final c in _slots) {
      c.dispose();
    }
    for (final n in _nodes) {
      n.dispose();
    }
    _legacyCtl.dispose();
    _legacyNode.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ state

  List<String> get _words => [for (final c in _slots) c.text.trim()];
  int get _filled => _words.where((w) => w.isNotEmpty).length;

  int? get _active {
    for (var i = 0; i < _n; i++) {
      if (_nodes[i].hasFocus) return i;
    }
    return null;
  }

  PhraseBoxState _state(int i) {
    final w = _slots[i].text.trim();
    if (w.isEmpty) return PhraseBoxState.neutral;
    if (bip39Index(w) != null) return PhraseBoxState.ok;
    // Still typing the start of a real word: not red yet.
    return _nodes[i].hasFocus && bip39IsPrefix(w) ? PhraseBoxState.neutral : PhraseBoxState.bad;
  }

  /// Leaving a box: a 4-letter start becomes the full word.
  void _focusChanged(int i) {
    if (!_nodes[i].hasFocus) {
      final w = _slots[i].text.trim();
      if (w.isNotEmpty) {
        _touched.add(i);
        final full = bip39Word(w);
        if (full != null && full != w) {
          _setSlot(i, full);
          _sync();
        }
      }
    }
    if (mounted) setState(() {});
  }

  /// The parent cleared or replaced the phrase.
  void _fromOutside() {
    if (_syncing) return;
    final t = widget.controller.text;
    final current = _legacy ? _legacyCtl.text.trim() : _words.where((w) => w.isNotEmpty).join(' ');
    if (t.trim() == current) return;
    _load(t, focus: false);
    setState(() {});
  }

  void _load(String text, {required bool focus}) {
    _touched.clear();
    if (looksLikeLegacyPhrase(text)) {
      _enterLegacy(text, focus: focus);
    } else {
      _legacy = false;
      _fill(0, phraseTokens(text), clearRest: true, focus: focus);
    }
  }

  void _setSlot(int i, String v) {
    _slots[i].value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
  }

  void _sync() {
    _syncing = true;
    final text = _legacy ? _legacyCtl.text.trim() : _words.where((w) => w.isNotEmpty).join(' ');
    if (widget.controller.text != text) widget.controller.text = text;
    _syncing = false;
    widget.onChanged?.call();
  }

  /// Puts [words] into the boxes from [from] on (full words for 4-letter starts).
  void _fill(int from, List<String> words, {required bool clearRest, bool focus = true}) {
    for (var j = 0; j < words.length && from + j < _n; j++) {
      _setSlot(from + j, bip39Word(words[j]) ?? words[j]);
      _touched.add(from + j);
    }
    final end = math.min(_n, from + words.length);
    if (clearRest) {
      for (var j = end; j < _n; j++) {
        _setSlot(j, '');
        _touched.remove(j);
      }
    }
    _sync();
    if (focus) {
      var next = _slots.indexWhere((c) => c.text.isEmpty, end);
      if (next < 0) next = _slots.indexWhere((c) => c.text.isEmpty);
      _nodes[next < 0 ? math.min(end, _n - 1) : next].requestFocus();
    }
  }

  void _enterLegacy(String text, {bool focus = true}) {
    _legacy = true;
    final t = text.trim();
    _legacyCtl.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
    for (final c in _slots) {
      c.clear();
    }
    _sync();
    if (focus) _legacyNode.requestFocus();
  }

  void _leaveLegacy() {
    _legacy = false;
    _legacyCtl.clear();
    _touched.clear();
    _sync();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nodes[0].requestFocus();
    });
  }

  // ------------------------------------------------------------ typing

  void _onSlotChanged(int i, String value) {
    final tokens = phraseTokens(value);
    final hasSep = _phraseSep.hasMatch(value);
    if (tokens.length > 1 || (hasSep && tokens.isNotEmpty)) {
      // A pasted phrase (or a space typed after a word): spread it out.
      if (looksLikeLegacyPhrase(value)) {
        _enterLegacy(value);
      } else {
        _fill(i, tokens, clearRest: i == 0 && tokens.length > 1);
      }
    } else if (i == 0 && _hasLegacyMark.hasMatch(value) && _legacyStart.hasMatch(value.trim().toLowerCase())) {
      // Digits or dashes never appear in the word list: an older-style code.
      _enterLegacy(value);
    } else {
      final w = tokens.isEmpty ? '' : tokens.first;
      if (w != value) _setSlot(i, w);
      _touched.remove(i);
      // A complete word that no longer word starts with: move on.
      if (w.isNotEmpty && bip39Index(w) != null && bip39Words[bip39Index(w)!] == w && phraseSuggestionsFor(w).isEmpty && i < _n - 1) {
        _touched.add(i);
        _nodes[i + 1].requestFocus();
      }
      _sync();
    }
    setState(() {});
  }

  void _pick(int i, String word) {
    _setSlot(i, word);
    _touched.add(i);
    _sync();
    if (i < _n - 1) {
      _nodes[i + 1].requestFocus();
    } else {
      setState(() {});
    }
  }

  KeyEventResult _onKey(int i, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.backspace && _slots[i].text.isEmpty && i > 0) {
      _nodes[i - 1].requestFocus();
      final prev = _slots[i - 1];
      prev.selection = TextSelection.collapsed(offset: prev.text.length);
      return KeyEventResult.handled;
    }
    final enter = k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter;
    final pickKey = (k == LogicalKeyboardKey.tab && !HardwareKeyboard.instance.isShiftPressed) || enter;
    if (pickKey) {
      final sug = phraseSuggestionsFor(_slots[i].text);
      if (sug.isNotEmpty) {
        _pick(i, sug.first);
        return KeyEventResult.handled;
      }
    }
    if (enter) {
      _submitted(i);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Enter / "next" in box [i]: take the suggestion, else move on (or submit).
  void _submitted(int i) {
    final sug = phraseSuggestionsFor(_slots[i].text);
    if (sug.isNotEmpty) {
      _pick(i, sug.first);
    } else if (i < _n - 1) {
      _nodes[i + 1].requestFocus();
    } else {
      widget.onSubmitted?.call();
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty || !mounted) return;
    _load(text, focus: true);
    setState(() {});
  }

  void _clear() {
    _touched.clear();
    if (_legacy) {
      _legacyCtl.clear();
      _sync();
    } else {
      _fill(0, const [], clearRest: true);
    }
    setState(() {});
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return AnimatedSwitcher(
      duration: Motion.normal,
      layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
      child: _legacy ? KeyedSubtree(key: const ValueKey('legacy'), child: _legacyField(context, s)) : KeyedSubtree(key: const ValueKey('words'), child: _wordGrid(context, s)),
    );
  }

  Widget _wordGrid(BuildContext context, S s) {
    final filled = _filled;
    final bad = [for (var i = 0; i < _n; i++) if (_state(i) == PhraseBoxState.bad) i];
    final words = _words;
    final allIn = filled == _n && bad.isEmpty;
    final check = allIn ? checkPhraseWords(words) : null;
    final active = _active;
    final sug = active == null ? const <String>[] : phraseSuggestionsFor(_slots[active].text);
    final Widget status;
    if (bad.isNotEmpty) {
      status = SecureMessage(s('sec_phrase_unknown', {'n': bad.first + 1}), key: const ValueKey('bad'));
    } else if (check != null && !check.ok) {
      status = SecureMessage(s('sec_phrase_checksum'), key: const ValueKey('checksum'));
    } else if (check != null) {
      status = SecureMessage(s('sec_phrase_valid'), tone: SecureTone.ok, key: const ValueKey('valid'));
    } else {
      status = Text(
        s('sec_phrase_count', {'n': filled, 't': _n}),
        key: const ValueKey('count'),
        style: context.tt.bodySmall?.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]),
      );
    }
    return PhraseSuggestPortal(
      link: active == null ? null : _links[active],
      words: widget.enabled ? sug : const [],
      alignRight: active != null && _cols > 1 && active % _cols == _cols - 1,
      number: active == null ? null : active + 1,
      onPick: (w) {
        if (active != null) _pick(active, w);
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        LayoutBuilder(builder: (context, box) {
          // 3 × 8 on desktop cards, 2 × 12 on phones (room for "category").
          final cols = box.maxWidth >= 340 && isDesktop(context) ? 3 : 2;
          _cols = cols;
          const gap = 8.0;
          final w = (box.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(spacing: gap, runSpacing: gap, children: [
            for (var i = 0; i < _n; i++)
              SizedBox(
                width: w,
                child: CompositedTransformTarget(
                  link: _links[i],
                  child: PhraseWordBox(
                    number: i + 1,
                    controller: _slots[i],
                    focusNode: _nodes[i],
                    state: _state(i),
                    compact: w < 125,
                    enabled: widget.enabled,
                    autofocus: widget.autofocus && i == 0,
                    last: i == _n - 1,
                    onChanged: (v) => _onSlotChanged(i, v),
                    onSubmitted: () => _submitted(i),
                  ),
                ),
              ),
          ]);
        }),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: AnimatedSwitcher(
              duration: Motion.fast,
              layoutBuilder: (current, previous) => Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
              child: status,
            ),
          ),
          if (filled > 0)
            _MiniAction(icon: AppIcons.close, label: s('sec_phrase_clear'), onTap: widget.enabled ? _clear : null)
          else
            _MiniAction(icon: AppIcons.paste, label: s('sec_phrase_paste'), onTap: widget.enabled ? _paste : null),
        ]),
        if (filled == 0) ...[
          const SizedBox(height: 8),
          Text(s('sec_phrase_help'), style: context.tt.bodySmall?.copyWith(height: 1.45)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: widget.enabled ? () => setState(() => _enterLegacy('')) : null,
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4), visualDensity: VisualDensity.compact),
              child: Text(s('sec_phrase_have_legacy')),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _legacyField(BuildContext context, S s) {
    final dark = _isDark(context);
    final focused = _legacyNode.hasFocus;
    final n = _legacyCtl.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').length;
    final complete = legacyPhraseComplete(_legacyCtl.text);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      // Wraps on small phones instead of overflowing.
      Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 4, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: LC.warning.withValues(alpha: dark ? 0.18 : 0.12), borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(AppIcons.history, size: 14, color: LC.warning),
            const SizedBox(width: 6),
            Text(s('sec_phrase_legacy'), style: const TextStyle(fontFamily: kFontFamily, fontSize: 12.5, fontWeight: FontWeight.w700, color: LC.warning)),
          ]),
        ),
        TextButton(
          onPressed: widget.enabled ? _leaveLegacy : null,
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          child: Text(s('sec_phrase_use_words')),
        ),
      ]),
      const SizedBox(height: 10),
      Text(s('sec_phrase_legacy_note'), style: context.tt.bodySmall?.copyWith(height: 1.45)),
      const SizedBox(height: 12),
      AnimatedContainer(
        duration: Motion.fast,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF1B1F3A) : const Color(0xFFF2F3FA),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: focused ? LC.primary : (dark ? const Color(0xFF2A2F55) : const Color(0xFFE1E4F0)), width: focused ? 1.5 : 1),
          boxShadow: focused ? [BoxShadow(color: LC.primary.withValues(alpha: dark ? 0.2 : 0.12), spreadRadius: 3)] : const [],
        ),
        child: Semantics(
          label: s('sec_phrase_legacy'),
          child: TextField(
            controller: _legacyCtl,
            focusNode: _legacyNode,
            enabled: widget.enabled,
            autofocus: true,
            minLines: 2,
            maxLines: 3,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.done,
            onChanged: (_) {
              _sync();
              setState(() {});
            },
            onSubmitted: (_) => widget.onSubmitted?.call(),
            style: TextStyle(fontFamily: kFontFamily, fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0.6, height: 1.5, color: context.lc.text),
            decoration: InputDecoration(
              hintText: s('sec_phrase_legacy_hint'),
              isCollapsed: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: complete
              ? SecureMessage(s('sec_phrase_legacy_ready'), tone: SecureTone.ok)
              : Text(s('sec_phrase_legacy_count', {'n': n}), style: context.tt.bodySmall?.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
        ),
        if (n > 0)
          _MiniAction(icon: AppIcons.close, label: s('sec_phrase_clear'), onTap: widget.enabled ? _clear : null)
        else
          _MiniAction(icon: AppIcons.paste, label: s('sec_phrase_paste'), onTap: widget.enabled ? _paste : null),
      ]),
    ]);
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: onTap,
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10)),
        icon: Icon(icon, size: 16),
        label: Text(label),
      );
}

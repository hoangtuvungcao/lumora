import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../state/settings.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/secure_input.dart';

/// Text sizes offered on the welcome step (Settings › Appearance keeps the
/// fine-grained slider over the same [Settings.textScale]).
const kOnboardingTextScales = [(0.9, 'onb_size_s'), (1.0, 'onb_size_m'), (1.15, 'onb_size_l')];

/// First onboarding step ("Welcome"): language, theme and text size. Every
/// choice is applied and saved at once (the UI settings file is written
/// before the core starts), so the next launch opens in the same look.
/// Arrow keys move between the cards of a row, Tab between rows, Enter
/// continues.
class OnboardingAppearance extends StatelessWidget {
  const OnboardingAppearance({super.key, required this.onContinue});
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final st = context.watch<Settings>();
    final scale = kOnboardingTextScales.map((e) => e.$1).reduce((a, b) => (a - st.textScale).abs() <= (b - st.textScale).abs() ? a : b);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): onContinue,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): onContinue,
      },
      child: Focus(
        autofocus: true,
        skipTraversal: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SecureHero(title: s('onb_setup_title'), subtitle: s('onb_setup_sub'), icon: AppIcons.palette, compact: true),
          const SizedBox(height: 26),
          _SectionLabel(icon: AppIcons.language, text: s('settings_language')),
          ChoiceRow<String>(
            label: s('settings_language'),
            values: const ['vi', 'en'],
            selected: st.locale,
            onChanged: (v) => st.update((x) => x.locale = v),
            semanticLabel: (v) => v == 'vi' ? 'Tiếng Việt' : 'English',
            builder: (_, v, sel, _) => _LangOption(code: v, selected: sel),
          ),
          const SizedBox(height: 22),
          _SectionLabel(icon: AppIcons.palette, text: s('settings_appearance')),
          ChoiceRow<ThemeMode>(
            label: s('settings_appearance'),
            values: const [ThemeMode.light, ThemeMode.dark, ThemeMode.system],
            selected: st.themeMode,
            onChanged: (v) => st.update((x) => x.themeMode = v),
            semanticLabel: (v) => _themeLabel(s, v),
            semanticHint: (v) => v == ThemeMode.system ? s('onb_theme_system_hint') : null,
            gap: 10,
            builder: (_, v, sel, w) => _ThemeOption(mode: v, label: _themeLabel(s, v), selected: sel, narrow: w < 120),
          ),
          const SizedBox(height: 22),
          _SectionLabel(icon: AppIcons.textSize, text: s('font_size')),
          ChoiceRow<double>(
            label: s('font_size'),
            values: [for (final o in kOnboardingTextScales) o.$1],
            selected: scale,
            onChanged: (v) => st.update((x) => x.textScale = v),
            semanticLabel: (v) => s(kOnboardingTextScales.firstWhere((o) => o.$1 == v).$2),
            gap: 10,
            builder: (_, v, sel, _) => _SizeOption(scale: v, label: s(kOnboardingTextScales.firstWhere((o) => o.$1 == v).$2), selected: sel),
          ),
          const SizedBox(height: 28),
          SecurePrimaryButton(label: s('continue'), icon: AppIcons.next, onPressed: onContinue),
          const SizedBox(height: 12),
          Text(
            s('onb_setup_later'),
            textAlign: TextAlign.center,
            style: context.tt.bodySmall?.copyWith(color: context.lc.muted, height: 1.45),
          ),
        ]),
      ),
    );
  }

  static String _themeLabel(S s, ThemeMode m) => switch (m) {
        ThemeMode.light => s('theme_light'),
        ThemeMode.dark => s('theme_dark'),
        ThemeMode.system => s('onb_theme_system'),
      };
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 10),
          child: Row(children: [
            Icon(icon, size: 16, color: context.lc.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 13.5, color: context.lc.text.withValues(alpha: 0.9)),
              ),
            ),
          ]),
        ),
      );
}

/// A row of equally wide, single-choice cards (a radio group): ←/→ move
/// the choice along the row, Tab leaves it, Space picks the focused card.
class ChoiceRow<T> extends StatefulWidget {
  const ChoiceRow({
    super.key,
    required this.label,
    required this.values,
    required this.selected,
    required this.onChanged,
    required this.builder,
    required this.semanticLabel,
    this.semanticHint,
    this.gap = 12,
  });

  final String label;
  final List<T> values;
  final T selected;
  final ValueChanged<T> onChanged;
  /// Builds a card's content; [width] is the card's width.
  final Widget Function(BuildContext context, T value, bool selected, double width) builder;
  final String Function(T value) semanticLabel;
  final String? Function(T value)? semanticHint;
  final double gap;

  @override
  State<ChoiceRow<T>> createState() => _ChoiceRowState<T>();
}

class _ChoiceRowState<T> extends State<ChoiceRow<T>> {
  late List<FocusNode> _nodes = _makeNodes();

  List<FocusNode> _makeNodes() => [for (final v in widget.values) FocusNode(debugLabel: 'choice $v')];

  @override
  void didUpdateWidget(ChoiceRow<T> old) {
    super.didUpdateWidget(old);
    if (old.values.length != widget.values.length) {
      for (final n in _nodes) {
        n.dispose();
      }
      _nodes = _makeNodes();
    }
  }

  @override
  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final step = switch (e.logicalKey) {
      LogicalKeyboardKey.arrowRight => rtl ? -1 : 1,
      LogicalKeyboardKey.arrowLeft => rtl ? 1 : -1,
      _ => 0,
    };
    if (step == 0) return KeyEventResult.ignored;
    final i = _nodes.indexWhere((n) => n.hasPrimaryFocus);
    if (i < 0) return KeyEventResult.ignored;
    final next = (i + step) % _nodes.length;
    widget.onChanged(widget.values[next]);
    _nodes[next].requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final n = widget.values.length;
        return _row(context, (box.maxWidth - widget.gap * (n - 1)) / n);
      });

  Widget _row(BuildContext context, double width) {
    final children = <Widget>[];
    for (var i = 0; i < widget.values.length; i++) {
      final v = widget.values[i];
      final sel = v == widget.selected;
      if (i > 0) children.add(SizedBox(width: widget.gap));
      children.add(Expanded(
        child: _ChoiceCard(
          focusNode: _nodes[i],
          selected: sel,
          label: widget.semanticLabel(v),
          hint: widget.semanticHint?.call(v),
          onTap: () => widget.onChanged(v),
          child: widget.builder(context, v, sel, width),
        ),
      ));
    }
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: widget.label,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: FocusTraversalGroup(
          child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)),
        ),
      ),
    );
  }
}

class _ChoiceCard extends StatefulWidget {
  const _ChoiceCard({required this.focusNode, required this.selected, required this.label, required this.onTap, required this.child, this.hint});
  final FocusNode focusNode;
  final bool selected;
  final String label;
  final String? hint;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_ChoiceCard> createState() => _ChoiceCardState();
}

class _ChoiceCardState extends State<_ChoiceCard> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final sel = widget.selected;
    final bg = sel
        ? LC.primary.withValues(alpha: dark ? 0.16 : 0.07)
        : _hover
            ? (dark ? const Color(0xFF242950) : const Color(0xFFF1F2FA))
            : (dark ? context.lc.surface2.withValues(alpha: 0.55) : context.lc.surface);
    final border = sel
        ? LC.primary
        : _hover
            ? LC.primary.withValues(alpha: 0.4)
            : (dark ? const Color(0xFF2A2F55) : context.lc.divider);
    return MergeSemantics(
      child: Semantics(
        inMutuallyExclusiveGroup: true,
        checked: sel,
        selected: sel,
        label: widget.label,
        hint: widget.hint,
        child: AnimatedContainer(
          duration: Motion.normal,
          curve: Motion.curve,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(color: border, width: sel ? 1.6 : 1),
          ),
          // Keyboard focus: a halo outside the card (the fill stays as is).
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(
              color: _focus ? LC.primary.withValues(alpha: 0.45) : Colors.transparent,
              width: 3,
              strokeAlign: BorderSide.strokeAlignOutside,
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              focusNode: widget.focusNode,
              borderRadius: BorderRadius.circular(Radii.lg),
              // The card draws its own hover / focus states.
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              onTap: widget.onTap,
              onHover: (v) => setState(() => _hover = v),
              onFocusChange: (v) => setState(() => _focus = v),
              child: Stack(children: [
                ExcludeSemantics(child: widget.child),
                Positioned(top: 7, right: 7, child: _CheckBadge(on: sel)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckBadge extends StatelessWidget {
  const _CheckBadge({required this.on});
  final bool on;
  @override
  Widget build(BuildContext context) => AnimatedScale(
        scale: on ? 1 : 0.4,
        duration: Motion.normal,
        curve: on ? Curves.easeOutBack : Motion.curve,
        child: AnimatedOpacity(
          opacity: on ? 1 : 0,
          duration: Motion.fast,
          child: Container(
            width: 19,
            height: 19,
            decoration: const BoxDecoration(shape: BoxShape.circle, gradient: LC.gradient),
            child: const Icon(AppIcons.check, size: 12, color: Colors.white),
          ),
        ),
      );
}

// ------------------------------------------------------------------ options

class _LangOption extends StatelessWidget {
  const _LangOption({required this.code, required this.selected});
  final String code;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final vi = code == 'vi';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        AnimatedContainer(
          duration: Motion.normal,
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: selected ? LC.gradient : null,
            color: selected ? null : LC.primary.withValues(alpha: dark ? 0.14 : 0.10),
            borderRadius: BorderRadius.circular(11),
            border: selected ? null : Border.all(color: LC.primary.withValues(alpha: dark ? 0.24 : 0.20)),
          ),
          child: Text(
            vi ? 'VI' : 'EN',
            textScaler: TextScaler.noScaling,
            style: TextStyle(
              fontFamily: kFontFamily,
              fontWeight: FontWeight.w700,
              fontSize: 13.5,
              letterSpacing: 0.4,
              color: selected ? Colors.white : (dark ? Color.lerp(LC.primary, Colors.white, 0.3) : LC.primary),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          vi ? 'Tiếng Việt' : 'English',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.tt.titleSmall?.copyWith(fontWeight: FontWeight.w700, fontSize: 15.5, color: context.lc.text),
        ),
        const SizedBox(height: 2),
        Text(
          vi ? 'Xin chào!' : 'Hello!',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.tt.bodySmall?.copyWith(color: context.lc.muted),
        ),
      ]),
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({required this.mode, required this.label, required this.selected, required this.narrow});
  final ThemeMode mode;
  final String label;
  final bool selected;

  /// Small phones: the icon sits above the label, which may wrap.
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final icon = switch (mode) {
      ThemeMode.light => AppIcons.sun,
      ThemeMode.dark => AppIcons.moon,
      ThemeMode.system => AppIcons.themeAuto,
    };
    final fg = selected ? context.lc.text : context.lc.muted;
    final style = (context.tt.bodyMedium ?? const TextStyle()).copyWith(fontWeight: FontWeight.w600, fontSize: 13.5, color: fg);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        AspectRatio(aspectRatio: 1.32, child: ThemePreview(mode: mode)),
        const SizedBox(height: 9),
        if (narrow) ...[
          Icon(icon, size: 15, color: selected ? LC.primary : fg),
          const SizedBox(height: 4),
          Text(label, maxLines: 2, textAlign: TextAlign.center, style: style.copyWith(height: 1.25)),
        ] else
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 15, color: selected ? LC.primary : fg),
            const SizedBox(width: 6),
            Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1, style: style))),
          ]),
      ]),
    );
  }
}

class _SizeOption extends StatelessWidget {
  const _SizeOption({required this.scale, required this.label, required this.selected});
  final double scale;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? context.lc.text : context.lc.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // The sample shows the option's own size, whatever is applied now.
        SizedBox(
          height: 26,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Text(
              'Aa',
              textScaler: TextScaler.noScaling,
              style: TextStyle(fontFamily: kFontFamily, fontWeight: FontWeight.w700, fontSize: 17 * scale, height: 1.1, color: selected ? LC.primary : fg),
            ),
          ),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(label, maxLines: 1, style: context.tt.bodySmall?.copyWith(fontWeight: FontWeight.w600, color: fg)),
        ),
      ]),
    );
  }
}

// ----------------------------------------------------------------- previews

/// Miniature of the app (rail, header, chat bubbles, composer) drawn in the
/// light or dark palette; "system" shows both, split on the diagonal.
class ThemePreview extends StatelessWidget {
  const ThemePreview({super.key, required this.mode});
  final ThemeMode mode;

  @override
  Widget build(BuildContext context) {
    final Widget body = switch (mode) {
      ThemeMode.light => const _MiniApp(LumoraColors.light),
      ThemeMode.dark => const _MiniApp(LumoraColors.dark),
      ThemeMode.system => Stack(fit: StackFit.expand, children: [
          const _MiniApp(LumoraColors.light),
          ClipPath(clipper: _DiagonalClip(), child: const _MiniApp(LumoraColors.dark)),
        ]),
    };
    return ExcludeSemantics(
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: context.lc.divider),
        ),
        child: ClipRRect(borderRadius: BorderRadius.circular(10), child: body),
      ),
    );
  }
}

class _DiagonalClip extends CustomClipper<Path> {
  @override
  Path getClip(Size s) => Path()
    ..moveTo(s.width * 0.62, 0)
    ..lineTo(s.width, 0)
    ..lineTo(s.width, s.height)
    ..lineTo(s.width * 0.38, s.height)
    ..close();

  @override
  bool shouldReclip(_DiagonalClip oldClipper) => false;
}

class _MiniApp extends StatelessWidget {
  const _MiniApp(this.c);
  final LumoraColors c;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth, h = box.maxHeight;
        final u = h / 20; // grid unit
        Widget bar(double width, Color color, {double? height, Gradient? gradient}) => Container(
              width: width,
              height: height ?? u * 1.1,
              decoration: BoxDecoration(color: gradient == null ? color : null, gradient: gradient, borderRadius: BorderRadius.circular(u)),
            );
        return ColoredBox(
          color: c.bg,
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Navigation rail.
            Container(
              width: w * 0.17,
              color: c.rail,
              padding: EdgeInsets.symmetric(vertical: u * 1.4),
              child: Column(children: [
                Container(width: w * 0.08, height: w * 0.08, decoration: BoxDecoration(gradient: LC.gradient, borderRadius: BorderRadius.circular(u * 0.8))),
                for (var i = 0; i < 3; i++) ...[
                  SizedBox(height: u * 1.3),
                  Container(width: w * 0.06, height: w * 0.06, decoration: BoxDecoration(color: c.muted.withValues(alpha: 0.35), shape: BoxShape.circle)),
                ],
              ]),
            ),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // Header.
                Container(
                  height: u * 3.6,
                  color: c.surface,
                  padding: EdgeInsets.symmetric(horizontal: u * 1.2),
                  child: Row(children: [
                    Container(width: u * 2, height: u * 2, decoration: BoxDecoration(color: LC.accent.withValues(alpha: 0.8), shape: BoxShape.circle)),
                    SizedBox(width: u * 0.9),
                    bar(w * 0.24, c.text.withValues(alpha: 0.75), height: u * 0.9),
                  ]),
                ),
                Container(height: 0.6, color: c.divider),
                // Messages.
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.all(u * 1.2),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                      Align(alignment: Alignment.centerLeft, child: bar(w * 0.42, c.surface2, height: u * 2.2)),
                      Align(alignment: Alignment.centerRight, child: bar(w * 0.36, LC.primary, height: u * 2.2, gradient: LC.gradient)),
                      Align(alignment: Alignment.centerLeft, child: bar(w * 0.28, c.surface2, height: u * 2.2)),
                    ]),
                  ),
                ),
                // Composer.
                Padding(
                  padding: EdgeInsets.fromLTRB(u * 1.2, 0, u * 1.2, u * 1.2),
                  child: Container(
                    height: u * 2.4,
                    decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(u * 1.2), border: Border.all(color: c.divider, width: 0.6)),
                  ),
                ),
              ]),
            ),
          ]),
        );
      });
}

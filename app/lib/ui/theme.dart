import 'dart:io' show Platform;

import 'package:flutter/material.dart';

/// Lumora design tokens.
abstract final class LC {
  static const primary = Color(0xFF6C5CE7);
  static const accent = Color(0xFF00C2D1);
  static const success = Color(0xFF22C55E);
  static const warning = Color(0xFFF59E0B);
  static const danger = Color(0xFFEF4444);

  static const darkBg = Color(0xFF0F1020);
  static const darkSurface = Color(0xFF171A2E);
  static const darkSurface2 = Color(0xFF1F2340);
  static const darkText = Color(0xFFE8EAF6);
  static const darkMuted = Color(0xFF9AA0C3);

  static const lightBg = Color(0xFFF7F8FC);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightSurface2 = Color(0xFFEEF0F8);
  static const lightText = Color(0xFF14162B);
  static const lightMuted = Color(0xFF5B607D);

  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primary, accent],
  );
}

abstract final class Radii {
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
}

abstract final class Motion {
  static const fast = Duration(milliseconds: 120);
  static const normal = Duration(milliseconds: 200);
  static const slow = Duration(milliseconds: 320);
  static const curve = Curves.easeOutCubic;
}

const kFontFamily = 'BeVietnamPro';

/// The headless test renderer draws BoxShadow blur as hard offset shapes;
/// drop decorative shadows there so screenshots match the real look.
final bool kNoShadows = Platform.environment.containsKey('FLUTTER_TEST');
const kFontFallback = ['NotoColorEmoji', 'Noto Color Emoji', 'Apple Color Emoji', 'Segoe UI Emoji'];

/// Extra semantic colours not covered by [ColorScheme].
@immutable
class LumoraColors extends ThemeExtension<LumoraColors> {
  const LumoraColors({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.text,
    required this.muted,
    required this.divider,
    required this.bubbleIn,
    required this.rail,
    required this.hover,
  });

  final Color bg;
  final Color surface;
  final Color surface2;
  final Color text;
  final Color muted;
  final Color divider;
  final Color bubbleIn;
  final Color rail;
  final Color hover;

  static const dark = LumoraColors(
    bg: LC.darkBg,
    surface: LC.darkSurface,
    surface2: LC.darkSurface2,
    text: LC.darkText,
    muted: LC.darkMuted,
    divider: Color(0xFF262A4A),
    bubbleIn: LC.darkSurface2,
    rail: Color(0xFF0B0C18),
    hover: Color(0x149AA0C3),
  );

  static const light = LumoraColors(
    bg: LC.lightBg,
    surface: LC.lightSurface,
    surface2: LC.lightSurface2,
    text: LC.lightText,
    muted: LC.lightMuted,
    divider: Color(0xFFE3E6F0),
    bubbleIn: Color(0xFFFFFFFF),
    rail: Color(0xFFE9EBF5),
    hover: Color(0x0F14162B),
  );

  @override
  LumoraColors copyWith() => this;

  @override
  LumoraColors lerp(LumoraColors? other, double t) {
    if (other == null) return this;
    return LumoraColors(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      bubbleIn: Color.lerp(bubbleIn, other.bubbleIn, t)!,
      rail: Color.lerp(rail, other.rail, t)!,
      hover: Color.lerp(hover, other.hover, t)!,
    );
  }
}

extension LumoraThemeX on BuildContext {
  LumoraColors get lc => Theme.of(this).extension<LumoraColors>()!;
  TextTheme get tt => Theme.of(this).textTheme;
  ColorScheme get cs => Theme.of(this).colorScheme;
}

ThemeData buildTheme(Brightness b, {bool compact = false}) {
  final dark = b == Brightness.dark;
  final c = dark ? LumoraColors.dark : LumoraColors.light;
  final scheme = ColorScheme(
    brightness: b,
    primary: LC.primary,
    onPrimary: Colors.white,
    primaryContainer: dark ? const Color(0xFF2D2670) : const Color(0xFFE6E2FF),
    onPrimaryContainer: dark ? const Color(0xFFE6E2FF) : const Color(0xFF231B6B),
    secondary: LC.accent,
    onSecondary: const Color(0xFF00262A),
    secondaryContainer: dark ? const Color(0xFF0B3F47) : const Color(0xFFD5F7FA),
    onSecondaryContainer: dark ? const Color(0xFFBFF4F8) : const Color(0xFF00363B),
    tertiary: LC.warning,
    onTertiary: Colors.black,
    error: LC.danger,
    onError: Colors.white,
    surface: c.surface,
    onSurface: c.text,
    onSurfaceVariant: c.muted,
    surfaceContainerLowest: c.bg,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.surface2,
    surfaceContainerHighest: c.surface2,
    outline: dark ? const Color(0xFF3A3F66) : const Color(0xFFCDD1E1),
    outlineVariant: c.divider,
    shadow: Colors.black,
    inverseSurface: dark ? LC.lightSurface : LC.darkSurface,
    onInverseSurface: dark ? LC.lightText : LC.darkText,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: scheme,
    fontFamily: kFontFamily,
    fontFamilyFallback: kFontFallback,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
    extensions: [c],
  );

  final text = base.textTheme.apply(bodyColor: c.text, displayColor: c.text).copyWith(
        titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: c.text, fontSize: 20),
        titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: c.text, fontSize: 15.5),
        titleSmall: base.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: c.text),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(color: c.text, fontSize: 14, height: 1.38),
        bodySmall: base.textTheme.bodySmall?.copyWith(color: c.muted, fontSize: 12.5),
        labelSmall: base.textTheme.labelSmall?.copyWith(color: c.muted, letterSpacing: 0.6, fontWeight: FontWeight.w600),
      );

  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(Radii.md),
    borderSide: BorderSide(color: scheme.outlineVariant),
  );

  return base.copyWith(
    textTheme: text,
    dividerTheme: DividerThemeData(color: c.divider, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
        side: BorderSide(color: c.divider),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface2,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      hintStyle: TextStyle(color: c.muted),
      border: border,
      enabledBorder: border.copyWith(borderSide: const BorderSide(color: Colors.transparent)),
      focusedBorder: border.copyWith(borderSide: const BorderSide(color: LC.primary, width: 1.4)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: LC.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size(64, 44),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        iconSize: 18,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
        textStyle: const TextStyle(fontFamily: kFontFamily, fontWeight: FontWeight.w600, fontSize: 14.5),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.text,
        minimumSize: const Size(64, 44),
        side: BorderSide(color: scheme.outline),
        iconSize: 18,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
        textStyle: const TextStyle(fontFamily: kFontFamily, fontWeight: FontWeight.w600, fontSize: 14.5),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: dark ? const Color(0xFFA99EFF) : LC.primary,
        iconSize: 18,
        textStyle: const TextStyle(fontFamily: kFontFamily, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sm)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: c.muted),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: c.muted,
      textColor: c.text,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : c.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? LC.primary : c.surface2),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? LC.primary : scheme.outline),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.surface2,
      selectedColor: scheme.primaryContainer,
      side: BorderSide.none,
      labelStyle: TextStyle(fontFamily: kFontFamily, color: c.text, fontSize: 13, fontWeight: FontWeight.w500),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.xl)),
      showCheckmark: false,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.xl)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surface2,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: c.divider)),
      textStyle: TextStyle(fontFamily: kFontFamily, color: c.text, fontSize: 14),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      height: 66,
      // Regular glyphs at rest, filled + brand colour when selected.
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
            size: 24,
            color: s.contains(WidgetState.selected) ? (dark ? const Color(0xFFC9C2FF) : LC.primary) : c.muted,
          )),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontFamily: kFontFamily,
            fontSize: 11.5,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
            color: s.contains(WidgetState.selected) ? c.text : c.muted,
          )),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? LC.darkSurface2 : LC.darkSurface,
      contentTextStyle: const TextStyle(fontFamily: kFontFamily, color: LC.darkText),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: dark ? Colors.black : LC.darkSurface, borderRadius: BorderRadius.circular(Radii.sm)),
      textStyle: const TextStyle(fontFamily: kFontFamily, color: Colors.white, fontSize: 12.5),
      waitDuration: const Duration(milliseconds: 400),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: LC.primary, linearTrackColor: c.surface2),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStateProperty.all(c.muted.withValues(alpha: 0.35)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: scheme.primaryContainer,
        selectedForegroundColor: scheme.onPrimaryContainer,
        side: BorderSide(color: scheme.outline),
        textStyle: const TextStyle(fontFamily: kFontFamily, fontWeight: FontWeight.w600, fontSize: 13),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
  );
}

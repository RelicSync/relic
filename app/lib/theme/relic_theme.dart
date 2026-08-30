import 'package:flutter/material.dart';

import 'tokens.dart';

/// A Material [ThemeData] derived from the Relic palette, for the surfaces
/// that still use Material widgets (onboarding TextFields, ListTiles,
/// AlertDialogs). Keeps them on-palette in both light and dark instead of the
/// old hardcoded ThemeData.dark wrappers.
ThemeData materialThemeFor(RelicColors c) {
  final brightness = c.isDark ? Brightness.dark : Brightness.light;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: c.base,
    fontFamily: 'StackSansText',
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: c.accent,
      onPrimary: c.onAccent,
      secondary: c.accentMuted,
      onSecondary: c.onAccent,
      error: c.danger,
      onError: c.onAccent,
      surface: c.panel,
      onSurface: c.text,
    ),
    dividerColor: c.borderStrong,
    dialogTheme: DialogThemeData(
      backgroundColor: c.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: BorderSide(color: c.border),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.base,
      foregroundColor: c.text,
      elevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      hintStyle: TextStyle(color: c.textFaintest),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.input),
        borderSide: BorderSide(color: c.borderStrong),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.input),
        borderSide: BorderSide(color: c.accent, width: 1.5),
      ),
    ),
  );
}

/// Provides the active [RelicColors] down the tree and exposes the three faces
/// of the 2026 system:
///
///   [headline] — Stack Sans Headline. Titles, big numbers, the wordmark. Set
///                tight; the negative tracking is baked in and scales.
///   [sans]     — Stack Sans Text. Every other string: rows, buttons, body,
///                settings, dialogs.
///   [mono]     — JetBrains Mono. Kickers, tags, counters, keycaps, secret
///                values, and any content that is itself code.
///
/// The rule of thumb from the design: if it is prose or a control, it is sans;
/// if it is a machine fact, it is mono.
class RelicTheme extends InheritedWidget {
  final RelicColors colors;

  /// True on phones (set by the mobile shell). Shared widgets read it via
  /// [isMobileOf] to use larger fonts / row heights / touch targets without
  /// forking a separate mobile layout.
  final bool isMobile;

  const RelicTheme({
    super.key,
    required this.colors,
    this.isMobile = false,
    required super.child,
  });

  static RelicColors of(BuildContext context) {
    final t = context.dependOnInheritedWidgetOfExactType<RelicTheme>();
    assert(t != null, 'RelicTheme missing from tree');
    return t!.colors;
  }

  static bool isMobileOf(BuildContext context) {
    final t = context.dependOnInheritedWidgetOfExactType<RelicTheme>();
    return t?.isMobile ?? false;
  }

  /// Layout breakpoint, deliberately separate from [isMobileOf]: that flag
  /// means "touch device" and keeps driving finger-sized targets, fonts and
  /// row heights; this one means "enough room for a two-pane layout" (iPad,
  /// Android tablets, foldables). Width-derived and reactive — an iPad in
  /// Split View can be 320dp wide, so it must re-evaluate on every resize,
  /// never cache a device class. docs/apple-port-2026-08.md §5.
  static bool isWideOf(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= wideBreakpoint;

  /// Minimum logical width for the two-pane layout.
  static const double wideBreakpoint = 700;

  @override
  bool updateShouldNotify(RelicTheme old) =>
      old.colors != colors || old.isMobile != isMobile;

  static TextStyle sans({
    double size = 13,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? height,
    double? letterSpacing,
  }) =>
      TextStyle(
        fontFamily: 'StackSansText',
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
      );

  /// Display type. The system sets headlines at −0.03em, tightening to −0.045em
  /// at hero scale, so the tracking is derived from [size] rather than passed.
  static TextStyle headline({
    double size = 20,
    FontWeight weight = FontWeight.w700,
    Color? color,
    double? height,
    double? letterSpacing,
  }) =>
      TextStyle(
        fontFamily: 'StackSansHeadline',
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height ?? (size >= 30 ? 1.05 : 1.2),
        letterSpacing: letterSpacing ?? size * (size >= 48 ? -0.045 : -0.03),
      );

  static TextStyle mono({
    double size = 12,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? height,
    double? letterSpacing,
  }) =>
      TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
      );

  /// A small uppercase mono section/field label.
  static TextStyle label(Color color) => const TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
      ).copyWith(color: color);

  /// The system's section kicker — "01 · CAPTURE". Uppercase mono, widely
  /// tracked, quiet. Callers uppercase the string themselves.
  static TextStyle kicker(Color color, {double size = 10}) => TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: size,
        fontWeight: FontWeight.w500,
        letterSpacing: size * 0.14,
        color: color,
      );
}

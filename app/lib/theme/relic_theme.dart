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
    fontFamily: 'IBMPlexSans',
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

/// Provides the active [RelicColors] down the tree and exposes the two IBM Plex
/// faces. Sans = UI/titles/body; Mono = search, secrets, content, labels, meta.
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
        fontFamily: 'IBMPlexSans',
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
      );

  static TextStyle mono({
    double size = 12,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? height,
    double? letterSpacing,
  }) =>
      TextStyle(
        fontFamily: 'IBMPlexMono',
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
      );

  /// A small uppercase mono section/field label.
  static TextStyle label(Color color) => const TextStyle(
        fontFamily: 'IBMPlexMono',
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
      ).copyWith(color: color);
}

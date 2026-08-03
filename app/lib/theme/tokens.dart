import 'package:flutter/widgets.dart';

/// Relic design tokens — transcribed from `design/relic-design-board.html`.
/// Dark is the default; light is a parity theme. Two-base: warm archival.
@immutable
class RelicColors {
  // surfaces (back → front)
  final Color base; // window / deepest popup bg
  final Color footer; // footer / deepest strip
  final Color panel; // panel / card / list-row bg
  final Color surface; // input / elevated chip / icon tile
  final Color surfaceHover; // hovered row/surface
  final Color selected; // selected row bg (amber tint)
  final Color selectedTile; // selected row's icon tile

  // text
  final Color text; // primary
  final Color textSecondary; // secondary
  final Color textMuted; // muted labels
  final Color textFaint; // meta line
  final Color textFaintest; // placeholder / hints
  final Color textOnSelected; // primary text on a selected row

  // accent (amber)
  final Color accent;
  final Color accentBright; // brighter amber on selection
  final Color accentMuted; // muted amber meta
  final Color accentDeep; // darker amber (light theme primary)
  final Color onAccent; // text/icon on an amber fill

  // borders & lines
  final Color border; // hairline
  final Color borderStrong; // stronger hairline / focus-ish

  // ghost chrome & floating surfaces
  final Color ghostHover; // ghost-button hover bg
  final Color selectedCard; // selected-row floating card bg
  final Color cardShadow; // selected-card shadow
  final Color autotagText; // quiet machine-tag "#tag" text
  final Color surfaceRaised; // floating chrome bg (toasts)
  final Color backdrop; // gallery / behind-window backdrop
  final Color inset; // recessed wells (recovery key, keycaps)

  // shadows
  final Color shadowStrong; // window / frame shadows
  final Color shadowModal; // dialog / toast shadows
  final Color shadowSoft; // menu / popover shadows

  // controls
  final Color track; // toggle / slider / progress off-track
  final Color toggleKnob; // toggle on-knob

  // semantic
  final Color success;
  final Color successDim;
  final Color warning;
  final Color warningDim;
  final Color warningBg;
  final Color danger;
  final Color dangerText;
  final Color dangerBg;

  // secret (violet)
  final Color secret;
  final Color secretBright;
  final Color secretBg;
  final Color secretBorder;

  // photo thumbnail placeholder
  final Color thumbBg;
  final Color thumbBar;

  final bool isDark;

  const RelicColors({
    required this.base,
    required this.footer,
    required this.panel,
    required this.surface,
    required this.surfaceHover,
    required this.selected,
    required this.selectedTile,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.textFaint,
    required this.textFaintest,
    required this.textOnSelected,
    required this.accent,
    required this.accentBright,
    required this.accentMuted,
    required this.accentDeep,
    required this.onAccent,
    required this.border,
    required this.borderStrong,
    required this.ghostHover,
    required this.selectedCard,
    required this.cardShadow,
    required this.autotagText,
    required this.surfaceRaised,
    required this.backdrop,
    required this.inset,
    required this.shadowStrong,
    required this.shadowModal,
    required this.shadowSoft,
    required this.track,
    required this.toggleKnob,
    required this.success,
    required this.successDim,
    required this.warning,
    required this.warningDim,
    required this.warningBg,
    required this.danger,
    required this.dangerText,
    required this.dangerBg,
    required this.secret,
    required this.secretBright,
    required this.secretBg,
    required this.secretBorder,
    required this.thumbBg,
    required this.thumbBar,
    required this.isDark,
  });

  static const dark = RelicColors(
    base: Color(0xFF16130E),
    footer: Color(0xFF14110C),
    panel: Color(0xFF1C1813),
    surface: Color(0xFF221E17),
    surfaceHover: Color(0xFF2A251B),
    selected: Color(0xFF34280F),
    selectedTile: Color(0xFF3E3014),
    text: Color(0xFFECE4D6),
    textSecondary: Color(0xFFA89D89),
    textMuted: Color(0xFF8A8070),
    textFaint: Color(0xFF7E7464),
    textFaintest: Color(0xFF6E6555),
    textOnSelected: Color(0xFFFBEFD6),
    accent: Color(0xFFDAA43E),
    accentBright: Color(0xFFECB857),
    accentMuted: Color(0xFFC49A5A),
    accentDeep: Color(0xFFB5832A),
    onAccent: Color(0xFF1A1206),
    border: Color(0x12FFFFFF), // rgba(255,255,255,0.07)
    borderStrong: Color(0x1FFFFFFF), // ~0.12
    ghostHover: Color(0xFF2A251B),
    selectedCard: Color(0xFF2C2619),
    cardShadow: Color(0x40000000),
    autotagText: Color(0xFF7E7050),
    surfaceRaised: Color(0xFF25201A),
    backdrop: Color(0xFF0E0C08),
    inset: Color(0xFF0F0C08),
    shadowStrong: Color(0x99140E04),
    shadowModal: Color(0x99000000),
    shadowSoft: Color(0x59000000),
    track: Color(0xFF2E281E),
    toggleKnob: Color(0xFFFFF8EC),
    success: Color(0xFF5FAE7A),
    successDim: Color(0xFF7FAE8E),
    warning: Color(0xFFE68A39),
    warningDim: Color(0xFFE0954B),
    warningBg: Color(0xFF241809),
    danger: Color(0xFFD2553F),
    dangerText: Color(0xFFE07A66),
    dangerBg: Color(0xFF2A1512),
    secret: Color(0xFF9683C6),
    secretBright: Color(0xFFAC9AD6),
    secretBg: Color(0xFF1E1A26),
    secretBorder: Color(0x599683C6), // rgba(150,131,198,0.35)
    thumbBg: Color(0xFF1F2A33),
    thumbBar: Color(0xFF33485A),
    isDark: true,
  );

  static const light = RelicColors(
    base: Color(0xFFF4EEE2),
    footer: Color(0xFFEFE7D6),
    panel: Color(0xFFFBF7EF),
    surface: Color(0xFFFFFFFF),
    surfaceHover: Color(0xFFF3ECDD),
    selected: Color(0xFFFFFFFF),
    selectedTile: Color(0xFFFBEFD2),
    text: Color(0xFF231D13),
    textSecondary: Color(0xFF6B6151),
    // Darkened for readable contrast on the near-white panels (the originals
    // sat ~2.5:1, below the 4.5:1 bar). Muted/faint ≈ 5:1, faintest ≈ 3.8:1.
    textMuted: Color(0xFF726A58),
    textFaint: Color(0xFF726A58),
    textFaintest: Color(0xFF8C8170),
    textOnSelected: Color(0xFF231D13),
    accent: Color(0xFFB5832A),
    accentBright: Color(0xFF87601A),
    accentMuted: Color(0xFF8A6A2A),
    accentDeep: Color(0xFFB5832A),
    onAccent: Color(0xFFFFF8EC),
    border: Color(0xFFE0D6C4),
    borderStrong: Color(0xFFD8CEBC),
    ghostHover: Color(0xFFEFE7D6),
    selectedCard: Color(0xFFFFFFFF),
    cardShadow: Color(0x1E231D13),
    autotagText: Color(0xFF95866B),
    surfaceRaised: Color(0xFFFFFFFF),
    backdrop: Color(0xFFE8E3D8),
    inset: Color(0xFFEFE7D6),
    shadowStrong: Color(0x40140E04),
    shadowModal: Color(0x33000000),
    shadowSoft: Color(0x26000000),
    track: Color(0xFFD8CEBC),
    toggleKnob: Color(0xFFFFF8EC),
    success: Color(0xFF2F8A55),
    successDim: Color(0xFF2F8A55),
    warning: Color(0xFFB5701E),
    warningDim: Color(0xFFB5701E),
    warningBg: Color(0xFFFBF1E5),
    danger: Color(0xFFB23A28),
    dangerText: Color(0xFFB23A28),
    dangerBg: Color(0xFFFBE7E2),
    secret: Color(0xFF6A56A0),
    secretBright: Color(0xFF6A56A0),
    secretBg: Color(0xFFF1ECFA),
    secretBorder: Color(0xFFD6CBEC),
    thumbBg: Color(0xFF1F2A33),
    thumbBar: Color(0xFF33485A),
    isDark: false,
  );
}

/// 4px-base spacing scale.
class Insets {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
}

class Radii {
  static const double chip = 6;
  static const double tile = 9;
  static const double row = 10;
  static const double input = 8;
  static const double card = 12;
  static const double popup = 0; // square outer panels (opaque window, no rounded corners)
  static const double pill = 999;
}

class Motion {
  static const selection = Duration(milliseconds: 120);
  static const panel = Duration(milliseconds: 180);
  static const toastIn = Duration(milliseconds: 160);
  static const toastOut = Duration(milliseconds: 240);
}

import 'package:flutter/widgets.dart';

/// Relic design tokens — transcribed from the 2026 design system
/// (`design_handoff_relic_landing`). Warm parchment ground, white cards, ink
/// text, gold gradient accents. Light is the default; dark is the parity theme
/// and is keyed to the system's own dark band rather than invented.
///
/// Where the source palette failed contrast for running text it has been
/// darkened, and the original value is named in a comment. The bright golds
/// (#FFD616 → #F2AE38) are **fill** colors: gold as *text* is always the deep
/// gold on a gold-tint chip, exactly as the system does it.
@immutable
class RelicColors {
  // surfaces (back → front)
  final Color base; // window / deepest popup bg
  final Color footer; // footer / deepest strip
  final Color panel; // panel / card / list-row bg
  final Color surface; // input / elevated chip / icon tile
  final Color surfaceHover; // hovered row/surface
  final Color selected; // selected row bg
  final Color selectedTile; // selected row's icon tile

  // text
  final Color text; // primary
  final Color textSecondary; // secondary
  final Color textMuted; // muted labels
  final Color textFaint; // meta line
  final Color textFaintest; // placeholder / hints
  final Color textOnSelected; // primary text on a selected row

  // accent (gold)
  final Color accent; // fill gold — marks, dots, icons, gradients
  final Color accentBright; // brightest gold (gradient start, fills only)
  final Color accentMuted; // deep gold used as TEXT (on chips / cards)
  final Color accentDeep; // deep gold, headings and emphasis
  final Color onAccent; // text/icon on a gold fill

  // borders & lines
  final Color border; // hairline
  final Color borderStrong; // stronger hairline / focus-ish

  // ghost chrome & floating surfaces
  final Color ghostHover; // ghost-button hover bg
  final Color selectedCard; // selected-row floating card bg
  final Color cardShadow; // selected-card shadow
  final Color autotagText; // quiet machine-tag "#tag" text
  final Color tagBg; // tag / meta chip ground
  final Color tagText; // tag / meta chip text (deep gold, reads on tagBg)
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

  // secret
  //
  // The 2026 system has no violet: a secret is marked with the warm "SECRET"
  // chip (gold-tint ground, deep-gold text), the same one the design file uses.
  // These four keep their old names so call sites do not have to change.
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
    required this.tagBg,
    required this.tagText,
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

  /// Parchment. The default.
  static const light = RelicColors(
    base: Color(0xFFF5F1E8), // page ground
    footer: Color(0xFFEFE7D6), // hero band bottom / deepest strip
    panel: Color(0xFFFFFFFF), // cards
    surface: Color(0xFFFFFFFF), // inputs, icon tiles (defined by border)
    surfaceHover: Color(0xFFF3EEE2),
    selected: Color(0xFFFFFFFF), // selected row is a white card + gold border
    selectedTile: Color(0xFFF9F0D6),
    text: Color(0xFF111110), // ink
    textSecondary: Color(0xFF5B5B57), // system "muted"
    textMuted: Color(0xFF5B5B57),
    // System "faint" is #9C9C96 (≈2.9:1 on white). Kept only for hints below;
    // anything that is really read is darkened to clear 4.5:1.
    textFaint: Color(0xFF6E6E68),
    textFaintest: Color(0xFF8C8C86),
    textOnSelected: Color(0xFF111110),
    accent: Color(0xFFDA9E12), // fill gold
    accentBright: Color(0xFFF2AE38),
    accentMuted: Color(0xFF7A5E14), // gold as text, on a gold-tint chip
    accentDeep: Color(0xFF8A6A1B),
    onAccent: Color(0xFF33200A),
    border: Color(0x14111110), // rgba(17,17,16,0.08)
    borderStrong: Color(0x29111110), // rgba(17,17,16,0.16)
    ghostHover: Color(0xFFEFE7D6),
    selectedCard: Color(0xFFFFFFFF),
    cardShadow: Color(0x268C6414), // rgba(140,100,20,0.15)
    autotagText: Color(0xFF8C8C86),
    tagBg: Color(0xFFF5EDD6),
    tagText: Color(0xFF7A5E14),
    surfaceRaised: Color(0xFFFFFFFF),
    backdrop: Color(0xFFEFEADF),
    inset: Color(0xFFF1EDE4),
    shadowStrong: Color(0x33000000),
    shadowModal: Color(0x2E000000),
    shadowSoft: Color(0x1F8C6414),
    track: Color(0xFFE3DCCB),
    toggleKnob: Color(0xFFFFFFFF),
    success: Color(0xFF2F8A55),
    successDim: Color(0xFF4CAF6E),
    warning: Color(0xFFB5701E),
    warningDim: Color(0xFFB5701E),
    warningBg: Color(0xFFFBF1E5),
    danger: Color(0xFFB23A28),
    dangerText: Color(0xFFB23A28),
    dangerBg: Color(0xFFFBE7E2),
    secret: Color(0xFF8A6A1B),
    secretBright: Color(0xFF7A5E14),
    secretBg: Color(0xFFF5EDD6),
    secretBorder: Color(0xFFE7D9AC),
    thumbBg: Color(0xFFF1F1EF),
    thumbBar: Color(0xFFEAEAE7),
    isDark: false,
  );

  /// Ink. Keyed to the system's dark privacy band.
  static const dark = RelicColors(
    base: Color(0xFF111110),
    footer: Color(0xFF0C0C0B),
    panel: Color(0xFF1D1D1B),
    surface: Color(0xFF262623),
    surfaceHover: Color(0xFF2A2A27),
    selected: Color(0xFF2A2A27),
    selectedTile: Color(0xFF3A3320),
    text: Color(0xFFF1F1EF),
    textSecondary: Color(0xFFB9B9B3),
    textMuted: Color(0xFFB9B9B3),
    textFaint: Color(0xFF8A8A84),
    textFaintest: Color(0xFF75756F),
    textOnSelected: Color(0xFFF1F1EF),
    accent: Color(0xFFF5C542), // the band's gold kicker
    accentBright: Color(0xFFFFD429),
    accentMuted: Color(0xFFD8B45C),
    accentDeep: Color(0xFFC79A1E),
    onAccent: Color(0xFF33200A),
    border: Color(0x14F1F1EF), // rgba(241,241,239,0.08)
    borderStrong: Color(0x29F1F1EF), // rgba(241,241,239,0.16)
    ghostHover: Color(0xFF262623),
    selectedCard: Color(0xFF262623),
    cardShadow: Color(0x73000000),
    autotagText: Color(0xFF8A8A84),
    tagBg: Color(0xFF332D1E),
    tagText: Color(0xFFE0C878),
    surfaceRaised: Color(0xFF24241F),
    backdrop: Color(0xFF0A0A09),
    inset: Color(0xFF0C0C0B),
    shadowStrong: Color(0x99000000),
    shadowModal: Color(0x99000000),
    shadowSoft: Color(0x59000000),
    track: Color(0xFF2E2E2A),
    toggleKnob: Color(0xFFF1F1EF),
    success: Color(0xFF75C284),
    successDim: Color(0xFF8FBF9A),
    warning: Color(0xFFE6A44C),
    warningDim: Color(0xFFDDA45E),
    warningBg: Color(0xFF2A2114),
    danger: Color(0xFFE8695A),
    dangerText: Color(0xFFEE8375),
    dangerBg: Color(0xFF2C1917),
    secret: Color(0xFFE0CE9A),
    secretBright: Color(0xFFF0DC94),
    secretBg: Color(0xFF2A2622),
    secretBorder: Color(0x59E0CE9A),
    thumbBg: Color(0xFF1D1D1B),
    thumbBar: Color(0xFF2E2E2A),
    isDark: true,
  );
}

/// The system's gold gradient. Fills only — buttons, marks, the "+" chip.
/// `linear-gradient(150deg, #FFD616, #F2AE38)`; 150° in CSS runs top-ish-left
/// to bottom-ish-right, which is this begin/end pair.
class Gradients {
  static const gold = LinearGradient(
    begin: Alignment(-0.5, -1),
    end: Alignment(0.5, 1),
    colors: [Color(0xFFFFD616), Color(0xFFF2AE38)],
  );

  /// The headline gradient, for the one emphasized word.
  /// `linear-gradient(120deg, #F0B400 10%, #EE9310 90%)`
  static const headline = LinearGradient(
    begin: Alignment(-1, -0.6),
    end: Alignment(1, 0.6),
    colors: [Color(0xFFF0B400), Color(0xFFEE9310)],
    stops: [0.1, 0.9],
  );
}

/// 4px-base spacing scale. The 2026 system breathes considerably more than the
/// old one, so the scale runs further up.
class Insets {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double section = 40;
}

class Radii {
  static const double tag = 6; // tag / meta chips
  static const double chip = 8; // badges, small square controls
  static const double tile = 10; // icon tiles
  static const double row = 14; // list rows
  static const double input = 12; // search / text fields
  static const double card = 18; // small cards, panels
  static const double cardLarge = 24; // feature cards
  static const double popup = 0; // square outer panel (opaque window)
  static const double pill = 999;
}

class Motion {
  static const selection = Duration(milliseconds: 120);
  static const panel = Duration(milliseconds: 180);
  static const toastIn = Duration(milliseconds: 160);
  static const toastOut = Duration(milliseconds: 240);
}

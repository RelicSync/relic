import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/relic_theme.dart';
import '../theme/tokens.dart';

/// Shared de-boxed control set for the 2026 visual language: ghost buttons
/// (borderless, hover-tinted), the filled primary CTA, and the hover/tap
/// plumbing they build on. Everything reads [RelicColors] tokens, so all
/// variants work in both palettes.

/// A tap target that swallows the gesture so an enclosing row's onTap doesn't
/// also fire. (Moved here from result_row.dart so any in-row control can use it.)
class SwallowTap extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  const SwallowTap({super.key, required this.child, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: RawGestureDetector(
        gestures: {
          SwallowTapRecognizer:
              GestureRecognizerFactoryWithHandlers<SwallowTapRecognizer>(
                () => SwallowTapRecognizer(),
                (r) => r.onTap = onTap,
              ),
        },
        child: child,
      ),
    );
  }
}

/// A tap recognizer that wins over the parent row's tap (so action buttons
/// act, not the row).
class SwallowTapRecognizer extends TapGestureRecognizer {
  @override
  void rejectGesture(int pointer) {
    // prefer to accept
    acceptGesture(pointer);
  }
}

/// Hover-tracking wrapper: builds its child with the current hover state and
/// handles cursor + tap. The base of every ghost control.
class Hoverable extends StatefulWidget {
  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback? onTap;
  final bool swallowTap;
  const Hoverable({
    super.key,
    required this.builder,
    this.onTap,
    this.swallowTap = false,
  });

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    Widget w = MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: widget.builder(context, _hover),
    );
    final onTap = widget.onTap;
    if (onTap == null) return w;
    if (widget.swallowTap) {
      // Opaque outer detector eats the raw hit so the row underneath never
      // sees it; the swallow recognizer delivers the actual tap.
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: SwallowTap(onTap: onTap, child: w),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: w,
    );
  }
}

enum GhostStyle {
  /// Borderless, transparent at rest (subtle surface fill on touch devices),
  /// [RelicColors.ghostHover] on hover. The default chrome button.
  ghost,

  /// Filled accent CTA (copy-on-selected, header +, primary dialog actions).
  filled,

  /// Destructive ghost: danger-colored glyph, transparent at rest,
  /// danger-tinted bg on hover.
  danger,

  /// Destructive CTA with a standing tint (confirm-delete buttons).
  dangerTint,

  /// Toggled-on state (pinned, active sort/date): amber-tinted fill.
  active,
}

/// The shared de-boxed button. Icon-only (square, [size] edge) when [label]
/// is null; a labeled pill (height [size], horizontal padding) otherwise.
class GhostButton extends StatelessWidget {
  final IconData? icon;
  final Widget Function(double size, Color color)? iconBuilder;
  final String? label;
  final double size;
  final GhostStyle style;
  final bool swallowTap;
  final VoidCallback? onTap; // null = disabled
  final String? tooltip;
  final double? radius;
  final double? iconSize; // defaults to size * 0.5
  final double? fontSize; // labeled buttons; defaults to 12.5

  const GhostButton({
    super.key,
    this.icon,
    this.iconBuilder,
    this.label,
    this.size = 28,
    this.style = GhostStyle.ghost,
    this.swallowTap = false,
    required this.onTap,
    this.tooltip,
    this.radius,
    this.iconSize,
    this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final mobile = RelicTheme.isMobileOf(context);
    // Phones get a finger-friendly minimum target.
    final s = mobile && label == null ? (size * 1.4).clamp(40.0, 64.0) : size;
    final disabled = onTap == null;

    return Hoverable(
      onTap: onTap,
      swallowTap: swallowTap,
      builder: (context, hovered) {
        final (Color bg, Color fg) = switch (style) {
          GhostStyle.filled => (
              hovered ? c.accentBright : c.accent,
              c.onAccent,
            ),
          GhostStyle.danger => (
              hovered ? c.dangerBg : const Color(0x00000000),
              c.dangerText,
            ),
          GhostStyle.dangerTint => (c.dangerBg, c.dangerText),
          GhostStyle.active => (c.selected, c.accent),
          GhostStyle.ghost => (
              hovered
                  ? c.ghostHover
                  // Touch devices have no hover; keep a faint standing fill
                  // so the control still reads as tappable.
                  : (mobile ? c.surface : const Color(0x00000000)),
              hovered ? c.text : c.textSecondary,
            ),
        };
        final fgFinal = disabled ? c.textFaintest : fg;
        final iSize = iconSize ?? s * 0.5;

        Widget inner;
        if (label == null) {
          inner = iconBuilder?.call(iSize, fgFinal) ??
              Icon(icon, size: iSize, color: fgFinal);
        } else {
          inner = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null || iconBuilder != null) ...[
                iconBuilder?.call(iSize, fgFinal) ??
                    Icon(icon, size: iSize, color: fgFinal),
                const SizedBox(width: 6),
              ],
              Text(
                label!,
                style: RelicTheme.sans(
                  size: fontSize ?? 12.5,
                  weight: style == GhostStyle.filled
                      ? FontWeight.w600
                      : FontWeight.w500,
                  color: fgFinal,
                ),
              ),
            ],
          );
        }

        Widget btn = AnimatedContainer(
          duration: Motion.selection,
          width: label == null ? s : null,
          height: s,
          padding: label == null
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: disabled && style == GhostStyle.filled ? c.track : bg,
            borderRadius: BorderRadius.circular(radius ?? Radii.input),
          ),
          // Container's `alignment` makes it EXPAND under bounded constraints,
          // which would stretch labeled buttons to full width. Icon-only
          // squares have a fixed width, so alignment is safe there; labeled
          // buttons hug their label via a widthFactor Center instead.
          alignment: label == null ? Alignment.center : null,
          child: label == null ? inner : Center(widthFactor: 1, child: inner),
        );
        if (tooltip != null) {
          btn = Tooltip(
            message: tooltip!,
            waitDuration: const Duration(milliseconds: 500),
            textStyle: RelicTheme.mono(size: 10, color: c.text),
            decoration: BoxDecoration(
              color: c.panel,
              borderRadius: BorderRadius.circular(Radii.chip),
              border: Border.all(color: c.borderStrong, width: 1),
            ),
            child: btn,
          );
        }
        return btn;
      },
    );
  }
}

/// Filled accent CTA with a label (dialog primaries, Update now, connect).
class PrimaryButton extends StatelessWidget {
  final IconData? icon;
  final String label;
  final VoidCallback? onTap;
  final double height;
  const PrimaryButton({
    super.key,
    this.icon,
    required this.label,
    required this.onTap,
    this.height = 30,
  });

  @override
  Widget build(BuildContext context) => GhostButton(
        icon: icon,
        label: label,
        size: height,
        style: GhostStyle.filled,
        onTap: onTap,
        iconSize: 13,
      );
}

/// Square icon-only ghost (header/dialog close buttons, inline icon actions).
class GhostIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double? iconSize;
  final String? tooltip;
  final bool swallowTap;
  const GhostIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.size = 28,
    this.iconSize,
    this.tooltip,
    this.swallowTap = false,
  });

  @override
  Widget build(BuildContext context) => GhostButton(
        icon: icon,
        size: size,
        onTap: onTap,
        iconSize: iconSize,
        tooltip: tooltip,
        swallowTap: swallowTap,
      );
}

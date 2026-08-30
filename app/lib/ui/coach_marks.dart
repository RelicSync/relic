import 'package:flutter/widgets.dart';

import '../theme/relic_theme.dart';
import '../theme/tokens.dart';
import '../widgets/controls.dart';

/// One coach-mark step: a widget to spotlight (via its [GlobalKey]) plus a short
/// explanation. If the key isn't laid out, the callout just centers.
class CoachStep {
  final GlobalKey targetKey;
  final String title;
  final String body;
  const CoachStep({required this.targetKey, required this.title, required this.body});
}

/// A dismissable, first-run coach-mark overlay. Dims the popup, spotlights one
/// real widget at a time (anchored by GlobalKey) with a short callout, and
/// advances on Next. Meant to be dropped into the popup's Stack (fills it).
class CoachMarks extends StatefulWidget {
  final List<CoachStep> steps;
  final VoidCallback onDone;
  const CoachMarks({super.key, required this.steps, required this.onDone});

  @override
  State<CoachMarks> createState() => _CoachMarksState();
}

class _CoachMarksState extends State<CoachMarks> {
  int _i = 0;

  void _next() {
    if (_i >= widget.steps.length - 1) {
      widget.onDone();
    } else {
      setState(() => _i++);
    }
  }

  /// Target rect in this overlay's own coordinate space, padded a little.
  Rect? _targetRect() {
    final self = context.findRenderObject();
    final tctx = widget.steps[_i].targetKey.currentContext;
    if (self is! RenderBox || tctx == null) return null;
    final box = tctx.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    final tl = box.localToGlobal(Offset.zero, ancestor: self);
    return (tl & box.size).inflate(5);
  }

  @override
  Widget build(BuildContext context) {
    final c = RelicTheme.of(context);
    final step = widget.steps[_i];
    return LayoutBuilder(builder: (context, constraints) {
      final overlay = Size(constraints.maxWidth, constraints.maxHeight);
      final rect = _targetRect();
      // Callout goes below the target if there's room, else above. Falls back to
      // centered when the target isn't measurable.
      const cardW = 268.0;
      const cardH = 156.0;
      double left, top;
      bool arrowUp; // arrow points up (callout is below the target)
      if (rect == null) {
        left = (overlay.width - cardW) / 2;
        top = (overlay.height - cardH) / 2;
        arrowUp = false;
      } else {
        left = (rect.center.dx - cardW / 2).clamp(12.0, overlay.width - cardW - 12);
        final below = rect.bottom + 12;
        if (below + cardH <= overlay.height - 12) {
          top = below;
          arrowUp = true;
        } else {
          top = (rect.top - cardH - 12).clamp(12.0, overlay.height - cardH - 12);
          arrowUp = false;
        }
      }
      return Stack(
        children: [
          // Scrim + spotlight cutout; absorbs taps so the popup behind is inert.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: CustomPaint(
                // The dim is the shadow black both palettes already use,
                // carried up to scrim strength: parchment is too light to dim
                // with, and ink would wash out in the dark theme.
                painter: _ScrimPainter(
                  rect,
                  c.shadowStrong.withValues(alpha: c.isDark ? 0.74 : 0.58),
                  c.accent,
                ),
              ),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            width: cardW,
            child: _callout(c, step, arrowUp),
          ),
        ],
      );
    });
  }

  Widget _callout(RelicColors c, CoachStep step, bool arrowUp) {
    final last = _i == widget.steps.length - 1;
    return Container(
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: c.border, width: 1),
        // It genuinely floats over the popup, so it takes the window
        // elevation. Deliberately not glass: the only thing behind it is a
        // flat scrim, and a blur with nothing interesting behind it just
        // reads as muddy.
        boxShadow: Shadows.window(c),
      ),
      padding: const EdgeInsets.fromLTRB(
        Insets.lg,
        Insets.lg,
        Insets.lg,
        Insets.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(step.title, style: RelicTheme.headline(size: 15, color: c.text)),
          const SizedBox(height: Insets.sm),
          Text(step.body,
              style: RelicTheme.sans(
                  size: 12.5, color: c.textSecondary, height: 1.45)),
          const SizedBox(height: Insets.lg),
          Row(children: [
            // progress dots
            for (var k = 0; k < widget.steps.length; k++)
              Padding(
                padding: const EdgeInsets.only(right: Insets.xs),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    // The hairline token is an 8%-alpha line, far too faint to
                    // read as a dot; the control track is the standing "off"
                    // fill in both palettes.
                    color: k == _i ? c.accent : c.track,
                  ),
                ),
              ),
            const Spacer(),
            if (!last) ...[
              GhostButton(label: 'Skip', size: 30, onTap: widget.onDone),
              const SizedBox(width: Insets.sm),
            ],
            // The one gold CTA in the view; it carries its own glow.
            GhostButton(
              label: last ? 'Got it' : 'Next',
              size: 30,
              style: GhostStyle.filled,
              onTap: _next,
            ),
          ]),
        ],
      ),
    );
  }
}

class _ScrimPainter extends CustomPainter {
  final Rect? hole;
  final Color scrim;
  final Color ring;
  _ScrimPainter(this.hole, this.scrim, this.ring);

  @override
  void paint(Canvas canvas, Size size) {
    final full = Path()..addRect(Offset.zero & size);
    if (hole == null) {
      canvas.drawPath(full, Paint()..color = scrim);
      return;
    }
    final rr = RRect.fromRectAndRadius(hole!, const Radius.circular(Radii.tile));
    final holePath = Path()..addRRect(rr);
    canvas.drawPath(
      Path.combine(PathOperation.difference, full, holePath),
      Paint()..color = scrim,
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = ring,
    );
  }

  @override
  bool shouldRepaint(_ScrimPainter old) =>
      old.hole != hole || old.scrim != scrim || old.ring != ring;
}

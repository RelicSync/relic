import 'package:flutter/widgets.dart';

import '../theme/relic_theme.dart';
import '../theme/tokens.dart';

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
      const cardH = 148.0;
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
                painter: _ScrimPainter(rect, const Color(0xCC0B0906), c.accent),
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
        boxShadow: const [
          BoxShadow(color: Color(0x99140E04), blurRadius: 40, spreadRadius: -8, offset: Offset(0, 16)),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(step.title,
              style: RelicTheme.sans(size: 14, weight: FontWeight.w600, color: c.text)),
          const SizedBox(height: 6),
          Text(step.body,
              style: RelicTheme.sans(size: 12.5, color: c.textMuted, height: 1.45)),
          const SizedBox(height: 14),
          Row(children: [
            // progress dots
            for (var k = 0; k < widget.steps.length; k++)
              Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: k == _i ? c.accent : c.border,
                  ),
                ),
              ),
            const Spacer(),
            if (!last)
              _link(c, 'Skip', widget.onDone),
            const SizedBox(width: 12),
            _primary(c, last ? 'Got it' : 'Next', _next),
          ]),
        ],
      ),
    );
  }

  Widget _link(RelicColors c, String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Text(label,
              style: RelicTheme.sans(size: 12.5, weight: FontWeight.w500, color: c.textMuted)),
        ),
      );

  Widget _primary(RelicColors c, String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: c.accent,
              borderRadius: BorderRadius.circular(Radii.input),
            ),
            child: Text(label,
                style: RelicTheme.sans(size: 12.5, weight: FontWeight.w600, color: c.onAccent)),
          ),
        ),
      );
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
    final rr = RRect.fromRectAndRadius(hole!, const Radius.circular(10));
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

import 'package:flutter/widgets.dart';

/// The polished gem brand icon (raster `assets/beautiful-icon.png`). This is the
/// app's main mark — used for the tray/window, the promote flourish, and brand
/// logos. The small inline vault-save markers keep [RelicMark] (the flat
/// diamond) since it reads better at tiny sizes.
class RelicIcon extends StatelessWidget {
  final double size;
  const RelicIcon({super.key, this.size = 24});

  @override
  Widget build(BuildContext context) => Image.asset(
        'assets/beautiful-icon.png',
        width: size,
        height: size,
        filterQuality: FilterQuality.medium,
      );
}

/// The Relic gem mark, drawn from the design's SVG path
/// `M5 4 H19 L21.5 9 L12 21 L2.5 9 Z` on a 24×24 viewbox.
class RelicMark extends StatelessWidget {
  final double size;
  final Color color;
  final bool paused;
  final Color? facet; // faint facet line color (defaults to a dark overlay)
  final bool facets; // draw the faint facet lines (off → a clean solid gem)
  final bool filled; // false → outline-only gem (e.g. a "not in vault" state)

  const RelicMark({
    super.key,
    this.size = 24,
    this.color = const Color(0xFFDAA43E),
    this.paused = false,
    this.facet,
    this.facets = true,
    this.filled = true,
  });

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _GemPainter(
            color: color,
            paused: paused,
            facet: facet,
            facets: facets,
            filled: filled),
      );
}

class _GemPainter extends CustomPainter {
  final Color color;
  final bool paused;
  final Color? facet;
  final bool facets;
  final bool filled;
  _GemPainter(
      {required this.color,
      required this.paused,
      this.facet,
      required this.facets,
      required this.filled});

  Path _gem(double s) {
    double x(double v) => v / 24 * s;
    return Path()
      ..moveTo(x(5), x(4))
      ..lineTo(x(19), x(4))
      ..lineTo(x(21.5), x(9))
      ..lineTo(x(12), x(21))
      ..lineTo(x(2.5), x(9))
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    double u(double v) => v / 24 * s;

    if (paused) {
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = u(1.3)
        ..color = color;
      canvas.drawPath(_gem(s), stroke);
      final bar = Paint()..color = color;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(u(9.4), u(9.5), u(1.7), u(5)), Radius.circular(u(0.6))),
        bar,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(u(13), u(9.5), u(1.7), u(5)), Radius.circular(u(0.6))),
        bar,
      );
      return;
    }

    if (!filled) {
      canvas.drawPath(
        _gem(s),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = u(2.2)
          ..strokeJoin = StrokeJoin.round
          ..color = color,
      );
      return;
    }

    canvas.drawPath(_gem(s), Paint()..color = color);

    // faint facets, scaled with size; skip on tiny marks (and when off)
    if (facets && s >= 24) {
      final f = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (u(0.7)).clamp(0.4, 1.2)
        ..color = facet ?? const Color(0x4D16130E);
      void line(double ax, double ay, double bx, double by) =>
          canvas.drawLine(Offset(u(ax), u(ay)), Offset(u(bx), u(by)), f);
      line(2.5, 9, 21.5, 9);
      line(9, 4, 8, 9);
      line(8, 9, 12, 21);
      line(15, 4, 16, 9);
      line(16, 9, 12, 21);
      line(5, 4, 8, 9);
      line(19, 4, 16, 9);
    }
  }

  @override
  bool shouldRepaint(_GemPainter old) =>
      old.color != color ||
      old.paused != paused ||
      old.facet != facet ||
      old.facets != facets ||
      old.filled != filled;
}

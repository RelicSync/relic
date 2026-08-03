import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Short-text glyph: a single squiggly line, vertically centered — reads as a
/// quick note/snippet, distinct from the straight paragraph lines used for
/// longer text.
class ShortTextGlyph extends StatelessWidget {
  final double size;
  final Color color;
  const ShortTextGlyph({super.key, required this.size, required this.color});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _ShortTextPainter(color)),
      );
}

class _ShortTextPainter extends CustomPainter {
  final Color color;
  _ShortTextPainter(this.color);

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final padX = w * 0.13;
    final fullW = w - padX * 2;
    final wavelength = fullW / 2; // two gentle humps across the width
    final amp = h * 0.1;

    _wave(canvas, paint, padX, h / 2, fullW, wavelength, amp); // single, centered
  }

  void _wave(Canvas canvas, Paint paint, double x0, double yc, double length,
      double wavelength, double amp) {
    final path = Path();
    const steps = 40;
    for (var i = 0; i <= steps; i++) {
      final dx = length * (i / steps);
      final x = x0 + dx;
      final y = yc - amp * math.sin(2 * math.pi * dx / wavelength);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ShortTextPainter old) => old.color != color;
}

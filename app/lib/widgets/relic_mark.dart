import 'package:flutter/widgets.dart';

/// The Relic mark: the gold shard from the 2026 design system, transcribed
/// from `logo-mark.svg` (148×150 viewBox) so it can be painted either with the
/// brand gradient or as a flat tint. The old faceted gem — and its raster
/// `assets/beautiful-icon.png` — is retired; there is now one mark at every
/// size.
///
/// The gradient is the one baked into the delivered asset and is not to be
/// restyled: #FFE24A → #FFCE06 → #F2A93B along (30,20) → (130,140).
class _Shard {
  static const double vw = 148;
  static const double vh = 150;

  /// The mark's aspect ratio, for callers that size by height.
  static const double aspect = vw / vh;

  static const gradient = LinearGradient(
    colors: [Color(0xFFFFE24A), Color(0xFFFFCE06), Color(0xFFF2A93B)],
    stops: [0, 0.5, 1],
  );

  /// The outline, in viewBox units.
  static Path path() => Path()
    ..moveTo(27.4388, 140.916)
    ..lineTo(132.709, 140.969)
    ..cubicTo(140.828, 140.973, 146.838, 133.421, 145.013, 125.51)
    ..lineTo(121.339, 22.9363)
    ..cubicTo(120.235, 18.1532, 116.458, 14.4442, 111.656, 13.4276)
    ..lineTo(80.9218, 6.92219)
    ..cubicTo(76.2452, 5.93228, 71.4106, 7.66958, 68.4338, 11.4098)
    ..lineTo(52.6439, 31.2487)
    ..lineTo(20.1246, 72.1069)
    ..lineTo(4.33476, 91.9458)
    ..cubicTo(1.35791, 95.686, 0.749738, 100.787, 2.76379, 105.122)
    ..lineTo(15.9997, 133.613)
    ..cubicTo(18.0679, 138.064, 22.53, 140.913, 27.4388, 140.916)
    ..close();
}

/// The brand mark at its full, gradient-filled self. This is the app's logo —
/// window header, onboarding, the promote flourish, brand lockups.
///
/// [size] is the height; the mark is a touch narrower than it is tall.
class RelicIcon extends StatelessWidget {
  final double size;
  const RelicIcon({super.key, this.size = 24});

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size * _Shard.aspect, size),
        painter: const _ShardPainter(),
      );
}

/// The same mark, flat-tinted, for the places a logo has to behave like an
/// icon: inline "kept in the vault" markers, paused and empty states, a mark
/// sitting on a gold fill. A solid shape is what actually reads at 12px.
class RelicMark extends StatelessWidget {
  final double size;
  final Color color;

  /// Draw the pause bars through the shard (capture paused).
  final bool paused;

  /// False → the outline only, e.g. a "not in the vault" state.
  final bool filled;

  const RelicMark({
    super.key,
    this.size = 24,
    this.color = const Color(0xFFDA9E12),
    this.paused = false,
    this.filled = true,
  });

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size * _Shard.aspect, size),
        painter: _ShardPainter(color: color, paused: paused, filled: filled),
      );
}

class _ShardPainter extends CustomPainter {
  /// Null → fill with the brand gradient.
  final Color? color;
  final bool paused;
  final bool filled;

  const _ShardPainter({this.color, this.paused = false, this.filled = true});

  @override
  void paint(Canvas canvas, Size size) {
    final s = (size.width / _Shard.vw) < (size.height / _Shard.vh)
        ? size.width / _Shard.vw
        : size.height / _Shard.vh;

    final paint = Paint()..isAntiAlias = true;
    if (color == null) {
      paint.shader = _Shard.gradient.createShader(
          Rect.fromPoints(const Offset(30, 20), const Offset(130, 140)));
    } else {
      paint.color = color!;
    }

    canvas.save();
    canvas.translate(
        (size.width - _Shard.vw * s) / 2, (size.height - _Shard.vh * s) / 2);
    canvas.scale(s);

    final path = _Shard.path();

    if (paused) {
      // Bars knocked out of the shard's body, over its visual mass (which
      // sits right of the viewBox centre).
      canvas.saveLayer(const Rect.fromLTWH(0, 0, _Shard.vw, _Shard.vh), Paint());
      canvas.drawPath(path, paint..style = PaintingStyle.fill);
      final knockout = Paint()..blendMode = BlendMode.clear;
      for (final x in const [60.0, 88.0]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(x, 66, 18, 52), const Radius.circular(6)),
          knockout,
        );
      }
      canvas.restore();
    } else if (filled) {
      canvas.drawPath(path, paint..style = PaintingStyle.fill);
    } else {
      canvas.drawPath(
        path,
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = (9 / s).clamp(6.0, 14.0)
          ..strokeJoin = StrokeJoin.round,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_ShardPainter old) =>
      old.color != color || old.paused != paused || old.filled != filled;
}

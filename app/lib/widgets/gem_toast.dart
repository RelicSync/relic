import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'relic_mark.dart';

/// A brief celebratory flourish shown bottom-center of the screen when a relic
/// is promoted to the vault via the hotkey: the gem pops in, jumps, spins, then
/// fades out. Calls [onDone] when finished so the host can hide the window.
class GemToast extends StatefulWidget {
  final VoidCallback onDone;
  const GemToast({super.key, required this.onDone});

  @override
  State<GemToast> createState() => _GemToastState();
}

class _GemToastState extends State<GemToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  );

  @override
  void initState() {
    super.initState();
    _ctl.forward();
    _ctl.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  double _iv(double v, double a, double b) =>
      ((v - a) / (b - a)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 46),
        child: AnimatedBuilder(
          animation: _ctl,
          builder: (_, __) {
            final v = _ctl.value;
            // pop in
            final pop = Curves.easeOutBack.transform(_iv(v, 0, 0.28));
            final scale = 0.6 + 0.4 * pop;
            // rise → hover → drop: ease-out going up (decelerate to the apex),
            // ease-in coming down (accelerate like gravity) — the two exponential
            // curves cross at the apex so the lift peaks there and lands at 0.
            const riseHeight = 17.0;
            final up = Curves.easeOutCubic.transform(_iv(v, 0.0, 0.42));
            final down = Curves.easeInCubic.transform(_iv(v, 0.5, 1.0));
            final jump = (up - down).clamp(0.0, 1.0) * riseHeight;
            // flip on the vertical axis across the rise + drop, eased both ends
            final spin =
                Curves.easeInOutCubic.transform(_iv(v, 0.16, 0.92)) *
                2 *
                math.pi;
            final fadeIn = Curves.easeOut.transform(_iv(v, 0, 0.12));
            final fadeOut = 1 - Curves.easeIn.transform(_iv(v, 0.82, 1.0));
            final opacity = (fadeIn * fadeOut).clamp(0.0, 1.0);
            // Bare gem: no circle, no facet lines (transparent facet), no glow.
            // The spin is around the vertical axis (a coin-flip) via a 3D
            // rotateY with a touch of perspective.
            return Opacity(
              opacity: opacity,
              child: Transform.translate(
                offset: Offset(0, -jump),
                child: Transform.scale(
                  scale: scale,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.0018)
                      ..rotateY(spin),
                    child: const RelicIcon(size: 44),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// One-shot generator for assets/tray_icon_template.png — the macOS menu-bar
/// mark. Run from app/:
///
///   dart run tool/make_tray_template.dart
///
/// A macOS template image is monochrome plus alpha: the menu bar throws the
/// colour away and re-tints the shape for the light and dark bars, so this
/// draws the 2026 shard as a bare silhouette in pure black and lets the alpha
/// carry the form. No tile behind it — the menu bar is a surface the app does
/// not control, and a cream tile would sit on it as a visible chip.
///
/// The geometry is the same path `tool/make_app_icon.py` renders (and the same
/// one `lib/widgets/relic_mark.dart` paints, and the one baked into
/// logo-mark.svg). Keep the two in step: if the mark moves, it moves in both.

// --- the mark, in its 148x150 viewBox ---------------------------------------

const Pt start = Pt(27.4388, 140.916);

/// 'L' is a line to a point; 'C' is a cubic with two controls and an end
/// point. Transcribed from logo-mark.svg, identical to make_app_icon.py.
const List<Seg> segments = [
  Seg.line(Pt(132.709, 140.969)),
  Seg.cubic(Pt(140.828, 140.973), Pt(146.838, 133.421), Pt(145.013, 125.51)),
  Seg.line(Pt(121.339, 22.9363)),
  Seg.cubic(Pt(120.235, 18.1532), Pt(116.458, 14.4442), Pt(111.656, 13.4276)),
  Seg.line(Pt(80.9218, 6.92219)),
  Seg.cubic(Pt(76.2452, 5.93228), Pt(71.4106, 7.66958), Pt(68.4338, 11.4098)),
  Seg.line(Pt(52.6439, 31.2487)),
  Seg.line(Pt(20.1246, 72.1069)),
  Seg.line(Pt(4.33476, 91.9458)),
  Seg.cubic(Pt(1.35791, 95.686), Pt(0.749738, 100.787), Pt(2.76379, 105.122)),
  Seg.line(Pt(15.9997, 133.613)),
  Seg.cubic(Pt(18.0679, 138.064), Pt(22.53, 140.913), Pt(27.4388, 140.916)),
];

/// 44px = the 22pt menu-bar slot at @2x, and what the asset has always been.
/// tray_manager hands the PNG to NSImage at 18pt square, so this is comfortably
/// above the pixels the bar actually asks for. Don't change it without changing
/// what `lib/desktop.dart` loads.
const int canvas = 44;

/// Inset of the drawn shard inside the canvas, in canvas pixels per side. The
/// silhouette is fitted to its own bounding box rather than the viewBox, so the
/// glyph reads as large as the bar allows with a hair of breathing room —
/// roughly 16pt of art in the 18pt square, which is what Apple's own menu-bar
/// glyphs use.
const double inset = 2.0;

/// Cubic flattening resolution. Matches make_app_icon.py's default so both
/// tools walk the curves the same way.
const int curveSteps = 48;

/// Sub-scanlines per output row. The fill accumulates exact horizontal span
/// coverage, so this only sets the vertical resolution of the antialiasing;
/// 16 puts the alpha ramp well past what 8 bits can record.
const int subRows = 16;

class Pt {
  const Pt(this.x, this.y);
  final double x;
  final double y;
}

class Seg {
  const Seg.line(this.end)
      : c1 = null,
        c2 = null;
  const Seg.cubic(Pt this.c1, Pt this.c2, this.end);
  final Pt? c1;
  final Pt? c2;
  final Pt end;
}

/// The outline as a polygon, cubics flattened to line segments.
List<Pt> flatten() {
  final pts = <Pt>[start];
  var cur = start;
  for (final seg in segments) {
    final c1 = seg.c1, c2 = seg.c2;
    if (c1 == null || c2 == null) {
      cur = seg.end;
      pts.add(cur);
      continue;
    }
    final p0 = cur, p3 = seg.end;
    for (var i = 1; i <= curveSteps; i++) {
      final t = i / curveSteps, u = 1 - t;
      pts.add(Pt(
        u * u * u * p0.x + 3 * u * u * t * c1.x
            + 3 * u * t * t * c2.x + t * t * t * p3.x,
        u * u * u * p0.y + 3 * u * u * t * c1.y
            + 3 * u * t * t * c2.y + t * t * t * p3.y,
      ));
    }
    cur = p3;
  }
  return pts;
}

/// The polygon mapped into the canvas: scaled to fit `inset` from every edge,
/// aspect preserved, and centred on what it actually covers.
List<Pt> placed() {
  final pts = flatten();
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final p in pts) {
    minX = math.min(minX, p.x);
    minY = math.min(minY, p.y);
    maxX = math.max(maxX, p.x);
    maxY = math.max(maxY, p.y);
  }
  final box = canvas - 2 * inset;
  final scale = math.min(box / (maxX - minX), box / (maxY - minY));
  final dx = (canvas - (maxX - minX) * scale) / 2 - minX * scale;
  final dy = (canvas - (maxY - minY) * scale) / 2 - minY * scale;
  return [for (final p in pts) Pt(p.x * scale + dx, p.y * scale + dy)];
}

/// Add `weight` of coverage to the part of row `base` the span [a, b) covers,
/// counting partial pixels at both ends.
void _span(List<double> cov, int base, double a, double b, double weight) {
  var lo = math.max(a, 0.0), hi = math.min(b, canvas.toDouble());
  if (hi <= lo) return;
  for (var x = lo.floor(); x < hi.ceil(); x++) {
    final l = math.max(lo, x.toDouble()), r = math.min(hi, x + 1.0);
    if (r > l) cov[base + x] += (r - l) * weight;
  }
}

/// Per-pixel coverage of the placed polygon, 0..1, by even-odd scanline fill.
List<double> coverage() {
  final poly = placed();
  final cov = List<double>.filled(canvas * canvas, 0.0);
  final xs = <double>[];
  for (var py = 0; py < canvas; py++) {
    for (var s = 0; s < subRows; s++) {
      final y = py + (s + 0.5) / subRows;
      xs.clear();
      for (var i = 0; i < poly.length; i++) {
        final p = poly[i], q = poly[(i + 1) % poly.length];
        if ((p.y <= y && q.y > y) || (q.y <= y && p.y > y)) {
          xs.add(p.x + (y - p.y) / (q.y - p.y) * (q.x - p.x));
        }
      }
      xs.sort();
      for (var i = 0; i + 1 < xs.length; i += 2) {
        _span(cov, py * canvas, xs[i], xs[i + 1], 1 / subRows);
      }
    }
  }
  return cov;
}

void main() {
  final cov = coverage();
  final out = img.Image(width: canvas, height: canvas, numChannels: 4);
  for (var y = 0; y < canvas; y++) {
    for (var x = 0; x < canvas; x++) {
      final a = (cov[y * canvas + x] * 255).round().clamp(0, 255);
      out.setPixelRgba(x, y, 0, 0, 0, a);
    }
  }
  File('assets/tray_icon_template.png').writeAsBytesSync(img.encodePng(out));
  stdout.writeln('wrote assets/tray_icon_template.png '
      '(${canvas}x$canvas template, bare shard, black + alpha)');
}

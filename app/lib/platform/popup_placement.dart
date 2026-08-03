import 'dart:ui';

/// Place a [size] rect near [anchor] (logical screen px): default
/// below-and-right of the anchor, flip left near the right edge and up near the
/// bottom edge, then clamp to the work area (`origin` + `area`). Returns the
/// rect plus whether it opened downward (top-anchored) — the mini picker keeps
/// that edge fixed so a later re-hug grows away from the cursor.
///
/// Pure and platform-free so it can be unit-tested without a window manager.
(Rect, bool) placePopupNear(
    Offset anchor, Size size, Offset origin, Size area, double gap) {
  final maxX = origin.dx + area.width - size.width;
  final maxY = origin.dy + area.height - size.height;
  var x = anchor.dx + gap;
  var y = anchor.dy + gap;
  var down = true;
  if (x > maxX) x = anchor.dx - size.width - gap; // flip left near right edge
  if (y > maxY) {
    y = anchor.dy - size.height - gap; // flip up near bottom edge
    down = false;
  }
  x = x.clamp(origin.dx, maxX < origin.dx ? origin.dx : maxX);
  y = y.clamp(origin.dy, maxY < origin.dy ? origin.dy : maxY);
  return (Rect.fromLTWH(x, y, size.width, size.height), down);
}

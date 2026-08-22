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

/// The work area (origin, size) of whichever display contains [point], or null
/// when none does — callers fall back to the primary display.
///
/// [displays] is the platform's display list already reduced to work areas, so
/// this stays free of any windowing dependency and the multi-monitor decision
/// — the part with real edge cases — is testable without a second screen.
/// Displays left of or above the primary have negative origins, which is why
/// nothing here assumes the desktop starts at 0,0.
///
/// A point on the seam between two displays belongs to the one on the right or
/// below, because [Rect.contains] is inclusive of left/top and exclusive of
/// right/bottom. That matches where the OS puts the cursor at the same spot.
(Offset, Size)? workAreaContaining(
    Offset point, List<(Offset, Size)> displays) {
  for (final (origin, size) in displays) {
    if (Rect.fromLTWH(origin.dx, origin.dy, size.width, size.height)
        .contains(point)) {
      return (origin, size);
    }
  }
  return null;
}

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/platform/popup_placement.dart';

void main() {
  // A single 1920x1080 monitor whose work area starts at the origin.
  const origin = Offset.zero;
  const area = Size(1920, 1080);
  const size = Size(340, 300);
  const gap = 8.0;

  test('opens below-and-right when there is room', () {
    final (rect, down) = placePopupNear(const Offset(400, 300), size, origin, area, gap);
    expect(down, isTrue);
    expect(rect.left, 408); // 400 + gap
    expect(rect.top, 308); // 300 + gap
    expect(rect.width, 340);
    expect(rect.height, 300);
  });

  test('flips left near the right edge', () {
    final (rect, down) = placePopupNear(const Offset(1900, 300), size, origin, area, gap);
    expect(down, isTrue); // no vertical flip here
    expect(rect.left, 1552); // 1900 - 340 - gap
    expect(rect.right <= area.width, isTrue);
  });

  test('flips up near the bottom edge', () {
    final (rect, down) = placePopupNear(const Offset(400, 1060), size, origin, area, gap);
    expect(down, isFalse);
    expect(rect.top, 752); // 1060 - 300 - gap
    expect(rect.bottom <= area.height, isTrue);
  });

  test('stays fully within the work area in a corner', () {
    final (rect, _) = placePopupNear(const Offset(1915, 1075), size, origin, area, gap);
    expect(rect.left >= origin.dx, isTrue);
    expect(rect.top >= origin.dy, isTrue);
    expect(rect.right <= area.width, isTrue);
    expect(rect.bottom <= area.height, isTrue);
  });

  test('respects a non-zero monitor origin (second monitor)', () {
    const origin2 = Offset(1920, 0);
    final (rect, _) = placePopupNear(const Offset(2000, 100), size, origin2, area, gap);
    expect(rect.left, 2008); // 2000 + gap
    expect(rect.left >= origin2.dx, isTrue);
    expect(rect.right <= origin2.dx + area.width, isTrue);
  });

  // Which monitor the popup belongs to. Pinned here rather than on hardware
  // because no QA environment we have can present a second display: VirtualBox
  // will not connect a second head without its X11 guest additions, an
  // xrandr --setmonitor split is invisible to GDK, and Xephyr's +xinerama
  // collapses its screens into one 1280x800 monitor.
  group('workAreaContaining', () {
    // Laptop at the origin, external screen to its LEFT — the layout that
    // breaks anything assuming the desktop starts at 0,0.
    const left = (Offset(-1920, 0), Size(1920, 1080));
    const laptop = (Offset.zero, Size(1440, 900));
    const displays = [left, laptop];

    test('picks the display the point is on', () {
      expect(workAreaContaining(const Offset(700, 400), displays), laptop);
      expect(workAreaContaining(const Offset(-900, 400), displays), left);
    });

    test('a negative-origin display is not treated as absent', () {
      // The bug this guards: clamping to the primary would drag the popup
      // across the seam onto the wrong screen.
      final hit = workAreaContaining(const Offset(-10, 10), displays);
      expect(hit, isNotNull);
      expect(hit!.$1.dx, -1920);
    });

    test('the seam belongs to the right-hand display, like the cursor does', () {
      expect(workAreaContaining(const Offset(0, 400), displays), laptop);
      expect(workAreaContaining(const Offset(-1, 400), displays), left);
    });

    test('a point on no display is null, so the caller falls back', () {
      // Real case: a work area shrunk by a dock, with the cursor over the dock.
      expect(workAreaContaining(const Offset(5000, 400), displays), isNull);
      expect(workAreaContaining(const Offset(700, 950), displays), isNull);
    });

    test('no displays at all is null, not a crash', () {
      expect(workAreaContaining(Offset.zero, const []), isNull);
    });

    test('placement then uses that display, not the whole desktop', () {
      final hit = workAreaContaining(const Offset(-100, 400), displays)!;
      final (rect, _) =
          placePopupNear(const Offset(-100, 400), size, hit.$1, hit.$2, gap);
      expect(rect.right <= 0, isTrue, reason: 'must not spill onto the laptop');
      expect(rect.left >= -1920, isTrue);
    });
  });
}

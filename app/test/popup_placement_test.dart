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
}

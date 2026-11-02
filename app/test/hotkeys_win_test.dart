import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/platform/src/windows/hotkeys_win.dart';

void main() {
  test('HID usages map to the virtual keys RegisterHotKey expects', () {
    expect(winVirtualKey(0x0007001E), 0x31); // 1
    expect(winVirtualKey(0x0007001F), 0x32); // 2
    expect(winVirtualKey(0x00070026), 0x39); // 9
    expect(winVirtualKey(0x00070027), 0x30); // 0
    expect(winVirtualKey(0x00070014), 0x51); // Q
    expect(winVirtualKey(0x0007002C), 0x20); // Space
    expect(winVirtualKey(0x0007003A), 0x70); // F1
    expect(winVirtualKey(0x00070045), 0x7B); // F12
  });

  test('keys we cannot name are trusted, not flagged', () {
    expect(winVirtualKey(0x00070036), isNull); // comma
    expect(winVirtualKey(0x000C00E9), isNull); // consumer page
  });
}

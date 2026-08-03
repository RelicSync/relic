import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/hotkeys.dart';

void main() {
  test('quick-paste defaults are Ctrl+Shift+1..5', () {
    final qp = HotkeyBinding.defaultQuickPaste;
    expect(qp.length, 5);
    // HID usage page 0x07: '1'=0x1E … '5'=0x22.
    const usages = [0x0007001E, 0x0007001F, 0x00070020, 0x00070021, 0x00070022];
    for (var i = 0; i < qp.length; i++) {
      final b = qp[i];
      expect(b.ctrl, isTrue);
      expect(b.shift, isTrue);
      expect(b.alt, isFalse);
      expect(b.win, isFalse);
      expect(b.label, '${i + 1}');
      expect(b.usbUsage, usages[i]);
      expect(b.display, 'Ctrl + Shift + ${i + 1}');
    }
  });

  test('mini picker default is Ctrl+Shift+Space', () {
    final m = HotkeyBinding.defaultMini;
    expect(m.ctrl, isTrue);
    expect(m.shift, isTrue);
    expect(m.alt, isFalse);
    expect(m.win, isFalse);
    expect(m.usbUsage, 0x0007002C); // Spacebar
    expect(m.display, 'Ctrl + Shift + Space');
  });

  test('all default chords are distinct (incl. quick-paste)', () {
    final chords = [
      HotkeyBinding.defaultHistory,
      HotkeyBinding.defaultCapture,
      HotkeyBinding.defaultPromote,
      HotkeyBinding.defaultMini,
      ...HotkeyBinding.defaultQuickPaste,
    ];
    for (var i = 0; i < chords.length; i++) {
      for (var j = i + 1; j < chords.length; j++) {
        expect(chords[i].sameChordAs(chords[j]), isFalse,
            reason: 'default hotkeys $i and $j collide');
      }
    }
  });

  test('a quick-paste binding round-trips through JSON', () {
    final orig = HotkeyBinding.defaultQuickPaste[2]; // Ctrl+Shift+3
    final back = HotkeyBinding.fromJson(orig.toJson());
    expect(back, isNotNull);
    expect(back!.sameChordAs(orig), isTrue);
    expect(back.label, '3');
  });
}

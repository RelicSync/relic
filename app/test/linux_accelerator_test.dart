import 'package:flutter_test/flutter_test.dart';

import 'package:relic_app/data/hotkeys.dart';
import 'package:relic_app/platform/foreground_app.dart';
import 'package:relic_app/platform/global_hotkeys.dart';

/// The Linux accelerator mapping is pure, so the bug that shipped in
/// hotkey_manager_linux — the spacebar registering as the KEYPAD space, which
/// silently broke Relic's main summon chord — is pinned from any host.
///
/// Note what these tests cannot reach: whether the grabbed chord is actually
/// *delivered*. keybinder-3.0 passed every assertion here and still dispatched
/// only the summon chord, because it dropped GDK's consumed modifiers before
/// matching and so lost the Shift out of every Shift+printable chord. That is
/// why hotkeys.cc grabs and matches on raw keycode+state itself, and why the
/// Linux hotkey QA step in docs/linux-port.md presses all nine on hardware.
void main() {
  group('linuxAccelerator', () {
    test('the spacebar is space, never KP_Space', () {
      final a = linuxAccelerator(
          ctrl: true, alt: false, shift: true, meta: false, usbUsage: 0x0007002C);
      expect(a, '<Control><Shift>space');
      expect(a, isNot(contains('KP_')));
    });

    test('every default Relic chord maps', () {
      for (final b in [
        HotkeyBinding.defaultHistory,
        HotkeyBinding.defaultCapture,
        HotkeyBinding.defaultPromote,
        HotkeyBinding.defaultMini,
        ...HotkeyBinding.defaultQuickPaste,
      ]) {
        final a = linuxAccelerator(
            ctrl: b.ctrl,
            alt: b.alt,
            shift: b.shift,
            meta: b.win,
            usbUsage: b.usbUsage);
        expect(a, isNotNull, reason: b.display);
        expect(a, startsWith('<Control><Shift>'), reason: b.display);
      }
    });

    test('modifier order is fixed and names real modifiers', () {
      expect(
        linuxAccelerator(
            ctrl: true, alt: true, shift: true, meta: true, usbUsage: 0x00070004),
        '<Control><Alt><Shift><Super>a',
      );
      // The accelerator is the map key in hotkeys.cc, so <Primary> and
      // <Control> must never both be spellable for the same chord.
      expect(
        linuxAccelerator(
            ctrl: true, alt: false, shift: false, meta: false, usbUsage: 0x00070014),
        isNot(contains('Primary')),
      );
    });

    test('digits and function keys land on their own names', () {
      expect(
          linuxAccelerator(
              ctrl: true, alt: false, shift: true, meta: false, usbUsage: 0x0007001E),
          '<Control><Shift>1');
      expect(
          linuxAccelerator(
              ctrl: false, alt: false, shift: false, meta: false, usbUsage: 0x00070045),
          'F12');
    });

    test('an unknown usage is null, not a guess', () {
      expect(
          linuxAccelerator(
              ctrl: true, alt: false, shift: false, meta: false, usbUsage: 0x00070065),
          isNull);
    });
  });

  group('waylandSessionFrom', () {
    test('unset or empty is X11, any value is Wayland', () {
      expect(waylandSessionFrom(null), isFalse);
      expect(waylandSessionFrom(''), isFalse);
      expect(waylandSessionFrom('wayland-0'), isTrue);
    });
  });
}

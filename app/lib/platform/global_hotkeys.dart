/// Turning Relic's platform-neutral hotkey bindings into the GTK accelerator
/// strings the Linux bridge grabs (linux/runner/hotkeys.cc).
///
/// Kept pure and separate from the channel code so the whole mapping tests
/// from any host (prior art: macAppKey, linuxAppKey). Relic stores chords as
/// USB HID usages — the same currency on every platform — and only Linux needs
/// them spelled as keysym names.
library;

/// USB HID usage → X keysym name, for the keys a chord may legitimately use.
/// Deliberately explicit: deriving these arithmetically is what produced
/// `KP_Space` for the spacebar in hotkey_manager_linux.
const Map<int, String> _keysymNames = {
  0x0007002C: 'space',
  0x00070028: 'Return',
  0x00070029: 'Escape',
  0x0007002B: 'Tab',
  // letters a..z are 0x04..0x1D
  0x00070004: 'a', 0x00070005: 'b', 0x00070006: 'c', 0x00070007: 'd',
  0x00070008: 'e', 0x00070009: 'f', 0x0007000A: 'g', 0x0007000B: 'h',
  0x0007000C: 'i', 0x0007000D: 'j', 0x0007000E: 'k', 0x0007000F: 'l',
  0x00070010: 'm', 0x00070011: 'n', 0x00070012: 'o', 0x00070013: 'p',
  0x00070014: 'q', 0x00070015: 'r', 0x00070016: 's', 0x00070017: 't',
  0x00070018: 'u', 0x00070019: 'v', 0x0007001A: 'w', 0x0007001B: 'x',
  0x0007001C: 'y', 0x0007001D: 'z',
  // digits: HID puts 1..9 at 0x1E..0x26 and 0 at 0x27
  0x0007001E: '1', 0x0007001F: '2', 0x00070020: '3', 0x00070021: '4',
  0x00070022: '5', 0x00070023: '6', 0x00070024: '7', 0x00070025: '8',
  0x00070026: '9', 0x00070027: '0',
  // function keys F1..F12 are 0x3A..0x45
  0x0007003A: 'F1', 0x0007003B: 'F2', 0x0007003C: 'F3', 0x0007003D: 'F4',
  0x0007003E: 'F5', 0x0007003F: 'F6', 0x00070040: 'F7', 0x00070041: 'F8',
  0x00070042: 'F9', 0x00070043: 'F10', 0x00070044: 'F11', 0x00070045: 'F12',
  // arrows
  0x0007004F: 'Right', 0x00070050: 'Left', 0x00070051: 'Down',
  0x00070052: 'Up',
};

/// The GTK accelerator for a chord, or null when the key has no keysym we are
/// willing to name (the caller then reports it as unregisterable rather than
/// binding something surprising).
///
/// Modifier order is fixed so the string is stable across runs (it is the map
/// key on the C++ side), and it names real modifiers — `<Control>`/`<Super>`
/// rather than the `<Primary>` alias, which reads as Command to anyone coming
/// from the macOS binding and is one indirection away from what X reports.
String? linuxAccelerator({
  required bool ctrl,
  required bool alt,
  required bool shift,
  required bool meta,
  required int usbUsage,
}) {
  final key = _keysymNames[usbUsage];
  if (key == null) return null;
  final b = StringBuffer();
  if (ctrl) b.write('<Control>');
  if (alt) b.write('<Alt>');
  if (shift) b.write('<Shift>');
  if (meta) b.write('<Super>');
  b.write(key);
  return b.toString();
}

import 'dart:io';

import 'package:win32/win32.dart';

/// Whether another program already owns a global chord on Windows.
///
/// hotkey_manager_windows throws away RegisterHotKey's result and reports
/// success every time, so a chord another app took first (on 2026-11-02 that
/// was Ctrl+Shift+1 and 2 on Jordan's box) just never fired, and Settings
/// never said why. This asks Windows directly: claim the chord on this thread,
/// and if that works, hand it straight back so the plugin can take it.
///
/// Call it after hotkeyManager.unregisterAll(), or our own earlier claim reads
/// as someone else's. Returns false when the key is not one we can name as a
/// virtual-key code, so an odd custom binding is trusted rather than flagged.
bool winChordTaken({
  required bool ctrl,
  required bool alt,
  required bool shift,
  required bool meta,
  required int usbUsage,
}) {
  if (!Platform.isWindows) return false;
  final vk = winVirtualKey(usbUsage);
  if (vk == null) return false;
  final mods = (ctrl ? MOD_CONTROL : 0) |
      (alt ? MOD_ALT : 0) |
      (shift ? MOD_SHIFT : 0) |
      (meta ? MOD_WIN : 0);
  // Any id works for a thread-level claim that lives a few microseconds.
  const probeId = 0xB7E1;
  try {
    if (RegisterHotKey(NULL, probeId, mods | MOD_NOREPEAT, vk) != 0) {
      UnregisterHotKey(NULL, probeId);
      return false;
    }
    return GetLastError() == ERROR_HOTKEY_ALREADY_REGISTERED;
  } catch (_) {
    return false;
  }
}

/// USB HID usage to Windows virtual-key code, for the keys a chord may use.
/// Null for anything else.
int? winVirtualKey(int usbUsage) {
  final u = usbUsage & 0xFFFF;
  if (usbUsage >> 16 != 0x07) return null;
  // letters a..z are 0x04..0x1D, and VK_A..VK_Z are their capitals
  if (u >= 0x04 && u <= 0x1D) return 0x41 + (u - 0x04);
  // HID puts 1..9 at 0x1E..0x26 and 0 at 0x27; VK_0..VK_9 are '0'..'9'
  if (u >= 0x1E && u <= 0x26) return 0x31 + (u - 0x1E);
  if (u == 0x27) return 0x30;
  // F1..F12 are 0x3A..0x45
  if (u >= 0x3A && u <= 0x45) return VK_F1 + (u - 0x3A);
  return switch (u) {
    0x2C => VK_SPACE,
    0x28 => VK_RETURN,
    0x29 => VK_ESCAPE,
    0x2B => VK_TAB,
    0x4F => VK_RIGHT,
    0x50 => VK_LEFT,
    0x51 => VK_DOWN,
    0x52 => VK_UP,
    _ => null,
  };
}

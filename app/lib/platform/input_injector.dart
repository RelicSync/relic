import 'dart:io' show Platform;

import 'src/macos/input_macos.dart' as mac;
import 'src/windows/input_win.dart' as win;

/// Synthetic keystrokes into the frontmost application: paste-on-select and
/// the chord-safe copy behind the save & annotate hotkey. Windows uses
/// SendInput; macOS posts CGEvents via the `relic/input` channel (which needs
/// the Accessibility grant — see [accessibilityTrusted]). Elsewhere these are
/// silent no-ops, matching the old Windows-only behavior.

/// Synthesize the platform paste chord (Ctrl+V / ⌘V) into the frontmost app.
/// Our window has already hidden, so the keystroke lands in whatever app the
/// user was in. Best-effort; failures are silent.
Future<void> sendPaste() async {
  if (Platform.isWindows) {
    win.sendPaste();
  } else if (Platform.isMacOS) {
    await mac.sendPaste();
  }
}

/// Synthesize the platform paste chord (Ctrl+V / ⌘V), safely from inside a
/// global-hotkey handler — the "paste latest" hotkey fires while the chord's
/// modifiers are still physically held, so this waits for (or force-releases)
/// them before injecting, or the paste would land as a modified chord.
/// Best-effort; the macOS path is not yet chord-safe (falls back to plain
/// [sendPaste] until the Swift bridge grows a paste-safe method).
Future<void> sendPasteChordSafe() async {
  if (Platform.isWindows) {
    await win.sendPasteChordSafe();
  } else if (Platform.isMacOS) {
    await mac.sendPaste();
  }
}

/// Synthesize the platform copy chord (Ctrl+C / ⌘C), safely from inside a
/// global-hotkey handler: the user is still physically holding the chord's
/// modifiers, so the implementation waits for (or force-releases) them before
/// injecting, or the copy would land as a dead chord. Best-effort.
Future<void> sendCopyChordSafe() async {
  if (Platform.isWindows) {
    await win.sendCopyChordSafe();
  } else if (Platform.isMacOS) {
    await mac.sendCopyChordSafe();
  }
}

/// Whether synthetic input can work at all right now. Always true on Windows;
/// on macOS this is the Accessibility (TCC) grant — pass [prompt] to surface
/// the system dialog once. False elsewhere.
Future<bool> inputInjectionAvailable({bool prompt = false}) async {
  if (Platform.isWindows) return true;
  if (Platform.isMacOS) return mac.accessibilityTrusted(prompt: prompt);
  return false;
}

/// macOS only: open System Settings → Privacy & Security → Accessibility so
/// the user can grant injection. No-op elsewhere.
Future<void> openInputPermissionSettings() async {
  if (Platform.isMacOS) await mac.openAccessibilitySettings();
}

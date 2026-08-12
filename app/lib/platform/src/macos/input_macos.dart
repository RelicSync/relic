import 'package:flutter/services.dart';

/// macOS backend of platform/input_injector.dart: a thin client over the
/// `relic/input` MethodChannel implemented by
/// macos/Runner/Bridge/InputBridge.swift (CGEvent synthesis). Injection needs
/// the Accessibility (TCC) grant; [accessibilityTrusted] is the gate the UI
/// checks before promising paste-on-select / selection capture.

const _ch = MethodChannel('relic/input');

/// Whether this process holds the Accessibility grant CGEvent posting needs.
/// [prompt] additionally asks macOS to show the system grant dialog once.
Future<bool> accessibilityTrusted({bool prompt = false}) async {
  try {
    return await _ch.invokeMethod<bool>('accessibilityTrusted', {
          'prompt': prompt,
        }) ??
        false;
  } catch (_) {
    return false;
  }
}

/// Open System Settings → Privacy & Security → Accessibility.
Future<void> openAccessibilitySettings() async {
  try {
    await _ch.invokeMethod<void>('openAccessibilitySettings');
  } catch (_) {}
}

/// Synthesize ⌘V into the frontmost application. Best-effort; silently does
/// nothing without the Accessibility grant.
///
/// Awaiting this waits for the keystroke to be posted, not consumed: the Swift
/// side holds the reply while it waits for us to stop being the frontmost app
/// (the popup has only just ordered out).
Future<void> sendPaste() async {
  try {
    await _ch.invokeMethod<void>('sendPaste');
  } catch (_) {}
}

/// Synthesize ⌘V into the frontmost application, chord-safely: the Swift side
/// waits for the hotkey's physical modifiers to clear before posting, so the
/// quick-paste chord doesn't land as ⌃⇧⌘V.
Future<void> sendPasteChordSafe() async {
  try {
    await _ch.invokeMethod<void>('sendPasteChordSafe');
  } catch (_) {}
}

/// Synthesize ⌘C into the frontmost application, chord-safely: the Swift side
/// waits for the hotkey's physical modifiers to clear before posting ⌘C,
/// mirroring the Windows SendInput ordering.
Future<void> sendCopyChordSafe() async {
  try {
    await _ch.invokeMethod<void>('sendCopyChordSafe');
  } catch (_) {}
}

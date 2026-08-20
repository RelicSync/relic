import 'package:flutter/services.dart';

/// Claiming the keyboard on X11, over our own bridge (linux/runner/
/// window_focus.cc — change the two together).
///
/// window_manager's show()+focus() raises the window but does not carry a
/// timestamp the window manager can attribute to the user, so mutter treats
/// the request as focus stealing: it raises the picker and sets
/// _NET_WM_STATE_DEMANDS_ATTENTION while the keyboard stays with the app
/// behind it. The bridge re-asks using the summoning hotkey's own X timestamp.
const _ch = MethodChannel('relic/window_focus');

/// Best-effort: false when the bridge is absent (Wayland, or a build without
/// it), and the caller keeps whatever window_manager achieved on its own.
Future<bool> claimKeyboardFocus() async {
  try {
    return await _ch.invokeMethod<bool>('claimFocus') ?? false;
  } catch (_) {
    return false;
  }
}

import 'dart:io' show Platform;

import 'src/macos/activation_macos.dart' as mac;

/// Bring the app process to the foreground ahead of window_manager's
/// show()/focus(). On Windows those calls already take the foreground, so this
/// is a no-op. On macOS an LSUIElement agent is refused activation unless it
/// asks forcefully (NSApp.activate ignoringOtherApps) — without this the
/// window reorders but the previous app (e.g. the OAuth browser) keeps focus.
Future<void> activateApp() async {
  if (Platform.isMacOS) await mac.activateApp();
}

/// Show the window natively, returning false when the caller should fall back
/// to window_manager's show()+focus().
///
/// macOS only, and it exists because window_manager cannot express the popup:
/// its show() always calls NSApp.activate(ignoringOtherApps: true), so every
/// summon would steal the foreground from the app the user is typing in. With
/// [activate] false the window is ordered front and made key WITHOUT activating
/// the app (it is an NSPanel — see macos/Runner/MainFlutterWindow.swift); with
/// [activate] true it comes forward like a normal app window, which is what
/// settings and onboarding want.
Future<bool> presentWindow({required bool activate}) async {
  if (!Platform.isMacOS) return false;
  return mac.presentWindow(activate: activate);
}

/// Hide the window natively, returning false when the caller should fall back
/// to window_manager's hide(). macOS only: on top of ordering the window out it
/// hands the foreground back to the previous app when Relic holds it (an agent
/// with no windows left otherwise stays active over a dead-looking desktop).
Future<bool> dismissWindow() async {
  if (!Platform.isMacOS) return false;
  return mac.dismissWindow();
}

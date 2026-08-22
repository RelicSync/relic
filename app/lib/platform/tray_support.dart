import 'dart:io' show Platform;

import 'src/linux/desktop_env_linux.dart' as lin;

/// Whether the desktop will actually SHOW a tray icon.
///
/// Windows and macOS always will, so this only ever has something to say on
/// Linux, where the answer is a real question: tray_manager publishes a
/// StatusNotifierItem over D-Bus and stock GNOME has no watcher to receive it,
/// so the icon goes nowhere while every call reports success. Relic's
/// quit-to-tray story assumes there is a tray to quit to; when there isn't, the
/// hotkey is the only way back and the user has to be told that instead.
///
/// Answers only what the user is TOLD — the icon is always attempted, so a
/// wrong "no" costs a sentence of copy, never the tray itself.
Future<bool> systemTrayAvailable() async {
  if (Platform.isLinux) return lin.hasTrayHost();
  return true;
}

/// The tray-hint copy for the first time the window disappears: without it a
/// new user who clicks away has no idea how to get Relic back.
///
/// Pure so every branch is testable from any host. [hotkey] is the display form
/// of the summon chord; [trayPresent] is [systemTrayAvailable].
String trayHintBody({
  required String hotkey,
  required bool isMacOS,
  required bool isLinux,
  required bool trayPresent,
}) {
  final press = 'Press $hotkey to open it anytime.';
  if (isLinux && !trayPresent) {
    // Naming the desktop's choice rather than Relic's: the user is about to go
    // looking for an icon that was never going to appear, and "your desktop
    // doesn't show tray icons" is the fact that saves them the hunt.
    return 'Your desktop does not show tray icons, so $hotkey is the way '
        'back to it.';
  }
  return 'It lives in your ${isMacOS ? 'menu bar' : 'tray'}. $press';
}

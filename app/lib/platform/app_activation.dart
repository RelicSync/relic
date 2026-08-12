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

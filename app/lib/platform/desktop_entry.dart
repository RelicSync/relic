import 'dart:io' show Platform;

import 'src/linux/desktop_entry_linux.dart' as lin;

/// Making the app known to the desktop shell.
///
/// Windows gets this from the installer (relic.iss writes the Start-menu
/// shortcut and the `relic` URL-scheme key) and macOS gets it from the .app
/// bundle's Info.plist. Linux ships as a tarball with no install step at all,
/// so Relic registers itself: a launcher entry with its icon, and the
/// `relic://` scheme handler the website's "Open Relic" button needs.
///
/// No-op everywhere else.
Future<bool> ensureDesktopEntry() async {
  if (Platform.isLinux) return lin.ensureRegistered();
  return true;
}

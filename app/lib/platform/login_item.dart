import 'dart:io' show Platform;

import 'src/linux/login_item_linux.dart' as lin;
import 'src/macos/login_item_macos.dart' as mac;
import 'src/windows/input_win.dart' as win;

/// Run-at-login registration: the HKCU Run key on Windows, SMAppService on
/// macOS, an XDG autostart desktop entry on Linux
/// (`~/.config/autostart/space.relic.app.desktop`). No-ops (false) elsewhere.

/// Enable or disable launching Relic when the user signs in. Returns whether
/// the change stuck.
Future<bool> setLaunchAtStartup(bool enable) async {
  if (Platform.isWindows) return win.setLaunchAtStartup(enable);
  if (Platform.isMacOS) return mac.setEnabled(enable);
  if (Platform.isLinux) return lin.setEnabled(enable);
  return false;
}

/// Whether the run-at-login registration is currently present.
Future<bool> isLaunchAtStartupEnabled() async {
  if (Platform.isWindows) return win.isLaunchAtStartupEnabled();
  if (Platform.isMacOS) return mac.isEnabled();
  if (Platform.isLinux) return lin.isEnabled();
  return false;
}

/// The exe path the run-at-login entry currently points at (Windows Run key or
/// the Linux desktop entry's `Exec=`, quotes stripped), or null when absent.
/// macOS's SMAppService registers by bundle id, so there is no path to steal
/// there — callers fall back to the presence check.
Future<String?> launchAtStartupTarget() async {
  if (Platform.isWindows) return win.launchAtStartupCommand();
  if (Platform.isLinux) return lin.target();
  return null;
}

/// Whether the run-at-login entry already launches with `--autostart` (so the
/// login launch settles into the tray). False for the older bare-exe entry,
/// letting startup migrate it in place. True on macOS: login launches go
/// through SMAppService, so there is nothing to migrate.
Future<bool> launchAtStartupHasAutostartFlag() async {
  if (Platform.isWindows) return win.launchAtStartupHasAutostart();
  if (Platform.isLinux) return lin.hasAutostartFlag();
  return true;
}

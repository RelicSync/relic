import 'dart:io' show Platform;

import 'foreground_app.dart' show kAppKeyNoise, linuxAppKey, macAppKey;
import 'src/linux/foreground_linux.dart' as lin;
import 'src/macos/foreground_macos.dart' as mac;
import 'src/windows/running_apps_win.dart' as win;

/// The applications the user has open right now, for the "Never capture
/// from" picker: [key] is the platform app key the blocklist stores and the
/// watcher gate compares against (exe stem on Windows, bundle-id-derived key
/// on macOS), [title] is a window title (Windows) or the app's localized name
/// (macOS) to help recognize the app. Shell hosts and other noise keys are
/// filtered out — they'd read as bizarre entries and (ApplicationFrameHost)
/// block more than they claim to.
typedef RunningApp = ({String key, String title});

Future<List<RunningApp>> runningApps() async {
  if (Platform.isWindows) {
    return win
        .runningWinApps()
        .where((a) => !kAppKeyNoise.contains(a.key))
        .toList();
  }
  if (Platform.isMacOS) {
    // Same derivation as the foreground read, so a picked entry always
    // matches at capture time; Relic itself keys to null and drops out.
    final seen = <String>{};
    final out = <RunningApp>[];
    for (final a in await mac.runningMacApps()) {
      final key = macAppKey(a.bundleId, a.name);
      if (key == null || kAppKeyNoise.contains(key)) continue;
      if (!seen.add(key)) continue;
      out.add((key: key, title: a.name.isEmpty ? key : a.name));
    }
    return out..sort((a, b) => a.key.compareTo(b.key));
  }
  if (Platform.isLinux) {
    // Same derivation as the foreground read, so a picked entry always
    // matches at capture time; Relic itself keys to null and drops out.
    // Empty under Wayland — the picker shows its empty state there.
    final seen = <String>{};
    final out = <RunningApp>[];
    for (final w in lin.runningX11Windows()) {
      final key = linuxAppKey(w.klass, w.instance);
      if (key == null || kAppKeyNoise.contains(key)) continue;
      if (!seen.add(key)) continue;
      out.add((key: key, title: w.title.isEmpty ? key : w.title));
    }
    return out..sort((a, b) => a.key.compareTo(b.key));
  }
  return const [];
}

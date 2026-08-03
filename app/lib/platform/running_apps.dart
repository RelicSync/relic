import 'dart:io' show Platform;

import 'foreground_app.dart' show kAppKeyNoise;
import 'src/windows/running_apps_win.dart' as win;

/// The applications the user has open right now, for the "Never capture
/// from" picker: [key] is the platform app key the blocklist stores and the
/// watcher gate compares against (exe stem on Windows), [title] is a window
/// title to help recognize the app. Shell hosts and other noise keys are
/// filtered out — they'd read as bizarre entries and (ApplicationFrameHost)
/// block more than they claim to.
typedef RunningApp = ({String key, String title});

Future<List<RunningApp>> runningApps() async {
  if (!Platform.isWindows) return const []; // macOS backend with the port
  return win
      .runningWinApps()
      .where((a) => !kAppKeyNoise.contains(a.key))
      .toList();
}

import 'dart:io';

import 'self_exec_linux.dart';

/// Self-update on Linux, which only exists for the AppImage.
///
/// An AppImage is one file, so updating is one atomic rename — the Linux
/// sibling of the macOS ditto-swap, and the reason the AppImage exists at all.
/// The unpacked tarball has no such story (a folder of files replaced under a
/// running process, with no package manager to sequence it), so it falls back
/// to opening the download page like every other unsupported case.
///
/// Replacing the file while it runs is safe: the running process holds the old
/// inode through its mount, and [File.rename] just moves a new inode into the
/// name. That is how AppImageUpdate has always done it.

/// The .AppImage this process is running from, or null when it is not one.
String? runningAppImage() {
  final p = Platform.environment['APPIMAGE'];
  if (p == null || p.isEmpty) return null;
  return File(p).existsSync() ? p : null;
}

/// Where to stage the download: beside the AppImage, so the swap is a rename
/// within one filesystem rather than a copy across two. Null when that
/// directory is not writable — a system-wide install (/opt, /usr/local) is
/// exactly the case that should defer to the browser instead of half-updating.
File? stagingFileFor(String appImagePath) {
  try {
    final dir = File(appImagePath).parent;
    final probe = File('${dir.path}/.relic-update-probe');
    probe.writeAsStringSync('');
    probe.deleteSync();
    return File('${dir.path}/.relic-update.AppImage');
  } catch (_) {
    return null;
  }
}

/// Move [staged] onto [appImagePath], keeping it executable.
///
/// The mode is set BEFORE the rename: a moment where the file exists at its
/// final name but is not executable is a moment where a launch fails.
void swapAppImage(File staged, String appImagePath) {
  final mode = Process.runSync('chmod', ['+x', staged.path]);
  if (mode.exitCode != 0) {
    throw StateError('could not make the update executable');
  }
  staged.renameSync(appImagePath);
}

/// Arm a detached relauncher: wait out THIS process, then start the new
/// AppImage. It has to wait, because the single-instance lock
/// (linux/runner/single_instance.cc) would turn an immediate launch into
/// "surface the running window" and then the old copy would exit — leaving
/// nothing running at all.
Future<void> relaunchAfterExit() async {
  final target = runningAppImage() ?? linuxSelfExecPath();
  await Process.start(
    'sh',
    [
      '-c',
      // kill -0 is a liveness probe, not a signal. The 60s ceiling means a
      // process that somehow never dies costs a stranded shell, not a relaunch
      // racing the lock forever.
      'for i in \$(seq 300); do kill -0 $pid 2>/dev/null || break; sleep 0.2; '
          'done; exec "$target"',
    ],
    mode: ProcessStartMode.detached,
  );
}

import 'dart:io';

/// The path a Linux desktop entry should point at to launch THIS copy of Relic.
///
/// Usually that is just the binary. Inside an AppImage it is not: the runtime
/// mounts the payload at a fresh `/tmp/.mount_XXXXXX` for the life of the
/// process, so [Platform.resolvedExecutable] is a path that will not exist next
/// time. An autostart entry written from it would silently stop working after
/// the first reboot, and the launcher entry would be rewritten on every launch.
///
/// The AppImage runtime sets `$APPIMAGE` to the real, stable path of the
/// .AppImage file itself, which is what any entry must reference. This is the
/// same rule every AppImage desktop-integration helper follows.
String linuxSelfExecPath() {
  final appImage = Platform.environment['APPIMAGE'];
  if (appImage != null && appImage.isNotEmpty) return appImage;
  return Platform.resolvedExecutable;
}

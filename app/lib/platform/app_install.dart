import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kDebugMode;

import 'shell.dart';
import 'src/macos/app_install_macos.dart' as mac;

/// Where the running bundle lives, as far as first-run rescue cares. macOS
/// only: Windows installs through an installer that puts the app in Program
/// Files, so there is no equivalent trap there.
enum BundleLocation {
  /// A place the app can just live: /Applications, ~/Applications, the
  /// Desktop, a build directory. Unusual is fine; only the two below strand
  /// people, so this one is left alone.
  settled,

  /// Still inside the downloaded disk image (a read-only /Volumes/… mount).
  /// The user double clicked Relic in the DMG window instead of dragging it
  /// across; ejecting takes the app with it and every setting they just typed
  /// goes too.
  diskImage,

  /// Gatekeeper's app translocation: a read-only shadow copy under
  /// /private/var/folders/…/AppTranslocation/…, which macOS makes when a
  /// quarantined app is launched from outside /Applications. Same ending as
  /// [diskImage] — the copy is thrown away, and the app cannot see or update
  /// its own folder while it runs.
  translocated,
}

/// Classify an executable path. Pure, so the rescue offer can be pinned by
/// tests without a Mac, a DMG, or Gatekeeper.
///
/// The path is the *resolved* executable, so translocation is already visible
/// in it: macOS rewrites it to the shadow copy rather than the original. A
/// [BundleLocation.diskImage] answer here is only "on some mounted volume" —
/// [applicationsInstallOffer] is where a writable one (an external disk
/// somebody keeps their apps on) is dropped again.
BundleLocation bundleLocationFor(String executablePath) {
  if (executablePath.contains('/AppTranslocation/')) {
    return BundleLocation.translocated;
  }
  if (executablePath.startsWith('/Volumes/')) return BundleLocation.diskImage;
  return BundleLocation.settled;
}

/// The .app root above [executablePath] (…/Relic.app/Contents/MacOS/relic_app
/// → …/Relic.app), or null when the executable is not inside a bundle at all
/// (a bare `dart` in a test, a Linux build). Last match wins so a nested helper
/// app resolves to itself rather than its host.
String? bundleRootFor(String executablePath) {
  const marker = '.app/Contents/MacOS/';
  final i = executablePath.lastIndexOf(marker);
  if (i < 0) return null;
  return executablePath.substring(0, i + '.app'.length);
}

/// The mount point above a /Volumes path (/Volumes/Relic 1.0.33/Relic.app/… →
/// /Volumes/Relic 1.0.33), or null when the path is not on a mounted volume.
String? volumeRootFor(String path) {
  const prefix = '/Volumes/';
  if (!path.startsWith(prefix)) return null;
  final rest = path.substring(prefix.length);
  final end = rest.indexOf('/');
  final name = end < 0 ? rest : rest.substring(0, end);
  return name.isEmpty ? null : '$prefix$name';
}

/// Should Relic offer to install itself into /Applications, and if so which
/// story does the user need to hear? Null means leave them alone. Pure: this
/// is the whole decision, and every fact it needs is passed in.
///
/// Debug builds are excluded outright: `flutter run` executes out of the build
/// directory, which is [BundleLocation.settled] anyway, but a developer who
/// mounts a DMG to test one should not have the app try to install itself over
/// their release copy.
///
/// [volumeWritable] tells a mounted disk image apart from an external disk
/// that somebody keeps their apps on: a DMG is always read-only, and a writable
/// volume is a place Relic can legitimately live, so it is left alone like any
/// other unusual-but-fine folder. Only consulted for /Volumes paths.
BundleLocation? applicationsInstallOffer({
  required bool isMacOS,
  required bool isDebug,
  required String executablePath,
  required bool volumeWritable,
}) {
  if (!isMacOS || isDebug) return null;
  final where = bundleLocationFor(executablePath);
  if (where == BundleLocation.settled) return null;
  if (where == BundleLocation.diskImage && volumeWritable) return null;
  return where;
}

/// [applicationsInstallOffer] answered for the running process.
BundleLocation? applicationsInstallOfferForThisProcess() =>
    applicationsInstallOffer(
      isMacOS: Platform.isMacOS,
      isDebug: kDebugMode,
      executablePath: Platform.resolvedExecutable,
      volumeWritable: _volumeWritable(Platform.resolvedExecutable),
    );

/// Can the volume this path sits on be written to? Answered the only way the
/// Dart IO layer can: by trying it, with a dotfile that is removed immediately.
/// Runs at most once per launch, and only for a /Volumes path — everything else
/// short-circuits before it and never touches the disk.
bool _volumeWritable(String path) {
  final root = volumeRootFor(path);
  if (root == null) return true; // not on a volume; the answer goes unused
  try {
    final probe = File('$root/.relic-write-probe');
    probe.writeAsStringSync('');
    probe.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}

/// Copy this bundle to /Applications/Relic.app and hand off to that copy.
///
/// Returns false when the copy did not happen (no write access to
/// /Applications, a locked or busy target, no bundle to copy from) — the caller
/// then falls back to [revealApplicationsFolder] plus instructions. It does not
/// return at all on success: the process exits so the installed copy is the
/// only one holding the tray icon and the hotkeys.
Future<bool> installIntoApplications() async {
  if (!Platform.isMacOS) return false;
  final root = bundleRootFor(Platform.resolvedExecutable);
  if (root == null) return false;
  return mac.installIntoApplications(root);
}

/// The manual path when [installIntoApplications] fails: put Finder on
/// /Applications so the user can drag the app across themselves.
Future<void> revealApplicationsFolder() =>
    revealInFileManager('/Applications');

/// Replace /Applications/Relic.app with the Relic.app inside the (already
/// sha256-verified) disk image at [dmgPath]. The macOS one-click self-update
/// backend (data/self_update.dart). Returns false when anything along the
/// mount → copy → detach path fails — the caller falls back to the browser
/// download page. On true, the new build is on disk and the caller finishes
/// the job with [relaunchInstalledCopyAfterExit] + its own exit.
Future<bool> installUpdateFromDiskImage(String dmgPath) async {
  if (!Platform.isMacOS) return false;
  return mac.installUpdateFromDiskImage(dmgPath);
}

/// Arm the detached relauncher: once this process exits, the installed copy
/// is opened fresh (an `open` while we still run would only reactivate us).
Future<void> relaunchInstalledCopyAfterExit() async {
  if (!Platform.isMacOS) return;
  await mac.reopenInstalledAfterExit();
}

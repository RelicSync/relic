import 'dart:io';

/// macOS backend of platform/app_install.dart: moving the running bundle into
/// /Applications and handing off to the copy that lands there.
///
/// Pure Dart on purpose — this runs before anything else in the app, and the
/// two tools it needs (ditto, open) are the same ones the release script and
/// every Mac installer use. No MethodChannel, so a stale native build cannot
/// break the one path that rescues a stranded first run.

const _target = '/Applications/Relic.app';

/// Copy [bundleRoot] to /Applications/Relic.app, replacing whatever is there,
/// then relaunch from the new location. False means the copy failed and the
/// caller should fall back to Finder; on success this never returns.
Future<bool> installIntoApplications(String bundleRoot) async {
  if (!await _copyBundle(bundleRoot, _target)) return false;
  await reopenInstalledAfterExit();
  exit(0);
}

/// Replace [target] with the `Relic.app` inside the disk image at [dmgPath]:
/// mount (invisibly, read-only), same ditto-swap as the first-run install,
/// detach. The self-update backend (data/self_update.dart) — the caller owns
/// what happens next (relaunch + exit), so unlike [installIntoApplications]
/// this RETURNS: false on any failure, true once the swap is on disk.
///
/// Replacing the RUNNING app's own bundle this way is safe on macOS: the
/// process keeps its mapped binary and frameworks by inode, so it runs on
/// unbothered while the path points at the new version — the same swap
/// Sparkle-updated apps have done for years. [target] is parameterized only
/// so tests can exercise the mount/copy/detach cycle against a scratch
/// directory instead of the real /Applications.
Future<bool> installUpdateFromDiskImage(String dmgPath,
    {String target = _target}) async {
  final mnt = Directory.systemTemp.createTempSync('relic-update-mnt');
  var mounted = false;
  try {
    // -nobrowse: no Finder window, no desktop icon — nothing for anyone to
    // wander into mid-update (a browsable build mount cost us a stray
    // second instance once; see AppDelegate.swift's guard).
    final attach = await Process.run('/usr/bin/hdiutil',
        ['attach', '-nobrowse', '-readonly', '-mountpoint', mnt.path, dmgPath]);
    if (attach.exitCode != 0) return false;
    mounted = true;
    final src = '${mnt.path}/Relic.app';
    if (!Directory(src).existsSync()) return false;
    return await _copyBundle(src, target);
  } catch (_) {
    return false;
  } finally {
    if (mounted) await _detach(mnt.path);
    try {
      mnt.deleteSync();
    } catch (_) {}
  }
}

Future<void> _detach(String mountpoint) async {
  final r = await Process.run('/usr/bin/hdiutil', ['detach', mountpoint]);
  if (r.exitCode != 0) {
    // Busy mounts happen (Spotlight). -force only tears down the mount table
    // entry; the image file itself is untouched either way.
    await Process.run('/usr/bin/hdiutil', ['detach', '-force', mountpoint]);
  }
}

Future<bool> _copyBundle(String bundleRoot, String target) async {
  // Staged beside the target (same volume, so the swap is a rename), with a
  // dotted name to stay out of Launchpad/Spotlight if we die mid-copy.
  final staging = Directory(
      '${Directory(target).parent.path}/.${target.split('/').last.replaceFirst('.app', '')}-installing.app');
  try {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    // ditto, not `cp -R`: it carries extended attributes and the sealed
    // resources through intact, so the copy keeps its code signature (cp -R
    // quietly breaks it, and a broken signature is a Gatekeeper refusal on the
    // very next launch). The disk image being read-only is fine — it is only
    // ever the source here.
    final copy = await Process.run('/usr/bin/ditto', [bundleRoot, staging.path]);
    if (copy.exitCode != 0) {
      _cleanUpStaging(staging);
      return false;
    }
    // Replace rather than merge: dittoing over an older Relic.app would leave
    // its removed files behind, and stale frameworks beside a new binary is
    // exactly the mix that fails signature validation.
    final targetDir = Directory(target);
    if (targetDir.existsSync()) targetDir.deleteSync(recursive: true);
    staging.renameSync(target);
    return true;
  } catch (_) {
    _cleanUpStaging(staging);
    return false;
  }
}

void _cleanUpStaging(Directory staging) {
  try {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  } catch (_) {}
}

/// Open the installed copy once this process is gone.
///
/// The order matters: `open` on a bundle whose identifier already belongs to a
/// running app just reactivates the running one, which here is the copy we are
/// trying to leave behind. So a detached shell waits out our pid and opens the
/// installed app after it, when nothing is left to reactivate. The path is a
/// fixed constant with no spaces, so there is nothing to quote around.
///
/// The copy inherits the disk image's quarantine flag, so Gatekeeper may ask
/// once more whether to open it. That prompt is fine: the app is notarized, the
/// user gets a plain Open button, and it never comes back after the first
/// launch from the new location.
Future<void> reopenInstalledAfterExit() async {
  try {
    await Process.start(
      '/bin/sh',
      [
        '-c',
        'while kill -0 $pid 2>/dev/null; do sleep 0.2; done; '
            '/usr/bin/open $_target',
      ],
      mode: ProcessStartMode.detached,
    );
  } catch (_) {
    // Worst case the user opens Relic themselves; the app is in the right
    // place either way, which is the part that was worth doing.
  }
}

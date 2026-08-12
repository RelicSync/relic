import 'dart:io';

/// macOS backend of platform/app_install.dart: moving the running bundle into
/// /Applications and handing off to the copy that lands there.
///
/// Pure Dart on purpose — this runs before anything else in the app, and the
/// two tools it needs (ditto, open) are the same ones the release script and
/// every Mac installer use. No MethodChannel, so a stale native build cannot
/// break the one path that rescues a stranded first run.

const _target = '/Applications/Relic.app';

/// Staged beside the target, not in /tmp: the rename that swaps it into place
/// has to be a same-volume move, and a dotted name keeps a half-written bundle
/// out of Launchpad and Spotlight if we die mid-copy.
const _staging = '/Applications/.Relic-installing.app';

/// Copy [bundleRoot] to /Applications/Relic.app, replacing whatever is there,
/// then relaunch from the new location. False means the copy failed and the
/// caller should fall back to Finder; on success this never returns.
Future<bool> installIntoApplications(String bundleRoot) async {
  if (!await _copyIntoApplications(bundleRoot)) return false;
  await _reopenAfterExit();
  exit(0);
}

Future<bool> _copyIntoApplications(String bundleRoot) async {
  final staging = Directory(_staging);
  try {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    // ditto, not `cp -R`: it carries extended attributes and the sealed
    // resources through intact, so the copy keeps its code signature (cp -R
    // quietly breaks it, and a broken signature is a Gatekeeper refusal on the
    // very next launch). The disk image being read-only is fine — it is only
    // ever the source here.
    final copy = await Process.run('/usr/bin/ditto', [bundleRoot, _staging]);
    if (copy.exitCode != 0) {
      _cleanUpStaging();
      return false;
    }
    // Replace rather than merge: dittoing over an older Relic.app would leave
    // its removed files behind, and stale frameworks beside a new binary is
    // exactly the mix that fails signature validation.
    final target = Directory(_target);
    if (target.existsSync()) target.deleteSync(recursive: true);
    staging.renameSync(_target);
    return true;
  } catch (_) {
    _cleanUpStaging();
    return false;
  }
}

void _cleanUpStaging() {
  try {
    final staging = Directory(_staging);
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
Future<void> _reopenAfterExit() async {
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

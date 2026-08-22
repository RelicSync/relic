import 'dart:io';

import 'package:hashlib/hashlib.dart' show sha256;
import 'package:http/http.dart' as http;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../platform/app_install.dart';
import 'update_check.dart';

/// One-click self-update for the desktop builds.
///
/// Streams the signed installer to a temp file, verifies it against the
/// manifest's sha256, then installs:
///   - Windows: hands off to a SILENT per-user Inno install (no UAC — see
///     installer/relic.iss) that force-closes this process and relaunches
///     the new build into the tray (`/RELAUNCH=1`, handled by the
///     ShouldRelaunch check in the .iss).
///   - macOS: mounts the DMG invisibly and swaps /Applications/Relic.app in
///     place (platform/app_install.dart, the same ditto-swap as the first-run
///     install offer), then exits so the detached relauncher can open the new
///     build. Safe while running — the process keeps its binary by inode.
///   - Linux: only from an AppImage, which is one file — so the install is one
///     atomic rename, the sibling of the mac swap. An unpacked tarball has no
///     such story (a folder replaced under a running process, with no package
///     manager to sequence it) and takes the browser fallback, as does a
///     system-wide AppImage the user cannot write.
///
/// On success this never returns. Callers catch [SelfUpdateUnsupported]
/// (unsupported platform, or a manifest without sha256) and any other
/// failure, and fall back to opening the download page.
class SelfUpdateUnsupported implements Exception {}

Future<void> installUpdate(
  UpdateInfo info, {
  void Function(String status)? onStatus,
}) async {
  final sha = info.sha256;
  if (sha == null ||
      !(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    throw SelfUpdateUnsupported();
  }
  if (Platform.isLinux) {
    final appImage = runningAppImagePath();
    if (appImage == null) throw SelfUpdateUnsupported();
    final staged = appImageStagingFile(appImage);
    if (staged == null) throw SelfUpdateUnsupported();
    await _download(info.url, staged, onStatus);
    onStatus?.call('Verifying…');
    await verifyInstaller(staged, sha);
    onStatus?.call('Installing. Relic will restart…');
    if (!installUpdatedAppImage(staged, appImage)) {
      try {
        staged.deleteSync();
      } catch (_) {}
      throw StateError('could not install the update');
    }
    // Arm the relauncher BEFORE dying: the single-instance lock means a launch
    // while we still hold it would only surface this window, and then this
    // process would exit leaving nothing running.
    await relaunchInstalledCopyAfterExit();
    await trayManager.destroy();
    exit(0);
  }
  final dir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}relic-update')
    ..createSync(recursive: true);
  if (Platform.isWindows) {
    final file = File('${dir.path}\\relic-setup-${info.version}.exe');
    await _download(info.url, file, onStatus);
    onStatus?.call('Verifying…');
    await verifyInstaller(file, sha);
    onStatus?.call('Installing. Relic will restart…');
    await Process.start(
      file.path,
      const [
        '/VERYSILENT',
        '/NORESTART',
        '/SUPPRESSMSGBOXES',
        '/FORCECLOSEAPPLICATIONS',
        '/RELAUNCH=1',
      ],
      mode: ProcessStartMode.detached,
    );
    // Get out of the installer's way: releasing our file locks with a clean
    // exit beats making it force-close us. It preps/extracts for a moment
    // before touching {app}, which is all the head start we need.
    await trayManager.destroy();
    await windowManager.destroy();
    return;
  }
  // macOS. The DMG is downloaded by us, not a browser, so it carries no
  // quarantine flag — the swapped-in app relaunches without a Gatekeeper
  // prompt. The sha256 check above is what stands in for that gate, and the
  // bundle inside is Developer ID signed and notarized besides.
  final file = File('${dir.path}/relic-${info.version}.dmg');
  await _download(info.url, file, onStatus);
  onStatus?.call('Verifying…');
  await verifyInstaller(file, sha);
  onStatus?.call('Installing. Relic will restart…');
  if (!await installUpdateFromDiskImage(file.path)) {
    throw StateError('could not install the update');
  }
  try {
    file.deleteSync();
  } catch (_) {}
  // Arm the relauncher BEFORE dying: it waits out this pid, then opens the
  // new copy (an `open` while we run would only reactivate this process).
  await relaunchInstalledCopyAfterExit();
  await trayManager.destroy();
  exit(0);
}

/// Throws unless [file]'s bytes hash to [expectedSha256] (hex, case-blind).
/// The installer is Authenticode-signed too; this catches a truncated or
/// swapped download before we ever execute it.
Future<void> verifyInstaller(File file, String expectedSha256) async {
  final digest = sha256.convert(await file.readAsBytes()).hex();
  if (digest.toLowerCase() != expectedSha256.toLowerCase()) {
    try {
      file.deleteSync();
    } catch (_) {}
    throw StateError('installer hash mismatch');
  }
}

Future<void> _download(
  String url,
  File out,
  void Function(String)? onStatus,
) async {
  onStatus?.call('Downloading…');
  final client = http.Client();
  try {
    final rsp = await client
        .send(http.Request('GET', Uri.parse(url)))
        .timeout(const Duration(seconds: 30));
    if (rsp.statusCode != 200) {
      throw HttpException('update download failed: HTTP ${rsp.statusCode}');
    }
    final total = rsp.contentLength ?? 0;
    var got = 0;
    var lastPct = -1;
    final sink = out.openWrite();
    try {
      await for (final chunk in rsp.stream) {
        sink.add(chunk);
        got += chunk.length;
        final pct = total > 0 ? got * 100 ~/ total : -1;
        if (pct != lastPct) {
          lastPct = pct;
          onStatus?.call('Downloading… $pct%');
        }
      }
    } finally {
      await sink.close();
    }
  } finally {
    client.close();
  }
}

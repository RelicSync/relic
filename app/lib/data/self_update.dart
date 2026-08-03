import 'dart:io';

import 'package:hashlib/hashlib.dart' show sha256;
import 'package:http/http.dart' as http;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'update_check.dart';

/// One-click self-update for the Windows build.
///
/// Streams the signed installer to a temp file, verifies it against the
/// manifest's sha256, then hands off to a SILENT per-user Inno install
/// (no UAC — see installer/relic.iss) that force-closes this process and
/// relaunches the new build into the tray (`/RELAUNCH=1`, handled by the
/// ShouldRelaunch check in the .iss).
///
/// On success this never returns: it tears the app down so the installer
/// can swap the files without waiting on our locks. Callers catch
/// [SelfUpdateUnsupported] (non-Windows, or a manifest without sha256) and
/// any other failure, and fall back to opening the download page.
class SelfUpdateUnsupported implements Exception {}

Future<void> installUpdate(
  UpdateInfo info, {
  void Function(String status)? onStatus,
}) async {
  final sha = info.sha256;
  if (!Platform.isWindows || sha == null) throw SelfUpdateUnsupported();
  final dir = Directory('${Directory.systemTemp.path}\\relic-update')
    ..createSync(recursive: true);
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

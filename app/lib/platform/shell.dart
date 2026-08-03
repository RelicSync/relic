import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

/// Open a folder in the OS file manager (Explorer / Finder), used by the
/// Settings "open data folder / logs / export" buttons. Best-effort.
Future<void> revealInFileManager(String dir) async {
  try {
    if (Platform.isWindows) {
      await Process.start('explorer', [dir]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [dir]);
    } else {
      await launchUrl(Uri.file(dir));
    }
  } catch (_) {}
}

/// Open the file manager with ONE file highlighted (Explorer /select, Finder
/// open -R) — the row download action's "take me to it". Falls back to just
/// opening the containing folder. Best-effort.
Future<void> revealFileInFileManager(String path) async {
  try {
    if (Platform.isWindows) {
      // Two args ("/select," then the quoted path) is the form Explorer
      // parses reliably when the path contains spaces.
      await Process.start('explorer', ['/select,', path]);
    } else if (Platform.isMacOS) {
      await Process.start('open', ['-R', path]);
    } else {
      await launchUrl(Uri.file(File(path).parent.path));
    }
  } catch (_) {}
}

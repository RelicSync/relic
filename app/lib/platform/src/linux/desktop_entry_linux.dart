import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;

/// Registering Relic with the Linux desktop: the launcher entry in
/// `~/.local/share/applications`, its icon in the user's hicolor theme.
///
/// Relic ships as a tarball, not a package, so nothing installs this for the
/// user — and without it Relic exists only as a binary in a folder. It has no
/// entry in the app grid, no icon anywhere, and no claim on `relic://` links,
/// which is how the website's post-checkout "Open Relic" button gets back to
/// the app. The self-registration is the Linux equivalent of what relic.iss
/// does on Windows and what the .app bundle carries on macOS.
///
/// Everything here is user-scoped and idempotent: it writes under
/// `$XDG_DATA_HOME` (never system paths, never sudo), rewrites only when the
/// entry is missing or points at a different binary, and fails soft.

const String _fileName = 'space.relic.app.desktop';
const String _iconName = 'space.relic.app';

/// `$XDG_DATA_HOME` or `~/.local/share`. Null when there is no home.
///
/// Note this is the same base as the vault (paths.dart), which is deliberate:
/// both are user data, and a relocated XDG_DATA_HOME should move both.
String? xdgDataHomeFrom(String? xdgDataHome, String? home) {
  if (xdgDataHome != null && xdgDataHome.isNotEmpty) return xdgDataHome;
  if (home == null || home.isEmpty) return null;
  return '$home/.local/share';
}

String? _dataHome() => xdgDataHomeFrom(
    Platform.environment['XDG_DATA_HOME'], Platform.environment['HOME']);

/// The launcher entry Relic writes for [exec]. Pure, so the format is pinned
/// by tests from any host.
///
/// `%u` and the `x-scheme-handler/relic` MIME type are what make `relic://`
/// links open the app; `StartupWMClass` is what lets the shell match the
/// running window back to this entry, so the taskbar shows Relic's own icon and
/// name rather than a generic one (the runner sets the matching prgname).
String applicationsDesktopEntry(String exec) {
  final quoted = exec.contains(' ') ? '"$exec"' : exec;
  return '[Desktop Entry]\n'
      'Type=Application\n'
      'Version=1.0\n'
      'Name=Relic\n'
      'GenericName=Clipboard Vault\n'
      'Comment=Everything you copy, kept and searchable\n'
      'Exec=$quoted %u\n'
      'Icon=$_iconName\n'
      'Terminal=false\n'
      'Categories=Utility;\n'
      'Keywords=clipboard;history;paste;vault;snippets;\n'
      'MimeType=x-scheme-handler/relic;\n'
      'StartupWMClass=space.relic.app\n'
      'StartupNotify=false\n';
}

/// The `Exec=` binary of an existing entry, quoting removed and arguments
/// dropped, or null. Kept here rather than shared with the autostart reader
/// because the two entries have different lifetimes and different Exec lines.
String? desktopEntryExec(String body) {
  for (final raw in body.split('\n')) {
    final line = raw.trim();
    if (!line.startsWith('Exec=')) continue;
    final value = line.substring(5).trim();
    if (value.isEmpty) return null;
    if (value.startsWith('"')) {
      final end = value.indexOf('"', 1);
      return end < 0 ? value.substring(1) : value.substring(1, end);
    }
    final sp = value.indexOf(' ');
    return sp < 0 ? value : value.substring(0, sp);
  }
  return null;
}

/// Whether an existing [body] already describes THIS install: same binary, and
/// carrying the scheme handler (an entry written before `relic://` support
/// would otherwise never be refreshed).
bool desktopEntryIsCurrent(String body, String exec) =>
    desktopEntryExec(body) == exec &&
    body.contains('x-scheme-handler/relic');

/// The icon, resized to a size the hicolor theme actually indexes. The source
/// asset is 291px, and a stray size in a `256x256` directory is exactly the
/// kind of thing icon caches silently skip.
Uint8List _iconPng(Uint8List source) {
  final decoded = img.decodeImage(source);
  if (decoded == null) return source;
  final resized = img.copyResize(decoded, width: 256, height: 256);
  return Uint8List.fromList(img.encodePng(resized));
}

/// Register (or refresh) the launcher entry and icon. Returns whether an entry
/// is in place afterwards. Safe to call on every launch.
Future<bool> ensureRegistered() async {
  try {
    final base = _dataHome();
    if (base == null) return false;
    final exec = Platform.resolvedExecutable;
    final entry = File('$base/applications/$_fileName');

    if (entry.existsSync() &&
        desktopEntryIsCurrent(entry.readAsStringSync(), exec)) {
      return true;
    }

    final icon =
        File('$base/icons/hicolor/256x256/apps/$_iconName.png');
    if (!icon.existsSync()) {
      try {
        final bytes = await rootBundle.load('assets/beautiful-icon.png');
        icon.parent.createSync(recursive: true);
        icon.writeAsBytesSync(_iconPng(bytes.buffer.asUint8List()));
      } catch (_) {
        // No icon is a cosmetic loss; the entry itself still works.
      }
    }

    entry.parent.createSync(recursive: true);
    entry.writeAsStringSync(applicationsDesktopEntry(exec));

    // Only this rebuilds the scheme-handler index, so relic:// links stay dead
    // until it runs. Absent on minimal systems, hence the swallowed failure.
    try {
      await Process.run('update-desktop-database', [entry.parent.path]);
    } catch (_) {}
    return true;
  } catch (_) {
    return false;
  }
}

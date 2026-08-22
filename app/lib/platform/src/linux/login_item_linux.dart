import 'dart:io';

import 'self_exec_linux.dart';

/// Run-at-login on Linux: the XDG autostart spec's
/// `~/.config/autostart/space.relic.app.desktop`. Every mainstream desktop
/// (GNOME, KDE, XFCE, Cinnamon, MATE) launches what it finds there, so this is
/// the one mechanism that does not need a per-desktop special case — and unlike
/// a systemd user unit it shows up in the desktop's own "Startup Applications"
/// UI, where a user who wants Relic gone can turn it off.
///
/// The entry is the autostart dir's, not the launcher's: it carries
/// `--autostart` so the login launch settles into the tray instead of throwing
/// a window at a user who just signed in.
///
/// Everything is best-effort — a read-only or missing home directory returns
/// false rather than throwing, exactly like the Windows registry arm.

const String _fileName = 'space.relic.app.desktop';

/// The autostart directory, `$XDG_CONFIG_HOME/autostart` falling back to
/// `~/.config/autostart`. Null when there is no home to write into.
///
/// This is the CONFIG dir, deliberately: the vault moved to
/// `$XDG_DATA_HOME/relic` (paths.dart), but an autostart entry is
/// configuration and the spec puts it nowhere else.
String? autostartDirFrom(String? xdgConfigHome, String? home) {
  if (xdgConfigHome != null && xdgConfigHome.isNotEmpty) {
    return '$xdgConfigHome/autostart';
  }
  if (home == null || home.isEmpty) return null;
  return '$home/.config/autostart';
}

String? autostartDirPath() => autostartDirFrom(
    Platform.environment['XDG_CONFIG_HOME'], Platform.environment['HOME']);

String? _entryPath() {
  final dir = autostartDirPath();
  return dir == null ? null : '$dir/$_fileName';
}

/// The desktop-entry body Relic writes for [exec]. Pure so the format is
/// pinned by tests from any host.
///
/// `X-GNOME-Autostart-enabled=true` is written explicitly because GNOME's own
/// startup-apps UI disables an entry by flipping that key rather than deleting
/// the file; writing it means re-enabling from Relic actually re-enables.
String autostartDesktopEntry(String exec) {
  final quoted = exec.contains(' ') ? '"$exec"' : exec;
  return '[Desktop Entry]\n'
      'Type=Application\n'
      'Version=1.0\n'
      'Name=Relic\n'
      'Comment=Clipboard vault\n'
      'Exec=$quoted --autostart\n'
      'Icon=space.relic.app\n'
      'Terminal=false\n'
      'Categories=Utility;\n'
      'X-GNOME-Autostart-enabled=true\n';
}

/// Whether a desktop-entry [body] describes an entry that will actually run.
/// The spec's `Hidden=true` means "deleted" and GNOME's
/// `X-GNOME-Autostart-enabled=false` means "switched off in the UI"; either one
/// makes a present file a no-op, so presence alone is not the answer.
bool autostartEntryEnabled(String body) {
  for (final raw in body.split('\n')) {
    final line = raw.trim().toLowerCase();
    if (line == 'hidden=true') return false;
    if (line == 'x-gnome-autostart-enabled=false') return false;
  }
  return true;
}

/// The executable an entry's `Exec=` points at, with desktop-entry quoting
/// removed and arguments dropped. Null when there is no Exec line.
///
/// Only the leading token is returned: the spec allows quoted paths (which is
/// how a path with spaces survives), so a leading `"` runs to the closing one.
String? autostartExecPath(String body) {
  for (final raw in body.split('\n')) {
    final line = raw.trim();
    if (!line.startsWith('Exec=')) continue;
    final value = line.substring(5).trim();
    if (value.isEmpty) return null;
    if (value.startsWith('"')) {
      final end = value.indexOf('"', 1);
      if (end < 0) return value.substring(1);
      return value.substring(1, end);
    }
    final sp = value.indexOf(' ');
    return sp < 0 ? value : value.substring(0, sp);
  }
  return null;
}

/// Whether an entry's `Exec=` already carries `--autostart`. False for an
/// older bare-exe entry, which lets startup rewrite it in place.
bool autostartEntryHasFlag(String body) {
  for (final raw in body.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('Exec=')) return line.contains('--autostart');
  }
  return false;
}

String? _readEntry() {
  try {
    final path = _entryPath();
    if (path == null) return null;
    final f = File(path);
    if (!f.existsSync()) return null;
    return f.readAsStringSync();
  } catch (_) {
    return null;
  }
}

/// Write or remove the autostart entry. Returns whether the change stuck.
bool setEnabled(bool enable) {
  try {
    final path = _entryPath();
    if (path == null) return false;
    final f = File(path);
    if (!enable) {
      if (f.existsSync()) f.deleteSync();
      return !f.existsSync();
    }
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(autostartDesktopEntry(linuxSelfExecPath()));
    return f.existsSync();
  } catch (_) {
    return false;
  }
}

/// Whether Relic is registered to run at login AND the entry is switched on.
bool isEnabled() {
  final body = _readEntry();
  return body != null && autostartEntryEnabled(body);
}

/// The executable the autostart entry points at, or null when there is none.
String? target() {
  final body = _readEntry();
  return body == null ? null : autostartExecPath(body);
}

/// Whether the existing entry already launches with `--autostart`. True when
/// there is no entry at all, so a fresh install has nothing to migrate.
bool hasAutostartFlag() {
  final body = _readEntry();
  return body == null || autostartEntryHasFlag(body);
}

/// Whether the entry on disk still describes the copy that is running:
/// present, switched on, pointing at this executable, and carrying the flag.
/// False means startup should rewrite it.
///
/// The comparison lives here rather than in the caller because "this
/// executable" is not [Platform.resolvedExecutable] under an AppImage — see
/// [linuxSelfExecPath].
bool isCurrent() {
  final body = _readEntry();
  if (body == null) return false;
  return autostartEntryEnabled(body) &&
      autostartEntryHasFlag(body) &&
      autostartExecPath(body) == linuxSelfExecPath();
}

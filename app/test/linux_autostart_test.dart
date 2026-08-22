import 'package:flutter_test/flutter_test.dart';

import 'package:relic_app/platform/src/linux/login_item_linux.dart';

/// The XDG autostart entry Relic writes on Linux is parsed back by the same
/// code that writes it (startup rewrites a stale or flag-less entry, see
/// LocalDeskRepo.load), so the format and the reader are pinned together here.
/// All of it is pure string work, so it runs from any host.
void main() {
  group('autostartDesktopEntry', () {
    test('round-trips through our own reader', () {
      const exe = '/home/j/relic/bundle/relic_app';
      final body = autostartDesktopEntry(exe);
      expect(autostartExecPath(body), exe);
      expect(autostartEntryHasFlag(body), isTrue);
      expect(autostartEntryEnabled(body), isTrue);
    });

    test('a path with spaces survives as a quoted Exec', () {
      const exe = '/home/j/My Apps/relic/relic_app';
      final body = autostartDesktopEntry(exe);
      expect(body, contains('Exec="$exe" --autostart'));
      expect(autostartExecPath(body), exe);
    });

    test('names the entry a real application GNOME will run', () {
      final body = autostartDesktopEntry('/opt/relic/relic_app');
      expect(body, startsWith('[Desktop Entry]\n'));
      expect(body, contains('Type=Application'));
      expect(body, contains('Terminal=false'));
      // Written explicitly: GNOME's startup-apps UI disables by flipping this
      // key rather than deleting, so re-enabling has to be able to flip back.
      expect(body, contains('X-GNOME-Autostart-enabled=true'));
    });
  });

  group('autostartEntryEnabled', () {
    test('a present file is not the same as an enabled one', () {
      const hidden = '[Desktop Entry]\nExec=/opt/relic/relic_app\nHidden=true\n';
      expect(autostartEntryEnabled(hidden), isFalse);
      const off = '[Desktop Entry]\nExec=/opt/relic/relic_app\n'
          'X-GNOME-Autostart-enabled=false\n';
      expect(autostartEntryEnabled(off), isFalse);
    });

    test('keys are matched case-insensitively and past stray spacing', () {
      expect(autostartEntryEnabled('  hidden=TRUE  '), isFalse);
    });

    test('anything else runs', () {
      expect(autostartEntryEnabled('[Desktop Entry]\nHidden=false\n'), isTrue);
    });
  });

  group('reading a foreign entry', () {
    test('an unquoted Exec drops its arguments', () {
      const body = '[Desktop Entry]\nExec=/opt/relic/relic_app --autostart\n';
      expect(autostartExecPath(body), '/opt/relic/relic_app');
      expect(autostartEntryHasFlag(body), isTrue);
    });

    test('a bare pre-flag entry reports no flag, so startup rewrites it', () {
      const body = '[Desktop Entry]\nExec=/opt/relic/relic_app\n';
      expect(autostartEntryHasFlag(body), isFalse);
      expect(autostartExecPath(body), '/opt/relic/relic_app');
    });

    test('no Exec line at all is null, not an empty path', () {
      expect(autostartExecPath('[Desktop Entry]\nType=Application\n'), isNull);
      expect(autostartExecPath('[Desktop Entry]\nExec=\n'), isNull);
    });
  });

  group('autostartDirFrom', () {
    test('is under the config dir, never the vault', () {
      // The vault moved to $XDG_DATA_HOME/relic; the autostart entry did not
      // follow it, because the spec only ever reads the config dir.
      expect(autostartDirFrom(null, '/home/j'), '/home/j/.config/autostart');
      expect(autostartDirFrom('/home/j/.config', '/home/j'),
          '/home/j/.config/autostart');
      expect(autostartDirFrom(null, '/home/j'), isNot(contains('.local/share')));
    });

    test('honors a relocated XDG_CONFIG_HOME', () {
      expect(autostartDirFrom('/cfg', '/home/j'), '/cfg/autostart');
    });

    test('no home means no entry, not a path relative to the cwd', () {
      expect(autostartDirFrom(null, null), isNull);
      expect(autostartDirFrom('', ''), isNull);
    });
  });
}

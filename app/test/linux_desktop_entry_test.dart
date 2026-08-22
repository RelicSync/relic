import 'package:flutter_test/flutter_test.dart';

import 'package:relic_app/platform/src/linux/desktop_entry_linux.dart';

/// Relic writes its own launcher entry on Linux because the tarball has no
/// install step. Startup rewrites the entry whenever it stops describing the
/// running install, so the writer and the reader are pinned together here.
void main() {
  group('applicationsDesktopEntry', () {
    test('claims relic:// and passes the URL through', () {
      final body = applicationsDesktopEntry('/opt/relic/relic_app');
      // Both halves are needed: the MIME type is what the scheme index reads,
      // %u is what actually hands the URL to the process.
      expect(body, contains('MimeType=x-scheme-handler/relic;'));
      expect(body, contains('Exec=/opt/relic/relic_app %u'));
    });

    test('matches the running window back to the entry', () {
      // The runner sets prgname to the application id; without the matching
      // StartupWMClass the shell shows a generic icon for the live window.
      expect(applicationsDesktopEntry('/opt/relic/relic_app'),
          contains('StartupWMClass=space.relic.app'));
    });

    test('a path with spaces survives as a quoted Exec', () {
      const exe = '/home/j/My Apps/relic/relic_app';
      final body = applicationsDesktopEntry(exe);
      expect(body, contains('Exec="$exe" %u'));
      expect(desktopEntryExec(body), exe);
    });

    test('round-trips as current for its own binary', () {
      const exe = '/opt/relic/relic_app';
      expect(desktopEntryIsCurrent(applicationsDesktopEntry(exe), exe), isTrue);
    });
  });

  group('desktopEntryIsCurrent', () {
    test('a moved bundle is stale, so startup rewrites it', () {
      final body = applicationsDesktopEntry('/old/relic_app');
      expect(desktopEntryIsCurrent(body, '/new/relic_app'), isFalse);
    });

    test('an entry predating relic:// support is stale at the same path', () {
      const body = '[Desktop Entry]\nType=Application\n'
          'Exec=/opt/relic/relic_app\nIcon=space.relic.app\n';
      expect(desktopEntryIsCurrent(body, '/opt/relic/relic_app'), isFalse);
    });
  });

  group('xdgDataHomeFrom', () {
    test('shares its base with the vault', () {
      expect(xdgDataHomeFrom(null, '/home/j'), '/home/j/.local/share');
      expect(xdgDataHomeFrom('/data', '/home/j'), '/data');
    });

    test('no home means nowhere to register', () {
      expect(xdgDataHomeFrom(null, null), isNull);
      expect(xdgDataHomeFrom('', ''), isNull);
    });
  });
}

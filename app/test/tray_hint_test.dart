import 'package:flutter_test/flutter_test.dart';

import 'package:relic_app/platform/tray_support.dart';

/// The one-time "Relic is still running" notification is the only thing that
/// tells a new user how to get the window back, so what it promises has to be
/// true on the desktop it is shown on. Pure, so every branch is checked from
/// any host.
void main() {
  group('trayHintBody', () {
    test('names the menu bar on macOS and the tray on Windows', () {
      expect(
        trayHintBody(
            hotkey: 'Ctrl+Shift+Space',
            isMacOS: true,
            isLinux: false,
            trayPresent: true),
        contains('menu bar'),
      );
      expect(
        trayHintBody(
            hotkey: 'Ctrl+Shift+Space',
            isMacOS: false,
            isLinux: false,
            trayPresent: true),
        contains('tray'),
      );
    });

    test('a Linux desktop WITH a tray gets the ordinary promise', () {
      final body = trayHintBody(
          hotkey: 'Ctrl+Shift+Space',
          isMacOS: false,
          isLinux: true,
          trayPresent: true);
      expect(body, contains('It lives in your tray'));
      expect(body, contains('Ctrl+Shift+Space'));
    });

    test('a Linux desktop WITHOUT one promises no icon at all', () {
      final body = trayHintBody(
          hotkey: 'Ctrl+Shift+Space',
          isMacOS: false,
          isLinux: true,
          trayPresent: false);
      expect(body, isNot(contains('lives in your tray')));
      expect(body, contains('does not show tray icons'));
      expect(body, contains('Ctrl+Shift+Space'));
    });

    test('every branch names the hotkey — it is the way back either way', () {
      for (final linux in [true, false]) {
        for (final present in [true, false]) {
          expect(
            trayHintBody(
                hotkey: 'F9',
                isMacOS: false,
                isLinux: linux,
                trayPresent: present),
            contains('F9'),
            reason: 'linux=$linux present=$present',
          );
        }
      }
    });
  });
}

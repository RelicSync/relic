import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:relic_app/platform/src/linux/app_install_linux.dart';

/// The AppImage swap is the whole of Linux self-update: one file replaced by
/// one rename. These exercise the real filesystem, so they are Linux-only —
/// public CI runs the suite on ubuntu-latest, which is where they count.
void main() {
  final onLinux = Platform.isLinux;

  group('stagingFileFor', () {
    test('stages beside the AppImage, so the swap is a rename not a copy', () {
      final dir = Directory.systemTemp.createTempSync('relic-appimg');
      addTearDown(() => dir.deleteSync(recursive: true));
      final target = '${dir.path}/Relic.AppImage';
      File(target).writeAsStringSync('old');
      final staged = stagingFileFor(target);
      expect(staged, isNotNull);
      expect(staged!.parent.path, dir.path);
    }, skip: onLinux ? null : 'POSIX file modes');

    test('a directory it cannot write is null, not a half-update', () {
      // A system-wide install (/opt, /usr/local) must defer to the browser
      // rather than download 33 MB it can never put in place.
      expect(stagingFileFor('/proc/relic/Relic.AppImage'), isNull);
    }, skip: onLinux ? null : 'POSIX permissions');

    test('leaves no probe file behind', () {
      final dir = Directory.systemTemp.createTempSync('relic-appimg');
      addTearDown(() => dir.deleteSync(recursive: true));
      stagingFileFor('${dir.path}/Relic.AppImage');
      expect(dir.listSync(), isEmpty);
    }, skip: onLinux ? null : 'POSIX permissions');
  });

  group('swapAppImage', () {
    test('replaces the file and leaves it executable', () {
      final dir = Directory.systemTemp.createTempSync('relic-appimg');
      addTearDown(() => dir.deleteSync(recursive: true));
      final target = '${dir.path}/Relic.AppImage';
      File(target).writeAsStringSync('old version');
      final staged = File('${dir.path}/.relic-update.AppImage')
        ..writeAsStringSync('new version');

      swapAppImage(staged, target);

      expect(File(target).readAsStringSync(), 'new version');
      expect(staged.existsSync(), isFalse, reason: 'renamed, not copied');
      // Not executable means the next launch fails, which is the one outcome
      // worse than not updating at all.
      final mode = Process.runSync('test', ['-x', target]);
      expect(mode.exitCode, 0);
    }, skip: onLinux ? null : 'POSIX file modes');

    test('the old inode survives, which is why this is safe while running', () {
      final dir = Directory.systemTemp.createTempSync('relic-appimg');
      addTearDown(() => dir.deleteSync(recursive: true));
      final target = '${dir.path}/Relic.AppImage';
      File(target).writeAsStringSync('old version');
      // Hold the old file open the way a running AppImage holds its mount.
      final held = File(target).openSync();
      addTearDown(held.closeSync);
      final staged = File('${dir.path}/.relic-update.AppImage')
        ..writeAsStringSync('new version');

      swapAppImage(staged, target);

      held.setPositionSync(0);
      expect(String.fromCharCodes(held.readSync(11)), 'old version');
      expect(File(target).readAsStringSync(), 'new version');
    }, skip: onLinux ? null : 'POSIX file semantics');
  });

  group('runningAppImage', () {
    test('is null outside an AppImage, so self-update declines', () {
      // The tests never run from one; a non-null answer here would mean
      // installUpdate tried to rename something that is not an AppImage.
      expect(runningAppImage(), isNull);
    });
  });
}

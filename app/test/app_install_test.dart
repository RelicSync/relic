import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:relic_app/platform/app_install.dart';
import 'package:relic_app/platform/src/macos/app_install_macos.dart' as mac;

/// The "you are running Relic out of the DMG" rescue is a decision made from
/// one string (the resolved executable path), so the whole contract is pinned
/// here: which paths strand a user, which are none of our business, and where
/// the bundle root is for the copy. No Mac, no disk image, no Gatekeeper.
void main() {
  group('bundleLocationFor', () {
    test('a mounted disk image is the trap we care about', () {
      expect(
        bundleLocationFor('/Volumes/Relic 1.0.33/Relic.app/Contents/MacOS/relic_app'),
        BundleLocation.diskImage,
      );
    });

    test('app translocation is the same trap wearing a temp path', () {
      expect(
        bundleLocationFor(
            '/private/var/folders/qx/1234abcd/T/AppTranslocation/8F2A-4C1B/d/Relic.app/Contents/MacOS/relic_app'),
        BundleLocation.translocated,
      );
    });

    test('anywhere writable is settled, including the odd but allowed spots', () {
      for (final path in [
        '/Applications/Relic.app/Contents/MacOS/relic_app',
        '/Users/jo/Applications/Relic.app/Contents/MacOS/relic_app',
        '/Users/jo/Desktop/Relic.app/Contents/MacOS/relic_app',
        '/Users/jo/src/relic/app/build/macos/Build/Products/Release/relic_app.app/Contents/MacOS/relic_app',
      ]) {
        expect(bundleLocationFor(path), BundleLocation.settled, reason: path);
      }
    });

    test('a folder merely named like a volume does not count', () {
      // Only a real mount lives at the root; /Users/…/Volumes/… is someone's
      // directory and none of our business.
      expect(
        bundleLocationFor('/Users/jo/Volumes/Relic.app/Contents/MacOS/relic_app'),
        BundleLocation.settled,
      );
    });
  });

  group('applicationsInstallOffer', () {
    const dmg = '/Volumes/Relic 1.0.33/Relic.app/Contents/MacOS/relic_app';

    test('a release Mac run from the disk image gets the offer', () {
      expect(
        applicationsInstallOffer(
            isMacOS: true,
            isDebug: false,
            executablePath: dmg,
            volumeWritable: false),
        BundleLocation.diskImage,
      );
    });

    test('a writable volume is somebody keeping apps on a disk, not a DMG', () {
      expect(
        applicationsInstallOffer(
            isMacOS: true,
            isDebug: false,
            executablePath:
                '/Volumes/Samsung T7/Applications/Relic.app/Contents/MacOS/relic_app',
            volumeWritable: true),
        isNull,
      );
    });

    test('translocation does not care about volume writability', () {
      const shadow =
          '/private/var/folders/qx/1234abcd/T/AppTranslocation/8F2A/d/Relic.app/Contents/MacOS/relic_app';
      for (final writable in [true, false]) {
        expect(
          applicationsInstallOffer(
              isMacOS: true,
              isDebug: false,
              executablePath: shadow,
              volumeWritable: writable),
          BundleLocation.translocated,
          reason: 'volumeWritable=$writable',
        );
      }
    });

    test('debug runs are never interrupted', () {
      expect(
        applicationsInstallOffer(
            isMacOS: true,
            isDebug: true,
            executablePath: dmg,
            volumeWritable: false),
        isNull,
      );
    });

    test('other platforms never see it', () {
      expect(
        applicationsInstallOffer(
            isMacOS: false,
            isDebug: false,
            executablePath: dmg,
            volumeWritable: false),
        isNull,
      );
      expect(
        applicationsInstallOffer(
            isMacOS: false,
            isDebug: false,
            executablePath: r'C:\Program Files\Relic\relic_app.exe',
            volumeWritable: true),
        isNull,
      );
    });

    test('an installed copy is left alone', () {
      expect(
        applicationsInstallOffer(
            isMacOS: true,
            isDebug: false,
            executablePath: '/Applications/Relic.app/Contents/MacOS/relic_app',
            volumeWritable: true),
        isNull,
      );
    });
  });

  group('volumeRootFor', () {
    test('is the mount point, spaces and all', () {
      expect(
        volumeRootFor('/Volumes/Relic 1.0.33/Relic.app/Contents/MacOS/relic_app'),
        '/Volumes/Relic 1.0.33',
      );
      expect(volumeRootFor('/Volumes/Backup'), '/Volumes/Backup');
    });

    test('is null off a mounted volume, so nothing gets probed', () {
      expect(volumeRootFor('/Applications/Relic.app'), isNull);
      expect(volumeRootFor('/Volumes/'), isNull);
    });
  });

  group('bundleRootFor', () {
    test('walks up out of Contents/MacOS', () {
      expect(
        bundleRootFor('/Volumes/Relic 1.0.33/Relic.app/Contents/MacOS/relic_app'),
        '/Volumes/Relic 1.0.33/Relic.app',
      );
    });

    test('a nested helper resolves to itself, not its host', () {
      expect(
        bundleRootFor(
            '/Applications/Relic.app/Contents/Helpers/Updater.app/Contents/MacOS/updater'),
        '/Applications/Relic.app/Contents/Helpers/Updater.app',
      );
    });

    test('an executable outside any bundle has no root to copy', () {
      expect(bundleRootFor('/usr/local/bin/relic'), isNull);
    });
  });

  // The self-update swap, against a real disk image and a scratch target —
  // hdiutil and ditto are macOS tools, so off a Mac this group is a no-op.
  // The target override exists exactly so this test never goes anywhere near
  // the real /Applications.
  group('installUpdateFromDiskImage', () {
    Future<String> makeDmg(Directory tmp, {required bool withApp}) async {
      final stage = Directory('${tmp.path}/stage')..createSync();
      if (withApp) {
        Directory('${stage.path}/Relic.app/Contents/MacOS')
            .createSync(recursive: true);
        File('${stage.path}/Relic.app/Contents/MacOS/relic_app')
            .writeAsStringSync('new-build');
      } else {
        File('${stage.path}/readme.txt').writeAsStringSync('nothing here');
      }
      final dmg = '${tmp.path}/update.dmg';
      final make = await Process.run('/usr/bin/hdiutil', [
        'create', '-srcfolder', stage.path, //
        '-volname', 'RelicTest', '-format', 'UDZO', dmg,
      ]);
      expect(make.exitCode, 0, reason: make.stderr.toString());
      return dmg;
    }

    test('swaps the target for the app inside the image, then detaches',
        () async {
      if (!Platform.isMacOS) return;
      final tmp = Directory.systemTemp.createTempSync('relic-dmg-test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final dmg = await makeDmg(tmp, withApp: true);
      // An older install sits at the target; the swap must replace it whole,
      // not merge into it (stale files beside a new binary breaks signing).
      final target = '${tmp.path}/Applications/Relic.app';
      Directory('$target/Contents').createSync(recursive: true);
      File('$target/Contents/stale').writeAsStringSync('old');

      expect(await mac.installUpdateFromDiskImage(dmg, target: target), isTrue);
      expect(
        File('$target/Contents/MacOS/relic_app').readAsStringSync(),
        'new-build',
      );
      expect(File('$target/Contents/stale').existsSync(), isFalse);
    });

    test('an image with no Relic.app fails without touching the target',
        () async {
      if (!Platform.isMacOS) return;
      final tmp = Directory.systemTemp.createTempSync('relic-dmg-test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final dmg = await makeDmg(tmp, withApp: false);
      final target = '${tmp.path}/Applications/Relic.app';
      Directory('$target/Contents').createSync(recursive: true);
      File('$target/Contents/stale').writeAsStringSync('old');

      expect(await mac.installUpdateFromDiskImage(dmg, target: target), isFalse);
      expect(File('$target/Contents/stale').readAsStringSync(), 'old');
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/platform/foreground_app.dart';
import 'package:relic_app/platform/running_apps.dart';

/// The blocklist picker's running-apps enumeration, run against the real OS
/// (flutter test executes on the host). Windows sessions can legitimately be
/// headless-ish, so content checks only apply to whatever comes back.
void main() {
  test('runningApps returns well-formed, deduped, noise-free keys', () async {
    final apps = await runningApps();
    if (!Platform.isWindows) {
      expect(apps, isEmpty);
      return;
    }
    final keys = apps.map((a) => a.key).toList();
    expect(keys.toSet().length, keys.length, reason: 'keys must be deduped');
    for (final a in apps) {
      expect(a.key, isNotEmpty);
      expect(a.key, equals(a.key.toLowerCase()),
          reason: 'keys are the lowercase stem the watcher gate compares');
      expect(a.key.endsWith('.exe'), isFalse,
          reason: 'stems have no extension');
      expect(kAppKeyNoise.contains(a.key), isFalse,
          reason: 'shell hosts are filtered from the picker');
      expect(a.title, isNotEmpty);
    }
  });

  test('picked keys round-trip through normExe unchanged', () async {
    // What the picker stores must be exactly what the gate compares: the
    // picker key normalized again must be a no-op.
    final apps = await runningApps();
    for (final a in apps) {
      expect(LocalDeskRepo.normExe(a.key), a.key);
    }
    // and the browse path ("Foo.EXE" file names) lands on the same stem
    expect(LocalDeskRepo.normExe('KeePass.EXE'), 'keepass');
    expect(LocalDeskRepo.normExe(' 1Password.exe '), '1password');
  });
}

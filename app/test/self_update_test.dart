import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/self_update.dart';
import 'package:relic_app/data/update_check.dart';

void main() {
  test('a manifest without sha256 cannot self-install (browser fallback)',
      () async {
    // Pre-sha256 manifests must route through the old open-the-download-page
    // path, never execute an unverifiable download. The full happy path
    // (download → verify → silent install → relaunch) is exercised manually
    // against a local server per docs in self_update.dart; it reinstalls the
    // app, so it stays out of CI.
    const info = UpdateInfo(version: '99.0.0', url: 'https://x.example');
    await expectLater(
        installUpdate(info), throwsA(isA<SelfUpdateUnsupported>()));
  });
}

// On-device smart tags (and its ~750 MB+ ML model download) must be off by
// default on a fresh install so no background bandwidth is used unless the user
// explicitly turns it on.
//
//   RELIC_DATA_DIR=$(mktemp -d) flutter test test/ml_enrich_default_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sandbox = Platform.environment['RELIC_DATA_DIR'];
  final guarded = sandbox == null || sandbox.toLowerCase().contains('roaming');

  test('mlEnrich is off by default on a fresh install and persists opt-in',
      () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    final prefs = File('$sandbox${Platform.pathSeparator}prefs.json');
    if (prefs.existsSync()) prefs.deleteSync();

    var repo = LocalDeskRepo();
    await repo.load();
    expect(repo.mlEnrich, isFalse);
    expect(repo.downloadingModels, isFalse);

    // Turning it on persists across launches.
    repo.setMlEnrich(true);
    expect(repo.mlEnrich, isTrue);
    expect(jsonDecode(prefs.readAsStringSync())['ml_enrich'], isTrue);
    repo.dispose();

    repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    expect(repo.mlEnrich, isTrue);
  });
}

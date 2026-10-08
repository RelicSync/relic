// Titles are on for every item by default since the t3 titler, and an older
// install (which saved both switches as off) is switched on exactly once.
//
//   RELIC_DATA_DIR=$(mktemp -d) flutter test test/describe_default_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sandbox = Platform.environment['RELIC_DATA_DIR'];
  final guarded = sandbox == null || sandbox.toLowerCase().contains('roaming');

  test('an old install is switched on once, then its choice sticks', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    final prefs = File('$sandbox${Platform.pathSeparator}prefs.json');
    prefs.writeAsStringSync(jsonEncode({'rich_captions': false, 'describe_everything': false}));

    var repo = LocalDeskRepo();
    await repo.load();
    repo.setMlEnrich(false);
    expect(repo.describeItems, isTrue);
    expect(repo.describeEverything, isTrue);
    expect(jsonDecode(prefs.readAsStringSync())['describe_all_on'], isTrue);

    // The person turns it off: that must survive the next launch.
    repo.setDescribeItems(false);
    repo.dispose();
    repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    repo.setMlEnrich(false);
    expect(repo.describeItems, isFalse);
  });
}

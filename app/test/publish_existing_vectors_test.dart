// A vault embedded before vectors travelled on AI records gets them attached
// once, so phones can search it by meaning without the desktop re-embedding.
//
//   RELIC_DATA_DIR=$(mktemp -d) flutter test test/publish_existing_vectors_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/data/relic_db.dart';
import 'package:relic_app/models/relic.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sandbox = Platform.environment['RELIC_DATA_DIR'];
  final guarded = sandbox == null || sandbox.toLowerCase().contains('roaming');

  test('existing vectors are attached once, then the pass is done', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    const model = 'embeddinggemma-300m-ft2@int8-mrl256';
    final sep = Platform.pathSeparator;
    final dbPath = '$sandbox${sep}relics.db';
    // A 1.0.59 vault: vectors from ft2, and the model already recorded.
    File('$sandbox${sep}prefs.json').writeAsStringSync('{"vector_model": "$model", "ml_enrich": false}');
    final seed = RelicDb.open(dbPath);
    seed.clearVectors();
    for (final uid in ['a', 'b', 'c']) {
      seed.upsert(Relic(
        uid: uid, createdAt: 1, updatedAt: 1, kind: Kind.string, source: Source.clipboard,
        promoted: true, byteSize: 3, device: 'd', tags: const [], content: 'item $uid', preview: 'item $uid',
      ));
      seed.upsertVectors(uid, [
        [0.6, 0.8],
      ]);
    }
    seed.dispose();
    final raw = sqlite3.open(dbPath)
      ..execute('UPDATE relics SET enrich_level = 3')
      ..execute('DELETE FROM ai_records');
    raw.dispose();

    final repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    repo.setMlEnrich(false);
    expect(repo.debugVectorModel, model);

    expect(repo.debugPublishExistingVectors(2), isTrue, reason: 'first batch');
    expect(repo.debugPublishExistingVectors(2), isTrue, reason: 'the rest');
    expect(repo.debugPublishExistingVectors(2), isFalse, reason: 'nothing left');
    expect(repo.debugVecPublishedModel, model);

    final check = sqlite3.open(dbPath);
    addTearDown(check.dispose);
    final rows = check.select('SELECT uid, vec IS NOT NULL AS has FROM ai_records ORDER BY uid');
    expect([for (final r in rows) (r['uid'], r['has'])], [('a', 1), ('b', 1), ('c', 1)]);
  });
}

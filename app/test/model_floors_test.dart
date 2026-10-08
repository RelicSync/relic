// Embedding-model swaps. Stored vectors, the tag-expansion table and the
// similarity floors all belong to one embedding model. These tests pin the
// guards that keep a model swap from quietly breaking search:
//
//   * relic-sift's preferred text model has calibrated floors,
//   * sift's reply carries the model name the guard compares,
//   * a changed model drops the old vectors, an unchanged one keeps them,
//     and the recorded model survives a restart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/data/relic_db.dart';
import 'package:relic_app/data/sift.dart';

/// The version string of the text-embedding model relic-sift prefers: the
/// first spec `text_embedding_spec` returns, looked up in models.rs.
String preferredTextModel() {
  final src = File('../relic-sift/src/models.rs').readAsStringSync();
  final fn = RegExp(r'pub fn text_embedding_spec[\s\S]*?\{[\s\S]*?&(\w+)').firstMatch(src)!;
  final spec = fn.group(1)!;
  final block = RegExp('pub const $spec: ModelSpec = ModelSpec \\{[\\s\\S]*?version: "([^"]+)"')
      .firstMatch(src)!;
  return block.group(1)!;
}

void main() {
  test('the text model relic-sift prefers has calibrated floors', () {
    final model = preferredTextModel();
    expect(
      LocalDeskRepo.modelFloors,
      contains(model),
      reason: 'Measure sem/tag floors for $model on the eval set and add a '
          'row to LocalDeskRepo.modelFloors before shipping it.',
    );
  });

  test('an unknown model falls back to the Gemma floors', () {
    expect(LocalDeskRepo.floorsFor('some-new-model'), (sem: 0.38, tag: 0.40));
    expect(LocalDeskRepo.floorsFor(null), (sem: 0.38, tag: 0.40));
  });

  test('a sift record names the model behind its vector', () {
    final r = SiftResult.fromJson({
      'category': {'primary': 'note', 'confidence': 0.9},
      'embeddings': {
        'text': {
          'model': 'embeddinggemma-300m@int8-mrl256',
          'dim': 2,
          'vector': [0.6, 0.8],
        },
      },
    });
    expect(r.textModel, 'embeddinggemma-300m@int8-mrl256');
    expect(r.textVector, [0.6, 0.8]);
  });

  final sandbox = Platform.environment['RELIC_DATA_DIR'];
  final guarded = sandbox == null || sandbox.toLowerCase().contains('roaming');

  test('sandboxed: a model change drops stored vectors, the same model keeps them', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    // A vault from before the check existed: vectors, no recorded model.
    final dbPath = '$sandbox${Platform.pathSeparator}relics.db';
    final prefs = File('$sandbox${Platform.pathSeparator}prefs.json');
    if (prefs.existsSync()) prefs.deleteSync();
    final seed = RelicDb.open(dbPath);
    seed.clearVectors();
    seed.upsertVectors('legacy-item', [
      [0.6, 0.8],
    ]);
    seed.dispose();

    var repo = LocalDeskRepo();
    await repo.load();
    repo.setMlEnrich(false);
    expect(repo.debugVectorCount, 1);
    expect(repo.debugVectorModel, isNull);

    // Same model as the vault was built with: adopted, nothing dropped.
    repo.debugNoteVectorModel(LocalDeskRepo.legacyVectorModel);
    expect(repo.debugVectorCount, 1);
    expect(repo.debugVectorModel, LocalDeskRepo.legacyVectorModel);

    // A new model: every stored vector goes, in memory and on disk.
    repo.debugNoteVectorModel('embeddinggemma-2-relic-ft1@int8-mrl256');
    expect(repo.debugVectorCount, 0);
    expect(repo.debugVectorModel, 'embeddinggemma-2-relic-ft1@int8-mrl256');
    repo.dispose();

    final check = RelicDb.open(dbPath);
    expect(check.allVectors(), isEmpty);
    check.upsertVectors('fresh-item', [
      [1.0, 0.0],
    ]);
    check.dispose();

    // The recorded model survives a restart, so a rerun keeps fresh vectors.
    repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    repo.setMlEnrich(false);
    expect(repo.debugVectorModel, 'embeddinggemma-2-relic-ft1@int8-mrl256');
    repo.debugNoteVectorModel('embeddinggemma-2-relic-ft1@int8-mrl256');
    expect(repo.debugVectorCount, 1);
  });
}

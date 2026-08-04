import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/relic_db.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/widgets/chrome.dart';

/// The vault half of open-vocabulary tag bounding (relic-sift/src/tag_vocab.rs
/// owns the snapping itself; `harness/compare_bound.py` verifies that against
/// the measured prototype). What matters here is the storage contract:
///
///  * counts accumulate per emitted STRING, while promotion is measured per
///    GROUP — a tag that only ever appears under two different spellings still
///    earns its chip;
///  * alias rows are kept, because reconcile is a silent no-op without them;
///  * reconcile rewrites the relics that used a representative which moved.
void main() {
  Relic mk(String uid, List<String> tags) => Relic(
        uid: uid,
        createdAt: 1000,
        updatedAt: 1000,
        kind: Kind.string,
        source: Source.clipboard,
        promoted: false,
        byteSize: 6,
        content: 'body $uid',
        preview: 'body $uid',
        tags: tags,
      );

  /// A stand-in for the sidecar's `added` payload — the vectors themselves are
  /// irrelevant to the DB layer, only that they round-trip.
  Map<String, List<double>> vecs(Map<String, List<double>> m) => m;

  test('counts accumulate per string but promotion is measured per group', () {
    final db = RelicDb.memory();
    // "dev" and "developer" both snap onto "development"; each is seen once.
    db.recordTagEmissions(
      ['dev'],
      {'dev': 'development'},
      vecs({'dev': [1, 0]}),
    );
    expect(db.provisionalTags(2), contains('development'),
        reason: 'one emission is not yet a facet');

    db.recordTagEmissions(
      ['developer'],
      {'developer': 'development'},
      vecs({'developer': [1, 0]}),
    );
    // Two DIFFERENT spellings, each seen once, but the group has two.
    expect(db.provisionalTags(2), isNot(contains('development')),
        reason: 'the group recurred, so the facet is earned');

    final reps = db.tagVocabReps();
    expect(reps.map((r) => r.tag), isNot(contains('dev')),
        reason: 'aliases are not representatives');
    db.dispose();
  });

  test('representatives report their whole group total, not their own count', () {
    final db = RelicDb.memory();
    db.recordTagEmissions(
      ['development', 'dev', 'dev'],
      {'development': 'development', 'dev': 'development'},
      vecs({'development': [1, 0], 'dev': [1, 0]}),
    );
    final reps = db.tagVocabReps();
    expect(reps, hasLength(1));
    expect(reps.single.tag, 'development');
    expect(reps.single.count, 3, reason: '1 + 2 across both spellings');
    expect(reps.single.vec, [1, 0], reason: 'the vector round-trips');
    db.dispose();
  });

  test('alias rows are retained — reconcile is a no-op without them', () {
    final db = RelicDb.memory();
    db.recordTagEmissions(
      ['development', 'dev'],
      {'development': 'development', 'dev': 'development'},
      vecs({'development': [1, 0], 'dev': [1, 0]}),
    );
    final all = db.tagVocabAll();
    expect(all.map((r) => r.tag).toSet(), {'development', 'dev'});
    expect(all.where((r) => r.isRepresentative).map((r) => r.tag), ['development']);
    db.dispose();
  });

  test('reconcile repoints rows and rewrites the relics that used them', () {
    final db = RelicDb.memory();
    // "dev" arrived first and became the representative — the exact drift the
    // reconcile pass exists to correct.
    db.recordTagEmissions(
      ['dev', 'development', 'development', 'development'],
      {'dev': 'dev', 'development': 'dev'},
      vecs({'dev': [1, 0], 'development': [1, 0]}),
    );
    db.upsert(mk('a', ['dev', 'note']));
    db.upsert(mk('b', ['note']));

    final touched = db.applyTagReconcile({
      'dev': 'development',
      'development': 'development',
    });

    expect(touched, 1, reason: 'only relic a carried the moved tag');
    expect(db.getByUid('a')!.tags, ['development', 'note'],
        reason: 'rewritten in place, order preserved, other tags untouched');
    expect(db.getByUid('b')!.tags, ['note']);
    final reps = db.tagVocabReps();
    expect(reps.single.tag, 'development');
    expect(reps.single.count, 4, reason: 'the whole group follows the rename');
    db.dispose();
  });

  test('reconcile collapsing two tags onto one does not duplicate the result',
      () {
    final db = RelicDb.memory();
    db.recordTagEmissions(
      ['deploy', 'deployment'],
      {'deploy': 'deploy', 'deployment': 'deployment'},
      vecs({'deploy': [1, 0], 'deployment': [1, 0]}),
    );
    // A relic carrying BOTH spellings must end up with one tag, not two.
    db.upsert(mk('a', ['deploy', 'deployment']));
    db.applyTagReconcile({'deploy': 'deployment', 'deployment': 'deployment'});
    expect(db.getByUid('a')!.tags, ['deployment']);
    db.dispose();
  });

  test('a reconcile that moves nothing touches nothing', () {
    final db = RelicDb.memory();
    db.recordTagEmissions(
      ['aws'],
      {'aws': 'aws'},
      vecs({'aws': [1, 0]}),
    );
    db.upsert(mk('a', ['aws']));
    expect(db.applyTagReconcile({'aws': 'aws'}), 0);
    expect(db.getByUid('a')!.tags, ['aws']);
    db.dispose();
  });

  test('provisional tags stay searchable — bounding never hides them from FTS',
      () {
    final db = RelicDb.memory();
    db.recordTagEmissions(
      ['roofing'],
      {'roofing': 'roofing'},
      vecs({'roofing': [1, 0]}),
    );
    db.upsert(mk('a', ['roofing']));
    // Provisional (seen once) — no chip...
    expect(db.provisionalTags(2), contains('roofing'));
    // ...but the tag is on the relic, which is what the FTS index derives from.
    expect(db.getByUid('a')!.tags, contains('roofing'));
    final hits = db.queryPage('roofing', Scope.all, 10, 0);
    expect(hits.map((r) => r.uid), contains('a'),
        reason: 'a provisional tag must still be findable');
    db.dispose();
  });
}

import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/heuristic_tags.dart';
import 'package:relic_app/data/relic_db.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/widgets/chrome.dart';

// The mobile launch rebuilds its whole search index in memory on every start,
// and an on-device trace put that at 6.1 SECONDS — more than ten times
// everything else in the launch combined (509ms from main() to a ready vault).
//
// The cause was upsert() being called in a loop: it opens its own transaction
// and re-prepares roughly eight statements from SQL text per relic. bulkLoad
// does one transaction with three reused prepared statements.
//
// These tests pin the two things that matter: the index it produces is
// EQUIVALENT to the per-relic path (a faster index that ranks differently is a
// silent search regression), and it is meaningfully faster.

Relic _mk(String uid, String content, {String? title, List<String>? tags}) =>
    Relic(
      uid: uid,
      createdAt: 1000 + uid.hashCode % 1000,
      updatedAt: 2000,
      kind: Kind.string,
      source: Source.clipboard,
      promoted: false,
      byteSize: content.length,
      tags: tags ?? detectTags(content),
      userTags: const ['mine'],
      title: title,
      content: content,
      preview: content,
    );

/// A corpus with enough shape to exercise tags, titles, and the trigram leg.
List<Relic> _corpus(int n) => List.generate(
      n,
      (i) => _mk(
        'uid-$i',
        'relic number $i about kubernetes deployment and postgres tuning '
            'https://example.com/$i user$i@example.com',
        title: i % 3 == 0 ? 'Note $i' : null,
      ),
    );

void main() {
  test('bulkLoad indexes the same corpus upsert does', () {
    final relics = _corpus(60);

    final viaUpsert = RelicDb.memory();
    for (final r in relics) {
      viaUpsert.upsert(r);
    }
    final viaBulk = RelicDb.memory();
    viaBulk.bulkLoad(relics);

    // Same rows.
    expect(viaBulk.allRows(), hasLength(relics.length));
    expect(viaBulk.countMatching('kubernetes', Scope.all),
        viaUpsert.countMatching('kubernetes', Scope.all));

    // Same lexical hits, in the same ranked order, for a spread of queries —
    // including a trigram-only one ("kubernets" is a typo) and a tag query.
    for (final q in [
      'kubernetes',
      'postgres tuning',
      'kubernets',
      'note',
      'example.com',
    ]) {
      final a =
          viaUpsert.queryPage(q, Scope.all, 20, 0).map((r) => r.uid).toList();
      final b =
          viaBulk.queryPage(q, Scope.all, 20, 0).map((r) => r.uid).toList();
      expect(b, a, reason: 'query "$q" must rank identically after bulkLoad');
      expect(b, isNotEmpty, reason: 'query "$q" should hit something');
    }

    viaUpsert.dispose();
    viaBulk.dispose();
  });

  test('bulkLoad preserves the fields the list and filters read back', () {
    final relics = _corpus(10);
    final db = RelicDb.memory();
    db.bulkLoad(relics, haveBlob: (r) => r.uid == 'uid-3');

    final rows = db.byUids(['uid-3', 'uid-7']);
    expect(rows, hasLength(2));
    final three = rows.firstWhere((r) => r.uid == 'uid-3');
    expect(three.title, 'Note 3');
    expect(three.userTags, ['mine']);
    expect(three.content, contains('kubernetes'));
    db.dispose();
  });

  // Deferring the build past first paint fixed the splash, but the work stayed
  // on the UI isolate — the list appeared and then froze for ~3s. A benchmark
  // put 2658ms of a 2900ms build in deriveIndexText (the in-prose regex
  // scanners) and only ~70ms in SQLite, so derivation moved to a background
  // isolate. These pin that the two halves still agree, and that the split is
  // real.

  test('a precomputed derive indexes identically to deriving inline', () async {
    final relics = _corpus(60);

    final inline = RelicDb.memory();
    inline.bulkLoad(relics);

    final rows = await Isolate.run(() => RelicDb.deriveIndexText(relics));
    final split = RelicDb.memory();
    split.bulkLoad(relics, derived: {for (final r in rows) r.uid: r});

    for (final q in [
      'kubernetes',
      'postgres tuning',
      'kubernets',
      'note',
      'example.com',
      'link', // aux-only: an injected concept term, never in the literal body
    ]) {
      expect(
        split.queryPage(q, Scope.all, 20, 0).map((r) => r.uid).toList(),
        inline.queryPage(q, Scope.all, 20, 0).map((r) => r.uid).toList(),
        reason: 'query "$q" must rank identically when derived off-isolate',
      );
    }
    // The aux column is the expensive part and the easiest to silently lose;
    // prove it actually landed rather than only matching an empty peer.
    expect(split.queryPage('link', Scope.all, 20, 0), isNotEmpty);

    inline.dispose();
    split.dispose();
  });

  test('a partial derive map still produces a correct index', () async {
    // bulkLoad falls back to inline derivation per missing uid, so a failed or
    // truncated isolate result degrades to slow-but-right, never to wrong.
    final relics = _corpus(20);
    final rows = await Isolate.run(() => RelicDb.deriveIndexText(relics));
    final partial = {
      for (final r in rows.take(5)) r.uid: r, // only a quarter of them
    };

    final full = RelicDb.memory()..bulkLoad(relics);
    final mixed = RelicDb.memory()..bulkLoad(relics, derived: partial);

    for (final q in ['kubernetes', 'link', 'note']) {
      expect(
        mixed.queryPage(q, Scope.all, 20, 0).map((r) => r.uid).toList(),
        full.queryPage(q, Scope.all, 20, 0).map((r) => r.uid).toList(),
        reason: 'query "$q" must survive a partial derive map',
      );
    }
    full.dispose();
    mixed.dispose();
  });

  test('the derive is the bulk of the cost, so the UI isolate keeps little',
      () async {
    // Guards the regression this split exists to prevent: if index text ever
    // starts being derived inside the insert loop again, the UI-thread half
    // balloons back and the list freezes on launch.
    final relics = _corpus(400);

    final a = RelicDb.memory();
    final inline = Stopwatch()..start();
    a.bulkLoad(relics);
    inline.stop();
    a.dispose();

    final rows = await Isolate.run(() => RelicDb.deriveIndexText(relics));
    final derived = {for (final r in rows) r.uid: r};
    final b = RelicDb.memory();
    final onMain = Stopwatch()..start();
    b.bulkLoad(relics, derived: derived);
    onMain.stop();
    b.dispose();

    expect(
      onMain.elapsedMicroseconds * 3,
      lessThan(inline.elapsedMicroseconds),
      reason: 'main-isolate half ${onMain.elapsedMilliseconds}ms vs '
          'all-inline ${inline.elapsedMilliseconds}ms — the derive split was '
          'lost, and the launch freeze is back',
    );
  });

  test('bulkLoad is substantially faster than a loop of upsert', () {
    // Guards the regression this exists to prevent: anything near parity means
    // the one-transaction / reused-statement batching was lost.
    //
    // The bar is 1.5x, not the 2x it started at. Both sides pay the same
    // derive cost, and derive is ~90% of the work, so it dilutes the ratio —
    // what bulkLoad saves is the per-row transaction and statement prepare,
    // which is real but can't show as a large multiple while it's measured
    // against a shared dominant term. The isolate-split test above is what
    // pins the cost that actually reaches the UI thread.
    final relics = _corpus(400);

    final a = RelicDb.memory();
    final slow = Stopwatch()..start();
    for (final r in relics) {
      a.upsert(r);
    }
    slow.stop();
    a.dispose();

    final b = RelicDb.memory();
    final fast = Stopwatch()..start();
    b.bulkLoad(relics);
    fast.stop();
    b.dispose();

    expect(
      (fast.elapsedMicroseconds * 3) ~/ 2,
      lessThan(slow.elapsedMicroseconds),
      reason: 'bulkLoad ${fast.elapsedMilliseconds}ms vs '
          'upsert loop ${slow.elapsedMilliseconds}ms — batching regressed',
    );
  });
}

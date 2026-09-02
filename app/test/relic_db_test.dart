import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/heuristic_tags.dart';
import 'package:relic_app/data/relic_db.dart';
import 'package:relic_app/data/repo.dart';
import 'package:relic_app/data/tag_synonyms.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/models/rich_body.dart';
import 'package:relic_app/widgets/chrome.dart';
import 'package:sqlite3/sqlite3.dart';

/// Build a relic exactly as capture would — tags computed by [detectTags].
Relic _captured(String uid, String content, {int createdAt = 1000}) => _mk(
      uid,
      content: content,
      tags: detectTags(content),
      createdAt: createdAt,
    );

Relic _mk(
  String uid, {
  String? content,
  List<String> tags = const [],
  bool promoted = false,
  int createdAt = 1000,
  String? title,
  String? note,
  Kind kind = Kind.string,
  String? blobKey,
}) =>
    Relic(
      uid: uid,
      createdAt: createdAt,
      updatedAt: createdAt,
      kind: kind,
      source: Source.clipboard,
      promoted: promoted,
      byteSize: content == null ? 0 : content.length,
      blobKey: blobKey,
      tags: tags,
      title: title,
      note: note,
      content: content,
      preview: content,
    );

void main() {
  test('pending ops are durable and ordered', () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);

    db.queueOp('b', 'push', 20);
    db.queueOp('a', 'delete', 10);
    db.queueOp('b', 'push', 30);

    expect(db.pendingCount(), 2);
    expect(db.pendingOps(), [
      (uid: 'a', op: 'delete', queuedAt: 10),
      (uid: 'b', op: 'push', queuedAt: 30),
    ]);

    db.clearOp('a', 'delete');
    expect(db.pendingOps(), [(uid: 'b', op: 'push', queuedAt: 30)]);

    db.clearOpsForUid('b');
    expect(db.pendingCount(), 0);
  });

  test('mostRecentUid is the globally-newest item, any device (paste-latest)',
      () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);

    expect(db.mostRecentUid(), isNull); // empty vault
    db.upsert(_mk('local-old', content: 'copied here yesterday', createdAt: 100));
    db.upsert(_mk('phone', content: 'screenshot from phone', createdAt: 500));
    db.upsert(_mk('local-mid', content: 'copied here', createdAt: 300));

    // Newest by created_at wins regardless of which device authored it.
    expect(db.mostRecentUid(), 'phone');
    expect(db.getByUid('phone')?.content, 'screenshot from phone');

    // A newer local capture then takes over.
    db.upsert(_mk('local-new', content: 'just copied', createdAt: 900));
    expect(db.mostRecentUid(), 'local-new');
  });

  test('nthMostRecentUid indexes the recency list for quick-paste 1-5', () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);

    expect(db.nthMostRecentUid(1), isNull); // empty vault
    db.upsert(_mk('a', content: 'a', createdAt: 100));
    db.upsert(_mk('b', content: 'b', createdAt: 200));
    db.upsert(_mk('c', content: 'c', createdAt: 300));

    // 1 = newest, counting down by created_at.
    expect(db.nthMostRecentUid(1), 'c');
    expect(db.nthMostRecentUid(2), 'b');
    expect(db.nthMostRecentUid(3), 'a');
    // Beyond the corpus (or a bad slot) is null, never a throw.
    expect(db.nthMostRecentUid(4), isNull);
    expect(db.nthMostRecentUid(0), isNull);
    // nthMostRecentUid(1) always agrees with mostRecentUid.
    expect(db.nthMostRecentUid(1), db.mostRecentUid());
  });

  test('snippetTriggers lists snippet-tagged relics with their trigger', () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);

    db.upsert(_mk('s1',
        content: 'Hey, welcome aboard!',
        title: ';welcome',
        tags: ['snippet'],
        createdAt: 100));
    db.upsert(_mk('s2',
        content: 'my mailing address',
        title: 'addr',
        tags: ['snippet'],
        createdAt: 200));
    // No title -> trigger falls back to the preview.
    db.upsert(_mk('s3',
        content: 'fallback body', tags: ['snippet'], createdAt: 50));
    db.upsert(_mk('plain', content: 'not a snippet', createdAt: 300));

    final triggers = db.snippetTriggers();
    // Only the three snippets, newest first; 'plain' is excluded.
    expect(triggers.map((t) => t.$1), ['s2', 's1', 's3']);
    expect(triggers.firstWhere((t) => t.$1 == 's1').$2, ';welcome');
    expect(triggers.firstWhere((t) => t.$1 == 's2').$2, 'addr');
    expect(triggers.firstWhere((t) => t.$1 == 's3').$2, 'fallback body');

    // vaultOnly drops unpromoted snippets.
    expect(db.snippetTriggers(vaultOnly: true), isEmpty);
  });

  test('queued retry clears prior sync rejection', () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);

    db.recordSyncRejection('r1', 'push', 402, 100);
    expect(db.rejectionCount(), 1);
    expect(db.hasPendingOrRejected('r1'), isTrue);

    db.queueOp('r1', 'push', 200);
    expect(db.rejectionCount(), 0);
    expect(db.pendingCount(), 1);
    expect(db.hasPendingOrRejected('r1'), isTrue);

    db.clearOp('r1', 'push');
    expect(db.hasPendingOrRejected('r1'), isFalse);
  });

  test('a number-tagged relic is findable by number/numeric/digits', () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);
    db.upsert(_mk('n1', content: 'order id 32562002462497 shipped',
        tags: ['number']));

    expect(db.countMatching('number', Scope.all), 1);
    expect(db.countMatching('numeric', Scope.all), 1);
    expect(db.queryPage('digits', Scope.all, 10, 0).map((r) => r.uid),
        ['n1']);
  });

  test('tag synonyms bridge concept queries to existing tags', () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);
    db.upsert(_mk('u1', content: 'https://example.com', tags: ['url']));
    db.upsert(_mk('s1', content: 'sk_live_0123456789abcdef', tags: ['secret']));

    expect(db.countMatching('link', Scope.all), 1);
    expect(db.countMatching('website', Scope.all), 1);
    expect(db.queryPage('link', Scope.all, 10, 0).map((r) => r.uid), ['u1']);

    expect(db.countMatching('password', Scope.all), 1);
    expect(db.queryPage('password', Scope.all, 10, 0).map((r) => r.uid),
        ['s1']);
  });

  test('a github link is findable by "github link" however it is embedded', () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);
    db.upsert(_captured('bare', 'https://github.com/jordan-gibbs/relic'));
    db.upsert(_captured(
        'embedded', 'check out https://github.com/jordan-gibbs/relic please'));
    db.upsert(
        _captured('markdown', '[relic](https://github.com/jordan-gibbs/relic)'));

    // All three resolve "link"/"url" via the tag synonym (bare) or the in-prose
    // entity scan (embedded/markdown) — not just the literal word "github".
    for (final q in ['github link', 'link', 'github url', 'links']) {
      expect(db.countMatching(q, Scope.all), 3, reason: 'query "$q"');
    }
  });

  group('retrieval robustness', () {
    test('stopwords: filler words do not force a strict-AND miss', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('s1',
          content: 'my saved note https://github.com/x', tags: ['url']));
      // "the"/"i" are stopwords; real terms link (in-prose synonym) + saved.
      expect(db.countMatching('the link I saved', Scope.all), 1);
    });

    test('AND→OR fallback rescues a partial multi-term query', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('sp',
          content: 'https://open.spotify.com/track/abc', tags: ['url']));
      // spotify + song (domain noun) match; "saved" does not → strict AND is
      // empty, OR fallback returns the relic.
      final page = db.queryPage('spotify song saved', Scope.all, 10, 0,
          byRelevance: true);
      expect(page.map((r) => r.uid), contains('sp'));
      expect(db.countMatching('spotify song saved', Scope.all),
          greaterThan(0));
    });

    test('strict AND still wins when it has hits (no spurious broadening)', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('both', content: 'https://github.com/x', tags: ['url']));
      db.upsert(_mk('lnk', content: 'a useful link list'));
      // Only 'both' has github AND link → AND matches it; no fallback to OR
      // (which would also pull in 'lnk').
      expect(db.countMatching('github link', Scope.all), 1);
      expect(
          db.queryPage('github link', Scope.all, 10, 0).map((r) => r.uid),
          ['both']);
    });

    test('countMatching and queryPage agree under the OR fallback', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('sp',
          content: 'https://open.spotify.com/track/abc', tags: ['url']));
      db.upsert(_mk('yt',
          content: 'https://youtu.be/xyz', tags: ['url']));
      const q = 'spotify song saved';
      final n = db.countMatching(q, Scope.all);
      final rows = db.queryPage(q, Scope.all, 100, 0);
      expect(rows.length, n);
    });

    test('phrase concatenation: "api key" / "ip address" hit one-token synonyms',
        () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('sec', content: 'sk_live_0123456789abcdef', tags: ['secret']));
      db.upsert(_mk('ip1', content: '192.168.0.1', tags: ['ip']));
      // "secret"→apikey and "ip"→ipaddress are stored concatenated; strict AND
      // on the two words misses, the concat fallback ("apikey"/"ipaddress") hits.
      expect(db.queryPage('api key', Scope.all, 10, 0).map((r) => r.uid),
          ['sec']);
      expect(db.countMatching('ip address', Scope.all), 1);
    });

    test('all-stopword query does not OR-explode to the corpus', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('a1', content: 'apple pie recipe note'));
      db.upsert(_mk('b1', content: 'banana bread loaf'));
      // "the a of" is all stopwords → kept but NOT relaxed to OR, so the prefix
      // "a"* must not pull in "apple".
      expect(db.countMatching('the a of', Scope.all), 0);
    });

    test('OR fallback honors an explicit oldest-first sort', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('old',
          content: 'https://open.spotify.com/track/a', tags: ['url'],
          createdAt: 1000));
      db.upsert(_mk('new',
          content: 'https://open.spotify.com/track/b', tags: ['url'],
          createdAt: 2000));
      final rows = db.queryPage('spotify song saved', Scope.all, 10, 0,
          oldestFirst: true);
      expect(rows.first.uid, 'old'); // date order, not bm25
    });
  });

  test('relevance ranks a concise link above a long text that contains one',
      () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);
    // The long text is NEWER, so date order would put it first.
    db.upsert(_captured('link', 'https://github.com/jordan-gibbs/relic',
        createdAt: 1000));
    final long = 'Notes from today: we shipped a lot. ${'blah ' * 80}'
        'see the repo at https://github.com/jordan-gibbs/relic for details, '
        '${'more words ' * 40}';
    db.upsert(_captured('long', long, createdAt: 2000)); // newer

    // byRelevance ranks by bm25 → the concise link (it IS the link) leads.
    final rel = db.queryPage('github link', Scope.all, 10, 0,
        byRelevance: true);
    expect(rel.first.uid, 'link');

    // Default (date) order would surface the newer long text first — the bug.
    final byDate = db.queryPage('github link', Scope.all, 10, 0);
    expect(byDate.first.uid, 'long');
  });

  group('trigram fuzzing (v7)', () {
    test('a real typo still finds the word (shared trigrams, not substring)',
        () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('k8s', content: 'kubernetes deployment rollout guide'));
      db.upsert(_mk('other', content: 'grocery list eggs milk'));

      // "kubernetse" is NOT a substring of the body — phrase-only matching
      // (the old behavior) returned nothing for it.
      final typo = db.trigramCandidates('kubernetse', Scope.all, 10);
      expect(typo.first, 'k8s');

      final recieve = RelicDb.memory();
      addTearDown(recieve.dispose);
      recieve.upsert(_mk('r1', content: 'please receive the package at noon'));
      expect(recieve.trigramCandidates('recieve', Scope.all, 10), ['r1']);
    });

    test('substring/prefix matching still works', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('k8s', content: 'kubernetes deployment'));
      expect(db.trigramCandidates('kuber', Scope.all, 10), ['k8s']);
    });

    test('trigram leg is accent-insensitive both ways', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('c1', content: 'café rendezvous on rue saint-honoré'));
      expect(db.trigramCandidates('cafe', Scope.all, 10), ['c1']);
      expect(db.trigramCandidates('café', Scope.all, 10), ['c1']);
    });

    test('synonym misspellings are NOT in the trigram body', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      // secret tag injects "passowrd" into FTS aux — the substring index must
      // not contain it (query "passow" would surface a confusing hit).
      db.upsert(_mk('s1', content: 'sk_live_abc', tags: ['secret']));
      expect(db.trigramCandidates('passow', Scope.all, 10), isEmpty);
    });
  });

  group('tag: filter exactness (v7)', () {
    test('tag:ip does not match zip/script tags, and badge count agrees', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('a', content: '10.0.0.1', tags: ['ip']));
      db.upsert(_mk('b', content: 'archive.zip attached', tags: ['zip']));
      db.upsert(_mk('c', content: 'deploy script', tags: ['script']));

      expect(db.countMatching('tag:ip', Scope.all), 1);
      expect(db.queryPage('tag:ip', Scope.all, 10, 0).single.uid, 'a');
      expect(db.countTag('ip'), db.countMatching('tag:ip', Scope.all));
    });

    test('tag matching is case-insensitive across all three matchers', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('u', content: 'x', tags: ['Reference']));
      expect(db.countTag('reference'), 1);
      expect(db.countMatching('tag:reference', Scope.all), 1);
      expect(db.uidsWithTag('reference'), ['u']);
    });
  });

  group('literal-vs-aux bm25 weighting (v7)', () {
    test('a literal content hit outranks an injected-synonym hit', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      // 'lit' literally contains "invoice"; 'syn' only gets it via the
      // receipt tag's synonym injection. Literal must lead.
      db.upsert(_mk('syn',
          content: 'Total \$41.20 thanks for shopping',
          tags: ['receipt'],
          createdAt: 2000));
      db.upsert(_mk('lit',
          content: 'invoice #221 for consulting services',
          createdAt: 1000));
      final rows =
          db.queryPage('invoice', Scope.all, 10, 0, byRelevance: true);
      expect(rows.map((r) => r.uid).toList(), ['lit', 'syn']);
    });

    test('aux synonyms still make tagged relics findable', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('r1', content: 'Total \$41.20', tags: ['receipt']));
      expect(db.countMatching('invoice', Scope.all), 1);
    });

    test('user tags get synonym expansion too', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      final r = _mk('u1', content: 'Total \$9.99');
      db.upsert(Relic(
        uid: r.uid,
        createdAt: r.createdAt,
        updatedAt: r.updatedAt,
        kind: r.kind,
        source: r.source,
        promoted: false,
        byteSize: r.byteSize,
        content: r.content,
        preview: r.preview,
        userTags: const ['receipt'],
      ));
      expect(db.countMatching('invoice', Scope.all), 1);
    });

    test('heavy tagging cannot bury a relic for its own literal word', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      // Same literal content; one relic carries many tags (lots of injected
      // aux terms). The tagged one must not sink below an untagged twin that
      // shares fewer of the query's signals.
      db.upsert(_mk('tagged',
          content: 'stripe webhook retry logic',
          tags: ['code', 'url', 'json', 'error', 'command'],
          createdAt: 1000));
      db.upsert(_mk('plain',
          content: 'random note mentioning stripe once in passing '
              'with a lot of extra words around it',
          createdAt: 2000));
      final rows = db.queryPage('stripe webhook', Scope.all, 10, 0,
          byRelevance: true);
      expect(rows.first.uid, 'tagged');
    });
  });

  group('query-side synonym expansion (fallback rung)', () {
    test('"pw" finds literal password content that never earned a tag', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('p1', content: 'the password is hunter2'));
      expect(db.countMatching('pw', Scope.all), 1);
      expect(db.queryPage('pw', Scope.all, 10, 0).single.uid, 'p1');
    });

    test('expansion never runs when the literal query already hits', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('lit', content: 'pw gauge reading 15 psi'));
      db.upsert(_mk('syn', content: 'the password is hunter2'));
      // Literal "pw" exists → precise result only, no synonym flood.
      expect(db.queryPage('pw', Scope.all, 10, 0).single.uid, 'lit');
      expect(db.countMatching('pw', Scope.all), 1);
    });

    test('a misspelled concept query still resolves', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('r1', content: 'receipt from the hardware store'));
      expect(db.countMatching('reciept', Scope.all), 1);
    });

    test('ambiguous synonyms never expand', () {
      // "social" is listed under both ssn and handle — expanding a
      // social-media search into SSN relics would be a privacy footgun.
      expect(kSynonymExpansions['social'], isNull);
      expect(kSynonymExpansions['location'], isNull); // path vs geo vs address
      // Unambiguous entries expand to [canonical synonym, tag word].
      expect(kSynonymExpansions['pw'], contains('password'));
      expect(kSynonymExpansions['reciept'], contains('receipt'));
    });
  });

  group('query language (round 2)', () {
    test('quoted phrases require adjacency and order', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('adj', content: 'rotate the api key monthly'));
      db.upsert(_mk('far', content: 'the api needs a new cache key'));
      // Loose AND matches both; the quoted phrase only the adjacent one.
      expect(db.countMatching('api key', Scope.all), 2);
      expect(db.queryPage('"api key"', Scope.all, 10, 0).single.uid, 'adj');
      expect(db.countMatching('"api key"', Scope.all), 1);
      // Order matters inside quotes.
      expect(db.countMatching('"key api"', Scope.all), 0);
    });

    test('-word excludes, and pure negation returns nothing', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('s', content: 'stripe invoice for march'));
      db.upsert(_mk('p', content: 'paypal invoice for march'));
      expect(db.queryPage('invoice -stripe', Scope.all, 10, 0).single.uid, 'p');
      expect(db.countMatching('invoice -stripe', Scope.all), 1);
      expect(db.countMatching('-stripe', Scope.all), 0); // no positives
      // A hyphenated WORD is not a negation.
      final h = RelicDb.memory();
      addTearDown(h.dispose);
      h.upsert(_mk('h1', content: 'sign up for the e-mail list'));
      expect(h.countMatching('e-mail', Scope.all), 1);
    });

    test('compact digit query finds a separated number', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_captured('ph', 'call bob at 555-123-4567 tomorrow'));
      expect(db.countMatching('5551234567', Scope.all), 1);
      // Reverse direction (separated query, compact body) via the concat rung.
      final c = RelicDb.memory();
      addTearDown(c.dispose);
      c.upsert(_captured('cp', 'code 5551234567'));
      expect(c.countMatching('555 123 4567', Scope.all), 1);
    });

    test('device label is searchable', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(Relic(
        uid: 'd1',
        createdAt: 1000,
        updatedAt: 1000,
        kind: Kind.string,
        source: Source.clipboard,
        promoted: false,
        byteSize: 5,
        device: "Jordan's S21",
        content: 'hello',
        preview: 'hello',
      ));
      expect(db.countMatching('s21', Scope.all), 1);
    });
  });

  group('attachment text (round 2)', () {
    test('setAttachmentText indexes into FTS + trigram and marks done', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      final r = Relic(
        uid: 'a1',
        createdAt: 1000,
        updatedAt: 1000,
        kind: Kind.string,
        source: Source.upload,
        promoted: false,
        byteSize: 10,
        content: 'see attached',
        preview: 'see attached',
        attachments: const [
          Attachment(id: 'x', name: 'lease.pdf', mime: 'application/pdf', size: 9),
        ],
      );
      db.upsert(r);
      expect(db.attachmentsNeedingText(10), ['a1']);
      expect(db.countMatching('termination', Scope.all), 0);

      db.setAttachmentText('a1', 'early termination clause: 60 days notice');
      expect(db.countMatching('termination', Scope.all), 1);
      expect(db.trigramCandidates('terminatoin', Scope.all, 10), ['a1']);
      expect(db.attachmentsNeedingText(10), isEmpty);

      // '' marks "extracted, nothing to index" — backlog must not retry.
      db.setAttachmentText('a1', '');
      expect(db.attachmentsNeedingText(10), isEmpty);
    });

    test('attachment text survives an ordinary upsert', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('a2', content: 'note'));
      db.setAttachmentText('a2', 'quarterly budget figures');
      db.upsert(_mk('a2', content: 'note edited'));
      expect(db.countMatching('budget', Scope.all), 1);
    });
  });

  test('a content edit reindexes search onto the NEW body', () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);
    final r = _mk('e1', content: 'the quick brown fox');
    db.upsert(r);
    expect(db.countMatching('fox', Scope.all), 1);
    // Mirror updateMeta: a body edit recomputes the preview too, or the old
    // text would linger in the index through it.
    db.upsert(r.copyWith(
        content: 'a slow green turtle', preview: 'a slow green turtle'));
    expect(db.countMatching('fox', Scope.all), 0); // old body gone from FTS
    expect(db.countMatching('turtle', Scope.all), 1);
    expect(db.trigramCandidates('turtl', Scope.all, 5), ['e1']);
  });

  test('byRecency orders a uid set newest-first', () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);
    db.upsert(_mk('old', content: 'x', createdAt: 100));
    db.upsert(_mk('mid', content: 'x', createdAt: 200));
    db.upsert(_mk('new', content: 'x', createdAt: 300));
    expect(db.byRecency(['old', 'new', 'mid']), ['new', 'mid', 'old']);
  });

  test('touch resurfaces a re-copied item (created_at moves too)', () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);
    db.upsert(_mk('link', content: 'https://example.com/x', createdAt: 100));
    db.upsert(_mk('other', content: 'y', createdAt: 200));
    expect(db.byRecency(['link', 'other']), ['other', 'link']);

    // Re-copying existing content dedupes to touch(). Every list surface
    // (popup, mobile, web vault, CLI) orders by created_at, so touch must
    // move BOTH stamps — an updated_at-only bump leaves the item buried and
    // the re-copy looks like a dropped capture.
    db.touch('link', 300, queuePush: true);
    final r = db.getByUid('link')!;
    expect(r.createdAt, 300);
    expect(r.updatedAt, 300);
    expect(db.byRecency(['link', 'other']), ['link', 'other']);
    // The bump also syncs (created_at rides in the plaintext envelope).
    expect(db.pendingOps(), [(uid: 'link', op: 'push', queuedAt: 300)]);
  });

  group('tag lifecycle guards (verification round)', () {
    test('corpus delete records lowercased suppression, case-insensitively',
        () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('a', content: 'x', tags: ['MP3', 'Audio']));
      expect(db.deleteTag('mp3', userTag: false), 1); // matches 'MP3'
      expect(db.getByUid('a')!.tags, ['Audio']);
      expect(db.suppressedTags('a'), ['mp3']); // stored lowercased
    });

    test('case-only rename keeps the tag and records NO suppression', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('a', content: 'x', tags: ['MP3']));
      expect(db.renameTag('MP3', 'mp3', userTag: false), 1);
      expect(db.getByUid('a')!.tags, ['mp3']);
      expect(db.suppressedTags('a'), isEmpty);
    });

    test('real rename suppresses the old name', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('a', content: 'x', tags: ['MP3']));
      expect(db.renameTag('mp3', 'audio', userTag: false), 1);
      expect(db.getByUid('a')!.tags, ['audio']);
      expect(db.suppressedTags('a'), ['mp3']);
    });

    test('retagInPlace refuses machine secret as source or target', () {
      final items = [
        _mk('s', content: 'sk_live_x', tags: ['secret', 'code']),
      ];
      expect(retagInPlace(items, 'secret', null, false), 0);
      expect(retagInPlace(items, 'code', 'secret', false), 0);
      expect(items.first.tags, ['secret', 'code']); // untouched
      expect(retagInPlace(items, 'code', 'snippet', false), 1); // normal ok
    });
  });

  test('suppressed tags survive upsert and round-trip', () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);
    final r = _mk('s1', content: 'x', tags: ['code']);
    db.upsert(r);
    expect(db.suppressedTags('s1'), isEmpty);
    db.setSuppressedTags('s1', ['code']);
    expect(db.suppressedTags('s1'), ['code']);
    // upsert (sync merge, edits, enrichment) must not clear suppression.
    db.upsert(r.copyWith(title: 'renamed'));
    expect(db.suppressedTags('s1'), ['code']);
    db.setSuppressedTags('s1', const []);
    expect(db.suppressedTags('s1'), isEmpty);
  });

  test('"it" is a real search term, not a stopword', () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);
    db.upsert(_mk('it1', content: 'IT ticket 4521 filed with helpdesk'));
    db.upsert(_mk('c1', content: 'concert ticket for saturday'));
    // "it ticket" must AND both words — only the IT relic matches.
    expect(db.queryPage('it ticket', Scope.all, 10, 0).single.uid, 'it1');
  });

  group('chunked vectors (v7)', () {
    test('upsertVectors round-trips chunk rows and replaces atomically', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsertVectors('u1', [
        [1.0, 0.0],
        [0.0, 1.0],
        [0.5, 0.5],
      ]);
      expect(db.vectorCount, 1); // distinct uids, not rows
      var rows = db.allVectors();
      expect(rows.length, 3);
      expect(rows.map((r) => r.chunk).toList(), [0, 1, 2]);
      expect(rows.first.vec, [1.0, 0.0]);

      // Re-upsert with a single vector → old chunks fully replaced.
      db.upsertVector('u1', [0.9, 0.1]);
      rows = db.allVectors();
      expect(rows.length, 1);
      expect(rows.single.chunk, 0);
    });

    test('promotedUids returns the vault allow-set', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('v1', content: 'a', promoted: true));
      db.upsert(_mk('s1', content: 'b'));
      expect(db.promotedUids(), {'v1'});
    });
  });

  test('v7 migration upgrades a v6 database in place', () async {
    final dir = await Directory.systemTemp.createTemp('relicdb-v7');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}relics.db';

    // Seed a real DB, then hand-revert it to the pre-v7 shape: 3-column FTS,
    // uid-keyed vectors, user_version = 6.
    final seeded = RelicDb.open(path);
    seeded.upsert(_mk('r1', content: 'Total \$41.20', tags: ['receipt']));
    seeded.dispose();
    final raw = sqlite3.open(path);
    raw.execute('DROP TABLE relics_fts');
    raw.execute('''CREATE VIRTUAL TABLE relics_fts USING fts5(
        uid UNINDEXED, body, tags, tokenize = 'porter unicode61');''');
    raw.execute('DROP TABLE vectors');
    raw.execute('''CREATE TABLE vectors (
        uid TEXT PRIMARY KEY, dim INTEGER NOT NULL, vec BLOB NOT NULL);''');
    raw.execute('INSERT INTO vectors (uid, dim, vec) VALUES (?,?,?)', [
      'r1',
      2,
      Float32List.fromList([0.5, 0.25]).buffer.asUint8List(),
    ]);
    raw.execute('PRAGMA user_version = 6');
    raw.dispose();

    // Reopen → the v7 migration must run.
    final db = RelicDb.open(path);
    addTearDown(db.dispose);
    // Old vector preserved as chunk 0 of the new (uid, chunk) key.
    final vecs = db.allVectors();
    expect(vecs.single.uid, 'r1');
    expect(vecs.single.chunk, 0);
    expect(vecs.single.vec, [0.5, 0.25]);
    // FTS rebuilt with the aux column: synonym search works post-migration.
    expect(db.countMatching('invoice', Scope.all), 1);
    final check = sqlite3.open(path);
    addTearDown(check.dispose);
    // The chain runs to the CURRENT latest version (v8-v10 reconcile stale
    // detector tags on the way, v11 splits the named FTS column).
    expect(check.select('PRAGMA user_version').first.values.first, 11);
  });

  test('v8 migration strips stale value-shape tags, keeps real ones', () async {
    final dir = await Directory.systemTemp.createTemp('relicdb-v8');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}relics.db';

    final seeded = RelicDb.open(path);
    // A long document that merely MENTIONS a percent — the old detector
    // tagged it `percent`; simulate that stale state below. ('data' is a sift
    // ML tag, i.e. NOT detector vocabulary — migrations must never touch
    // other producers' tags.)
    final doc = 'quarterly report: revenue grew, and churn fell by 3% '
        '${'more words ' * 30}';
    seeded.upsert(_mk('doc', content: doc, tags: ['data', 'percent']));
    // A naked value keeps its tag.
    seeded.upsert(_mk('naked', content: '15% off', tags: ['percent']));
    // Secret-class is never touched by the strip.
    seeded.upsert(_mk('sec',
        content: 'sk_live_0123456789abcdef', tags: ['secret', 'number']));
    seeded.dispose();
    final raw = sqlite3.open(path);
    raw.execute('PRAGMA user_version = 7'); // pretend v8/v9 haven't run
    raw.dispose();

    final db = RelicDb.open(path);
    addTearDown(db.dispose);
    expect(db.getByUid('doc')!.tags, ['data']); // stale percent gone
    expect(db.getByUid('naked')!.tags, contains('percent'));
    expect(db.getByUid('sec')!.tags, contains('secret'));
  });

  test('v9 migration reconciles detector tags both directions', () async {
    final dir = await Directory.systemTemp.createTemp('relicdb-v9');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}relics.db';

    final seeded = RelicDb.open(path);
    // Stale in-prose class: prose that merely CONTAINS a link — the old loose
    // detector tagged it `url`.
    seeded.upsert(_mk('prose',
        content: 'a long essay about focus and craft, with one reference '
            'to https://example.com/post tucked mid-paragraph '
            '${'and plenty more words ' * 8}',
        tags: ['url']));
    // Recall gain: commands the detector recognizes today.
    seeded.upsert(
        _mk('kube', content: 'kubectl get pods -n production --watch'));
    // Suppression is honored on merge: this relic WOULD gain `command`, but
    // the user removed it once.
    seeded.upsert(
        _mk('sup', content: 'kubectl describe deployment relic-api'));
    seeded.setSuppressedTags('sup', ['command']);
    seeded.dispose();
    final raw = sqlite3.open(path);
    raw.execute('PRAGMA user_version = 8'); // pretend only v9 is pending
    raw.dispose();

    final db = RelicDb.open(path);
    addTearDown(db.dispose);
    expect(db.getByUid('prose')!.tags, isNot(contains('url')));
    expect(db.getByUid('kube')!.tags, contains('command'));
    expect(db.getByUid('sup')!.tags, isNot(contains('command')));
  });

  test('v10 migration cleans blob-relic stale tags + case dupes', () async {
    final dir = await Directory.systemTemp.createTemp('relicdb-v10');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}relics.db';

    final seeded = RelicDb.open(path);
    // A photo whose OCR caption was tagged `code` by the old detector; the
    // current detector finds nothing code-like in it.
    seeded.upsert(Relic(
      uid: 'photo1',
      createdAt: 1000,
      updatedAt: 1000,
      kind: Kind.photo,
      source: Source.clipboard,
      promoted: false,
      byteSize: 10,
      content: 'a golden retriever runs across a sunny lawn',
      preview: 'a golden retriever runs across a sunny lawn',
      tags: const ['photo', 'code'],
    ));
    // A file carrying both the ext chip and the detector tag (case dupe) —
    // first occurrence (the chip) wins.
    seeded.upsert(Relic(
      uid: 'file1',
      createdAt: 1000,
      updatedAt: 1000,
      kind: Kind.file,
      source: Source.upload,
      promoted: false,
      byteSize: 10,
      filename: 'notes.md',
      content: '# heading\n\nsome markdown body',
      preview: 'notes.md',
      tags: const ['Document', 'Markdown', 'markdown'],
    ));
    seeded.dispose();
    final raw = sqlite3.open(path);
    raw.execute('PRAGMA user_version = 9'); // pretend only v10 is pending
    raw.dispose();

    final db = RelicDb.open(path);
    addTearDown(db.dispose);
    expect(db.getByUid('photo1')!.tags, ['photo']); // stale `code` gone
    expect(db.getByUid('file1')!.tags, ['Document', 'Markdown']);
  });

  group('lexicalHybridUids (shared ML-free hybrid — powers mobile search)', () {
    test('a concise exact match outranks a long doc that merely contains it', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_captured('short', 'kubernetes', createdAt: 100));
      db.upsert(_captured(
          'long',
          'a very long note that happens to mention kubernetes somewhere in the '
              'middle of a great deal of other unrelated words and sentences',
          createdAt: 200)); // newer, but should NOT win on relevance
      final ranked = db.lexicalHybridUids('kubernetes', Scope.all);
      expect(ranked, isNotNull);
      expect(ranked!.first, 'short', reason: 'bm25 length-norm ranks concise first');
      expect(ranked, containsAll(['short', 'long']));
    });

    test('a typo still finds the item via the trigram leg', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_captured('k', 'kubernetes deployment guide'));
      // "kubernetse" (transposed) shares most trigrams with "kubernetes".
      final ranked = db.lexicalHybridUids('kubernetse', Scope.all);
      expect(ranked, isNotNull);
      expect(ranked, contains('k'));
    });

    test('empty query returns null (nothing to rank)', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_captured('a', 'hello world'));
      expect(db.lexicalHybridUids('   ', Scope.all), isNull);
    });

    test('rrfFuse rewards agreement across legs', () {
      // 'x' appears in both lists; 'y' only in one — 'x' should rank first.
      final fused = RelicDb.rrfFuse([
        ['x', 'y'],
        ['x', 'z'],
      ]);
      expect(fused.first, 'x');
      expect(fused, containsAll(['x', 'y', 'z']));
    });
  });

  group('tag-intent leg (type-word queries)', () {
    test('tagIntentOf resolves tag words, synonyms, and plurals', () {
      expect(tagIntentOf('url'), 'url');
      expect(tagIntentOf('link'), 'url');
      expect(tagIntentOf('links'), 'url'); // singularized
      expect(tagIntentOf('Link'), 'url'); // case-folded
      expect(tagIntentOf('screenshot'), 'screenshot');
      // A tag word that is ALSO a synonym under another tag stays itself.
      expect(tagIntentOf('chart'), 'chart');
      // Ambiguous synonyms (listed under several tags) never resolve.
      expect(tagIntentOf('social'), isNull);
      // Ordinary words name nothing.
      expect(tagIntentOf('banana'), isNull);
      expect(tagIntentOf('relic'), isNull);
    });

    test('items that ARE the named type outrank items that merely say its word',
        () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      // An actual link about relic (tag: url), older…
      db.upsert(_captured('thelink', 'https://relic.space/privacy',
          createdAt: 100));
      // …vs a newer long OCR-ish doc whose body literally contains both
      // query words several times (the screenshot-of-the-app failure mode).
      db.upsert(_captured(
          'ocr',
          'a screenshot of the relic app window showing the relic vault with '
              'a share link button and another link and the word relic again '
              'across a very long stretch of recognized interface text',
          createdAt: 200));
      expect(db.getByUid('thelink')!.tags, contains('url'));

      final ranked = db.lexicalHybridUids('relic link', Scope.all)!;
      expect(ranked.first, 'thelink',
          reason: 'tag-intent puts the real link above the doc that says "link"');
      expect(ranked, contains('ocr'));
    });

    test('residual filters INSIDE the tag set; a residual miss adds nothing',
        () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_captured('r1', 'https://relic.space', createdAt: 100));
      db.upsert(_captured('g1', 'https://github.com/foo', createdAt: 200));

      // Residual "relic" keeps only the relic link in the leg.
      expect(db.tagIntentCandidates('relic link', Scope.all, 10), ['r1']);
      // A residual that matches no tagged item must NOT degrade to a tag dump.
      expect(db.tagIntentCandidates('banana link', Scope.all, 10), isEmpty);
      // No tag named → the leg stays out of the fusion entirely.
      expect(db.tagIntentCandidates('banana split', Scope.all, 10), isEmpty);
      // Quoted queries mean literal text, not type intent.
      expect(db.tagIntentCandidates('"relic link"', Scope.all, 10), isEmpty);
    });

    test('a pure type-word query lists the tag items newest-first', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_captured('old', 'https://a.example', createdAt: 100));
      db.upsert(_captured('new', 'https://b.example', createdAt: 200));
      db.upsert(_captured('txt', 'no links here at all', createdAt: 300));

      expect(db.tagIntentCandidates('links', Scope.all, 10), ['new', 'old']);
    });

    test('vault scope restricts the leg to promoted items', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('kept', content: 'https://relic.space', tags: ['url'],
          promoted: true, createdAt: 100));
      db.upsert(_mk('hist', content: 'https://relic.dev', tags: ['url'],
          createdAt: 200));

      expect(db.tagIntentCandidates('links', Scope.vault, 10), ['kept']);
      expect(db.tagIntentCandidates('relic link', Scope.vault, 10), ['kept']);
    });
  });

  group('named FTS column (v11)', () {
    test('a word in a hand-written title outranks it buried in a long body',
        () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk(
          'ocr',
          content:
              'a very long recognized text that mentions the stripe webhook '
              'endpoint somewhere in the middle of a great many other words '
              'about invoices customers payments and configuration',
          createdAt: 200)); // newer
      db.upsert(_mk('named',
          content: 'https://dashboard.stripe.com/webhooks/we_123',
          title: 'stripe webhook endpoint',
          createdAt: 100));

      final page =
          db.queryPage('stripe webhook', Scope.all, 10, 0, byRelevance: true);
      expect(page.first.uid, 'named',
          reason: 'annotation must pay off — the named item leads');
      expect(page.map((r) => r.uid), containsAll(['named', 'ocr']));
    });

    test('a note makes an unrelated body findable AND ranked first', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('noted', content: '4111 1111 1111 1111',
          note: 'hetzner root password reminder', createdAt: 100));
      db.upsert(_mk('plain',
          content: 'the hetzner invoice arrived yesterday', createdAt: 200));

      final page = db.queryPage('hetzner', Scope.all, 10, 0, byRelevance: true);
      expect(page.first.uid, 'noted');
    });
  });

  group('query operators (kind:/is:/has:)', () {
    RelicDb seed() {
      final db = RelicDb.memory();
      db.upsert(_mk('txt', content: 'stripe invoice text', createdAt: 100));
      db.upsert(_mk('img',
          content: 'a stripe dashboard screenshot',
          kind: Kind.photo,
          blobKey: 'b1',
          createdAt: 200));
      db.upsert(_mk('kept',
          content: 'stripe api key rotation runbook',
          promoted: true,
          createdAt: 300));
      return db;
    }

    test('kind: filters by kind, with web-style aliases', () {
      final db = seed();
      addTearDown(db.dispose);
      expect(db.queryPage('stripe kind:image', Scope.all, 10, 0)
          .map((r) => r.uid), ['img']);
      expect(db.queryPage('stripe kind:text', Scope.all, 10, 0)
          .map((r) => r.uid), ['kept', 'txt']);
      expect(db.countMatching('stripe kind:image', Scope.all), 1);
      // Unknown kind matches nothing (mirrors the web).
      expect(db.countMatching('stripe kind:banana', Scope.all), 0);
    });

    test('is:kept and has:file filter; unknown values stay literal text', () {
      final db = seed();
      addTearDown(db.dispose);
      expect(db.queryPage('stripe is:kept', Scope.all, 10, 0)
          .map((r) => r.uid), ['kept']);
      expect(db.queryPage('stripe has:file', Scope.all, 10, 0)
          .map((r) => r.uid), ['img']);
      expect(db.queryPage('stripe has:blob', Scope.all, 10, 0)
          .map((r) => r.uid), ['img']);
      // is:elsewhere is NOT an operator: it stays free text, so it must not
      // FILTER anything — the OR-recall rung still matches all three stripe
      // items (same as the web, where an unknown token is just a term).
      expect(db.countMatching('stripe is:elsewhere', Scope.all), 3);
    });

    test('operator-only query browses date-ordered under the filter', () {
      final db = seed();
      addTearDown(db.dispose);
      expect(db.queryPage('is:kept', Scope.all, 10, 0).map((r) => r.uid),
          ['kept']);
      expect(db.queryPage('kind:image', Scope.all, 10, 0).map((r) => r.uid),
          ['img']);
      expect(db.countMatching('has:file', Scope.all), 1);
    });

    test('operators compose with tag: and count/page agree', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('a', content: 'https://x.example/report',
          tags: ['url'], createdAt: 100));
      db.upsert(_mk('b', content: 'https://x.example/report',
          tags: ['url'], promoted: true, createdAt: 200));
      expect(db.queryPage('tag:url is:kept', Scope.all, 10, 0)
          .map((r) => r.uid), ['b']);
      expect(db.countMatching('tag:url is:kept', Scope.all), 1);
    });
  });

  group('kept boost factor', () {
    test('a kept item wins the tie against an identical newer history item',
        () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('kept', content: 'meeting notes alpha',
          promoted: true, createdAt: 100));
      db.upsert(_mk('hist', content: 'meeting notes alpha', createdAt: 200));

      final ranked = db.lexicalHybridUids('meeting notes', Scope.all)!;
      expect(ranked.first, 'kept',
          reason: 'deliberately saved beats clipboard noise on a tie');
    });

    test('kept boost cannot resurrect a match that misses query terms', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(
          _mk('exact', content: 'docker compose up -d', createdAt: 100));
      db.upsert(_mk('kept-weak',
          content: 'a long saved note about docker deployment strategies '
              'and staged rollout plans across environments',
          promoted: true,
          createdAt: 200)); // matches only "docker", newer AND kept

      final ranked = db.lexicalHybridUids('docker compose', Scope.all)!;
      expect(ranked.first, 'exact',
          reason: 'a 5% factor flips near-ties, not term misses');
    });
  });

  group('usage frecency (cornerstone boost)', () {
    const hl = RelicDb.kUseHalfLifeSecs;

    test('decayedUse halves per half-life and recordUse decays-then-adds', () {
      // Pure math first.
      expect(RelicDb.decayedUse(4.0, 1000, 1000), 4.0);
      expect(RelicDb.decayedUse(4.0, 1000, 1000 + hl), closeTo(2.0, 1e-9));
      expect(RelicDb.decayedUse(4.0, 1000, 1000 + 2 * hl), closeTo(1.0, 1e-9));
      expect(RelicDb.decayedUse(0, null, 1000), 0);

      // Stored state: three touches at t0, one a half-life later —
      // 3 * 0.5 + 1 = 2.5 effective touches.
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('r1', content: 'x'));
      for (var i = 0; i < 3; i++) {
        db.recordUse('r1', 1000);
      }
      db.recordUse('r1', 1000 + hl);
      expect(db.useFactors(['r1'], 1000 + hl)['r1'],
          closeTo(RelicDb.useFactor(2.5), 1e-9));
      // recordUse on an unknown uid is a no-op, not a crash.
      db.recordUse('ghost', 1000);
      expect(db.useFactors(['ghost'], 1000), isEmpty);
    });

    test('useFactor is 1 at zero, monotone, and capped below the max', () {
      expect(RelicDb.useFactor(0), 1.0);
      expect(RelicDb.useFactor(RelicDb.kUseBoostHalf),
          closeTo(1.0 + RelicDb.kUseBoostMax / 2, 1e-9)); // half the cap
      var prev = 1.0;
      for (final d in [0.5, 1.0, 3.0, 10.0, 50.0, 1000.0]) {
        final f = RelicDb.useFactor(d);
        expect(f, greaterThan(prev));
        expect(f, lessThan(1.0 + RelicDb.kUseBoostMax));
        prev = f;
      }
    });

    test('untouched items never appear in useFactors', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('quiet', content: 'x'));
      expect(db.useFactors(['quiet'], 1000), isEmpty);
    });

    test('rrfFuse factors flip a tie but ignore uids no leg found', () {
      // x and y tie perfectly (each first in one list, second in the other).
      final tied = RelicDb.rrfFuse([
        ['x', 'y'],
        ['y', 'x'],
      ]);
      expect(tied.first, 'x'); // uid tiebreak
      final boosted = RelicDb.rrfFuse([
        ['x', 'y'],
        ['y', 'x'],
      ], factors: {
        'y': 1.25,
        'ghost': 9.0, // not a candidate — must not appear
      });
      expect(boosted.first, 'y');
      expect(boosted, isNot(contains('ghost')));
    });

    test('an often-touched twin outranks the newer identical item', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('corner', content: 'meeting notes alpha', createdAt: 100));
      db.upsert(_mk('fresh', content: 'meeting notes alpha', createdAt: 200));

      // Identical content: bm25 ties, so the untouched order hinges on FTS
      // tie order (unspecified) + the recency leg — assert only membership.
      var ranked = db.lexicalHybridUids('meeting notes', Scope.all, now: 300)!;
      expect(ranked, containsAll(['corner', 'fresh']));

      // 10 touches → factor ~1.17, an order of magnitude above the largest
      // edge any tie order + recency can give the fresh twin (~1.7%).
      for (var i = 0; i < 10; i++) {
        db.recordUse('corner', 250);
      }
      ranked = db.lexicalHybridUids('meeting notes', Scope.all, now: 300)!;
      expect(ranked.first, 'corner',
          reason: 'the usage factor outweighs the recency-leg edge');
    });

    test('usage cannot surface an item the query does not match', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('corner', content: 'ssh key for the build server',
          createdAt: 100));
      db.upsert(_mk('match', content: 'grocery list eggs milk',
          createdAt: 200));
      for (var i = 0; i < 50; i++) {
        db.recordUse('corner', 250);
      }
      final ranked = db.lexicalHybridUids('grocery list', Scope.all, now: 300)!;
      expect(ranked, contains('match'));
      expect(ranked, isNot(contains('corner')),
          reason: 'the boost is a multiplier on matches, never a leg');
    });

    test('a stale ex-favorite fades back to parity', () {
      // 20 touches, then a year untouched → ~0.005 effective touches; the
      // factor decays into rounding noise instead of pinning the item forever.
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('stale', content: 'meeting notes alpha', createdAt: 100));
      for (var i = 0; i < 20; i++) {
        db.recordUse('stale', 300);
      }
      expect(db.useFactors(['stale'], 300)['stale'],
          greaterThan(1.15)); // a real boost while hot
      final yearLater = 300 + 12 * hl;
      final faded = db.useFactors(['stale'], yearLater)['stale'] ?? 1.0;
      expect(faded, lessThan(1.001)); // within tie-break noise of no boost
    });
  });

  group('personalized ranking (query-pick + context memory)', () {
    test('memoryTerms cleans like search: stopwords, operators, cap', () {
      expect(RelicDb.memoryTerms('the stripe webhook I saved'),
          ['stripe', 'webhook', 'saved']);
      // Operator clauses drop whole — neither "tag" nor "url" is stored.
      expect(RelicDb.memoryTerms('tag:url stripe kind:image'), ['stripe']);
      expect(RelicDb.memoryTerms('tag:url'), isEmpty);
      // One-letter terms dropped, cap at 6.
      expect(RelicDb.memoryTerms('a b cd ef gh ij kl mn op'),
          ['cd', 'ef', 'gh', 'ij', 'kl', 'mn']);
    });

    test('query-pick memory learns and outranks the recency edge', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('corner', content: 'meeting notes alpha', createdAt: 100));
      db.upsert(_mk('fresh', content: 'meeting notes alpha', createdAt: 200));

      // Two picks of the older twin while searching "meeting".
      db.recordQueryPick('meeting', 'corner', 250);
      db.recordQueryPick('meeting', 'corner', 260);
      final ranked =
          db.lexicalHybridUids('meeting notes', Scope.all, now: 300)!;
      expect(ranked.first, 'corner',
          reason: 'picked twice for this term beats any tie-order edge');

      // A query sharing no stored term earns no factor at all.
      expect(
          db.rankFactors(['corner', 'fresh'], query: 'unrelated words',
              now: 300)['corner'],
          isNull);
    });

    test('query-pick counters decay-then-add like usage', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('r1', content: 'x'));
      db.recordQueryPick('alpha beta', 'r1', 1000);
      db.recordQueryPick('alpha', 'r1', 1000 + RelicDb.kUseHalfLifeSecs);
      // alpha: 1 * 0.5 + 1 = 1.5; beta: decayed to 0.5.
      final f = db.rankFactors(['r1'],
          query: 'alpha beta', now: 1000 + RelicDb.kUseHalfLifeSecs);
      // Sum s = 1.5 + 0.5 = 2.0 → 1 + 0.25 * 2/5.
      expect(f['r1'], closeTo(1.10, 1e-9));
    });

    test('boost cannot surface an item the query does not match', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('corner', content: 'ssh key for the build server'));
      db.upsert(_mk('match', content: 'grocery list eggs milk'));
      for (var i = 0; i < 20; i++) {
        db.recordQueryPick('grocery', 'corner', 100 + i);
      }
      final ranked = db.lexicalHybridUids('grocery list', Scope.all, now: 300)!;
      expect(ranked, contains('match'));
      expect(ranked, isNot(contains('corner')),
          reason: 'even a poisoned association is a multiplier, never a leg');
    });

    test('context memory: uid rows boost, tag rows generalize, apps isolate',
        () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('cmd1', content: 'docker compose up alpha',
          tags: ['command'], createdAt: 100));
      db.upsert(_mk('cmd2', content: 'docker compose up beta',
          tags: ['command'], createdAt: 200));
      db.upsert(_mk('txt', content: 'docker meeting summary', createdAt: 300));

      // Pasted cmd1 into the terminal a few times.
      for (var i = 0; i < 3; i++) {
        db.recordContextPick('wt', 'cmd1', ['command'], 250 + i);
      }

      final f = db.rankFactors(['cmd1', 'cmd2', 'txt'], app: 'wt', now: 300);
      // cmd1: uid factor AND tag factor; cmd2: tag factor only; txt: none.
      expect(f['cmd1']!, greaterThan(f['cmd2']!));
      expect(f['cmd2']!, greaterThan(1.0));
      expect(f['txt'], isNull);
      // A different app sees none of it.
      expect(db.rankFactors(['cmd1', 'cmd2'], app: 'slack', now: 300),
          isEmpty);
    });

    test('stacked factors clamp at kPersonalBoostCap', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('r1', content: 'x', tags: ['command']));
      for (var i = 0; i < 60; i++) {
        db.recordUse('r1', 1000);
        db.recordQueryPick('alpha beta gamma', 'r1', 1000);
        db.recordContextPick('wt', 'r1', ['command'], 1000);
      }
      final f = db.rankFactors(['r1'],
          query: 'alpha beta gamma', app: 'wt', now: 1000);
      // Unclamped product would be ~1.25 * 1.25 * 1.15 * 1.08 ≈ 1.94.
      expect(f['r1'], RelicDb.kPersonalBoostCap);
    });

    test('deleting a relic forgets its memory rows; tag rows stay', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('r1', content: 'x', tags: ['command']));
      db.upsert(_mk('r2', content: 'x two', tags: ['command']));
      db.recordQueryPick('alpha', 'r1', 1000);
      db.recordContextPick('wt', 'r1', ['command'], 1000);
      db.delete('r1');

      expect(db.rankFactors(['r1'], query: 'alpha', now: 1000), isEmpty);
      // The class-level tag row survives and still generalizes to r2.
      final f = db.rankFactors(['r2'], app: 'wt', now: 1000);
      expect(f['r2'], greaterThan(1.0));
      // uid-level rows for r1 are gone even if it somehow reappears in a
      // candidate list.
      expect(db.rankFactors(['r1'], app: 'wt', now: 1000), isEmpty);
    });

    test('idle memory rows prune on the next record', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('old', content: 'x'));
      db.upsert(_mk('new', content: 'y'));
      db.recordQueryPick('alpha', 'old', 1000);
      // A record far in the future sweeps the idle row.
      final later = 1000 + RelicDb.kMemoryIdleSecs + 1;
      db.recordQueryPick('beta', 'new', later);
      expect(db.rankFactors(['old'], query: 'alpha', now: later), isEmpty);
    });

    test('clearPersonalMemory zeroes every signal', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('r1', content: 'x', tags: ['command']));
      db.recordUse('r1', 1000);
      db.recordQueryPick('alpha', 'r1', 1000);
      db.recordContextPick('wt', 'r1', ['command'], 1000);
      expect(
          db.rankFactors(['r1'], query: 'alpha', app: 'wt', now: 1000),
          isNotEmpty);

      db.clearPersonalMemory();
      expect(
          db.rankFactors(['r1'], query: 'alpha', app: 'wt', now: 1000),
          isEmpty);
    });

    test('factorsFor callback boosts matches, never surfaces non-matches', () {
      // The mobile lens's shape: personal counters live OUTSIDE this index
      // (PersonalStore), supplied per-union via the callback.
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('first', content: 'meeting notes alpha', createdAt: 100));
      db.upsert(_mk('picked', content: 'meeting notes alpha', createdAt: 200));
      db.upsert(_mk('other', content: 'grocery list eggs', createdAt: 300));

      // Without external factors the first-inserted twin leads.
      final plain = db.lexicalHybridUids('meeting notes', Scope.all, now: 400)!;
      expect(plain.first, 'first');

      final ranked = db.lexicalHybridUids('meeting notes', Scope.all,
          now: 400,
          factorsFor: (union) {
            expect(union, containsAll(['first', 'picked']));
            return {'picked': 1.2, 'other': 5.0};
          })!;
      expect(ranked.first, 'picked',
          reason: 'the externally-boosted twin overtakes the tie-order edge');
      expect(ranked, isNot(contains('other')),
          reason: 'external factors are multipliers on matches, never a leg');
    });
  });

  group('clear all history (batch) + retention helpers', () {
    test('clearUnpromoted deletes history, spares vault, cascades indexes',
        () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('h1', content: 'ephemeral alpaca note', createdAt: 100));
      db.upsert(_mk('h2', content: 'another alpaca scrap', createdAt: 200));
      db.upsert(_mk('v1',
          content: 'kept alpaca treasure', promoted: true, createdAt: 300));
      db.upsertVector('h1', [1.0, 0.0]);
      db.upsertVector('v1', [0.0, 1.0]);
      db.recordQueryPick('alpaca note', 'h1', 400);
      db.recordContextPick('chrome', 'h1', ['url'], 400);

      final res = db.clearUnpromoted(500, queueDeletes: false);

      expect(res.uids.toSet(), {'h1', 'h2'});
      expect(db.updatedAtOf('h1'), isNull);
      expect(db.updatedAtOf('v1'), isNotNull, reason: 'vault is immune');
      expect(db.countUnpromoted(), 0);
      // FTS finds only the survivor.
      expect(db.countMatching('alpaca', Scope.all), 1);
      expect(db.hasVector('h1'), isFalse);
      expect(db.hasVector('v1'), isTrue);
      // query_memory rows for cleared uids are gone.
      expect(db.rankFactors(['h1'], query: 'alpaca note', now: 500), isEmpty);
      // context uid rows are gone, but tag rows survive (class-level) and
      // still generalize to surviving items carrying the tag.
      db.upsert(_mk('v2',
          content: 'https://kept.example', tags: ['url'], promoted: true));
      expect(db.rankFactors(['v2'], app: 'chrome', now: 500),
          contains('v2'));
    });

    test('tombstones queued only when asked; push ops + rejections cleared',
        () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('h1', content: 'one'));
      db.upsert(_mk('h2', content: 'two'));
      db.queueOp('h1', 'push', 10);
      db.recordSyncRejection('h2', 'push', 402, 20);

      final res = db.clearUnpromoted(100, queueDeletes: true);
      expect(res.uids.length, 2);
      final ops = db.pendingOps();
      expect(ops.map((o) => (o.uid, o.op)).toSet(),
          {('h1', 'delete'), ('h2', 'delete')},
          reason: 'push ops replaced by tombstones, atomically');
      expect(ops.every((o) => o.queuedAt == 100), isTrue);
      expect(db.rejectionCount(), 0);
      expect(db.hasPendingDelete('h1'), isTrue);
      expect(db.hasPendingDelete('v-none'), isFalse);

      // Local-only variant queues nothing.
      final db2 = RelicDb.memory();
      addTearDown(db2.dispose);
      db2.upsert(_mk('h1', content: 'one'));
      db2.clearUnpromoted(100, queueDeletes: false);
      expect(db2.pendingCount(), 0);
    });

    test('blob keys shared with vault rows are not orphans', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('h1',
          content: 'img', kind: Kind.photo, blobKey: 'shared-key'));
      db.upsert(_mk('h2',
          content: 'img2', kind: Kind.photo, blobKey: 'history-only'));
      db.upsert(_mk('v1',
          content: 'img', kind: Kind.photo, blobKey: 'shared-key',
          promoted: true));

      final res = db.clearUnpromoted(100, queueDeletes: false);
      expect(res.orphanBlobKeys, {'history-only'},
          reason: 'the vault row still needs shared-key bytes');
    });

    test('empty history is a no-op', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('v1', content: 'kept', promoted: true));
      final res = db.clearUnpromoted(100, queueDeletes: true);
      expect(res.uids, isEmpty);
      expect(res.orphanBlobKeys, isEmpty);
      expect(db.pendingCount(), 0);
      expect(db.updatedAtOf('v1'), isNotNull);
    });

    test('countNeedingEnrich follows setEnrichLevel', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('a', content: 'x'));
      db.upsert(_mk('b', content: 'y'));
      expect(db.countNeedingEnrich(3), 2);
      db.setEnrichLevel('a', 3);
      expect(db.countNeedingEnrich(3), 1);
      expect(db.countNeedingEnrich(1), 1, reason: 'b is still level 0');
      db.setEnrichLevel('b', 1);
      expect(db.countNeedingEnrich(1), 0);
      expect(db.countNeedingEnrich(3), 1);
    });

    test('unpromotedOlderThan: strict cutoff, vault immune', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('old', content: 'old', createdAt: 100));
      db.upsert(_mk('edge', content: 'edge', createdAt: 200));
      db.upsert(_mk('new', content: 'new', createdAt: 300));
      db.upsert(_mk('oldkept',
          content: 'kept', createdAt: 50, promoted: true));

      final rows = db.unpromotedOlderThan(200);
      expect(rows.map((r) => r.uid), ['old'],
          reason: 'created_at == cutoff stays; vault stays');
    });
  });

  group('clip reminders (local-only)', () {
    test('addReminder → dueReminders boundary, markFired, clear', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('a', content: 'note a'));

      // remind_at is epoch MILLISECONDS.
      final id = db.addReminder('a', 1000, note: 'ping');
      expect(id, greaterThan(0));

      // Not yet due (now < remind_at).
      expect(db.dueReminders(999), isEmpty);
      // Due at the exact boundary (remind_at <= now).
      final due = db.dueReminders(1000);
      expect(due.map((r) => r.relicUid), ['a']);
      expect(due.single.note, 'ping');

      // remindersFor lists pending, then markFired removes it from both.
      expect(db.remindersFor('a').map((r) => r.id), [id]);
      db.markFired(id);
      expect(db.dueReminders(5000), isEmpty,
          reason: 'a fired reminder never comes due again');
      expect(db.remindersFor('a'), isEmpty,
          reason: 'fired reminders are not pending');
    });

    test('dueReminders is oldest-first; clearReminder deletes', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('a', content: 'a'));
      final later = db.addReminder('a', 3000);
      final sooner = db.addReminder('a', 2000);

      expect(db.dueReminders(5000).map((r) => r.id), [sooner, later],
          reason: 'ordered by remind_at ascending');

      db.clearReminder(sooner);
      expect(db.dueReminders(5000).map((r) => r.id), [later]);
      expect(db.remindersFor('a').map((r) => r.id), [later]);
    });

    test('reminders are off the sync wire (no pending_ops)', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('a', content: 'a'));
      db.addReminder('a', 1000);
      // Scheduling a reminder must not queue any push/delete op.
      expect(db.pendingCount(), 0);
    });
  });

  test('snippet tag backs the picker facet (tagFrequencies.user)', () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);
    // A snippet is a normal string relic carrying the reserved user tag.
    db.upsert(Relic(
      uid: 's1',
      createdAt: 1000,
      updatedAt: 1000,
      kind: Kind.string,
      source: Source.upload,
      promoted: false,
      byteSize: 4,
      tags: const [],
      userTags: const ['snippet'],
      title: ';welcome',
      content: 'Hi there!',
      preview: 'Hi there!',
    ));
    db.upsert(_mk('plain', content: 'not a snippet'));

    final freq = db.tagFrequencies(false);
    expect(freq.user['snippet'], 1,
        reason: 'the Snippets facet counts relics tagged #snippet');
  });

  group('rich text column', () {
    RichBody body(String plain, {String html = '<b>x</b>'}) =>
        RichBody.capture(plain: plain, html: html)!;

    test('round-trips through upsert', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);

      final rich = body('hello', html: '<b>hello</b>');
      db.upsert(_mk('a', content: 'hello').copyWith(rich: rich));

      final back = db.getByUid('a')!;
      expect(back.rich, rich);
      expect(back.richIfCurrent, rich);
    });

    test('a later upsert without rich CLEARS it', () {
      // The column is synced, so it must be in the ON CONFLICT DO UPDATE set,
      // not just the INSERT. If it were insert-only this would still return the
      // old value and a peer could never remove formatting.
      final db = RelicDb.memory();
      addTearDown(db.dispose);

      db.upsert(_mk('a', content: 'hello').copyWith(rich: body('hello')));
      expect(db.getByUid('a')!.rich, isNotNull);

      db.upsert(_mk('a', content: 'hello'));
      expect(db.getByUid('a')!.rich, isNull);
    });

    test('bulkLoad round-trips it too', () {
      // bulkLoad has its own parallel INSERT. Missing the column there would
      // make rich text silently vanish on the mobile paste path, which builds
      // its whole index this way.
      final db = RelicDb.memory();
      addTearDown(db.dispose);

      final rich = body('hello');
      db.bulkLoad([_mk('a', content: 'hello').copyWith(rich: rich)]);
      expect(db.getByUid('a')!.rich, rich);
    });

    test('setRich replaces it and richOf reads it back', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);

      db.upsert(_mk('a', content: 'hello'));
      expect(db.richOf('a'), isNull);

      final rich = body('hello');
      db.setRich('a', rich);
      expect(db.richOf('a'), rich);
      expect(db.getByUid('a')!.rich, rich);

      db.setRich('a', null);
      expect(db.richOf('a'), isNull);
    });

    test('setRich does not queue a push on its own', () {
      // It is always paired with touch(), which owns updated_at and the queue.
      final db = RelicDb.memory();
      addTearDown(db.dispose);

      db.upsert(_mk('a', content: 'hello'));
      db.clearOpsForUid('a');
      db.setRich('a', body('hello'));
      expect(db.pendingCount(), 0);
    });

    test('markup is never searchable', () {
      // The stored HTML must stay out of the FTS body: indexing it would make
      // every browser copy match div/span/style/mso, and would let markup
      // outrank real text.
      final db = RelicDb.memory();
      addTearDown(db.dispose);

      final rich = RichBody.capture(
        plain: 'quarterly figures',
        html: '<div style="mso-pad:0">zzzqmarker</div>',
      )!;
      db.upsert(
          _captured('a', 'quarterly figures').copyWith(rich: rich));

      expect(db.lexicalHybridUids('quarterly', Scope.all), contains('a'));
      expect(db.lexicalHybridUids('zzzqmarker', Scope.all) ?? const [],
          isEmpty);
      expect(db.lexicalHybridUids('mso', Scope.all) ?? const [], isEmpty);
      expect(db.lexicalHybridUids('div', Scope.all) ?? const [], isEmpty);
    });
  });
}

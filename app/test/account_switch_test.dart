// Account-switch isolation (the 2026-07-14 leak: binding a different account
// auto-pushed the previous account's entire vault into it). Three layers:
//
//  1. RelicDb.clearAllPendingSync — the queued outbound ops from account A
//     must never replay against account B.
//  2. LocalDeskRepo._prepareBind — first bind / same-account rebind keeps the
//     push-all onboarding; an account SWITCH holds items back behind an
//     explicit merge offer instead. (Sandbox-gated like the other repo tests:
//     RELIC_DATA_DIR=$(mktemp -d) flutter test test/account_switch_test.dart)
//  3. WorkerRepo cache guard — a relic_cache.json stamped with another
//     account's id is discarded wholesale on load, and destroyLocalCache
//     removes it on sign-out.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_crypto/relic_crypto.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/data/relic_db.dart';
import 'package:relic_app/data/supabase_auth.dart';
import 'package:relic_app/data/worker_repo.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/widgets/chrome.dart';

// Same rationale as clear_history_test: restore real networking so the
// discard-port baseUrl fails transiently (ops stay queued) instead of the
// flutter_test 400-mock draining the outbox.
class _RealNetwork extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealNetwork();

  group('RelicDb account-switch helpers', () {
    test('clearAllPendingSync drops every op and rejection, rows survive', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('u1', 'one'));
      db.upsert(_mk('u2', 'two'));
      db.queueOp('u1', 'push', 1000);
      db.queueOp('u2', 'delete', 1000);
      db.recordSyncRejection('u1', 'push', 402, 1000);
      expect(db.pendingCount(), 2);

      db.clearAllPendingSync();
      expect(db.pendingCount(), 0);
      expect(db.allRejections(), isEmpty);
      expect(db.countAll(), 2, reason: 'only sync state clears, never data');
    });

    test('countAll counts promoted and unpromoted alike', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('u1', 'history'));
      db.upsert(_mk('u2', 'vault').copyWith(promoted: true));
      expect(db.countAll(), 2);
      expect(db.countUnpromoted(), 1);
    });

    test('holdAll hides rows from every read path, releaseHeld restores them',
        () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('u1', 'alpha keeper', createdAt: 100));
      db.upsert(_mk('u2', 'beta keeper', createdAt: 200));
      expect(db.countAll(), 2);

      expect(db.holdAll('supabase:acct-one'), 2);
      expect(db.countHeld(), 2);
      expect(db.heldByOf('u1'), 'supabase:acct-one');

      // Everything the user (or the sync push) can reach goes quiet.
      expect(db.countAll(), 0);
      expect(db.countUnpromoted(), 0);
      expect(db.isEmpty, isTrue);
      expect(db.allRows(), isEmpty, reason: 'never pushed to the new account');
      expect(db.queryPage('', Scope.all, 50, 0), isEmpty);
      expect(db.queryPage('alpha', Scope.all, 50, 0), isEmpty);
      expect(db.countMatching('alpha', Scope.all), 0);
      expect(db.ftsCandidates('alpha', Scope.all, 10), isEmpty);
      expect(db.trigramCandidates('keeper', Scope.all, 10), isEmpty);
      expect(db.byUids(['u1', 'u2']), isEmpty);
      expect(db.mostRecentUid(), isNull);
      expect(db.nthMostRecentUid(1), isNull);
      expect(db.uidByContent('alpha keeper'), isNull,
          reason: 'a re-copy must capture afresh, not vanish into a held row');

      // Items captured AFTER the switch are the new account's, and visible.
      db.upsert(_mk('u3', 'fresh copy', createdAt: 300));
      expect(db.queryPage('', Scope.all, 50, 0).map((r) => r.uid), ['u3']);
      expect(db.countAll(), 1);
      expect(db.mostRecentUid(), 'u3');

      // Signing back into the original account brings exactly its rows back.
      expect(db.releaseHeld('supabase:acct-one'), 2);
      expect(db.countHeld(), 0);
      expect(db.countAll(), 3);
      expect(db.countMatching('alpha', Scope.all), 1);
      expect(db.queryPage('', Scope.all, 50, 0).map((r) => r.uid),
          ['u3', 'u2', 'u1']);
    });

    test('releaseHeld only frees its own identity; releaseAllHeld frees the lot',
        () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('a1', 'account one item'));
      db.holdAll('supabase:one');
      db.upsert(_mk('b1', 'account two item'));
      db.holdAll('supabase:two');
      expect(db.countHeld(), 2);

      expect(db.releaseHeld('supabase:one'), 1);
      expect(db.heldByOf('a1'), isNull);
      expect(db.heldByOf('b1'), 'supabase:two');

      expect(db.releaseAllHeld(), 1);
      expect(db.countHeld(), 0);
      expect(db.countAll(), 2);
    });

    test('held rows are exempt from clear-history and keep their blob alive',
        () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('old', 'previous account').copyWith(blobKey: 'blob-old'));
      db.holdAll('supabase:one');
      db.upsert(_mk('new', 'this account').copyWith(blobKey: 'blob-new'));

      final res = db.clearUnpromoted(500, queueDeletes: true);
      expect(res.uids, ['new'], reason: 'only the visible history is cleared');
      expect(res.orphanBlobKeys, {'blob-new'});
      expect(res.orphanBlobKeys, isNot(contains('blob-old')),
          reason: 'a held row still references its bytes');
      expect(db.countHeld(), 1);
      expect(db.pendingOps().map((p) => p.uid), ['new'],
          reason: 'no tombstone for the held row against this account');
      // Blob accounting still sees it, so the cache sweeper cannot collect it.
      expect(db.allWithBlob().map((r) => r.uid), contains('old'));
    });

    test('held rows are exempt from retention eviction', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('old1', 'one', createdAt: 100));
      db.upsert(_mk('old2', 'two', createdAt: 200));
      db.holdAll('supabase:one');
      db.upsert(_mk('new1', 'three', createdAt: 300));

      expect(db.countUnpromoted(), 1);
      expect(db.unpromotedBeyond(0).map((r) => r.uid), ['new1']);
      expect(db.unpromotedOlderThan(250).map((r) => r.uid), isEmpty);
    });

    test('holdOldest tags the N oldest rows (legacy prefs migration)', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      for (var i = 0; i < 5; i++) {
        db.upsert(_mk('u$i', 'item $i', createdAt: 100 + i));
      }
      expect(db.holdOldest(2, 'previous-account'), 2);
      expect(db.heldByOf('u0'), 'previous-account');
      expect(db.heldByOf('u1'), 'previous-account');
      expect(db.heldByOf('u2'), isNull);
      expect(db.countAll(), 3);
      // The sentinel is not an account, so no bind can release it.
      expect(db.releaseHeld('supabase:anyone'), 0);
      expect(db.countHeld(), 2);
    });
  });

  final sandbox = Platform.environment['RELIC_DATA_DIR'];
  final guarded =
      sandbox == null || sandbox.toLowerCase().contains('roaming');

  test('sandboxed: bind pushes on first/same account, holds back on a switch',
      () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    final repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    repo.setMlEnrich(false);
    repo.captureText('mine alpha');
    repo.captureText('mine beta');
    final n = repo.all.length;
    expect(n, greaterThanOrEqualTo(2));

    // First-ever bind (local install joining an account): push-all allowed.
    expect(repo.debugPrepareBind('supabase:acct-one'), isTrue);
    expect(repo.mergeOfferCount, 0);

    // Re-binding the SAME account (sign out / sign back in): still allowed.
    expect(repo.debugPrepareBind('supabase:acct-one'), isTrue);
    expect(repo.mergeOfferCount, 0);

    // Switching accounts: no auto-push; the items become a pending offer.
    expect(repo.debugPrepareBind('supabase:acct-two'), isFalse,
        reason: 'a switch must never auto-upload the old account\'s items');
    expect(repo.mergeOfferCount, n);

    // ...and they are TUCKED AWAY: gone from the list and from search, not
    // sitting in the history looking like this account's broken sync.
    expect(repo.all, isEmpty);
    await repo.setQuery('mine', Scope.all);
    expect(repo.visible, isEmpty);

    // Anything copied after the switch belongs to the new account and shows.
    repo.captureText('theirs gamma');
    await repo.setQuery('', Scope.all);
    expect(repo.visible.map((r) => r.content), ['theirs gamma']);
    await repo.setQuery('gamma', Scope.all);
    expect(repo.visible, hasLength(1));
    await repo.setQuery('', Scope.all);

    // Dismiss keeps them tucked away and stops asking.
    repo.dismissMergeOffer();
    expect(repo.mergeOfferCount, 0);
    expect(repo.all.map((r) => r.content), ['theirs gamma'],
        reason: 'dismiss hides the offer, not the holdback');

    // Back to acct-two again later: same account now, push-all fine.
    expect(repo.debugPrepareBind('supabase:acct-two'), isTrue);

    // Signing back into the ORIGINAL account releases exactly its rows and
    // holds acct-two's instead.
    expect(repo.debugPrepareBind('supabase:acct-one'), isFalse);
    expect(repo.all.map((r) => r.content),
        containsAll(<String>['mine alpha', 'mine beta']));
    expect(repo.all.any((r) => r.content == 'theirs gamma'), isFalse);
    expect(repo.mergeOfferCount, 1, reason: 'gamma is acct-two\'s now');
  });

  test('sandboxed: dismiss survives a reload; accept releases and queues pushes',
      () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    _wipeSandbox(sandbox);
    var repo = LocalDeskRepo();
    await repo.load();
    repo.setMlEnrich(false);
    repo.captureText('held one');
    repo.captureText('held two');
    final n = repo.all.length;

    expect(repo.debugPrepareBind('supabase:first'), isTrue);
    expect(repo.debugPrepareBind('supabase:second'), isFalse);
    expect(repo.mergeOfferCount, n);
    repo.dismissMergeOffer();
    expect(repo.mergeOfferCount, 0);
    repo.dispose();

    // Reload: the dismissal is remembered, the rows are still held and hidden.
    repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    repo.setMlEnrich(false);
    expect(repo.mergeOfferCount, 0, reason: 'dismissal persisted');
    expect(repo.all, isEmpty, reason: 'still tucked away after a restart');

    // Accepting brings them back and queues a push for every row.
    repo.debugSetMasterKey(Uint8List.fromList(List.filled(32, 3)));
    await repo.acceptMergeOffer();
    expect(repo.all, hasLength(n));
    expect(repo.mergeOfferCount, 0);
    expect(repo.sync.pending, n, reason: 'every row queued for this account');
  });

  test('sandboxed: deleting the holdback erases it without any tombstone push',
      () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    _wipeSandbox(sandbox);
    final repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    repo.setMlEnrich(false);
    repo.captureText('doomed one');
    repo.captureText('doomed two');
    final n = repo.all.length;

    expect(repo.debugPrepareBind('supabase:first'), isTrue);
    expect(repo.debugPrepareBind('supabase:second'), isFalse);
    expect(repo.mergeOfferCount, n);
    repo.debugSetMasterKey(Uint8List.fromList(List.filled(32, 4)));

    expect(await repo.deleteMergeOffer(), n);
    expect(repo.mergeOfferCount, 0);
    expect(repo.all, isEmpty);
    // The current account never had these items; a tombstone addressed to it
    // would at best be noise and at worst delete a stranger's row.
    expect(repo.sync.pending, 0, reason: 'no delete ops queued');
    // Gone for good: signing back into the old account brings nothing back.
    expect(repo.debugPrepareBind('supabase:first'), isFalse);
    expect(repo.all, isEmpty);
    expect(repo.mergeOfferCount, 0);
  });

  test('sandboxed: a legacy merge_offer_count tags the oldest rows on load',
      () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    _wipeSandbox(sandbox);
    var repo = LocalDeskRepo();
    await repo.load();
    repo.setMlEnrich(false);
    for (var i = 0; i < 4; i++) {
      repo.captureText('legacy item $i');
    }
    expect(repo.all, hasLength(4));
    repo.dispose();

    // Rewrite prefs the way the FIRST version of the holdback left them: a
    // count, no marked rows, no record of which account they belonged to.
    final prefsFile =
        File('$sandbox${Platform.pathSeparator}prefs.json');
    final prefs =
        jsonDecode(prefsFile.readAsStringSync()) as Map<String, dynamic>;
    prefs['merge_offer_count'] = 2;
    prefs['synced_account'] = 'supabase:current';
    prefsFile.writeAsStringSync(jsonEncode(prefs));

    repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    repo.setMlEnrich(false);

    // The two OLDEST are now held (hidden), and the offer keeps its size.
    expect(repo.mergeOfferCount, 2);
    expect(repo.all.map((r) => r.content).toSet(),
        {'legacy item 2', 'legacy item 3'});
    // The legacy key is gone; the count is derived from the rows from here on.
    final rewritten =
        jsonDecode(prefsFile.readAsStringSync()) as Map<String, dynamic>;
    expect(rewritten.containsKey('merge_offer_count'), isFalse);
    // The sentinel belongs to no account, so a bind never auto-releases it.
    expect(repo.debugPrepareBind('supabase:previous-owner'), isFalse);
    expect(repo.mergeOfferCount, 4,
        reason: 'the sentinel rows stay held, plus the two just switched away');
  });

  group('WorkerRepo cache guard', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('relic_cache_guard_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => tmp.path,
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    final mk = Uint8List.fromList(List.generate(32, (i) => i * 7 & 0xff));

    Future<WorkerRepo> repo() => WorkerRepo.bindSupabaseWithMk(
          baseUrl: 'http://127.0.0.1:9', // discard port — flushes fail fast
          session: const SupabaseSession(
            accessToken: 't',
            refreshToken: 'r',
            expiresAt: 4102444800,
            userId: 'test-user',
          ),
          mk: mk,
        );

    Future<Map<String, dynamic>> envFor(String uid, String content) async {
      final sealed = await RelicCrypto.sealRelicPayload(mk, uid, {
        'kind': 'string',
        'source': 'clipboard',
        'content': content,
        'preview': content,
        'tags': <String>[],
        'user_tags': <String>[],
      });
      return {
        'v': 1,
        'uid': uid,
        'created_at': 1,
        'updated_at': 2,
        'byte_size': content.length,
        'promoted': false,
        'n': sealed['n'],
        'ct': sealed['ct'],
      };
    }

    File cacheFile() => File('${tmp.path}/relic_cache.json');

    test('a cache stamped with a DIFFERENT account is discarded on load',
        () async {
      cacheFile().writeAsStringSync(jsonEncode({
        'account': 'someone-else',
        'cursor': 999,
        'items': [await envFor('leak-1', 'not yours')],
        'outbox': [
          {'op': 'delete', 'uid': 'leak-1', 'deleted_at': 5},
        ],
      }));

      final r = await repo();
      await r.load();
      expect(r.all, isEmpty, reason: 'foreign items must not surface');
      expect(r.debugOutbox, isEmpty,
          reason: 'foreign ops must not replay against this account');
      expect(cacheFile().existsSync(), isFalse, reason: 'stale cache deleted');
    });

    test('a cache stamped with THIS account loads normally', () async {
      cacheFile().writeAsStringSync(jsonEncode({
        'account': 'test-user',
        'items': [await envFor('own-1', 'mine')],
        'outbox': [
          {'op': 'delete', 'uid': 'gone-uid', 'deleted_at': 5},
        ],
      }));

      final r = await repo();
      await r.load();
      expect(r.all.single.content, 'mine');
      expect(r.debugOutbox, hasLength(1));
    });

    test('an unstamped (pre-guard) cache is trusted as this account\'s',
        () async {
      cacheFile().writeAsStringSync(jsonEncode({
        'items': [await envFor('own-1', 'legacy cache')],
        'outbox': <Map<String, dynamic>>[],
      }));

      final r = await repo();
      await r.load();
      expect(r.all.single.content, 'legacy cache');
    });

    test('saveCache stamps the owner so the next session can check it',
        () async {
      final r = await repo();
      await r.load();
      await r.captureText('stamp me'); // queues + persists the cache
      final j =
          jsonDecode(cacheFile().readAsStringSync()) as Map<String, dynamic>;
      expect(j['account'], 'test-user');
    });

    test('destroyLocalCache wipes the file and the in-memory mirror',
        () async {
      final r = await repo();
      await r.load();
      await r.captureText('to be forgotten');
      expect(r.all, isNotEmpty);
      expect(cacheFile().existsSync(), isTrue);

      await r.destroyLocalCache();
      expect(r.all, isEmpty);
      expect(r.debugOutbox, isEmpty);
      expect(cacheFile().existsSync(), isFalse);
    });
  });
}

/// Repo-level tests share ONE RELIC_DATA_DIR (it is read from the environment
/// once), so each starts by emptying it — otherwise the previous test's vault
/// and prefs are still sitting there.
void _wipeSandbox(String dir) {
  for (final e in Directory(dir).listSync()) {
    try {
      e.deleteSync(recursive: true);
    } catch (_) {}
  }
}

Relic _mk(String uid, String content, {int createdAt = 100}) => Relic(
      uid: uid,
      createdAt: createdAt,
      updatedAt: createdAt,
      kind: Kind.string,
      source: Source.clipboard,
      promoted: false,
      byteSize: content.length,
      content: content,
      preview: content,
    );

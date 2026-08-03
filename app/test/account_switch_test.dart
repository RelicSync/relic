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

    // Dismiss keeps them local and forgets the offer.
    repo.dismissMergeOffer();
    expect(repo.mergeOfferCount, 0);

    // Back to acct-two again later: same account now, push-all fine.
    expect(repo.debugPrepareBind('supabase:acct-two'), isTrue);
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

Relic _mk(String uid, String content) => Relic(
      uid: uid,
      createdAt: 100,
      updatedAt: 100,
      kind: Kind.string,
      source: Source.clipboard,
      promoted: false,
      byteSize: content.length,
      content: content,
      preview: content,
    );

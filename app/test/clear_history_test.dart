import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_crypto/relic_crypto.dart';
import 'package:relic_app/data/personal_store.dart';
import 'package:relic_app/data/supabase_auth.dart';
import 'package:relic_app/data/worker_repo.dart';

// Offline WorkerRepo harness: bindSupabaseWithMk sets the master key without
// touching the network, and every save/flush is failure-tolerant (a dead
// baseUrl just leaves ops queued in the outbox), so the delete/clear/pull
// bookkeeping is testable without a server.
//
// flutter_test's binding mocks ALL HttpClients to answer 400 — which the
// outbox treats as a PERMANENT rejection and drops the op. These tests need
// the opposite (a transient failure that keeps ops queued), so real
// networking is restored and the discard-port baseUrl refuses the connection.
class _RealNetwork extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealNetwork();

  final mk = Uint8List.fromList(List.generate(32, (i) => i * 7 & 0xff));

  Future<WorkerRepo> repo({bool autoVault = true}) =>
      WorkerRepo.bindSupabaseWithMk(
        baseUrl: 'http://127.0.0.1:9', // discard port — flushes fail fast
        session: const SupabaseSession(
          accessToken: 't',
          refreshToken: 'r',
          expiresAt: 4102444800, // 2100 — never "expired" mid-test
          userId: 'test-user',
        ),
        mk: mk,
        autoVault: autoVault,
      );

  Future<Map<String, dynamic>> envFor(
    String uid,
    String content, {
    required int updatedAt,
    bool promoted = false,
  }) async {
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
      'updated_at': updatedAt,
      'byte_size': content.length,
      'promoted': promoted,
      'n': sealed['n'],
      'ct': sealed['ct'],
    };
  }

  test('a pull never resurrects an item whose delete is still queued',
      () async {
    final r = await repo();
    await r.captureText('alpha thing');
    final relic = r.all.singleWhere((x) => x.content == 'alpha thing');

    await r.delete(relic);
    expect(r.all, isEmpty);
    expect(
      r.debugOutbox.where(
          (o) => o['uid'] == relic.uid && o['op'] == 'delete'),
      hasLength(1),
      reason: 'offline flush must leave the tombstone queued',
    );

    // The race: a pull snapshot taken before the delete reached the server
    // hands the old envelope back, with a NEWER updated_at than anything
    // local. The queued tombstone must win.
    final stale = await envFor(relic.uid, 'alpha thing',
        updatedAt: relic.updatedAt + 100);
    expect(await r.debugUpsertEnv(stale), isFalse);
    expect(r.all, isEmpty, reason: 'deleted item must not resurrect');

    // Control: the same envelope under a fresh uid upserts normally.
    final fresh = await envFor('fresh-uid', 'from another device',
        updatedAt: relic.updatedAt + 100);
    expect(await r.debugUpsertEnv(fresh), isTrue);
    expect(r.all.single.uid, 'fresh-uid');
  });

  test('clearHistory removes every unpromoted item, batched; vault survives',
      () async {
    final tmp = Directory.systemTemp.createTempSync('relic_clear_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    final r = await repo(autoVault: false); // captures are born unpromoted
    await r.captureText('history one');
    await r.captureText('history two');
    await r.captureText('kept in the vault');
    final vault = r.all.singleWhere((x) => x.content == 'kept in the vault');
    await r.promote(vault, true);
    expect(r.historyCount, 2);

    // Learned-ranking rows must go with their items (and only theirs).
    final h1 = r.all.singleWhere((x) => x.content == 'history one');
    final store = PersonalStore('${tmp.path}${Platform.pathSeparator}p.db',
        List<int>.generate(32, (i) => i));
    addTearDown(store.dispose);
    store.recordUse(h1.uid, 1000);
    store.recordUse(vault.uid, 1000);
    r.debugSetPersonalStore(store);

    final n = await r.clearHistory();
    expect(n, 2);
    expect(r.historyCount, 0);
    expect(r.all.single.uid, vault.uid, reason: 'vault item untouched');

    final deletes = r.debugOutbox.where((o) => o['op'] == 'delete').toList();
    expect(deletes, hasLength(2),
        reason: 'one queued tombstone per cleared item');
    expect(deletes.map((o) => o['uid']), isNot(contains(vault.uid)));
    for (final d in deletes) {
      expect(
        r.debugOutbox.where(
            (o) => o['uid'] == d['uid'] && o['op'] == 'put'),
        isEmpty,
        reason: 'pending puts for cleared uids are superseded',
      );
    }

    expect(store.factors([h1.uid], null, 1000), isEmpty,
        reason: 'learned rows for cleared items forgotten');
    expect(store.factors([vault.uid], null, 1000), isNotEmpty,
        reason: 'vault item keeps its learned signal');

    // Idempotent when there is nothing left to clear.
    expect(await r.clearHistory(), 0);
  });

  test('captureText with autoVault keeps items out of historyCount', () async {
    final r = await repo(); // autoVault: true → born promoted
    await r.captureText('straight to vault');
    expect(r.historyCount, 0);
    expect(await r.clearHistory(), 0);
    expect(r.all, hasLength(1));
  });
}

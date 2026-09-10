// The phone's sync used to do its heavy work on the UI isolate: pure-Dart
// XChaCha20 for every envelope a pull brought back, the search index one
// transaction per relic with the regex scanners run inline, and a synchronous
// JSON write of the whole cache after every pass, changed or not. On a vault
// of a thousand items that froze the list for seconds, on a timer.
//
// These tests push a thousand sealed envelopes through the real pull path and
// the real cache round trip while a 4 ms timer ticks on the main isolate. The
// ticks that fail to fire add up to how long the UI would have been frozen.
// Before the work moved off the isolate that was most of the job, seconds;
// now it is held to a fraction of a second. The tests also pin what the hop
// must not change: every item lands, search finds it, and a second launch
// reads them all back from the cache.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_crypto/relic_crypto.dart';
import 'package:relic_app/widgets/chrome.dart' show Scope;
import 'package:relic_app/data/supabase_auth.dart';
import 'package:relic_app/data/worker_repo.dart';

class _RealNetwork extends HttpOverrides {}

/// How much of [job]'s wall time the main isolate spent busy, in
/// milliseconds, plus the longest single stretch it was busy.
///
/// A 4 ms timer ticks while the job runs. Every tick that did not fire is
/// 4 ms the isolate was doing something else, so `wall - ticks * 4` is the
/// time the UI would have been frozen in total, and the longest gap between
/// two ticks is the longest single freeze. Both matter: the old per-item
/// path yielded between items, so its longest gap was short while its total
/// was the whole job.
Future<({int wallMs, int busyMs, int worstGapMs})> uiCost(
    Future<void> Function() job) async {
  final sw = Stopwatch()..start();
  var last = 0;
  var worst = 0;
  var ticks = 0;
  final t = Timer.periodic(const Duration(milliseconds: 4), (_) {
    ticks++;
    final now = sw.elapsedMilliseconds;
    final gap = now - last;
    if (gap > worst) worst = gap;
    last = now;
  });
  try {
    await job();
  } finally {
    t.cancel();
  }
  final wall = sw.elapsedMilliseconds;
  final busy = wall - ticks * 4;
  return (wallMs: wall, busyMs: busy < 0 ? 0 : busy, worstGapMs: worst);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealNetwork();

  final mk = Uint8List.fromList(List.generate(32, (i) => i * 13 & 0xff));
  const count = 1000;
  // Generous. The SQLite slices are the only work left on the isolate, tens
  // of milliseconds in all; the old inline path kept it busy for seconds.
  const budgetMs = 500;

  late Directory tmp;
  late List<Map<String, dynamic>> envs;

  setUpAll(() async {
    // Enough prose per item that the index scanners have real work, and one
    // rare word in a known subset so search has something to prove.
    const prose =
        'Meeting notes from the quarterly review. Ship the invoice to the '
        'client by Friday, then confirm the wire reference with accounting. '
        'Remember the parking code is 4471 and the building closes at nine. ';
    envs = [];
    for (var i = 0; i < count; i++) {
      final uid = 'u$i';
      final content = '${i % 50 == 0 ? 'lantern ' : ''}$prose$prose$prose$i';
      final sealed = await RelicCrypto.sealRelicPayload(mk, uid, {
        'kind': 'string',
        'source': 'clipboard',
        'content': content,
        'preview': content.substring(0, 60),
        'tags': <String>[],
        'user_tags': <String>[],
      });
      envs.add({
        'v': 1,
        'uid': uid,
        'created_at': 1000 + i,
        'updated_at': 1000 + i,
        'byte_size': content.length,
        'promoted': true,
        'n': sealed['n'],
        'ct': sealed['ct'],
      });
    }
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('relic_off_thread_');
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

  Future<WorkerRepo> repo() => WorkerRepo.bindSupabaseWithMk(
        baseUrl: 'http://127.0.0.1:9', // discard port: no network on the path
        session: const SupabaseSession(
          accessToken: 't',
          refreshToken: 'r',
          expiresAt: 4102444800,
          userId: 'test-user',
        ),
        mk: mk,
      );

  test('a thousand pulled items land without holding the UI isolate',
      () async {
    final r = await repo();
    await r.loadLocal();
    // Force the index up front so the pull takes the indexed path, the one a
    // running app is on when a sync lands.
    await r.setQuery('warmup', Scope.all);

    final pull = await uiCost(() async {
      expect(await r.debugAbsorbEnvelopes(envs), isTrue);
    });
    // ignore: avoid_print
    print('pull of $count items: $pull');
    expect(pull.busyMs, lessThan(budgetMs));
    expect(pull.worstGapMs, lessThan(budgetMs));

    await r.setQuery('', Scope.all);
    expect(r.matchCount, count, reason: 'every envelope opened and landed');
    await r.setQuery('lantern', Scope.all);
    expect(r.matchCount, count ~/ 50, reason: 'the index took the page');
    await r.setQuery('parking code', Scope.all);
    expect(r.matchCount, count, reason: 'body text is indexed');
  });

  test('the same page twice changes nothing the second time', () async {
    final r = await repo();
    await r.loadLocal();
    expect(await r.debugAbsorbEnvelopes(envs), isTrue);
    expect(await r.debugAbsorbEnvelopes(envs), isFalse,
        reason: 'an envelope no newer than the cached one is not news');
  });

  test('the cache is written and read back off the UI isolate', () async {
    final a = await repo();
    await a.loadLocal();
    expect(await a.debugAbsorbEnvelopes(envs), isTrue);

    final write = await uiCost(() => a.debugSaveCache());
    // ignore: avoid_print
    print('cache write of $count items: $write');
    expect(write.busyMs, lessThan(budgetMs));
    expect(write.worstGapMs, lessThan(budgetMs));
    expect(File('${tmp.path}/relic_cache.json').existsSync(), isTrue);
    expect(File('${tmp.path}/relic_cache.json.tmp').existsSync(), isFalse,
        reason: 'the temporary file is renamed into place');

    // A second launch: the read and every decrypt happen before first paint,
    // and that is exactly where the launch animation used to stop.
    final b = await repo();
    final read = await uiCost(() => b.loadLocal());
    // ignore: avoid_print
    print('launch from a $count-item cache: $read');
    expect(read.busyMs, lessThan(budgetMs));
    expect(read.worstGapMs, lessThan(budgetMs));
    await b.setQuery('', Scope.all);
    expect(b.matchCount, count, reason: 'the cache round-trips every item');
  });

  test('overlapping cache writes collapse and the last one wins', () async {
    final a = await repo();
    await a.loadLocal();
    expect(await a.debugAbsorbEnvelopes(envs.take(10).toList()), isTrue);
    final first = a.debugSaveCache();
    // Lands while the first write is on the isolate; the joiner must wait
    // for a follow-up that includes it.
    expect(await a.debugAbsorbEnvelopes(envs.skip(10).take(10).toList()),
        isTrue);
    final second = a.debugSaveCache();
    await Future.wait([first, second]);

    final b = await repo();
    await b.loadLocal();
    await b.setQuery('', Scope.all);
    expect(b.matchCount, 20);
  });
}

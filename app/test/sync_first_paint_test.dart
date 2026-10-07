// Opening the phone app after a day away took five seconds or more before a
// new item appeared, with the vault already on screen from cache. The items
// were not slow to arrive: the pass fetched the account, then the items, then
// the tombstones, then the AI records, one round trip after another, and only
// published the list once at the very end. On a phone radio every one of
// those round trips is a few hundred milliseconds, so the page of new items
// sat decrypted and indexed, invisible, through two more of them.
//
// Now the item pull is the first request after the token refresh, the other
// reads go out alongside it, and each page is published the moment it has
// been absorbed. These tests pin that order.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_crypto/relic_crypto.dart';
import 'package:relic_app/data/supabase_auth.dart';
import 'package:relic_app/data/worker_repo.dart';
import 'package:relic_app/widgets/chrome.dart' show SyncKind;

class _RealNetwork extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealNetwork();

  final mk = Uint8List.fromList(List.generate(32, (i) => i * 7 & 0xff));

  late Directory tmp;
  late HttpServer server;
  late String url;
  // Every path the server has been asked for, in arrival order.
  late List<String> arrivals;
  // The query of every item pull, in arrival order.
  late List<Map<String, String>> pulls;
  // Paths the server has finished answering, in completion order.
  late List<String> answered;
  // Paths that are made to answer slowly, as a phone radio would.
  late Set<String> slow;
  late List<Map<String, dynamic>> page;
  late List<Map<String, dynamic>> tombs;
  late bool tombstonesFail;

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
      'created_at': 10,
      'updated_at': 10,
      'byte_size': content.length,
      'promoted': true,
      'n': sealed['n'],
      'ct': sealed['ct'],
    };
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('relic_first_paint_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
    arrivals = [];
    pulls = [];
    answered = [];
    slow = {};
    page = [await envFor('fresh', 'copied on the desktop yesterday')];
    tombs = [];
    tombstonesFail = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${server.port}';
    unawaited(server.forEach((req) async {
      final path = req.uri.path;
      arrivals.add(path);
      if (path == '/relics') pulls.add(req.uri.queryParameters);
      if (slow.contains(path)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      if (path == '/tombstones' && tombstonesFail) {
        req.response.statusCode = 503;
        await req.response.close();
        answered.add(path);
        return;
      }
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json;
      req.response.write(switch (path) {
        '/tombstones' => jsonEncode({'items': tombs}),
        '/account' => jsonEncode({
            'tier': 'free',
            'storage_used': 0,
            'storage_quota': 1000,
            'vault_count': 1,
          }),
        '/relics' => jsonEncode({'items': page, 'next_cursor': null}),
        _ => jsonEncode({'items': <Object>[]}),
      });
      await req.response.close();
      answered.add(path);
    }));
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await server.close(force: true);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<WorkerRepo> repo() => WorkerRepo.bindSupabaseWithMk(
        baseUrl: url,
        session: const SupabaseSession(
          accessToken: 't',
          refreshToken: 'r',
          expiresAt: 4102444800, // far future: never triggers a token refresh
          userId: 'test-user',
        ),
        mk: mk,
      );

  test('a pulled page is on screen before the slow reads come back', () async {
    // The account, the tombstones and the AI records all take their time. The
    // item pull answers at once.
    slow.addAll(['/account', '/tombstones', '/ai']);
    final r = await repo();
    await r.loadLocal();

    List<String>? answeredAtFirstPaint;
    List<String>? uidsAtFirstPaint;
    r.changes.addListener(() {
      if (answeredAtFirstPaint != null) return;
      answeredAtFirstPaint = List.of(answered);
      uidsAtFirstPaint = r.all.map((x) => x.uid).toList();
    });

    await r.syncDelta();

    expect(uidsAtFirstPaint, ['fresh'],
        reason: 'the first publish must carry the pulled item');
    expect(answeredAtFirstPaint, isNot(contains('/tombstones')),
        reason: 'the item was shown before the tombstones answered');
    expect(answeredAtFirstPaint, isNot(contains('/ai')),
        reason: 'the item was shown before the AI records answered');
    expect(r.sync.kind, SyncKind.synced);
    expect(answered, containsAll(['/account', '/tombstones', '/ai']),
        reason: 'the slow reads still complete within the pass');
  });

  test('the side reads go out alongside the item pull', () async {
    // Hold the item pull so the others have time to arrive. They must already
    // be in flight by then: a pass that sent them one after another, waiting
    // on each, would have the pull arrive alone.
    slow.add('/relics');
    final r = await repo();
    await r.loadLocal();
    await r.syncDelta();

    final pullAt = arrivals.indexOf('/relics');
    expect(pullAt, greaterThanOrEqualTo(0));
    final beforePull = arrivals.take(pullAt).toSet();
    expect(beforePull, containsAll(['/account', '/tombstones']),
        reason: 'the account and tombstone reads were sent with the pull');
    expect(arrivals.indexOf('/ai'), greaterThan(pullAt),
        reason: 'AI records still come after the items they decorate');
    expect(r.all.map((x) => x.uid), ['fresh']);
    expect(r.sync.kind, SyncKind.synced);
  });

  test('a cold pull walks the vault first, then everything, newest first',
      () async {
    final r = await repo();
    await r.loadLocal();
    await r.syncDelta();
    // Nothing cached: the vault walk, then the full walk. The server here
    // answers both with the same page, and the second sees it as not news.
    expect(pulls.map((q) => q['promoted']), ['1', null]);
    expect(pulls.map((q) => q['order']), ['desc', 'desc']);
    expect(pulls.map((q) => q['since']), ['0', '0']);
    expect(r.all.map((x) => x.uid), ['fresh']);
    expect(r.sync.kind, SyncKind.synced);

    // With a cursor there is only the one walk.
    pulls.clear();
    await r.syncDelta();
    expect(pulls.map((q) => q['promoted']), [null]);
    expect(pulls.single['since'], isNot('0'));
  });

  test('a tombstone fetched alongside the pull still removes the item',
      () async {
    final r = await repo();
    await r.loadLocal();
    await r.syncDelta();
    expect(r.all.map((x) => x.uid), ['fresh']);

    // The next pass finds the item deleted on another device. The server no
    // longer lists it, and its tombstone is applied after the pull, so the
    // row goes even though the two reads were in flight together.
    page = [];
    tombs = [
      {'uid': 'fresh', 'deleted_at': 20},
    ];
    await r.syncDelta();
    expect(r.all, isEmpty);
    expect(r.sync.kind, SyncKind.synced);
  });

  test('a tombstone read that fails leaves the pass offline', () async {
    // The tombstones are fetched alongside the pull and never throw from
    // there, so the pass has to notice on its own that they did not come.
    tombstonesFail = true;
    final r = await repo();
    await r.loadLocal();
    await r.syncDelta();
    expect(r.all.map((x) => x.uid), ['fresh'],
        reason: 'the pulled page was still shown');
    expect(r.sync.kind, SyncKind.offline);
  });
}

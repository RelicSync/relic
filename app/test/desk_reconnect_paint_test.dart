// Reconnecting to an account on the desktop (Switch account, or signing in
// again after a disconnect) pulled the whole vault before showing any of it.
// The list sat empty under "Syncing" for as long as every page took to come
// down, and on a big vault that was minutes. Now each page goes on screen as
// it lands, newest first, and a page's decrypt and index work leaves the UI
// isolate. This pins the on-screen half; worker/test/relic.test.ts pins the
// newest-first order on the server.
//
// LocalDeskRepo reads its data dir from RELIC_DATA_DIR, which cannot be set
// from inside a test, so like desk_sync_chip_test.dart this runs only when
// the invoker points that at a sandbox:
//
//   RELIC_DATA_DIR=$(mktemp -d) flutter test test/desk_reconnect_paint_test.dart
//
// See clear_history_test.dart for why real networking has to be restored:
// flutter_test answers every HttpClient with 400.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_crypto/relic_crypto.dart';

class _RealNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..connectionTimeout = const Duration(milliseconds: 500);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealNetwork();

  final sandbox = Platform.environment['RELIC_DATA_DIR'];
  final guarded =
      sandbox == null || sandbox.toLowerCase().contains('roaming');
  final mk = Uint8List.fromList(List.generate(32, (i) => i * 7 & 0xff));

  late HttpServer server;
  late String url;
  // The query string of every /relics request, in arrival order.
  late List<Map<String, String>> pulls;
  // What the server answers: the vault walk (`promoted=1`), the first page
  // of the full walk, and the page behind the cursor. That last one waits on
  // [release], which is the test's hand on the network.
  late Map<String, Object?> vault;
  late Map<String, Object?> first;
  late Map<String, Object?> rest;
  late Completer<void> release;

  Future<Map<String, dynamic>> envFor(String uid, String content, int at,
      {bool promoted = false}) async {
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
      'created_at': at,
      'updated_at': at,
      'byte_size': content.length,
      'promoted': promoted,
      'n': sealed['n'],
      'ct': sealed['ct'],
    };
  }

  setUp(() async {
    pulls = [];
    vault = {'items': const <Object>[], 'next_cursor': null};
    first = {'items': const <Object>[], 'next_cursor': null};
    rest = {'items': const <Object>[], 'next_cursor': null};
    release = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${server.port}';
    unawaited(server.forEach((req) async {
      final path = req.uri.path;
      await req.drain<void>();
      Future<void> json(Object body) async {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(body));
        await req.response.close();
      }

      if (path == '/relics') {
        final q = req.uri.queryParameters;
        pulls.add(q);
        if (q['promoted'] == '1') {
          await json(vault);
        } else if (q['cursor'] == null) {
          await json(first);
        } else {
          await release.future;
          await json(rest);
        }
        return;
      }
      if (path == '/tombstones') {
        await json({'items': const []});
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    }));
  });

  tearDown(() async {
    if (!release.isCompleted) release.complete();
    await server.close(force: true);
  });

  Future<LocalDeskRepo> bound() async {
    final repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    repo.setMlEnrich(false); // hermetic: no sift sidecar
    // No poll timer and no socket: only the code under test moves the queue.
    repo.debugBindSync(url, mk);
    return repo;
  }

  Future<void> until(bool Function() ok,
      {Duration limit = const Duration(seconds: 10)}) async {
    final end = DateTime.now().add(limit);
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('the first page is on screen while the rest is still coming down',
      () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    // The sandbox outlives one test, so every row this test plants is its
    // own.
    final tag = DateTime.now().microsecondsSinceEpoch;
    final saved = 'saved-$tag';
    final newest = 'new-$tag';
    final oldest = 'old-$tag';
    final vaultEnv =
        await envFor(saved, 'saved to the vault $tag', 150, promoted: true);
    vault = {
      'items': [vaultEnv],
      'next_cursor': null,
    };
    first = {
      'items': [await envFor(newest, 'copied yesterday $tag', 200), vaultEnv],
      'next_cursor': '150:$saved',
    };
    rest = {
      'items': [await envFor(oldest, 'copied last year $tag', 100)],
      'next_cursor': null,
    };
    final repo = await bound();
    var notes = 0;
    repo.addListener(() => notes++);

    final pull = repo.syncNow();
    // The vault walk landed and was painted before anything else: the saved
    // item is in the visible window and the listener was told.
    await until(() => repo.visible.any((r) => r.uid == saved));
    expect(notes, greaterThan(0));
    expect(pulls.first['promoted'], '1');
    expect(pulls.first['order'], 'desc');
    // Then the first page of everything, while the page behind it is still
    // being waited on.
    await until(() => repo.visible.any((r) => r.uid == newest));
    expect(pulls.length, 3);
    expect(pulls[1]['promoted'], isNull);
    expect(pulls[1]['cursor'], isNull);
    expect(pulls[2]['cursor'], '150:$saved');
    expect(repo.all.any((r) => r.uid == oldest), isFalse);
    // The chip still says the pull is running. That is the point: items on
    // screen under "Syncing", not an empty list under it.
    expect(repo.syncBusy, isTrue);

    release.complete();
    await pull;
    expect(repo.all.any((r) => r.uid == oldest), isTrue);
    expect(repo.all.where((r) => r.uid == saved).length, 1,
        reason: 'the vault item seen on both walks is one row');
    // The older page filled in underneath; the top of the list held still.
    final uids = repo.visible.map((r) => r.uid).toList();
    expect(uids.indexOf(newest), lessThan(uids.indexOf(saved)));
    expect(uids.indexOf(saved), lessThan(uids.indexOf(oldest)));
    expect(repo.syncBusy, isFalse);
  });

  test('a page the vault already has leaves the window alone', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    final tag = DateTime.now().microsecondsSinceEpoch;
    final uid = 'same-$tag';
    final env = await envFor(uid, 'already here $tag', 300);
    first = {
      'items': [env],
      'next_cursor': null,
    };
    final repo = await bound();
    release.complete();
    await repo.syncNow();
    expect(repo.all.any((r) => r.uid == uid), isTrue);
    // The same row again, no newer: the pull must not rewrite it, which is
    // what the LWW check used to guarantee one row at a time.
    final before = repo.all.firstWhere((r) => r.uid == uid);
    await repo.syncNow();
    final after = repo.all.firstWhere((r) => r.uid == uid);
    expect(after.updatedAt, before.updatedAt);
    expect(after.content, before.content);
  });
}

// Two things the desktop picker used to say that were not true.
//
// "Syncing…" on a text item for ten or twenty seconds: a capture that landed
// while a flush pass was already draining had its kick dropped by the
// in-flight guard, so the new row waited for the next poll (45 seconds with
// the doorbell up). A request the edge had quietly dropped waited on the OS
// connect timeout, and a transient failure waited for that same poll before
// anything retried.
//
// "Offline" on the header chip, then "Synced" three seconds later: one failed
// request anywhere in a cycle flipped the flag on the spot, and opening the
// picker was simply when the user caught it. The flag also began life as
// false, so the very first frame after a bind read "Offline".
//
// LocalDeskRepo reads its data dir from RELIC_DATA_DIR, which cannot be set
// from inside a test, so like annotate_test.dart this runs only when the
// invoker points that at a sandbox:
//
//   RELIC_DATA_DIR=$(mktemp -d) flutter test test/desk_sync_chip_test.dart
//
// See clear_history_test.dart for why real networking has to be restored:
// flutter_test answers every HttpClient with 400. The short connect timeout
// is for Jordan's Windows box, where a loopback connect now and then hangs or
// dies with errno 10057 (sync_coalesce_test.dart sees the same); the retry
// under test takes over from there, so the waits below allow a few doublings.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/widgets/chrome.dart' show SyncKind;

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
  var putDelay = Duration.zero; // hold each relic put this long
  var dropPuts = 0; // destroy the socket under the next N relic puts
  var failPulls = false; // answer /relics with 500
  var puts = <String>[]; // relic uids the server accepted, in order

  Future<void> json(HttpRequest req, Object body) async {
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await req.response.close();
  }

  setUp(() async {
    LocalDeskRepo.offlineGrace = const Duration(milliseconds: 400);
    LocalDeskRepo.retryDelay = const Duration(milliseconds: 150);
    putDelay = Duration.zero;
    dropPuts = 0;
    failPulls = false;
    puts = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${server.port}';
    unawaited(server.forEach((req) async {
      final path = req.uri.path;
      await req.drain<void>();
      if (req.method == 'PUT' && path.startsWith('/relic/')) {
        if (dropPuts > 0) {
          dropPuts--;
          final s = await req.response.detachSocket(writeHeaders: false);
          s.destroy();
          return;
        }
        if (putDelay > Duration.zero) await Future<void>.delayed(putDelay);
        puts.add(path.substring('/relic/'.length));
        await json(req, const <String, Object>{});
        return;
      }
      if (path == '/relics') {
        if (failPulls) {
          req.response.statusCode = 500;
          await req.response.close();
          return;
        }
        await json(req, {'items': const [], 'next_cursor': null});
        return;
      }
      if (path == '/tombstones') {
        await json(req, {'items': const []});
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    }));
  });

  tearDown(() async {
    await server.close(force: true);
    LocalDeskRepo.offlineGrace = const Duration(seconds: 15);
    LocalDeskRepo.retryDelay = const Duration(seconds: 3);
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

  Relic rowWith(LocalDeskRepo repo, String text) =>
      repo.all.firstWhere((x) => x.content == text);

  test('the idle chip before the first cycle reads synced, not offline',
      () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    final repo = await bound();
    expect(repo.sync.kind, SyncKind.synced);
  });

  test('a capture made while a push is in flight goes out right after it',
      () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    final repo = await bound();
    putDelay = const Duration(milliseconds: 300);
    final tag = DateTime.now().microsecondsSinceEpoch;
    repo.captureText('first $tag');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    repo.captureText('second $tag'); // lands mid-flush: the kick used to drop
    await until(() => puts.length == 2);
    expect(puts, [
      rowWith(repo, 'first $tag').uid,
      rowWith(repo, 'second $tag').uid,
    ]);
    expect(repo.relicSync(rowWith(repo, 'second $tag')), RelicSync.synced);
    expect(repo.sync.kind, SyncKind.synced);
  });

  test('a dropped connection keeps the green dot and retries on its own',
      () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    final repo = await bound();
    dropPuts = 1;
    final text = 'alpha ${DateTime.now().microsecondsSinceEpoch}';
    repo.captureText(text);
    // The first put dies under the client. Nothing else is running, so only
    // the failure-armed retry can land it.
    await until(() => puts.length == 1);
    await until(() => repo.relicSync(rowWith(repo, text)) == RelicSync.synced);
    expect(repo.sync.kind, SyncKind.synced);
    // The retry ran a whole cycle, so the pull behind the push landed too.
    await until(() => repo.lastSyncedAt != null);
  });

  test('a refused pull is offline only once the streak outlives the grace',
      () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    final repo = await bound();
    failPulls = true;
    await repo.syncNow();
    // Just failed: still inside the grace, so the chip says nothing yet.
    expect(repo.sync.kind, SyncKind.synced);
    var notes = 0;
    repo.addListener(() => notes++);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    // The retries kept failing, the grace ran out, and the chip was told.
    expect(repo.sync.kind, SyncKind.offline);
    expect(notes, greaterThan(0));
    // The server comes back: the next retry ends the streak by itself.
    failPulls = false;
    await until(() => repo.sync.kind == SyncKind.synced);
  });
}

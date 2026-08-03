import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_crypto/relic_crypto.dart';
import 'package:relic_app/data/net.dart';
import 'package:relic_app/data/supabase_auth.dart';
import 'package:relic_app/data/worker_repo.dart';
import 'package:relic_app/widgets/chrome.dart' show Scope;

// Two launch problems, one root cause: the mobile splash awaited a full network
// sync before painting, and every request on that path had no timeout at all.
// So "slow network" and "no network" both looked like a frozen logo, and a
// captive portal that accepts the connection and never answers could hold it
// open indefinitely.
//
// load() is now split: loadLocal() is everything needed to SHOW the vault (read
// cache, unwrap key, decrypt, index) and is the only thing a launch awaits;
// syncDelta() runs behind the painted UI. These tests pin that separation, and
// the offline-write behaviour that "works without a network" actually requires.
//
// See offline_launch_test.dart for why real networking must be restored:
// flutter_test answers every HttpClient with 400, which the outbox treats as a
// PERMANENT rejection and drops.
class _RealNetwork extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealNetwork();

  final mk = Uint8List.fromList(List.generate(32, (i) => i * 3 & 0xff));

  group('netTimeoutForBytes', () {
    test('small payloads get the short interactive deadline', () {
      expect(netTimeoutForBytes(0), kNetTimeout);
      expect(netTimeoutForBytes(1024), kNetTimeout);
      expect(netTimeoutForBytes(256 * 1024), kNetTimeout);
    });

    test('bigger payloads get more room, in proportion', () {
      final oneMb = netTimeoutForBytes(1024 * 1024);
      final tenMb = netTimeoutForBytes(10 * 1024 * 1024);
      expect(oneMb, greaterThan(kNetTimeout));
      expect(tenMb, greaterThan(oneMb));
    });

    test('never exceeds the blob ceiling, even at absurd sizes', () {
      // A one-line snippet and a 90 MB video share this code path; the point of
      // scaling is that the snippet never inherits the video's deadline, and
      // the video never gets an unbounded one.
      expect(netTimeoutForBytes(100 * 1024 * 1024), lessThanOrEqualTo(kBlobTimeout));
      expect(netTimeoutForBytes(1 << 40), kBlobTimeout);
    });
  });

  group('launch does not touch the network', () {
    late Directory tmp;
    late HttpServer stalling;
    late String stalledUrl;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('relic_offline_first_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => tmp.path,
      );
      // A server that ACCEPTS the connection and then never answers. This is the
      // case a missing timeout can't survive: unlike a refused port, nothing
      // fails fast, so anything awaiting it waits for the OS TCP timeout.
      stalling = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      stalling.listen((_) {/* deliberately never responds */});
      stalledUrl = 'http://127.0.0.1:${stalling.port}';
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      await stalling.close(force: true);
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

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
        'promoted': true,
        'n': sealed['n'],
        'ct': sealed['ct'],
      };
    }

    Future<WorkerRepo> repoAt(String baseUrl) => WorkerRepo.bindSupabaseWithMk(
          baseUrl: baseUrl,
          session: const SupabaseSession(
            accessToken: '',
            refreshToken: 'stored-refresh',
            expiresAt: 0,
            userId: 'test-user',
            email: 'user@example.com',
          ),
          mk: mk,
        );

    test('loadLocal paints the vault while the server never answers', () async {
      File('${tmp.path}/relic_cache.json').writeAsStringSync(jsonEncode({
        'account': 'test-user',
        'cursor': 500,
        'items': [
          await envFor('a', 'alpha'),
          await envFor('b', 'bravo'),
        ],
      }));

      final repo = await repoAt(stalledUrl);
      final started = DateTime.now();
      await repo.loadLocal();
      final took = DateTime.now().difference(started);

      // The whole point: the cached vault is decrypted and ready without a
      // single byte crossing the wire. load() would have blocked here on
      // syncDelta until the server answered — which it never does.
      expect(repo.all.map((r) => r.uid), containsAll(['a', 'b']));
      expect(took, lessThan(const Duration(seconds: 3)),
          reason: 'loadLocal must not wait on any request');
    });

    test('loadLocal on a device with no cache yet still completes', () async {
      final repo = await repoAt(stalledUrl);
      await expectLater(repo.loadLocal(), completes);
      expect(repo.all, isEmpty);
    });

    // The search index is built AFTER the launch paints, and the derive half
    // runs on another isolate, so there is a window of a few seconds where a
    // launch is fully interactive but the index does not exist yet.
    //
    // Searching in that window used to force the whole build to run
    // synchronously on the UI isolate — reintroducing the exact freeze the
    // deferral removed, on the keystroke that triggers it. It must answer from
    // the degraded matcher instead, then upgrade itself when the index lands.
    test('a search during the deferred index build answers now, upgrades later',
        () async {
      File('${tmp.path}/relic_cache.json').writeAsStringSync(jsonEncode({
        'account': 'test-user',
        'cursor': 1,
        'items': [
          await envFor('a', 'kubernetes deployment notes'),
          await envFor('b', 'grocery list'),
        ],
      }));

      final repo = await repoAt(stalledUrl);
      var ready = false;
      repo.onIndexReady = () => ready = true;
      await repo.loadLocal();

      // Deliberately NO pump/await here: the build is still owed, which is the
      // case a user hits by opening the app and typing straight away.
      await repo.setQuery('kubernetes', Scope.all);
      expect(repo.visible.map((r) => r.uid), ['a'],
          reason: 'a literal query must still be answerable immediately');
      expect(repo.matchCount, 1);

      // A typo only the trigram index can resolve. Its coming back EMPTY is the
      // proof that the answer above came from the degraded matcher and not from
      // a build forced synchronously behind the query.
      await repo.setQuery('kubernets', Scope.all);
      expect(repo.visible, isEmpty);
      expect(ready, isFalse);

      for (var i = 0; i < 100 && !ready; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(ready, isTrue,
          reason: 'the UI has no listener on the repo, so it must be told');
      expect(repo.visible.map((r) => r.uid), ['a'],
          reason: 'the typo query must re-answer itself from the real index');
    });
  });

  group('writes survive with no network', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('relic_offline_write_');
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

    // Discard port: every request fails transiently, which is what "offline"
    // looks like to the repo.
    Future<WorkerRepo> offlineRepo() => WorkerRepo.bindSupabaseWithMk(
          baseUrl: 'http://127.0.0.1:9',
          session: const SupabaseSession(
            accessToken: '',
            refreshToken: 'stored-refresh',
            expiresAt: 0,
            userId: 'test-user',
            email: 'user@example.com',
          ),
          mk: mk,
        );

    Map<String, dynamic> readCache() => jsonDecode(
        File('${tmp.path}/relic_cache.json').readAsStringSync())
        as Map<String, dynamic>;

    test('capturing a file offline keeps the relic AND its bytes', () async {
      final repo = await offlineRepo();
      final bytes = Uint8List.fromList(List.generate(2048, (i) => i & 0xff));

      // This used to throw: captureFile awaited the upload, and _uploadBlob
      // throws when it fails, so sharing a file with no signal lost it outright.
      await expectLater(
        repo.captureFile(bytes, filename: 'report.pdf', mime: 'application/pdf'),
        completes,
      );

      expect(repo.all, hasLength(1));
      final r = repo.all.single;
      expect(r.filename, 'report.pdf');
      expect(r.blobKey, isNotNull);

      // The bytes are on the device, so the relic is fully usable here: it can
      // be viewed, opened and saved to Downloads with no network.
      final cached = repo.cachedBlobPath(r);
      expect(cached, isNotNull);
      expect(File(cached!).readAsBytesSync(), equals(bytes));

      // And the upload is queued rather than abandoned.
      expect(repo.debugBlobOutbox, [r.blobKey]);
      expect(repo.debugOutbox, hasLength(1));
    });

    test('capturing an image offline queues its blob too', () async {
      final repo = await offlineRepo();
      await repo.captureImage(
        Uint8List.fromList(List.filled(64, 7)),
        mime: 'image/png',
        filename: 'shot.png',
      );
      expect(repo.all, hasLength(1));
      expect(repo.debugBlobOutbox, hasLength(1));
    });

    test('the blob queue is persisted, so a relaunch still retries', () async {
      final repo = await offlineRepo();
      await repo.captureFile(Uint8List.fromList([1, 2, 3]), filename: 'a.bin');
      final key = repo.all.single.blobKey;

      expect(readCache()['blobOutbox'], [key],
          reason: 'a queue only in memory is lost the moment the app closes');

      // A fresh repo (the relaunch) picks the queue back up.
      final reopened = await offlineRepo();
      await reopened.primeCache();
      expect(reopened.debugBlobOutbox, [key]);
    });

    test('a queued blob whose local file is gone is dropped, not retried forever',
        () async {
      final repo = await offlineRepo();
      await repo.captureFile(Uint8List.fromList([9, 9]), filename: 'gone.bin');
      final r = repo.all.single;
      File(repo.cachedBlobPath(r)!).deleteSync(); // cache eviction

      await repo.syncDelta(); // flushes the blob queue first

      expect(repo.debugBlobOutbox, isEmpty,
          reason: 'there are no bytes left to send, so the key must not stick');
      expect(readCache()['blobOutbox'], isEmpty);
    });

    test('editing and deleting offline both queue instead of failing', () async {
      final repo = await offlineRepo();
      await repo.captureText('note to edit');
      final r = repo.all.single;

      await expectLater(repo.updateMeta(r, title: 'renamed'), completes);
      expect(repo.all.single.title, 'renamed');

      await expectLater(repo.delete(repo.all.single), completes);
      expect(repo.all, isEmpty);
      expect(repo.debugOutbox.any((o) => o['op'] == 'delete'), isTrue);
    });
  });
}

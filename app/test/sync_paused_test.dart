// The free plan syncs one device (worker/src/syncplan.ts). A device that is
// not the one gets 403 sync_paused on every sync route. These tests pin what
// the apps do with that: say so instead of "Offline", keep what was captured
// queued rather than dropping it, ask again only every few minutes, and pick
// this device on request.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relic_app/data/supabase_auth.dart';
import 'package:relic_app/data/sync_plan.dart';
import 'package:relic_app/data/worker_repo.dart';
import 'package:relic_app/widgets/chrome.dart' show SyncKind;

class _RealNetwork extends HttpOverrides {}

String pausedBody({String keep = 'pc'}) => jsonEncode({
      'error': 'sync_paused',
      'message': 'Free plans sync one device. Sync is paused on this one.',
      'sync_until': 1000,
      'sync_device': keep,
      'devices': [
        {
          'device_id': 'pc',
          'label': "Jordan's PC",
          'platform': 'windows',
          'this_device': false,
        },
        {
          'device_id': 'phone',
          'label': null,
          'platform': 'android',
          'this_device': true,
        },
      ],
    });

void main() {
  group('SyncPause', () {
    test('reads the 403 body', () {
      final p = SyncPause.fromBody(pausedBody())!;
      expect(p.syncUntil, 1000);
      expect(p.syncDevice, 'pc');
      expect(p.devices, hasLength(2));
      expect(p.devices[1].thisDevice, isTrue);
      expect(p.syncDeviceName, "Jordan's PC");
      expect(p.message, contains("yours is Jordan's PC"));
    });

    test('ignores every other error', () {
      expect(SyncPause.fromBody('{"error":"email_unverified"}'), isNull);
      expect(SyncPause.fromBody('not json'), isNull);
      expect(SyncPause.fromBody('[]'), isNull);
    });

    test('names an unlabelled device by its platform', () {
      final p = SyncPause.fromBody(pausedBody(keep: 'phone'))!;
      expect(p.syncDeviceName, 'your Android phone');
    });

    test('falls back when the syncing device is not listed', () {
      final p = SyncPause.fromBody(pausedBody(keep: 'gone'))!;
      expect(p.syncDeviceName, isNull);
      expect(p.message, startsWith('Sync is paused here.'));
    });
  });

  group('SyncPauseGate', () {
    test('publishes a pause and spaces out the re-checks', () {
      final g = SyncPauseGate();
      final t0 = DateTime(2026, 11, 1, 12);
      expect(g.absorb(403, pausedBody(), now: t0), isTrue);
      expect(g.holding, isTrue);
      expect(g.skipPull(now: t0.add(const Duration(minutes: 1))), isTrue);
      expect(
        g.skipPull(force: true, now: t0.add(const Duration(minutes: 1))),
        isFalse,
      );
      expect(g.skipPull(now: t0.add(kPausedRecheck)), isFalse);
      g.clear();
      expect(g.holding, isFalse);
      expect(g.skipPull(now: t0), isFalse);
    });

    test('leaves other refusals to the caller', () {
      final g = SyncPauseGate();
      expect(g.absorb(403, '{"error":"email_unverified"}'), isFalse);
      expect(g.absorb(500, pausedBody()), isFalse);
      expect(g.holding, isFalse);
    });
  });

  group('the free week countdown', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000);
    int inDays(double d) => 1000000 + (d * 86400).round();

    test('counts whole days, rounding up', () {
      expect(daysUntil(inDays(2.2), now: now), 3);
      expect(daysUntil(inDays(0.1), now: now), 1);
      expect(daysUntil(inDays(-1), now: now), 0);
    });

    test('says nothing outside the week', () {
      expect(syncWeekLine(null, now: now), isNull);
      expect(syncWeekLine(inDays(-0.5), now: now), isNull);
    });

    test('reads plainly', () {
      expect(
        syncWeekLine(inDays(3), now: now),
        'Free sync on all your devices ends in 3 days.',
      );
      expect(
        syncWeekLine(inDays(0.4), now: now),
        'Free sync on all your devices ends in 1 day.',
      );
    });
  });

  group('postSyncDevice', () {
    Future<SyncPickResult> pick(http.Client client) => http.runWithClient(
          () => postSyncDevice(
            url: Uri.parse('https://x/account/sync-device'),
            headers: const {'Authorization': 'Bearer t'},
            deviceId: 'phone',
          ),
          () => client,
        );

    test('sends the device id', () async {
      late Map<String, dynamic> sent;
      final r = await pick(MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        expect(req.headers['Authorization'], 'Bearer t');
        return http.Response('{"ok":true,"sync_device":"phone"}', 200);
      }));
      expect(sent, {'device_id': 'phone'});
      expect(r.outcome, SyncPickOutcome.ok);
      expect(r.message(), 'This device syncs now.');
    });

    test('reports the once-a-week limit with its date', () async {
      final at = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3 * 86400 - 60;
      final r = await pick(MockClient((_) async => http.Response(
            jsonEncode({'error': 'sync_switch_cooldown', 'retry_at': at}),
            429,
          )));
      expect(r.outcome, SyncPickOutcome.cooldown);
      expect(r.retryAt, at);
      expect(r.message(), contains('Try again in 3 days'));
    });

    test('a bare rate-limit 429 or a dead network is a plain failure',
        () async {
      expect(
        (await pick(MockClient((_) async => http.Response('', 429)))).outcome,
        SyncPickOutcome.failed,
      );
      expect(
        (await pick(MockClient((_) async => throw const SocketException('x'))))
            .outcome,
        SyncPickOutcome.failed,
      );
    });
  });

  group('WorkerRepo on a paused phone', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final mk = Uint8List.fromList(List.generate(32, (i) => i * 7 & 0xff));

    late Directory tmp;
    late HttpServer server;
    late String url;
    late bool paused;
    late List<String> arrivals; // "METHOD /path", in order
    late List<Object?> picks; // bodies of POST /account/sync-device

    setUp(() async {
      HttpOverrides.global = _RealNetwork();
      tmp = Directory.systemTemp.createTempSync('relic_sync_paused_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => tmp.path,
      );
      paused = true;
      arrivals = [];
      picks = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      url = 'http://127.0.0.1:${server.port}';
      unawaited(server.forEach((req) async {
        final path = req.uri.path;
        arrivals.add('${req.method} $path');
        final body = await utf8.decoder.bind(req).join();
        final account = path.startsWith('/account');
        if (path == '/account/sync-device') {
          picks.add(jsonDecode(body));
          paused = false;
          req.response
            ..statusCode = 200
            ..write('{"ok":true,"sync_device":"phone"}');
        } else if (paused && !account) {
          req.response
            ..statusCode = 403
            ..headers.contentType = ContentType.json
            ..write(pausedBody());
        } else {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(switch (path) {
              '/account' => jsonEncode({
                  'tier': 'free',
                  'storage_used': 0,
                  'storage_quota': 1000,
                  'vault_count': 0,
                  'sync_until': 1000,
                  'sync_device': 'pc',
                  'sync_paused': paused,
                }),
              '/relics' => jsonEncode({'items': [], 'next_cursor': null}),
              _ => jsonEncode({'items': <Object>[]}),
            });
        }
        await req.response.close();
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

    Future<WorkerRepo> repo() async {
      final r = await WorkerRepo.bindSupabaseWithMk(
        baseUrl: url,
        session: const SupabaseSession(
          accessToken: 't',
          refreshToken: 'r',
          expiresAt: 4102444800, // far future: never triggers a token refresh
          userId: 'test-user',
        ),
        mk: mk,
      );
      r.deviceId = 'phone';
      await r.loadLocal();
      return r;
    }

    test('reads as paused, not offline, and keeps captures queued', () async {
      final r = await repo();
      await r.syncDelta();
      expect(r.syncPaused.value, isNotNull);
      expect(r.syncPaused.value!.syncDevice, 'pc');
      expect(r.sync.kind, SyncKind.paused);

      await r.captureText('saved while paused');
      expect(arrivals.where((a) => a.startsWith('PUT /relic/')), isEmpty,
          reason: 'a paused phone must not push, and must not drop the op');
      await r.syncDelta(); // inside the re-check window: no request at all
      expect(arrivals.where((a) => a == 'GET /relics'), hasLength(1));
      expect(r.sync.kind, SyncKind.paused);
      expect(r.sync.pending, 1);
    });

    test('syncing this phone instead lifts the pause and sends the queue',
        () async {
      final r = await repo();
      await r.syncDelta();
      await r.captureText('saved while paused');

      final res = await r.syncThisDevice();
      expect(res.outcome, SyncPickOutcome.ok);
      expect(picks, [
        {'device_id': 'phone'},
      ]);
      expect(r.syncPaused.value, isNull);

      final end = DateTime.now().add(const Duration(seconds: 10));
      while (!arrivals.any((a) => a.startsWith('PUT /relic/'))) {
        if (DateTime.now().isAfter(end)) fail('the queued capture never went');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await r.syncDelta();
      expect(r.sync.kind, SyncKind.synced);
    });

    test('a pull that goes through lifts a pause set earlier', () async {
      final r = await repo();
      await r.syncDelta();
      await r.captureText('saved while paused');
      expect(r.syncPaused.value, isNotNull);
      paused = false; // say the account paid on the web
      SyncPauseGate.recheck = Duration.zero;
      addTearDown(() => SyncPauseGate.recheck = kPausedRecheck);
      await r.syncDelta();
      expect(r.syncPaused.value, isNull);
      // The pass that found the pause gone runs once more for the queue.
      final end = DateTime.now().add(const Duration(seconds: 10));
      while (!arrivals.any((a) => a.startsWith('PUT /relic/'))) {
        if (DateTime.now().isAfter(end)) fail('the queued capture never went');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
  });
}

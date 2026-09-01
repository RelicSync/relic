// Two things drive syncDelta on their own schedule: the foreground poll timer
// and the live-sync doorbell's wake. Overlapping passes were therefore normal,
// not exotic, and they share everything that matters — the cursor, the item
// list, and the one SyncState the chip reads.
//
// The visible symptom was the chip: whichever pass hit a transient error
// published "Offline" over the top of the other, which at that moment was
// happily pulling items into the list. The app said it had no connection while
// new items were visibly arriving over that connection.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/supabase_auth.dart';
import 'package:relic_app/data/worker_repo.dart';
import 'package:relic_app/widgets/chrome.dart';

class _RealNetwork extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealNetwork();

  final mk = Uint8List.fromList(List.generate(32, (i) => i * 11 & 0xff));

  late HttpServer server;
  late String url;
  var relicPulls = 0;
  var failNextRelicPull = false;

  setUp(() async {
    relicPulls = 0;
    failNextRelicPull = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${server.port}';
    unawaited(server.forEach((req) async {
      final path = req.uri.path;
      if (path == '/relics') {
        relicPulls++;
        if (failNextRelicPull) {
          failNextRelicPull = false;
          req.response.statusCode = 401; // the shape a stale bearer produces
          await req.response.close();
          return;
        }
        // Slow enough that a second caller lands while this one is in flight,
        // which is the whole point of the test.
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json;
      req.response.write(switch (path) {
        '/account' => jsonEncode({
            'tier': 'free',
            'storage_used': 0,
            'storage_quota': 1000,
            'vault_count': 0,
          }),
        _ => jsonEncode({'items': <Object>[]}),
      });
      await req.response.close();
    }));
  });

  tearDown(() => server.close(force: true));

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

  /// Await the follow-up pass. It is deliberately fire-and-forget (a wake is
  /// not something a caller waits on), so a test has to watch for it landing.
  Future<void> settle(bool Function() done) async {
    for (var i = 0; i < 500 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('overlapping callers ride one pass instead of racing', () async {
    final r = await repo();
    // Three callers at once, as a poll tick plus two doorbell wakes would be.
    await Future.wait([r.syncDelta(), r.syncDelta(), r.syncDelta()]);
    await settle(() => relicPulls >= 2);
    // One pass for the first caller, then a single follow-up standing in for
    // every wake that arrived while it ran — never one pass per caller.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(relicPulls, 2);
  });

  test('a pass that fails cannot flag offline over one that is working',
      () async {
    final r = await repo();
    failNextRelicPull = true; // the first pass takes a 401 and gives up

    final first = r.syncDelta();
    // A wake arriving mid-pass. Before coalescing this started a second,
    // independent pass racing the first; now it joins it and queues one
    // follow-up, which is what actually gets the items.
    final second = r.syncDelta();
    await Future.wait([first, second]);
    await settle(() => r.sync.kind != SyncKind.offline);

    expect(r.sync.kind, isNot(SyncKind.offline),
        reason: 'the follow-up pass succeeded, so the chip must not say offline');
    expect(relicPulls, 2);
  });

  test('a clean run reports synced', () async {
    final r = await repo();
    await r.syncDelta();
    expect(r.sync.kind, SyncKind.synced);
    expect(relicPulls, 1, reason: 'one caller, one pass');
  });
}

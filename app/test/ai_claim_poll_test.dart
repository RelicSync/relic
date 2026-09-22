// The enrich worker used to talk to the server even when it had nothing to say.
//
// _enrichCycle runs on a 6-second timer that never stops, and it asked the
// coordinator to divide up the work before checking whether there was any. On
// an idle vault the batch is empty every single time, so the app posted
// {"items":[]} to /ai/claim ten times a minute, forever, on every desktop.
//
// Measured against production on 2026-09-22, while chasing D1 overload errors:
// 64% of EVERY request the Worker served was one of these. 300 of 300 sampled
// bodies were 12 bytes. The server answers an empty claim without touching D1,
// but authentication runs first and had already charged the database twice
// before the handler saw the body, so an empty poll cost from end to end.
//
// The return value cannot pin this: an empty batch yields an empty set whether
// or not the request went out. Only a server watching for the POST can tell,
// which is why this drives a real loopback server.
//
// LocalDeskRepo reads its data dir from RELIC_DATA_DIR, which cannot be set
// from inside a test, so like desk_sync_chip_test.dart this runs only when the
// invoker points that at a sandbox:
//
//   RELIC_DATA_DIR=$(mktemp -d) flutter test test/ai_claim_poll_test.dart
//
// Real networking has to be restored because flutter_test answers every
// HttpClient with 400 (see clear_history_test.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/models/relic.dart';

class _RealNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..connectionTimeout = const Duration(milliseconds: 500);
}

Relic _relic(String uid) => Relic(
      uid: uid,
      createdAt: 1000,
      updatedAt: 1000,
      kind: Kind.string,
      source: Source.clipboard,
      promoted: true,
      byteSize: 16,
      content: 'body of $uid',
      preview: 'p',
      tags: const [],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealNetwork();

  final sandbox = Platform.environment['RELIC_DATA_DIR'];
  final guarded = sandbox == null || sandbox.toLowerCase().contains('roaming');
  final mk = Uint8List.fromList(List.generate(32, (i) => i * 7 & 0xff));

  late HttpServer server;
  late String url;
  var claims = <String>[]; // bodies of every POST /ai/claim we received

  setUp(() async {
    claims = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${server.port}';
    unawaited(server.forEach((req) async {
      final body = await utf8.decodeStream(req);
      if (req.method == 'POST' && req.uri.path == '/ai/claim') {
        claims.add(body);
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'granted': const <String>[],
            'done': const <Object>[],
            'lease_expires_at': 0,
          }));
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    }));
  });

  tearDown(() async => server.close(force: true));

  Future<LocalDeskRepo> bound() async {
    final repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    repo.setMlEnrich(false); // hermetic: no sift sidecar
    repo.debugBindSync(url, mk, deviceId: 'desk-under-test');
    return repo;
  }

  test('an empty batch makes no request at all', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    final repo = await bound();
    final granted = await repo.debugClaimAiWork(const [], 3);
    expect(granted, isEmpty);
    expect(claims, isEmpty, reason: 'an idle vault must not poll /ai/claim');
  });

  test('a batch with work in it still claims', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    final repo = await bound();
    await repo.debugClaimAiWork([_relic('u1'), _relic('u2')], 3);
    // The guard must not have swallowed a real claim: exactly one request,
    // carrying both uids at the level asked for.
    expect(claims, hasLength(1));
    final sent = jsonDecode(claims.single) as Map<String, dynamic>;
    final items = (sent['items'] as List).cast<Map<String, dynamic>>();
    expect(items.map((i) => i['uid']), ['u1', 'u2']);
    expect(items.every((i) => i['level'] == 3), isTrue);
  });
}

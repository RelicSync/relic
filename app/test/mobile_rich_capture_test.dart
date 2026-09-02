// The one Android capture path that can carry formatting.
//
// Phones have no clipboard watcher, so almost everything on Android arrives
// either through the share sheet or through the Quick Settings tile. The share
// sheet can never be styled: `receive_sharing_intent` hands Dart a bare String.
// The tile reads the clipboard itself, and a clipboard read CAN see the HTML
// flavor Chrome, Gmail and Docs publish alongside the text.
//
// These tests pin the repo half of that path — what gets stored, and the two
// rules that must survive it: plain text is authoritative, and a secret never
// carries formatting.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/models/rich_body.dart';
import 'package:relic_app/data/supabase_auth.dart';
import 'package:relic_app/data/worker_repo.dart';

class _RealNetwork extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test answers every HttpClient with a 400, which the outbox reads as
  // a permanent rejection. These captures are offline by design (port 9 is the
  // discard port), so let the real stack refuse the connection instead.
  HttpOverrides.global = _RealNetwork();

  final mk = Uint8List.fromList(List.generate(32, (i) => i * 7 & 0xff));

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('relic_mobile_rich_');
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
        baseUrl: 'http://127.0.0.1:9', // discard port: every push is offline
        session: const SupabaseSession(
          accessToken: '',
          refreshToken: 'stored-refresh',
          expiresAt: 0,
          userId: 'test-user',
          email: 'user@example.com',
        ),
        mk: mk,
      );

  test('a tile capture keeps the HTML the clipboard offered', () async {
    final r = await repo();
    expect(await r.captureText('Kessler Roofing', html: '<b>Kessler</b> Roofing'),
        isTrue);

    final stored = r.all.single;
    expect(stored.content, 'Kessler Roofing');
    expect(stored.rich?.html, '<b>Kessler</b> Roofing');
    expect(stored.rich?.rtf, isNull,
        reason: 'nothing on Android publishes or reads RTF');
    expect(stored.richIfCurrent, isNotNull,
        reason: 'the paste path must be willing to serve it');
  });

  test('a capture with no HTML is an ordinary capture, not a broken one',
      () async {
    final r = await repo();
    expect(await r.captureText('just some text'), isTrue);
    expect(r.all.single.rich, isNull);
    expect(r.all.single.content, 'just some text');
  });

  test('a secret never carries formatting', () async {
    final r = await repo();
    // The masked plain text would be scrubbed while the HTML flavor shipped the
    // same value in the clear.
    await r.captureText('glpat-AbCdEf0123456789AbCd',
        html: '<code>glpat-AbCdEf0123456789AbCd</code>');

    final stored = r.all.single;
    expect(stored.tags, contains('secret'), reason: 'the fixture must be one');
    expect(stored.rich, isNull);
    expect(stored.richIfCurrent, isNull);
  });

  test('re-copying styled text fills the formatting into the existing item',
      () async {
    final r = await repo();
    await r.captureText('quarterly numbers'); // taken plain first
    expect(r.all.single.rich, isNull);

    await r.captureText('quarterly numbers', html: '<i>quarterly</i> numbers');

    expect(r.all, hasLength(1), reason: 'a re-copy bumps, it never duplicates');
    expect(r.all.single.rich?.html, '<i>quarterly</i> numbers');
  });

  test('a plain re-copy does not strip formatting already stored', () async {
    final r = await repo();
    await r.captureText('quarterly numbers', html: '<i>quarterly</i> numbers');

    await r.captureText('quarterly numbers'); // the same text, taken plain

    expect(r.all, hasLength(1));
    expect(r.all.single.rich?.html, '<i>quarterly</i> numbers',
        reason: 'plain text is authoritative, but it is not a reason to lose '
            'a flavor we already have for exactly this text');
  });

  test('an oversized HTML flavor is dropped and the text still lands', () async {
    final r = await repo();
    final huge = '<p>${'x' * (kRichMaxBytes + 1024)}</p>';

    expect(await r.captureText('a big table', html: huge), isTrue);
    expect(r.all.single.content, 'a big table');
    expect(r.all.single.rich, isNull,
        reason: 'over the cap the formatting goes, never the capture');
  });

  test('formatting goes inert the moment the text is edited', () async {
    final r = await repo();
    await r.captureText('draft one', html: '<b>draft one</b>');

    await r.updateMeta(r.all.single, content: 'draft two');

    final stored = r.all.single;
    expect(stored.rich, isNotNull, reason: 'the field is still on the row');
    expect(stored.richIfCurrent, isNull,
        reason: 'the fingerprint no longer matches, so the flavor is inert');
  });

  test('the stored body survives a cache round trip', () async {
    final a = await repo();
    await a.captureText('styled note', html: '<b>styled</b> note');

    final b = await repo(); // a fresh launch reading the same cache
    await b.loadLocal();

    expect(b.all.single.rich?.html, '<b>styled</b> note');
    expect(
        utf8.encode(jsonEncode(b.all.single.rich!.toJson())).length,
        lessThanOrEqualTo(kRichMaxBytes));
  });
}

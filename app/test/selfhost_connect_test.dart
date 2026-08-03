import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:relic_crypto/relic_crypto.dart';
import 'package:relic_app/data/selfhost_link.dart';

/// Verifies the self-host client contract (the "Obsidian model", see
/// selfhost/). The passphrase-derived bearer is opaque to the server, so the
/// only pure-client invariant is that it is *deterministic* — every device that
/// knows the passphrase computes the same token and therefore the same
/// trust-on-first-use identity.
///
/// The live round-trip drives a REAL self-host server exactly the way the app
/// does (enroll → create/unwrap keyparams → seal a relic → put → list →
/// decrypt → seal a blob → put → get), proving the client crypto + wire agree
/// with the server. It runs only when `--dart-define=SELFHOST_URL=<url>` points
/// at a running instance, so the committed test stays CI-safe.
void main() {
  group('deriveSelfHostToken', () {
    test('is deterministic — same passphrase, same token (cross-device)', () {
      final a = RelicCrypto.deriveSelfHostToken('correct horse battery staple');
      final b = RelicCrypto.deriveSelfHostToken('correct horse battery staple');
      expect(a, b);
    });

    test('differs by passphrase', () {
      final a = RelicCrypto.deriveSelfHostToken('passphrase one');
      final b = RelicCrypto.deriveSelfHostToken('passphrase two');
      expect(a, isNot(b));
    });

    test('is a non-empty URL-safe base64 string (no padding)', () {
      final t = RelicCrypto.deriveSelfHostToken('a passphrase');
      expect(t, isNotEmpty);
      expect(t, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    });
  });

  group('SelfHostLink (config QR payload)', () {
    test('round-trips url + secret, never carries a passphrase', () {
      final link = SelfHostLink.build('http://192.168.1.10:8799', secret: 'sekret');
      expect(link.startsWith(SelfHostLink.prefix), isTrue);
      expect(link.contains('pass'), isFalse); // the passphrase is never in the QR
      final p = SelfHostLink.parse(link);
      expect(p?.url, 'http://192.168.1.10:8799');
      expect(p?.secret, 'sekret');
    });

    test('url only (no secret)', () {
      final p = SelfHostLink.parse(SelfHostLink.build('http://host:8787'));
      expect(p?.url, 'http://host:8787');
      expect(p?.secret, isNull);
    });

    test('rejects non-self-host / malformed strings', () {
      expect(SelfHostLink.parse('relic-pair:v1:abc:def:'), isNull);
      expect(SelfHostLink.parse('https://relic.space'), isNull);
      expect(SelfHostLink.parse('relic://selfhost'), isNull); // no url param
      expect(SelfHostLink.parse('not a uri at all ::::'), isNull);
    });
  });

  group('live self-host round-trip', () {
    const url = String.fromEnvironment('SELFHOST_URL');
    Map<String, String> auth(String token) => {'Authorization': 'Bearer $token'};

    test('enroll → keyparams → relic → blob against a running server', () async {
      final base = url.replaceAll(RegExp(r'/+$'), '');
      const pass = 'a-strong-test-passphrase';
      final token = RelicCrypto.deriveSelfHostToken(pass);

      // 1. Enroll (trust-on-first-use claims the fresh instance).
      final enroll = await http.post(
        Uri.parse('$base/enroll'),
        headers: {...auth(token), 'Content-Type': 'application/json'},
        body: jsonEncode({'device_id': 'test-dev-1', 'label': 'CI', 'platform': 'test'}),
      );
      expect(enroll.statusCode, 200, reason: 'enroll: ${enroll.body}');
      expect((jsonDecode(enroll.body) as Map)['tier'], 'max');

      // A wrong passphrase → a different token → rejected.
      final wrong = await http.post(
        Uri.parse('$base/enroll'),
        headers: {
          ...auth(RelicCrypto.deriveSelfHostToken('not the passphrase')),
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'device_id': 'test-dev-x'}),
      );
      expect(wrong.statusCode, 403);

      // 2. Fresh vault: create keyparams, then unwrap them back (parity).
      final kp0 = await http.get(Uri.parse('$base/keyparams'), headers: auth(token));
      expect(kp0.statusCode, 404);
      final (kp, mk) = await RelicCrypto.createKeyParams(pass);
      final putKp = await http.put(
        Uri.parse('$base/keyparams'),
        headers: {...auth(token), 'Content-Type': 'application/json'},
        body: jsonEncode(kp),
      );
      expect(putKp.statusCode, 200);
      final kp1 = await http.get(Uri.parse('$base/keyparams'), headers: auth(token));
      expect(kp1.statusCode, 200);
      final mk2 = await RelicCrypto.unwrapMasterKey(
          jsonDecode(kp1.body) as Map<String, dynamic>, pass);
      expect(mk2, mk, reason: 'a second device unwraps the same master key');

      // 3. Seal + PUT a relic, then list + decrypt it back.
      const uid = 'test-uid-0001';
      final sealed = await RelicCrypto.sealRelicPayload(
          mk, uid, {'kind': 'string', 'source': 'clipboard', 'content': 'hello self-host'});
      final env = {
        'v': 1,
        'uid': uid,
        'created_at': 1000,
        'updated_at': 1000,
        'byte_size': 15,
        'promoted': false,
        'n': sealed['n'],
        'ct': sealed['ct'],
      };
      final putRelic = await http.put(
        Uri.parse('$base/relic/$uid'),
        headers: {...auth(token), 'Content-Type': 'application/json'},
        body: jsonEncode(env),
      );
      expect(putRelic.statusCode, 200, reason: 'put relic: ${putRelic.body}');

      final list = await http.get(
        Uri.parse('$base/relics').replace(queryParameters: {'since': '0', 'limit': '500'}),
        headers: auth(token),
      );
      expect(list.statusCode, 200);
      final items = (jsonDecode(list.body)['items'] as List).cast<Map<String, dynamic>>();
      final got = items.firstWhere((e) => e['uid'] == uid);
      final payload = await RelicCrypto.openRelicPayload(mk, got);
      expect(payload?['content'], 'hello self-host');

      // 4. Seal + POST a blob (single-shot), then GET it and confirm the
      // plaintext is byte-identical after decrypt.
      const blobKey = 'testblob0001';
      final clear = Uint8List.fromList(List.generate(2048, (i) => i % 256));
      final wire = await RelicCrypto.sealBlob(mk, blobKey, clear);
      final putBlob = await http.post(
        Uri.parse('$base/blob').replace(queryParameters: {'id': blobKey}),
        headers: {...auth(token), 'Content-Type': 'application/octet-stream'},
        body: wire,
      );
      expect(putBlob.statusCode, 200, reason: 'put blob: ${putBlob.body}');
      expect((jsonDecode(putBlob.body) as Map)['key'], blobKey);
      final getBlob = await http.get(Uri.parse('$base/blob/$blobKey'), headers: auth(token));
      expect(getBlob.statusCode, 200);
      final back = await RelicCrypto.openBlob(mk, blobKey, getBlob.bodyBytes);
      expect(back, clear, reason: 'blob decrypts byte-for-byte');
    }, skip: url.isEmpty ? 'set --dart-define=SELFHOST_URL to run' : false);
  });
}

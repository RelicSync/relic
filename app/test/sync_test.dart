import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:relic_crypto/relic_crypto.dart';

void main() {
  test('cross-device sync round-trip on the live Worker', () async {
    final url = Platform.environment['RELIC_URL'];
    final token = Platform.environment['RELIC_SYNC_TOKEN'];
    final pass = Platform.environment['RELIC_SYNC_PASS'];
    if (url == null || token == null || pass == null) { markTestSkipped('set env'); return; }
    final base = url.replaceAll(RegExp(r'/+$'), '');
    final auth = {'Authorization': 'Bearer $token'};

    // Device A: create the vault key + push an encrypted relic
    final (kp, mkA) = await RelicCrypto.createKeyParams(pass);
    final putKp = await http.put(Uri.parse('$base/keyparams?replace=1'),
        headers: {...auth, 'Content-Type': 'application/json'}, body: jsonEncode(kp));
    expect(putKp.statusCode, 200, reason: 'PUT keyparams');
    final uid = 'synctest-${DateTime.now().millisecondsSinceEpoch}';
    final payload = {'kind': 'string', 'source': 'clipboard', 'content': 'cross device hello', 'preview': 'x', 'tags': [], 'user_tags': []};
    final sealed = await RelicCrypto.sealRelicPayload(mkA, uid, payload);
    final env = {'v': 1, 'uid': uid, 'created_at': 1, 'updated_at': 2, 'byte_size': 17, 'promoted': false, 'n': sealed['n'], 'ct': sealed['ct']};
    final putR = await http.put(Uri.parse('$base/relic/$uid'),
        headers: {...auth, 'Content-Type': 'application/json'}, body: jsonEncode(env));
    expect(putR.statusCode, 200, reason: 'PUT relic');

    // Device B: unwrap the key from the server, pull, decrypt
    final kpResp = await http.get(Uri.parse('$base/keyparams'), headers: auth);
    final mkB = await RelicCrypto.unwrapMasterKey(jsonDecode(kpResp.body) as Map<String, dynamic>, pass);
    expect(mkB, isNotNull, reason: 'device B unwrap key');
    final list = await http.get(Uri.parse('$base/relics?since=0&limit=500'), headers: auth);
    final items = (jsonDecode(list.body)['items'] as List).cast<Map<String, dynamic>>();
    final found = items.firstWhere((e) => e['uid'] == uid, orElse: () => {});
    expect(found.isNotEmpty, true, reason: 'relic returned by /relics');
    final dec = await RelicCrypto.openRelicPayload(mkB!, found);
    expect(dec?['content'], 'cross device hello');
    print('CROSS-DEVICE OK: device B decrypted device A relic');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('cross-device BLOB round-trip on the live Worker', () async {
    final url = Platform.environment['RELIC_URL'];
    final token = Platform.environment['RELIC_SYNC_TOKEN'];
    final pass = Platform.environment['RELIC_SYNC_PASS'];
    if (url == null || token == null || pass == null) { markTestSkipped('set env'); return; }
    final base = url.replaceAll(RegExp(r'/+$'), '');
    final auth = {'Authorization': 'Bearer $token'};

    // Device A: ensure a key exists, seal + upload a blob
    final (kp, mkA) = await RelicCrypto.createKeyParams(pass);
    await http.put(Uri.parse('$base/keyparams?replace=1'),
        headers: {...auth, 'Content-Type': 'application/json'}, body: jsonEncode(kp));
    final blobId = 'blob-${DateTime.now().millisecondsSinceEpoch}';
    final bytes = Uint8List.fromList(List.generate(4096, (i) => (i * 31 + 7) & 0xff));
    final wire = await RelicCrypto.sealBlob(mkA, blobId, bytes);
    final post = await http.post(Uri.parse('$base/blob').replace(queryParameters: {'id': blobId}),
        headers: auth, body: wire);
    expect(post.statusCode, 200, reason: 'POST blob');
    expect(jsonDecode(post.body)['key'], blobId);

    // Device B: unwrap key, download blob, decrypt → bytes match
    final mkB = await RelicCrypto.unwrapMasterKey(
        jsonDecode((await http.get(Uri.parse('$base/keyparams'), headers: auth)).body) as Map<String, dynamic>, pass);
    final get = await http.get(Uri.parse('$base/blob/$blobId'), headers: auth);
    expect(get.statusCode, 200, reason: 'GET blob');
    final dec = await RelicCrypto.openBlob(mkB!, blobId, get.bodyBytes);
    expect(dec, isNotNull, reason: 'decrypt blob');
    expect(dec, orderedEquals(bytes), reason: 'blob bytes match');
    print('BLOB CROSS-DEVICE OK: device B decrypted device A image bytes');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

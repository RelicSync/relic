@Tags(['live'])
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/api.dart';
import 'package:relic_app/data/http_relay.dart';
import 'package:relic_app/data/pairing.dart';

/// Live integration check against the deployed KV-backed /pair relay. Skipped
/// unless a bearer is supplied:
///   flutter test test/live_relay_test.dart --dart-define=RELIC_TEST_TOKEN=...
/// Validates the real KV timing the in-process MockRelay can't reproduce.
void main() {
  const token = String.fromEnvironment('RELIC_TEST_TOKEN');
  const base = kWorkerBaseUrl;

  test('live relay: full pairing round-trip transfers the MK', () async {
    if (token.isEmpty) {
      markTestSkipped('set RELIC_TEST_TOKEN to run');
      return;
    }
    final mk = Uint8List.fromList(List.generate(32, (i) => (i * 13 + 1) & 0xff));
    final relay =
        HttpRelay(baseUrl: base, bearer: () async => token, deviceId: 'pairtest');
    final trusted = await TrustedDevicePairing.display(relay, mk);
    final neu = await NewDevicePairing.fromQr(relay, trusted.qr);

    final sas = await Future.wait([trusted.handshake(), neu.handshake()]);
    expect(sas[0], sas[1], reason: 'SAS must match across the live relay');

    await trusted.approveAndDeliver();
    expect(await neu.receiveMk(), mk, reason: 'MK must transfer end-to-end');
  }, timeout: const Timeout(Duration(seconds: 120)));
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/mock_relay.dart';
import 'package:relic_app/data/pairing.dart';

void main() {
  final mk = Uint8List.fromList(List.generate(32, (i) => (i * 11 + 5) & 0xff));

  test('TRUSTED shows QR, NEW scans → SAS matches, MK transfers', () async {
    final relay = MockRelay();
    final trusted = await TrustedDevicePairing.display(relay, mk);
    final neu = await NewDevicePairing.fromQr(relay, trusted.qr);

    // Both run the handshake concurrently (interleaving on the event loop).
    final sas = await Future.wait([trusted.handshake(), neu.handshake()]);
    expect(sas[0], sas[1], reason: 'SAS must match on both screens');
    expect(sas[0], matches(RegExp(r'^\d{4}$')));

    // Human confirms → trusted approves → new device receives the key.
    await trusted.approveAndDeliver();
    expect(await neu.receiveMk(), mk);
  });

  test('NEW shows QR, TRUSTED scans → still transfers (camera-direction agnostic)',
      () async {
    final relay = MockRelay();
    final neu = await NewDevicePairing.display(relay);
    final trusted = await TrustedDevicePairing.fromQr(relay, neu.qr, mk);

    final sas = await Future.wait([neu.handshake(), trusted.handshake()]);
    expect(sas[0], sas[1]);

    await trusted.approveAndDeliver();
    expect(await neu.receiveMk(), mk);
  });

  test('the delivered MK slot is single-use (consumed on claim)', () async {
    final relay = MockRelay();
    final trusted = await TrustedDevicePairing.display(relay, mk);
    final neu = await NewDevicePairing.fromQr(relay, trusted.qr);
    await Future.wait([trusted.handshake(), neu.handshake()]);
    await trusted.approveAndDeliver();

    expect(await neu.receiveMk(), mk);
    // The slot is gone; a replay finds nothing and times out.
    expect(await relay.poll(trusted.pairingId, 'mk'), isNull);
  });

  test('an expired session is torn down; a re-put starts a fresh empty one',
      () async {
    // The real relay (KV) accepts any conforming id, so MockRelay.put no longer
    // throws for an unknown/expired id — instead the teardown is that the old
    // slots are gone and a re-put opens a fresh, empty session.
    final relay = MockRelay();
    final trusted = await TrustedDevicePairing.display(relay, mk);
    await relay.put(trusted.pairingId, 'tp', Uint8List.fromList([9]));
    relay.expire(trusted.pairingId);
    // Post-expiry reads see nothing (absent / expired / consumed all look alike).
    expect(await relay.poll(trusted.pairingId, 'tp'), isNull);
    expect(await relay.take(trusted.pairingId, 'tp'), isNull);
    // A re-put starts a fresh session; the old slot does not resurrect.
    await relay.put(trusted.pairingId, 'np', Uint8List.fromList([7]));
    expect(await relay.poll(trusted.pairingId, 'tp'), isNull);
    expect(await relay.poll(trusted.pairingId, 'np'), [7]);
  });

  test('MockRelay.put creates a session for an unknown id (relay parity)',
      () async {
    final relay = MockRelay();
    const id = 'deadbeefdeadbeefdeadbeefdeadbeef'; // 32 hex, passes isPairId
    await relay.put(id, 'np', Uint8List.fromList([1, 2, 3]));
    expect(await relay.poll(id, 'np'), [1, 2, 3]);
  });

  test('typed code: displayWithCode → fromCode (sloppy) → SAS → MK transfers',
      () async {
    final relay = MockRelay();
    const acct = 'user-abc';
    final trusted =
        await TrustedDevicePairing.displayWithCode(relay, mk, accountId: acct);
    // NEW types the code sloppily: lower case, spaces instead of hyphens.
    final sloppy = trusted.code.toLowerCase().replaceAll('-', ' ');
    final neu =
        await NewDevicePairing.fromCode(relay, sloppy, localAccountId: acct);

    final sas = await Future.wait([trusted.handshake(), neu.handshake()]);
    expect(sas[0], sas[1], reason: 'both sides derive the same session + SAS');

    await trusted.approveAndDeliver();
    expect(await neu.receiveMk(), mk);
  });

  test('the same code-minted session also pairs via its v2 QR', () async {
    final relay = MockRelay();
    const acct = 'user-abc';
    final trusted =
        await TrustedDevicePairing.displayWithCode(relay, mk, accountId: acct);
    final neu =
        await NewDevicePairing.fromQr(relay, trusted.qr, localAccountId: acct);

    final sas = await Future.wait([trusted.handshake(), neu.handshake()]);
    expect(sas[0], sas[1]);

    await trusted.approveAndDeliver();
    expect(await neu.receiveMk(), mk);
  });

  test('cancel() mid-handshake throws PairingCancelled promptly', () async {
    final relay = MockRelay();
    final trusted = await TrustedDevicePairing.display(relay, mk);
    final neu = await NewDevicePairing.fromQr(relay, trusted.qr);
    // NEW posts np and waits for tp that never comes; cancel unblocks the wait.
    final fut = neu.handshake();
    neu.cancel();
    await expectLater(fut, throwsA(isA<PairingCancelled>()));
  });

  test('after NEW rejects the SAS, the mk slot is never populated', () async {
    final relay = MockRelay();
    final trusted = await TrustedDevicePairing.display(relay, mk);
    final neu = await NewDevicePairing.fromQr(relay, trusted.qr);
    await Future.wait([trusted.handshake(), neu.handshake()]);
    neu.cancel(); // "they don't match" → receiveMk never called
    // Trusted never approves; nothing sealed the master key.
    expect(await relay.poll(trusted.pairingId, 'mk'), isNull);
  });

  test('QR round-trips and rejects non-Relic payloads', () {
    final ck = PairingCrypto.randomChannelKey();
    final qr = PairingCrypto.buildQr('abc-123', ck, relayHint: 'us');
    final p = PairingCrypto.parseQr(qr);
    expect(p.pairingId, 'abc-123');
    expect(p.channelKey, ck);
    expect(p.relayHint, 'us');
    expect(() => PairingCrypto.parseQr('https://evil.example'),
        throwsFormatException);
  });

  test('SAS/channel golden vector (pins the cross-impl transcript)', () async {
    // Frozen inputs → a fixed SAS + channel key. Any change to the transcript
    // definition (labels, field order, hashing) in PairingCrypto.deriveChannel
    // trips this, and a future Rust/relay reimplementation must reproduce it.
    Uint8List gen(int seed, int step) =>
        Uint8List.fromList(List.generate(32, (i) => (i * step + seed) & 0xff));
    final shared = gen(0, 1);
    final channelKey = gen(255, -1);
    final npPub = gen(0, 7);
    final tpPub = gen(1, 13);
    const pairingId = 'relic-test-vector-0001';

    final d = await PairingCrypto.deriveChannel(
      shared: shared,
      channelKey: channelKey,
      npPub: npPub,
      tpPub: tpPub,
      pairingId: pairingId,
    );
    String hex(Uint8List b) =>
        b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

    expect(d.sas, '1490');
    expect(hex(d.ckey),
        '3c17408aca314b688ecf5ccc8ca4351415fcc829e00ac4e3c2aec107aaab0c62');
  });

  test('a swapped pubkey (MITM) yields a non-matching SAS', () async {
    // Two independent exchanges: an attacker who substitutes a key cannot make
    // both sides land on the same shared secret, so the SAS diverges.
    final ckey = PairingCrypto.randomChannelKey();
    final a = await PairingCrypto.newEphemeral();
    final b = await PairingCrypto.newEphemeral();
    final evil = await PairingCrypto.newEphemeral();
    final aPub = await PairingCrypto.publicBytes(a);
    final bPub = await PairingCrypto.publicBytes(b);
    final evilPub = await PairingCrypto.publicBytes(evil);

    // Honest: A and B share directly.
    final sAB = await PairingCrypto.sharedSecret(a, bPub);
    final honest = await PairingCrypto.deriveChannel(
        shared: sAB, channelKey: ckey, npPub: aPub, tpPub: bPub, pairingId: 'p');

    // MITM: A actually talks to evil but still believes it's B (tpPub=bPub).
    final sAE = await PairingCrypto.sharedSecret(a, evilPub);
    final mitm = await PairingCrypto.deriveChannel(
        shared: sAE, channelKey: ckey, npPub: aPub, tpPub: bPub, pairingId: 'p');

    expect(mitm.sas, isNot(honest.sas));
  });
}

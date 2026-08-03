import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_crypto/relic_crypto.dart';
import 'package:relic_app/data/mock_relay.dart';
import 'package:relic_app/data/pairing.dart';
import 'package:relic_app/services/onboarding_service.dart';

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // --- 1. mint / display / parse round-trip + Crockford tolerance ------------

  test('code mint/display/parse round-trips; tolerant of case, spaces, I/L/O',
      () async {
    final code = PairingCode.mint(accountId: 'acct');
    final disp = code.display();
    expect(
        disp,
        matches(RegExp(
            r'^[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}$')));
    expect(disp[0], '2', reason: 'version symbol');

    // Exact, lower case + spaces for hyphens, and I/L/O folded to 1/0 all parse
    // to the same body.
    expect(PairingCode.parse(disp).body, code.body);
    expect(PairingCode.parse(disp.toLowerCase().replaceAll('-', ' ')).body,
        code.body);
    final folded = disp.replaceAll('1', 'I').replaceAll('0', 'O');
    expect(PairingCode.parse(folded).body, code.body);

    // ...and they derive an identical session.
    final d1 = await PairingCode.parse(disp).derive();
    final d2 = await PairingCode.parse(folded.toLowerCase()).derive();
    expect(d1.pairingId, d2.pairingId);
    expect(d1.channelKey, d2.channelKey);
  });

  // --- 2. checksum / version / length faults ---------------------------------

  test('a flipped check digit trips .checksum; bad version .version; short .format',
      () {
    final raw = PairingCode.mint(accountId: 'acct').display().replaceAll('-', '');

    // Flip the last (checksum) symbol: body18 is unchanged so the recomputed
    // checksum no longer matches — deterministically a checksum fault.
    final flipped =
        raw.substring(0, 19) + (raw[19] == '0' ? '1' : '0');
    expect(
        () => PairingCode.parse(flipped),
        throwsA(predicate((e) =>
            e is PairingCodeException &&
            e.kind == PairingCodeError.checksum)));

    // Wrong version symbol.
    expect(
        () => PairingCode.parse('3${raw.substring(1)}'),
        throwsA(predicate((e) =>
            e is PairingCodeException && e.kind == PairingCodeError.version)));

    // Wrong length.
    expect(
        () => PairingCode.parse(raw.substring(0, 19)),
        throwsA(predicate((e) =>
            e is PairingCodeException && e.kind == PairingCodeError.format)));

    // A non-Crockford symbol (U) at full length is also a format fault.
    expect(
        () => PairingCode.parse('${raw.substring(0, 19)}U'),
        throwsA(predicate((e) =>
            e is PairingCodeException && e.kind == PairingCodeError.format)));
  });

  // --- 3. code derivation golden ---------------------------------------------

  test('code derivation golden (frozen at implementation)', () async {
    const body18 = '2ABCDEFGHJKMNPQRST';
    final d = await PairingCrypto.deriveCode(body18);
    expect(d.pairingId, '9c474023c9ae367e5da3041412b3dc08');
    expect(d.pairingId, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(_hex(d.channelKey),
        'fcfc1905d6e1945e6549ac26ac2ca982a5c56a69c7e3a6520060ac8b841dd6e3');
  });

  // --- 5. account binding (hint golden + QR/code checks) ----------------------

  test('accountHint golden + v2/v1 QR binding checks', () async {
    const acct = 'relic-test-account-0001';
    expect(PairingCrypto.accountHint(acct).substring(0, 8), 'TXKP1KEV');

    final relay = MockRelay();
    final ck = PairingCrypto.randomChannelKey();
    const id = '9c474023c9ae367e5da3041412b3dc08';
    final qr = PairingCrypto.buildQrV2(id, ck,
        accountHint: PairingCrypto.accountHint(acct).substring(0, 8));

    // Same account → OK.
    final ok = await NewDevicePairing.fromQr(relay, qr, localAccountId: acct);
    expect(ok.pairingId, id);

    // Different account → rejected before any relay traffic.
    await expectLater(
        NewDevicePairing.fromQr(relay, qr, localAccountId: 'someone-else'),
        throwsA(isA<PairingAccountMismatch>()));

    // v1 QR + a known local account → no check (v1 carries no hint).
    final v1 = PairingCrypto.buildQr('abc-123', ck);
    expect((await NewDevicePairing.fromQr(relay, v1, localAccountId: acct))
            .pairingId,
        'abc-123');

    // Empty ah in a v2 QR → no check.
    final noAh = PairingCrypto.buildQrV2('abc-123', ck, accountHint: '');
    expect(
        (await NewDevicePairing.fromQr(relay, noAh, localAccountId: acct))
            .pairingId,
        'abc-123');
  });

  test('fromCode rejects a 2-char account-hint mismatch', () async {
    final relay = MockRelay();
    const mintAcct = 'relic-test-account-0001';
    final code = PairingCode.mint(accountId: mintAcct);

    // A local account whose 2-char hint differs (deterministic tiny search).
    final mintHint = PairingCrypto.accountHint(mintAcct).substring(0, 2);
    var other = 'other-0';
    var i = 0;
    while (PairingCrypto.accountHint(other).substring(0, 2) == mintHint) {
      other = 'other-${++i}';
    }
    await expectLater(
        NewDevicePairing.fromCode(relay, code.display(), localAccountId: other),
        throwsA(isA<PairingAccountMismatch>()));

    // Same account → no mismatch (constructs fine).
    final okay = await NewDevicePairing.fromCode(relay, code.display(),
        localAccountId: mintAcct);
    expect(okay.pairingId, matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  // --- 8. mk_fp in keyparams --------------------------------------------------

  test('mk_fp: present, stable across rewrap, golden, and inert to unwrap',
      () async {
    final mk = Uint8List.fromList(List.generate(32, (i) => (i * 11 + 5) & 0xff));
    expect(_hex(RelicCrypto.mkFingerprint(mk)), 'bfe3cf9f9dd1197a');

    final (kp, generated) = await RelicCrypto.createKeyParams('p1');
    expect(kp.containsKey('mk_fp'), isTrue);
    // Rewrapping the same MK keeps the same fingerprint.
    final kpB = await RelicCrypto.rewrapKeyParams(generated, 'p2');
    expect(kpB['mk_fp'], kp['mk_fp']);
    // The extra field does not disturb the passphrase unwrap.
    expect(await RelicCrypto.unwrapMasterKey(kp, 'p1'), generated);
  });

  // --- 9. verifyPairedMk decision logic --------------------------------------

  test('decidePairedMk branch order', () {
    // A present fp is definitive, even if a trial-open would disagree.
    expect(OnboardingService.decidePairedMk(fpMatch: true), isTrue);
    expect(
        OnboardingService.decidePairedMk(
            fpMatch: false, envelopePresent: true, envelopeOpens: true),
        isFalse);
    // No fp → the trial-open decides.
    expect(
        OnboardingService.decidePairedMk(
            envelopePresent: true, envelopeOpens: true),
        isTrue);
    expect(
        OnboardingService.decidePairedMk(
            envelopePresent: true, envelopeOpens: false),
        isFalse);
    // Legacy keyparams (no fp) AND an empty vault → accept.
    expect(OnboardingService.decidePairedMk(), isTrue);
  });

  test('fingerprint compare + trial-open feed the decision', () async {
    final mk = Uint8List.fromList(List.generate(32, (i) => i));
    final wrong = Uint8List.fromList(List.generate(32, (i) => (i + 1) & 0xff));

    expect(RelicCrypto.mkFingerprint(mk), RelicCrypto.mkFingerprint(mk));
    expect(RelicCrypto.mkFingerprint(mk),
        isNot(RelicCrypto.mkFingerprint(wrong)));

    final sealed = await RelicCrypto.sealRelicPayload(mk, 'u1', {'x': 1});
    final env = {'uid': 'u1', ...sealed};
    expect(await RelicCrypto.openRelicPayload(mk, env), isNotNull);
    expect(await RelicCrypto.openRelicPayload(wrong, env), isNull);
  });
}

import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_crypto/relic_crypto.dart';

void main() {
  test('Argon2id matches relic-core pinned vector', () {
    final salt = Uint8List.fromList(List.filled(16, 0x42));
    final kek = RelicCrypto.deriveKek('correct horse battery staple', salt);
    final hex = kek.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    expect(hex, 'dde64ab2660a0dedd449fa0414587bd0407e68ebe4a3f1595f2c167f1f7ff3cd');
  });

  test('relic payload decrypt round-trips with AAD binding', () async {
    final mk = Uint8List.fromList(List.generate(32, (i) => i));
    final aead = Xchacha20.poly1305Aead();
    final payload = utf8.encode('{"kind":"string","source":"clipboard","content":"hi"}');
    final box = await aead.encrypt(payload,
        secretKey: SecretKey(mk),
        nonce: List.generate(24, (i) => 7),
        aad: utf8.encode('relic.relic.v1:uid-1'));
    final env = {
      'v': 1,
      'uid': 'uid-1',
      'n': base64.encode(box.nonce),
      'ct': base64.encode([...box.cipherText, ...box.mac.bytes]),
    };
    final got = await RelicCrypto.openRelicPayload(mk, env);
    expect(got?['content'], 'hi');
    final bad = {...env, 'uid': 'uid-2'};
    expect(await RelicCrypto.openRelicPayload(mk, bad), isNull);
  });

  test('create → rewrap under a new passphrase preserves the master key', () async {
    final (kp, mk) = await RelicCrypto.createKeyParams('first passphrase');
    // Original passphrase unwraps; a wrong one returns null (the key check).
    expect(await RelicCrypto.unwrapMasterKey(kp, 'first passphrase'), mk);
    expect(await RelicCrypto.unwrapMasterKey(kp, 'wrong'), isNull);

    final kp2 = await RelicCrypto.rewrapKeyParams(mk, 'second passphrase');
    // Same MK comes back under the new passphrase; the old one no longer works.
    expect(await RelicCrypto.unwrapMasterKey(kp2, 'second passphrase'), mk);
    expect(await RelicCrypto.unwrapMasterKey(kp2, 'first passphrase'), isNull);
    // Rewrap used a fresh salt + nonce (no reuse).
    expect(kp2['salt'], isNot(kp['salt']));
    expect(kp2['mk_nonce'], isNot(kp['mk_nonce']));
    // Shape is unchanged.
    expect(kp2.keys.toSet(), kp.keys.toSet());
  });

  test('ShareCrypto: wire shape, roundtrip, AAD binds the share id', () async {
    final id = ShareCrypto.mintId();
    expect(id.length, 22); // 16 bytes, unpadded base64url
    expect(RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(id), isTrue);

    final payload = {'v': 1, 'kind': 'text', 'text': 'wifi: hunter2'};
    final sealed = await ShareCrypto.seal(id, payload);
    expect(sealed.keyFragment.length, 43); // 32 bytes, unpadded base64url
    // iv(12) + ct(len(json)) + tag(16)
    expect(sealed.wire.length, greaterThan(29));

    // Roundtrip decrypts under the right (id, key).
    expect(await ShareCrypto.open(id, sealed.keyFragment, sealed.wire), payload);
    // A DIFFERENT share id must fail (AAD binding — ciphertext can't be
    // replayed under another share row).
    expect(await ShareCrypto.open(ShareCrypto.mintId(), sealed.keyFragment, sealed.wire),
        isNull);
    // A flipped ciphertext byte must fail.
    final tampered = Uint8List.fromList(sealed.wire);
    tampered[14] ^= 1;
    expect(await ShareCrypto.open(id, sealed.keyFragment, tampered), isNull);
  });
}

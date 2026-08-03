import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:hashlib/hashlib.dart';

/// Dart port of relic-core's crypto (wire-format.md), wire-compatible:
/// Argon2id KEK → unwrap XChaCha20-Poly1305 master key → decrypt relic
/// payloads. Pinned params must match the Rust exactly.
class RelicCrypto {
  static const int keyLen = 32;
  static const int nonceLen = 24;
  static const int saltLen = 16;
  static const _argonMemKiB = 64 * 1024;
  static const _argonIters = 3;
  static const _argonLanes = 4;

  static final _aead = Xchacha20.poly1305Aead();

  /// Argon2id(passphrase, salt) → 32-byte KEK. Pinned params (v0x13).
  static Uint8List deriveKek(String passphrase, Uint8List salt) {
    final d = Argon2(
      salt: salt,
      type: Argon2Type.argon2id,
      version: Argon2Version.v13,
      hashLength: keyLen,
      iterations: _argonIters,
      parallelism: _argonLanes,
      memorySizeKB: _argonMemKiB,
    ).convert(utf8.encode(passphrase));
    return Uint8List.fromList(d.bytes);
  }

  /// AEAD-decrypt. `ctWithTag` is Rust's ciphertext||tag(16). Throws on failure.
  static Future<Uint8List> _open(
      Uint8List key, Uint8List nonce, Uint8List ctWithTag, String aad) async {
    if (ctWithTag.length < 16) throw const FormatException('ciphertext too short');
    final cipherText = ctWithTag.sublist(0, ctWithTag.length - 16);
    final mac = Mac(ctWithTag.sublist(ctWithTag.length - 16));
    final clear = await _aead.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: SecretKey(key),
      aad: utf8.encode(aad),
    );
    return Uint8List.fromList(clear);
  }

  static Future<Uint8List> _seal(
      Uint8List key, Uint8List nonce, List<int> plaintext, String aad) async {
    final box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: utf8.encode(aad),
    );
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  /// A deterministic bearer token for **self-host** (account-less) sync, derived
  /// from the vault passphrase alone so every device computes the same token —
  /// the self-host server's trust-on-first-use enrollment then recognizes it
  /// (`selfhost/src/enroll.ts` stores only `sha256(token)`). Domain-separated
  /// from the vault KEK: this token only gates access to *ciphertext*; the vault
  /// master key stays a random key wrapped by the passphrase ([unwrapMasterKey]),
  /// so a leaked token can't decrypt anything. Derived once at connect and then
  /// persisted like a device token, so there's no repeat Argon2 pass on relaunch.
  ///
  /// The salt is a fixed, app-wide constant (not the per-vault keyparams salt):
  /// the token must be reproducible from the passphrase with no server round-trip,
  /// so a new device can enroll knowing only the URL + passphrase.
  static String deriveSelfHostToken(String passphrase) {
    final salt = Uint8List.fromList(sha256
        .convert(utf8.encode('relic.selfhost.authsalt.v1'))
        .bytes
        .sublist(0, saltLen));
    final kek = deriveKek(passphrase, salt);
    final digest = sha256
        .convert([...utf8.encode('relic.selfhost.authtoken.v1'), ...kek])
        .bytes;
    return base64Url.encode(digest).replaceAll('=', '');
  }

  /// Unwrap the master key from a keyparams record using the passphrase.
  /// Returns null on wrong passphrase.
  static Future<Uint8List?> unwrapMasterKey(
      Map<String, dynamic> keyparams, String passphrase) async {
    final salt = base64.decode(keyparams['salt'] as String);
    final kek = deriveKek(passphrase, Uint8List.fromList(salt));
    final nonce = Uint8List.fromList(base64.decode(keyparams['mk_nonce'] as String));
    final wrapped = Uint8List.fromList(base64.decode(keyparams['wrapped_mk'] as String));
    try {
      return await _open(kek, nonce, wrapped, 'relic.mkwrap.v1');
    } on SecretBoxAuthenticationError {
      return null;
    }
  }

  /// Decrypt a relic envelope's private payload → JSON map. AAD binds the uid.
  static Future<Map<String, dynamic>?> openRelicPayload(
      Uint8List mk, Map<String, dynamic> env) async {
    final uid = env['uid'] as String;
    final nonce = Uint8List.fromList(base64.decode(env['n'] as String));
    final ct = Uint8List.fromList(base64.decode(env['ct'] as String));
    try {
      final clear = await _open(mk, nonce, ct, 'relic.relic.v1:$uid');
      return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    } on SecretBoxAuthenticationError {
      return null;
    }
  }

  static final _rng = Random.secure();
  static Uint8List _randomNonce() =>
      Uint8List.fromList(List.generate(nonceLen, (_) => _rng.nextInt(256)));
  static Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

  /// A short, non-secret fingerprint of a master key: the first 8 bytes of
  /// `SHA-256(utf8('relic.mkfp.v1') || mk)`. It lets a device that received an MK
  /// over pairing confirm it opens *this* account's vault before binding, without
  /// revealing the key. Carried opaquely in keyparams as `mk_fp` (base64).
  static Uint8List mkFingerprint(Uint8List mk) => Uint8List.fromList(
      sha256.convert([...utf8.encode('relic.mkfp.v1'), ...mk]).bytes.sublist(0, 8));

  /// Wrap a master key under a passphrase → a fresh keyparams record (new salt
  /// and nonce, AAD `relic.mkwrap.v1`). The byte-for-byte shape matches
  /// relic-core's KeyParams / wire-format.md; `mk_fp` is an additive,
  /// backward-compatible field (older readers ignore it, the worker stores it
  /// opaquely).
  static Future<Map<String, dynamic>> _wrapMk(
      Uint8List mk, String passphrase) async {
    final salt = _randomBytes(saltLen);
    final kek = deriveKek(passphrase, salt);
    final nonce = _randomNonce();
    final wrapped = await _seal(kek, nonce, mk, 'relic.mkwrap.v1');
    return {
      'v': 1,
      'salt': base64.encode(salt),
      'argon2': {'m_kib': _argonMemKiB, 't': _argonIters, 'p': _argonLanes},
      'mk_nonce': base64.encode(nonce),
      'wrapped_mk': base64.encode(wrapped),
      'mk_fp': base64.encode(mkFingerprint(mk)),
    };
  }

  /// First device: generate a random master key, wrap it under the passphrase,
  /// and return the keyparams record (to PUT) + the master key. Matches
  /// relic-core's KeyParams::create / wire-format.md.
  static Future<(Map<String, dynamic>, Uint8List)> createKeyParams(
      String passphrase) async {
    final mk = _randomBytes(keyLen);
    return (await _wrapMk(mk, passphrase), mk);
  }

  /// Re-wrap an existing master key under a new passphrase (new salt + nonce,
  /// same MK). Backs passphrase change and recovery-kit import; the caller then
  /// `PUT /keyparams?replace=1`. No content is re-encrypted — the MK is
  /// unchanged, so the recovery kit also stays valid (wire-format.md §rotation).
  static Future<Map<String, dynamic>> rewrapKeyParams(
          Uint8List mk, String newPassphrase) =>
      _wrapMk(mk, newPassphrase);

  /// Seal a relic payload → `{n, ct}` base64 for the envelope.
  static Future<Map<String, String>> sealRelicPayload(
      Uint8List mk, String uid, Map<String, dynamic> payload) async {
    final nonce = _randomNonce();
    final ct = await _seal(mk, nonce, utf8.encode(jsonEncode(payload)), 'relic.relic.v1:$uid');
    return {'n': base64.encode(nonce), 'ct': base64.encode(ct)};
  }

  /// Encrypt a blob → wire bytes `nonce(24) ‖ ct`, AAD bound to the blob id.
  /// Encrypt mirror of [openBlob].
  static Future<Uint8List> sealBlob(Uint8List mk, String blobId, Uint8List bytes) async {
    final nonce = _randomNonce();
    final ct = await _seal(mk, nonce, bytes, 'relic.blob.v1:$blobId');
    return Uint8List.fromList([...nonce, ...ct]);
  }

  /// Decrypt a blob (`nonce ‖ ct`) given its client id.
  static Future<Uint8List?> openBlob(Uint8List mk, String blobId, Uint8List wire) async {
    if (wire.length < nonceLen) return null;
    final nonce = wire.sublist(0, nonceLen);
    final ct = wire.sublist(nonceLen);
    try {
      return await _open(mk, Uint8List.fromList(nonce), Uint8List.fromList(ct),
          'relic.blob.v1:$blobId');
    } on SecretBoxAuthenticationError {
      return null;
    }
  }
}

/// Crypto for sealed local backups (`.relicvault` files). Same primitives as
/// the sync vault (Argon2id KEK → XChaCha20-Poly1305) but a fully independent
/// key hierarchy: a random 32-byte backup key (BK) is wrapped under a
/// DEDICATED backup passphrase and the wrap record travels inside every
/// backup file, so a file is self-contained — any Relic install plus the
/// passphrase can open it. The unwrapped BK also sits in the OS credential
/// store so scheduled backups run without prompting (and without a 64 MiB
/// Argon2 pass). AAD domains are backup-only: a backup segment can never be
/// replayed as sync wire bytes or vice versa.
class BackupCrypto {
  static String _aad(String domain) => 'relic.backup.v1:$domain';

  /// Fresh BK wrapped under [passphrase] → (wrap record, BK). The record's
  /// shape mirrors keyparams (salt, pinned argon2 params, nonce, wrapped key)
  /// and is safe to persist in prefs and embed in file headers.
  static Future<(Map<String, dynamic>, Uint8List)> createWrap(
      String passphrase) async {
    final bk = RelicCrypto._randomBytes(RelicCrypto.keyLen);
    final salt = RelicCrypto._randomBytes(RelicCrypto.saltLen);
    final kek = RelicCrypto.deriveKek(passphrase, salt);
    final nonce = RelicCrypto._randomNonce();
    final wrapped = await RelicCrypto._seal(kek, nonce, bk, _aad('bkwrap'));
    return (
      {
        'v': 1,
        'salt': base64.encode(salt),
        'argon2': {
          'm_kib': RelicCrypto._argonMemKiB,
          't': RelicCrypto._argonIters,
          'p': RelicCrypto._argonLanes,
        },
        'bk_nonce': base64.encode(nonce),
        'wrapped_bk': base64.encode(wrapped),
      },
      bk,
    );
  }

  /// Unwrap the BK from a wrap record. Null on wrong passphrase.
  static Future<Uint8List?> unwrapBk(
      Map<String, dynamic> wrap, String passphrase) async {
    try {
      final salt = Uint8List.fromList(base64.decode(wrap['salt'] as String));
      final kek = RelicCrypto.deriveKek(passphrase, salt);
      final nonce =
          Uint8List.fromList(base64.decode(wrap['bk_nonce'] as String));
      final wrapped =
          Uint8List.fromList(base64.decode(wrap['wrapped_bk'] as String));
      return await RelicCrypto._open(kek, nonce, wrapped, _aad('bkwrap'));
    } on SecretBoxAuthenticationError {
      return null;
    } catch (_) {
      return null; // malformed record reads as "can't open", not a crash
    }
  }

  /// Seal one backup segment → `nonce(24) ‖ ct ‖ tag(16)`. [domain] binds the
  /// segment to its role in the file ('manifest', `blob:<key>`).
  static Future<Uint8List> seal(
      Uint8List bk, String domain, List<int> plain) async {
    final nonce = RelicCrypto._randomNonce();
    final ct = await RelicCrypto._seal(bk, nonce, plain, _aad(domain));
    return Uint8List.fromList([...nonce, ...ct]);
  }

  /// Decrypt mirror of [seal]. Null on tamper/wrong key/wrong domain.
  static Future<Uint8List?> open(
      Uint8List bk, String domain, Uint8List wire) async {
    if (wire.length < RelicCrypto.nonceLen + 16) return null;
    try {
      return await RelicCrypto._open(
        bk,
        Uint8List.fromList(wire.sublist(0, RelicCrypto.nonceLen)),
        Uint8List.fromList(wire.sublist(RelicCrypto.nonceLen)),
        _aad(domain),
      );
    } on SecretBoxAuthenticationError {
      return null;
    }
  }
}

/// Crypto for E2EE share links — deliberately a DIFFERENT primitive from
/// RelicCrypto: recipients decrypt in a browser, and WebCrypto speaks AES-GCM
/// natively but not XChaCha20. Wire = `iv(12) ‖ ct ‖ tag(16)`; the key rides
/// in the URL fragment (43-char unpadded base64url) and never reaches the
/// server; the AAD binds the ciphertext to its share id so a ciphertext can't
/// be replayed under another id. Mirrors the inline JS in worker/src/share.ts.
class ShareCrypto {
  static const _aadPrefix = 'relic.share.v1:';
  static final _gcm = AesGcm.with256bits(nonceLength: 12);

  static String _b64url(Uint8List b) =>
      base64UrlEncode(b).replaceAll('=', '');

  /// A fresh 128-bit share id (22 chars). Minted client-side so [seal] can
  /// bind the AAD before upload; the server 409s a collision and the caller
  /// simply re-mints.
  static String mintId() => _b64url(RelicCrypto._randomBytes(16));

  /// Encrypt [payload] for the share [id] under a fresh random key.
  /// Returns the URL-fragment key and the wire bytes to POST.
  static Future<({String keyFragment, Uint8List wire})> seal(
      String id, Map<String, dynamic> payload) async {
    final key = RelicCrypto._randomBytes(32);
    final iv = RelicCrypto._randomBytes(12);
    final box = await _gcm.encrypt(
      utf8.encode(jsonEncode(payload)),
      secretKey: SecretKey(key),
      nonce: iv,
      aad: utf8.encode('$_aadPrefix$id'),
    );
    return (
      keyFragment: _b64url(key),
      wire: Uint8List.fromList([...iv, ...box.cipherText, ...box.mac.bytes]),
    );
  }

  /// Decrypt mirror of [seal] — used by tests to prove the AAD binding and by
  /// nothing else in the app (recipients decrypt in the browser).
  static Future<Map<String, dynamic>?> open(
      String id, String keyFragment, Uint8List wire) async {
    if (wire.length < 29) return null;
    var b64 = keyFragment.replaceAll('-', '+').replaceAll('_', '/');
    while (b64.length % 4 != 0) {
      b64 += '=';
    }
    try {
      final clear = await _gcm.decrypt(
        SecretBox(
          wire.sublist(12, wire.length - 16),
          nonce: wire.sublist(0, 12),
          mac: Mac(wire.sublist(wire.length - 16)),
        ),
        secretKey: SecretKey(base64.decode(b64)),
        aad: utf8.encode('$_aadPrefix$id'),
      );
      return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    } on SecretBoxAuthenticationError {
      return null;
    }
  }
}

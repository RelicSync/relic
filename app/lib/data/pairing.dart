import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:hashlib/hashlib.dart';

import 'recovery.dart' show Crockford;

/// QR device-transfer pairing (docs/cloudflare/13-device-onboarding.md §5).
///
/// A TRUSTED device (already holds the master key) hands the MK to a NEW device
/// end-to-end encrypted, through a relay that only ever sees opaque ciphertext.
/// The passphrase is never involved. Confidentiality rests on a live X25519 ECDH
/// (`S`) that never transits; the QR carries only a short-lived channel key (`CK`)
/// that is a second factor and binds the out-of-band channel. A 4-digit SAS
/// derived from both ephemeral pubkeys + `S` + `CK` defeats an active relay MITM.
///
/// Transport ([PairingRelay]) and crypto ([PairingCrypto]) are split so the
/// mock/loopback relay and the eventual Cloudflare `/pair/*` relay are
/// interchangeable with zero crypto/UI change.

// ── Transport seam ──────────────────────────────────────────────────────────

/// The relay moves opaque blobs between the two devices and knows nothing else.
/// Maps to doc 13 §5.5: [allocate]→`POST /pair/start`, [put]→`/pair/offer`÷
/// `/pair/deliver`, [poll]→`/pair/poll`, [take]→`/pair/claim`. Slots used here:
/// `np` (NEW's sealed pubkey), `tp` (TRUSTED's sealed pubkey), `mk` (sealed
/// master key, single-use).
abstract class PairingRelay {
  /// Reserve a pairing session, returning its id (UUID). The channel key is
  /// generated client-side and rides only in the QR — never sent to the relay.
  Future<String> allocate();
  Future<void> put(String pairingId, String slot, Uint8List blob);

  /// Read a slot without consuming it; null until present (or if expired).
  Future<Uint8List?> poll(String pairingId, String slot);

  /// Read a slot and consume it (single-use); null if absent/expired.
  Future<Uint8List?> take(String pairingId, String slot);

  /// How often the orchestrators poll a slot. The in-process mock can spin fast;
  /// a network relay over Cloudflare KV should poll gently (KV read cost +
  /// negative-cache window), so the HTTP relay overrides this to ~700ms.
  Duration get pollInterval => const Duration(milliseconds: 40);
}

class PairingTimeout implements Exception {
  final String slot;
  const PairingTimeout(this.slot);
  @override
  String toString() => 'PairingTimeout(waiting for $slot)';
}

// ── Crypto ──────────────────────────────────────────────────────────────────

class PairingCrypto {
  static const qrPrefix = 'relic-pair:v1';
  static const qrPrefixV2 = 'relic-pair:v2';
  static final _x25519 = X25519();
  static final _aead = Xchacha20.poly1305Aead();
  static final _rng = Random.secure();

  static Uint8List randomChannelKey() =>
      Uint8List.fromList(List.generate(32, (_) => _rng.nextInt(256)));

  /// `relic-pair:v1:<pairing_id>:<channel_key b32>:<relay_hint>` (doc §5.1).
  /// Kept byte-identical for legacy / no-accountId callers.
  static String buildQr(String pairingId, Uint8List channelKey,
          {String? relayHint}) =>
      '$qrPrefix:$pairingId:${Crockford.encode(channelKey)}:${relayHint ?? ''}';

  /// `relic-pair:v2:<pairing_id>:<channel_key b32>:<ah>:<relay_hint>` (doc §5).
  /// [accountHint] is 8 Crockford chars (40 bits) binding the QR to an account,
  /// or empty for no check. The rest mirrors v1.
  static String buildQrV2(String pairingId, Uint8List channelKey,
          {String accountHint = '', String? relayHint}) =>
      '$qrPrefixV2:$pairingId:${Crockford.encode(channelKey)}:$accountHint:${relayHint ?? ''}';

  static ({
    String pairingId,
    Uint8List channelKey,
    String? accountHint,
    String? relayHint
  }) parseQr(String qr) {
    final parts = qr.trim().split(':');
    if (parts.length < 4 || parts[0] != 'relic-pair') {
      throw const FormatException('not a relic pairing QR');
    }
    switch (parts[1]) {
      case 'v1':
        // relic-pair : v1 : <id> : <key> : <hint?>
        return (
          pairingId: parts[2],
          channelKey: Crockford.decode(parts[3]),
          accountHint: null,
          relayHint: parts.length > 4 && parts[4].isNotEmpty ? parts[4] : null,
        );
      case 'v2':
        // relic-pair : v2 : <id> : <key> : <ah> : <hint?>
        if (parts.length < 5) {
          throw const FormatException('malformed v2 pairing QR');
        }
        return (
          pairingId: parts[2],
          channelKey: Crockford.decode(parts[3]),
          accountHint: parts[4].isNotEmpty ? parts[4] : null,
          relayHint: parts.length > 5 && parts[5].isNotEmpty ? parts[5] : null,
        );
      default:
        throw const FormatException('unsupported relic pairing version');
    }
  }

  /// Account binding (doc §5): a per-account fingerprint in Crockford base32.
  /// The v2 QR carries the first 8 chars (40 bits); the typed code carries the
  /// first 2 (10 bits). A slip-through only degrades to a timeout, then MK
  /// validation catches it.
  static String accountHint(String accountId) => Crockford.encode(
      Uint8List.fromList(
          sha256.convert(utf8.encode('relic.pair.v2.acct:$accountId')).bytes));

  /// First two Crockford chars of SHA-256 over the 18-char code body. Guards a
  /// typed code against a single mistyped symbol.
  static String _codeChecksum(String body18) => Crockford.encode(
          Uint8List.fromList(
              sha256.convert(utf8.encode('relic.pair.v2.chk:$body18')).bytes))
      .substring(0, 2);

  /// Derive the relay session id + channel key from a typed code's 18-char body.
  /// Both devices HKDF the same body, so the id never transits the wire. The id
  /// is 32 lowercase hex chars, which passes the relay's `isPairId`.
  static Future<({String pairingId, Uint8List channelKey})> deriveCode(
      String body18) async {
    final ikm = Uint8List.fromList(utf8.encode(body18));
    const salt = 'relic.pair.v2.code';
    final idBytes = await _hkdf(ikm, utf8.encode(salt), 'id', 16);
    final key = await _hkdf(ikm, utf8.encode(salt), 'key', 32);
    final pairingId =
        idBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return (pairingId: pairingId, channelKey: key);
  }

  static Future<SimpleKeyPair> newEphemeral() => _x25519.newKeyPair();

  static Future<Uint8List> publicBytes(SimpleKeyPair kp) async =>
      Uint8List.fromList((await kp.extractPublicKey()).bytes);

  static Future<Uint8List> sharedSecret(
      SimpleKeyPair mine, Uint8List theirPub) async {
    final s = await _x25519.sharedSecretKey(
      keyPair: mine,
      remotePublicKey: SimplePublicKey(theirPub, type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await s.extractBytes());
  }

  static Future<Uint8List> _hkdf(
      Uint8List ikm, List<int> salt, String info, int len) async {
    final out = await Hkdf(hmac: Hmac.sha256(), outputLength: len).deriveKey(
      secretKey: SecretKey(ikm),
      nonce: salt,
      info: utf8.encode(info),
    );
    return Uint8List.fromList(await out.extractBytes());
  }

  /// Derive the channel AEAD key + the 4-digit SAS from the completed exchange.
  /// Both sides compute this identically from data they each possess after the
  /// pubkey swap. Swapping a key changes `S` on one side → mismatched SAS.
  static Future<({Uint8List ckey, String sas})> deriveChannel({
    required Uint8List shared,
    required Uint8List channelKey,
    required Uint8List npPub,
    required Uint8List tpPub,
    required String pairingId,
  }) async {
    final ikm = Uint8List.fromList([...shared, ...channelKey]);
    final ckey = await _hkdf(
        ikm, utf8.encode(pairingId), 'relic.pair.v1.chan', 32);
    final transcript = <int>[
      ...utf8.encode('relic.pair.v1.sas'),
      ...npPub,
      ...tpPub,
      ...shared,
      ...channelKey,
    ];
    final d = sha256.convert(transcript).bytes;
    final n =
        ((d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3]) & 0xFFFFFFFF;
    final sas = (n % 10000).toString().padLeft(4, '0');
    return (ckey: ckey, sas: sas);
  }

  // AEAD: nonce(24) ‖ ct ‖ tag(16). Mirrors RelicCrypto.sealBlob's wire shape.
  static Future<Uint8List> _seal(
      Uint8List key, String aad, List<int> plaintext) async {
    final nonce =
        Uint8List.fromList(List.generate(24, (_) => _rng.nextInt(256)));
    final box = await _aead.encrypt(plaintext,
        secretKey: SecretKey(key), nonce: nonce, aad: utf8.encode(aad));
    return Uint8List.fromList([...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  static Future<Uint8List?> _open(
      Uint8List key, String aad, Uint8List wire) async {
    if (wire.length < 24 + 16) return null;
    final nonce = wire.sublist(0, 24);
    final ctTag = wire.sublist(24);
    final ct = ctTag.sublist(0, ctTag.length - 16);
    final mac = Mac(ctTag.sublist(ctTag.length - 16));
    try {
      final clear = await _aead.decrypt(SecretBox(ct, nonce: nonce, mac: mac),
          secretKey: SecretKey(key), aad: utf8.encode(aad));
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      return null;
    }
  }

  // Pubkey-in-transit, sealed under the QR's channel key so the relay cannot
  // read or substitute it without the out-of-band QR.
  static Future<Uint8List> sealPub(
          Uint8List channelKey, String pairingId, Uint8List pub) =>
      _seal(channelKey, 'relic.pair.v1.kex:$pairingId', pub);
  static Future<Uint8List?> openPub(
          Uint8List channelKey, String pairingId, Uint8List blob) =>
      _open(channelKey, 'relic.pair.v1.kex:$pairingId', blob);

  // Master-key delivery (v1: vault-only). `session_grant` is reserved for v2.
  static Future<Uint8List> sealMk(
          Uint8List ckey, String pairingId, Uint8List mk) =>
      _seal(ckey, 'relic.pair.v1:$pairingId',
          utf8.encode(jsonEncode({'v': 1, 'mk': base64.encode(mk)})));
  static Future<Uint8List?> openMk(
      Uint8List ckey, String pairingId, Uint8List blob) async {
    final clear = await _open(ckey, 'relic.pair.v1:$pairingId', blob);
    if (clear == null) return null;
    final j = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    return Uint8List.fromList(base64.decode(j['mk'] as String));
  }
}

// ── Typed pairing code ────────────────────────────────────────────────────────

/// Why a [PairingCode.parse] failed. [format] = not a 20-symbol Crockford code
/// at all; [version] = a Crockford code but not this (v2) protocol; [checksum] =
/// a v2 code whose check digits fail (a mistype).
enum PairingCodeError { format, version, checksum }

class PairingCodeException implements Exception {
  final PairingCodeError kind;
  const PairingCodeException(this.kind);
  @override
  String toString() => 'PairingCodeException($kind)';
}

/// The scanned QR (or typed code) belongs to a different Relic account. Thrown
/// before any relay traffic, from the 40-bit (QR) or 10-bit (code) account hint.
class PairingAccountMismatch implements Exception {
  /// Whether the mismatch came from a scanned QR (vs a typed code); only changes
  /// the noun in the user-facing sentence.
  final bool viaQr;
  const PairingAccountMismatch({required this.viaQr});
  String get message =>
      'This ${viaQr ? 'QR code' : 'code'} belongs to a different Relic account. '
      'Sign in with the same account on both devices, then try again.';
  @override
  String toString() => message;
}

/// A pairing handshake was cancelled (the user rejected a mismatched SAS, backed
/// out, or the screen was disposed). Both orchestrators surface this from any
/// in-flight relay wait so the loops stop promptly.
class PairingCancelled implements Exception {
  const PairingCancelled();
  @override
  String toString() => 'PairingCancelled';
}

/// A typed pairing code: 20 Crockford symbols shown as `2SSS-SSSS-SSSS-SSSS-HHCC`.
/// The first 18 symbols — version (`2`) + a 75-bit seed + a 2-char account hint —
/// are the [body]; the last two are a checksum. The body alone derives the
/// pairing_id and channel_key (both sides HKDF the same 18 chars), so a NEW
/// device that types the code lands on the exact relay session the TRUSTED
/// device minted, with no round-trip to exchange the id. Crockford tolerance
/// means lower case, spaces, hyphens and `I`/`L`/`O` slips all fold to one body.
class PairingCode {
  /// The normalized 18-symbol body (version + seed + account hint).
  final String body;
  const PairingCode._(this.body);

  static const _version = '2';
  static final _rng = Random.secure();

  /// Mint a fresh code bound to [accountId]: 75 bits of CSPRNG seed plus the
  /// first two hint chars of the account.
  static PairingCode mint({required String accountId}) {
    // 10 random bytes → 16 Crockford symbols (80 bits); keep 15 (= 75 bits).
    final seedBytes =
        Uint8List.fromList(List.generate(10, (_) => _rng.nextInt(256)));
    final seed = Crockford.encode(seedBytes).substring(0, 15);
    final hint = PairingCrypto.accountHint(accountId).substring(0, 2);
    return PairingCode._('$_version$seed$hint');
  }

  /// Parse a user-typed code (any case, with or without separators). Throws a
  /// [PairingCodeException]: [PairingCodeError.format] = not a 20-symbol
  /// Crockford code, [PairingCodeError.version] = not a v2 code,
  /// [PairingCodeError.checksum] = mistyped (the check digits fail).
  static PairingCode parse(String typed) {
    final norm = Crockford.normalize(typed);
    if (norm.length != 20 ||
        !norm.runes
            .every((r) => Crockford.isSymbol(String.fromCharCode(r)))) {
      throw const PairingCodeException(PairingCodeError.format);
    }
    if (norm[0] != _version) {
      throw const PairingCodeException(PairingCodeError.version);
    }
    final body = norm.substring(0, 18);
    if (norm.substring(18) != PairingCrypto._codeChecksum(body)) {
      throw const PairingCodeException(PairingCodeError.checksum);
    }
    return PairingCode._(body);
  }

  /// The 2-char account hint carried in the body (chars 16..17).
  String get hint => body.substring(16, 18);

  /// The display form: 5 groups of 4, `2SSS-SSSS-SSSS-SSSS-HHCC`.
  String display() {
    final full = body + PairingCrypto._codeChecksum(body);
    final groups = <String>[];
    for (var i = 0; i < full.length; i += 4) {
      groups.add(full.substring(i, i + 4));
    }
    return groups.join('-');
  }

  /// Derive the relay session id + channel key. Both devices compute this
  /// identically from the body, so no id is exchanged over the wire.
  Future<({String pairingId, Uint8List channelKey})> derive() =>
      PairingCrypto.deriveCode(body);
}

// ── Orchestrators ─────────────────────────────────────────────────────────────
// Role (NEW vs TRUSTED) is about who holds the MK; it is independent of who
// displayed vs scanned the QR. The displayer allocates the session + channel
// key; the scanner reads them from the QR. Both then run the symmetric pubkey
// swap (NEW under slot `np`, TRUSTED under `tp`) and derive the same SAS.

const _pollFor = Duration(seconds: 110); // within the relay's ~120s slot TTL

Future<Uint8List> _waitFor(PairingRelay relay, String id, String slot,
    {bool consume = false, bool Function()? cancelled}) async {
  final deadline = DateTime.now().add(_pollFor);
  while (DateTime.now().isBefore(deadline)) {
    if (cancelled?.call() ?? false) throw const PairingCancelled();
    final blob =
        consume ? await relay.take(id, slot) : await relay.poll(id, slot);
    if (blob != null) return blob;
    await Future<void>.delayed(relay.pollInterval);
  }
  throw PairingTimeout(slot);
}

/// Best-effort scrub of a key buffer's contents (Uint8List is mutable even when
/// the field is `final`). Used by `cancel()` so a torn-down handshake does not
/// leave the channel key lingering in RAM.
void _zero(Uint8List? b) {
  if (b == null) return;
  for (var i = 0; i < b.length; i++) {
    b[i] = 0;
  }
}

/// The joining device. Obtains the MK without the passphrase.
class NewDevicePairing {
  final PairingRelay relay;
  final String pairingId;
  final Uint8List channelKey;
  final String? _qr;
  Uint8List? _ckey;
  bool _cancelled = false;
  String? sas;

  NewDevicePairing._(this.relay, this.pairingId, this.channelKey, this._qr);

  /// NEW shows the QR (it allocates the session); the TRUSTED device scans it.
  /// With [accountId] the QR is v2 (carries NEW's 8-char account hint so the
  /// trusted side can reject a cross-account scan); without it, a byte-identical
  /// v1 QR for legacy / no-account callers.
  static Future<NewDevicePairing> display(PairingRelay relay,
      {String? relayHint, String? accountId}) async {
    final id = await relay.allocate();
    final ck = PairingCrypto.randomChannelKey();
    final qr = accountId == null
        ? PairingCrypto.buildQr(id, ck, relayHint: relayHint)
        : PairingCrypto.buildQrV2(id, ck,
            accountHint: PairingCrypto.accountHint(accountId).substring(0, 8),
            relayHint: relayHint);
    return NewDevicePairing._(relay, id, ck, qr);
  }

  /// NEW scans the TRUSTED device's QR. When the QR carries an account hint and
  /// [localAccountId] is known, a cross-account scan throws
  /// [PairingAccountMismatch] before any relay traffic.
  static Future<NewDevicePairing> fromQr(PairingRelay relay, String qr,
      {String? localAccountId}) async {
    final p = PairingCrypto.parseQr(qr);
    if (p.accountHint != null && localAccountId != null) {
      final expected =
          PairingCrypto.accountHint(localAccountId).substring(0, 8);
      if (p.accountHint != expected) {
        throw const PairingAccountMismatch(viaQr: true);
      }
    }
    return NewDevicePairing._(relay, p.pairingId, p.channelKey, null);
  }

  /// NEW types the code shown on a trusted device. The body derives the same
  /// pairing_id + channel_key the trusted side minted. A 2-char account-hint
  /// mismatch throws [PairingAccountMismatch] at parse time (no relay traffic).
  static Future<NewDevicePairing> fromCode(PairingRelay relay, String typed,
      {String? localAccountId}) async {
    final code = PairingCode.parse(typed); // throws PairingCodeException
    if (localAccountId != null &&
        code.hint != PairingCrypto.accountHint(localAccountId).substring(0, 2)) {
      throw const PairingAccountMismatch(viaQr: false);
    }
    final d = await code.derive();
    return NewDevicePairing._(relay, d.pairingId, d.channelKey, null);
  }

  String get qr => _qr ?? (throw StateError('this side scanned; it has no QR'));

  /// Abort the handshake: any in-flight relay wait throws [PairingCancelled] on
  /// its next loop, and the channel key is scrubbed. Idempotent.
  void cancel() {
    _cancelled = true;
    _zero(_ckey);
    _zero(channelKey);
  }

  /// Post our pubkey, wait for theirs, derive the SAS. Returns the 4-digit code
  /// for the user to compare against the trusted device.
  Future<String> handshake() async {
    final eph = await PairingCrypto.newEphemeral();
    final npPub = await PairingCrypto.publicBytes(eph);
    await relay.put(pairingId, 'np',
        await PairingCrypto.sealPub(channelKey, pairingId, npPub));
    final tpSealed =
        await _waitFor(relay, pairingId, 'tp', cancelled: () => _cancelled);
    final tpPub =
        await PairingCrypto.openPub(channelKey, pairingId, tpSealed);
    if (tpPub == null) throw const FormatException('bad pubkey on channel');
    final shared = await PairingCrypto.sharedSecret(eph, tpPub);
    final d = await PairingCrypto.deriveChannel(
        shared: shared,
        channelKey: channelKey,
        npPub: npPub,
        tpPub: tpPub,
        pairingId: pairingId);
    _ckey = d.ckey;
    return sas = d.sas;
  }

  /// After the SAS is confirmed and the trusted device approves: fetch + open
  /// the sealed master key. Throws [PairingTimeout] if approval never comes.
  Future<Uint8List> receiveMk() async {
    final sealed = await _waitFor(relay, pairingId, 'mk',
        consume: true, cancelled: () => _cancelled);
    final mk = await PairingCrypto.openMk(_ckey!, pairingId, sealed);
    if (mk == null) throw const FormatException('master key did not authenticate');
    return mk;
  }
}

/// The already-onboarded device that holds the master key and authorizes a join.
class TrustedDevicePairing {
  final PairingRelay relay;
  final Uint8List mk;
  final String pairingId;
  final Uint8List channelKey;
  final String? _qr;
  final String? _code;
  Uint8List? _ckey;
  bool _cancelled = false;
  String? sas;

  TrustedDevicePairing._(
      this.relay, this.mk, this.pairingId, this.channelKey, this._qr,
      [this._code]);

  /// TRUSTED shows the QR (allocates the session); the NEW device scans it.
  static Future<TrustedDevicePairing> display(PairingRelay relay, Uint8List mk,
      {String? relayHint}) async {
    final id = await relay.allocate();
    final ck = PairingCrypto.randomChannelKey();
    return TrustedDevicePairing._(
        relay, mk, id, ck, PairingCrypto.buildQr(id, ck, relayHint: relayHint));
  }

  /// TRUSTED mints one session with two doors: a v2 QR *and* the equivalent
  /// typed code, both derived from the same code body. Registration-free — the
  /// derived pairing_id is written straight to `/pair/offer`, so this SKIPS
  /// `POST /pair/start`. [accountId] binds both surfaces to this account.
  static Future<TrustedDevicePairing> displayWithCode(
      PairingRelay relay, Uint8List mk,
      {required String accountId, String? relayHint}) async {
    final code = PairingCode.mint(accountId: accountId);
    final d = await code.derive();
    final qr = PairingCrypto.buildQrV2(d.pairingId, d.channelKey,
        accountHint: PairingCrypto.accountHint(accountId).substring(0, 8),
        relayHint: relayHint);
    return TrustedDevicePairing._(
        relay, mk, d.pairingId, d.channelKey, qr, code.display());
  }

  /// TRUSTED scans the NEW device's QR. A cross-account scan (when the QR
  /// carries a hint and [localAccountId] is known) throws
  /// [PairingAccountMismatch] before any relay traffic.
  static Future<TrustedDevicePairing> fromQr(
      PairingRelay relay, String qr, Uint8List mk,
      {String? localAccountId}) async {
    final p = PairingCrypto.parseQr(qr);
    if (p.accountHint != null && localAccountId != null) {
      final expected =
          PairingCrypto.accountHint(localAccountId).substring(0, 8);
      if (p.accountHint != expected) {
        throw const PairingAccountMismatch(viaQr: true);
      }
    }
    return TrustedDevicePairing._(relay, mk, p.pairingId, p.channelKey, null);
  }

  String get qr => _qr ?? (throw StateError('this side scanned; it has no QR'));

  /// The typed pairing code, when this session was minted via [displayWithCode].
  String get code =>
      _code ?? (throw StateError('this session has no typed code'));

  /// Abort the handshake: any in-flight relay wait throws [PairingCancelled] on
  /// its next loop, and the channel key is scrubbed. The MK is never touched
  /// (it is only ever sealed inside [approveAndDeliver]). Idempotent.
  void cancel() {
    _cancelled = true;
    _zero(_ckey);
    _zero(channelKey);
  }

  Future<String> handshake() async {
    final eph = await PairingCrypto.newEphemeral();
    final tpPub = await PairingCrypto.publicBytes(eph);
    await relay.put(pairingId, 'tp',
        await PairingCrypto.sealPub(channelKey, pairingId, tpPub));
    final npSealed =
        await _waitFor(relay, pairingId, 'np', cancelled: () => _cancelled);
    final npPub =
        await PairingCrypto.openPub(channelKey, pairingId, npSealed);
    if (npPub == null) throw const FormatException('bad pubkey on channel');
    final shared = await PairingCrypto.sharedSecret(eph, npPub);
    final d = await PairingCrypto.deriveChannel(
        shared: shared,
        channelKey: channelKey,
        npPub: npPub,
        tpPub: tpPub,
        pairingId: pairingId);
    _ckey = d.ckey;
    return sas = d.sas;
  }

  /// Only call after the human confirmed the SAS matches and approved the join.
  /// Seals the master key to the channel and posts it for the new device.
  Future<void> approveAndDeliver() async {
    await relay.put(
        pairingId, 'mk', await PairingCrypto.sealMk(_ckey!, pairingId, mk));
  }
}

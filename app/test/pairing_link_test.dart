import 'dart:typed_data';

import 'package:relic_app/data/pairing.dart';
import 'package:relic_app/data/pairing_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = Uint8List.fromList(List.generate(32, (i) => i));
  final bare = PairingCrypto.buildQrV2(
      '0123456789abcdef0123456789abcdef', key,
      accountHint: 'ABCDEFGH');
  final minted = DateTime.utc(2026, 9, 15, 12, 0, 0);

  group('PairingLink.build', () {
    test('wraps the payload after the # with the mint time and email', () {
      final link = PairingLink.build(bare,
          issuedAt: minted, email: 'jo+relic@example.com');
      expect(link, startsWith('https://relic.space/pair#relic-pair:v2:'));
      expect(link, contains('&t=${minted.millisecondsSinceEpoch ~/ 1000}'));
      expect(link, contains('&e=jo%2Brelic%40example.com'));
      // Nothing before the # but the fixed route: the server never sees more.
      expect(link.substring(0, link.indexOf('#')), 'https://relic.space/pair');
    });

    test('carries only the payload when nothing else is known', () {
      expect(PairingLink.build(bare), 'https://relic.space/pair#$bare');
    });

    test('has a relic:// twin with the same fragment', () {
      final link = PairingLink.build(bare, issuedAt: minted);
      final custom = PairingLink.toCustomScheme(link);
      expect(custom, startsWith('relic://pair#relic-pair:v2:'));
      expect(custom.substring(custom.indexOf('#')),
          link.substring(link.indexOf('#')));
    });
  });

  group('PairingLink.parse', () {
    test('reads the https link back, fields intact', () {
      final p = PairingLink.parse(PairingLink.build(bare,
          issuedAt: minted, email: 'jo+relic@example.com'));
      expect(p, isNotNull);
      expect(p!.payload, bare);
      expect(p.issuedAt, minted);
      expect(p.email, 'jo+relic@example.com');
    });

    test('reads the relic:// fallback and the www host', () {
      final link = PairingLink.build(bare, issuedAt: minted);
      expect(PairingLink.parse(PairingLink.toCustomScheme(link))?.payload,
          bare);
      expect(
          PairingLink.parse(link.replaceFirst('relic.space', 'www.relic.space'))
              ?.payload,
          bare);
    });

    test('accepts the bare payload old desktops still show', () {
      final p = PairingLink.parse(bare);
      expect(p?.payload, bare);
      expect(p?.issuedAt, isNull);
      expect(p?.email, isNull);
    });

    test('rejects everything else', () {
      expect(PairingLink.parse('https://relic.space/get'), isNull);
      expect(PairingLink.parse('https://relic.space/pair'), isNull);
      expect(PairingLink.parse('https://relic.space/pair#nope'), isNull);
      expect(PairingLink.parse('https://evil.example/pair#$bare'), isNull);
      expect(PairingLink.parse('relic://capture'), isNull);
      expect(PairingLink.parse('relic://selfhost?url=http://x'), isNull);
      expect(PairingLink.parse(''), isNull);
    });

    test('a mangled t or e loses only that field', () {
      final p = PairingLink.parse(
          'https://relic.space/pair#$bare&t=soon&e=%E0%A4%A&x=1');
      expect(p?.payload, bare);
      expect(p?.issuedAt, isNull);
      expect(p?.email, isNull);
    });

    test('looksLikePairing is the scanner filter', () {
      expect(PairingLink.looksLikePairing(bare), isTrue);
      expect(PairingLink.looksLikePairing(PairingLink.build(bare)), isTrue);
      expect(PairingLink.looksLikePairing('https://relic.space/'), isFalse);
      expect(PairingLink.looksLikePairing('hello'), isFalse);
    });
  });

  group('expiry', () {
    test('expired past the code life, live before it', () {
      final p = PairingLink.parse(PairingLink.build(bare, issuedAt: minted))!;
      expect(p.isExpired(now: minted.add(const Duration(seconds: 90))),
          isFalse);
      expect(p.isExpired(now: minted.add(const Duration(seconds: 121))),
          isTrue);
    });

    test('a link without a mint time is never called expired', () {
      expect(PairingLink.parse(bare)!.isExpired(now: DateTime.now()), isFalse);
    });
  });

  group('PairingCrypto.parseQr', () {
    test('parses the https link like the bare payload', () {
      final fromBare = PairingCrypto.parseQr(bare);
      final fromLink = PairingCrypto.parseQr(
          PairingLink.build(bare, issuedAt: minted, email: 'a@b.c'));
      expect(fromLink.pairingId, fromBare.pairingId);
      expect(fromLink.channelKey, fromBare.channelKey);
      expect(fromLink.accountHint, fromBare.accountHint);
      expect(fromLink.relayHint, fromBare.relayHint);
    });

    test('still rejects a non-pairing string', () {
      expect(() => PairingCrypto.parseQr('https://relic.space/get'),
          throwsFormatException);
    });
  });
}

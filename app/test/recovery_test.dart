import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/recovery.dart';

void main() {
  group('Crockford base32', () {
    test('round-trips arbitrary byte lengths', () {
      for (final n in [1, 2, 5, 16, 31, 32, 48]) {
        final data = Uint8List.fromList(List.generate(n, (i) => (i * 37) & 0xff));
        final enc = Crockford.encode(data);
        expect(Crockford.decode(enc), data, reason: 'len $n');
      }
    });

    test('32 bytes encodes to 52 chars', () {
      final mk = Uint8List.fromList(List.generate(32, (i) => i));
      expect(Crockford.encode(mk).length, 52);
    });

    test('decode is tolerant of spacing, case, and I/L/O folding', () {
      final data = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
      final enc = Crockford.encode(data); // canonical, uppercase
      final messy = enc.toLowerCase().replaceAllMapped(
            RegExp(r'.{2}'),
            (m) => '${m[0]} ', // inject spaces
          );
      expect(Crockford.decode(messy), data);
      // 0 and O, 1 and I/L are interchangeable on input.
      expect(Crockford.decode('O1IL'), Crockford.decode('0111'));
    });

    test('rejects out-of-alphabet symbols (incl. U)', () {
      expect(() => Crockford.decode('ABCU'), throwsFormatException);
      expect(() => Crockford.decode('!!!!'), throwsFormatException);
    });
  });

  group('Crockford.normalize (kit re-entry proof matcher)', () {
    test('folds case, whitespace/hyphens, and I/L→1, O→0', () {
      expect(Crockford.normalize('o1il'), Crockford.normalize('0111'));
      expect(Crockford.normalize(' a b-c\td '), 'ABCD');
      expect(Crockford.normalize('Ab1'), 'AB1');
    });

    test('a group matches the same group typed with tolerated mistakes', () {
      const group = 'O1IL'; // as it might appear in a kit
      expect(
        Crockford.normalize(' o1il ') == Crockford.normalize(group),
        isTrue,
      );
      expect(
        Crockford.normalize('0000') == Crockford.normalize(group),
        isFalse,
      );
    });
  });

  group('RecoveryKit', () {
    final mk = Uint8List.fromList(List.generate(32, (i) => (i * 7 + 3) & 0xff));

    test('round-trips master key and email', () {
      final text = RecoveryKit.fromMk(mk, 'jordan@example.com');
      expect(text, contains('relic-mk-v1'));
      expect(text, contains('jordan@example.com'));
      final parsed = RecoveryKit.parse(text);
      expect(parsed.mk, mk);
      expect(parsed.email, 'jordan@example.com');
    });

    test('parse tolerates reflowed whitespace / line breaks', () {
      final text = RecoveryKit.fromMk(mk, 'a@b.co');
      final mangled = text.replaceAll(' ', '\n  ').replaceAll('\n\n', '\n');
      expect(RecoveryKit.parse(mangled).mk, mk);
    });

    test('a single mistyped character fails with a checksum error', () {
      final text = RecoveryKit.fromMk(mk, 'a@b.co');
      // Flip one base32 char in the key body (first group after the email line).
      final idx = text.indexOf('\n', text.indexOf('email:')) + 1;
      final ch = text[idx];
      final swap = ch == 'A' ? 'B' : 'A';
      final broken = text.replaceRange(idx, idx + 1, swap);
      expect(
        () => RecoveryKit.parse(broken),
        throwsA(isA<RecoveryKitException>()
            .having((e) => e.kind, 'kind', RecoveryKitError.checksum)),
      );
    });

    test('non-kit text fails with a format error', () {
      expect(
        () => RecoveryKit.parse('just some random clipboard text'),
        throwsA(isA<RecoveryKitException>()
            .having((e) => e.kind, 'kind', RecoveryKitError.format)),
      );
    });

    test('truncated body fails as checksum (mistyped), not format', () {
      final text = RecoveryKit.fromMk(mk, 'a@b.co');
      final short = text.substring(0, text.length - 6); // drop a group
      expect(
        () => RecoveryKit.parse(short),
        throwsA(isA<RecoveryKitException>()
            .having((e) => e.kind, 'kind', RecoveryKitError.checksum)),
      );
    });

    test('groups() returns the 14 four-char key-line groups', () {
      final text = RecoveryKit.fromMk(mk, 'a@b.co');
      final groups = RecoveryKit.groups(text);
      expect(groups.length, 14);
      expect(groups.every((g) => g.length == 4), isTrue);
      // The proof compares a typed group to the rendered one via normalize.
      expect(
        Crockford.normalize(groups[3].toLowerCase()) ==
            Crockford.normalize(groups[3]),
        isTrue,
      );
    });
  });
}

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/passphrase_strength.dart';
import 'package:relic_app/data/wordlist.dart';

double _log2(num x) => log(x) / ln2;

void main() {
  group('wordlist', () {
    test('is the full EFF short list 2.0 (1,296 unique words)', () {
      expect(effShortWordlist.length, 1296);
      expect(effShortWordSet.length, 1296);
      // every word lowercase, no whitespace
      for (final w in effShortWordlist) {
        expect(w, equals(w.toLowerCase()));
        expect(w.contains(RegExp(r'\s')), isFalse);
      }
    });
  });

  group('diceware detection', () {
    test('a phrase of wordlist words scores words * log2(1296)', () {
      final words = effShortWordlist.take(5).toList();
      final phrase = words.join(' ');
      expect(dicewareBits(phrase), closeTo(5 * _log2(1296), 1e-6));
    });

    test('is case-insensitive and tolerant of extra spacing', () {
      final phrase = '  ${effShortWordlist[0].toUpperCase()}   '
          '${effShortWordlist[1]} ';
      expect(dicewareBits(phrase), closeTo(2 * _log2(1296), 1e-6));
    });

    test('a non-wordlist token disqualifies the whole phrase', () {
      final phrase = '${effShortWordlist[0]} zznotaword ${effShortWordlist[1]}';
      expect(dicewareBits(phrase), 0);
    });

    test('empty input is 0 bits', () {
      expect(dicewareBits(''), 0);
      expect(dicewareBits('   '), 0);
    });
  });

  group('character-class pool math', () {
    test('lowercase only uses a 26-symbol pool', () {
      // "zzzz" is not an EFF word, so no single-word penalty applies.
      expect(charClassBits('zzzz'), closeTo(4 * _log2(26), 1e-6));
    });

    test('mixed classes sum the pools (26+26+10+33 = 95)', () {
      expect(charClassBits('Ab1!'), closeTo(4 * _log2(95), 1e-6));
    });

    test('digits-only uses a 10-symbol pool', () {
      expect(charClassBits('4726'), closeTo(4 * _log2(10), 1e-6));
    });
  });

  group('penalties', () {
    test('a worst-known password is halved', () {
      final full = 'password'.length * _log2(26);
      expect(charClassBits('password'), closeTo(full * 0.5, 1e-6));
    });

    test('worst-list match is case-insensitive', () {
      final full = 'Password'.length * _log2(26 + 26);
      expect(charClassBits('Password'), closeTo(full * 0.5, 1e-6));
    });

    test('a single dictionary word is halved', () {
      final word = effShortWordlist.firstWhere((w) => w.length >= 6);
      final full = word.length * _log2(26);
      expect(charClassBits(word), closeTo(full * 0.5, 1e-6));
    });

    test('a multi-word diceware phrase is NOT penalized as a single word', () {
      final phrase = '${effShortWordlist[0]} ${effShortWordlist[1]}';
      // pool = lower(26) + space symbol(33) = 59
      expect(charClassBits(phrase), closeTo(phrase.length * _log2(59), 1e-6));
    });
  });

  group('estimate = max(diceware, char)', () {
    test('takes the larger of the two models', () {
      final phrase = effShortWordlist.take(3).join(' ');
      expect(estimateEntropyBits(phrase),
          equals(max(dicewareBits(phrase), charClassBits(phrase))));
    });
  });

  group('band boundaries', () {
    test('maps bits to the four bands at the documented edges', () {
      expect(bandForBits(0), PassphraseBand.weak);
      expect(bandForBits(39.999), PassphraseBand.weak);
      expect(bandForBits(40), PassphraseBand.okay);
      expect(bandForBits(59.999), PassphraseBand.okay);
      expect(bandForBits(60), PassphraseBand.strong);
      expect(bandForBits(79.999), PassphraseBand.strong);
      expect(bandForBits(80), PassphraseBand.excellent);
      expect(bandForBits(200), PassphraseBand.excellent);
    });

    test('PassphraseStrength exposes label, fraction and nudge', () {
      final weak = estimatePassphrase('abc');
      expect(weak.band, PassphraseBand.weak);
      expect(weak.label, 'Weak');
      expect(weak.needsNudge, isTrue);

      final excellent = PassphraseStrength(200, bandForBits(200));
      expect(excellent.fraction, 1.0); // saturates at 80 bits
      expect(excellent.needsNudge, isFalse);
      expect(excellent.label, 'Excellent');
    });
  });

  group('suggester', () {
    test('emits 5 wordlist words joined by single spaces (injected RNG)', () {
      final phrase = suggestPassphrase(rng: Random(42));
      final parts = phrase.split(' ');
      expect(parts.length, 5);
      for (final p in parts) {
        expect(effShortWordSet.contains(p), isTrue);
      }
      // no double spaces / leading / trailing whitespace
      expect(phrase.trim(), phrase);
      expect(phrase.contains('  '), isFalse);
    });

    test('injected seed is deterministic; different seeds differ', () {
      expect(suggestPassphrase(rng: Random(1)),
          suggestPassphrase(rng: Random(1)));
      expect(suggestPassphrase(rng: Random(1)) ==
          suggestPassphrase(rng: Random(2)),
          isFalse);
    });

    test('wordCount is honored', () {
      expect(suggestPassphrase(rng: Random(7), wordCount: 8).split(' ').length,
          8);
    });

    test('default CSPRNG path yields 5 valid words', () {
      final parts = suggestPassphrase().split(' ');
      expect(parts.length, 5);
      for (final p in parts) {
        expect(effShortWordSet.contains(p), isTrue);
      }
    });
  });
}

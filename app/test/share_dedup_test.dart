import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/share_dedup.dart';

void main() {
  group('ShareDedup', () {
    test('fingerprint is stable for identical bytes and kind', () {
      final a = ShareDedup.fingerprint('img', [1, 2, 3, 4]);
      final b = ShareDedup.fingerprint('img', [1, 2, 3, 4]);
      expect(a, b);
      expect(a, startsWith('img:'));
    });

    test('fingerprint differs by content and by kind', () {
      expect(ShareDedup.fingerprint('img', [1, 2, 3]),
          isNot(ShareDedup.fingerprint('img', [1, 2, 4])));
      // Same bytes, different share kind → different key (never cross-dedup).
      expect(ShareDedup.fingerprint('img', [1, 2, 3]),
          isNot(ShareDedup.fingerprint('file', [1, 2, 3])));
    });

    test('alreadySeen reflects the map', () {
      final fp = ShareDedup.fingerprint('img', [9, 9, 9]);
      expect(ShareDedup.alreadySeen({}, fp), isFalse);
      expect(ShareDedup.alreadySeen({fp: 100}, fp), isTrue);
    });

    test('prune drops entries older than the TTL', () {
      const now = 1000000000;
      final seen = {
        'fresh': now - 10,
        'stale': now - ShareDedup.ttlSeconds - 1,
      };
      final pruned = ShareDedup.prune(seen, now);
      expect(pruned.containsKey('fresh'), isTrue);
      expect(pruned.containsKey('stale'), isFalse);
    });

    test('prune caps the map to the most recent maxEntries', () {
      const now = 2000000000;
      final seen = {
        for (var i = 0; i < ShareDedup.maxEntries + 25; i++) 'k$i': now - i,
      };
      final pruned = ShareDedup.prune(seen, now);
      expect(pruned.length, ShareDedup.maxEntries);
      // Newest (smallest age → largest ts) are kept; the oldest 25 dropped.
      expect(pruned.containsKey('k0'), isTrue); // ts = now (newest)
      expect(pruned.containsKey('k${ShareDedup.maxEntries + 24}'), isFalse);
    });

    test('decode tolerates null / empty / corrupt input', () {
      expect(ShareDedup.decode(null), isEmpty);
      expect(ShareDedup.decode(''), isEmpty);
      expect(ShareDedup.decode('not json'), isEmpty);
      expect(ShareDedup.decode('{"a":5}'), {'a': 5});
    });

    test('encode/decode round-trips', () {
      final seen = {'img:abc': 111, 'txt:def': 222};
      expect(ShareDedup.decode(ShareDedup.encode(seen)), seen);
      // and it is valid JSON
      expect(jsonDecode(ShareDedup.encode(seen)), isA<Map<String, dynamic>>());
    });
  });
}

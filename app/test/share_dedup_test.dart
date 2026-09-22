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

    test('uidFor finds the item a share landed on', () {
      final fp = ShareDedup.fingerprint('img', [9, 9, 9]);
      expect(ShareDedup.uidFor({}, fp), isNull);
      expect(ShareDedup.uidFor({fp: const SeenShare(100, 'u1')}, fp), 'u1');
    });

    test('an entry from an older build has no uid, so the share is stored afresh',
        () {
      final fp = ShareDedup.fingerprint('img', [9, 9, 9]);
      final seen = ShareDedup.decode(jsonEncode({fp: 100}));
      expect(seen[fp], const SeenShare(100, null));
      expect(ShareDedup.uidFor(seen, fp), isNull);
    });

    test('prune drops entries older than the TTL', () {
      const now = 1000000000;
      final seen = {
        'fresh': const SeenShare(now - 10, 'a'),
        'stale': SeenShare(now - ShareDedup.ttlSeconds - 1, 'b'),
      };
      final pruned = ShareDedup.prune(seen, now);
      expect(pruned.containsKey('fresh'), isTrue);
      expect(pruned.containsKey('stale'), isFalse);
    });

    test('prune caps the map to the most recent maxEntries', () {
      const now = 2000000000;
      final seen = {
        for (var i = 0; i < ShareDedup.maxEntries + 25; i++)
          'k$i': SeenShare(now - i, 'u$i'),
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
      expect(ShareDedup.decode('{"a":{"t":5,"u":"x"}}'),
          {'a': const SeenShare(5, 'x')});
    });

    test('encode/decode round-trips', () {
      final seen = {
        'img:abc': const SeenShare(111, 'u-1'),
        'txt:def': const SeenShare(222, null),
      };
      expect(ShareDedup.decode(ShareDedup.encode(seen)), seen);
      // and it is valid JSON
      expect(jsonDecode(ShareDedup.encode(seen)), isA<Map<String, dynamic>>());
    });
  });
}

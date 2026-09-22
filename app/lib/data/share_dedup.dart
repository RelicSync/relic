import 'dart:convert';

import 'package:hashlib/hashlib.dart';

/// One remembered share: when it was captured, and which item it landed on.
class SeenShare {
  final int at;
  final String? uid;
  const SeenShare(this.at, this.uid);

  @override
  bool operator ==(Object other) =>
      other is SeenShare && other.at == at && other.uid == uid;

  @override
  int get hashCode => Object.hash(at, uid);
}

/// Remembers what the phone has shared in, so sharing it again moves the
/// existing item to the top instead of making a second copy.
///
/// Text needs none of this: the repo finds an identical text item by its
/// content and bumps it. A photo or file has no such lookup, so the phone keeps
/// a small persisted map from a content fingerprint to the uid it was stored
/// under. A share whose fingerprint is here is resurfaced through that uid; if
/// the item is gone (deleted since, or another account's), it is captured
/// afresh. The window is 90 days, which is how long a re-share is a bump rather
/// than a new item.
///
/// Older builds stored only a timestamp per fingerprint and used it to refuse
/// the share ("Already in Relic"). Those entries still decode, with no uid, and
/// a share matching one is captured afresh: better a second copy than a share
/// that goes nowhere.
class ShareDedup {
  static const int ttlSeconds = 90 * 24 * 60 * 60; // keep fingerprints 90 days
  static const int maxEntries = 500; // bound the persisted map

  /// Stable content fingerprint: a kind-prefixed hex SHA-256 of the bytes.
  static String fingerprint(String kind, List<int> bytes) =>
      '$kind:${sha256.convert(bytes).hex()}';

  /// The item [fp] was stored under, if this phone remembers sharing it.
  static String? uidFor(Map<String, SeenShare> seen, String fp) =>
      seen[fp]?.uid;

  /// Drop fingerprints older than the TTL, then cap the map to [maxEntries]
  /// keeping the most recently seen. Returns a new map.
  static Map<String, SeenShare> prune(
      Map<String, SeenShare> seen, int nowSecs) {
    final out = Map<String, SeenShare>.from(seen)
      ..removeWhere((_, s) => nowSecs - s.at > ttlSeconds);
    if (out.length > maxEntries) {
      final entries = out.entries.toList()
        ..sort((a, b) => a.value.at.compareTo(b.value.at)); // oldest first
      final keep = entries.sublist(entries.length - maxEntries);
      out
        ..clear()
        ..addEntries(keep);
    }
    return out;
  }

  /// Decode the persisted JSON blob. Tolerant of a null/empty/corrupt value
  /// (returns an empty map) and of the older timestamp-only shape.
  static Map<String, SeenShare> decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, SeenShare>{};
      j.forEach((k, v) {
        if (v is num) {
          out[k] = SeenShare(v.toInt(), null);
        } else if (v is Map<String, dynamic>) {
          out[k] = SeenShare((v['t'] as num).toInt(), v['u'] as String?);
        }
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  static String encode(Map<String, SeenShare> seen) => jsonEncode({
        for (final e in seen.entries)
          e.key: {'t': e.value.at, if (e.value.uid != null) 'u': e.value.uid},
      });
}

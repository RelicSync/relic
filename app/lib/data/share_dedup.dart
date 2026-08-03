import 'dart:convert';

import 'package:hashlib/hashlib.dart';

/// De-duplicates shared captures on the mobile lens.
///
/// Android re-delivers the launch `ACTION_SEND` intent when the app is later
/// reopened from the recents/history screen (`FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`).
/// `receive_sharing_intent`'s `getInitialMedia()` then hands us a screenshot that
/// was already shared days ago, and we'd capture it again as a brand-new relic
/// (new uid + fresh `created_at`) — so it resurfaces as the newest item locally.
///
/// This keeps a small, persisted map of content fingerprints for recently
/// captured shares. A share whose fingerprint we've already seen is skipped, so
/// the phantom never gets created. The window is generous (90 days) so a genuine
/// re-share much later still goes through; an intentional immediate re-share of
/// the identical bytes is the only false-skip, and Relic already holds that item.
class ShareDedup {
  static const int ttlSeconds = 90 * 24 * 60 * 60; // keep fingerprints 90 days
  static const int maxEntries = 500; // bound the persisted map

  /// Stable content fingerprint: a kind-prefixed hex SHA-256 of the bytes.
  static String fingerprint(String kind, List<int> bytes) =>
      '$kind:${sha256.convert(bytes).hex()}';

  /// True when [fp] has already been captured (present in [seen]).
  static bool alreadySeen(Map<String, int> seen, String fp) =>
      seen.containsKey(fp);

  /// Drop fingerprints older than the TTL, then cap the map to [maxEntries]
  /// keeping the most recently seen. Returns a new map.
  static Map<String, int> prune(Map<String, int> seen, int nowSecs) {
    final out = Map<String, int>.from(seen)
      ..removeWhere((_, ts) => nowSecs - ts > ttlSeconds);
    if (out.length > maxEntries) {
      final entries = out.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value)); // oldest first
      final keep = entries.sublist(entries.length - maxEntries);
      out
        ..clear()
        ..addEntries(keep);
    }
    return out;
  }

  /// Decode the persisted JSON blob into a fingerprint→timestamp map. Tolerant
  /// of a null/empty/corrupt value (returns an empty map).
  static Map<String, int> decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return j.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  static String encode(Map<String, int> seen) => jsonEncode(seen);
}

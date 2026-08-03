import '../models/relic.dart';

/// One display row: the representative relic plus any exact-duplicate rows
/// collapsed behind it.
class GroupedRelic {
  final Relic relic;
  final List<Relic> duplicates;
  const GroupedRelic(this.relic, [this.duplicates = const []]);

  /// Devices of the hidden duplicates, in rank order (may repeat the shown
  /// relic's own device when the copy landed twice on one machine).
  List<String> get dupDevices => [for (final d in duplicates) d.device ?? ''];
}

/// Collapse exact-duplicate TEXT rows for display: the same copy captured on
/// two machines (e.g. a remote-desktop tool mirroring the clipboard) syncs
/// into two identical items, and every list then shows them back-to-back.
/// Rows with identical trimmed content fold into the FIRST occurrence
/// (i.e. the best-ranked one — input order is preserved), carrying the
/// others as a device hint. Only blob-less text items collapse: images and
/// files can share a caption without being the same thing.
///
/// If a later duplicate is vault-kept and the current representative isn't,
/// they swap — the kept copy is the one the user deliberately saved, so the
/// star, keep-toggle, and edit actions must act on IT, not on a transient
/// history twin.
List<GroupedRelic> collapseDuplicates(List<Relic> rows) {
  final reps = <Relic>[];
  final dups = <List<Relic>>[];
  final firstAt = <String, int>{};
  for (final r in rows) {
    String? key;
    if (r.kind == Kind.string && r.blobKey == null) {
      final c = r.content?.trim();
      if (c != null && c.isNotEmpty) key = c;
    }
    final at = key == null ? null : firstAt[key];
    if (at == null) {
      if (key != null) firstAt[key] = reps.length;
      reps.add(r);
      dups.add(<Relic>[]);
    } else if (r.promoted && !reps[at].promoted) {
      dups[at].add(reps[at]);
      reps[at] = r;
    } else {
      dups[at].add(r);
    }
  }
  return [
    for (var i = 0; i < reps.length; i++) GroupedRelic(reps[i], dups[i]),
  ];
}

import 'dart:convert';

import 'package:hashlib/hashlib.dart';
import 'package:sqlite3/sqlite3.dart';

import 'relic_db.dart';

/// On-disk store for the mobile lens's personalized-ranking signals (usage
/// frecency + query-pick memory) — the persistent home the desktop signals
/// have in the vault DB but WorkerRepo lacks, because its search index is an
/// ephemeral [RelicDb.memory] rebuilt every session.
///
/// Same math as desktop, by construction: every curve and constant comes from
/// the [RelicDb] statics (decay-then-add counters, 30-day half-life, factor
/// product clamped at [RelicDb.kPersonalBoostCap]), so a pick "weighs" the
/// same on a phone as on the desktop.
///
/// Privacy: vault content is encrypted at rest on mobile, so raw search terms
/// must not be the one plaintext exception. Terms are stored as
/// hex(HMAC-SHA256(salt, term)) truncated to 16 bytes; the caller owns the
/// random per-account salt (secure storage). Store and lookup hash through
/// the same [_hashTerm], so matching is exact without ever reversing a term.
/// Uids are already opaque; counts and timestamps are not sensitive.
class PersonalStore {
  final Database _db;
  final List<int> _salt;

  PersonalStore(String path, List<int> salt)
      : _db = sqlite3.open(path),
        _salt = List.unmodifiable(salt) {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS usage (
        uid TEXT PRIMARY KEY, count REAL NOT NULL, last_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS query_memory (
        term_h TEXT NOT NULL, uid TEXT NOT NULL,
        count REAL NOT NULL, last_at INTEGER NOT NULL,
        PRIMARY KEY (term_h, uid));
    ''');
  }

  /// Keyed term hash at rest: 16 bytes of HMAC-SHA256(salt, term), hex.
  String _hashTerm(String term) =>
      sha256.hmac.by(_salt).convert(utf8.encode(term)).hex().substring(0, 32);

  /// Record one "touch": the user reached for this item. [now] epoch seconds.
  void recordUse(String uid, int now) {
    final rows =
        _db.select('SELECT count, last_at FROM usage WHERE uid = ?', [uid]);
    final prev = rows.isEmpty
        ? 0.0
        : RelicDb.decayedUse((rows.first['count'] as num).toDouble(),
            rows.first['last_at'] as int, now);
    _db.execute(
      'INSERT INTO usage (uid, count, last_at) VALUES (?,?,?) '
      'ON CONFLICT(uid) DO UPDATE SET count = excluded.count, '
      'last_at = excluded.last_at',
      [uid, prev + 1, now],
    );
    _prune(now);
  }

  /// Remember "searching [query], the user picked [uid]" — decaying
  /// (term_h, uid) counters, mirroring [RelicDb.recordQueryPick] with hashed
  /// terms. Terms come from [RelicDb.memoryTerms] so store and lookup always
  /// tokenize identically.
  void recordQueryPick(String query, String uid, int now) {
    final terms = RelicDb.memoryTerms(query);
    if (terms.isEmpty) return;
    _db.execute('BEGIN');
    try {
      for (final t in terms) {
        final h = _hashTerm(t);
        final rows = _db.select(
          'SELECT count, last_at FROM query_memory WHERE term_h = ? AND uid = ?',
          [h, uid],
        );
        final prev = rows.isEmpty
            ? 0.0
            : RelicDb.decayedUse((rows.first['count'] as num).toDouble(),
                rows.first['last_at'] as int, now);
        _db.execute(
          'INSERT INTO query_memory (term_h, uid, count, last_at) '
          'VALUES (?,?,?,?) '
          'ON CONFLICT(term_h, uid) DO UPDATE SET count = excluded.count, '
          'last_at = excluded.last_at',
          [h, uid, prev + 1, now],
        );
      }
      _prune(now);
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Rows idle past [RelicDb.kMemoryIdleSecs] have decayed 256x — below any
  /// rank-visible factor — and are dropped on the next record (mirrors the
  /// desktop prune).
  void _prune(int now) {
    final cutoff = now - RelicDb.kMemoryIdleSecs;
    _db.execute('DELETE FROM usage WHERE last_at < ?', [cutoff]);
    _db.execute('DELETE FROM query_memory WHERE last_at < ?', [cutoff]);
  }

  /// Per-uid multipliers for a candidate [union]: usage factor times
  /// query-pick factor (when [query] has free text), product clamped at
  /// [RelicDb.kPersonalBoostCap]. Absent uid means 1.0 — personalization can
  /// only amplify items that already matched. [now] epoch seconds.
  Map<String, double> factors(List<String> union, String? query, int now) {
    if (union.isEmpty) return const {};
    final uph = List.filled(union.length, '?').join(',');
    final out = <String, double>{};
    for (final r in _db.select(
      'SELECT uid, count, last_at FROM usage WHERE uid IN ($uph)',
      union,
    )) {
      final d = RelicDb.decayedUse(
          (r['count'] as num).toDouble(), r['last_at'] as int, now);
      final f = RelicDb.useFactor(d);
      if (f > 1.0) out[r['uid'] as String] = f;
    }
    final terms = query == null ? const <String>[] : RelicDb.memoryTerms(query);
    if (terms.isNotEmpty) {
      final hashes = [for (final t in terms) _hashTerm(t)];
      final tph = List.filled(hashes.length, '?').join(',');
      final sum = <String, double>{};
      for (final r in _db.select(
        'SELECT uid, count, last_at FROM query_memory '
        'WHERE term_h IN ($tph) AND uid IN ($uph)',
        [...hashes, ...union],
      )) {
        final d = RelicDb.decayedUse(
            (r['count'] as num).toDouble(), r['last_at'] as int, now);
        sum[r['uid'] as String] = (sum[r['uid'] as String] ?? 0) + d;
      }
      sum.forEach((u, s) {
        if (s <= 0) return;
        final f = 1.0 +
            RelicDb.kQueryBoostMax * s / (s + RelicDb.kQueryBoostHalf);
        out[u] = (out[u] ?? 1.0) * f;
      });
    }
    out.removeWhere((_, f) => f <= 1.0);
    out.updateAll((_, f) =>
        f > RelicDb.kPersonalBoostCap ? RelicDb.kPersonalBoostCap : f);
    return out;
  }

  /// Forget a deleted relic's signals (uid rows only, like the desktop
  /// cascade).
  void deleteUid(String uid) {
    _db.execute('DELETE FROM usage WHERE uid = ?', [uid]);
    _db.execute('DELETE FROM query_memory WHERE uid = ?', [uid]);
  }

  /// Wipe everything learned on this device.
  void clear() {
    _db.execute('DELETE FROM usage');
    _db.execute('DELETE FROM query_memory');
  }

  void dispose() => _db.dispose();
}

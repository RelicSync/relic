import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/personal_store.dart';
import 'package:relic_app/data/relic_db.dart';

// The mobile lens's on-disk personal-ranking store: same decay math as the
// desktop signals (all curves come from the RelicDb statics), but persistent
// across the ephemeral in-memory index, with query terms HMAC-hashed at rest.
void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('relic_personal_');
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  final salt = List<int>.generate(32, (i) => i);
  String path(String name) => '${tmp.path}${Platform.pathSeparator}$name';

  test('round-trip: picks become factors and survive a reopen', () {
    var s = PersonalStore(path('p.db'), salt);
    s.recordUse('u1', 1000);
    s.recordUse('u1', 1000);
    // Two same-instant touches: decayed d = 2 → useFactor = 1 + 0.25*2/7.
    final usage = s.factors(['u1', 'u2'], null, 1000);
    expect(usage['u1'], closeTo(RelicDb.useFactor(2), 1e-12));
    expect(usage.containsKey('u2'), isFalse,
        reason: 'absent means 1.0 — never-touched items get no entry');

    s.recordQueryPick('ngrok tunnel', 'u1', 1000);
    s.recordQueryPick('ngrok tunnel', 'u1', 1000);
    // Shared term "ngrok": s = 2 → query factor 1 + 0.25*2/(2+3) = 1.10.
    final both = s.factors(['u1'], 'ngrok thing', 1000);
    expect(both['u1'], closeTo(RelicDb.useFactor(2) * 1.10, 1e-9));

    // Persistence: same file, same salt → the hashed terms still match.
    s.dispose();
    s = PersonalStore(path('p.db'), salt);
    addTearDown(s.dispose);
    expect(s.factors(['u1'], 'ngrok thing', 1000)['u1'],
        closeTo(RelicDb.useFactor(2) * 1.10, 1e-9));
  });

  test('raw query terms never touch disk (hashed at rest)', () {
    final s = PersonalStore(path('h.db'), salt);
    s.recordQueryPick('kubernetes cluster', 'uid-visible', 1000);
    s.dispose();
    final text = latin1.decode(File(path('h.db')).readAsBytesSync());
    expect(text.contains('uid-visible'), isTrue,
        reason: 'control: uids are stored raw (already opaque)');
    expect(text.contains('kubernetes'), isFalse,
        reason: 'the term must appear only as its keyed hash');
    expect(text.contains('cluster'), isFalse);
  });

  test('counters halve after a half-life and idle rows prune', () {
    final s = PersonalStore(path('d.db'), salt);
    addTearDown(s.dispose);
    s.recordUse('u1', 1000);
    final later = 1000 + RelicDb.kUseHalfLifeSecs;
    expect(s.factors(['u1'], null, later)['u1'],
        closeTo(RelicDb.useFactor(0.5), 1e-9));

    // A record far in the future sweeps rows idle past kMemoryIdleSecs.
    s.recordQueryPick('alpha', 'u1', 1000);
    final sweep = 1000 + RelicDb.kMemoryIdleSecs + 1;
    s.recordUse('u2', sweep);
    expect(s.factors(['u1'], 'alpha', sweep), isEmpty);
  });

  test('stacked usage + query factors clamp at kPersonalBoostCap', () {
    final s = PersonalStore(path('c.db'), salt);
    addTearDown(s.dispose);
    for (var i = 0; i < 60; i++) {
      s.recordUse('u1', 1000);
      s.recordQueryPick('alpha beta gamma', 'u1', 1000);
    }
    // Unclamped product would be ~1.23 * 1.25 ≈ 1.53.
    expect(s.factors(['u1'], 'alpha beta gamma', 1000)['u1'],
        RelicDb.kPersonalBoostCap);
  });

  test('deleteUid and clear forget the learned signals', () {
    final s = PersonalStore(path('x.db'), salt);
    addTearDown(s.dispose);
    s.recordUse('u1', 1000);
    s.recordQueryPick('alpha', 'u1', 1000);
    s.recordUse('u2', 1000);

    s.deleteUid('u1');
    expect(s.factors(['u1'], 'alpha', 1000), isEmpty);
    expect(s.factors(['u2'], null, 1000), isNotEmpty);

    s.clear();
    expect(s.factors(['u2'], null, 1000), isEmpty);
  });

  test('stores are isolated per file and per salt', () {
    final a = PersonalStore(path('a.db'), salt);
    a.recordUse('u1', 1000);
    a.recordQueryPick('alpha', 'u1', 1000);

    // A second account's file sees nothing.
    final b = PersonalStore(path('b.db'), salt);
    addTearDown(b.dispose);
    expect(b.factors(['u1'], 'alpha', 1000), isEmpty);

    // Same file reopened under a DIFFERENT salt: usage (uid-keyed) survives,
    // but the hashed query memory can no longer match — no cross-account
    // term leakage even if a file were shared.
    a.dispose();
    final other = List<int>.generate(32, (i) => 255 - i);
    final a2 = PersonalStore(path('a.db'), other);
    addTearDown(a2.dispose);
    expect(a2.factors(['u1'], 'alpha', 1000)['u1'],
        closeTo(RelicDb.useFactor(1), 1e-12),
        reason: 'usage factor only — the query component must not resolve');
  });
}

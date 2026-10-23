// Search eval: runs a query list through the real desktop search against a
// COPY of a vault and writes the top results per query, for an offline scorer
// to grade. Skipped unless pointed at a sandbox. Never point it at a live data
// dir: the repo writes prefs and may migrate the database.
//
//   RELIC_DATA_DIR=<sandbox with relics.db, prefs.json, tag_vectors.json>
//   RELIC_EVAL_SIFT=<path to sift.exe>          (optional; no semantic legs without it)
//   RELIC_EVAL_QUERIES=<json: [{"id": "...", "q": "..."}]>
//   RELIC_EVAL_OUT=<json out>
//   flutter test test/search_eval_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/widgets/chrome.dart';
import 'package:relic_app/data/sift.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final sandbox = env['RELIC_DATA_DIR'];
  final queries = env['RELIC_EVAL_QUERIES'];
  final out = env['RELIC_EVAL_OUT'];
  final guarded = sandbox == null ||
      sandbox.toLowerCase().contains('roaming') ||
      queries == null ||
      out == null;

  test('search eval', () async {
    if (guarded) {
      markTestSkipped('search eval sandbox not set');
      return;
    }
    final repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    final siftPath = env['RELIC_EVAL_SIFT'];
    if (siftPath != null) repo.debugSift = SiftSidecar(siftPath);
    final list = (jsonDecode(File(queries).readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    final results = <Map<String, dynamic>>[];
    final sw = Stopwatch();
    for (final q in list) {
      sw
        ..reset()
        ..start();
      await repo.setQuery(q['q'] as String, Scope.all);
      sw.stop();
      results.add({
        'id': q['id'],
        'q': q['q'],
        'ms': sw.elapsedMilliseconds,
        'count': repo.matchCount,
        'top': [for (final r in repo.visible.take(20)) r.uid],
      });
    }
    File(out).writeAsStringSync(jsonEncode(results));
  }, timeout: const Timeout(Duration(minutes: 60)));
}

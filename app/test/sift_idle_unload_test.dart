@Tags(['sidecar'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/sift.dart';

/// Integration checks for the idle unload, run against the real sift binary.
///
/// These matter more than a mocked equivalent would: what is being verified is
/// that a *process* actually goes away and that killing one does not strand its
/// replacement. That is exactly the class of bug a fake would paper over — the
/// resident classifier once leaked a second copy holding the whole model set
/// because a dead process's close event cleared its successor's registration.
///
/// Skipped when no binary is present (CI without a Rust build).
void main() {
  final exe = _findSift();
  final skipReason = exe == null ? 'no sift binary present' : null;

  // Count only sidecars *this test process* spawned. A global count would race
  // the developer's own running copy of Relic, whose enrichment pass starts and
  // stops sidecars of its own.
  int siftCount() {
    final r = Process.runSync('powershell', [
      '-NoProfile',
      '-Command',
      "(Get-CimInstance Win32_Process -Filter \"Name='sift.exe' AND "
          "ParentProcessId=$pid\" | Measure-Object).Count",
    ]);
    return int.tryParse('${r.stdout}'.trim()) ?? -1;
  }

  test('an idle query embedder is dropped, and leaves nothing behind',
      () async {
    final before = siftCount();
    final s = SiftSidecar(exe!, embedIdle: const Duration(milliseconds: 700));

    final v = await s.embedQuery('quarterly planning notes');
    expect(v, isNotNull, reason: 'embed sidecar should answer');
    expect(v!.length, greaterThan(8));
    expect(siftCount(), greaterThan(before), reason: 'embedder should be up');

    // Past the idle window: the process should be gone, not merely unreferenced.
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(siftCount(), before,
        reason: 'idle embedder should have exited, releasing its memory');

    // And it must come back on demand, with the same answer.
    final again = await s.embedQuery('a different phrase entirely');
    expect(again, isNotNull, reason: 'embedder should reload on demand');
    expect(again!.length, v.length);

    s.dispose();
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(siftCount(), before, reason: 'dispose should leave nothing running');
  },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: skipReason);

  test('reload after an unload does not strand a second copy', () async {
    final before = siftCount();
    final s = SiftSidecar(exe!, embedIdle: const Duration(milliseconds: 400));

    // Drive several unload/reload cycles. The stranding bug shows up as a
    // process count that ratchets upward, since each leaked copy stays alive.
    for (var i = 0; i < 3; i++) {
      final v = await s.embedQuery('cycle $i distinct query text');
      expect(v, isNotNull);
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(siftCount(), before,
          reason: 'cycle $i left a process behind — a leaked embedder');
    }

    s.dispose();
  },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: skipReason);

  // The classifier is the larger of the two (~2.0-2.5 GB settled vs ~1.2 GB),
  // and unlike the embedder nothing was ever dropping it: stopServer() only
  // ran when a setting changed, so one enrichment pass left it resident for
  // the rest of the session.
  test('an idle classifier is dropped too', () async {
    final before = siftCount();
    final s = SiftSidecar(exe!, serverIdle: const Duration(milliseconds: 700));

    final r = await s.classifyText('quarterly planning notes and budget',
        ml: true, embeddings: false);
    expect(r, isNotNull, reason: 'classifier should answer');
    expect(siftCount(), greaterThan(before), reason: 'classifier should be up');

    await Future<void>.delayed(const Duration(seconds: 3));
    expect(siftCount(), before,
        reason: 'idle classifier should have exited, releasing its memory');

    // Still usable afterwards: the next item just pays the reload.
    final again = await s.classifyText('a second unrelated snippet',
        ml: true, embeddings: false);
    expect(again, isNotNull, reason: 'classifier should reload on demand');

    s.stopServer();
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(siftCount(), before, reason: 'stopServer should leave nothing running');
  },
      timeout: const Timeout(Duration(minutes: 5)),
      skip: skipReason);

  test('a request in flight is never unloaded from under itself', () async {
    final s = SiftSidecar(exe!, embedIdle: const Duration(milliseconds: 1));
    // The idle window is shorter than the request takes, so if the unload did
    // not defer while a request is pending, this would come back null.
    for (var i = 0; i < 3; i++) {
      final v = await s.embedQuery('in flight query $i');
      expect(v, isNotNull, reason: 'request $i was cut off mid-flight');
    }
    s.dispose();
  },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: skipReason);
}

/// The installed app's binary, else the dev build. Null skips the suite.
String? _findSift() {
  final sep = Platform.pathSeparator;
  final home = Platform.environment['LOCALAPPDATA'] ?? '';
  for (final c in [
    '${Directory.current.path}$sep..${sep}target${sep}release${sep}sift.exe',
    if (home.isNotEmpty) '$home${sep}Relic${sep}sift.exe',
  ]) {
    if (File(c).existsSync()) return File(c).absolute.path;
  }
  return null;
}

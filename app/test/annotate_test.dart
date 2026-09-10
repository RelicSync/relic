// Repo-level tests for the save & annotate flow (captureForAnnotate for
// text and for copied files + updateMeta content edits). LocalDeskRepo reads its data dir from the
// RELIC_DATA_DIR env override, which can't be set from inside a test — so
// these run ONLY when the invoker points that at a sandbox:
//
//   RELIC_DATA_DIR=$(mktemp -d) flutter test test/annotate_test.dart
//
// Without it the suite skips rather than touching the real vault.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/models/relic.dart';

void main() {
  final sandbox = Platform.environment['RELIC_DATA_DIR'];
  final guarded = sandbox == null ||
      // Refuse to run against anything that looks like the real data dir.
      sandbox.toLowerCase().contains('roaming');

  test('save & annotate repo flow', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    final repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    repo.setMlEnrich(false); // keep the test hermetic (no sift sidecar)

    // New text: captured, promoted, attributed.
    final res = await repo.captureForAnnotate(
      text: 'TSA1234567',
      sourceApp: 'chrome',
    );
    expect(res, isNotNull);
    final (r1, promoted1) = res!;
    expect(promoted1, isTrue);
    expect(r1.promoted, isTrue);
    expect(r1.content, 'TSA1234567');
    expect(r1.source, Source.hotkey);
    expect(r1.tags, contains('chrome'));

    // Same text again: dedupe onto the SAME relic, no duplicate.
    final res2 = await repo.captureForAnnotate(text: 'TSA1234567');
    expect(res2!.$1.uid, r1.uid);
    expect(repo.all.where((x) => x.content == 'TSA1234567').length, 1);

    // Body edit: content/preview/byteSize follow; detector tags reconcile.
    await repo.captureForAnnotate(text: 'https://example.com/pricing');
    final link = repo.all.firstWhere(
        (x) => x.content == 'https://example.com/pricing');
    expect(link.tags, contains('url'));
    await repo.updateMeta(link, content: 'a plain sentence with no link now');
    final edited = repo.all.firstWhere((x) => x.uid == link.uid);
    expect(edited.content, 'a plain sentence with no link now');
    expect(edited.preview, isNot(contains('example.com')));
    expect(edited.tags, isNot(contains('url'))); // detector reconciled
    expect(edited.byteSize, 'a plain sentence with no link now'.length);

    // Suppression survives a body edit: remove `command`, then edit the body
    // to something command-shaped — it must NOT come back.
    await repo.captureForAnnotate(text: 'kubectl get pods -n prod');
    final kube =
        repo.all.firstWhere((x) => x.content == 'kubectl get pods -n prod');
    expect(kube.tags, contains('command'));
    await repo.updateMeta(kube,
        tags: kube.tags.where((t) => t != 'command').toList());
    await repo.updateMeta(kube, content: 'kubectl describe deploy relic-api');
    final kube2 = repo.all.firstWhere((x) => x.uid == kube.uid);
    expect(kube2.tags, isNot(contains('command')));

    // Secrets: body is never editable through updateMeta.
    await repo.captureForAnnotate(text: 'sk_live_0123456789abcdef');
    final sec = repo.all
        .firstWhere((x) => x.content == 'sk_live_0123456789abcdef');
    expect(sec.isSecret, isTrue);
    await repo.updateMeta(sec, content: 'overwritten!', note: 'stripe key');
    final sec2 = repo.all.firstWhere((x) => x.uid == sec.uid);
    expect(sec2.content, 'sk_live_0123456789abcdef'); // unchanged
    expect(sec2.note, 'stripe key'); // note edits still work
  });

  test('save & annotate a copied file', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    final repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    repo.setMlEnrich(false);
    // .bin so document text extraction has nothing to do with them.
    final dir = Directory('$sandbox${Platform.pathSeparator}copied');
    dir.createSync(recursive: true);
    File p(String name, List<int> bytes) =>
        File('${dir.path}${Platform.pathSeparator}$name')
          ..writeAsBytesSync(bytes);
    final a = p('render.bin', List<int>.generate(300, (i) => i % 251));
    final b = p('mesh.bin', List<int>.generate(300, (i) => (i * 7) % 253));

    // A file copy: captured as a file relic, promoted, named after the file.
    final res = await repo.captureForAnnotate(files: [a.path]);
    expect(res, isNotNull);
    final (r1, promoted1) = res!;
    expect(promoted1, isTrue);
    expect(r1.kind, Kind.file);
    expect(r1.filename, 'render.bin');
    expect(r1.byteSize, 300);

    // The hotkey after the watcher already took the same copy: one relic.
    final res2 = await repo.captureForAnnotate(files: [a.path]);
    expect(res2!.$1.uid, r1.uid);
    expect(repo.all.where((x) => x.filename == 'render.bin').length, 1);

    // The watcher first, then the hotkey, for a different file: still one.
    expect(repo.captureFile(b.path, b.readAsBytesSync()), isTrue);
    final res3 = await repo.captureForAnnotate(files: [b.path]);
    expect(res3!.$1.filename, 'mesh.bin');
    expect(res3.$1.promoted, isTrue);
    expect(repo.all.where((x) => x.filename == 'mesh.bin').length, 1);

    // Several files: the editor opens on the first, every one is in the vault.
    final c = p('notes.bin', List<int>.generate(64, (i) => 255 - i));
    final d = p('scan.bin', List<int>.generate(64, (i) => i * 3 % 256));
    final res4 = await repo.captureForAnnotate(files: [c.path, d.path]);
    expect(res4!.$1.filename, 'notes.bin');
    final scan = repo.all.firstWhere((x) => x.filename == 'scan.bin');
    expect(scan.promoted, isTrue);

    // Paste stack: the first file is what gets queued.
    final s = repo.captureForStack(files: [d.path, c.path]);
    expect(s?.uid, scan.uid);
    expect(repo.all.where((x) => x.filename == 'scan.bin').length, 1);
  });
}

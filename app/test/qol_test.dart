// Tests for the July 2026 QoL round: sync-rejection reasons + retry plumbing,
// version comparison for the Devices screen, vault import, and attachment
// editing. Repo-level tests run only under a RELIC_DATA_DIR sandbox:
//
//   RELIC_DATA_DIR=$(mktemp -d) flutter test test/qol_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/device_directory.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/data/relic_db.dart';
import 'package:relic_app/data/repo.dart';
import 'package:relic_app/models/relic.dart';

void main() {
  group('syncRejectionReason', () {
    test('maps the statuses the worker actually returns', () {
      expect(syncRejectionReason(402), 'Vault is full on your plan');
      expect(syncRejectionReason(413), 'Too large for your plan');
      expect(syncRejectionReason(403), 'Confirm your email to sync');
      expect(syncRejectionReason(409), 'A newer copy exists elsewhere');
      expect(syncRejectionReason(400), 'Sync error');
      expect(syncRejectionReason(0), 'Sync error'); // blob missing locally
    });

    test('hints exist only where the user can act', () {
      expect(syncRejectionHint(402), isNotNull);
      expect(syncRejectionHint(413), isNotNull);
      expect(syncRejectionHint(409), isNotNull);
      expect(syncRejectionHint(400), isNull);
      expect(syncRejectionHint(0), isNull);
    });
  });

  group('compareVersions', () {
    test('numeric segment order, not string order', () {
      expect(compareVersions('1.0.9', '1.0.13'), lessThan(0));
      expect(compareVersions('1.0.13', '1.0.9'), greaterThan(0));
      expect(compareVersions('1.0.13', '1.0.13'), 0);
    });
    test('unequal lengths pad with zeros', () {
      expect(compareVersions('1.0', '1.0.0'), 0);
      expect(compareVersions('1.0', '1.0.1'), lessThan(0));
      expect(compareVersions('2', '1.9.9'), greaterThan(0));
    });
    test('build/pre-release suffixes are stripped', () {
      expect(compareVersions('1.0.13+14', '1.0.13'), 0);
      expect(compareVersions('1.0.13-beta', '1.0.12'), greaterThan(0));
    });
    test('garbage degrades to equal-zero, never throws', () {
      expect(compareVersions('', ''), 0);
      expect(compareVersions('abc', '1.0'), lessThan(0));
    });
  });

  group('sync_rejections accessors', () {
    test('rejectionFor / allRejections round-trip and queueOp clears', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('u1', 'hello one'));
      db.upsert(_mk('u2', 'hello two'));

      db.recordSyncRejection('u1', 'push', 413, 1000);
      db.recordSyncRejection('u2', 'push', 402, 2000);

      final r1 = db.rejectionFor('u1');
      expect(r1, isNotNull);
      expect(r1!.status, 413);
      expect(r1.op, 'push');
      expect(r1.rejectedAt, 1000);
      expect(db.rejectionFor('missing'), isNull);

      final all = db.allRejections();
      expect(all, hasLength(2));
      expect(all.first.uid, 'u2'); // newest rejection first
      expect(all.first.status, 402);

      // The retry path: re-queueing the op clears the rejection row (that's
      // what makes retrySync a two-liner) and the badge flips to syncing.
      expect(db.syncStateFor('u1'), 2); // blocked
      db.queueOp('u1', 'push', 3000);
      expect(db.rejectionFor('u1'), isNull);
      expect(db.syncStateFor('u1'), 1); // syncing
      expect(db.allRejections(), hasLength(1));
    });

    test('recordSyncRejection upserts the latest status per (uid, op)', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_mk('u1', 'x'));
      db.recordSyncRejection('u1', 'push', 413, 1000);
      db.recordSyncRejection('u1', 'push', 402, 2000);
      expect(db.allRejections(), hasLength(1));
      expect(db.rejectionFor('u1')!.status, 402);
    });
  });

  final sandbox = Platform.environment['RELIC_DATA_DIR'];
  final guarded =
      sandbox == null || sandbox.toLowerCase().contains('roaming');

  test('sandboxed: export → delete → import restores (and re-import skips)',
      () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    final repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    repo.setMlEnrich(false);

    repo.captureText('import round trip alpha');
    repo.captureText('import round trip beta');
    final beforeUids = {for (final r in repo.all) r.uid};
    expect(beforeUids.length, greaterThanOrEqualTo(2));

    final dest = Directory.systemTemp.createTempSync('relic-import-test');
    addTearDown(() => dest.deleteSync(recursive: true));
    final exp = await repo.exportVault(dest.path, includeSecrets: false);
    expect(exp.items, beforeUids.length);

    // Wipe one item, then import: only the deleted one comes back.
    final victim =
        repo.all.firstWhere((r) => r.content == 'import round trip alpha');
    await repo.delete(victim);
    expect(repo.all.any((r) => r.uid == victim.uid), isFalse);

    final res = await repo.importVault(exp.path);
    expect(res.imported, 1);
    expect(res.skipped, beforeUids.length - 1);
    expect(res.failed, 0);
    final restored =
        repo.all.firstWhere((r) => r.uid == victim.uid);
    expect(restored.content, 'import round trip alpha');
    expect(restored.createdAt, victim.createdAt); // timestamps preserved

    // Idempotent: a second run skips everything.
    final again = await repo.importVault(exp.path);
    expect(again.imported, 0);
    expect(again.skipped, beforeUids.length);
  });

  test('sandboxed: import rejects damaged and newer-version exports',
      () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    final repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    repo.setMlEnrich(false);

    final dir = Directory.systemTemp.createTempSync('relic-import-bad');
    addTearDown(() => dir.deleteSync(recursive: true));

    // No vault.json at all.
    await expectLater(repo.importVault(dir.path), throwsA(isA<StateError>()));

    // Newer format version.
    File('${dir.path}${Platform.pathSeparator}vault.json')
        .writeAsStringSync('{"version": 2, "items": []}');
    await expectLater(repo.importVault(dir.path), throwsA(isA<StateError>()));

    // Truncated JSON.
    File('${dir.path}${Platform.pathSeparator}vault.json')
        .writeAsStringSync('{"version": 1, "items": [');
    await expectLater(repo.importVault(dir.path), throwsA(isA<StateError>()));
  });

  test('sandboxed: attachment edit rebuilds the bundle under a new key',
      () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    final repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    repo.setMlEnrich(false);

    final a = Uint8List.fromList(List.filled(64, 1));
    final b = Uint8List.fromList(List.filled(32, 2));
    expect(
      repo.createNote(title: 'bundle', body: 'note body', files: [
        ('a.bin', null, a),
        ('b.bin', null, b),
      ]),
      isTrue,
    );
    final note = repo.all.firstWhere((r) => r.title == 'bundle');
    expect(note.attachments, hasLength(2));
    final oldKey = note.blobKey!;

    // Remove one, add one → new key, manifest = kept + added, sizes right.
    final c = Uint8List.fromList(List.filled(16, 3));
    final res = await repo.updateAttachments(
      note,
      added: [('c.bin', null, c)],
      removedIds: {note.attachments.first.id},
    );
    expect(res, AttachmentEditResult.ok);
    final after = repo.all.firstWhere((r) => r.uid == note.uid);
    expect(after.attachments.map((x) => x.name), ['b.bin', 'c.bin']);
    expect(after.blobKey, isNotNull);
    expect(after.blobKey, isNot(oldKey));
    expect(after.byteSize, b.length + c.length);
    final bytes = await repo.blobBytes(after);
    expect(bytes, isNotNull);
    expect(bytes!.length, b.length + c.length);

    // Removing the rest degrades to a plain text note.
    final res2 = await repo.updateAttachments(
      after,
      removedIds: after.attachments.map((x) => x.id).toSet(),
    );
    expect(res2, AttachmentEditResult.ok);
    final plain = repo.all.firstWhere((r) => r.uid == note.uid);
    expect(plain.attachments, isEmpty);
    expect(plain.blobKey, isNull);
    expect(plain.content, 'note body');

    // Over-cap add is refused wholesale.
    repo.setMaxItemMb(1);
    final big = Uint8List(2 * 1024 * 1024);
    final res3 = await repo.updateAttachments(
      plain,
      added: [('big.bin', null, big)],
    );
    expect(res3, AttachmentEditResult.tooLarge);
  });
}

Relic _mk(String uid, String content) => Relic(
      uid: uid,
      createdAt: 100,
      updatedAt: 100,
      kind: Kind.string,
      source: Source.clipboard,
      promoted: false,
      byteSize: content.length,
      content: content,
      preview: content,
    );

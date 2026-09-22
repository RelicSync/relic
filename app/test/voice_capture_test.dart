import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/data/relic_db.dart';
import 'package:relic_app/data/sync_jobs.dart';
import 'package:relic_app/models/relic.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const metadata = {
    'v': 1,
    'mode': 'voice_note',
    'raw': 'my shoes are downstairs',
    'duration_ms': 2100,
  };
  const item = Relic(
    uid: '11111111-1111-4111-8111-111111111111',
    createdAt: 1,
    updatedAt: 1,
    kind: Kind.string,
    source: Source.voice,
    promoted: false,
    byteSize: 100,
    content: 'My shoes are downstairs.',
    voice: metadata,
    tags: ['voice-note'],
  );

  test(
    'voice metadata survives database writes, batch sync and normal edits',
    () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(item);
      expect(db.getByUid(item.uid)!.voice, metadata);
      db.upsert(item.copyWith(title: 'Shoes', promoted: true));
      expect(db.getByUid(item.uid)!.voice, metadata);
      db.upsertMany([item.copyWith(note: 'Basement')]);
      expect(db.getByUid(item.uid)!.voice, metadata);
      expect(db.getByUid(item.uid)!.allTags, contains('voice-note'));
      db.setRich(item.uid, null);
      expect(
        db.getByUid(item.uid)!.byteSize,
        utf8.encode(item.content!).length +
            utf8.encode(jsonEncode(metadata)).length,
      );
    },
  );

  test('older payload does not erase locally known voice metadata', () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);
    db.upsert(item);
    db.upsert(
      const Relic(
        uid: '11111111-1111-4111-8111-111111111111',
        createdAt: 1,
        updatedAt: 2,
        kind: Kind.string,
        source: Source.api,
        promoted: true,
        byteSize: 30,
        content: 'Shoes moved upstairs.',
      ),
    );
    expect(db.getByUid(item.uid)!.voice, metadata);
    expect(db.getByUid(item.uid)!.content, 'Shoes moved upstairs.');
  });

  test('encrypted envelope decoding and export retain metadata', () {
    final payload = item.toJson();
    final decoded = relicFromEnvelope(payload, payload);
    expect(decoded.voice, metadata);
    expect(decoded.source, Source.voice);
    expect(decoded.copyWith(title: 'Changed').toJson()['voice'], metadata);
  });

  test(
    'one session is idempotent, repeated speech is distinct, note promotes',
    () async {
      final sandbox = Platform.environment['RELIC_DATA_DIR'];
      if (sandbox == null || sandbox.toLowerCase().contains('roaming')) {
        markTestSkipped('Requires an isolated RELIC_DATA_DIR');
        return;
      }
      final repo = LocalDeskRepo();
      await repo.load();
      addTearDown(repo.dispose);
      repo.setMlEnrich(false);
      final first = repo.captureVoice(
        sessionId: '22222222-2222-4222-8222-222222222222',
        text: 'I put my tennis shoes downstairs.',
        metadata: {...metadata, 'mode': 'dictation'},
        promote: false,
      );
      expect(first.created, isTrue);
      expect(first.relic.promoted, isFalse);
      final retry = repo.captureVoice(
        sessionId: first.relic.uid,
        text: first.relic.content!,
        metadata: metadata,
        promote: false,
      );
      expect(retry.created, isFalse);
      expect(retry.relic.uid, first.relic.uid);
      final note = repo.captureVoice(
        sessionId: '33333333-3333-4333-8333-333333333333',
        text: first.relic.content!,
        metadata: metadata,
        promote: true,
      );
      expect(note.relic.promoted, isTrue);
      expect(note.relic.uid, isNot(first.relic.uid));
      expect(repo.all.where((r) => r.content == first.relic.content).length, 2);
      expect(repo.relicByUid(first.relic.uid)!.voice?['mode'], 'dictation');
      await repo.updateMeta(first.relic, content: 'They moved upstairs.');
      final edited = repo.relicByUid(first.relic.uid)!;
      expect(edited.voice, first.relic.voice);
      expect(
        edited.byteSize,
        utf8.encode(edited.content!).length +
            utf8.encode(jsonEncode(edited.voice)).length,
      );
    },
  );
}

// AI records: how a generated title and its tags reach the user's other
// devices, and how devices avoid generating the same thing twice.
//
// The behaviour being pinned here is the fix for a real defect. Enrichment used
// to write its title straight to the local row with no push queued and no
// updated_at bump, so an AI title never left the machine that produced it, and
// every device that received a relic re-ran the models to get its own different
// answer. The three things that had to become true:
//
//   * a generated title propagates,
//   * only one device generates it, and
//   * neither of those may disturb the relic's own updated_at, or a background
//     tagging pass would look like a user edit.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/data/relic_db.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/widgets/chrome.dart' show Scope;

Relic _r(
  String uid, {
  String? title,
  List<String> tags = const [],
  Kind kind = Kind.string,
  int createdAt = 1000,
  int updatedAt = 1000,
  String? content,
}) =>
    Relic(
      uid: uid,
      createdAt: createdAt,
      updatedAt: updatedAt,
      kind: kind,
      source: Source.clipboard,
      promoted: true,
      byteSize: 16,
      title: title,
      content: content ?? 'body of $uid',
      preview: 'p',
      tags: tags,
    );

AiRecord _rec(
  String uid, {
  int at = 5000,
  int level = 3,
  String? by = 'desk-a',
  String? title,
  List<String> tags = const [],
  String? text,
}) =>
    AiRecord(
      uid: uid,
      at: at,
      level: level,
      by: by,
      title: title,
      tags: tags,
      text: text,
    );

void main() {
  group('which result stands (mirrors worker/src/ai.ts aiResultWins)', () {
    test('anything beats nothing', () {
      expect(RelicDb.aiResultWins(_rec('u'), null), isTrue);
    });

    test('a higher level wins even when it is older', () {
      // A real model upgrade should apply, regardless of clocks.
      expect(
        RelicDb.aiResultWins(_rec('u', at: 100, level: 4), _rec('u', at: 9000, level: 3)),
        isTrue,
      );
    });

    test('never downgrades to an older model generation', () {
      expect(
        RelicDb.aiResultWins(_rec('u', at: 9000, level: 2), _rec('u', at: 100, level: 3)),
        isFalse,
      );
    });

    test('at equal level the earliest result from ANOTHER device stands', () {
      // This is what stops a device whose lease expired mid-job from publishing
      // late and changing a title the user is already looking at.
      final stored = _rec('u', at: 1000, by: 'desk-a');
      expect(
        RelicDb.aiResultWins(_rec('u', at: 900, by: 'desk-b'), stored),
        isTrue,
      );
      expect(
        RelicDb.aiResultWins(_rec('u', at: 1100, by: 'desk-b'), stored),
        isFalse,
      );
    });

    test('a device may amend its own record, but not walk it backwards', () {
      // The two halves of a record are produced by different passes that finish
      // at different times: the models caption an item, and a separate pass
      // reads its attachments once their bytes are local. Without this the
      // second half could never be published, because at equal level the
      // earlier record wins and the record IS its own predecessor.
      final stored = _rec('u', at: 1000, by: 'desk-a');
      expect(
        RelicDb.aiResultWins(_rec('u', at: 1000, by: 'desk-a'), stored),
        isTrue,
        reason: 'amending in place: same record, more of it',
      );
      expect(
        RelicDb.aiResultWins(_rec('u', at: 1200, by: 'desk-a'), stored),
        isTrue,
        reason: 'its own later word about its own record',
      );
      expect(
        RelicDb.aiResultWins(_rec('u', at: 800, by: 'desk-a'), stored),
        isFalse,
        reason: 'a record never moves backwards, not even its owner may',
      );
    });

    test('an exact tie breaks the same way on every device', () {
      // Both machines must reach the SAME verdict or they trade writes forever.
      final stored = _rec('u', at: 1000, by: 'bbb');
      expect(RelicDb.aiResultWins(_rec('u', at: 1000, by: 'aaa'), stored), isTrue);
      expect(
        RelicDb.aiResultWins(_rec('u', at: 1000, by: 'ccc'), stored),
        isFalse,
      );
    });

    test('a record with no device id cannot pass itself off as the owner', () {
      // Pre-dates the field, or a client that would not identify itself. It
      // must fall through to the ordinary rules rather than matching another
      // anonymous record and amending it.
      final stored = _rec('u', at: 1000, by: null);
      expect(RelicDb.aiResultWins(_rec('u', at: 1200, by: null), stored), isFalse);
    });
  });

  group('storing records', () {
    test('a better record replaces a worse one, a worse one is refused', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);

      expect(
        db.putAiRecord(_rec('u1', at: 1000, title: 'first'), needsPush: true),
        isTrue,
      );
      // Another device, later, same level: refused, and the stored record is
      // untouched.
      expect(
        db.putAiRecord(_rec('u1', at: 2000, by: 'desk-b', title: 'late'),
            needsPush: true),
        isFalse,
      );
      expect(db.aiRecord('u1')!.title, 'first');

      // Newer model generation: accepted.
      expect(
        db.putAiRecord(_rec('u1', at: 2000, level: 4, title: 'upgraded'),
            needsPush: true),
        isTrue,
      );
      expect(db.aiRecord('u1')!.title, 'upgraded');
    });

    test('records pulled from the server are never echoed back', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);

      db.putAiRecord(_rec('mine', title: 'local'), needsPush: true);
      db.putAiRecord(_rec('theirs', title: 'remote'), needsPush: false);

      expect(db.aiRecordsNeedingPush().map((r) => r.uid), ['mine']);
      expect(db.countAiRecordsNeedingPush(), 1);
    });

    test('marking pushed settles the record, including when a peer won', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.putAiRecord(_rec('u1', title: 'x'), needsPush: true);
      db.markAiPushed('u1');
      // A `stale: true` answer is an answer. Retrying would loop forever.
      expect(db.aiRecordsNeedingPush(), isEmpty);
      expect(db.aiRecord('u1')!.title, 'x', reason: 'settled, not discarded');
    });

    test('a record survives arriving before its relic does', () {
      // Relics and AI records ride independent cursors, so either order is
      // normal. The record has to wait rather than be dropped.
      final db = RelicDb.memory();
      addTearDown(db.dispose);

      db.putAiRecord(_rec('ghost', title: 'waiting'), needsPush: false);
      expect(db.aiRecord('ghost')!.title, 'waiting');
      expect(db.aiRecordsUnapplied(), isEmpty, reason: 'no relic to apply to');

      db.upsert(_r('ghost'));
      expect(db.aiRecordsUnapplied(), ['ghost']);
    });

    test('an applied record stops being reported as pending', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('u1'));
      db.putAiRecord(_rec('u1', level: 3, title: 't'), needsPush: false);
      expect(db.aiRecordsUnapplied(), ['u1']);

      db.raiseEnrichLevel('u1', 3);
      expect(db.aiRecordsUnapplied(), isEmpty);
    });

    test('deleting a relic takes its AI record with it', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('u1'));
      db.putAiRecord(_rec('u1', title: 't'), needsPush: false);

      db.delete('u1');
      expect(db.aiRecord('u1'), isNull,
          reason: 'a re-created uid must not inherit a stranger title');
    });

    test('an account switch stops owed records from reaching the new account', () {
      // The 2026-07-14 leak, in its AI-record form: work generated while bound
      // to one account must never be published into another.
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.putAiRecord(_rec('u1', title: 'from account A'), needsPush: true);
      expect(db.countAiRecordsNeedingPush(), 1);

      db.clearAllPendingSync();
      expect(db.aiRecordsNeedingPush(), isEmpty);
      expect(db.aiRecord('u1'), isNotNull,
          reason: 'still shown locally, just not outbound');
    });
  });

  group('enrich level', () {
    test('adopting a record level takes the item out of the work queue', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('u1'));
      expect(db.needingEnrich(3, 10).map((r) => r.uid), ['u1']);

      db.raiseEnrichLevel('u1', 3);
      expect(db.needingEnrich(3, 10), isEmpty,
          reason: 'a peer already did this work; do not redo it');
    });

    test('never moves backwards', () {
      // A record from a device on an OLDER model generation must not re-queue
      // the corpus on a newer one.
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('u1'));
      db.raiseEnrichLevel('u1', 3);
      db.raiseEnrichLevel('u1', 1);
      expect(db.enrichLevelOf('u1'), 3);
    });
  });

  group('merging a record into a relic', () {
    test('a generated title fills an empty one', () {
      final out = mergeAiRecord(
        cur: _r('u1'),
        rec: _rec('u1', title: 'Kessler Roofing pricing'),
        suppressed: const {},
      );
      expect(out.title, 'Kessler Roofing pricing');
    });

    test('a title the user typed is never replaced', () {
      final out = mergeAiRecord(
        cur: _r('u1', title: 'Q3 budget'),
        rec: _rec('u1', title: 'a spreadsheet of numbers'),
        suppressed: const {},
      );
      expect(out.title, 'Q3 budget');
    });

    test('tags merge without duplicating, case-blind', () {
      final out = mergeAiRecord(
        cur: _r('u1', tags: ['Markdown', 'invoice']),
        rec: _rec('u1', tags: ['markdown', 'roofing', 'invoice']),
        suppressed: const {},
      );
      expect(out.tags, ['Markdown', 'invoice', 'roofing']);
    });

    test('a tag the user deleted here is not re-added by a peer', () {
      // Suppression is local to each device, which is exactly why the producer
      // cannot do this filtering for us.
      final out = mergeAiRecord(
        cur: _r('u1', tags: ['invoice']),
        rec: _rec('u1', tags: ['roofing', 'receipt']),
        suppressed: const {'roofing'},
      );
      expect(out.tags, ['invoice', 'receipt']);
    });

    test('a record carrying nothing new leaves the relic alone', () {
      final cur = _r('u1', title: 'named', tags: ['invoice']);
      final out = mergeAiRecord(
        cur: cur,
        rec: _rec('u1', title: 'generated', tags: ['invoice']),
        suppressed: const {},
      );
      expect(out.title, cur.title);
      expect(out.tags, cur.tags);
    });

    test('a file keeps its filename as its headline', () {
      // Files are titled by their filename, never renamed to generated text.
      final out = mergeAiRecord(
        cur: _r('u1', kind: Kind.file),
        rec: _rec('u1', title: 'some prose about the contents'),
        suppressed: const {},
      );
      expect(out.title, isNull);
    });
  });

  group('one-time convergence of pre-existing titles', () {
    test('publishes what is already here, without running any models', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('titled', title: 'generated earlier', createdAt: 100));
      db.upsert(_r('tagged', tags: ['invoice'], createdAt: 200));
      db.upsert(_r('bare', createdAt: 300));
      for (final u in ['titled', 'tagged', 'bare']) {
        db.raiseEnrichLevel(u, 3);
      }

      final n = db.seedAiRecordsFromRelics(minLevel: 3, by: 'desk-a');
      expect(n, 2, reason: 'the bare item has nothing worth sending');
      expect(db.aiRecord('titled')!.title, 'generated earlier');
      expect(db.aiRecord('tagged')!.tags, ['invoice']);
      expect(db.aiRecord('bare'), isNull);
      expect(db.countAiRecordsNeedingPush(), 2);
    });

    test('stamps records with the relic created_at, so both devices agree', () {
      // The determinism argument: both machines derive the SAME ai_at for the
      // same item, so earliest-wins reduces to the device tiebreak and each one
      // independently picks the same winner. Using "now" would hand the vault
      // to whichever device happened to run the pass second.
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('u1', title: 't', createdAt: 4242));
      db.raiseEnrichLevel('u1', 3);

      db.seedAiRecordsFromRelics(minLevel: 3, by: 'desk-a');
      expect(db.aiRecord('u1')!.at, 4242);
    });

    test('skips items the ML pass never reached', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('stage-a-only', title: 'x'));
      db.raiseEnrichLevel('stage-a-only', 1);

      expect(db.seedAiRecordsFromRelics(minLevel: 3, by: 'd'), 0);
    });

    test('never overwrites a record that already exists', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('u1', title: 'local title'));
      db.raiseEnrichLevel('u1', 3);
      db.putAiRecord(_rec('u1', at: 10, title: 'a peer got here first'),
          needsPush: false);

      db.seedAiRecordsFromRelics(minLevel: 3, by: 'desk-a');
      expect(db.aiRecord('u1')!.title, 'a peer got here first');
      expect(db.countAiRecordsNeedingPush(), 0,
          reason: 'a record we already have must not become outbound');
    });

    test('is idempotent, so a second run costs nothing', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('u1', title: 't'));
      db.raiseEnrichLevel('u1', 3);

      expect(db.seedAiRecordsFromRelics(minLevel: 3, by: 'd'), 1);
      expect(db.seedAiRecordsFromRelics(minLevel: 3, by: 'd'), 0);
    });
  });

  group('extracted text travels with the record', () {
    // The half of the feature that decides whether a screenshot is findable by
    // the words inside it. OCR output lands in the relic's content column, and
    // that column only moves on a user edit, so before this the text existed on
    // exactly one machine: the one that happened to read the image.
    test('fills content on an item that has none', () {
      final out = mergeAiRecord(
        cur: _r('u1', kind: Kind.photo, content: ''),
        rec: _rec('u1', text: 'INVOICE 4471 Kessler Roofing \$2,480'),
        suppressed: const {},
      );
      expect(out.content, 'INVOICE 4471 Kessler Roofing \$2,480');
    });

    test('never overwrites text that is already here', () {
      // A peer cannot tell this device's own extraction from something the user
      // typed into the item, so the only safe rule is to leave both alone.
      final out = mergeAiRecord(
        cur: _r('u1', kind: Kind.photo, content: 'what the user wrote'),
        rec: _rec('u1', text: 'what the model read'),
        suppressed: const {},
      );
      expect(out.content, 'what the user wrote');
    });

    test('a text relic never takes AI text', () {
      // A string's content IS the relic. It already syncs in the envelope, and
      // a second copy arriving on a path with no last-write-wins would be a
      // stale body waiting to overwrite a real one.
      final out = mergeAiRecord(
        cur: _r('u1', kind: Kind.string, content: ''),
        rec: _rec('u1', text: 'not this relic\'s job'),
        suppressed: const {},
      );
      expect(out.content, '');
    });

    test('a record carrying only extracted text is still worth publishing', () {
      // A scanned page the labeler had nothing to say about still has all of
      // its text to contribute.
      expect(_rec('u1', text: 'a page of scanned words').isEmpty, isFalse);
      expect(_rec('u1').isEmpty, isTrue);
    });

    test('survives the round trip through the local table', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.putAiRecord(_rec('u1', text: 'read off the image'), needsPush: true);
      expect(db.aiRecord('u1')!.text, 'read off the image');
      expect(db.aiRecordsNeedingPush().single.text, 'read off the image');
    });

    test('a long document is cut to the budget, not dropped', () {
      // The front of a document is where its title, headings and names are, so
      // most of it is worth far more than none of it.
      final payload = _rec('u1', text: 'x' * 200000).toPayload();
      final t = payload['text'] as String;
      expect(t.length, lessThanOrEqualTo(kAiTextBytes + 1));
      expect(t.endsWith('…'), isTrue, reason: 'and says so');
    });

    test('the budget is counted in bytes, not characters', () {
      // A character budget would let a document in a non-Latin script build a
      // record three times the size the server accepts, and a refused record is
      // dropped rather than retried.
      final t = aiTextForWire('東' * 20000)!;
      expect(t.length, lessThan(20000));
      expect(utf8.encode(t).length, lessThanOrEqualTo(kAiTextBytes + 3));
    });

    test('a character built from a surrogate pair is never split', () {
      final t = aiTextForWire('🧾' * 20000)!;
      // Half a pair survives encoding only as a replacement character, so the
      // round trip is the test: it comes back unchanged only if the cut fell
      // between whole characters.
      expect(utf8.decode(utf8.encode(t)), t);
      expect(utf8.encode(t).length, lessThanOrEqualTo(kAiTextBytes + 3));
      expect(t.runes.last, '…'.runes.first);
    });

    test('text that still will not fit is dropped, the title is not', () {
      // JSON escaping has no fixed ratio: one control character costs six bytes
      // to encode. Losing the whole record over that would be the worse
      // outcome, so the text goes and everything else travels.
      final rec = _rec('u1', title: 'Scan 41', text: '' * kAiTextBytes);
      final payload = rec.toPayload();
      expect(payload.containsKey('text'), isFalse);
      expect(payload['title'], 'Scan 41');
    });

    test('convergence seeds the text an already-enriched vault holds', () {
      // The case that matters for this user's own vault: the desktops have
      // already OCR'd everything, and none of it has ever left them.
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('shot', kind: Kind.photo, content: 'BOARDING PASS 14C'));
      db.upsert(_r('note', kind: Kind.string, content: 'typed by hand'));
      db.raiseEnrichLevel('shot', 3);
      db.raiseEnrichLevel('note', 3);

      db.seedAiRecordsFromRelics(minLevel: 3, by: 'desk-a');
      expect(db.aiRecord('shot')!.text, 'BOARDING PASS 14C',
          reason: 'an untitled screenshot is seeded for its text alone');
      expect(db.aiRecord('note'), isNull,
          reason: 'a text relic already syncs its own body');
    });
  });

  group('attachment text travels with the record', () {
    // Reading an attachment needs no models, but it does need the attachment
    // bytes, and blobs download lazily. A desktop that never opened the note
    // has nothing to read, and a phone has no extractor at all, so both would
    // otherwise find the note by its filename and nothing else.
    test('lands where the device has none of its own', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('u1'));

      expect(db.applyAttachmentText('u1', 'QUOTE 118 Kessler Roofing'), isTrue);
      // Searchable, which is the entire point: the note itself says nothing
      // about Kessler, only the file stapled to it does.
      expect(db.queryPage('kessler', Scope.all, 10, 0).map((r) => r.uid), ['u1']);
    });

    test('never overwrites what this device read itself', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('u1'));
      db.setAttachmentText('u1', 'read from the local bytes');

      expect(db.applyAttachmentText('u1', 'a peer copy'), isFalse);
    });

    test('"ran, found nothing" is an answer and is not retried', () {
      // The empty string is a value here, not an absence: it means extraction
      // ran and there was nothing to index. Treating it as absent would put the
      // item back in the backlog on every device, forever.
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('u1'));
      db.setAttachmentText('u1', '');

      expect(db.applyAttachmentText('u1', 'a peer copy'), isFalse);
    });

    test('an amendment does not discard the half that came first', () {
      // The models caption an item; a separate pass reads its attachments once
      // their bytes are local. Whichever finishes second must add to the record
      // rather than replace it.
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.putAiRecord(
        _rec('u1', at: 100, by: 'desk-a', title: 'Roofing quote', tags: ['invoice']),
        needsPush: false,
      );
      expect(
        db.putAiRecord(
          AiRecord(uid: 'u1', at: 100, level: 3, by: 'desk-a', att: 'QUOTE 118'),
          needsPush: true,
        ),
        isTrue,
      );

      final rec = db.aiRecord('u1')!;
      expect(rec.att, 'QUOTE 118');
      expect(rec.title, 'Roofing quote', reason: 'the first half survived');
      expect(rec.tags, ['invoice']);
      expect(db.countAiRecordsNeedingPush(), 1,
          reason: 'and the whole, merged record is what gets published');
    });

    test('the two extracted texts share one budget', () {
      // They barely compete in practice — an item with OCR of its own is a
      // photo or a document, and a note with attachments has nothing to OCR —
      // so one budget spent in order beats doubling the ceiling for a case that
      // hardly happens.
      final p = AiRecord(
        uid: 'u1', at: 1, level: 3, by: 'd',
        text: 'x' * 40000,
        att: 'y' * 40000,
      ).toPayload();
      final total = utf8.encode(p['text'] as String).length +
          utf8.encode(p['att'] as String? ?? '').length;
      expect(total, lessThanOrEqualTo(kAiTextBytes + 8));
    });

    test('convergence seeds attachment text an already-indexed vault holds', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('note'));
      db.raiseEnrichLevel('note', 3);
      db.setAttachmentText('note', 'the bundled PDF said this');

      db.seedAiRecordsFromRelics(minLevel: 3, by: 'desk-a');
      expect(db.aiRecord('note')!.att, 'the bundled PDF said this');
    });
  });

  group('the semantic index on a device that did not do the work', () {
    // The hole the work-claim opened. Only one device runs the models on an
    // item now, and every other device adopts the result and marks the item
    // done — which also meant they never embedded it, so it was missing from
    // their semantic index and findable there by keyword only.
    test('an adopted item with no local vector is queued for embedding', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('adopted', content: 'a peer read this out of a screenshot'));
      db.raiseEnrichLevel('adopted', 3);

      expect(db.needingVectors(3, 10).map((r) => r.uid), ['adopted']);
    });

    test('an item this device embedded itself is not redone', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('mine', content: 'text'));
      db.raiseEnrichLevel('mine', 3);
      db.upsertVectors('mine', [
        [0.1, 0.2, 0.3],
      ]);

      expect(db.needingVectors(3, 10), isEmpty);
    });

    test('an item still awaiting the models is left to the normal pass', () {
      // Otherwise the backfill would embed it now and the enrich pass would
      // embed it again a moment later.
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('pending', content: 'text'));

      expect(db.needingVectors(3, 10), isEmpty);
    });

    test('an item with nothing to embed leaves the queue for good', () {
      // There is no vector to produce, so without this it would come back every
      // six seconds for the life of the vault.
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('empty', content: '  '));
      db.raiseEnrichLevel('empty', 3);

      expect(db.needingVectors(3, 10), isEmpty);
    });

    test('the embedded document matches what the enriching device embedded', () {
      // A vector is only worth anything if it means the same thing on every
      // device. Two machines embedding different documents for one item would
      // rank the same query differently.
      final note = Relic(
        uid: 'n', createdAt: 1, updatedAt: 1, kind: Kind.string,
        source: Source.clipboard, promoted: true, byteSize: 4,
        title: 'Stripe webhook retry logic', note: 'from the incident',
        content: 'the snippet itself', preview: 'p',
      );
      expect(
        LocalDeskRepo.embedDocFor(note),
        'Stripe webhook retry logic\nfrom the incident\nthe snippet itself',
      );
      // A screenshot has neither: what it means is whatever was read out of it.
      expect(
        LocalDeskRepo.embedDocFor(
            _r('s', kind: Kind.photo, content: 'BOARDING PASS 14C')),
        'BOARDING PASS 14C',
      );
    });
  });

  group('the relic timeline stays undisturbed', () {
    test('applying AI output does not bump updated_at or queue a push', () {
      // The whole reason AI output is a separate document. If it rode the relic
      // envelope, every background tagging pass would count as a user edit,
      // reshuffle "recently updated", and race a rename.
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(_r('u1', updatedAt: 1000), queuePush: true);
      db.clearOp('u1', 'push');
      expect(db.pendingCount(), 0);

      final cur = db.getByUid('u1')!;
      final merged = mergeAiRecord(
        cur: cur,
        rec: _rec('u1', title: 'generated', tags: ['invoice']),
        suppressed: const {},
      );
      db.upsert(cur.copyWith(tags: merged.tags, title: merged.title));

      expect(db.getByUid('u1')!.title, 'generated');
      expect(db.updatedAtOf('u1'), 1000, reason: 'timeline untouched');
      expect(db.pendingCount(), 0, reason: 'AI output never rides the envelope');
    });
  });
}

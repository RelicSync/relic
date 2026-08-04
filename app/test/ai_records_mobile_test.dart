// The phone's half of AI records: a pure consumer.
//
// Phones never run the models — the weights are gigabytes and the compute is
// minutes — so every title a phone shows was generated on one of the account's
// desktops. Before AI records existed there was no way for it to get there at
// all: enrichment wrote the title to the producing machine's local row and
// stopped. On a phone that meant a vaulted screenshot stayed untitled forever
// while a desktop three feet away had already named it.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_crypto/relic_crypto.dart';
import 'package:relic_app/data/supabase_auth.dart';
import 'package:relic_app/data/worker_repo.dart';
import 'package:relic_app/widgets/chrome.dart' show Scope;

// Same rationale as clear_history_test: flutter_test's binding answers every
// request with 400, which the outbox treats as a permanent rejection. Real
// networking plus the discard port gives a transient failure instead.
class _RealNetwork extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealNetwork();

  final mk = Uint8List.fromList(List.generate(32, (i) => i * 7 & 0xff));

  Future<WorkerRepo> repo() => WorkerRepo.bindSupabaseWithMk(
        baseUrl: 'http://127.0.0.1:9', // discard port — flushes fail fast
        session: const SupabaseSession(
          accessToken: 't',
          refreshToken: 'r',
          expiresAt: 4102444800,
          userId: 'test-user',
        ),
        mk: mk,
        autoVault: true,
      );

  Future<Map<String, dynamic>> relicEnv(
    String uid, {
    required String content,
    String? title,
    List<String> tags = const [],
    int updatedAt = 10,
    String kind = 'string',
  }) async {
    final sealed = await RelicCrypto.sealRelicPayload(mk, uid, {
      'kind': kind,
      'source': 'clipboard',
      'content': content,
      'preview': content,
      if (title != null) 'title': title,
      'tags': tags,
      'user_tags': <String>[],
    });
    return {
      'v': 1,
      'uid': uid,
      'created_at': 1,
      'updated_at': updatedAt,
      'byte_size': content.length,
      'promoted': true,
      'n': sealed['n'],
      'ct': sealed['ct'],
    };
  }

  Future<Map<String, dynamic>> aiEnv(
    String uid, {
    String? title,
    List<String> tags = const [],
    String? text,
    String? att,
    int at = 500,
    int level = 3,
    String device = 'desk-a',
  }) async {
    final sealed = await RelicCrypto.sealAiPayload(mk, uid, {
      if (title != null) 'title': title,
      'tags': tags,
      if (text != null) 'text': text,
      if (att != null) 'att': att,
    });
    return {
      'v': 1,
      'uid': uid,
      'ai_at': at,
      'level': level,
      'device': device,
      'n': sealed['n'],
      'ct': sealed['ct'],
    };
  }

  test('a desktop-generated title reaches the phone', () async {
    final r = await repo();
    await r.debugUpsertEnv(await relicEnv('u1', content: 'some pasted text'));
    expect(r.all.single.title, isNull, reason: 'nothing has named it yet');

    expect(
      await r.debugAbsorbAiEnv(
          await aiEnv('u1', title: 'Kessler Roofing pricing', tags: ['invoice'])),
      isTrue,
    );
    expect(r.all.single.title, 'Kessler Roofing pricing');
    expect(r.all.single.tags, contains('invoice'));
  });

  test('a record that arrives before its relic still lands', () async {
    // Relics and AI records ride independent cursors, so either order happens.
    final r = await repo();
    expect(await r.debugAbsorbAiEnv(await aiEnv('u1', title: 'named early')),
        isFalse, reason: 'nothing to apply it to yet');

    await r.debugUpsertEnv(await relicEnv('u1', content: 'the body'));
    expect(r.all.single.title, 'named early',
        reason: 'the waiting record applies when the relic shows up');
  });

  test('an unrelated edit elsewhere does not strip the generated title',
      () async {
    // The relic envelope never carries the AI title, so a later relic update
    // rebuilds the row without it. It has to be folded back in.
    final r = await repo();
    await r.debugUpsertEnv(await relicEnv('u1', content: 'v1', updatedAt: 10));
    await r.debugAbsorbAiEnv(await aiEnv('u1', title: 'generated'));
    expect(r.all.single.title, 'generated');

    await r.debugUpsertEnv(await relicEnv('u1', content: 'v2', updatedAt: 20));
    expect(r.all.single.content, 'v2', reason: 'the edit applied');
    expect(r.all.single.title, 'generated', reason: 'and the title survived it');
  });

  test('a title the user typed is never replaced by a generated one', () async {
    final r = await repo();
    await r.debugUpsertEnv(
        await relicEnv('u1', content: 'body', title: 'Q3 budget'));
    await r.debugAbsorbAiEnv(
        await aiEnv('u1', title: 'a spreadsheet of numbers'));
    expect(r.all.single.title, 'Q3 budget');
  });

  test('another vault\'s record is refused rather than half-applied', () async {
    final r = await repo();
    await r.debugUpsertEnv(await relicEnv('u1', content: 'body'));

    final otherKey = Uint8List.fromList(List.filled(32, 9));
    final sealed =
        await RelicCrypto.sealAiPayload(otherKey, 'u1', {'title': 'not yours'});
    final foreign = {
      'v': 1, 'uid': 'u1', 'ai_at': 500, 'level': 3, 'device': 'x',
      'n': sealed['n'], 'ct': sealed['ct'],
    };
    expect(await r.debugAbsorbAiEnv(foreign), isFalse);
    expect(r.all.single.title, isNull);
  });

  test('a screenshot becomes searchable by the words inside it', () async {
    // The phone cannot read an image and never will. Either the desktop's OCR
    // travels or a vaulted receipt is findable at one desk and nowhere else.
    final r = await repo();
    await r.debugUpsertEnv(
        await relicEnv('u1', content: '', kind: 'photo'));
    await r.debugAbsorbAiEnv(
        await aiEnv('u1', title: 'a boarding pass', text: 'BOARDING PASS 14C'));

    expect(r.all.single.content, 'BOARDING PASS 14C');
    await r.setQuery('boarding', Scope.all);
    expect(r.visible.map((x) => x.uid), ['u1']);
  });

  test('extracted text never overwrites what is already on the item', () async {
    // Could be this device's own copy, could be something the user typed. The
    // sending device cannot tell the two apart, so it defers to neither.
    final r = await repo();
    await r.debugUpsertEnv(
        await relicEnv('u1', content: 'the user\'s own words', kind: 'photo'));
    await r.debugAbsorbAiEnv(await aiEnv('u1', text: 'what the model read'));
    expect(r.all.single.content, 'the user\'s own words');
  });

  test('a text relic keeps its own body', () async {
    // A string's content is the relic. It syncs in the envelope, with
    // last-write-wins behind it; an AI record must not write a second copy on
    // a path that has none.
    final r = await repo();
    await r.debugUpsertEnv(await relicEnv('u1', content: 'typed by hand'));
    await r.debugAbsorbAiEnv(await aiEnv('u1', text: 'stale copy'));
    expect(r.all.single.content, 'typed by hand');
  });

  test('a note is findable by what its attachment says', () async {
    // Reading an attachment needs no models, but it does need the attachment
    // bytes and an extractor. A phone has neither, so a desktop's copy is the
    // only one it will ever have — without it, the note is findable here by
    // its filename and nothing else.
    final r = await repo();
    await r.debugUpsertEnv(await relicEnv('u1', content: 'quote from the roofer'));
    r.debugRebuildIndex(); // the index a launched app already has
    await r.debugAbsorbAiEnv(await aiEnv('u1', att: 'QUOTE 118 Kessler Roofing'));

    await r.setQuery('kessler', Scope.all);
    expect(r.visible.map((x) => x.uid), ['u1']);
  });

  test('attachment text survives a full index rebuild', () async {
    // A rebuild reloads every index row from the relics alone, and attachment
    // text is not on the relic. It has to be written back on top or search
    // quietly loses it on the next launch.
    final r = await repo();
    await r.debugUpsertEnv(await relicEnv('u1', content: 'quote from the roofer'));
    await r.debugAbsorbAiEnv(await aiEnv('u1', att: 'QUOTE 118 Kessler Roofing'));
    r.debugRebuildIndex();

    await r.setQuery('kessler', Scope.all);
    expect(r.visible.map((x) => x.uid), ['u1']);
  });

  test('tags merge without duplicating what the relic already carries',
      () async {
    final r = await repo();
    await r.debugUpsertEnv(
        await relicEnv('u1', content: 'body', tags: ['invoice']));
    await r.debugAbsorbAiEnv(
        await aiEnv('u1', tags: ['invoice', 'roofing']));
    expect(r.all.single.tags, ['invoice', 'roofing']);
  });
}

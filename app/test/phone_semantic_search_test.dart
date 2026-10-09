// Semantic search on the phone.
//
// A phone runs no model over its items. The vectors come from a desktop,
// inside the AI record it publishes for each item, and the phone compares
// them against a query vector from an encoder the host plugs in. These tests
// use a fake encoder with canned answers, so they pin the plumbing: which
// stored vectors count, how the leg is gated, that the lexical answer shows
// first and the semantic one lands on top, and that a slow answer for a
// query the user has typed past changes nothing.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_crypto/relic_crypto.dart';
import 'package:relic_app/data/query_encoder.dart';
import 'package:relic_app/data/repo.dart' show SortMode;
import 'package:relic_app/data/supabase_auth.dart';
import 'package:relic_app/data/worker_repo.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/widgets/chrome.dart' show Scope;

// Same rationale as ai_records_mobile_test: flutter_test's binding answers
// every request with 400, which the outbox treats as a permanent rejection.
// Real networking plus the discard port gives a transient failure instead.
class _RealNetwork extends HttpOverrides {}

const _space = 'embeddinggemma-300m-ft2@int8-mrl256';
const _dim = 256;

/// A unit vector along one axis, as wide as the real space.
List<double> _axis(int i) =>
    [for (var j = 0; j < _dim; j++) j == i ? 1.0 : 0.0];

/// An encoder whose answers are looked up, not computed.
class _FakeEncoder implements QueryEncoder {
  _FakeEncoder({this.space = _space});

  @override
  final String space;
  @override
  String get name => 'fake';
  @override
  bool ready = true;

  final Map<String, List<double>> canned = {};

  /// When set, the next embed waits on it before answering, so a test can
  /// hold one answer back while a later query lands.
  Completer<void>? holdNext;
  int embeds = 0;
  int unloads = 0;

  @override
  Future<Float32List?> embed(String query) async {
    embeds++;
    final hold = holdNext;
    holdNext = null;
    if (hold != null) await hold.future;
    final v = canned[query.trim().toLowerCase()];
    return v == null ? null : Float32List.fromList(v);
  }

  @override
  Future<void> unload() async {
    unloads++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealNetwork();

  final mk = Uint8List.fromList(List.generate(32, (i) => i * 7 & 0xff));

  Future<WorkerRepo> repo() async {
    final r = await WorkerRepo.bindSupabaseWithMk(
      baseUrl: 'http://127.0.0.1:9', // discard port: flushes fail fast
      session: const SupabaseSession(
        accessToken: 't',
        refreshToken: 'r',
        expiresAt: 4102444800,
        userId: 'test-user',
      ),
      mk: mk,
      autoVault: true,
    );
    r.semanticDebounce = const Duration(milliseconds: 20);
    return r;
  }

  /// Long enough for the debounce and the embed to run.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 250));

  Future<Map<String, dynamic>> relicEnv(
    String uid, {
    required String content,
    bool promoted = true,
  }) async {
    final sealed = await RelicCrypto.sealRelicPayload(mk, uid, {
      'kind': 'string',
      'source': 'clipboard',
      'content': content,
      'preview': content,
      'tags': <String>[],
      'user_tags': <String>[],
    });
    return {
      'v': 1,
      'uid': uid,
      'created_at': 1,
      'updated_at': 10,
      'byte_size': content.length,
      'promoted': promoted,
      'n': sealed['n'],
      'ct': sealed['ct'],
    };
  }

  Future<Map<String, dynamic>> aiEnv(
    String uid, {
    List<List<double>>? vectors,
    String model = _space,
    String? title,
  }) async {
    final sealed = await RelicCrypto.sealAiPayload(mk, uid, {
      'title': ?title,
      'tags': <String>[],
      if (vectors != null) 'vec': AiVectors.quantize(model, vectors).toJson(),
    });
    return {
      'v': 1,
      'uid': uid,
      'ai_at': 500,
      'level': 3,
      'device': 'desk-a',
      'n': sealed['n'],
      'ct': sealed['ct'],
    };
  }

  /// Two items. The first has a vector along axis 0, the second along
  /// axis 1. Neither says "gutter".
  Future<WorkerRepo> twoItems({bool secondPromoted = true}) async {
    final r = await repo();
    await r.debugUpsertEnv(
        await relicEnv('u1', content: 'some pasted text about roofing'));
    await r.debugUpsertEnv(await relicEnv('u2',
        content: 'weekly grocery list', promoted: secondPromoted));
    await r.debugAbsorbAiEnv(await aiEnv('u1', vectors: [_axis(0)]));
    await r.debugAbsorbAiEnv(await aiEnv('u2', vectors: [_axis(1)]));
    r.debugRebuildIndex(); // the index a launched app already has
    return r;
  }

  test('a query no keyword matches is found through its vector', () async {
    final r = await twoItems();
    final enc = _FakeEncoder()..canned['gutter quote'] = _axis(0);
    r.queryEncoder = enc;
    expect(r.usableVectorCount, 2);
    expect(r.semanticSearchActive, isTrue);

    await r.setQuery('gutter quote', Scope.all);
    expect(r.visible, isEmpty, reason: 'nothing says gutter');

    await settle();
    expect(r.visible.map((x) => x.uid), ['u1']);
    expect(r.matchCount, 1);
    expect(enc.embeds, 1);
  });

  test('a vector from another model is not compared against', () async {
    final r = await repo();
    await r.debugUpsertEnv(
        await relicEnv('u1', content: 'some pasted text about roofing'));
    await r.debugAbsorbAiEnv(await aiEnv('u1',
        vectors: [_axis(0)], model: 'some-other-model@int8'));
    r.debugRebuildIndex();
    final enc = _FakeEncoder()..canned['gutter quote'] = _axis(0);
    r.queryEncoder = enc;

    expect(r.storedVectorCount, 1, reason: 'the record carries a vector');
    expect(r.usableVectorCount, 0, reason: 'but not in this encoder\'s space');
    expect(r.semanticSearchActive, isFalse);

    await r.setQuery('gutter quote', Scope.all);
    await settle();
    expect(r.visible, isEmpty);
    expect(enc.embeds, 0, reason: 'no usable vector, so no embed');

    // Swapping in an encoder for that space re-reads the stored vectors.
    r.queryEncoder = _FakeEncoder(space: 'some-other-model@int8');
    expect(r.usableVectorCount, 1);
    expect(r.semanticSearchActive, isFalse,
        reason: 'that space has no measured floor, so the leg stays off');
  });

  test('without an encoder, or with the switch off, results are lexical',
      () async {
    final r = await twoItems();
    // The vector for this query points at the grocery list, so the semantic
    // leg would add u2 to a lexical answer that only holds u1.
    final enc = _FakeEncoder()..canned['pasted text'] = _axis(1);
    var ticks = 0;
    r.changes.addListener(() => ticks++);

    await r.setQuery('pasted text', Scope.all);
    expect(r.visible.map((x) => x.uid), ['u1']);
    await settle();
    expect(r.visible.map((x) => x.uid), ['u1'], reason: 'no encoder');
    expect(ticks, 0);

    r.queryEncoder = enc;
    r.semanticSearch = false;
    await r.setQuery('pasted text', Scope.all);
    await settle();
    expect(r.visible.map((x) => x.uid), ['u1'], reason: 'switch off');
    expect(enc.embeds, 0, reason: 'the encoder is never asked');

    r.semanticSearch = true;
    await r.setQuery('pasted text', Scope.all);
    await settle();
    expect(r.visible.map((x) => x.uid), ['u1', 'u2'],
        reason: 'the keyword hit stays first; the vector hit joins it');
    expect(r.matchCount, 2);
  });

  test('a deleted item\'s vector is gone', () async {
    final r = await twoItems();
    final enc = _FakeEncoder()..canned['gutter quote'] = _axis(0);
    r.queryEncoder = enc;
    expect(r.usableVectorCount, 2);

    await r.delete(r.byUid('u1')!);
    expect(r.usableVectorCount, 1);

    await r.setQuery('gutter quote', Scope.all);
    await settle();
    expect(r.visible, isEmpty, reason: 'nothing left to match the vector');
  });

  test('the lexical answer shows first; the semantic one lands on top, '
      'and a stale answer is dropped', () async {
    final r = await twoItems();
    final enc = _FakeEncoder()
      ..canned['pasted text'] = _axis(1)
      ..canned['alpha beta'] = _axis(0);
    r.queryEncoder = enc;
    var ticks = 0;
    r.changes.addListener(() => ticks++);

    await r.setQuery('pasted text', Scope.all);
    expect(r.visible.map((x) => x.uid), ['u1'],
        reason: 'the lexical answer is there as soon as setQuery returns');
    expect(ticks, 0);
    await settle();
    expect(ticks, 1, reason: 'the semantic answer is one publish');
    expect(r.visible.map((x) => x.uid), ['u1', 'u2']);

    // Hold the answer for one query while the user types past it.
    final hold = Completer<void>();
    enc.holdNext = hold;
    await r.setQuery('alpha beta', Scope.all);
    expect(r.visible, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(enc.embeds, 2, reason: 'the embed started and is waiting');

    await r.setQuery('pasted text', Scope.all);
    await settle();
    expect(r.visible.map((x) => x.uid), ['u1', 'u2']);
    expect(ticks, 2);

    hold.complete(); // the old answer arrives now
    await settle();
    expect(r.visible.map((x) => x.uid), ['u1', 'u2'],
        reason: 'the answer for "alpha beta" changed nothing');
    expect(ticks, 2, reason: 'and published nothing');
  });

  test('vault scope only sees promoted items', () async {
    final r = await twoItems(secondPromoted: false);
    final enc = _FakeEncoder()..canned['alpha beta'] = _axis(1);
    r.queryEncoder = enc;

    await r.setQuery('alpha beta', Scope.vault);
    await settle();
    expect(r.visible, isEmpty, reason: 'u2 is not in the vault');

    await r.setQuery('alpha beta', Scope.all);
    await settle();
    expect(r.visible.map((x) => x.uid), ['u2']);
  });

  test('the leg is skipped for tag:, negation, short and date-sorted queries',
      () async {
    final r = await twoItems();
    final enc = _FakeEncoder()
      ..canned['tag:x gutter'] = _axis(0)
      ..canned['gutter -quote'] = _axis(0)
      ..canned['gu'] = _axis(0)
      ..canned['gutter quote'] = _axis(0);
    r.queryEncoder = enc;

    await r.setQuery('tag:x gutter', Scope.all);
    await r.setQuery('gutter -quote', Scope.all);
    await r.setQuery('gu', Scope.all);
    await r.setQuery('gutter quote', Scope.all, sort: SortMode.newest);
    await settle();
    expect(enc.embeds, 0);
    expect(r.visible, isEmpty);
  });

  test('the encoder is unloaded after an idle spell', () async {
    final r = await twoItems();
    r.encoderIdleUnload = const Duration(milliseconds: 60);
    final enc = _FakeEncoder()..canned['gutter quote'] = _axis(0);
    r.queryEncoder = enc;

    await r.setQuery('gutter quote', Scope.all);
    await settle();
    expect(r.visible.map((x) => x.uid), ['u1']);
    expect(enc.unloads, 1);
  });
}

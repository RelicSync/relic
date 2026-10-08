// The vectors an AI record carries, so a phone can search by meaning with
// the desktop's work. These pin the wire shape and the quantisation error.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/models/relic.dart';

const _space = 'embeddinggemma-300m-ft2@int8-mrl256';

List<double> _unit(math.Random rnd, int dim) {
  final v = List.generate(dim, (_) => rnd.nextDouble() * 2 - 1);
  final n = math.sqrt(v.fold<double>(0, (a, x) => a + x * x));
  return [for (final x in v) x / n];
}

double _dot(List<double> a, List<double> b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    s += a[i] * b[i];
  }
  return s;
}

void main() {
  final rnd = math.Random(7);

  test('a quantised vector round-trips within one percent of cosine', () {
    final v = _unit(rnd, 256);
    final q = AiVectors.quantize(_space, [v]);
    expect(q.dim, 256);
    expect(q.chunks.single.length, 256);
    final back = q.chunk(0);
    expect(_dot(v, back), closeTo(1.0, 0.01));
    // Dequantised chunks are unit length again, so dot == cosine downstream.
    expect(_dot(back, back), closeTo(1.0, 1e-5));
  });

  test('the wire shape is m, d, q, s, c and survives JSON', () {
    final q = AiVectors.quantize(_space, [_unit(rnd, 256), _unit(rnd, 256)]);
    final j = jsonDecode(jsonEncode(q.toJson())) as Map<String, dynamic>;
    expect(j['m'], _space);
    expect(j['d'], 256);
    expect(j['q'], 'i8');
    expect((j['s'] as List).length, 2);
    expect((j['c'] as List).length, 2);
    final back = AiVectors.fromJson(j)!;
    expect(back.model, _space);
    expect(back.chunks.length, 2);
    expect(_dot(back.chunk(1), q.chunk(1)), closeTo(1.0, 1e-5));
    // Two chunks of 256 int8 plus scales stay well under a few kilobytes.
    expect(utf8.encode(jsonEncode(q.toJson())).length, lessThan(900));
  });

  test('more chunks than the cap are dropped from the end', () {
    final many = List.generate(AiVectors.maxChunks + 4, (_) => _unit(rnd, 8));
    final q = AiVectors.quantize(_space, many);
    expect(q.chunks.length, AiVectors.maxChunks);
  });

  test('anything malformed reads as no vectors, never as an error', () {
    expect(AiVectors.fromJson(null), isNull);
    expect(AiVectors.fromJson('nope'), isNull);
    expect(AiVectors.fromJson({'m': _space, 'd': 4, 'q': 'f32', 's': [1.0], 'c': ['AAAA']}),
        isNull, reason: 'only int8 is understood');
    expect(
        AiVectors.fromJson({'m': _space, 'd': 4, 'q': 'i8', 's': [1.0, 1.0], 'c': ['AAAAAA==']}),
        isNull,
        reason: 'scales and chunks must pair up');
    expect(AiVectors.fromJson({'m': _space, 'd': 4, 'q': 'i8', 's': [1.0], 'c': ['AAA=']}),
        isNull,
        reason: 'a chunk must be dim long');
  });

  test('the AI record carries it and old payloads still parse', () {
    final q = AiVectors.quantize(_space, [_unit(rnd, 256)]);
    final rec = AiRecord(uid: 'u', at: 10, level: 3, title: 'Key', vec: q);
    final p = rec.toPayload();
    expect(p['vec'], isA<Map<String, dynamic>>());
    final back = AiRecord.fromWire({'uid': 'u', 'ai_at': 10, 'level': 3}, p);
    expect(back.vec, isNotNull);
    expect(back.vec!.model, _space);
    expect(back.title, 'Key');
    // A payload from before the field has no vectors and nothing else changes.
    final old = AiRecord.fromWire({'uid': 'u', 'ai_at': 10}, {'title': 'Key', 'tags': <String>[]});
    expect(old.vec, isNull);
    expect(old.title, 'Key');
  });

  test('a record with only vectors is worth publishing', () {
    final q = AiVectors.quantize(_space, [_unit(rnd, 16)]);
    expect(AiRecord(uid: 'u', at: 1, level: 1, vec: q).isEmpty, isFalse);
    expect(const AiRecord(uid: 'u', at: 1, level: 1).isEmpty, isTrue);
  });
}

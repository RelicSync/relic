// The pure-Dart WordPiece tokenizer against ids from Python's tokenizers
// (0.22) on a toy BERT-style vocabulary: test/fixtures/wordpiece_toy.tokenizer.json
// holds the file, wordpiece_toy_cases.json the texts with the ids and mask
// Python produced, with [CLS] and [SEP] on. The cases cover lowercasing,
// accent stripping, punctuation splitting, a long word, CJK characters,
// added tokens typed by hand, runs of whitespace, an empty string, and one
// case cut to six tokens.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/wordpiece_tokenizer.dart';

void main() {
  final tok = WordPieceTokenizer.fromJson(
      File('test/fixtures/wordpiece_toy.tokenizer.json').readAsStringSync());
  final cases = (jsonDecode(
          File('test/fixtures/wordpiece_toy_cases.json').readAsStringSync())
      as List)
      .cast<Map<String, dynamic>>();

  test('matches Python tokenizers on every toy case', () {
    expect(cases.length, greaterThan(30));
    final failures = <String>[];
    for (final c in cases) {
      final text = c['text'] as String;
      final want = (c['ids'] as List).cast<int>();
      final mask = (c['mask'] as List).cast<int>();
      final max = c['max'] as int? ?? 512;
      final got = tok.encode(text, maxTokens: max);
      if (got.ids.join(',') != want.join(',') ||
          got.mask.join(',') != mask.join(',')) {
        failures.add('${jsonEncode(text)}\n  want $want\n  got  ${got.ids}');
      }
    }
    expect(failures, isEmpty,
        reason: '${failures.length} of ${cases.length} differ:\n'
            '${failures.join('\n')}');
  });

  test('specials come from the template', () {
    expect(tok.clsId, 2);
    expect(tok.sepId, 3);
    expect(tok.unkId, 1);
    expect(tok.encode('', maxTokens: 64).ids, [2, 3]);
  });
}

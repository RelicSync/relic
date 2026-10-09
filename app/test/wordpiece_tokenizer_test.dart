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

  // The shipped student's real tokenizer (all-MiniLM-L6-v2, uncased, 30,522
  // pieces) against 61 cases from Python tokenizers 0.22, truncation 64:
  // test/fixtures/wordpiece_minilm_cases.json. The tokenizer.json is not in
  // the repo, so this runs only when RELIC_STUDENT_DIR points at a directory
  // holding it (the model release folder, or the phone's models dir).
  test('matches Python tokenizers on the real MiniLM file', () {
    final dir = Platform.environment['RELIC_STUDENT_DIR'];
    final file = dir == null ? null : File('$dir/tokenizer.json');
    if (file == null || !file.existsSync()) {
      markTestSkipped('RELIC_STUDENT_DIR not set or has no tokenizer.json');
      return;
    }
    final real = WordPieceTokenizer.fromJson(file.readAsStringSync());
    final real61 = (jsonDecode(
            File('test/fixtures/wordpiece_minilm_cases.json').readAsStringSync())
        as List)
        .cast<Map<String, dynamic>>();
    expect(real61.length, 61);
    expect(real.clsId, 101);
    expect(real.sepId, 102);
    expect(real.unkId, 100);
    final failures = <String>[];
    for (final c in real61) {
      final text = c['text'] as String;
      final want = (c['ids'] as List).cast<int>();
      final got = real.encode(text, maxTokens: 64);
      if (got.ids.join(',') != want.join(',')) {
        failures.add('${jsonEncode(text)}\n  want $want\n  got  ${got.ids}');
      }
    }
    expect(failures, isEmpty,
        reason: '${failures.length} of ${real61.length} differ:\n'
            '${failures.join('\n')}');
  });
}

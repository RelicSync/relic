// The pure-Dart Gemma tokenizer must produce exactly the ids the Python
// `tokenizers` library does, or a phone's query would land somewhere else in
// the vector space than the desktop's items. test/fixtures/
// gemma_tokenizer_cases.json holds sixty texts with the ids and attention
// mask recorded from tokenizers 0.22 (plain words, unicode, emoji, code, runs
// of spaces, tabs and newlines, added tokens typed by hand, an empty string,
// a 300-character word).
//
// The real tokenizer.json is 20 MB and is not in the repo. Point
// RELIC_MODELS_DIR at a directory holding
// embeddinggemma-300m.tokenizer.json (the desktop's model cache works:
// %LOCALAPPDATA%\relic-sift\models on Windows) and the exactness test runs;
// without it, it is skipped the way desk_sync_chip_test.dart skips without
// RELIC_DATA_DIR. The small synthetic cases below always run and cover the
// mechanics (added tokens, byte fallback, merge order, truncation).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/gemma_tokenizer.dart';

/// A toy tokenizer.json in the same shape as the real one.
String _toyJson() {
  final vocab = <String, int>{
    '<pad>': 0,
    '<eos>': 1,
    '<bos>': 2,
    '<unk>': 3,
    '[multimodal]': 5,
  };
  var next = 6;
  for (var b = 0; b < 256; b++) {
    vocab['<0x${b.toRadixString(16).toUpperCase().padLeft(2, '0')}>'] = next++;
  }
  for (final piece in [
    '▁', 'a', 'b', 'c', 'd', 'x',
    'ab', 'abc', '▁a', '▁ab', '▁abc', 'xx', 'xxx', 'xxxx',
    'bc', 'bcd', 'cd', '▁▁',
  ]) {
    vocab[piece] = next++;
  }
  final merges = <List<String>>[
    ['a', 'b'], // rank 0: ab
    ['ab', 'c'], // rank 1: abc
    ['▁', 'a'], // rank 2
    ['▁', 'ab'], // rank 3
    ['▁', 'abc'], // rank 4
    ['x', 'x'], // rank 5: xx
    ['xx', 'x'], // rank 6: xxx
    ['xx', 'xx'], // rank 7: xxxx
    ['b', 'c'], // rank 8: bc (loses to ab at rank 0)
    ['bc', 'd'], // rank 9
    ['c', 'd'], // rank 10
    ['▁', '▁'], // rank 11
  ];
  return jsonEncode({
    'version': '1.0',
    'added_tokens': [
      for (final e in {'<pad>': 0, '<eos>': 1, '<bos>': 2, '<unk>': 3}.entries)
        {
          'id': e.value,
          'content': e.key,
          'single_word': false,
          'lstrip': false,
          'rstrip': false,
          'normalized': false,
          'special': true,
        },
      {
        'id': 5,
        'content': '[multimodal]',
        'single_word': false,
        'lstrip': false,
        'rstrip': false,
        'normalized': false,
        'special': false,
      },
    ],
    'normalizer': {
      'type': 'Replace',
      'pattern': {'String': ' '},
      'content': '▁',
    },
    'pre_tokenizer': {
      'type': 'Split',
      'pattern': {'String': ' '},
      'behavior': 'MergedWithPrevious',
      'invert': false,
    },
    'post_processor': {
      'type': 'TemplateProcessing',
      'single': [
        {'SpecialToken': {'id': '<bos>', 'type_id': 0}},
        {'Sequence': {'id': 'A', 'type_id': 0}},
        {'SpecialToken': {'id': '<eos>', 'type_id': 0}},
      ],
      'special_tokens': {
        '<bos>': {'id': '<bos>', 'ids': [2], 'tokens': ['<bos>']},
        '<eos>': {'id': '<eos>', 'ids': [1], 'tokens': ['<eos>']},
      },
    },
    'decoder': {'type': 'ByteFallback'},
    'model': {
      'type': 'BPE',
      'dropout': null,
      'unk_token': '<unk>',
      'continuing_subword_prefix': null,
      'end_of_word_suffix': null,
      'fuse_unk': true,
      'byte_fallback': true,
      'ignore_merges': false,
      'vocab': vocab,
      'merges': merges,
    },
  });
}

void main() {
  group('toy tokenizer', () {
    final tok = GemmaTokenizer.fromJson(_toyJson());
    final json = jsonDecode(_toyJson()) as Map<String, dynamic>;
    final vocab = ((json['model'] as Map)['vocab'] as Map).cast<String, int>();
    int id(String piece) => vocab[piece]!;

    test('wraps in bos and eos', () {
      final e = tok.encode('a', maxTokens: 512);
      expect(e.ids, [2, id('a'), 1]);
      expect(e.mask, [1, 1, 1]);
    });

    test('merges by rank, not left to right', () {
      // "abcd": ab (rank 0) first, then abc (rank 1); d is left alone. A pass
      // that took bc (rank 8) would never see abc.
      expect(tok.encodeRaw('abcd'), [id('abc'), id('d')]);
    });

    test('spaces become the space mark and merge with the next word', () {
      expect(tok.encodeRaw(' abc'), [id('▁abc')]);
      expect(tok.encodeRaw('a abc'), [id('a'), id('▁abc')]);
    });

    test('runs of spaces are their own tokens, not a split', () {
      expect(tok.encodeRaw('a  b'), [id('a'), id('▁▁'), id('b')]);
    });

    test('same pair at several positions: leftmost first', () {
      // xxxxx: xx at 0, then xx at 2 (both rank 5). The queue then holds
      // (xx,x) at 2 (rank 6) and (xx,xx) at 0 (rank 7); the stale (xx,x) at 0
      // is skipped, xx+x at 2 wins, and (xx,xxx) is no merge. Python's
      // tokenizers gives the same [xx, xxx] for this toy file; a greedy pass
      // that merged every xx first would give [xxxx, x].
      expect(tok.encodeRaw('xxxxx'), [id('xx'), id('xxx')]);
    });

    test('byte fallback for characters outside the vocab', () {
      final bytes = utf8.encode('é');
      expect(tok.encodeRaw('é'),
          bytes.map((b) => id('<0x${b.toRadixString(16).toUpperCase()}>')));
    });

    test('added tokens are cut out of the raw text', () {
      expect(tok.encodeRaw('a<eos>b'), [id('a'), 1, id('b')]);
      expect(tok.encodeRaw('[multimodal]'), [5]);
      // After an added token the rest starts fresh, space included.
      expect(tok.encodeRaw('<bos> a'), [2, id('▁a')]);
    });

    test('truncation keeps the first ids and both specials', () {
      final e = tok.encode('a b c d', maxTokens: 4);
      expect(e.ids.length, 4);
      expect(e.ids.first, 2);
      expect(e.ids.last, 1);
      expect(e.ids.sublist(1, 3), tok.encodeRaw('a b c d').sublist(0, 2));
    });

    test('empty text is just the specials', () {
      expect(tok.encode('', maxTokens: 512).ids, [2, 1]);
    });
  });

  group('real tokenizer', () {
    final dir = Platform.environment['RELIC_MODELS_DIR'];
    final path = dir == null
        ? null
        : '$dir${Platform.pathSeparator}embeddinggemma-300m.tokenizer.json';

    test('matches Python tokenizers on every fixture case', () async {
      if (path == null || !File(path).existsSync()) {
        markTestSkipped('RELIC_MODELS_DIR not set or has no tokenizer.json');
        return;
      }
      final tok = await GemmaTokenizer.load(path);
      final cases = jsonDecode(
        File('test/fixtures/gemma_tokenizer_cases.json').readAsStringSync(),
      ) as List;
      expect(cases.length, 60);
      final failures = <String>[];
      for (final c in cases.cast<Map<String, dynamic>>()) {
        final text = c['text'] as String;
        final want = (c['ids'] as List).cast<int>();
        final mask = (c['mask'] as List).cast<int>();
        final got = tok.encode(text, maxTokens: 512);
        if (got.ids.join(',') != want.join(',') ||
            got.mask.join(',') != mask.join(',')) {
          failures.add('${jsonEncode(text)}\n  want $want\n  got  ${got.ids}');
        }
      }
      expect(failures, isEmpty,
          reason: '${failures.length} of ${cases.length} differ:\n'
              '${failures.join('\n')}');
    });

    test('truncates a long text to 512 ids with the specials on', () async {
      if (path == null || !File(path).existsSync()) {
        markTestSkipped('RELIC_MODELS_DIR not set or has no tokenizer.json');
        return;
      }
      final tok = await GemmaTokenizer.load(path);
      final e = tok.encode(List.filled(700, 'word').join(' '), maxTokens: 512);
      expect(e.ids.length, 512);
      expect(e.ids.first, tok.bosId);
      expect(e.ids.last, tok.eosId);
      expect(e.mask.every((m) => m == 1), isTrue);
    });
  });
}

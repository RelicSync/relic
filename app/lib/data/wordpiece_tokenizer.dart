/// A BERT WordPiece tokenizer in pure Dart, for the small distilled query
/// encoder that shares the desktop's vector space.
///
/// Reads a Hugging Face `tokenizer.json` with a `WordPiece` model, a
/// `BertNormalizer`, a `BertPreTokenizer` and a `[CLS] A [SEP]` template, and
/// follows the Python library's steps:
///
/// * added tokens (`[CLS]`, `[SEP]`, `[UNK]`...) are cut out of the raw text
///   first, leftmost and longest;
/// * the normaliser drops control characters, turns every kind of whitespace
///   into a space, pads CJK characters with spaces so each is its own word,
///   strips accents and lowercases (each as the file asks);
/// * the pre-tokeniser splits on whitespace and makes every punctuation
///   character its own word;
/// * WordPiece takes each word greedily, longest vocab piece first, later
///   pieces with the `##` prefix, and the whole word is `[UNK]` when any part
///   has no piece or the word is longer than `max_input_chars_per_word`.
///
/// Where Dart has no Unicode tables, this file carries small ones: accents
/// are stripped for the Latin-1 and Latin Extended-A letters (café, naïve,
/// résumé), punctuation is the ASCII set plus the general and CJK punctuation
/// blocks, and control and space characters follow the Unicode categories by
/// range. Text outside those (say a precomposed Vietnamese letter) may
/// tokenise differently from Python; a search query very rarely gets there.
/// `test/wordpiece_tokenizer_test.dart` checks a toy vocabulary against ids
/// from Python on the cases that matter.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'query_tokenizer.dart';

class WordPieceTokenizer implements QueryTokenizer {
  final Map<String, int> _vocab;
  final String _prefix;
  final int _maxWordChars;
  final int unkId;
  final int clsId;
  final int sepId;
  final bool _cleanText;
  final bool _handleCjk;
  final bool _stripAccents;
  final bool _lowercase;
  final List<String> _added; // longest first

  WordPieceTokenizer._(
    this._vocab,
    this._prefix,
    this._maxWordChars,
    this.unkId,
    this.clsId,
    this.sepId,
    this._cleanText,
    this._handleCjk,
    this._stripAccents,
    this._lowercase,
    this._added,
  );

  static Future<WordPieceTokenizer> load(String path) =>
      Isolate.run(() => fromJson(File(path).readAsStringSync()));

  static WordPieceTokenizer fromJson(String json) {
    final root = jsonDecode(json) as Map<String, dynamic>;
    final model = root['model'] as Map<String, dynamic>;
    if (model['type'] != 'WordPiece') {
      throw FormatException(
          'tokenizer model is ${model['type']}, not WordPiece');
    }
    final vocab = (model['vocab'] as Map<String, dynamic>).cast<String, int>();
    final addedList = (root['added_tokens'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    for (final t in addedList) {
      vocab[t['content'] as String] = t['id'] as int;
    }
    final added = addedList.map((t) => t['content'] as String).toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    var clsName = '[CLS]';
    var sepName = '[SEP]';
    final post = root['post_processor'] as Map<String, dynamic>?;
    if (post != null && post['type'] == 'TemplateProcessing') {
      final specials = (post['single'] as List)
          .map((e) => (e as Map<String, dynamic>)['SpecialToken'])
          .whereType<Map<String, dynamic>>()
          .map((e) => e['id'] as String)
          .toList();
      if (specials.length >= 2) {
        clsName = specials.first;
        sepName = specials.last;
      }
    }
    int special(String name) {
      final id = vocab[name];
      if (id == null) throw FormatException('tokenizer has no $name token');
      return id;
    }

    var cleanText = true;
    var handleCjk = true;
    var lowercase = true;
    bool? stripAccents;
    final norm = root['normalizer'] as Map<String, dynamic>?;
    if (norm != null && norm['type'] == 'BertNormalizer') {
      cleanText = norm['clean_text'] != false;
      handleCjk = norm['handle_chinese_chars'] != false;
      lowercase = norm['lowercase'] != false;
      stripAccents = norm['strip_accents'] as bool?;
    }
    final unkName = model['unk_token'] as String? ?? '[UNK]';
    return WordPieceTokenizer._(
      vocab,
      model['continuing_subword_prefix'] as String? ?? '##',
      model['max_input_chars_per_word'] as int? ?? 100,
      special(unkName),
      special(clsName),
      special(sepName),
      cleanText,
      handleCjk,
      // The library strips accents whenever it lowercases unless told not to.
      stripAccents ?? lowercase,
      lowercase,
      added,
    );
  }

  @override
  TokenEncoding encode(String text, {required int maxTokens}) {
    final body = encodeRaw(text);
    final keep = maxTokens - 2;
    final ids = <int>[clsId];
    if (keep > 0) {
      ids.addAll(keep < body.length ? body.sublist(0, keep) : body);
    }
    ids.add(sepId);
    return TokenEncoding(ids, List<int>.filled(ids.length, 1));
  }

  /// The ids with no specials and no length cap.
  List<int> encodeRaw(String text) {
    final out = <int>[];
    var i = 0;
    var pieceStart = 0;
    while (i < text.length) {
      String? hit;
      for (final a in _added) {
        if (text.startsWith(a, i)) {
          hit = a;
          break;
        }
      }
      if (hit == null) {
        i++;
        continue;
      }
      if (pieceStart < i) _encodePiece(text.substring(pieceStart, i), out);
      out.add(_vocab[hit]!);
      i += hit.length;
      pieceStart = i;
    }
    if (pieceStart < text.length) _encodePiece(text.substring(pieceStart), out);
    return out;
  }

  void _encodePiece(String piece, List<int> out) {
    for (final word in _preTokenize(_normalize(piece))) {
      _wordPiece(word, out);
    }
  }

  String _normalize(String s) {
    final b = StringBuffer();
    for (final cp in s.runes) {
      var c = cp;
      if (_cleanText) {
        if (c == 0 || c == 0xFFFD || _isControl(c)) continue;
        if (_isWhitespace(c)) c = 0x20;
      }
      if (_handleCjk && _isCjk(c)) {
        b
          ..write(' ')
          ..writeCharCode(c)
          ..write(' ');
        continue;
      }
      if (_stripAccents) {
        final base = _accentBase[c];
        if (base != null) c = base;
        if (_isCombiningMark(c)) continue;
      }
      b.writeCharCode(c);
    }
    var out = b.toString();
    if (_lowercase) out = out.toLowerCase();
    return out;
  }

  static List<String> _preTokenize(String s) {
    final words = <String>[];
    final cur = StringBuffer();
    void flush() {
      if (cur.isNotEmpty) {
        words.add(cur.toString());
        cur.clear();
      }
    }

    for (final c in s.runes) {
      if (_isWhitespace(c)) {
        flush();
      } else if (_isPunctuation(c)) {
        flush();
        words.add(String.fromCharCode(c));
      } else {
        cur.writeCharCode(c);
      }
    }
    flush();
    return words;
  }

  void _wordPiece(String word, List<int> out) {
    final chars = word.runes.toList();
    if (chars.length > _maxWordChars) {
      out.add(unkId);
      return;
    }
    final pieces = <int>[];
    var start = 0;
    while (start < chars.length) {
      var end = chars.length;
      int? found;
      while (start < end) {
        var sub = String.fromCharCodes(chars.sublist(start, end));
        if (start > 0) sub = '$_prefix$sub';
        final id = _vocab[sub];
        if (id != null) {
          found = id;
          break;
        }
        end--;
      }
      if (found == null) {
        out.add(unkId);
        return;
      }
      pieces.add(found);
      start = end;
    }
    out.addAll(pieces);
  }

  static bool _isWhitespace(int c) =>
      c == 0x20 ||
      c == 0x09 ||
      c == 0x0A ||
      c == 0x0D ||
      c == 0xA0 ||
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x200A) ||
      c == 0x202F ||
      c == 0x205F ||
      c == 0x3000;

  static bool _isControl(int c) {
    if (c == 0x09 || c == 0x0A || c == 0x0D) return false;
    return c < 0x20 ||
        (c >= 0x7F && c <= 0x9F) ||
        c == 0xAD ||
        (c >= 0x200B && c <= 0x200F) ||
        (c >= 0x202A && c <= 0x202E) ||
        (c >= 0x2060 && c <= 0x2064) ||
        c == 0xFEFF;
  }

  static bool _isCjk(int c) =>
      (c >= 0x4E00 && c <= 0x9FFF) ||
      (c >= 0x3400 && c <= 0x4DBF) ||
      (c >= 0x20000 && c <= 0x2A6DF) ||
      (c >= 0x2A700 && c <= 0x2B73F) ||
      (c >= 0x2B740 && c <= 0x2B81F) ||
      (c >= 0x2B920 && c <= 0x2CEAF) ||
      (c >= 0xF900 && c <= 0xFAFF) ||
      (c >= 0x2F800 && c <= 0x2FA1F);

  static bool _isCombiningMark(int c) =>
      (c >= 0x0300 && c <= 0x036F) ||
      (c >= 0x1AB0 && c <= 0x1AFF) ||
      (c >= 0x1DC0 && c <= 0x1DFF) ||
      (c >= 0x20D0 && c <= 0x20FF) ||
      (c >= 0xFE20 && c <= 0xFE2F);

  static bool _isPunctuation(int c) =>
      (c >= 33 && c <= 47) ||
      (c >= 58 && c <= 64) ||
      (c >= 91 && c <= 96) ||
      (c >= 123 && c <= 126) ||
      c == 0xA1 ||
      c == 0xA7 ||
      c == 0xAB ||
      c == 0xB6 ||
      c == 0xB7 ||
      c == 0xBB ||
      c == 0xBF ||
      (c >= 0x2010 && c <= 0x2027) ||
      (c >= 0x2030 && c <= 0x205E) ||
      (c >= 0x3001 && c <= 0x3003) ||
      (c >= 0x3008 && c <= 0x3011) ||
      (c >= 0x3014 && c <= 0x301F) ||
      (c >= 0xFF01 && c <= 0xFF0F) ||
      (c >= 0xFF1A && c <= 0xFF20) ||
      (c >= 0xFF3B && c <= 0xFF40) ||
      (c >= 0xFF5B && c <= 0xFF65);
}

/// Precomposed Latin letters to their base letter, Latin-1 Supplement and
/// Latin Extended-A. What NFD plus dropping combining marks gives for these.
const Map<int, int> _accentBase = {
  0xC0: 0x41, 0xC1: 0x41, 0xC2: 0x41, 0xC3: 0x41, 0xC4: 0x41, 0xC5: 0x41,
  0xC7: 0x43, 0xC8: 0x45, 0xC9: 0x45, 0xCA: 0x45, 0xCB: 0x45, 0xCC: 0x49,
  0xCD: 0x49, 0xCE: 0x49, 0xCF: 0x49, 0xD1: 0x4E, 0xD2: 0x4F, 0xD3: 0x4F,
  0xD4: 0x4F, 0xD5: 0x4F, 0xD6: 0x4F, 0xD9: 0x55, 0xDA: 0x55, 0xDB: 0x55,
  0xDC: 0x55, 0xDD: 0x59, 0xE0: 0x61, 0xE1: 0x61, 0xE2: 0x61, 0xE3: 0x61,
  0xE4: 0x61, 0xE5: 0x61, 0xE7: 0x63, 0xE8: 0x65, 0xE9: 0x65, 0xEA: 0x65,
  0xEB: 0x65, 0xEC: 0x69, 0xED: 0x69, 0xEE: 0x69, 0xEF: 0x69, 0xF1: 0x6E,
  0xF2: 0x6F, 0xF3: 0x6F, 0xF4: 0x6F, 0xF5: 0x6F, 0xF6: 0x6F, 0xF9: 0x75,
  0xFA: 0x75, 0xFB: 0x75, 0xFC: 0x75, 0xFD: 0x79, 0xFF: 0x79,
  0x100: 0x41, 0x101: 0x61, 0x102: 0x41, 0x103: 0x61, 0x104: 0x41,
  0x105: 0x61, 0x106: 0x43, 0x107: 0x63, 0x108: 0x43, 0x109: 0x63,
  0x10A: 0x43, 0x10B: 0x63, 0x10C: 0x43, 0x10D: 0x63, 0x10E: 0x44,
  0x10F: 0x64, 0x112: 0x45, 0x113: 0x65, 0x114: 0x45, 0x115: 0x65,
  0x116: 0x45, 0x117: 0x65, 0x118: 0x45, 0x119: 0x65, 0x11A: 0x45,
  0x11B: 0x65, 0x11C: 0x47, 0x11D: 0x67, 0x11E: 0x47, 0x11F: 0x67,
  0x120: 0x47, 0x121: 0x67, 0x122: 0x47, 0x123: 0x67, 0x124: 0x48,
  0x125: 0x68, 0x128: 0x49, 0x129: 0x69, 0x12A: 0x49, 0x12B: 0x69,
  0x12C: 0x49, 0x12D: 0x69, 0x12E: 0x49, 0x12F: 0x69, 0x130: 0x49,
  0x134: 0x4A, 0x135: 0x6A, 0x136: 0x4B, 0x137: 0x6B, 0x139: 0x4C,
  0x13A: 0x6C, 0x13B: 0x4C, 0x13C: 0x6C, 0x13D: 0x4C, 0x13E: 0x6C,
  0x143: 0x4E, 0x144: 0x6E, 0x145: 0x4E, 0x146: 0x6E, 0x147: 0x4E,
  0x148: 0x6E, 0x14C: 0x4F, 0x14D: 0x6F, 0x14E: 0x4F, 0x14F: 0x6F,
  0x150: 0x4F, 0x151: 0x6F, 0x154: 0x52, 0x155: 0x72, 0x156: 0x52,
  0x157: 0x72, 0x158: 0x52, 0x159: 0x72, 0x15A: 0x53, 0x15B: 0x73,
  0x15C: 0x53, 0x15D: 0x73, 0x15E: 0x53, 0x15F: 0x73, 0x160: 0x53,
  0x161: 0x73, 0x162: 0x54, 0x163: 0x74, 0x164: 0x54, 0x165: 0x74,
  0x168: 0x55, 0x169: 0x75, 0x16A: 0x55, 0x16B: 0x75, 0x16C: 0x55,
  0x16D: 0x75, 0x16E: 0x55, 0x16F: 0x75, 0x170: 0x55, 0x171: 0x75,
  0x172: 0x55, 0x173: 0x75, 0x174: 0x57, 0x175: 0x77, 0x176: 0x59,
  0x177: 0x79, 0x178: 0x59, 0x179: 0x5A, 0x17A: 0x7A, 0x17B: 0x5A,
  0x17C: 0x7A, 0x17D: 0x5A, 0x17E: 0x7A,
};

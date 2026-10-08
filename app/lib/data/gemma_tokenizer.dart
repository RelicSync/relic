/// The EmbeddingGemma tokenizer in pure Dart.
///
/// Reads the model's `tokenizer.json` (the Hugging Face `tokenizers` format)
/// and turns text into the same ids the Python library produces, so a query
/// embedded on a phone lands in the same place as the desktop's vectors.
/// The desktop uses the Rust `tokenizers` crate; this follows its algorithm
/// step for step, and `test/gemma_tokenizer_test.dart` checks it against ids
/// recorded from Python on sixty texts.
///
/// What the file says the pipeline is, and what this does about each part:
///
/// * `added_tokens`: 6415 strings (`<bos>`, `<eos>`, `<pad>`, `<unk>`,
///   `[multimodal]`, `<unusedN>`...) that are cut out of the raw text first,
///   before any normalising, and become one id each. Matching is leftmost,
///   then longest, like the Aho-Corasick automaton the library builds. None
///   of them is flagged `normalized`, `lstrip`, `rstrip` or `single_word`, so
///   that is the whole rule.
/// * `normalizer`: Replace every space with `▁` (U+2581).
/// * `pre_tokenizer`: Split on a space. The normaliser has already turned
///   every space into `▁`, so this never matches and each stretch of text
///   between added tokens reaches the model as one word. (The fixture case
///   `a  b   c` proves it: the runs of `▁` come out as their own tokens, which
///   a split would not allow.)
/// * `model`: BPE with 262144 vocab entries and 514906 merges, byte fallback
///   on, unk fusing on. Each word starts as one symbol per character. A
///   character with no vocab entry becomes its UTF-8 bytes as `<0xNN>` tokens.
///   Merges then apply lowest rank first, leftmost first among equals, through
///   a priority queue over a linked list, which is exactly the library's
///   `Word::merge_all`. The order matters: a greedy pass that merges every
///   occurrence of one pair before looking again can give different ids.
/// * `post_processor`: `<bos> A <eos>`. Truncation keeps the first
///   `maxTokens - 2` ids so the specials always fit.
///
/// Loading parses twenty megabytes of JSON. [load] does that on a worker
/// isolate and keeps only what encoding needs: single-character vocab ids,
/// the merge table as two sorted typed arrays (about 8 MB), the byte tokens
/// and a trie of the added tokens.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'query_tokenizer.dart';

class GemmaTokenizer implements QueryTokenizer {
  /// The longest text that is tokenised; anything past it is dropped before
  /// encoding. The desktop cuts at the same length (relic-sift `MAX_CHARS`).
  static const int maxChars = 8000;

  final Map<int, int> _charIds; // code point -> id, single-character entries
  final Int64List _mergeKeys; // sorted pair keys (left * _idSpan + right)
  final Int64List _mergeVals; // rank * _idSpan + merged id, same order
  final int _idSpan;
  final Int32List _byteIds; // <0x00>..<0xFF>, or -1 when the vocab lacks one
  final _TrieNode _added;
  final int bosId;
  final int eosId;
  final int unkId; // -1 when the model names no unk token
  final bool _fuseUnk;
  final String _spaceReplacement;

  GemmaTokenizer._(
    this._charIds,
    this._mergeKeys,
    this._mergeVals,
    this._idSpan,
    this._byteIds,
    this._added,
    this.bosId,
    this.eosId,
    this.unkId,
    this._fuseUnk,
    this._spaceReplacement,
  );

  /// Parse a `tokenizer.json` file on a worker isolate.
  static Future<GemmaTokenizer> load(String path) =>
      Isolate.run(() => fromJson(File(path).readAsStringSync()));

  /// Parse the contents of a `tokenizer.json`. Synchronous and slow for the
  /// real file; tests with small hand-made files call it directly.
  static GemmaTokenizer fromJson(String json) {
    final root = jsonDecode(json) as Map<String, dynamic>;
    final model = root['model'] as Map<String, dynamic>;
    if (model['type'] != 'BPE') {
      throw FormatException('tokenizer model is ${model['type']}, not BPE');
    }
    final vocab = (model['vocab'] as Map<String, dynamic>).cast<String, int>();
    var maxId = -1;
    for (final id in vocab.values) {
      if (id > maxId) maxId = id;
    }
    for (final t in (root['added_tokens'] as List? ?? const [])) {
      final id = (t as Map<String, dynamic>)['id'] as int;
      if (id > maxId) maxId = id;
    }
    final idSpan = maxId + 1;

    final charIds = <int, int>{};
    vocab.forEach((piece, id) {
      final runes = piece.runes;
      if (runes.length == 1) charIds[runes.first] = id;
    });

    final byteIds = Int32List(256);
    for (var b = 0; b < 256; b++) {
      final hex = b.toRadixString(16).toUpperCase().padLeft(2, '0');
      byteIds[b] = vocab['<0x$hex>'] ?? -1;
    }

    // Merges: either ["a", "b"] pairs (current files) or "a b" strings.
    final merges = model['merges'] as List;
    final keys = Int64List(merges.length);
    final vals = Int64List(merges.length);
    var n = 0;
    for (var rank = 0; rank < merges.length; rank++) {
      final m = merges[rank];
      String left;
      String right;
      if (m is List) {
        left = m[0] as String;
        right = m[1] as String;
      } else {
        final s = m as String;
        final sp = s.indexOf(' ');
        if (sp < 0) continue;
        left = s.substring(0, sp);
        right = s.substring(sp + 1);
      }
      final a = vocab[left];
      final b = vocab[right];
      final c = vocab[left + right];
      if (a == null || b == null || c == null) continue;
      keys[n] = a * idSpan + b;
      vals[n] = rank * idSpan + c;
      n++;
    }
    final order = List<int>.generate(n, (i) => i)
      ..sort((x, y) => keys[x].compareTo(keys[y]));
    final sortedKeys = Int64List(n);
    final sortedVals = Int64List(n);
    for (var i = 0; i < n; i++) {
      sortedKeys[i] = keys[order[i]];
      sortedVals[i] = vals[order[i]];
    }

    final added = _TrieNode();
    for (final t in (root['added_tokens'] as List? ?? const [])) {
      final m = t as Map<String, dynamic>;
      added.insert(m['content'] as String, m['id'] as int);
    }

    final unkName = model['unk_token'] as String?;
    final unkId = unkName == null ? -1 : (vocab[unkName] ?? -1);

    // The post-processor names the two specials; fall back to the usual
    // Gemma names when a file leaves it out.
    var bosName = '<bos>';
    var eosName = '<eos>';
    final post = root['post_processor'] as Map<String, dynamic>?;
    if (post != null && post['type'] == 'TemplateProcessing') {
      final single = post['single'] as List;
      final specials = single
          .map((e) => (e as Map<String, dynamic>)['SpecialToken'])
          .whereType<Map<String, dynamic>>()
          .map((e) => e['id'] as String)
          .toList();
      if (specials.length >= 2) {
        bosName = specials.first;
        eosName = specials.last;
      }
    }
    int special(String name) {
      final id = vocab[name] ?? _addedId(root, name);
      if (id == null) throw FormatException('tokenizer has no $name token');
      return id;
    }

    var spaceReplacement = '▁';
    final norm = root['normalizer'] as Map<String, dynamic>?;
    if (norm != null && norm['type'] == 'Replace') {
      final pattern = norm['pattern'] as Map<String, dynamic>;
      if (pattern['String'] == ' ') {
        spaceReplacement = norm['content'] as String;
      }
    }

    return GemmaTokenizer._(
      charIds,
      sortedKeys,
      sortedVals,
      idSpan,
      byteIds,
      added,
      special(bosName),
      special(eosName),
      unkId,
      model['fuse_unk'] == true,
      spaceReplacement,
    );
  }

  static int? _addedId(Map<String, dynamic> root, String name) {
    for (final t in (root['added_tokens'] as List? ?? const [])) {
      final m = t as Map<String, dynamic>;
      if (m['content'] == name) return m['id'] as int;
    }
    return null;
  }

  @override
  TokenEncoding encode(String text, {required int maxTokens}) {
    if (text.length > maxChars) {
      var cut = maxChars;
      // Never split a surrogate pair.
      final cu = text.codeUnitAt(cut - 1);
      if (cu >= 0xD800 && cu <= 0xDBFF) cut--;
      text = text.substring(0, cut);
    }
    final body = encodeRaw(text);
    final keep = maxTokens - 2;
    final ids = <int>[bosId];
    if (keep > 0) {
      ids.addAll(keep < body.length ? body.sublist(0, keep) : body);
    }
    ids.add(eosId);
    return TokenEncoding(ids, List<int>.filled(ids.length, 1));
  }

  /// The ids for [text] with no specials and no length cap. What the Python
  /// library returns with `add_special_tokens=False`.
  List<int> encodeRaw(String text) {
    final out = <int>[];
    var i = 0;
    var pieceStart = 0;
    while (i < text.length) {
      final hit = _added.longestMatch(text, i);
      if (hit == null) {
        i++;
        continue;
      }
      if (pieceStart < i) _bpe(_normalize(text.substring(pieceStart, i)), out);
      out.add(hit.id);
      i += hit.length;
      pieceStart = i;
    }
    if (pieceStart < text.length) {
      _bpe(_normalize(text.substring(pieceStart)), out);
    }
    return out;
  }

  String _normalize(String s) => s.replaceAll(' ', _spaceReplacement);

  int _mergeIndex(int key) {
    var lo = 0;
    var hi = _mergeKeys.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final k = _mergeKeys[mid];
      if (k < key) {
        lo = mid + 1;
      } else if (k > key) {
        hi = mid - 1;
      } else {
        return mid;
      }
    }
    return -1;
  }

  /// BPE over one word, appended to [out]. Mirrors `BPE::merge_word` and
  /// `Word::merge_all` from the `tokenizers` crate.
  void _bpe(String word, List<int> out) {
    if (word.isEmpty) return;
    // One symbol per character, with byte fallback and unk fusing.
    final ids = <int>[];
    var pendingUnk = false;
    for (final rune in word.runes) {
      final id = _charIds[rune];
      if (id != null) {
        ids.add(id);
        pendingUnk = false;
        continue;
      }
      final bytes = utf8.encode(String.fromCharCode(rune));
      var allBytes = true;
      for (final b in bytes) {
        if (_byteIds[b] < 0) {
          allBytes = false;
          break;
        }
      }
      if (allBytes) {
        for (final b in bytes) {
          ids.add(_byteIds[b]);
        }
        pendingUnk = false;
        continue;
      }
      if (unkId < 0) continue;
      if (pendingUnk && _fuseUnk) continue;
      ids.add(unkId);
      pendingUnk = true;
    }

    final n = ids.length;
    if (n < 2) {
      out.addAll(ids);
      return;
    }
    final prev = Int32List(n);
    final next = Int32List(n);
    final alive = List<bool>.filled(n, true);
    for (var i = 0; i < n; i++) {
      prev[i] = i - 1;
      next[i] = i + 1 < n ? i + 1 : -1;
    }

    // Queue entries pack rank, position and merged id into one int so the
    // heap orders by rank, then by position, with no allocation per entry.
    final heap = _IntHeap();
    void offer(int pos, int left, int right) {
      final at = _mergeIndex(left * _idSpan + right);
      if (at < 0) return;
      final v = _mergeVals[at];
      final rank = v ~/ _idSpan;
      final newId = v % _idSpan;
      heap.push((rank << 40) | (pos << 20) | newId);
    }

    for (var i = 0; i + 1 < n; i++) {
      offer(i, ids[i], ids[i + 1]);
    }
    while (heap.isNotEmpty) {
      final top = heap.pop();
      final pos = (top >> 20) & 0xFFFFF;
      final newId = top & 0xFFFFF;
      if (!alive[pos]) continue;
      final np = next[pos];
      if (np < 0) continue;
      // Skip an entry that a merge next door has made stale.
      final at = _mergeIndex(ids[pos] * _idSpan + ids[np]);
      if (at < 0) continue;
      final v = _mergeVals[at];
      if (v % _idSpan != newId) continue;

      ids[pos] = newId;
      alive[np] = false;
      final nn = next[np];
      next[pos] = nn;
      if (nn >= 0) prev[nn] = pos;
      final p = prev[pos];
      if (p >= 0) offer(p, ids[p], ids[pos]);
      if (nn >= 0) offer(pos, ids[pos], ids[nn]);
    }
    for (var i = 0; i >= 0; i = next[i]) {
      out.add(ids[i]);
    }
  }
}

class _Match {
  final int id;
  final int length;
  const _Match(this.id, this.length);
}

/// A trie over UTF-16 code units for the added tokens.
class _TrieNode {
  final Map<int, _TrieNode> children = {};
  int id = -1;

  void insert(String s, int tokenId) {
    var node = this;
    for (var i = 0; i < s.length; i++) {
      node = node.children.putIfAbsent(s.codeUnitAt(i), _TrieNode.new);
    }
    node.id = tokenId;
  }

  /// The longest added token starting exactly at [start], or null.
  _Match? longestMatch(String text, int start) {
    var node = this;
    _Match? best;
    for (var i = start; i < text.length; i++) {
      final nxt = node.children[text.codeUnitAt(i)];
      if (nxt == null) break;
      node = nxt;
      if (node.id >= 0) best = _Match(node.id, i - start + 1);
    }
    return best;
  }
}

/// A binary min-heap of ints.
class _IntHeap {
  final List<int> _a = [];

  bool get isNotEmpty => _a.isNotEmpty;

  void push(int v) {
    _a.add(v);
    var i = _a.length - 1;
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_a[parent] <= _a[i]) break;
      final t = _a[parent];
      _a[parent] = _a[i];
      _a[i] = t;
      i = parent;
    }
  }

  int pop() {
    final top = _a[0];
    final last = _a.removeLast();
    if (_a.isNotEmpty) {
      _a[0] = last;
      var i = 0;
      final n = _a.length;
      while (true) {
        final l = 2 * i + 1;
        final r = l + 1;
        var m = i;
        if (l < n && _a[l] < _a[m]) m = l;
        if (r < n && _a[r] < _a[m]) m = r;
        if (m == i) break;
        final t = _a[m];
        _a[m] = _a[i];
        _a[i] = t;
        i = m;
      }
    }
    return top;
  }
}

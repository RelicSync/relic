/// What an [OnnxQueryEncoder] needs from a tokenizer: text in, token ids and
/// an attention mask out, already cut to the model's length and already
/// wearing the model's start and end tokens.
///
/// Two tokenizers implement it. [GemmaTokenizer] is the desktop model's
/// SentencePiece-style BPE, and a WordPiece one serves the small distilled
/// encoder that shares the same vector space. The encoder never looks inside
/// the ids; it hands them to ONNX Runtime as int64 tensors.
library;

/// One encoded text. [ids] and [mask] have the same length; the mask is all
/// ones because nothing here pads (every query runs as a batch of one).
class TokenEncoding {
  final List<int> ids;
  final List<int> mask;
  const TokenEncoding(this.ids, this.mask);

  int get length => ids.length;
}

abstract class QueryTokenizer {
  /// Encode [text] to at most [maxTokens] ids, special tokens included.
  TokenEncoding encode(String text, {required int maxTokens});
}

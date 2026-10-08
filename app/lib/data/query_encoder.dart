import 'dart:typed_data';

/// Turns a search query into a unit-length vector in one embedding space.
///
/// The phone has no model of its own for the items: those vectors arrive from
/// the desktop inside AI records ([AiVectors]), tagged with the model version
/// that made them. The query side is what this is for, and it is pluggable
/// on purpose. The first encoder is the desktop's own EmbeddingGemma ft2 run
/// through ONNX Runtime on the phone (an opt-in download); the second is a
/// small distilled encoder trained into the same space. Both report the
/// [space] their output lives in, and the repo compares only against stored
/// vectors from that space.
abstract class QueryEncoder {
  /// The model version string of the space this encoder's vectors live in,
  /// in the desktop's words (`embeddinggemma-300m-ft2@int8-mrl256`). Stored
  /// vectors whose model string differs are never compared against it.
  String get space;

  /// A short name for this encoder itself, for the About page and logs
  /// (`ft2-onnx`, `q25`). Two encoders can share a [space].
  String get name;

  /// Whether the encoder can answer now: its files are present and it has
  /// loaded, or can load without a download. Cheap to call on every search.
  bool get ready;

  /// The unit-length vector for [query], or null when the encoder cannot
  /// answer (not ready, model failed to load, text empty). Never throws:
  /// a search must fall back to the lexical legs, not fail.
  Future<Float32List?> embed(String query);

  /// Let go of the loaded model. The repo calls this after an idle spell so a
  /// 300M-parameter model does not sit in a phone's memory between searches.
  Future<void> unload();
}

/// The semantic floor per space: a stored vector scoring under it is not a
/// match at all. Copied from the desktop's `_semFloor` table; a new space
/// needs its own entry, measured on the search benchmark, before it ships.
const Map<String, double> semanticFloorBySpace = {
  'embeddinggemma-300m@int8-mrl256': 0.38,
  'embeddinggemma-300m-ft2@int8-mrl256': 0.22,
};

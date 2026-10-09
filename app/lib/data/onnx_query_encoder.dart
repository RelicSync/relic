/// A [QueryEncoder] that runs an ONNX model on the phone.
///
/// The model and everything that differs between models lives in an
/// [OnnxEncoderSpec]: which files, which tokenizer, the prompt wrapped round
/// the query, the length cap, the output tensor to read and whether to cut it
/// to 256 dims and normalise. The desktop's EmbeddingGemma ft2 is
/// [OnnxEncoderSpec.ft2]. A distilled student that outputs a finished
/// 256-dim unit vector with no prompt is the same class with another spec.
///
/// Rules from the interface: never throws (null on any failure, with a line
/// in the debug log), lazy (the session opens on the first [embed]), and
/// [unload] lets the model go so it does not sit in memory between searches.
/// The tokenizer stays loaded after the first use: it is a few megabytes and
/// takes a second to parse, the session is the three hundred.
///
/// ONNX Runtime comes from flutter_onnxruntime, which has no platform code
/// under `flutter test`. [QueryModelSession] is the thin seam the encoder
/// needs from it, so a host test can stand in a fake and a device test can
/// run the real thing (integration_test/semantic_query_parity_test.dart).
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'gemma_tokenizer.dart';
import 'model_download.dart'
    show semanticGraphFile, semanticTokenizerFile, semanticWeightsFile, studentGraphFile, studentTokenizerFile;
import 'query_encoder.dart';
import 'query_tokenizer.dart';
import 'wordpiece_tokenizer.dart';

/// The output of one model run: the values of one output tensor, flat, with
/// its shape.
typedef ModelOutput = ({Float32List values, List<int> shape});

/// What the encoder needs from a loaded model.
abstract class QueryModelSession {
  /// Run the model on one sequence of [ids] with [mask], both int64
  /// [1, len], and return the output tensor named [outputName].
  Future<ModelOutput> run(String outputName, List<int> ids, List<int> mask);

  Future<void> close();
}

typedef SessionOpener = Future<QueryModelSession> Function(String graphPath);

class OnnxEncoderSpec {
  /// The vector space, in the desktop's words. See [QueryEncoder.space].
  final String space;

  /// A short name for this encoder. See [QueryEncoder.name].
  final String name;

  /// Where the files are.
  final String modelDir;

  /// The ONNX graph, relative to [modelDir]. Weights the graph refers to by
  /// name must sit beside it under that name.
  final String graphFile;

  /// Every file that must exist for [QueryEncoder.ready] to be true.
  final List<String> requiredFiles;

  /// Loads the tokenizer from [modelDir].
  final Future<QueryTokenizer> Function(String modelDir) loadTokenizer;

  /// Wrapped round the query before tokenising, with `<text>` standing for
  /// the query. Null sends the raw query.
  final String? promptTemplate;

  /// The longest sequence the model takes, specials included.
  final int maxTokens;

  /// The output tensor to read, shaped [batch, dims].
  final String outputName;

  /// Keep only the first [dims] values of the output and normalise them to
  /// unit length. True for a model that emits a wider raw embedding (Gemma's
  /// 768 with Matryoshka truncation to 256); false for one whose output is
  /// already the finished vector.
  final bool truncateAndNormalise;

  /// Width of the finished vector.
  final int dims;

  const OnnxEncoderSpec({
    required this.space,
    required this.name,
    required this.modelDir,
    required this.graphFile,
    required this.requiredFiles,
    required this.loadTokenizer,
    required this.promptTemplate,
    required this.maxTokens,
    required this.outputName,
    required this.truncateAndNormalise,
    this.dims = 256,
  });

  /// The desktop's EmbeddingGemma ft2, int8, with its query prompt and
  /// Matryoshka cut to 256. The ids match relic-sift's encoder.rs.
  static OnnxEncoderSpec ft2(String modelDir) => OnnxEncoderSpec(
        space: 'embeddinggemma-300m-ft2@int8-mrl256',
        name: 'ft2-onnx',
        modelDir: modelDir,
        graphFile: semanticGraphFile,
        requiredFiles: const [
          semanticGraphFile,
          semanticWeightsFile,
          semanticTokenizerFile,
        ],
        loadTokenizer: (dir) => GemmaTokenizer.load(
            '$dir${Platform.pathSeparator}$semanticTokenizerFile'),
        promptTemplate: 'task: search result | query: <text>',
        maxTokens: 512,
        outputName: 'sentence_embedding',
        truncateAndNormalise: true,
      );

  /// A distilled student in the same space: a BERT WordPiece tokenizer
  /// (uncased, `[CLS] A [SEP]`), the raw query with no prompt, at most 64
  /// tokens, and one output `query_embedding` [batch, 256] that is already
  /// unit length. File names and the model version come with the model.
  static OnnxEncoderSpec wordPieceStudent({
    required String modelDir,
    required String graphFile,
    required String tokenizerFile,
    required String space,
    required String name,
    List<String> extraFiles = const [],
  }) =>
      OnnxEncoderSpec(
        space: space,
        name: name,
        modelDir: modelDir,
        graphFile: graphFile,
        requiredFiles: [graphFile, tokenizerFile, ...extraFiles],
        loadTokenizer: (dir) => WordPieceTokenizer.load(
            '$dir${Platform.pathSeparator}$tokenizerFile'),
        promptTemplate: null,
        maxTokens: 64,
        outputName: 'query_embedding',
        truncateAndNormalise: false,
      );

  /// The shipped student: all-MiniLM-L6-v2 distilled into the ft2 space
  /// (round 2). Uncased WordPiece from its own tokenizer.json, raw query, 64
  /// tokens, `query_embedding` [batch, 256] already unit length. Its floor is
  /// its own entry in the repo's per-encoder table (0.23, matched to ft2's
  /// 0.22 on the search benchmark).
  static OnnxEncoderSpec studentMiniLm(String modelDir) => wordPieceStudent(
        modelDir: modelDir,
        graphFile: studentGraphFile,
        tokenizerFile: studentTokenizerFile,
        space: 'embeddinggemma-300m-ft2@int8-mrl256',
        name: studentEncoderName,
      );

  String get graphPath => '$modelDir${Platform.pathSeparator}$graphFile';
}

/// The student's encoder name, which keys its floor in the repo.
const String studentEncoderName = 'q-minilm-l6-d2';

class OnnxQueryEncoder implements QueryEncoder {
  final OnnxEncoderSpec spec;
  final SessionOpener _open;

  QueryTokenizer? _tokenizer;
  QueryModelSession? _session;
  bool? _filesPresent;

  /// Work on the session happens one call at a time, so an [unload] never
  /// closes a session under a running [embed].
  Future<void> _turn = Future.value();

  OnnxQueryEncoder(this.spec, {SessionOpener? openSession})
      : _open = openSession ?? _openOrtSession;

  @override
  String get space => spec.space;

  @override
  String get name => spec.name;

  @override
  bool get ready => _filesPresent ??= spec.requiredFiles.every((f) =>
      File('${spec.modelDir}${Platform.pathSeparator}$f').existsSync());

  /// Forget the cached answer to [ready]; call after files land or go.
  void recheckFiles() => _filesPresent = null;

  @override
  Future<Float32List?> embed(String query) {
    final text = query.trim();
    if (text.isEmpty || !ready) return Future.value(null);
    return _serial(() => _embed(text));
  }

  @override
  Future<void> unload() => _serial(() async {
        final s = _session;
        _session = null;
        if (s != null) {
          try {
            await s.close();
          } catch (e) {
            debugPrint('${spec.name}: close: $e');
          }
        }
      });

  Future<T> _serial<T>(Future<T> Function() work) {
    final done = _turn.then((_) => work());
    _turn = done.then((_) {}, onError: (_) {});
    return done;
  }

  Future<Float32List?> _embed(String text) async {
    try {
      final tok = _tokenizer ??= await spec.loadTokenizer(spec.modelDir);
      final session = _session ??= await _open(spec.graphPath);
      final prompt = spec.promptTemplate;
      final input =
          prompt == null ? text : prompt.replaceFirst('<text>', text);
      final enc = tok.encode(input, maxTokens: spec.maxTokens);
      final out = await session.run(spec.outputName, enc.ids, enc.mask);
      final width = out.shape.length >= 2 ? out.shape.last : out.values.length;
      if (width <= 0 || out.values.length < width) {
        debugPrint('${spec.name}: unexpected output shape ${out.shape}');
        return null;
      }
      final n = spec.truncateAndNormalise ? math.min(spec.dims, width) : width;
      final v = Float32List(n);
      for (var i = 0; i < n; i++) {
        v[i] = out.values[i];
      }
      if (spec.truncateAndNormalise) _normalise(v);
      return v;
    } catch (e, st) {
      debugPrint('${spec.name}: embed failed: $e\n$st');
      // Whatever broke, do not keep a half-made session around; the next
      // call starts clean, and a missing file reads as not ready again.
      final s = _session;
      _session = null;
      _filesPresent = null;
      if (s != null) {
        try {
          await s.close();
        } catch (_) {}
      }
      return null;
    }
  }

  static void _normalise(Float32List v) {
    var sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    if (sum <= 0) return;
    final inv = 1 / math.sqrt(sum);
    for (var i = 0; i < v.length; i++) {
      v[i] *= inv;
    }
  }
}

Future<QueryModelSession> _openOrtSession(String graphPath) async =>
    _OrtQueryModelSession(await OnnxRuntime().createSession(graphPath));

/// The real thing, over flutter_onnxruntime.
class _OrtQueryModelSession implements QueryModelSession {
  final OrtSession _session;
  _OrtQueryModelSession(this._session);

  @override
  Future<ModelOutput> run(
      String outputName, List<int> ids, List<int> mask) async {
    final shape = [1, ids.length];
    final idsT = await OrtValue.fromList(Int64List.fromList(ids), shape);
    OrtValue? maskT;
    Map<String, OrtValue>? outputs;
    try {
      maskT = await OrtValue.fromList(Int64List.fromList(mask), shape);
      outputs = await _session.run({'input_ids': idsT, 'attention_mask': maskT});
      final out = outputs[outputName];
      if (out == null) {
        throw StateError('model has no output $outputName '
            '(has ${outputs.keys.join(', ')})');
      }
      final flat = await out.asFlattenedList();
      final values = Float32List(flat.length);
      for (var i = 0; i < flat.length; i++) {
        values[i] = (flat[i] as num).toDouble();
      }
      return (values: values, shape: List<int>.from(out.shape));
    } finally {
      await idsT.dispose();
      await maskT?.dispose();
      if (outputs != null) {
        for (final v in outputs.values) {
          await v.dispose();
        }
      }
    }
  }

  @override
  Future<void> close() => _session.close();
}

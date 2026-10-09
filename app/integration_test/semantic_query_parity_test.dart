import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:relic_app/data/gemma_tokenizer.dart';
import 'package:relic_app/data/model_download.dart';
import 'package:relic_app/data/onnx_query_encoder.dart';

import 'query_refs_data.dart';

/// Does the phone's query encoder land where the desktop's does?
///
/// `test/fixtures/query_refs.json` holds four query vectors from the desktop
/// model (Python onnxruntime, the same prompt and pooling); `query_refs_data.dart`
/// is those numbers as Dart constants, since a test running inside the app
/// cannot read the fixture file. This runs the real ONNX Runtime through
/// flutter_onnxruntime, which has no platform code under `flutter test`, so
/// it is a device test only.
///
/// Run it on a connected phone:
///
///     flutter test integration_test/semantic_query_parity_test.dart -d <device-id>
///
/// With nothing else given it downloads the 330 MB bundle into the app's own
/// support directory through [ModelDownloadManager] (the Wi-Fi gate is bypassed
/// here on purpose: you asked for it), which takes a few minutes the first time
/// and is reused after. To use files already on the phone, pass a directory
/// the app can read:
///
///     --dart-define=RELIC_MODELS_DIR=/data/user/0/relic.space.app/files/models
///
/// The int8 graph on a phone's ARM kernels will not reproduce the desktop's
/// floats bit for bit; the bar is cosine 0.99 or better against each
/// reference, which is far inside the 0.22 floor the space uses.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ft2 query vectors match the desktop references', (tester) async {
    const given = String.fromEnvironment('RELIC_MODELS_DIR');
    final dir = given.isNotEmpty
        ? Directory(given)
        : Directory(
            '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}models');
    if (!semanticModelFt2.isComplete(dir)) {
      final m = ModelDownloadManager(
        dir: dir,
        bundle: semanticModelFt2,
        isWifi: () async => true,
      );
      await m.start();
      expect(m.state.value.isReady, isTrue, reason: '${m.state.value}');
      m.dispose();
    }

    final spec = OnnxEncoderSpec.ft2(dir.path);
    final tok = await GemmaTokenizer.load(
        '${dir.path}${Platform.pathSeparator}$semanticTokenizerFile');
    final enc = OnnxQueryEncoder(spec);
    expect(enc.ready, isTrue);
    expect(enc.space, 'embeddinggemma-300m-ft2@int8-mrl256');

    for (final e in kQueryRefs.entries) {
      final prompt = spec.promptTemplate!.replaceFirst('<text>', e.key);
      expect(tok.encode(prompt, maxTokens: spec.maxTokens).length, e.value.tokens,
          reason: 'token count for "${e.key}"');
      final v = await enc.embed(e.key);
      expect(v, isNotNull, reason: 'embed("${e.key}") returned null');
      expect(v!.length, 256);
      expect(_cosine(v, e.value.vec), greaterThan(0.99),
          reason: 'cosine to the desktop vector for "${e.key}"');
      expect((_norm(v) - 1).abs(), lessThan(1e-3));
    }

    // Unload frees the session; the next embed loads it again on its own.
    await enc.unload();
    final again = await enc.embed('that aws key');
    expect(again, isNotNull);
    expect(_cosine(again!, kQueryRefs['that aws key']!.vec), greaterThan(0.99));
    await enc.unload();

    // Nothing to embed is null, never a throw.
    expect(await enc.embed('   '), isNull);
  });
}

double _cosine(Float32List a, List<double> b) {
  var dot = 0.0;
  var nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    nb += b[i] * b[i];
  }
  return dot / (_norm(a) * (nb == 0 ? 1 : math.sqrt(nb)));
}

double _norm(Float32List v) {
  var s = 0.0;
  for (final x in v) {
    s += x * x;
  }
  return math.sqrt(s);
}

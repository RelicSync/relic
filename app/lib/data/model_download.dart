/// Downloads a search model onto a phone, one bundle of files at a time.
///
/// A bundle ([ModelBundle]) is a list of files with their URLs and exact
/// sizes. The manager fetches them into one directory, resumes a file that
/// was cut off (HTTP Range from the length of the `.part` file), checks every
/// finished file against its listed size, and tells the UI where it is
/// through a [ValueNotifier] of [ModelDownloadState].
///
/// Wi-Fi only: the bundle is hundreds of megabytes. The manager asks a
/// [WifiCheck] before each file and listens to a stream of changes while a
/// file is in flight; off Wi-Fi it drops the connection, keeps the partial
/// file, and waits. The check and the stream are injected so a test can flip
/// them without the connectivity plugin ([WifiWatch] wires the real one).
///
/// Nothing here blocks the UI: the body streams to disk in small chunks and
/// progress is published at most a few times a second.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ModelFile {
  final String name;
  final String url;

  /// Size on the server. With no [minBytes] it is exact: a finished file of
  /// any other length is thrown away and the download is marked failed. With
  /// [minBytes] it is only an estimate for the progress bar, and any file at
  /// least [minBytes] long passes.
  final int bytes;
  final int? minBytes;
  const ModelFile({
    required this.name,
    required this.url,
    required this.bytes,
    this.minBytes,
  });

  /// Whether a file of [length] bytes counts as this file.
  bool accepts(int length) {
    final min = minBytes;
    return min == null ? length == bytes : length >= min;
  }
}

class ModelBundle {
  /// A short id for logs and preferences.
  final String id;
  final List<ModelFile> files;
  const ModelBundle({required this.id, required this.files});

  int get totalBytes => files.fold(0, (n, f) => n + f.bytes);

  /// Whether every file is on disk at its exact size.
  bool isComplete(Directory dir) => files.every((f) {
        final file = File('${dir.path}${Platform.pathSeparator}${f.name}');
        return file.existsSync() && f.accepts(file.lengthSync());
      });
}

/// The graph file of the ft2 model, named once for the manifest, the encoder
/// spec and the ready check. It switches to
/// `embeddinggemma-300m-ft2.gf.int8.onnx` once that file is live on
/// models.relic.space: a gather-first rewrite of the same graph with
/// bit-identical vectors and the same model version string, loading the same
/// weights file by name. Its exact size is not known yet, which is why the
/// graph is the one file checked against a minimum rather than an exact size.
const String semanticGraphFile = 'embeddinggemma-300m-ft2.int8.onnx';

/// The ft2 weights, which the graph refers to by this exact name; ONNX
/// Runtime looks for it beside the graph.
const String semanticWeightsFile = 'embeddinggemma-300m-ft2.onnx_data';

/// The Gemma tokenizer, shared with the stock model.
const String semanticTokenizerFile = 'embeddinggemma-300m.tokenizer.json';

/// The desktop's search embedding model, EmbeddingGemma fine-tuned on copy
/// and search pairs, as an int8 ONNX graph. Three files, about 330 MB.
/// Sizes are what the desktop's relic-sift registry downloaded
/// (`relic-sift/src/models.rs` lists the same files with minimums); there is
/// no published checksum, so size plus a successful load is the check.
const ModelBundle semanticModelFt2 = ModelBundle(
  id: 'embeddinggemma-300m-ft2',
  files: [
    ModelFile(
      name: semanticGraphFile,
      url: 'https://models.relic.space/relic-sift/v2/$semanticGraphFile',
      bytes: 581739,
      minBytes: 400000,
    ),
    ModelFile(
      name: semanticTokenizerFile,
      url: 'https://models.relic.space/relic-sift/v1/$semanticTokenizerFile',
      bytes: 20323312,
    ),
    ModelFile(
      name: semanticWeightsFile,
      url: 'https://models.relic.space/relic-sift/v2/$semanticWeightsFile',
      bytes: 308890624,
    ),
  ],
);

enum ModelDownloadPhase { absent, downloading, ready, failed }

class ModelDownloadState {
  final ModelDownloadPhase phase;

  /// Bytes landed over bytes expected, 0..1. Meaningful while downloading.
  final double fraction;

  /// Why the last attempt failed, in plain words for the settings row.
  final String? reason;

  /// Downloading, but stopped until Wi-Fi comes back.
  final bool waitingForWifi;

  const ModelDownloadState._(
    this.phase, {
    this.fraction = 0,
    this.reason,
    this.waitingForWifi = false,
  });

  static const absent = ModelDownloadState._(ModelDownloadPhase.absent);
  static const ready = ModelDownloadState._(ModelDownloadPhase.ready);
  const ModelDownloadState.downloading(double fraction,
      {bool waitingForWifi = false})
      : this._(ModelDownloadPhase.downloading,
            fraction: fraction, waitingForWifi: waitingForWifi);
  const ModelDownloadState.failed(String reason)
      : this._(ModelDownloadPhase.failed, reason: reason);

  bool get isReady => phase == ModelDownloadPhase.ready;
  bool get isDownloading => phase == ModelDownloadPhase.downloading;

  @override
  String toString() => 'ModelDownloadState($phase, '
      '${(fraction * 100).toStringAsFixed(1)}%'
      '${waitingForWifi ? ', waiting for wifi' : ''}'
      '${reason == null ? '' : ', $reason'})';
}

typedef WifiCheck = Future<bool> Function();

/// Thrown inside the loop for a failure no retry can fix.
class _Fatal implements Exception {
  final String reason;
  _Fatal(this.reason);
}

/// Thrown when the current transfer was cut on purpose (cancel, or Wi-Fi went
/// away); the loop decides what to do next.
class _Interrupted implements Exception {}

class ModelDownloadManager {
  final Directory dir;
  final ModelBundle bundle;
  final WifiCheck isWifi;
  final http.Client Function() _newClient;
  final Duration stallTimeout;
  final Duration retryDelay;
  final int maxAttempts;

  /// Publish progress after this many new bytes. The notifier drives a
  /// progress bar, so there is no point in more than a few updates a second.
  final int progressEvery;

  final ValueNotifier<ModelDownloadState> state =
      ValueNotifier(ModelDownloadState.absent);

  StreamSubscription<bool>? _wifiSub;
  bool _wifi = true; // last word from the stream; the check refreshes it
  Completer<void>? _wifiBack;
  http.Client? _active; // the client of the transfer in flight
  bool _cancelled = false;
  Future<void>? _run;

  ModelDownloadManager({
    required this.dir,
    required this.bundle,
    required this.isWifi,
    Stream<bool>? wifiChanges,
    http.Client Function()? newClient,
    this.stallTimeout = const Duration(seconds: 30),
    this.retryDelay = const Duration(seconds: 3),
    this.maxAttempts = 6,
    this.progressEvery = 1024 * 1024,
  }) : _newClient = newClient ?? http.Client.new {
    _wifiSub = wifiChanges?.listen(_onWifi);
  }

  bool get isRunning => _run != null;

  /// Look at the disk and set [state] to ready or absent. Does not start
  /// anything. Call once after construction.
  Future<void> refresh() async {
    if (_run != null) return;
    state.value = bundle.isComplete(dir)
        ? ModelDownloadState.ready
        : ModelDownloadState.absent;
  }

  /// Download whatever is missing. A no-op while a run is in progress or the
  /// bundle is already complete. Returns when the run ends, in any state.
  Future<void> start() {
    final running = _run;
    if (running != null) return running;
    if (bundle.isComplete(dir)) {
      state.value = ModelDownloadState.ready;
      return Future.value();
    }
    _cancelled = false;
    final run = _loop().whenComplete(() => _run = null);
    _run = run;
    return run;
  }

  /// Stop the run. Partial files stay so a later [start] resumes them.
  Future<void> cancel() async {
    _cancelled = true;
    _active?.close();
    _wifiBack?.complete();
    _wifiBack = null;
    final running = _run;
    if (running != null) await running;
    await refresh();
  }

  /// Stop the run and remove every file of the bundle, partial or whole.
  Future<void> delete() async {
    await cancel();
    for (final f in bundle.files) {
      for (final path in [_path(f.name), _path('${f.name}.part')]) {
        try {
          final file = File(path);
          if (file.existsSync()) file.deleteSync();
        } catch (e) {
          debugPrint('model download: could not delete $path: $e');
        }
      }
    }
    state.value = ModelDownloadState.absent;
  }

  void dispose() {
    _cancelled = true;
    _active?.close();
    _wifiSub?.cancel();
    _wifiBack?.complete();
    _wifiBack = null;
    state.dispose();
  }

  String _path(String name) => '${dir.path}${Platform.pathSeparator}$name';

  void _onWifi(bool on) {
    _wifi = on;
    if (on) {
      _wifiBack?.complete();
      _wifiBack = null;
    } else {
      // Cut the transfer; the loop keeps the partial file and waits.
      _active?.close();
    }
  }

  Future<void> _waitForWifi(int done, int total) async {
    state.value = ModelDownloadState.downloading(
      total == 0 ? 0 : done / total,
      waitingForWifi: true,
    );
    final c = _wifiBack ??= Completer<void>();
    await c.future;
  }

  Future<void> _loop() async {
    final total = bundle.totalBytes;
    try {
      await dir.create(recursive: true);
      var done = 0;
      for (final f in bundle.files) {
        final target = File(_path(f.name));
        if (target.existsSync() && f.accepts(target.lengthSync())) {
          done += f.bytes;
          continue;
        }
        final part = File(_path('${f.name}.part'));
        var attempts = 0;
        while (true) {
          if (_cancelled) return;
          _wifi = await isWifi();
          if (!_wifi) {
            await _waitForWifi(done + _length(part), total);
            continue;
          }
          state.value =
              ModelDownloadState.downloading(_fraction(done, part, total));
          try {
            await _fetch(f, part, (got) {
              state.value =
                  ModelDownloadState.downloading((done + got) / total);
            });
            final len = _length(part);
            if (!f.accepts(len)) {
              _tryDelete(part);
              throw _Fatal('The downloaded file was not the right size.');
            }
            if (target.existsSync()) target.deleteSync();
            part.renameSync(target.path);
            done += f.bytes;
            break;
          } on _Interrupted {
            // Cancelled, or Wi-Fi went away: the top of the loop sorts it out.
            continue;
          } catch (e) {
            if (e is _Fatal) rethrow;
            attempts++;
            debugPrint('model download: ${f.name} attempt $attempts: $e');
            if (attempts >= maxAttempts) {
              throw _Fatal(
                  'The download stopped. Check your connection and try again.');
            }
            await Future<void>.delayed(retryDelay * attempts);
          }
        }
      }
      state.value = bundle.isComplete(dir)
          ? ModelDownloadState.ready
          : const ModelDownloadState.failed('Some files are missing.');
    } on _Fatal catch (e) {
      state.value = ModelDownloadState.failed(e.reason);
    } catch (e) {
      debugPrint('model download: $e');
      state.value =
          const ModelDownloadState.failed('The download could not finish.');
    }
  }

  static int _length(File f) => f.existsSync() ? f.lengthSync() : 0;

  static double _fraction(int done, File part, int total) =>
      total == 0 ? 0 : (done + _length(part)) / total;

  static void _tryDelete(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Fetch one file into [part], resuming from its current length. Throws
  /// [_Interrupted] when the transfer was cut on purpose, [_Fatal] when the
  /// server's answer rules the file out, anything else for a retry.
  Future<void> _fetch(
      ModelFile f, File part, void Function(int got) onProgress) async {
    var have = _length(part);
    if (have > f.bytes && f.minBytes == null) {
      _tryDelete(part);
      have = 0;
    }
    final req = http.Request('GET', Uri.parse(f.url));
    if (have > 0) req.headers['range'] = 'bytes=$have-';
    final client = _newClient();
    _active = client;
    IOSink? sink;
    try {
      final res = await client.send(req).timeout(stallTimeout);
      var append = true;
      switch (res.statusCode) {
        case 206:
          final cr = res.headers['content-range'] ?? '';
          final slash = cr.lastIndexOf('/');
          final totalStr = slash < 0 ? '' : cr.substring(slash + 1).trim();
          final total = int.tryParse(totalStr);
          if (total != null && !f.accepts(total)) {
            throw _Fatal('The file on the server is not the size expected.');
          }
          final dash = cr.indexOf('-');
          final startStr =
              cr.startsWith('bytes ') && dash > 6 ? cr.substring(6, dash) : '';
          if (int.tryParse(startStr.trim()) != have) {
            throw _Fatal('The server resumed from the wrong place.');
          }
        case 200:
          // The server ignored the range: start over.
          final declared = res.contentLength;
          if (declared != null && !f.accepts(declared)) {
            throw _Fatal('The file on the server is not the size expected.');
          }
          append = false;
          have = 0;
        case 416:
          // Our partial file does not fit the server's copy. Drop it and
          // let the retry fetch from the top.
          _tryDelete(part);
          throw HttpException('range not satisfiable for ${f.name}');
        case >= 400 && < 500:
          throw _Fatal('The model file is not on the server (${res.statusCode}).');
        default:
          throw HttpException('status ${res.statusCode} for ${f.name}');
      }
      sink = part.openWrite(
          mode: append ? FileMode.writeOnlyAppend : FileMode.writeOnly);
      var got = have;
      var lastShown = got;
      await for (final chunk in res.stream.timeout(stallTimeout)) {
        if (_cancelled) throw _Interrupted();
        sink.add(chunk);
        got += chunk.length;
        if (got > f.bytes && f.minBytes == null) {
          throw _Fatal('The server sent more than the file should hold.');
        }
        if (got - lastShown >= progressEvery) {
          lastShown = got;
          onProgress(got);
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      onProgress(got);
    } on http.ClientException {
      // The client was closed under the transfer (cancel or Wi-Fi gone), or
      // the connection dropped. Either way the loop decides.
      if (_cancelled || !_wifi) throw _Interrupted();
      rethrow;
    } finally {
      if (identical(_active, client)) _active = null;
      client.close();
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
    }
  }
}

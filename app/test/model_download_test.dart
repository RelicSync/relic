// The model download manager against a loopback server: the whole bundle
// lands, a cut-off file resumes from its .part with a Range request, a file
// of the wrong size fails the download instead of becoming a model, nothing
// moves off Wi-Fi and a transfer in flight pauses when Wi-Fi goes, and
// delete leaves no file behind. The Wi-Fi answer is a function and a stream
// handed in by the test, so the connectivity plugin is never touched.
//
// No TestWidgetsFlutterBinding here on purpose: the binding answers every
// HttpClient with 400 (see clear_history_test.dart), and this test has no
// widgets, so plain dart:io networking is left alone.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/model_download.dart';

/// Serves the bundle's files with Range support and a few switches.
class _ModelServer {
  final Map<String, Uint8List> files;
  late HttpServer _server;
  final rangeHeaders = <String, List<String?>>{}; // name -> Range per request
  final requests = <String>[];
  bool ignoreRange = false; // answer 200 from the top whatever the Range
  bool chunked = false; // send no Content-Length
  final shortBy = <String, int>{}; // serve this many bytes fewer than listed
  Duration chunkDelay = Duration.zero; // throttle, 16 KB per delay
  final missing = <String>{};

  _ModelServer(this.files);

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_server.forEach(_handle));
  }

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final name = req.uri.pathSegments.last;
    requests.add(name);
    await req.drain<void>();
    final res = req.response;
    final all = files[name];
    if (all == null || missing.contains(name)) {
      res.statusCode = 404;
      await res.close();
      return;
    }
    final body = all.sublist(0, all.length - (shortBy[name] ?? 0));
    final range = req.headers.value('range');
    rangeHeaders.putIfAbsent(name, () => []).add(range);
    var start = 0;
    if (range != null && !ignoreRange) {
      final m = RegExp(r'^bytes=(\d+)-$').firstMatch(range);
      start = int.parse(m!.group(1)!);
      if (start >= body.length) {
        res.statusCode = 416;
        await res.close();
        return;
      }
      res.statusCode = 206;
      res.headers.set('content-range', 'bytes $start-${body.length - 1}/${body.length}');
    } else {
      res.statusCode = 200;
    }
    final slice = body.sublist(start);
    if (!chunked) res.contentLength = slice.length;
    try {
      for (var off = 0; off < slice.length; off += 16 * 1024) {
        res.add(slice.sublist(off, min(off + 16 * 1024, slice.length)));
        await res.flush();
        if (chunkDelay > Duration.zero) await Future<void>.delayed(chunkDelay);
      }
      await res.close();
    } catch (_) {
      // The client went away; that is the point of some tests.
    }
  }
}

Future<ModelDownloadState> _waitFor(
  ModelDownloadManager m,
  bool Function(ModelDownloadState s) test, {
  Duration timeout = const Duration(seconds: 15),
}) {
  final c = Completer<ModelDownloadState>();
  void check() {
    if (!c.isCompleted && test(m.state.value)) c.complete(m.state.value);
  }

  m.state.addListener(check);
  check();
  return c.future
      .timeout(timeout, onTimeout: () => throw TimeoutException('waited for state; last ${m.state.value}'))
      .whenComplete(() => m.state.removeListener(check));
}

void main() {
  final rnd = Random(7);
  Uint8List bytes(int n) => Uint8List.fromList(List.generate(n, (_) => rnd.nextInt(256)));
  final data = {
    'graph.onnx': bytes(20 * 1024),
    'tok.json': bytes(5 * 1024 + 13),
    'weights.onnx_data': bytes(300 * 1024 + 7),
  };

  late _ModelServer server;
  late Directory dir;
  late ModelBundle bundle;
  late StreamController<bool> wifi;
  var wifiOn = true;
  final managers = <ModelDownloadManager>[];

  ModelDownloadManager manager() {
    final m = ModelDownloadManager(
      dir: dir,
      bundle: bundle,
      isWifi: () async => wifiOn,
      wifiChanges: wifi.stream,
      stallTimeout: const Duration(seconds: 5),
      retryDelay: const Duration(milliseconds: 50),
      maxAttempts: 3,
      progressEvery: 16 * 1024,
    );
    managers.add(m);
    return m;
  }

  setUp(() async {
    server = _ModelServer(data);
    await server.start();
    dir = await Directory.systemTemp.createTemp('relic_model_dl');
    bundle = ModelBundle(
      id: 'test',
      files: [
        for (final e in data.entries)
          ModelFile(name: e.key, url: '${server.base}/${e.key}', bytes: e.value.length),
      ],
    );
    wifi = StreamController<bool>.broadcast();
    wifiOn = true;
  });

  tearDown(() async {
    for (final m in managers) {
      m.dispose();
    }
    managers.clear();
    await wifi.close();
    await server.close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> expectComplete() async {
    for (final e in data.entries) {
      final f = File('${dir.path}${Platform.pathSeparator}${e.key}');
      expect(f.existsSync(), isTrue, reason: '${e.key} missing');
      expect(await f.readAsBytes(), e.value, reason: '${e.key} differs');
      expect(File('${f.path}.part').existsSync(), isFalse);
    }
  }

  test('bundle sizes: the ft2 bundle is about 330 MB', () {
    expect(semanticModelFt2.files.length, 3);
    expect((semanticModelFt2.totalBytes / 1e6).round(), 330);
    // The weights must keep the name the graph refers to.
    expect(semanticModelFt2.files.map((f) => f.name),
        contains('embeddinggemma-300m-ft2.onnx_data'));
    // The graph is checked against a minimum (its gather-first rewrite has
    // no final size yet); the other two are exact.
    final graph =
        semanticModelFt2.files.firstWhere((f) => f.name == semanticGraphFile);
    expect(graph.accepts(graph.bytes + 1000), isTrue);
    expect(graph.accepts(1000), isFalse);
    for (final f
        in semanticModelFt2.files.where((f) => f.name != semanticGraphFile)) {
      expect(f.accepts(f.bytes), isTrue);
      expect(f.accepts(f.bytes - 1), isFalse);
    }
  });

  test('a minimum-size file passes when longer and fails when shorter',
      () async {
    // Listed 1000 bytes short of what the server has, with a minimum under
    // both: it lands. With a minimum above what the server has: it fails.
    final graph = data['graph.onnx']!;
    ModelBundle b(int min) => ModelBundle(
          id: 'min',
          files: [
            ModelFile(
                name: 'graph.onnx',
                url: '${server.base}/graph.onnx',
                bytes: graph.length - 1000,
                minBytes: min),
          ],
        );
    final ok = ModelDownloadManager(
        dir: dir, bundle: b(1000), isWifi: () async => true);
    managers.add(ok);
    await ok.start();
    expect(ok.state.value.isReady, isTrue, reason: '${ok.state.value}');
    expect(File('${dir.path}${Platform.pathSeparator}graph.onnx').lengthSync(),
        graph.length);
    final bad = ModelDownloadManager(
        dir: dir, bundle: b(graph.length + 1), isWifi: () async => true);
    managers.add(bad);
    await bad.refresh();
    expect(bad.state.value.phase, ModelDownloadPhase.absent);
    await bad.start();
    expect(bad.state.value.phase, ModelDownloadPhase.failed);
  });

  test('downloads the whole bundle and reports ready', () async {
    final m = manager();
    await m.refresh();
    expect(m.state.value.phase, ModelDownloadPhase.absent);
    final seen = <ModelDownloadPhase>{};
    m.state.addListener(() => seen.add(m.state.value.phase));
    await m.start();
    expect(m.state.value.isReady, isTrue);
    expect(seen, contains(ModelDownloadPhase.downloading));
    await expectComplete();
    // A fresh manager over the same directory sees it ready without a byte.
    final again = manager();
    await again.refresh();
    expect(again.state.value.isReady, isTrue);
    final before = server.requests.length;
    await again.start();
    expect(server.requests.length, before);
  });

  test('resumes a partial file with a Range request', () async {
    final big = data['weights.onnx_data']!;
    final part = File('${dir.path}${Platform.pathSeparator}weights.onnx_data.part');
    await dir.create(recursive: true);
    await part.writeAsBytes(big.sublist(0, 100 * 1024));
    final m = manager();
    await m.start();
    expect(m.state.value.isReady, isTrue, reason: '${m.state.value}');
    await expectComplete();
    expect(server.rangeHeaders['weights.onnx_data'], ['bytes=${100 * 1024}-']);
  });

  test('a server that ignores Range still yields a correct file', () async {
    server.ignoreRange = true;
    final big = data['weights.onnx_data']!;
    final part = File('${dir.path}${Platform.pathSeparator}weights.onnx_data.part');
    await dir.create(recursive: true);
    await part.writeAsBytes(big.sublist(0, 50 * 1024));
    final m = manager();
    await m.start();
    expect(m.state.value.isReady, isTrue, reason: '${m.state.value}');
    await expectComplete();
  });

  test('a file of the wrong size fails the download', () async {
    server.shortBy['tok.json'] = 100;
    final m = manager();
    await m.start();
    expect(m.state.value.phase, ModelDownloadPhase.failed);
    expect(m.state.value.reason, isNotEmpty);
    expect(File('${dir.path}${Platform.pathSeparator}tok.json').existsSync(), isFalse);
    expect(File('${dir.path}${Platform.pathSeparator}tok.json.part').existsSync(), isFalse);
    // The server was asked for the short file once: no retries on a size the
    // server itself declared.
    expect(server.requests.where((n) => n == 'tok.json').length, 1);
  });

  test('a short body with no Content-Length fails after the check', () async {
    server.chunked = true;
    server.shortBy['graph.onnx'] = 1;
    final m = manager();
    await m.start();
    expect(m.state.value.phase, ModelDownloadPhase.failed);
    expect(File('${dir.path}${Platform.pathSeparator}graph.onnx').existsSync(), isFalse);
  });

  test('a missing file on the server fails without retries', () async {
    server.missing.add('graph.onnx');
    final m = manager();
    await m.start();
    expect(m.state.value.phase, ModelDownloadPhase.failed);
    expect(server.requests.where((n) => n == 'graph.onnx').length, 1);
  });

  test('nothing moves off Wi-Fi; the download starts when it comes back', () async {
    wifiOn = false;
    final m = manager();
    final run = m.start();
    await _waitFor(m, (s) => s.isDownloading && s.waitingForWifi);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(server.requests, isEmpty);
    wifiOn = true;
    wifi.add(true);
    await run;
    expect(m.state.value.isReady, isTrue, reason: '${m.state.value}');
    await expectComplete();
  });

  test('a transfer in flight pauses when Wi-Fi goes and resumes after', () async {
    server.chunkDelay = const Duration(milliseconds: 15);
    final m = manager();
    final run = m.start();
    // Wait until the big file is under way (the two small ones land first).
    await _waitFor(m, (s) => s.isDownloading && s.fraction > 0.15 && s.fraction < 0.9);
    wifiOn = false;
    wifi.add(false);
    final paused = await _waitFor(m, (s) => s.waitingForWifi);
    expect(paused.isDownloading, isTrue);
    final part = File('${dir.path}${Platform.pathSeparator}weights.onnx_data.part');
    expect(part.existsSync(), isTrue);
    final kept = part.lengthSync();
    expect(kept, greaterThan(0));
    final requestsAtPause = server.requests.length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(server.requests.length, requestsAtPause, reason: 'no requests while waiting');
    server.chunkDelay = Duration.zero;
    wifiOn = true;
    wifi.add(true);
    await run;
    expect(m.state.value.isReady, isTrue, reason: '${m.state.value}');
    await expectComplete();
    final ranges = server.rangeHeaders['weights.onnx_data']!;
    expect(ranges.first, isNull);
    expect(ranges.last, 'bytes=$kept-');
  });

  test('cancel keeps the partial file; delete removes everything', () async {
    server.chunkDelay = const Duration(milliseconds: 15);
    final m = manager();
    unawaited(m.start());
    await _waitFor(m, (s) => s.isDownloading && s.fraction > 0.15 && s.fraction < 0.9);
    await m.cancel();
    expect(m.isRunning, isFalse);
    expect(m.state.value.phase, ModelDownloadPhase.absent);
    final part = File('${dir.path}${Platform.pathSeparator}weights.onnx_data.part');
    expect(part.existsSync(), isTrue);
    await m.delete();
    expect(m.state.value.phase, ModelDownloadPhase.absent);
    expect(dir.listSync(), isEmpty);
  });

  test('a dropped connection is retried and the file resumes', () async {
    // First answer for the big file is cut short by closing the socket.
    var cut = false;
    final cutServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(cutServer.forEach((req) async {
      final name = req.uri.pathSegments.last;
      await req.drain<void>();
      final body = data[name]!;
      final range = req.headers.value('range');
      var start = 0;
      if (range != null) {
        start = int.parse(RegExp(r'^bytes=(\d+)-$').firstMatch(range)!.group(1)!);
      }
      if (name == 'weights.onnx_data' && !cut) {
        // Promise the whole file, send 64 KB, drop the socket.
        cut = true;
        final socket = await req.response.detachSocket(writeHeaders: false);
        socket.write('HTTP/1.1 200 OK\r\n'
            'content-length: ${body.length}\r\n'
            'connection: close\r\n\r\n');
        socket.add(body.sublist(0, 64 * 1024));
        await socket.flush();
        socket.destroy();
        return;
      }
      if (range != null) {
        req.response.statusCode = 206;
        req.response.headers.set('content-range', 'bytes $start-${body.length - 1}/${body.length}');
      }
      req.response.contentLength = body.length - start;
      req.response.add(body.sublist(start));
      await req.response.close();
    }));
    final b = ModelBundle(
      id: 'cut',
      files: [
        for (final e in data.entries)
          ModelFile(
              name: e.key,
              url: 'http://127.0.0.1:${cutServer.port}/${e.key}',
              bytes: e.value.length),
      ],
    );
    final m = ModelDownloadManager(
      dir: dir,
      bundle: b,
      isWifi: () async => true,
      retryDelay: const Duration(milliseconds: 30),
      stallTimeout: const Duration(seconds: 5),
      progressEvery: 16 * 1024,
    );
    managers.add(m);
    await m.start();
    await cutServer.close(force: true);
    expect(m.state.value.isReady, isTrue, reason: '${m.state.value}');
    await expectComplete();
  });
}

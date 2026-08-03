import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One relic's classification, parsed from a `sift` ClassificationRecord
/// (schema `sift/0.1`, see relic-sift/src/record.rs).
class SiftResult {
  final String category; // category.primary
  final double confidence;
  final bool needsReview;
  final List<String> labels; // e.g. pii_present
  final List<String> relicTags; // → merged into Relic.tags
  // Open-vocabulary tags from the labeler. Deliberately NOT part of
  // [relicTags]: these are unbounded, so they must go through
  // `sift tags bound` (snap near-duplicates + require recurrence) before they
  // are shown, while the curated relicTags pass straight through.
  final List<String> labelTags;
  final String? extractedText; // OCR/doc/caption text, secret-masked
  final String? caption; // the labeler's generated title (masked)
  final String preview;
  final List<double>? textVector; // document embedding (when --vectors)
  // Per-chunk embeddings for long documents (same space as [textVector],
  // which stays the whole-doc/head vector). Null/empty for short texts.
  final List<List<double>>? textChunkVectors;

  SiftResult({
    required this.category,
    required this.confidence,
    required this.needsReview,
    required this.labels,
    required this.relicTags,
    this.labelTags = const [],
    required this.extractedText,
    required this.preview,
    this.caption,
    this.textVector,
    this.textChunkVectors,
  });

  factory SiftResult.fromJson(Map<String, dynamic> j) {
    final cat = (j['category'] as Map<String, dynamic>?) ?? const {};
    final emb = (j['embeddings'] as Map<String, dynamic>?)?['text'] as Map<String, dynamic>?;
    final vec = (emb?['vector'] as List?)?.map((e) => (e as num).toDouble()).toList();
    final chunks = (emb?['chunks'] as List?)
        ?.map((c) =>
            (c as List).map((e) => (e as num).toDouble()).toList())
        .toList();
    return SiftResult(
      category: cat['primary'] as String? ?? 'unsorted',
      confidence: (cat['confidence'] as num?)?.toDouble() ?? 0,
      needsReview: cat['needs_review'] as bool? ?? false,
      labels: (j['labels'] as List?)?.cast<String>() ?? const [],
      relicTags: (j['relic_tags'] as List?)?.cast<String>() ?? const [],
      labelTags: (j['label_tags'] as List?)?.cast<String>() ?? const [],
      extractedText: j['extracted_text'] as String?,
      caption: j['caption'] as String?,
      preview: j['preview'] as String? ?? '',
      textVector: vec,
      textChunkVectors: chunks,
    );
  }
}

/// The result of `sift tags bound`.
class TagBoundResult {
  /// Emitted tag string → the representative it belongs to.
  final Map<String, String> mapping;

  /// Vectors for every string embedded this run, **aliases included**. All of
  /// it must be persisted: reconcile needs the alias rows to work at all.
  final Map<String, List<double>> vectors;

  /// Representative → its group total after this batch.
  final Map<String, int> counts;

  /// Representatives that have earned a visible facet chip.
  final Set<String> promoted;

  const TagBoundResult({
    required this.mapping,
    required this.vectors,
    required this.counts,
    required this.promoted,
  });

  factory TagBoundResult.fromJson(Map<String, dynamic> j) => TagBoundResult(
        mapping: ((j['mapping'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k as String, v as String)),
        vectors: {
          for (final a in (j['added'] as List? ?? const []))
            (a['tag'] as String):
                (a['vec'] as List).map((e) => (e as num).toDouble()).toList(),
        },
        counts: ((j['counts'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k as String, (v as num).toInt())),
        promoted: {...?(j['promoted'] as List?)?.cast<String>()},
      );
}

/// Bridge to the bundled `sift` classification binary (relic-sift). Runs the
/// full local ML pipeline out-of-process so it never blocks capture or the UI.
/// All model downloads + ONNX runtime loading happen inside the sidecar.
class SiftSidecar {
  final String exePath;

  /// Idle windows before each resident sidecar is dropped. Overridable so
  /// tests can exercise the unload without waiting minutes; production uses
  /// the defaults.
  final Duration serverIdle;
  final Duration embedIdle;

  SiftSidecar(
    this.exePath, {
    this.serverIdle = defaultServerIdle,
    this.embedIdle = defaultEmbedIdle,
  });

  bool _modelsReady = false;
  bool get modelsReady => _modelsReady;

  /// Whether item descriptions are enabled at all (the user's setting).
  ///
  /// Deliberately separate from the per-item `label` argument: this decides
  /// whether the resident server *loads* the labeler, which must stay constant
  /// across items, while individual items still opt in or out. Set it before
  /// classifying, and call [stopServer] when it changes.
  bool labelCapable = false;

  /// CPU budget for the sidecar (`gentle` | `balanced` | `fast`), passed
  /// straight through to `sift --speed`. It scales the ONNX thread count to the
  /// host and drops the process below foreground priority for everything but
  /// `fast`. Part of the resident server's flag key, so changing it restarts
  /// the server — threads are fixed when a session is built.
  String speed = 'balanced';

  /// Find sift.exe: next to the running app (packaged), else the dev target dir.
  /// Returns null if no binary is present.
  static SiftSidecar? locate() {
    final sep = Platform.pathSeparator;
    final exe = Platform.isWindows ? 'sift.exe' : 'sift';
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      '$exeDir$sep$exe', // packaged: alongside relic_app.exe
      // dev: app/build/windows/x64/runner/Release/ → repo root/target/release
      '$exeDir$sep..$sep..$sep..$sep..$sep..$sep..${sep}target${sep}release$sep$exe',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return SiftSidecar(File(c).absolute.path);
    }
    return null;
  }

  /// Refresh whether the core ML models are downloaded and ready.
  Future<bool> checkModels() async {
    try {
      final r = await Process.run(exePath, ['models', 'status']);
      // `models status` prints "MISSING" for any absent core model; optional
      // ones print "optional", so a clean core set has no "MISSING".
      _modelsReady = r.exitCode == 0 && !'${r.stdout}'.contains('MISSING');
    } catch (_) {
      _modelsReady = false;
    }
    return _modelsReady;
  }

  /// The model cache directory (`sift models path` prints exactly one line).
  /// Null when the binary fails or prints nothing.
  Future<String?> modelsPath() async {
    try {
      final r = await Process.run(exePath, ['models', 'path']);
      if (r.exitCode != 0) return null;
      final p = '${r.stdout}'.trim();
      return p.isEmpty ? null : p;
    } catch (_) {
      return null;
    }
  }

  /// Delete models a previous version left behind that this one can never load
  /// — chiefly Florence-2, which Qwen3.5 replaced (~246 MB). Returns the bytes
  /// freed, or 0 if the binary is old enough not to know the subcommand.
  ///
  /// Safe to run unattended and idempotent, so the caller only has to make sure
  /// it happens once per upgrade rather than reason about what is on disk.
  Future<int> pruneModels({bool deep = false}) async {
    try {
      final r = await Process.run(
        exePath,
        ['models', 'prune', '--json', if (deep) '--deep'],
      );
      if (r.exitCode != 0) return 0;
      final j = jsonDecode('${r.stdout}'.trim()) as Map<String, dynamic>;
      return (j['freed_bytes'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Download the core models (~450 MB) — and optionally the Qwen3.5
  /// open-vocabulary labeler (~666 MB). Long-running; call off the hot path.
  Future<void> downloadModels({bool label = false}) async {
    try {
      await Process.run(exePath, ['models', 'download', if (label) '--label']);
    } catch (_) {}
    await checkModels();
  }

  /// The query-side tag-expansion table: `{model_version, dim, gloss_hash,
  /// tags:[{tag, vec}]}`. Embeds every searchable tag's gloss once (document
  /// prefix), so the app can match a query against tags semantically. Returns
  /// the decoded JSON map, or null if the binary/model isn't ready.
  Future<Map<String, dynamic>?> tagVectors() async {
    try {
      final r = await Process.run(exePath, ['tags', 'vectors', '--compact']);
      if (r.exitCode != 0) return null;
      final line = '${r.stdout}'.split('\n').firstWhere(
            (l) => l.trimLeft().startsWith('{'),
            orElse: () => '',
          );
      if (line.isEmpty) return null;
      return jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Bound a batch of open-vocabulary tags: snap near-duplicates onto one
  /// representative and report which representatives have recurred enough to
  /// be shown. See relic-sift/src/tag_vocab.rs for why both halves are needed.
  ///
  /// Stateless on the sidecar's side — [vocabulary] goes in, the update comes
  /// back, and the vault stays the single source of truth. [emitted] may
  /// repeat; repetition is exactly the promotion signal.
  ///
  /// With [reconcile], re-derives the whole grouping from scratch in frequency
  /// order instead of absorbing [emitted]. Pass **every** row for that, aliases
  /// included: given representatives only it is a no-op by construction.
  Future<TagBoundResult?> boundTags({
    required List<Map<String, dynamic>> vocabulary,
    List<String> emitted = const [],
    bool reconcile = false,
  }) async {
    if (!reconcile && emitted.isEmpty) return null;
    try {
      final proc = await Process.start(exePath, [
        'tags',
        'bound',
        '--compact',
        if (reconcile) '--reconcile',
      ]);
      proc.stdin.write(jsonEncode({
        'vocabulary': vocabulary,
        'emitted': emitted,
      }));
      await proc.stdin.close();
      final out = await proc.stdout.transform(utf8.decoder).join();
      await proc.stderr.drain<void>();
      if (await proc.exitCode != 0) return null;
      final line = out
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.startsWith('{'), orElse: () => '');
      if (line.isEmpty) return null;
      return TagBoundResult.fromJson(jsonDecode(line) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<SiftResult?> classifyText(String text,
          {required bool ml, bool label = false, bool embeddings = true}) =>
      _classify(
          text: text,
          kind: 'string',
          ml: ml,
          label: label,
          embeddings: embeddings);

  Future<SiftResult?> classifyPath(String path,
          {required bool ml,
          required String kind,
          bool label = false,
          bool ocr = true,
          bool imageTags = true,
          bool embeddings = true}) =>
      _classify(
          path: path,
          kind: kind,
          ml: ml,
          label: label,
          ocr: ocr,
          imageTags: imageTags,
          embeddings: embeddings);

  // --- resident classifier --------------------------------------------------
  // A long-lived `sift classify --serve`: every model loads once, then one JSON
  // request per stdin line → one record per stdout line.
  //
  // This is not a micro-optimization. Measured with the labeler on, a one-shot
  // run spends ~6 s loading models and priming to do ~0.8 s of actual work, so
  // an enricher going item-by-item was paying 7× for nothing. Same 22 items:
  // ~128 s across 22 processes, 23 s through one.
  //
  // The flags are baked in at spawn, so a change of settings restarts the
  // process — hence [_serveKey]. Requests are serialized: the sidecar answers
  // in order and there is no request id to match on.

  Process? _serveProc;
  String? _serveKey;
  Completer<String>? _servePending;
  Future<void> _serveLock = Future.value();

  /// A single stalled item must not wedge the whole enrichment loop.
  static const Duration _serveTimeout = Duration(seconds: 180);

  /// How long the classifier may sit unused before we let it go.
  ///
  /// Staying resident is expensive in a way the file sizes do not suggest:
  /// ONNX Runtime memory-maps the quantized weights at load, then expands them
  /// to fp32 on first inference and keeps that for the life of the session, so
  /// this process settles at ~2.0-2.5 GB of private commit. Dropping it is the
  /// only thing that gives that back — no session option avoids the expansion
  /// (prepacking, memory pattern, arena and optimization level were all
  /// measured, and none moved it).
  ///
  /// Cheap to undo: a cold spawn answers its first item in ~5.4 s against
  /// ~3.6 s warm, so a reload costs about 1.8 s on a background pass that is
  /// already seconds per item. Nobody is waiting on it.
  static const Duration defaultServerIdle = Duration(minutes: 5);
  Timer? _serveIdle;

  /// Stop the resident classifier (settings changed, or shutting down).
  void stopServer() {
    _serveIdle?.cancel();
    _serveIdle = null;
    _serveProc?.kill();
    _resetServe();
  }

  /// Restart the idle countdown. Called after every request, so the timer
  /// measures silence rather than uptime.
  void _touchServeIdle() {
    _serveIdle?.cancel();
    _serveIdle = null;
    if (_serveProc == null) return;
    _serveIdle = Timer(serverIdle, _unloadServer);
  }

  /// Drop an idle classifier. Process exit is what actually returns the
  /// memory, so this kills rather than trying to free anything in-process.
  void _unloadServer() {
    _serveIdle?.cancel();
    _serveIdle = null;
    // A request landed between the timer firing and now: leave it alone and
    // let the next completion re-arm the countdown.
    if (_servePending != null) return _touchServeIdle();
    final p = _serveProc;
    if (p == null) return;
    // Unregister BEFORE killing: the exit event arrives later, and _resetServe
    // would otherwise fire against whatever is registered by then.
    _serveProc = null;
    _serveKey = null;
    try {
      p.kill();
    } catch (_) {}
  }

  /// Clear the registration only if [p] is still the server we're tracking.
  /// A late event from a process we already replaced must not touch its
  /// successor's state.
  void _resetServeIf(Process p) {
    if (identical(_serveProc, p)) _resetServe();
  }

  void _resetServe() {
    _serveProc = null;
    _serveKey = null;
    if (_servePending != null && !_servePending!.isCompleted) {
      _servePending!.completeError('classify server closed');
    }
    _servePending = null;
  }

  Future<bool> _ensureServer(List<String> flags) async {
    final key = flags.join(' ');
    if (_serveProc != null && _serveKey == key) return true;
    if (_serveProc != null) {
      // Different flags: the running process can't honor them.
      _serveProc?.kill();
      _resetServe();
    }
    try {
      final p = await Process.start(exePath, [
        'classify',
        '--serve',
        '--compact',
        ...flags,
      ]);
      _serveProc = p;
      _serveKey = key;
      // Every handler below is scoped to `p`. A killed server's stdout closes
      // asynchronously — after its replacement has already registered — so an
      // unscoped onDone would clear the *new* server's registration, leaving it
      // running and unreferenced while the next call spawned another. That
      // leaked a second resident classifier holding the whole model set. The
      // same guard stops a dying server's last line from completing a request
      // that now belongs to its replacement.
      p.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (!identical(_serveProc, p)) return;
        final l = line.trim();
        if (l.startsWith('{') &&
            _servePending != null &&
            !_servePending!.isCompleted) {
          _servePending!.complete(l);
        }
      }, onError: (_) => _resetServeIf(p), onDone: () => _resetServeIf(p));
      p.stderr.drain<void>();
      return true;
    } catch (_) {
      _resetServe();
      return false;
    }
  }

  /// One request through the resident classifier. Null means "couldn't serve
  /// it" — the caller falls back to a one-shot run rather than losing the item.
  Future<SiftResult?> _serve(
    List<String> flags,
    Map<String, dynamic> request,
  ) {
    final done = Completer<SiftResult?>();
    _serveLock = _serveLock.then((_) async {
      if (!await _ensureServer(flags)) {
        done.complete(null);
        return;
      }
      final pending = Completer<String>();
      _servePending = pending;
      try {
        _serveProc!.stdin.writeln(jsonEncode(request));
        final line = await pending.future.timeout(_serveTimeout);
        final j = jsonDecode(line) as Map<String, dynamic>;
        // A per-request error (unreadable file, bad path) is reported instead
        // of killing the server, so one bad item can't end the pass.
        done.complete(j.containsKey('error') ? null : SiftResult.fromJson(j));
      } catch (_) {
        // Timeout or a dead pipe: drop the process so the next call restarts it.
        _serveProc?.kill();
        _resetServe();
        done.complete(null);
      } finally {
        _servePending = null;
        _touchServeIdle();
      }
    });
    return done.future;
  }

  Future<SiftResult?> _classify({
    String? path,
    String? text,
    required String kind,
    required bool ml,
    required bool label,
    bool ocr = true,
    bool imageTags = true,
    bool embeddings = true,
  }) async {
    // The process flag says the labeler may run at all; the per-request field
    // says whether THIS item earns one. Keeping them apart is what stops the
    // resident server thrashing — a vault note and a stream clipping differ
    // per item, and respawning to flip a flag would discard the model load.
    final serverMayLabel = label || labelCapable;
    // Flags that configure the pipeline itself — the resident server is keyed
    // on exactly these, so a settings change restarts it and nothing else does.
    final flags = <String>['--speed', speed];
    if (!ml) {
      flags.add('--no-ml'); // Stage-A only: instant, no models
    } else {
      flags.add('--offline'); // present → no network
      if (embeddings) flags.add('--vectors'); // emit the doc vector for search
      if (!ocr) flags.add('--no-ocr');
      if (!imageTags) flags.add('--no-image-tags');
    }
    if (serverMayLabel) {
      // One flag now: the labeler emits a short title plus open-vocabulary
      // tags. Florence's caption-length and object-detection knobs are gone —
      // it had neither a title nor a tag channel, which is why it was replaced.
      flags.add('--label');
    }

    // Resident first — with the labeler on, spawning per item costs 7×. Falls
    // through to a one-shot run if the server can't start or dies mid-request,
    // so a broken server degrades speed, never correctness.
    final served = await _serve(flags, {
      'kind': kind,
      'label': label,
      if (path != null) 'path': path,
      if (path == null) 'text': text ?? '',
    });
    if (served != null) return served;

    final args = <String>[
      'classify',
      '--compact',
      ...flags.where((f) => f != '--label'),
      if (label) '--label',
    ];
    if (path != null) {
      args..add('--kind')..add(kind)..add(path);
    } else {
      args.add('--stdin');
    }
    try {
      final proc = await Process.start(exePath, args);
      if (path == null) {
        proc.stdin.add(utf8.encode(text ?? ''));
        await proc.stdin.close();
      }
      final out = await proc.stdout.transform(utf8.decoder).join();
      await proc.stderr.drain<void>();
      if (await proc.exitCode != 0) return null;
      final line = out
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.startsWith('{'), orElse: () => '');
      if (line.isEmpty) return null;
      return SiftResult.fromJson(jsonDecode(line) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  // --- persistent query embedder (for fast semantic search-as-you-type) ---
  // A long-lived `sift embed --serve` process: model loads once, then one
  // query per stdin line → one vector per stdout line. Requests are serialized.

  Process? _embedProc;
  Completer<String>? _pending;
  Future<void> _embedLock = Future.value();
  final Map<String, List<double>> _embedCache = {}; // small LRU of query → vector
  final List<String> _embedOrder = [];

  /// Load the embed model ahead of the first real search (kills first-query lag).
  Future<void> warmUp() async {
    try {
      await embedQuery('relic');
    } catch (_) {}
  }

  Future<void> _ensureEmbedServer() async {
    if (_embedProc != null) return;
    try {
      final p = await Process.start(exePath, [
        '--speed',
        speed,
        'embed',
        '--serve',
      ]);
      _embedProc = p;
      // Scoped to `p` for the same reason as the classifier above: now that an
      // idle embedder is killed and respawned as a matter of course, a dead
      // process's close event lands after its replacement has registered. An
      // unscoped handler would clear the new one, leaving it running and
      // unreferenced — a second resident copy holding another ~1.2 GB.
      p.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (!identical(_embedProc, p)) return;
        final l = line.trim();
        if (l.startsWith('{') && _pending != null && !_pending!.isCompleted) {
          _pending!.complete(l);
        }
      }, onError: (_) => _resetEmbedIf(p), onDone: () => _resetEmbedIf(p));
      p.stderr.drain<void>();
    } catch (_) {
      _embedProc = null;
    }
  }

  /// Clear the registration only if [p] is still the embedder we're tracking.
  void _resetEmbedIf(Process p) {
    if (identical(_embedProc, p)) _resetEmbed();
  }

  void _resetEmbed() {
    _embedProc = null;
    if (_pending != null && !_pending!.isCompleted) {
      _pending!.completeError('embed server closed');
    }
    _pending = null;
  }

  /// How long the query embedder may sit unused before we let it go. Same
  /// fp32 weight expansion as the classifier: ~98 MB at load becomes ~1.2 GB
  /// the moment it embeds anything, and it never comes back down.
  ///
  /// Longer than the classifier's window because this one is in front of a
  /// person: reloading costs ~1.7 s plus ~220 ms for the first query. Search
  /// stays usable through it — the keyword leg answers immediately either way
  /// and the semantic leg just joins a beat later — but a burst of searching
  /// should not keep paying that, and ten minutes covers a working session.
  static const Duration defaultEmbedIdle = Duration(minutes: 10);
  Timer? _embedIdle;

  void _touchEmbedIdle() {
    _embedIdle?.cancel();
    _embedIdle = null;
    if (_embedProc == null) return;
    _embedIdle = Timer(embedIdle, _unloadEmbed);
  }

  /// Drop an idle embedder; the cache of recent query vectors outlives it, so
  /// repeating a recent search still costs nothing.
  void _unloadEmbed() {
    _embedIdle?.cancel();
    _embedIdle = null;
    if (_pending != null) return _touchEmbedIdle(); // request in flight
    final p = _embedProc;
    if (p == null) return;
    _embedProc = null; // unregister before kill; the exit event arrives later
    try {
      p.kill();
    } catch (_) {}
  }

  /// Embed a search query into a bge vector (query-prefixed, L2-normalized),
  /// matching the stored document vectors. Null if unavailable. Serialized.
  Future<List<double>?> embedQuery(String query) {
    final key = query.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
    if (key.isEmpty) return Future.value(null);
    final hit = _embedCache[key];
    if (hit != null) return Future.value(hit);
    final result = _embedLock.then((_) => _embedOne(key));
    _embedLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<List<double>?> _embedOne(String q) async {
    await _ensureEmbedServer();
    final p = _embedProc;
    if (p == null) return null;
    final c = Completer<String>();
    _pending = c;
    try {
      p.stdin.writeln(q);
      final line = await c.future.timeout(const Duration(seconds: 30));
      final j = jsonDecode(line) as Map<String, dynamic>;
      final v = (j['vector'] as List).map((e) => (e as num).toDouble()).toList();
      _embedCache[q] = v; // cache (bounded LRU)
      _embedOrder.add(q);
      if (_embedOrder.length > 32) _embedCache.remove(_embedOrder.removeAt(0));
      return v;
    } catch (_) {
      return null;
    } finally {
      if (identical(_pending, c)) _pending = null;
      _touchEmbedIdle();
    }
  }

  void dispose() {
    _embedIdle?.cancel();
    _embedIdle = null;
    try {
      _embedProc?.kill();
    } catch (_) {}
    _embedProc = null;
    try {
      stopServer();
    } catch (_) {}
  }
}

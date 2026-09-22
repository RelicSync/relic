import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../platform/paths.dart';
import 'local_desk_repo.dart';

/// Owns one explicitly requested recording. Inherited process pipes are the
/// complete IPC surface; neither audio nor transcripts go to a network service.
class VoiceController extends ChangeNotifier {
  VoiceController(this.repo, {this.launchProcess});
  @visibleForTesting
  final Future<Process> Function(String executable, List<String> arguments)?
  launchProcess;
  final LocalDeskRepo repo;
  static const _native = MethodChannel('relic/voice');
  Process? _process;
  StreamSubscription<String>? _output;
  StreamSubscription<List<int>>? _errors;
  bool _disposed = false, _launching = false, _confirmed = false;
  bool enabled = false, ready = false, recording = false, processing = false;
  bool punctuation = true, shortcuts = true;
  bool _note = false,
      _latched = false,
      _practice = false,
      _practiceNext = false;
  bool _audioStarted = false;
  bool _protocolReady = false;
  Future<void> _preferenceWrite = Future.value();
  int _generation = 0;
  String? _id;
  String _app = '';
  String status = 'Voice is off';
  String lastText = '', lastRaw = '';
  double progress = 0, seconds = 0, level = 0;
  int? device;
  String? _deviceName;
  List<Map<String, dynamic>> devices = [];
  List<String> vocabulary = [];
  List<Map<String, dynamic>> corrections = [];
  Map<String, dynamic>? _pending;
  Map<String, dynamic> _sessionSettings = {};
  DateTime? _capturedAt;
  String _lastBlocklist = '';
  void _syncBlocklist() {
    final entries = repo.captureBlocklist.toList()..sort();
    final key = entries.join("|");
    if (key == _lastBlocklist) return;
    _lastBlocklist = key;
    unawaited(_native.invokeMethod("blocklist", entries));
  }

  bool get hasPending => _pending != null;
  bool get busy => recording || processing || _launching;

  /// The desktops that ship a Voice worker and a native gesture bridge:
  /// Windows (native_voice.cpp) and macOS (VoiceBridge.swift). Linux is a
  /// separate port (relic-voice/RELEASE.md).
  static bool get supported => Platform.isWindows || Platform.isMacOS;

  /// The Voice key as this platform names it, for every label that mentions it.
  static String get keyLabel => Platform.isMacOS ? 'Right Option' : 'Right Alt';

  /// The modifier that turns a dictation into a voice note.
  static String get modifierLabel => Platform.isMacOS ? 'Control' : 'Left Ctrl';

  /// How a corrections rule names an app on this platform: the exe on
  /// Windows, the app key (the same one tags use) on a Mac.
  static String get appRuleExample => Platform.isMacOS ? 'chrome' : 'code.exe';

  /// Where the bundled worker lives, relative to the app executable: beside
  /// it on Windows (voice\relic-voice.exe), in Contents/Resources/voice on a
  /// Mac (codesign treats a plain folder under Helpers as nested code and
  /// refuses the Python files inside it; Resources seals them as data).
  /// RELIC_VOICE_WORKER points a dev tree at a bundle built elsewhere.
  static String get workerPath {
    final override = Platform.environment['RELIC_VOICE_WORKER'];
    if (override != null && override.isNotEmpty) return override;
    final sep = Platform.pathSeparator;
    final root = File(Platform.resolvedExecutable).parent.path;
    if (Platform.isMacOS) {
      return '$root$sep..${sep}Resources${sep}voice${sep}relic-voice';
    }
    return '$root${sep}voice${sep}relic-voice.exe';
  }

  /// This install ships a Voice worker: the tour and the offer card only
  /// mention Voice when it is really there.
  static bool get bundled => supported && File(workerPath).existsSync();

  /// macOS refused (or the person refused) microphone access; Voice settings
  /// shows the way to System Settings.
  bool microphoneDenied = false;

  /// True once Voice was offered or explicitly set, so the one-time opt-in
  /// card on first open never comes back.
  bool offered = false;

  /// The opt-in card is due: Windows, never offered, not on, and a Voice
  /// worker is actually installed beside the app.
  bool get offerPending =>
      supported && !enabled && !offered && !_disposed && workerInstalled;

  bool get workerInstalled {
    if (launchProcess != null) return true;
    return File(workerPath).existsSync();
  }

  /// macOS gates the microphone per app: ask once, up front, so the system
  /// prompt lands when Voice is turned on rather than mid-sentence. Windows
  /// answers from the worker at record time instead.
  Future<bool> _microphoneAllowed() async {
    if (!Platform.isMacOS) return true;
    try {
      var state = await _native.invokeMethod<String>('microphone');
      if (state == 'undetermined') {
        final granted = await _native.invokeMethod<bool>('requestMicrophone');
        state = granted == true ? 'authorized' : 'denied';
      }
      microphoneDenied = state == 'denied' || state == 'restricted';
    } catch (_) {
      microphoneDenied = false;
    }
    return !microphoneDenied;
  }

  /// System Settings, Privacy & Security, Microphone.
  Future<void> openMicrophoneSettings() async {
    try {
      await _native.invokeMethod<void>('openMicrophoneSettings');
    } catch (_) {}
  }

  Future<void> acceptOffer() => setEnabled(true);

  Future<void> declineOffer() async {
    offered = true;
    await savePreferences();
  }

  File get _prefs =>
      File('${appDataPath()}${Platform.pathSeparator}voice.json');

  Future<void> initialize() async {
    if (!supported) return;
    // Voice stays off until the person turns it on, from the one-time offer
    // on first open or from Settings. A saved choice always wins.
    enabled = false;
    repo.addListener(_syncBlocklist);
    _syncBlocklist();
    try {
      final j = jsonDecode(await _prefs.readAsString()) as Map<String, dynamic>;
      enabled = j['enabled'] == true;
      offered = j['offered'] == true || j.containsKey('enabled');
      punctuation = j['punctuation'] != false;
      shortcuts = j['shortcuts'] != false;
      device = j['device'] as int?;
      _deviceName = j['device_name'] as String?;
      vocabulary = (j['vocabulary'] as List? ?? [])
          .whereType<String>()
          .take(500)
          .toList();
      corrections = (j['corrections'] as List? ?? [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .take(500)
          .toList();
    } catch (_) {
      /* first use, or damaged preferences */
    }
    _native.setMethodCallHandler((call) async {
      if (call.method == 'event' && call.arguments is Map) {
        await _gesture(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
    if (enabled) await _launch();
    _changed();
  }

  Future<void> savePreferences() {
    if (device == null) {
      _deviceName = null;
    } else if (devices.isNotEmpty) {
      _deviceName = devices
          .where((d) => d['id'] == device)
          .map((d) => d['name'] as String)
          .firstOrNull;
    }
    final payload = jsonEncode({
      'version': 1,
      'enabled': enabled,
      'offered': offered,
      'punctuation': punctuation,
      'shortcuts': shortcuts,
      'device': device,
      'device_name': _deviceName,
      'vocabulary': vocabulary,
      'corrections': corrections,
    });
    final result = _preferenceWrite.catchError((Object _) {}).then((_) async {
      final file = _prefs;
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.partial');
      await temp.writeAsString(payload, flush: true);
      await temp.rename(file.path);
    });
    _preferenceWrite = result;
    return result.then((_) async {
      if (ready && !busy) await _native.invokeMethod('enable', shortcuts);
      _changed();
    });
  }

  Future<void> setEnabled(bool on) async {
    offered = true;
    if (enabled == on && (ready || _launching)) return;
    enabled = on;
    if (on) {
      await savePreferences();
      await _launch();
    } else {
      await _stopWorker();
      status = 'Voice is off';
      await savePreferences();
    }
    _changed();
  }

  Future<void> retry() async {
    await _stopWorker();
    if (enabled) await _launch();
  }

  Future<void> _launch() async {
    if (_launching || _disposed || !enabled) return;
    _launching = true;
    _protocolReady = false;
    final generation = ++_generation;
    status = 'Preparing Voice';
    _changed();
    try {
      final sep = Platform.pathSeparator;
      final exe = workerPath;
      if (launchProcess == null && !File(exe).existsSync()) {
        throw StateError(
          'Voice worker is missing. Install a build that includes Voice.',
        );
      }
      if (!await _microphoneAllowed()) {
        _launching = false;
        if (generation != _generation) return;
        status =
            'Microphone access is off for Relic. Allow it in System Settings, then retry.';
        _changed();
        return;
      }
      final modelDir = '${appDataPath()}${sep}voice-models';
      final process = await (launchProcess ?? Process.start)(exe, [
        '--models',
        modelDir,
      ]);
      if (_disposed || generation != _generation) {
        process.kill();
        return;
      }
      _process = process;
      _output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (generation != _generation || line.length > 262144) return;
            try {
              final message = jsonDecode(line) as Map<String, dynamic>;
              unawaited(_workerEvent(message, generation));
            } catch (_) {
              /* Only versioned JSON is accepted. Never echo native output. */
            }
          });
      _errors = process.stderr.listen(
        (_) {},
      ); // Drain without logging private data.
      unawaited(
        process.exitCode.then((_) async {
          if (_disposed || generation != _generation) return;
          _process = null;
          ready = recording = processing = _launching = false;
          _id = null;
          await _native.invokeMethod('enable', false);
          await _overlay('hidden');
          status = 'Voice stopped. Retry in settings.';
          _changed();
        }),
      );
    } catch (e) {
      _launching = false;
      status = e is StateError
          ? e.message.toString()
          : 'Could not start Voice. Retry in settings.';
      _changed();
    }
  }

  void _send(Map<String, dynamic> message) {
    try {
      _process?.stdin.writeln(jsonEncode(message));
    } catch (_) {
      /* exit handler owns recovery */
    }
  }

  Future<void> _workerEvent(Map<String, dynamic> e, int generation) async {
    if (_disposed || generation != _generation) return;
    final event = e['event'];
    if (event == 'hello') {
      if (e['protocol'] != 1 || e['backend'] != 'cpu') {
        await _stopWorker();
        status = 'Voice worker version is incompatible. Reinstall this build.';
      } else {
        _protocolReady = true;
      }
    } else if (event == 'download') {
      progress = (e['received'] as num) / (e['total'] as num);
      status = 'Downloading Voice models: ${(progress * 100).round()}%';
    } else if (event == 'loading') {
      status = 'Loading Voice models';
    } else if (event == 'ready') {
      if (!_protocolReady || !enabled) return;
      ready = true;
      _launching = false;
      devices = (e['devices'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
      if (_deviceName != null) {
        device = devices
            .where((d) => d['name'] == _deviceName)
            .map((d) => d['id'] as int?)
            .firstOrNull;
      } else if (device != null && !devices.any((d) => d['id'] == device)) {
        device = null;
      }
      await _native.invokeMethod('blocklist', repo.captureBlocklist.toList());
      final registered = await _native.invokeMethod<bool>('enable', shortcuts);
      status = shortcuts && registered != true
          ? 'Voice is ready. Keyboard shortcut unavailable.'
          : 'Ready';
    } else if (event == 'idle') {
      processing = false;
      if (status == 'Canceling') status = 'Ready';
      if (_id == null && !hasPending) await _native.invokeMethod('complete');
    } else if (event == 'error' && (e['id'] == null || e['id'] == _id)) {
      status = e['message'] as String? ?? 'Voice failed. Retry in settings.';
      if (e['id'] == null) {
        ready = false;
        _launching = false;
      }
      await _finish(status);
    } else if (e['id'] == _id && _id != null) {
      if (event == 'audio_started') {
        _audioStarted = true;
        if (_confirmed) await _recordingOverlay();
      } else if (event == 'level') {
        seconds = (e['seconds'] as num).toDouble();
        level = (e['level'] as num).toDouble();
        if (_confirmed && _audioStarted && recording && !processing) {
          await _native.invokeMethod('level', level);
          if (seconds >= 50) await _recordingOverlay();
        }
      } else if (event == 'processing') {
        recording = false;
        processing = true;
        status = 'Transcribing';
        await _native.invokeMethod('processing');
        await _overlay('processing');
      } else if (event == 'result') {
        await _overlay('hidden');
        await _accept(e);
      }
    }
    _changed();
  }

  Future<void> _gesture(Map<String, dynamic> e) async {
    switch (e['event']) {
      case 'candidate':
        if (!ready || processing || hasPending || _id != null) return;
        _id = const Uuid().v4();
        _note = e['note'] == true;
        _app = e['app'] as String? ?? '';
        _practice = _practiceNext;
        _practiceNext = false;
        _capturedAt = DateTime.now();
        _confirmed = _audioStarted = false;
        _latched = false;
        recording = true;
        seconds = level = 0;
        _sessionSettings =
            jsonDecode(
                  jsonEncode({
                    'punctuation': punctuation,
                    'vocabulary': vocabulary,
                    'corrections': corrections,
                  }),
                )
                as Map<String, dynamic>;
        _send({
          'op': 'start',
          'id': _id,
          'device': device,
          'settings': _sessionSettings,
          'app': _note ? '' : _app,
        });
      case 'held':
      case 'latched':
        if (_id == null) return;
        _confirmed = true;
        _latched = e['event'] == 'latched';
        if (_audioStarted) await _recordingOverlay();
      case 'stop':
        await stop();
      case 'cancel':
        await cancel(preserveGesture: e['waiting'] == true);
      case 'blocked':
        await _finish('Dictation is blocked for this app');
    }
    _changed();
  }

  Future<void> start({bool note = false, bool practice = false}) async {
    if (!ready || busy || hasPending) return;
    _practiceNext = practice;
    await _native.invokeMethod('blocklist', repo.captureBlocklist.toList());
    // Tray/practice remains usable with the bare-Alt shortcut switched off.
    if (!shortcuts) await _native.invokeMethod('enable', true);
    await _native.invokeMethod('start', {
      'mode': note ? 'voice_note' : 'dictation',
    });
  }

  Future<void> stop() async {
    if (_id == null || processing) return;
    recording = false;
    processing = true;
    status = 'Transcribing';
    _send({'op': 'stop', 'id': _id});
    await _native.invokeMethod('processing');
    await _overlay('processing');
    _changed();
  }

  Future<void> cancel({bool preserveGesture = false}) async {
    _send({'op': 'cancel', 'id': _id});
    _id = null;
    recording = false;
    _confirmed = _audioStarted = false;
    status = processing ? 'Canceling' : 'Ready';
    if (!preserveGesture) await _native.invokeMethod('complete');
    await _overlay('hidden');
    _changed();
  }

  Future<void> _accept(Map<String, dynamic> e, {bool retry = false}) async {
    // The worker can exit after a disk failure. The pending result owns its
    // stable identity independently of the now-ended recording session.
    final sid = retry ? e['id'] as String? : _id;
    if (sid == null) return;
    lastText = e['text'] as String? ?? '';
    lastRaw = e['raw'] as String? ?? '';
    if (lastText.trim().isEmpty) {
      await _finish('No speech detected');
      return;
    }
    if (_practice) {
      await _finish('Test complete');
      return;
    }
    try {
      final result = repo.captureVoice(
        sessionId: sid,
        text: lastText,
        promote: _note,
        sourceApp: _app.replaceFirst(
          RegExp(r'\.exe$', caseSensitive: false),
          '',
        ),
        metadata: {
          'v': 1,
          'session_id': sid,
          'mode': _note ? 'voice_note' : 'dictation',
          'raw': lastRaw,
          'duration_ms': e['duration_ms'],
          'model': e['model'],
          'captured_at': _capturedAt?.toUtc().toIso8601String(),
          'source_app': _app,
          'applied_rules': e['applied_rules'],
          'settings_version': 1,
        },
      );
      _pending = null;
      final destination = result.relic.promoted ? 'vault' : 'history';
      String insertion = 'skipped';
      if (!_note && !retry && sid == _id) {
        for (var attempt = 0; attempt < 20; attempt++) {
          insertion =
              await _native.invokeMethod<String>('insert', {
                'text': lastText,
              }) ??
              'blocked';
          if (insertion != 'modifiers_held') break;
          await Future<void>.delayed(const Duration(milliseconds: 25));
          if (sid != _id) break;
        }
      }
      var message = 'Saved to $destination';
      if (result.promotionRefused) {
        message = 'Saved to history. Vault full.';
      } else if (!_note && insertion != 'sent') {
        message += '. Copy from Relic.';
      }
      if (e['warning'] != null) message += ' Formatting unavailable.';
      await _finish(message);
    } catch (_) {
      _pending = e;
      recording = processing = false;
      status = 'Could not save. Retry or copy the text in Voice settings.';
      await _overlay('hidden');
      _changed();
    }
  }

  Future<void> retrySave() async {
    final pending = _pending;
    if (pending != null) await _accept(pending, retry: true);
  }

  Future<void> discardPending() async {
    _pending = null;
    await _finish('Discarded');
  }

  Future<void> _recordingOverlay() async {
    status =
        '${_note ? 'Voice note: ' : ''}${_latched ? 'Tap $keyLabel to finish' : 'Release $keyLabel to finish'}';
    if (seconds >= 50) status += ' (${(60 - seconds).ceil()}s)';
    await _overlay('recording');
  }

  Future<void> _overlay(String phase) async {
    if (_disposed) return;
    await _native.invokeMethod('overlay', {'phase': phase});
  }

  Future<void> _finish(String message) async {
    _id = null;
    recording = processing = false;
    status = message;
    await _native.invokeMethod('complete');
    if (!shortcuts) await _native.invokeMethod('enable', false);
    await _overlay('hidden');
    _changed();
  }

  Future<void> shutdown() => _stopWorker();

  Future<void> _stopWorker() async {
    ++_generation;
    _id = null;
    ready = recording = processing = _launching = false;
    await _native.invokeMethod('enable', false);
    await _overlay('hidden');
    final process = _process;
    _process = null;
    await _output?.cancel();
    await _errors?.cancel();
    if (process != null) {
      try {
        process.stdin.writeln('{"op":"shutdown"}');
        await process.stdin.close();
      } catch (_) {}
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        process.kill();
      }
    }
  }

  void _changed() {
    repo.voiceBusy = recording || processing;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (supported) unawaited(_stopWorker());
    repo.removeListener(_syncBlocklist);
    _disposed = true;
    repo.voiceBusy = false;
    if (supported) _native.setMethodCallHandler(null);
    super.dispose();
  }
}

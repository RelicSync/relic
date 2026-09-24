import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/data/voice_controller.dart';

/// A worker process whose stdout the test writes and whose stdin it reads.
class _FakeWorker implements Process {
  final out = StreamController<List<int>>();
  final sent = <Map<String, dynamic>>[];
  final _exit = Completer<int>();
  late final IOSink _in = IOSink(_Sink(sent));

  void emit(Map<String, dynamic> event) =>
      out.add(utf8.encode('${jsonEncode(event)}\n'));

  @override
  Stream<List<int>> get stdout => out.stream;
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  IOSink get stdin => _in;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 1;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) _exit.complete(0);
    return true;
  }
}

class _Sink implements StreamConsumer<List<int>> {
  _Sink(this.sent);
  final List<Map<String, dynamic>> sent;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      for (final line in const LineSplitter().convert(utf8.decode(chunk))) {
        if (line.trim().isNotEmpty) {
          sent.add(jsonDecode(line) as Map<String, dynamic>);
        }
      }
    }
  }

  @override
  Future<void> close() async {}
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('relic/voice');

  Future<void> gesture(Map<String, dynamic> event) async {
    final done = Completer<void>();
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('event', event)),
      (_) => done.complete(),
    );
    await done.future;
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('a double tap latches even when the worker reports idle between taps',
      () async {
    final profile = Platform.environment['RELIC_DATA_DIR'];
    if (!VoiceController.supported ||
        profile == null ||
        profile.toLowerCase().contains('roaming')) {
      markTestSkipped('Requires Windows or macOS and an isolated RELIC_DATA_DIR');
      return;
    }
    final native = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      native.add(call.method);
      return call.method == 'enable' ? true : null;
    });
    addTearDown(() =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final prefs = File('$profile/voice.json');
    await prefs.parent.create(recursive: true);
    await prefs.writeAsString('{"enabled":true}');
    addTearDown(() async {
      if (await prefs.exists()) await prefs.delete();
    });

    final worker = _FakeWorker();
    final repo = LocalDeskRepo();
    final voice = VoiceController(repo, launchProcess: (_, _) async => worker);
    await voice.initialize();
    worker.emit({'event': 'hello', 'protocol': 1, 'backend': 'cpu'});
    worker.emit({'event': 'ready', 'devices': [], 'max_seconds': 600});
    await settle();
    expect(voice.ready, isTrue);
    expect(voice.maxSeconds, 600, reason: 'the worker says how long a take may run');

    // First tap: the key goes down (a take starts) and comes up quickly.
    await gesture({'event': 'candidate', 'note': false, 'app': 'code.exe'});
    await gesture({'event': 'cancel', 'waiting': true});
    expect(worker.sent.map((m) => m['op']), ['start', 'cancel']);

    // The worker answers the cancel before the second tap lands. Its idle
    // report used to reset the native gesture, so the second tap started a
    // brand new first tap and the double tap never latched.
    native.clear();
    worker.emit({'event': 'canceled', 'id': worker.sent.first['id']});
    worker.emit({'event': 'idle'});
    await settle();
    expect(native, isNot(contains('complete')),
        reason: 'the waiting first tap belongs to the key gesture');

    // Second tap latches and records.
    await gesture({'event': 'candidate', 'note': false, 'app': 'code.exe'});
    await gesture({'event': 'latched', 'note': false});
    expect(voice.recording, isTrue);
    expect(worker.sent.last['op'], 'start');

    // A finished take still hands the gesture back.
    final id = worker.sent.last['id'];
    worker.emit({'event': 'processing', 'id': id});
    worker.emit({'event': 'error', 'id': id, 'message': 'Transcription failed.'});
    await settle();
    expect(native, contains('complete'));
    native.clear();
    worker.emit({'event': 'idle'});
    await settle();
    expect(native, contains('complete'),
        reason: 'an idle with no tap waiting still settles the gesture');

    worker.kill();
    voice.dispose();
    repo.dispose();
  });
}

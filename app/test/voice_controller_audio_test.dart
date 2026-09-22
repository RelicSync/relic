import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/data/voice_capture.dart';
import 'package:relic_app/data/voice_controller.dart';
import 'package:relic_app/models/relic.dart';

class FailingRepo extends LocalDeskRepo {
  bool fail = false;
  @override
  VoiceCaptureResult captureVoice({
    required String sessionId,
    required String text,
    required Map<String, dynamic> metadata,
    required bool promote,
    String? sourceApp,
  }) {
    if (fail) throw StateError('Injected disk failure');
    return super.captureVoice(
      sessionId: sessionId,
      text: text,
      metadata: metadata,
      promote: promote,
      sourceApp: sourceApp,
    );
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'human audio: dictate, vault note, cancel, disk retry and insertion order',
    () async {
      final profile = Platform.environment['RELIC_DATA_DIR'];
      final fixture = Platform.environment['RELIC_VOICE_FIXTURE'];
      if (profile == null ||
          fixture == null ||
          profile.toLowerCase().contains('roaming')) {
        markTestSkipped(
          'Requires isolated profile and explicit real human audio fixture',
        );
        return;
      }
      final source = Directory('../relic-voice').absolute;
      final repo = FailingRepo();
      await repo.load();
      repo.setMlEnrich(false);
      final insertions = <String>[];
      final nativeCalls = <String>[];
      final overlayPhases = <String>[];
      final levels = <double>[];
      const channel = MethodChannel('relic/voice');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        nativeCalls.add(call.method);
        if (call.method == 'overlay') {
          final args = call.arguments as Map;
          expect(args.containsKey('status'), isFalse);
          overlayPhases.add(args['phase'] as String);
        }
        if (call.method == 'level') {
          final level = call.arguments as double;
          expect(level.isFinite && level >= 0 && level <= 1, isTrue);
          expect(overlayPhases.last, 'recording');
          levels.add(level);
        }
        if (call.method == 'enable') return true;
        if (call.method == 'insert') {
          final text = (call.arguments as Map)['text'] as String;
          expect(
            repo.all.any((r) => r.content == text),
            isTrue,
            reason: 'Save must commit before insertion',
          );
          insertions.add(text);
          return 'sent';
        }
        return null;
      });
      final voice = VoiceController(
        repo,
        launchProcess: (_, _) => Process.start(
          Platform.isWindows
              ? '${source.path}/.venv/Scripts/python.exe'
              : '${source.path}/.venv/bin/python',
          [
            '${source.path}/protocol_fixture.py',
            '--models',
            '${source.path}/test-output/r2-models',
            '--audio',
            fixture,
          ],
        ),
      );
      await voice.initialize();
      addTearDown(() async {
        await voice.shutdown();
        voice.dispose();
        repo.dispose();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      });
      Future<void> until(bool Function() predicate) async {
        final end = DateTime.now().add(const Duration(seconds: 30));
        while (!predicate()) {
          if (DateTime.now().isAfter(end)) fail('Timed out: ${voice.status}');
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      Future<void> gesture(String event, {bool note = false}) async {
        final complete = Completer<void>();
        binding.defaultBinaryMessenger.handlePlatformMessage(
          'relic/voice',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('event', {
              'event': event,
              'note': note,
              'app': 'notepad.exe',
            }),
          ),
          (_) => complete.complete(),
        );
        await complete.future;
      }

      Future<void> record({bool note = false}) async {
        await gesture('candidate', note: note);
        await gesture('held', note: note);
        await until(() => voice.level > 0);
        await voice.stop();
      }

      expect(voice.enabled, isTrue);
      await until(() => voice.ready);
      await record();
      await until(() => voice.status.startsWith('Saved'));
      final dictated = repo.all.firstWhere(
        (r) =>
            r.source == Source.voice &&
            (r.content ?? '').toLowerCase().contains('mister quilter'),
      );
      expect(dictated.promoted, isFalse);
      expect(dictated.content!.toLowerCase(), contains('mister quilter'));
      expect(insertions, [dictated.content]);
      expect(dictated.voice?['raw'], isNotEmpty);
      expect(
        overlayPhases,
        containsAllInOrder(['recording', 'processing', 'hidden']),
      );
      expect(overlayPhases.last, 'hidden');
      expect(levels.any((v) => v > 0), isTrue);
      await record(note: true);
      await until(() => voice.status == 'Saved to vault');
      expect(
        repo.all
            .where(
              (r) => r.source == Source.voice && r.content == dictated.content,
            )
            .length,
        2,
      );
      expect(
        repo.all
            .where(
              (r) =>
                  r.source == Source.voice &&
                  r.promoted &&
                  r.content == dictated.content,
            )
            .length,
        1,
      );
      expect(insertions.length, 1);
      await record();
      await voice.cancel();
      await until(() => !voice.processing);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        repo.all
            .where(
              (r) => r.source == Source.voice && r.content == dictated.content,
            )
            .length,
        2,
      );
      expect(insertions.length, 1);
      repo.fail = true;
      await record();
      await until(() => voice.hasPending);
      expect(insertions.length, 1);
      // A worker exit must not strand a transcript that failed to save.
      await voice.shutdown();
      repo.fail = false;
      await voice.retrySave();
      expect(voice.hasPending, isFalse);
      expect(
        repo.all
            .where(
              (r) => r.source == Source.voice && r.content == dictated.content,
            )
            .length,
        3,
      );
      expect(
        insertions.length,
        1,
        reason: 'A recovered save must not insert into a stale target',
      );
      expect(nativeCalls, contains('complete'));
      expect(overlayPhases.last, 'hidden');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/data/voice_controller.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Desktop leaves Voice off until it is offered or explicitly turned on',
    () async {
      final profile = Platform.environment['RELIC_DATA_DIR'];
      if (!VoiceController.supported ||
          profile == null ||
          profile.toLowerCase().contains('roaming')) {
        markTestSkipped(
          'Requires Windows or macOS and an isolated RELIC_DATA_DIR',
        );
        return;
      }
      const channel = MethodChannel('relic/voice');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => null,
      );
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final prefs = File('$profile/voice.json');
      await prefs.parent.create(recursive: true);
      // (payload, enabled after initialize, opt-in card due)
      const cases = <(String?, bool, bool)>[
        (null, false, true), // fresh install: off, offer it
        ('{}', false, true), // damaged or empty prefs: same
        ('{"enabled":true}', true, false), // turned on before
        ('{"enabled":false}', false, false), // turned off before: never nag
        ('{"offered":true}', false, false), // declined the card once
      ];
      for (final (payload, expectedEnabled, expectedOffer) in cases) {
        if (await prefs.exists()) await prefs.delete();
        if (payload != null) await prefs.writeAsString(payload);
        var launches = 0;
        final repo = LocalDeskRepo();
        final voice = VoiceController(
          repo,
          launchProcess: (_, _) async {
            launches++;
            throw StateError('Fixture stops before process launch');
          },
        );
        await voice.initialize();
        expect(voice.enabled, expectedEnabled, reason: '$payload');
        expect(voice.offerPending, expectedOffer, reason: '$payload');
        expect(launches, expectedEnabled ? 1 : 0, reason: '$payload');
        if (expectedOffer) {
          // Declining is remembered and never launches the worker.
          await voice.declineOffer();
          expect(voice.offerPending, isFalse);
          expect(voice.enabled, isFalse);
          expect(launches, 0);
          expect(await prefs.readAsString(), contains('"offered":true'));
        }
        await voice.shutdown();
        voice.dispose();
        repo.dispose();
      }
      // Accepting the card turns Voice on, launches, and is remembered.
      if (await prefs.exists()) await prefs.delete();
      var launches = 0;
      final repo = LocalDeskRepo();
      final voice = VoiceController(
        repo,
        launchProcess: (_, _) async {
          launches++;
          throw StateError('Fixture stops before process launch');
        },
      );
      await voice.initialize();
      expect(voice.offerPending, isTrue);
      await voice.acceptOffer();
      expect(voice.enabled, isTrue);
      expect(voice.offerPending, isFalse);
      expect(launches, 1);
      final saved = await prefs.readAsString();
      expect(saved, contains('"enabled":true'));
      expect(saved, contains('"offered":true'));
      await voice.shutdown();
      voice.dispose();
      repo.dispose();
      await prefs.delete();
    },
  );
}

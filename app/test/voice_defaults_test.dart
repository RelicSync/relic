import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/data/voice_controller.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Windows prepares Voice on first install and upgrade, preserving explicit opt-out',
    () async {
      final profile = Platform.environment['RELIC_DATA_DIR'];
      if (!Platform.isWindows ||
          profile == null ||
          profile.toLowerCase().contains('roaming')) {
        markTestSkipped('Requires Windows and an isolated RELIC_DATA_DIR');
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
      for (final payload in <String?>[
        null,
        '{}',
        '{"enabled":true}',
        '{"enabled":false}',
      ]) {
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
        final expected = payload != '{"enabled":false}';
        expect(voice.enabled, expected);
        expect(launches, expected ? 1 : 0);
        if (!expected) {
          await voice.savePreferences();
          expect(await prefs.readAsString(), contains('"enabled":false'));
        }
        await voice.shutdown();
        voice.dispose();
        repo.dispose();
      }
      await prefs.delete();
    },
  );
}

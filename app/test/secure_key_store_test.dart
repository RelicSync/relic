import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/secure_key_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('forPlatform picks the OS-native store', () {
    final s = SecureKeyStore.forPlatform();
    if (Platform.isWindows) {
      expect(s, isA<WindowsKeyStore>());
    } else if (Platform.isLinux) {
      expect(s, isA<LinuxKeyStore>());
    } else if (Platform.isMacOS) {
      expect(s, isA<KeychainKeyStore>());
    }
  });

  // In flutter_test no platform channels are registered, so every libsecret
  // call throws — the same shape as a session with no Secret Service daemon
  // on the bus (WSL, CI, bare X). These run the fallback path for real, on
  // every host OS.
  group('LinuxKeyStore with no Secret Service daemon', () {
    test('master key round-trips via the in-memory fallback', () async {
      final s = LinuxKeyStore();
      final mk = Uint8List.fromList(List.generate(32, (i) => i));
      await s.putMasterKey('scope-a', mk);
      expect(await s.getMasterKey('scope-a'), mk);
      expect(await s.getMasterKey('scope-b'), isNull);
      await s.deleteMasterKey('scope-a');
      expect(await s.getMasterKey('scope-a'), isNull);
    });

    test('refresh token round-trips via the in-memory fallback', () async {
      final s = LinuxKeyStore();
      await s.putRefreshToken('scope-a', 'tok-1');
      expect(await s.getRefreshToken('scope-a'), 'tok-1');
      await s.deleteRefreshToken('scope-a');
      expect(await s.getRefreshToken('scope-a'), isNull);
    });

    test('backup key round-trips via the in-memory fallback', () async {
      final s = LinuxKeyStore();
      final bk = Uint8List.fromList(List.generate(32, (i) => 255 - i));
      await s.putBackupKey(bk);
      expect(await s.getBackupKey(), bk);
      await s.deleteBackupKey();
      expect(await s.getBackupKey(), isNull);
    });
  });
}

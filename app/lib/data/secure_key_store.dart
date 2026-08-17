import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hashlib/hashlib.dart';

import 'secure_store.dart';

/// Cross-platform OS-backed storage for the two onboarding secrets, kept in
/// distinct slots and never merged (docs/cloudflare/13-device-onboarding.md §0):
///
///   - `relic.vault.mk:<scope>`        the unwrapped 32-byte master key (crypto)
///   - `relic.session.refresh:<scope>` the long-lived refresh token (auth)
///
/// It stores the **unwrapped master key**, never the passphrase. This replaces
/// the old mobile behavior of persisting the cleartext passphrase and re-running
/// Argon2 on every launch.
abstract class SecureKeyStore {
  Future<void> putMasterKey(String scope, Uint8List mk);
  Future<Uint8List?> getMasterKey(String scope);
  Future<void> deleteMasterKey(String scope);

  Future<void> putRefreshToken(String scope, String token);
  Future<String?> getRefreshToken(String scope);
  Future<void> deleteRefreshToken(String scope);

  /// The local sealed-backup key (BK), one per install — deliberately NOT
  /// account-scoped: backups cover the whole local vault, account or not.
  /// Holding the unwrapped BK here is what lets scheduled backups run without
  /// prompting for the backup passphrase (mirrors the master-key posture).
  Future<void> putBackupKey(Uint8List bk);
  Future<Uint8List?> getBackupKey();
  Future<void> deleteBackupKey();

  /// A stable per-account namespace, matching `WindowsSecureStore.syncScope`'s
  /// scheme so existing Windows entries resolve unchanged.
  static String scopeFor(String baseUrl, String accountId) =>
      sha256sum('$baseUrl\n$accountId', utf8).substring(0, 32);

  static String mkSlot(String scope) => 'relic.vault.mk:$scope';
  static String refreshSlot(String scope) => 'relic.session.refresh:$scope';
  static const backupKeySlot = 'relic.backup.bk';

  /// The right implementation for the running platform. Windows → DPAPI
  /// (Credential Manager); iOS/macOS/Android → Keychain/Keystore; Linux →
  /// Secret Service (libsecret) with an in-memory fallback; everything else
  /// (web, tests) → in-memory.
  static SecureKeyStore forPlatform() {
    if (Platform.isWindows) return WindowsKeyStore();
    if (Platform.isIOS || Platform.isMacOS || Platform.isAndroid) {
      return KeychainKeyStore();
    }
    if (Platform.isLinux) return LinuxKeyStore();
    return MemoryKeyStore();
  }
}

/// Windows: thin adapter over the existing DPAPI [WindowsSecureStore]. Reuses
/// the same `sync-master-key:<scope>` slot the desktop already writes, so no
/// migration is needed on Windows.
class WindowsKeyStore implements SecureKeyStore {
  @override
  Future<void> putMasterKey(String scope, Uint8List mk) async =>
      WindowsSecureStore.writeBytes(
          WindowsSecureStore.syncMasterKeyName(scope), mk);
  @override
  Future<Uint8List?> getMasterKey(String scope) async =>
      WindowsSecureStore.readBytes(WindowsSecureStore.syncMasterKeyName(scope));
  @override
  Future<void> deleteMasterKey(String scope) async =>
      WindowsSecureStore.delete(WindowsSecureStore.syncMasterKeyName(scope));

  @override
  Future<void> putRefreshToken(String scope, String token) async =>
      WindowsSecureStore.writeString(
          WindowsSecureStore.syncDeviceTokenName(scope), token);
  @override
  Future<String?> getRefreshToken(String scope) async =>
      WindowsSecureStore.readString(
          WindowsSecureStore.syncDeviceTokenName(scope));
  @override
  Future<void> deleteRefreshToken(String scope) async =>
      WindowsSecureStore.delete(WindowsSecureStore.syncDeviceTokenName(scope));

  @override
  Future<void> putBackupKey(Uint8List bk) async =>
      WindowsSecureStore.writeBytes(SecureKeyStore.backupKeySlot, bk);
  @override
  Future<Uint8List?> getBackupKey() async =>
      WindowsSecureStore.readBytes(SecureKeyStore.backupKeySlot);
  @override
  Future<void> deleteBackupKey() async =>
      WindowsSecureStore.delete(SecureKeyStore.backupKeySlot);
}

/// iOS / macOS / Android: Keychain / Keystore via flutter_secure_storage. The MK
/// is base64 in a Keychain item accessible after first unlock (survives reboot,
/// not synced off-device); Android uses Keystore-backed EncryptedSharedPreferences.
class KeychainKeyStore implements SecureKeyStore {
  // Android uses Keystore-backed ciphers by default now (the old
  // EncryptedSharedPreferences flag is deprecated and auto-migrated). iOS/macOS
  // pin the item to "after first unlock, this device only".
  static const _s = FlutterSecureStorage(
    iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device),
    mOptions: MacOsOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  @override
  Future<void> putMasterKey(String scope, Uint8List mk) =>
      _s.write(key: SecureKeyStore.mkSlot(scope), value: base64.encode(mk));
  @override
  Future<Uint8List?> getMasterKey(String scope) async {
    final v = await _s.read(key: SecureKeyStore.mkSlot(scope));
    if (v == null) return null;
    try {
      return Uint8List.fromList(base64.decode(v));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> deleteMasterKey(String scope) =>
      _s.delete(key: SecureKeyStore.mkSlot(scope));

  @override
  Future<void> putRefreshToken(String scope, String token) =>
      _s.write(key: SecureKeyStore.refreshSlot(scope), value: token);
  @override
  Future<String?> getRefreshToken(String scope) =>
      _s.read(key: SecureKeyStore.refreshSlot(scope));
  @override
  Future<void> deleteRefreshToken(String scope) =>
      _s.delete(key: SecureKeyStore.refreshSlot(scope));

  @override
  Future<void> putBackupKey(Uint8List bk) =>
      _s.write(key: SecureKeyStore.backupKeySlot, value: base64.encode(bk));
  @override
  Future<Uint8List?> getBackupKey() async {
    final v = await _s.read(key: SecureKeyStore.backupKeySlot);
    if (v == null) return null;
    try {
      return Uint8List.fromList(base64.decode(v));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> deleteBackupKey() =>
      _s.delete(key: SecureKeyStore.backupKeySlot);
}

/// Linux: Secret Service (libsecret) via flutter_secure_storage — any
/// provider works (GNOME Keyring, KWallet's Secret Service bridge). Sessions
/// with no daemon on the bus (WSL, CI, bare X) make every libsecret call
/// throw; each call then falls back to a private [MemoryKeyStore], degrading
/// to passphrase-per-launch instead of breaking sign-in outright.
class LinuxKeyStore implements SecureKeyStore {
  static const _s = FlutterSecureStorage();
  final MemoryKeyStore _fallback = MemoryKeyStore();

  Future<Uint8List?> _readBytes(
      String key, Future<Uint8List?> Function() fallback) async {
    String? v;
    try {
      v = await _s.read(key: key);
    } catch (_) {
      return fallback();
    }
    if (v == null) return null;
    try {
      return Uint8List.fromList(base64.decode(v));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> putMasterKey(String scope, Uint8List mk) async {
    try {
      await _s.write(
          key: SecureKeyStore.mkSlot(scope), value: base64.encode(mk));
    } catch (_) {
      await _fallback.putMasterKey(scope, mk);
    }
  }

  @override
  Future<Uint8List?> getMasterKey(String scope) => _readBytes(
      SecureKeyStore.mkSlot(scope), () => _fallback.getMasterKey(scope));

  @override
  Future<void> deleteMasterKey(String scope) async {
    try {
      await _s.delete(key: SecureKeyStore.mkSlot(scope));
    } catch (_) {}
    await _fallback.deleteMasterKey(scope);
  }

  @override
  Future<void> putRefreshToken(String scope, String token) async {
    try {
      await _s.write(key: SecureKeyStore.refreshSlot(scope), value: token);
    } catch (_) {
      await _fallback.putRefreshToken(scope, token);
    }
  }

  @override
  Future<String?> getRefreshToken(String scope) async {
    try {
      return await _s.read(key: SecureKeyStore.refreshSlot(scope));
    } catch (_) {
      return _fallback.getRefreshToken(scope);
    }
  }

  @override
  Future<void> deleteRefreshToken(String scope) async {
    try {
      await _s.delete(key: SecureKeyStore.refreshSlot(scope));
    } catch (_) {}
    await _fallback.deleteRefreshToken(scope);
  }

  @override
  Future<void> putBackupKey(Uint8List bk) async {
    try {
      await _s.write(
          key: SecureKeyStore.backupKeySlot, value: base64.encode(bk));
    } catch (_) {
      await _fallback.putBackupKey(bk);
    }
  }

  @override
  Future<Uint8List?> getBackupKey() =>
      _readBytes(SecureKeyStore.backupKeySlot, () => _fallback.getBackupKey());

  @override
  Future<void> deleteBackupKey() async {
    try {
      await _s.delete(key: SecureKeyStore.backupKeySlot);
    } catch (_) {}
    await _fallback.deleteBackupKey();
  }
}

/// Web / tests — and [LinuxKeyStore]'s daemonless fallback: RAM only. Nothing
/// is persisted, so the passphrase is re-entered each session (doc 13 §2 web
/// caveat). Never persists secrets.
class MemoryKeyStore implements SecureKeyStore {
  final Map<String, Uint8List> _mk = {};
  final Map<String, String> _refresh = {};

  @override
  Future<void> putMasterKey(String scope, Uint8List mk) async =>
      _mk[scope] = Uint8List.fromList(mk);
  @override
  Future<Uint8List?> getMasterKey(String scope) async => _mk[scope];
  @override
  Future<void> deleteMasterKey(String scope) async => _mk.remove(scope);

  @override
  Future<void> putRefreshToken(String scope, String token) async =>
      _refresh[scope] = token;
  @override
  Future<String?> getRefreshToken(String scope) async => _refresh[scope];
  @override
  Future<void> deleteRefreshToken(String scope) async => _refresh.remove(scope);

  Uint8List? _bkSlot;
  @override
  Future<void> putBackupKey(Uint8List bk) async =>
      _bkSlot = Uint8List.fromList(bk);
  @override
  Future<Uint8List?> getBackupKey() async => _bkSlot;
  @override
  Future<void> deleteBackupKey() async => _bkSlot = null;
}

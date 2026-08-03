import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:hashlib/hashlib.dart';
import 'package:win32/win32.dart';

/// Small Windows Credential Manager wrapper for sync secrets.
///
/// Generic credentials are DPAPI-protected by Windows for the current user.
/// Relic only stores small values here: the unwrapped 32-byte master key and
/// the bearer device token used for auto-reconnect.
class WindowsSecureStore {
  WindowsSecureStore._();

  static String syncScope(String baseUrl, String token) =>
      sha256sum('$baseUrl\n$token', utf8).substring(0, 32);

  static String syncMasterKeyName(String scope) => 'sync-master-key:$scope';
  static String syncDeviceTokenName(String scope) => 'sync-device-token:$scope';

  static String _target(String name) {
    // A sandboxed instance (RELIC_DATA_DIR set) namespaces its Credential Manager
    // entries so it can never read or overwrite the real vault's keys/tokens.
    final portable = Platform.environment['RELIC_DATA_DIR'];
    final prefix =
        (portable != null && portable.isNotEmpty) ? 'Relic-test' : 'Relic';
    return '$prefix:$name';
  }

  static bool writeBytes(String name, List<int> bytes) {
    if (!Platform.isWindows || bytes.isEmpty) return false;
    final target = _target(name).toNativeUtf16();
    final user = 'Relic'.toNativeUtf16();
    final blob = calloc<Uint8>(bytes.length);
    final cred = calloc<CREDENTIAL>();
    try {
      blob.asTypedList(bytes.length).setAll(0, bytes);
      cred.ref
        ..Type = CRED_TYPE_GENERIC
        ..TargetName = target
        ..CredentialBlobSize = bytes.length
        ..CredentialBlob = blob
        ..Persist = CRED_PERSIST_LOCAL_MACHINE
        ..UserName = user;
      return CredWrite(cred, 0) != 0;
    } catch (_) {
      return false;
    } finally {
      calloc.free(cred);
      calloc.free(blob);
      calloc.free(user);
      calloc.free(target);
    }
  }

  static Uint8List? readBytes(String name) {
    if (!Platform.isWindows) return null;
    final target = _target(name).toNativeUtf16();
    final out = calloc<Pointer<CREDENTIAL>>();
    try {
      if (CredRead(target, CRED_TYPE_GENERIC, 0, out) == 0) return null;
      final cred = out.value;
      if (cred == nullptr || cred.ref.CredentialBlob == nullptr) return null;
      return Uint8List.fromList(
        cred.ref.CredentialBlob.asTypedList(cred.ref.CredentialBlobSize),
      );
    } catch (_) {
      return null;
    } finally {
      if (out.value != nullptr) CredFree(out.value.cast());
      calloc.free(out);
      calloc.free(target);
    }
  }

  static bool writeString(String name, String value) =>
      writeBytes(name, utf8.encode(value));

  static String? readString(String name) {
    final bytes = readBytes(name);
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  static bool delete(String name) {
    if (!Platform.isWindows) return false;
    final target = _target(name).toNativeUtf16();
    try {
      final r = CredDelete(target, CRED_TYPE_GENERIC, 0);
      return r != 0 || GetLastError() == ERROR_NOT_FOUND;
    } catch (_) {
      return false;
    } finally {
      calloc.free(target);
    }
  }
}

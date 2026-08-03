import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// The Relic backend Worker origin (relic.space is the website; the API lives
/// on its own subdomain).
const String kWorkerBaseUrl = 'https://api.relic.space';

/// A stable per-install device id (UUID), generated once and persisted. Sent as
/// the `X-Relic-Device` header so the backend can list this device and honor a
/// remote remove. Not secret — it only labels the device; it never unlocks data.
class DeviceId {
  static const _key = 'relic.device.id';
  static const _store = FlutterSecureStorage();
  static String? _cached;

  static Future<String> get() async {
    if (_cached != null) return _cached!;
    var id = await _store.read(key: _key);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await _store.write(key: _key, value: id);
    }
    return _cached = id;
  }

  /// The OS platform tag stored alongside the device in the registry.
  static String platform() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }
}

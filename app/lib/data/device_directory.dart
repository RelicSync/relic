import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// One entry in the account's device list (`GET /account/devices`).
class DeviceEntry {
  final String deviceId;
  final String label;
  final String platform;
  final int? lastSeenAt; // epoch seconds
  final String? appVersion; // last version the device reported; null = unknown
  final bool thisDevice;
  const DeviceEntry({
    required this.deviceId,
    required this.label,
    required this.platform,
    this.lastSeenAt,
    this.appVersion,
    this.thisDevice = false,
  });

  factory DeviceEntry.fromJson(Map<String, dynamic> j) => DeviceEntry(
        deviceId: j['device_id'] as String,
        label: (j['label'] as String?) ?? 'Device',
        platform: (j['platform'] as String?) ?? '',
        lastSeenAt: (j['last_seen_at'] as num?)?.toInt(),
        appVersion: j['app_version'] as String?,
        thisDevice: j['this_device'] == true,
      );
}

/// Compare dotted version strings by numeric segment ("1.0.9" < "1.0.13").
/// Build/pre-release suffixes are stripped at the first character outside
/// [0-9.], so "1.0.13+14" compares as "1.0.13". Returns <0, 0, >0.
int compareVersions(String a, String b) {
  List<int> parse(String v) {
    final m = RegExp(r'^[0-9.]*').firstMatch(v)!.group(0)!;
    return [
      for (final s in m.split('.'))
        if (s.isNotEmpty) int.parse(s),
    ];
  }

  final pa = parse(a), pb = parse(b);
  for (var i = 0; i < pa.length || i < pb.length; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x - y;
  }
  return 0;
}

/// Raised when registering a new device would exceed the tier's device cap; the
/// backend hands back the current list so the UI can offer remove-or-upgrade.
class DeviceCapException implements Exception {
  final List<DeviceEntry> devices;
  const DeviceCapException(this.devices);
  @override
  String toString() => 'DeviceCapException(${devices.length} devices)';
}

/// Client for the device registry (`/account/devices`). Backs the settings
/// "your devices" list + remote remove, and registers this device on connect.
class DeviceDirectory {
  final String baseUrl;
  final Future<String?> Function() bearer;
  final String deviceId;
  final String? appVersion; // this install's version, reported on register
  const DeviceDirectory({
    required this.baseUrl,
    required this.bearer,
    required this.deviceId,
    this.appVersion,
  });

  // Resolved once per process from PackageInfo when the constructor didn't
  // supply one, so the existing factories don't all need threading. Fails
  // soft (null) in tests where the platform channel is absent.
  static String? _ownVersion;
  static bool _ownVersionTried = false;
  Future<String?> _version() async {
    if (appVersion case final v? when v.isNotEmpty) return v;
    if (!_ownVersionTried) {
      _ownVersionTried = true;
      try {
        _ownVersion = (await PackageInfo.fromPlatform()).version;
      } catch (_) {}
    }
    return _ownVersion;
  }

  Future<Map<String, String>> _headers({bool json = false}) async {
    final t = await bearer();
    final v = await _version();
    return {
      if (t != null && t.isNotEmpty) 'Authorization': 'Bearer $t',
      'X-Relic-Device': deviceId,
      if (v != null && v.isNotEmpty) 'X-Relic-App-Version': v,
      if (json) 'Content-Type': 'application/json',
    };
  }

  /// Register/refresh this device. Throws [DeviceCapException] on a 409.
  Future<void> register({required String label, required String platform}) async {
    final v = await _version();
    final r = await http.post(Uri.parse('$baseUrl/account/devices'),
        headers: await _headers(json: true),
        body: jsonEncode({
          'device_id': deviceId,
          'label': label,
          'platform': platform,
          if (v != null && v.isNotEmpty) 'app_version': v,
        }));
    if (r.statusCode == 409) {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      throw DeviceCapException(_parse(j['devices']));
    }
    if (r.statusCode != 200) {
      throw Exception('device register failed (${r.statusCode})');
    }
  }

  Future<List<DeviceEntry>> list() async {
    final r = await http.get(Uri.parse('$baseUrl/account/devices'),
        headers: await _headers());
    if (r.statusCode != 200) return const [];
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return _parse(j['devices']);
  }

  Future<void> remove(String id) async {
    await http.delete(Uri.parse('$baseUrl/account/devices/$id'),
        headers: await _headers());
  }

  /// Rename a device (PATCH /account/devices/:id {label}). Throws on failure so
  /// the rename dialog can surface it rather than silently no-op.
  Future<void> rename(String id, String label) async {
    final r = await http.patch(Uri.parse('$baseUrl/account/devices/$id'),
        headers: await _headers(json: true),
        body: jsonEncode({'label': label}));
    if (r.statusCode != 200) {
      throw Exception('device rename failed (${r.statusCode})');
    }
  }

  static List<DeviceEntry> _parse(dynamic devices) => (devices as List? ?? [])
      .map((d) => DeviceEntry.fromJson(d as Map<String, dynamic>))
      .toList();
}

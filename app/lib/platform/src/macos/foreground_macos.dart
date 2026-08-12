import 'package:flutter/services.dart';

/// macOS backend of platform/foreground_app.dart and platform/running_apps.dart:
/// a thin client over the `relic/frontmost` MethodChannel implemented by
/// macos/Runner/Bridge/ForegroundAppBridge.swift (NSWorkspace). No special
/// permission required.

const _ch = MethodChannel('relic/frontmost');

/// An app as macOS reports it: [bundleId] is the identity ("com.google.Chrome"),
/// [name] its localized name ("Google Chrome"), empty when macOS has none.
typedef MacApp = ({String bundleId, String name});

/// The frontmost application, or null when it can't be determined.
Future<MacApp?> frontmostApp() async {
  try {
    return _appOf(await _ch.invokeMapMethod<String, String>('frontmost'));
  } catch (_) {
    return null;
  }
}

/// The applications with a Dock presence right now (activation policy
/// `.regular`), for the capture-blocklist picker. Empty on any failure.
Future<List<MacApp>> runningMacApps() async {
  try {
    final rows = await _ch.invokeListMethod<Object?>('runningApps') ?? const [];
    return rows
        .map((r) => _appOf((r as Map?)?.cast<String, Object?>()))
        .nonNulls
        .toList();
  } catch (_) {
    return const [];
  }
}

MacApp? _appOf(Map<String, Object?>? m) {
  final id = m?['bundleId'] as String?;
  if (id == null || id.isEmpty) return null;
  return (bundleId: id, name: (m?['name'] as String?) ?? '');
}

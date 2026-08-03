import 'package:flutter/services.dart';

/// macOS backend of platform/foreground_app.dart: a thin client over the
/// `relic/frontmost` MethodChannel implemented by
/// macos/Runner/Bridge/ForegroundAppBridge.swift
/// (NSWorkspace.frontmostApplication). No special permission required.

const _ch = MethodChannel('relic/frontmost');

/// The frontmost application's bundle identifier ("com.google.Chrome"), or
/// null when it can't be determined.
Future<String?> frontmostBundleId() async {
  try {
    final r = await _ch.invokeMethod<String>('bundleId');
    return (r == null || r.isEmpty) ? null : r;
  } catch (_) {
    return null;
  }
}

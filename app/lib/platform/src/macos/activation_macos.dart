import 'package:flutter/services.dart';

/// macOS backend of platform/app_activation.dart: a thin client over the
/// `relic/activate` MethodChannel implemented by
/// macos/Runner/Bridge/ActivationBridge.swift, which calls
/// NSApp.activate(ignoringOtherApps: true) — the only activation an
/// LSUIElement agent can use to take the foreground from another app.

const _ch = MethodChannel('relic/activate');

/// Best-effort; false when the channel is missing (e.g. stale native build).
Future<bool> activateApp() async {
  try {
    return await _ch.invokeMethod<bool>('activate') ?? false;
  } catch (_) {
    return false;
  }
}

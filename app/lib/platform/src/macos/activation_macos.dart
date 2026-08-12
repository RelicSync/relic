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

/// Put the window on screen. [activate] false is the popup: the window takes
/// key (so typing lands in the search box) while the app the user came from
/// keeps the foreground. True is settings/onboarding, which take the
/// foreground for real. See macos/Runner/MainFlutterWindow.swift.
Future<bool> presentWindow({required bool activate}) async {
  try {
    return await _ch.invokeMethod<bool>('present', {'activate': activate}) ??
        false;
  } catch (_) {
    return false;
  }
}

/// Take the window off screen, handing the foreground back to the previous app
/// when we hold it.
Future<bool> dismissWindow() async {
  try {
    return await _ch.invokeMethod<bool>('dismiss') ?? false;
  } catch (_) {
    return false;
  }
}

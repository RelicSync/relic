import 'package:flutter/services.dart';

/// macOS backend of platform/login_item.dart: a thin client over the
/// `relic/login_item` MethodChannel implemented by
/// macos/Runner/Bridge/LoginItemBridge.swift (SMAppService.mainApp) — the
/// macOS analog of the HKCU Run key.

const _ch = MethodChannel('relic/login_item');

/// Register/unregister the app as a login item. Returns whether it stuck.
Future<bool> setEnabled(bool enable) async {
  try {
    return await _ch.invokeMethod<bool>('set', {'enable': enable}) ?? false;
  } catch (_) {
    return false;
  }
}

/// Whether the login item is currently registered.
Future<bool> isEnabled() async {
  try {
    return await _ch.invokeMethod<bool>('get') ?? false;
  } catch (_) {
    return false;
  }
}

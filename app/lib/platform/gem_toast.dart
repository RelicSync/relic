import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Relic's small transparent gem flourish, drawn by a native overlay window
/// (a layered Win32 window today; an NSPanel on macOS later — see
/// docs/macos-port.md Phase 7). This bypasses Flutter's transparent-window
/// path, which ghosts on some Windows systems.
///
/// Contract: returns false whenever the native side can't show it (channel
/// unregistered, non-desktop platform) and the caller falls back to a normal
/// OS notification — so shipping macOS without GemToastPanel.swift is safe.

const _nativeToast = MethodChannel('relic/native_toast');

Future<bool> showNativeGemToast() async {
  // Deliberate allowlist: Linux stays on the local_notifier fallback for good
  // (a GTK layer-shell overlay isn't worth a per-compositor fight).
  if (!Platform.isWindows && !Platform.isMacOS) return false;
  try {
    return await _nativeToast.invokeMethod<bool>('showGemToast') ?? true;
  } catch (_) {
    return false;
  }
}

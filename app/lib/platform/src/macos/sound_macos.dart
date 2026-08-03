import 'package:flutter/services.dart';

/// macOS backend of platform/sound.dart: a thin client over the `relic/sound`
/// MethodChannel implemented by macos/Runner/Bridge/SoundBridge.swift, which
/// resolves the Flutter asset inside the app bundle
/// (FlutterDartProject.lookupKey) and plays it with NSSound.

const _ch = MethodChannel('relic/sound');

/// Play a bundled Flutter asset ("assets/sounds/relic-sound.wav").
/// Best-effort; false when the channel or asset is missing.
Future<bool> playAsset(String asset) async {
  try {
    return await _ch.invokeMethod<bool>('play', {'asset': asset}) ?? false;
  } catch (_) {
    return false;
  }
}

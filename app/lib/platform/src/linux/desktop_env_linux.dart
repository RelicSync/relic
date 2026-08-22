import 'package:flutter/services.dart';

/// Facts about the running Linux desktop that dart:io cannot see, answered by
/// linux/runner/desktop_env.cc over a MethodChannel.

const MethodChannel _channel = MethodChannel('relic/desktop_env');

/// Whether anything on the session bus is listening for tray icons
/// (a StatusNotifierWatcher). False on stock GNOME, which has shipped no
/// system tray since 3.26.
///
/// True on any failure — a missing channel (tests) or a refused call must never
/// make Relic claim a tray is absent when it is not.
Future<bool> hasTrayHost() async {
  try {
    return await _channel.invokeMethod<bool>('hasTrayHost') ?? true;
  } catch (_) {
    return true;
  }
}

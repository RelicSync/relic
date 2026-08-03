import 'dart:io';

import 'package:flutter/services.dart';

/// Dart side of `SaveChannel.kt` — writes bytes into the device's real, public
/// Downloads collection via MediaStore.
///
/// Only meaningful on Android; every entry point is a no-op/false elsewhere so
/// callers don't need their own platform guards.
class AndroidSave {
  static const _ch = MethodChannel('relic/save');

  static bool? _available;

  /// Whether a public-Downloads write is possible here (Android 10+). Cached —
  /// the answer can't change while the process is alive.
  static Future<bool> available() async {
    if (!Platform.isAndroid) return false;
    final cached = _available;
    if (cached != null) return cached;
    bool ok;
    try {
      ok = await _ch.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      ok = false; // channel missing (old build / hot-reload race)
    }
    _available = ok;
    return ok;
  }

  /// Copy the decrypted file at [sourcePath] into public Downloads as [name].
  /// Returns the user-facing location ("Download/report.pdf"), with whatever
  /// name MediaStore settled on after de-duplication. Throws [SaveFailure] with
  /// a readable message.
  ///
  /// Takes a path rather than bytes on purpose — the native side streams it, so
  /// a 100 MB relic never has to exist as a buffer on either side of the channel.
  static Future<String> saveToDownloads({
    required String name,
    required String sourcePath,
    required String mime,
  }) async {
    try {
      final where = await _ch.invokeMethod<String>('saveToDownloads', {
        'name': name,
        'sourcePath': sourcePath,
        'mime': mime,
      });
      if (where == null || where.isEmpty) {
        throw const SaveFailure('Downloads did not report a location');
      }
      return where;
    } on PlatformException catch (e) {
      throw SaveFailure(e.message ?? 'Could not save to Downloads');
    } on MissingPluginException {
      throw const SaveFailure('Saving to Downloads is unavailable in this build');
    }
  }
}

/// A save that genuinely failed (as opposed to one the user canceled).
class SaveFailure implements Exception {
  final String message;
  const SaveFailure(this.message);
  @override
  String toString() => message;
}

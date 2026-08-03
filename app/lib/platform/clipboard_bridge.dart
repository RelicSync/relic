import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'src/macos/clipboard_macos.dart' as mac;
import 'src/windows/clipboard_win.dart' as win;

/// Native clipboard operations the cross-platform plugins don't cover: the
/// change counter, privacy markers, file copies, raw-bitmap fallbacks and
/// sensitive writes. Windows dispatches to Win32 (src/windows/clipboard_win),
/// macOS to NSPasteboard via a MethodChannel (src/macos/clipboard_macos);
/// everything else gets the benign empty results callers already handle by
/// falling back to Flutter's framework clipboard.
///
/// All functions are async because the macOS side crosses a MethodChannel; the
/// Windows implementations complete synchronously.

/// The system clipboard's change counter — bumps on EVERY clipboard write,
/// regardless of format. Used to detect whether a synthesized copy actually
/// produced one, and to guard the post-secret scrub. 0 when unavailable.
Future<int> clipboardSequence() async {
  if (Platform.isWindows) return win.clipboardSequence();
  if (Platform.isMacOS) return mac.changeCount();
  return 0;
}

/// True when the current clipboard contents explicitly ask history/monitoring
/// tools to ignore them (password managers set private formats on Windows,
/// org.nspasteboard.* marker types on macOS).
Future<bool> clipboardShouldBeIgnored() async {
  if (Platform.isWindows) return win.clipboardShouldBeIgnored();
  if (Platform.isMacOS) return mac.shouldBeIgnored();
  return false;
}

/// Empty the system clipboard — the post-secret-copy scrub. Best-effort;
/// callers gate on clipboardSequence() so nothing copied since our own write
/// is ever destroyed.
Future<bool> clearClipboard() async {
  if (Platform.isWindows) return win.clearClipboard();
  if (Platform.isMacOS) return mac.clear();
  return false;
}

/// Add the platform's privacy hints to the current clipboard contents.
Future<bool> markClipboardSensitive() async {
  if (Platform.isWindows) return win.markClipboardSensitive();
  if (Platform.isMacOS) return mac.markSensitive();
  return false;
}

/// Place text on the clipboard with privacy hints that exclude it from
/// clipboard history, cloud clipboard, and monitoring tools. False → the
/// caller falls back to the framework clipboard (no hints).
Future<bool> writeSensitiveTextToClipboard(String text) async {
  if (Platform.isWindows) return win.writeSensitiveTextToClipboard(text);
  if (Platform.isMacOS) return mac.writeSensitiveText(text);
  return false;
}

/// File paths from a file-manager copy (Explorer CF_HDROP / Finder file URLs),
/// or empty.
Future<List<String>> clipboardFilePaths() async {
  if (Platform.isWindows) return win.clipboardFilePaths();
  if (Platform.isMacOS) return mac.filePaths();
  return const [];
}

/// A raster image from the clipboard for sources that don't provide a PNG/JPEG
/// representation (Windows CF_DIB from PrtScn-era tools, macOS TIFF),
/// normalized to PNG bytes. Null when there is none or it can't be decoded.
Future<Uint8List?> clipboardImageAsPng() async {
  try {
    Uint8List? raw;
    if (Platform.isWindows) {
      raw = win.clipboardDibAsBmp();
    } else if (Platform.isMacOS) {
      raw = await mac.rawImage();
    }
    if (raw == null) return null;
    final decoded = img.decodeImage(raw); // sniffs BMP/TIFF/…
    if (decoded == null) return null;
    return Uint8List.fromList(img.encodePng(decoded));
  } catch (_) {
    return null;
  }
}

/// Put a real file on the clipboard so it pastes as a file in the file manager
/// (CF_HDROP / file-URL pasteboard item), not just its path text.
Future<bool> writeFileToClipboard(String path) async {
  if (Platform.isWindows) return win.writeFileToClipboard(path);
  if (Platform.isMacOS) return mac.writeFile(path);
  return false;
}

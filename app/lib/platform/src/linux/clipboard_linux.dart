import 'package:super_clipboard/super_clipboard.dart';

/// Linux clipboard extras, deliberately built on super_clipboard rather than
/// raw X11 FFI: its Rust core speaks both X11 and Wayland, which hand-rolled
/// Xlib selection code would not. Only what the cross-platform reader ladder
/// in desktop.dart does NOT already cover lives here:
///
///   - file lists (`text/uri-list` — Nautilus/Dolphin/Thunar copies), and
///   - the password-manager privacy hint (`x-kde-passwordManagerHint`, the
///     cross-desktop convention KeePassXC/Bitwarden set even outside KDE).
///
/// Everything is best-effort: any failure returns the benign empty result
/// the bridge's callers already handle.

/// The privacy-hint target. Presence alone is the signal (its value is
/// "secret"), mirroring how the Windows side treats the mere presence of
/// ExcludeClipboardContentFromMonitorProcessing; no decode is ever needed.
const _passwordManagerHint = SimpleValueFormat<String>(
  fallback: SimplePlatformCodec<String>(formats: ['x-kde-passwordManagerHint']),
);

Future<bool> shouldBeIgnored() async {
  try {
    final clip = SystemClipboard.instance;
    if (clip == null) return false;
    final reader = await clip.read();
    return reader.canProvide(_passwordManagerHint);
  } catch (_) {
    return false;
  }
}

/// File paths from a file-manager copy, or empty. Returns plain filesystem
/// paths (scheme stripped, percent-decoded) because the capture loop feeds
/// them straight to File(path) — same shape as the Windows and macOS arms.
Future<List<String>> filePaths() async {
  try {
    final clip = SystemClipboard.instance;
    if (clip == null) return const [];
    final reader = await clip.read();
    final out = <String>[];
    for (final item in reader.items) {
      if (!item.canProvide(Formats.fileUri)) continue;
      final uri = await item.readValue(Formats.fileUri);
      if (uri != null && uri.isScheme('file')) out.add(uri.toFilePath());
    }
    return out;
  } catch (_) {
    return const [];
  }
}

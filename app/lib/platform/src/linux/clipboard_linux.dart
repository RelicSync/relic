import 'package:flutter/services.dart' show Clipboard;
import 'package:super_clipboard/super_clipboard.dart';

/// Linux clipboard extras, deliberately built on super_clipboard rather than
/// raw X11 FFI: its Rust core speaks both X11 and Wayland, which hand-rolled
/// Xlib selection code would not. Only what the cross-platform reader ladder
/// in desktop.dart does NOT already cover lives here:
///
///   - file lists (`text/uri-list` — Nautilus/Dolphin/Thunar copies),
///   - the password-manager privacy hint (`x-kde-passwordManagerHint`, the
///     cross-desktop convention KeePassXC/Bitwarden set even outside KDE), and
///   - a stand-in for the clipboard change counter ([sequence]).
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

/// A stand-in for the clipboard change counter Windows and macOS provide.
///
/// X11 has no such counter, and until Relic could synthesize keystrokes that
/// did not matter — the bridge just answered 0 everywhere. It matters now: the
/// save & annotate hotkey synthesizes Ctrl+C and then asks whether the
/// clipboard changed, and against a constant 0 the answer is always "no", so a
/// working copy was injected and its result thrown away in favour of whatever
/// was on the clipboard beforehand.
///
/// Derived from the content rather than counted, which has one blind spot:
/// replacing an image with a DIFFERENT image reads as unchanged, because
/// hashing the pixels on every poll is not worth it. That case then falls back
/// to the clipboard, which is exactly what Linux did before, so nothing
/// regresses — it is only the improvement that stops short. Copying identical
/// text twice is likewise "unchanged", and there the fallback captures the
/// same bytes anyway.
Future<int> sequence() async {
  try {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    var hasImage = false;
    final clip = SystemClipboard.instance;
    if (clip != null) {
      final reader = await clip.read();
      hasImage = reader.canProvide(Formats.png) ||
          reader.canProvide(Formats.jpeg);
    }
    return Object.hash(text, hasImage);
  } catch (_) {
    return 0;
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

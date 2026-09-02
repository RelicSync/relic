import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:super_clipboard/super_clipboard.dart';

import '../models/rich_body.dart';
import 'rich_formats.dart';
import 'src/linux/clipboard_linux.dart' as lin;
import 'src/macos/clipboard_macos.dart' as mac;
import 'src/windows/clipboard_win.dart' as win;

/// Native clipboard operations the cross-platform plugins don't cover: the
/// change counter, privacy markers, file copies, raw-bitmap fallbacks and
/// sensitive writes. Windows dispatches to Win32 (src/windows/clipboard_win),
/// macOS to NSPasteboard via a MethodChannel (src/macos/clipboard_macos),
/// Linux to super_clipboard-based readers for the two capture-critical pieces
/// (src/linux/clipboard_linux: file lists + the password-manager hint);
/// everything else gets the benign empty results callers already handle by
/// falling back to Flutter's framework clipboard. X11 has no clipboard change
/// counter, so [clipboardSequence] is derived from the content there (see
/// src/linux/clipboard_linux); the post-secret scrub still never arms, because
/// [clearClipboard] has no Linux arm.
///
/// All functions are async because the macOS side crosses a MethodChannel; the
/// Windows implementations complete synchronously.

/// The system clipboard's change counter — bumps on EVERY clipboard write,
/// regardless of format. Used to detect whether a synthesized copy actually
/// produced one, and to guard the post-secret scrub. 0 when unavailable.
///
/// Windows and macOS expose a real counter. X11 does not, so Linux returns a
/// value derived from the clipboard's content: callers only ever compare two
/// readings for equality, which is all the derived value promises.
Future<int> clipboardSequence() async {
  if (Platform.isWindows) return win.clipboardSequence();
  if (Platform.isMacOS) return mac.changeCount();
  if (Platform.isLinux) return lin.sequence();
  return 0;
}

/// True when the current clipboard contents explicitly ask history/monitoring
/// tools to ignore them (password managers set private formats on Windows,
/// org.nspasteboard.* marker types on macOS, the x-kde-passwordManagerHint
/// target on Linux).
Future<bool> clipboardShouldBeIgnored() async {
  if (Platform.isWindows) return win.clipboardShouldBeIgnored();
  if (Platform.isMacOS) return mac.shouldBeIgnored();
  if (Platform.isLinux) return lin.shouldBeIgnored();
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

/// Place [text] on the clipboard together with the formatting flavors in
/// [rich], so pasting into Slack, Word or Notion keeps the styling.
///
/// Plain text always goes on too, and it goes on first where the platform lets
/// us order the write, so a target that understands none of the rich types
/// still gets a correct paste.
///
/// Windows and macOS use their native writes rather than super_clipboard: that
/// plugin publishes lazily (OLE on Windows, an NSPasteboardWriter promise on
/// macOS), so the content would die when Relic quits, and its clearContents
/// would drop the privacy markers. Linux has no native write at all, and
/// Android and iOS have no reason to want one, so all three take the plugin
/// path. The lazy-provider lifetime problem does not exist on iOS: the plugin
/// calls the provider eagerly there, and the bytes are already in hand.
///
/// Returns false when nothing native handled it; the caller then falls back to
/// the framework clipboard, losing only the formatting.
Future<bool> writeRichToClipboard(
  String text,
  RichBody rich, {
  bool sensitive = false,
}) async {
  final html = rich.html;
  final rtf = rich.rtf;
  if (Platform.isWindows) {
    return win.writeRichToClipboard(
      text,
      cfHtml: html == null ? null : cfHtmlEncode(html),
      rtf: rtf,
      sensitive: sensitive,
    );
  }
  if (Platform.isMacOS) {
    return mac.writeRich(text, html: html, rtf: rtf, sensitive: sensitive);
  }
  if (Platform.isLinux || Platform.isAndroid || Platform.isIOS) {
    try {
      final clip = SystemClipboard.instance;
      if (clip == null) return false;
      // Highest fidelity first: some platforms honour the order as the
      // author's preference. Android additionally REQUIRES plainText in the
      // same item or the write can be refused outright.
      final item = DataWriterItem();
      if (html != null) item.add(kRelicHtml(html));
      // Nothing on Android publishes or reads RTF, so leave ClipDescription
      // clean there. iOS keeps it: Pages, Notes and Mail all read public.rtf.
      if (rtf != null && !Platform.isAndroid) item.add(kRelicRtf(rtf));
      item.add(Formats.plainText(text));
      await clip.write([item]);
      return true;
    } catch (_) {
      return false;
    }
  }
  return false;
}

/// File paths from a file-manager copy (Explorer CF_HDROP / Finder file URLs
/// / text/uri-list on Linux), or empty.
Future<List<String>> clipboardFilePaths() async {
  if (Platform.isWindows) return win.clipboardFilePaths();
  if (Platform.isMacOS) return mac.filePaths();
  if (Platform.isLinux) return lin.filePaths();
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

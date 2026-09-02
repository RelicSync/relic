// The two clipboard format constants rich text needs.
//
// Split out of models/rich_body.dart so the model layer stays pure Dart: this
// file is the only half that pulls in super_clipboard, and models/relic.dart
// must never depend on a plugin.
import 'dart:convert';
import 'dart:typed_data';

import 'package:super_clipboard/super_clipboard.dart';

import '../models/rich_body.dart';

// --- Clipboard formats -------------------------------------------------------
//
// Neither stock super_clipboard constant is usable here, for reasons that are
// easy to re-break, so both are declared locally. The template is the
// `x-kde-passwordManagerHint` format in platform/src/linux/clipboard_linux.dart.

/// The Windows registered clipboard format name for CF_HTML.
const _cfHtml = 'HTML Format';

/// HTML on the clipboard.
///
/// NOT `Formats.htmlText`: its Windows codec lists both `text/html` and
/// CF_HTML as decoding formats and decodes anything that is not CF_HTML as
/// UTF-16. Some Qt and Electron apps register a Windows clipboard format
/// literally named `text/html` holding UTF-8, and the reader picks by the
/// source app's priority order, which we do not control. Those apps would come
/// back as mojibake. Restricting Windows to `HTML Format` removes the choice.
const kRelicHtml = SimpleValueFormat<String>(
  windows: SimplePlatformCodec<String>(
    formats: [_cfHtml],
    onDecode: cfHtmlFromSystem,
    onEncode: cfHtmlToSystem,
  ),
  macos: SimplePlatformCodec<String>(
    formats: ['public.html'],
    onDecode: _utf8FromSystem,
    onEncode: _htmlWithCharset,
  ),
  ios: SimplePlatformCodec<String>(
    formats: ['public.html'],
    onDecode: _utf8FromSystem,
    onEncode: _htmlWithCharset,
  ),
  fallback: SimplePlatformCodec<String>(
    formats: ['text/html'],
    onDecode: _utf8FromSystem,
  ),
);

/// RTF on the clipboard, as raw bytes.
///
/// NOT `Formats.rtf`: that is a `SimpleFileFormat`, and a file format publishes
/// only its FIRST platform format, so it can never offer both `text/rtf` and
/// `application/rtf` on Linux — and LibreOffice and GTK look for both. It also
/// falls back to `mimeTypes` on Windows, which would register a format named
/// `application/rtf` that no Windows app reads; Word, WordPad and Outlook use
/// the registered name `Rich Text Format`. A value format publishes every entry.
const kRelicRtf = SimpleValueFormat<Uint8List>(
  windows: SimplePlatformCodec<Uint8List>(
    formats: ['Rich Text Format'],
    onDecode: _bytesFromSystem,
  ),
  macos: SimplePlatformCodec<Uint8List>(
    formats: ['public.rtf'],
    onDecode: _bytesFromSystem,
  ),
  ios: SimplePlatformCodec<Uint8List>(
    formats: ['public.rtf'],
    onDecode: _bytesFromSystem,
  ),
  fallback: SimplePlatformCodec<Uint8List>(
    formats: ['text/rtf', 'application/rtf'],
    onDecode: _bytesFromSystem,
  ),
);

/// Prepend the charset marker some macOS apps (Notes, Mail) need to stop
/// assuming latin-1. Matches what super_clipboard's own encoder does.
Object _htmlWithCharset(String html, PlatformFormat format) =>
    "<meta charset='utf-8'>$html";

Future<String?> _utf8FromSystem(
    PlatformDataProvider provider, PlatformFormat format) async {
  final bytes = await _bytesFromSystem(provider, format);
  return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
}

/// Coerce whatever the platform handed back into bytes.
///
/// The default codec only does a `value is T` cast, which is too fragile: the
/// same logical format arrives as a String, a `List<int>` or a `TypedData`
/// depending on the backend, and MS Office on macOS answers an empty Map when
/// you copy text alongside an image.
Future<Uint8List?> _bytesFromSystem(
    PlatformDataProvider provider, PlatformFormat format) async {
  final v = await provider.getData(format);
  if (v == null) return null;
  if (v is Uint8List) return v;
  if (v is TypedData) {
    return Uint8List.view(
        v.buffer, v.offsetInBytes, v.lengthInBytes);
  }
  if (v is List<int>) return Uint8List.fromList(v);
  if (v is String) return Uint8List.fromList(utf8.encode(v));
  return null; // empty Map and anything else: nothing usable
}

/// CF_HTML adapters. The byte math itself is pure and lives in
/// models/rich_body.dart; these two only bridge it to super_clipboard's codec
/// signature.
Future<String?> cfHtmlFromSystem(
    PlatformDataProvider provider, PlatformFormat format) async {
  final bytes = await _bytesFromSystem(provider, format);
  return bytes == null ? null : cfHtmlDecode(bytes);
}

Object cfHtmlToSystem(String html, PlatformFormat format) => cfHtmlEncode(html);

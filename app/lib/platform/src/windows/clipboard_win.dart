import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Windows backend of platform/clipboard_bridge.dart. Every public helper here
/// calls into Win32 (user32/kernel32); each guards on [Platform.isWindows] and
/// returns a benign empty result elsewhere, so the facade can dispatch safely.

const _cfUnicodeText = 13;
const _gmemMoveable = 0x0002;

/// `OpenClipboard` routinely loses a race: right after another app updates the
/// clipboard (e.g. Explorer on Ctrl+C) that app — and every other clipboard
/// listener woken by the same event — still briefly holds the clipboard open,
/// so a lone `OpenClipboard(0)` fails and the capture is silently dropped. Retry
/// for a short window (here ~10×16ms ≈ 160ms, only while contended) so a real
/// file copy isn't missed. Returns true once the clipboard is open (caller must
/// `CloseClipboard`), false if it never frees up.
bool _openClipboardWithRetry({int attempts = 10, int delayMs = 16}) {
  for (var i = 0; i < attempts; i++) {
    if (OpenClipboard(0) != 0) return true;
    if (i < attempts - 1) Sleep(delayMs);
  }
  return false;
}

int _registeredClipboardFormat(String name) {
  final p = name.toNativeUtf16();
  try {
    return RegisterClipboardFormat(p);
  } finally {
    calloc.free(p);
  }
}

bool _putGlobalBytes(int format, List<int> bytes) {
  final hMem = GlobalAlloc(_gmemMoveable, bytes.length);
  if (hMem == nullptr) return false;
  final ptr = GlobalLock(hMem);
  if (ptr == nullptr) {
    GlobalFree(hMem);
    return false;
  }
  ptr.cast<Uint8>().asTypedList(bytes.length).setAll(0, bytes);
  GlobalUnlock(hMem);
  if (SetClipboardData(format, hMem.address) == 0) {
    GlobalFree(hMem);
    return false;
  }
  return true; // the system owns hMem now
}

bool _markClipboardSensitiveOpen() {
  var ok = true;
  for (final name in [
    'ExcludeClipboardContentFromMonitorProcessing',
    'CanIncludeInClipboardHistory',
    'CanUploadToCloudClipboard',
  ]) {
    final fmt = _registeredClipboardFormat(name);
    if (fmt == 0) {
      ok = false;
    } else {
      ok = _putGlobalBytes(fmt, const [0, 0, 0, 0]) && ok;
    }
  }
  return ok;
}

int? _readClipboardDword(int format) {
  if (!_openClipboardWithRetry()) return null;
  try {
    final h = GetClipboardData(format);
    if (h == 0) return null;
    final ptr = GlobalLock(Pointer.fromAddress(h));
    if (ptr == nullptr) return null;
    try {
      return ptr.cast<Uint32>().value;
    } finally {
      GlobalUnlock(Pointer.fromAddress(h));
    }
  } finally {
    CloseClipboard();
  }
}

/// The system clipboard's change counter — bumps on EVERY clipboard write,
/// regardless of format. Cheap (no OpenClipboard), used to detect whether a
/// synthesized Ctrl+C actually produced a copy. 0 on non-Windows.
int clipboardSequence() {
  if (!Platform.isWindows) return 0;
  try {
    return GetClipboardSequenceNumber();
  } catch (_) {
    return 0;
  }
}

/// True when the current clipboard contents explicitly ask history/monitoring
/// tools to ignore them. Password managers and other sensitive apps use these
/// private Windows formats.
bool clipboardShouldBeIgnored() {
  if (!Platform.isWindows) return false;
  for (final name in [
    'ExcludeClipboardContentFromMonitorProcessing',
    'Clipboard Viewer Ignore',
  ]) {
    final fmt = _registeredClipboardFormat(name);
    if (fmt != 0 && IsClipboardFormatAvailable(fmt) != 0) return true;
  }
  for (final name in [
    'CanIncludeInClipboardHistory',
    'CanUploadToCloudClipboard',
  ]) {
    final fmt = _registeredClipboardFormat(name);
    if (fmt != 0 &&
        IsClipboardFormatAvailable(fmt) != 0 &&
        _readClipboardDword(fmt) == 0) {
      return true;
    }
  }
  return false;
}

/// Empty the system clipboard — the post-secret-copy scrub. Best-effort,
/// Windows-only; callers gate on clipboardSequence() so nothing copied since
/// our own write is ever destroyed.
bool clearClipboard() {
  if (!Platform.isWindows) return false;
  if (OpenClipboard(0) == 0) return false;
  try {
    EmptyClipboard();
    return true;
  } finally {
    CloseClipboard();
  }
}

/// Add Windows privacy hints to the current clipboard contents.
bool markClipboardSensitive() {
  if (!Platform.isWindows) return false;
  if (OpenClipboard(0) == 0) return false;
  try {
    return _markClipboardSensitiveOpen();
  } finally {
    CloseClipboard();
  }
}

/// UTF-16LE with the null terminator CF_UNICODETEXT wants.
Uint8List _utf16le(String text) {
  final bytes = BytesBuilder();
  for (final u in text.codeUnits) {
    bytes.addByte(u & 0xff);
    bytes.addByte((u >> 8) & 0xff);
  }
  bytes.add(const [0, 0]);
  return bytes.toBytes();
}

/// Place text on the clipboard with Windows privacy hints that exclude it from
/// clipboard history, cloud clipboard, and monitoring tools.
bool writeSensitiveTextToClipboard(String text) =>
    writeRichToClipboard(text, sensitive: true);

/// Place text plus its formatting flavors on the clipboard in ONE clipboard
/// session, highest fidelity first.
///
/// Deliberately raw Win32 rather than super_clipboard's writer, which is what
/// the photo path uses. Two reasons, both load-bearing:
///
///  * super_native_extensions publishes through `OleSetClipboard` with a live
///    delayed-rendering IDataObject and never calls `OleFlushClipboard`, so the
///    content dies when Relic exits. Relic is a tray app people quit, and
///    "copy, quit, paste" works today.
///  * [_markClipboardSensitiveOpen] needs to own the clipboard. Under OLE the
///    owner is OLE's hidden window, so the privacy hints would not stick.
///
/// [cfHtml] must already be CF_HTML-framed (see cfHtmlEncode); [rtf] is raw RTF
/// bytes. Either may be null. Returns false if the clipboard never opened, in
/// which case the caller falls back to the framework write.
bool writeRichToClipboard(
  String text, {
  Uint8List? cfHtml,
  Uint8List? rtf,
  bool sensitive = false,
}) {
  if (!Platform.isWindows) return false;
  if (!_openClipboardWithRetry()) return false;
  try {
    EmptyClipboard();
    // Plain text first: if anything below fails the clipboard still holds a
    // correct, if unformatted, copy.
    if (!_putGlobalBytes(_cfUnicodeText, _utf16le(text))) return false;
    var ok = true;
    if (cfHtml != null) {
      final fmt = _registeredClipboardFormat('HTML Format');
      ok = fmt != 0 && _putGlobalBytes(fmt, cfHtml) && ok;
    }
    if (rtf != null) {
      // The registered name Word, WordPad and Outlook publish under. NOT the
      // `application/rtf` MIME type, which no Windows app reads.
      final fmt = _registeredClipboardFormat('Rich Text Format');
      ok = fmt != 0 && _putGlobalBytes(fmt, rtf) && ok;
    }
    if (sensitive) ok = _markClipboardSensitiveOpen() && ok;
    return ok;
  } finally {
    CloseClipboard();
  }
}

/// File paths from a CF_HDROP clipboard copy (Explorer Ctrl+C), or empty.
/// Mirrors the proven relic-app/src/win.rs logic. Windows-only (uses Win32).
List<String> clipboardFilePaths() {
  const cfHdrop = 15; // CF_HDROP
  final paths = <String>[];
  if (!Platform.isWindows) return paths;
  if (!_openClipboardWithRetry()) return paths;
  try {
    final handle = GetClipboardData(cfHdrop);
    if (handle == 0) return paths;
    final count = DragQueryFile(handle, 0xFFFFFFFF, nullptr, 0);
    for (var i = 0; i < count; i++) {
      final needed = DragQueryFile(handle, i, nullptr, 0) + 1;
      final buf = calloc<Uint16>(needed);
      try {
        DragQueryFile(handle, i, buf.cast<Utf16>(), needed);
        paths.add(buf.cast<Utf16>().toDartString());
      } finally {
        calloc.free(buf);
      }
    }
  } finally {
    CloseClipboard();
  }
  return paths;
}

/// Read a CF_DIB clipboard image and wrap it as a self-contained BMP, for
/// screenshot tools (e.g. PrtScn) that don't put a "PNG" format. Null if none.
Uint8List? clipboardDibAsBmp() {
  const cfDib = 8; // CF_DIB
  if (!Platform.isWindows) return null;
  if (!_openClipboardWithRetry()) return null;
  try {
    final h = GetClipboardData(cfDib);
    if (h == 0) return null;
    final hg = Pointer.fromAddress(h);
    final size = GlobalSize(hg);
    if (size <= 40) return null;
    final ptr = GlobalLock(hg);
    if (ptr == nullptr) return null;
    final Uint8List dib;
    try {
      dib = Uint8List.fromList(ptr.cast<Uint8>().asTypedList(size));
    } finally {
      GlobalUnlock(hg);
    }
    final bd = ByteData.sublistView(dib);
    final biSize = bd.getUint32(0, Endian.little);
    final biBitCount = bd.getUint16(14, Endian.little);
    final compression = bd.getUint32(16, Endian.little);
    final biClrUsed = bd.getUint32(32, Endian.little);
    var palette = 0;
    if (biBitCount > 0 && biBitCount <= 8) {
      palette = (biClrUsed != 0 ? biClrUsed : (1 << biBitCount)) * 4;
    }
    final masks = (compression == 3 && biSize == 40) ? 12 : 0;
    final bfOffBits = 14 + biSize + palette + masks;
    final fileSize = 14 + dib.length;
    final out = Uint8List(fileSize);
    final ob = ByteData.sublistView(out);
    out[0] = 0x42; // 'B'
    out[1] = 0x4D; // 'M'
    ob.setUint32(2, fileSize, Endian.little);
    ob.setUint32(10, bfOffBits, Endian.little);
    out.setRange(14, fileSize, dib);
    return out;
  } catch (_) {
    return null;
  } finally {
    CloseClipboard();
  }
}

/// Put a real file on the clipboard as CF_HDROP, so it pastes as a file
/// (e.g. into Explorer), not just its path text. Returns success.
bool writeFileToClipboard(String path) {
  if (!Platform.isWindows) return false;
  const cfHdrop = 15;
  // DROPFILES(20) + path UTF-16 + double-null terminator
  final units = path.codeUnits;
  final body = BytesBuilder();
  for (final u in units) {
    body.addByte(u & 0xff);
    body.addByte((u >> 8) & 0xff);
  }
  body.add(const [0, 0, 0, 0]); // path null + list null
  final pathBytes = body.toBytes();
  final total = 20 + pathBytes.length;
  final blob = Uint8List(total);
  final bd = ByteData.sublistView(blob);
  bd.setUint32(0, 20, Endian.little); // pFiles = offset to file list
  bd.setUint32(16, 1, Endian.little); // fWide = TRUE
  blob.setRange(20, total, pathBytes);

  final hMem = GlobalAlloc(_gmemMoveable, total);
  if (hMem == nullptr) return false;
  final ptr = GlobalLock(hMem);
  if (ptr == nullptr) {
    GlobalFree(hMem);
    return false;
  }
  ptr.cast<Uint8>().asTypedList(total).setAll(0, blob);
  GlobalUnlock(hMem);

  if (OpenClipboard(0) == 0) {
    GlobalFree(hMem);
    return false;
  }
  var ok = false;
  try {
    EmptyClipboard();
    ok =
        SetClipboardData(cfHdrop, hMem.address) !=
        0; // on success the system owns hMem
    if (ok) _markClipboardSensitiveOpen();
  } finally {
    CloseClipboard();
  }
  if (!ok) GlobalFree(hMem);
  return ok;
}

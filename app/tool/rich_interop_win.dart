// Windows clipboard interop harness for rich text (§8 of
// docs/rich-text-paste-stack-2026-09.md).
//
// The unit tests cover our CF_HTML framing against our own decoder, which
// proves we are self-consistent and nothing else. The open question is whether
// Word, Excel and the browsers accept what we emit and whether we can read what
// they publish. This drives the REAL production code paths (cfHtmlEncode /
// cfHtmlDecode from models/rich_body.dart, writeRichToClipboard from
// platform/src/windows/clipboard_win.dart) so a pass here is a statement about
// shipping code, not about a mock.
//
// Not a flutter test: it needs a real clipboard and a real Office instance, so
// it can never run in CI. Pair it with tool/rich_interop_win.ps1, which does the
// Word and Excel half over COM.
//
//   write        our payload onto the clipboard, then read it straight back
//   read         decode what the previous app published
//   roundtrip    capture -> JSON -> replay, the fragment path that ships today
//   replayclean  same, but keeping the whole document with file:/// stripped
//   replayraw    replay the source's CF_HTML byte for byte (diagnosis only)
//   raw          print the full CF_HTML next to the fragment we keep
//   watch        detect anything else on the machine overwriting the clipboard
//   dump         list the formats currently on the clipboard
// A console harness reports by printing, and public CI treats analyzer infos as
// fatal, so the lint is turned off here rather than routed through a logger.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:relic_app/models/rich_body.dart';
import 'package:relic_app/platform/src/windows/clipboard_win.dart';
import 'package:win32/win32.dart';

/// The payload every direction agrees on. Bold in the middle so a target app
/// either shows styling or does not, with no judgement call in between.
const _plain = 'plain bold done';
const _html = '<span style="font-family:Calibri;font-size:14pt">'
    'plain <b>bold</b> done</span>';
const _rtf = r'{\rtf1\ansi\deff0{\fonttbl{\f0 Calibri;}}'
    '\\f0\\fs28 plain \\b bold\\b0  done}';

int _fmt(String name) {
  final p = name.toNativeUtf16();
  try {
    return RegisterClipboardFormat(p);
  } finally {
    calloc.free(p);
  }
}

/// `OpenClipboard` with the same retry the shipping code uses. Without it this
/// harness reports formats as "absent" whenever any other clipboard listener
/// (an installed Relic, Office, a clipboard manager) happens to hold the
/// clipboard open at that instant, which turns a healthy write into a fake
/// failure. Same reasoning as `_openClipboardWithRetry` in clipboard_win.dart.
bool _open({int attempts = 10, int delayMs = 16}) {
  for (var i = 0; i < attempts; i++) {
    if (OpenClipboard(0) != 0) return true;
    if (i < attempts - 1) Sleep(delayMs);
  }
  return false;
}

/// Raw bytes of one clipboard format, or null when it is not offered.
Uint8List? _read(int format) {
  if (!_open()) return null;
  try {
    final h = GetClipboardData(format);
    if (h == 0) return null;
    final hg = Pointer.fromAddress(h);
    final size = GlobalSize(hg);
    if (size == 0) return null;
    final ptr = GlobalLock(hg);
    if (ptr == nullptr) return null;
    try {
      return Uint8List.fromList(ptr.cast<Uint8>().asTypedList(size));
    } finally {
      GlobalUnlock(hg);
    }
  } finally {
    CloseClipboard();
  }
}

/// Every format currently on the clipboard, as (id, name).
List<(int, String)> _enumerate() {
  final out = <(int, String)>[];
  if (!_open()) return out;
  try {
    var f = 0;
    while ((f = EnumClipboardFormats(f)) != 0) {
      final buf = calloc<Uint16>(256);
      try {
        final n = GetClipboardFormatName(f, buf.cast<Utf16>(), 256);
        out.add((f, n > 0 ? buf.cast<Utf16>().toDartString() : _builtin(f)));
      } finally {
        calloc.free(buf);
      }
    }
  } finally {
    CloseClipboard();
  }
  return out;
}

String _builtin(int f) => switch (f) {
      1 => 'CF_TEXT',
      8 => 'CF_DIB',
      13 => 'CF_UNICODETEXT',
      15 => 'CF_HDROP',
      17 => 'CF_DIBV5',
      _ => 'builtin #$f',
    };

String _utf16(Uint8List b) {
  final units = <int>[];
  for (var i = 0; i + 1 < b.length; i += 2) {
    final u = b[i] | (b[i + 1] << 8);
    if (u == 0) break;
    units.add(u);
  }
  return String.fromCharCodes(units);
}

void _pass(String what) => print('  PASS  $what');
void _fail(String what) {
  print('  FAIL  $what');
  exitCode = 1;
}

/// Put our payload on the clipboard through the shipping writer, then read it
/// straight back and check the bytes survived the round trip through Win32.
void _write() {
  print('WRITE: production writeRichToClipboard()');
  final ok = writeRichToClipboard(
    _plain,
    cfHtml: cfHtmlEncode(_html),
    rtf: Uint8List.fromList(utf8.encode(_rtf)),
  );
  ok ? _pass('writeRichToClipboard returned true') : _fail('writer returned false');

  final text = _read(13);
  text != null && _utf16(text) == _plain
      ? _pass('CF_UNICODETEXT is the exact plain text')
      : _fail('CF_UNICODETEXT was ${text == null ? "absent" : _utf16(text)}');

  final html = _read(_fmt('HTML Format'));
  if (html == null) {
    _fail('HTML Format absent');
  } else {
    final decoded = cfHtmlDecode(html);
    decoded == _html
        ? _pass('HTML Format round-trips through our own decoder')
        : _fail('HTML Format decoded to $decoded');
    // The header the OS and every consumer actually parses.
    final head = utf8.decode(html.take(120).toList(), allowMalformed: true);
    head.startsWith('Version:0.9')
        ? _pass('CF_HTML header starts Version:0.9')
        : _fail('CF_HTML header is ${head.split("\r\n").first}');
  }

  final rtf = _read(_fmt('Rich Text Format'));
  rtf != null && utf8.decode(rtf, allowMalformed: true).startsWith(r'{\rtf1')
      ? _pass('Rich Text Format present and starts {\\rtf1')
      : _fail('Rich Text Format absent or malformed');

  print('\nClipboard now holds:');
  for (final (id, name) in _enumerate()) {
    print('  $id  $name');
  }
  print('\nPaste into Word/Excel now, or run tool/rich_interop_win.ps1 verify.');
}

/// Read whatever the previous app copied. Run after copying from Word, Excel or
/// a browser: this is the capture ladder's half of the matrix.
void _readSide() {
  print('READ: what the source app published, through our decoder');
  final formats = _enumerate();
  print('Formats offered:');
  for (final (id, name) in formats) {
    print('  $id  $name');
  }

  final text = _read(13);
  print('\nplain: ${text == null ? "(none)" : _utf16(text)}');

  final html = _read(_fmt('HTML Format'));
  if (html == null) {
    print('HTML Format: (not offered)');
  } else {
    final decoded = cfHtmlDecode(html);
    if (decoded == null) {
      _fail('HTML Format offered but our decoder returned null');
      print(utf8.decode(html.take(400).toList(), allowMalformed: true));
    } else {
      _pass('decoded ${decoded.length} chars of HTML');
      print('  ${decoded.substring(0, decoded.length.clamp(0, 300))}');
    }
  }

  final rtf = _read(_fmt('Rich Text Format'));
  if (rtf == null) {
    print('Rich Text Format: (not offered)');
  } else {
    final s = utf8.decode(rtf, allowMalformed: true);
    s.startsWith(r'{\rtf1')
        ? _pass('RTF offered, ${rtf.length} bytes')
        : _fail('RTF offered but does not start {\\rtf1');
  }

  // What capture would actually store, cap and all.
  final body = RichBody.capture(
    plain: text == null ? '' : _utf16(text),
    html: html == null ? null : cfHtmlDecode(html),
    rtf: rtf,
  );
  print('\nRichBody.capture -> ${body == null ? "null (nothing kept)" : ""}');
  if (body != null) {
    print('  html: ${body.html?.length ?? 0} chars');
    print('  rtf:  ${body.rtf?.length ?? 0} bytes');
    print('  json: ${jsonEncode(body.toJson()).length} bytes '
        '(cap $kRichMaxBytes)');
  }
}

/// The whole feature in one pass: read what the source app published, put it
/// through the real capture path and a JSON round trip (what sync and the DB
/// column do to it), then write it back out through the real writer. Whatever a
/// target app pastes after this is what a user would actually get.
void _roundTrip() {
  print('ROUND TRIP: source app -> RichBody -> JSON -> clipboard');
  final text = _read(13);
  if (text == null) {
    _fail('no plain text on the clipboard; copy something styled first');
    return;
  }
  final plain = _utf16(text);
  final htmlRaw = _read(_fmt('HTML Format'));
  final body = RichBody.capture(
    plain: plain,
    html: htmlRaw == null ? null : cfHtmlDecode(htmlRaw),
    rtf: _read(_fmt('Rich Text Format')),
  );
  if (body == null) {
    _fail('capture kept nothing');
    return;
  }
  _pass('captured ${body.html?.length ?? 0} chars HTML, '
      '${body.rtf?.length ?? 0} bytes RTF');

  // Exactly what the DB column and the sync payload do to it.
  final revived = RichBody.fromJson(jsonDecode(jsonEncode(body.toJson())));
  if (revived == null) {
    _fail('did not survive the JSON round trip');
    return;
  }
  revived == body
      ? _pass('survived JSON byte-identically')
      : _fail('changed across the JSON round trip');

  // And the staleness guard the whole design rests on.
  revived.forPlain(plain) != null
      ? _pass('forPlain() serves it for the unchanged text')
      : _fail('forPlain() refused the text it came from');
  revived.forPlain('$plain edited') == null
      ? _pass('forPlain() goes inert once the text is edited')
      : _fail('stale formatting was served for edited text');

  final ok = writeRichToClipboard(
    plain,
    cfHtml: revived.html == null ? null : cfHtmlEncode(revived.html!),
    rtf: revived.rtf,
  );
  ok ? _pass('replayed onto the clipboard') : _fail('replay write failed');
}

/// CF_HTML around a COMPLETE html document, with the fragment offsets taken
/// from the document's own StartFragment/EndFragment markers. This is what
/// cfHtmlEncode would have to become to preserve out-of-fragment context.
Uint8List _cfHtmlFullDocument(String doc) {
  String hdr(int sh, int eh, int sf, int ef) =>
      'Version:0.9\r\n'
      'StartHTML:${sh.toString().padLeft(10, '0')}\r\n'
      'EndHTML:${eh.toString().padLeft(10, '0')}\r\n'
      'StartFragment:${sf.toString().padLeft(10, '0')}\r\n'
      'EndFragment:${ef.toString().padLeft(10, '0')}\r\n';
  final headerLen = utf8.encode(hdr(0, 0, 0, 0)).length;
  final docBytes = utf8.encode(doc);
  int byteOf(int charIndex) => utf8.encode(doc.substring(0, charIndex)).length;

  const open = '<!--StartFragment-->';
  const close = '<!--EndFragment-->';
  final si = doc.indexOf(open);
  final ei = doc.indexOf(close);
  final sf = headerLen + (si >= 0 ? byteOf(si + open.length) : 0);
  final ef = headerLen + (ei >= 0 ? byteOf(ei) : docBytes.length);

  final out = BytesBuilder();
  out.add(utf8.encode(hdr(headerLen, headerLen + docBytes.length, sf, ef)));
  out.add(docBytes);
  out.addByte(0);
  return out.toBytes();
}

void main(List<String> args) {
  if (!Platform.isWindows) {
    print('Windows only.');
    exitCode = 2;
    return;
  }
  switch (args.isEmpty ? 'dump' : args.first) {
    case 'write':
      _write();
    case 'read':
      _readSide();
    case 'roundtrip':
      _roundTrip();
    case 'watch':
      // Does anything else on this machine overwrite the clipboard after we
      // write it? GetClipboardSequenceNumber bumps on every write by any
      // process, so a change here is a third party clobbering our formats.
      // A running clipboard manager (an installed Relic, Windows clipboard
      // history, Office) is the usual suspect, and it makes interop results
      // look intermittent for reasons that have nothing to do with our code.
      writeRichToClipboard(_plain,
          cfHtml: cfHtmlEncode(_html),
          rtf: Uint8List.fromList(utf8.encode(_rtf)));
      final seq0 = clipboardSequence();
      print('  wrote, sequence = $seq0');
      for (var i = 1; i <= 12; i++) {
        Sleep(250);
        final seq = clipboardSequence();
        if (seq != seq0) {
          final names = _enumerate().map((e) => e.$2).toList();
          _fail('at ${i * 250}ms someone else wrote (sequence $seq0 -> $seq)');
          print('  clipboard now holds: ${names.join(", ")}');
          final stillRich = names.contains('HTML Format');
          print(stillRich
              ? '  rich formats survived their write'
              : '  RICH FORMATS DESTROYED by that write');
          return;
        }
      }
      _pass('sequence held at $seq0 for 3s, nothing else wrote');
    case 'replayclean':
      // The candidate fix: keep the WHOLE CF_HTML document (so the <style>
      // block and the table wrappers survive) but strip the file:/// <link>
      // elements, which point at the source machine's temp dir and would
      // otherwise sync the username. Offsets are recomputed from the markers.
      final raw2 = _read(_fmt('HTML Format'));
      final t2 = _read(13);
      if (raw2 == null || t2 == null) {
        _fail('need both plain text and HTML Format on the clipboard');
        break;
      }
      final full = utf8.decode(raw2, allowMalformed: true);
      final start = full.indexOf('<html');
      final doc = start < 0 ? full : full.substring(start);
      final cleaned = doc.replaceAll(
        RegExp(r'<link[^>]*href="?file:///[^">]*"?[^>]*>', caseSensitive: false),
        '',
      );
      print('  document ${doc.length} chars -> ${cleaned.length} after strip');
      cleaned.contains('file:///')
          ? _fail('a file:/// reference survived the strip')
          : _pass('no file:/// paths remain');
      writeRichToClipboard(_utf16(t2),
              cfHtml: _cfHtmlFullDocument(cleaned),
              rtf: _read(_fmt('Rich Text Format')))
          ? _pass('replayed the cleaned full document')
          : _fail('replay failed');
    case 'replayraw':
      // Diagnosis check: replay the source app's CF_HTML document byte for
      // byte instead of re-wrapping just the fragment. If a target that fails
      // the normal round trip passes this one, the loss is the discarded
      // out-of-fragment context (the <style> block and the table wrappers),
      // not the clipboard plumbing.
      final raw = _read(_fmt('HTML Format'));
      final t = _read(13);
      if (raw == null || t == null) {
        _fail('need both plain text and HTML Format on the clipboard');
      } else {
        writeRichToClipboard(_utf16(t),
                cfHtml: raw, rtf: _read(_fmt('Rich Text Format')))
            ? _pass('replayed ${raw.length} bytes of original CF_HTML verbatim')
            : _fail('replay failed');
      }
    case 'raw':
      final h = _read(_fmt('HTML Format'));
      if (h == null) {
        print('(no HTML Format)');
      } else {
        print('--- RAW CF_HTML (${h.length} bytes) ---');
        print(utf8.decode(h, allowMalformed: true));
        print('--- FRAGMENT WE KEEP (${cfHtmlDecode(h)?.length} chars) ---');
        print(cfHtmlDecode(h));
      }
    default:
      for (final (id, name) in _enumerate()) {
        print('$id  $name');
      }
  }
}

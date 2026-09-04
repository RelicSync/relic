// The formatting flavors that travel alongside a text relic's plain content.
//
// When you copy a styled paragraph, the source app puts several representations
// on the clipboard at once: plain text, HTML, and (on Windows and macOS) RTF.
// Relic used to keep only the plain one, so pasting into Slack or Word lost
// every bit of styling. A RichBody is the other flavors, stored next to
// `content` and written back alongside it on paste.
//
// Three rules shape this file:
//
//  * Plain text is always authoritative. A rich flavor is a bonus that can be
//    dropped at any point (over the cap, a read timeout, a secret, an old peer)
//    without the relic becoming wrong. Nothing here may ever be the only copy
//    of what the user captured.
//  * The stored HTML is untrusted third-party markup. It exists to be handed
//    back to the OS clipboard and nothing else. Never render it, never feed it
//    to the search index, never derive tags from it.
//  * It carries a fingerprint of the text it came from. Any writer that changes
//    `content` without knowing this field exists — relic-cli's upsert, a future
//    import path — leaves formatting behind that no longer matches. Readers go
//    through RichBody.forPlain, which returns null on a mismatch, so stale
//    formatting is inert rather than wrong.
import 'dart:convert';
import 'dart:typed_data';

/// Cap on the serialized [RichBody] JSON, in bytes.
///
/// The binding constraint is the Worker's envelope gate, which rejects a push
/// when the request body exceeds `caps.item * 1.5` (10 MB * 1.5 on the free
/// tier). [encodedLength] counts toward `byte_size` (see `textByteSize`), so a
/// maximal 10 MB text relic plus 256 KB of rich seals to roughly 13.7 MB of
/// base64 against a 15 MB ceiling and stays comfortable; 1 MB would not.
///
/// It is also the right product number. A styled paragraph or a small table is
/// 2-30 KB of HTML and 5-60 KB of RTF. What 256 KB excludes is exactly what you
/// do not want syncing: Word RTF with embedded `\pict` image data, or a
/// thousand-row spreadsheet dumped as HTML.
const int kRichMaxBytes = 256 * 1024;

/// Fingerprint of the plain text a [RichBody] was derived from.
///
/// Full-pass FNV-1a, deliberately NOT the sampled hash `RelicDb` uses for
/// `content_hash`. That one samples about 64 bytes and so cannot see a
/// same-length edit in an unsampled region, which is precisely the case this
/// fingerprint exists to catch. A full pass costs nothing next to the regex
/// sweeps `_tagsFor` already runs over the same string.
int richFingerprint(String plain) {
  var h = 0x811c9dc5;
  for (final byte in utf8.encode(plain)) {
    h ^= byte;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h;
}

/// The formatting flavors for one relic. Immutable; at least one of [html] and
/// [rtf] is non-null (a body with neither is never constructed — the factories
/// return null instead).
class RichBody {
  /// [richFingerprint] of the plain text these flavors came from.
  final int h;

  /// An HTML fragment, as the source app published it. Untrusted markup.
  final String? html;

  /// Raw RTF bytes, as the source app published them.
  final Uint8List? rtf;

  const RichBody._({required this.h, this.html, this.rtf});

  /// Build a body for [plain] from whatever flavors the clipboard offered.
  ///
  /// Returns null when there is nothing worth keeping. Over the cap, RTF is
  /// dropped first and HTML kept: HTML works on all five platforms, RTF only on
  /// Windows and macOS. If HTML alone is still over, nothing is stored.
  static RichBody? capture({
    required String plain,
    String? html,
    Uint8List? rtf,
  }) {
    final h = (html != null && html.isNotEmpty) ? html : null;
    final r = (rtf != null && rtf.isNotEmpty) ? rtf : null;
    if (h == null && r == null) return null;

    final fp = richFingerprint(plain);
    final both = RichBody._(h: fp, html: h, rtf: r);
    if (both.encodedLength <= kRichMaxBytes) return both;

    if (h == null) return null; // RTF alone was already too big
    final htmlOnly = RichBody._(h: fp, html: h);
    return htmlOnly.encodedLength <= kRichMaxBytes ? htmlOnly : null;
  }

  /// Wire/DB shape. RTF is base64 because it is bytes, not text.
  Map<String, dynamic> toJson() => {
        'h': h,
        if (html != null) 'html': html,
        if (rtf != null) 'rtf': base64.encode(rtf!),
      };

  /// Parse a stored or synced body. Returns null on anything malformed, on a
  /// body with no flavors, or on one over [kRichMaxBytes].
  ///
  /// The cap is re-applied on the way IN, not just on capture: a peer running a
  /// future build with a larger cap, or a hostile server, must not be able to
  /// make this device store an oversized blob in a text row.
  static RichBody? fromJson(Object? v) {
    if (v == null) return null;
    try {
      final j = v is String ? jsonDecode(v) : v;
      if (j is! Map) return null;
      final fp = (j['h'] as num?)?.toInt();
      if (fp == null) return null;
      final html = j['html'] as String?;
      final rtfB64 = j['rtf'] as String?;
      final rtf = rtfB64 == null ? null : base64.decode(rtfB64);
      if ((html == null || html.isEmpty) && (rtf == null || rtf.isEmpty)) {
        return null;
      }
      final body = RichBody._(
        h: fp,
        html: (html != null && html.isNotEmpty) ? html : null,
        rtf: (rtf != null && rtf.isNotEmpty) ? rtf : null,
      );
      return body.encodedLength <= kRichMaxBytes ? body : null;
    } catch (_) {
      return null; // malformed JSON, bad base64 — treat as absent
    }
  }

  /// The body only if it still matches [plain]. This is the single accessor
  /// every reader must use; see the fingerprint rule at the top of the file.
  RichBody? forPlain(String? plain) =>
      plain != null && richFingerprint(plain) == h ? this : null;

  /// Serialized size of this body, in bytes: what it costs in the DB row, in
  /// the sealed payload, and therefore in `byte_size`. Base64 for RTF is
  /// included because that is the form that is actually stored.
  int get encodedLength => utf8.encode(jsonEncode(toJson())).length;

  @override
  bool operator ==(Object other) =>
      other is RichBody &&
      other.h == h &&
      other.html == html &&
      _sameBytes(other.rtf, rtf);

  @override
  int get hashCode => Object.hash(h, html, rtf?.length);

  static bool _sameBytes(Uint8List? a, Uint8List? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// --- Dropping the source's skin ---------------------------------------------
//
// A browser puts the page's LOOK on the clipboard as well as its structure.
// Copy three sentences out of a dark-themed site and the fragment carries
// `color: #e6edf3` and `background-color: #0d1117` on every span, so pasting it
// into a white document gives you white text in black boxes. That is not a bug
// in anything: Chrome published it, Word's default is to keep source
// formatting, and a direct paste does exactly the same. It is still the wrong
// default for a clipboard manager, because you paste things weeks later into
// documents you were not thinking about when you copied.
//
// So the skin goes and the structure stays. Bold, italic, links, lists,
// headings, tables and alignment all survive and take the destination's look.
//
// This runs on the way OUT, never on capture: the stored HTML keeps everything
// the source published, so the decision is reversible and nothing is lost.
// RTF is deliberately left alone. The dark-page problem is a web problem and
// the web publishes HTML; RTF comes from Word and Pages, where the formatting
// is the user's own and Word prefers RTF over HTML when both are offered.
//
// Regexes, not a parser. The scrub is best-effort by design — plain text is
// authoritative, so the worst case is a flavor that keeps a colour it should
// have dropped. Every rewrite happens INSIDE a tag, never over a text node, so
// prose that happens to contain "color = red" is untouched.

/// CSS properties dropped on the way to the clipboard. Anything ending in
/// `-color` goes as well, which covers `background-color`, `border-color`,
/// `text-decoration-color`, `caret-color` and the `-webkit-` spellings without
/// listing them: a real capture from GitHub had five different `*-color`
/// properties on it.
///
/// Shorthands that can carry a colour among other values (`border: 1px solid
/// #fff`) keep it. Picking a colour out of a shorthand value means parsing the
/// value, and the failure it would fix is a border that blends in, not text you
/// cannot read.
const _skinProps = {
  'color',
  'background',
  'background-image',
  'font',
  'font-family',
  'font-size',
  'text-shadow',
  'box-shadow',
  'outline',
  '-webkit-text-stroke',
  '-webkit-text-stroke-width',
};

/// The pre-CSS attribute spellings of the same thing (`<font color>`,
/// `<td bgcolor>`, `<body text link vlink>`).
final _skinAttrs = RegExp(
  r'''\s(?:bgcolor|background|color|text|link|vlink|alink)\s*=\s*'''
  r'''(?:"[^"]*"|'[^']*'|[^\s>]+)''',
  caseSensitive: false,
);

final _htmlTag = RegExp(r'<[a-zA-Z][^>]*>');
// The leading whitespace is part of the match so that removing an attribute
// closes the gap it leaves rather than turning `<p style="color:red">` into
// `<p >`.
final _styleAttr = RegExp(
  r'''(\s*)\bstyle\s*=\s*(["'])([\s\S]*?)\2''',
  caseSensitive: false,
);
final _styleBlock = RegExp(
  r'<style\b[^>]*>([\s\S]*?)</style\s*>',
  caseSensitive: false,
);
final _cssBlock = RegExp(r'\{([^{}]*)\}');

/// Keep the declarations in one `;`-separated CSS run that are not skin.
String _keepDecls(String css) {
  final kept = <String>[];
  for (final d in css.split(';')) {
    final i = d.indexOf(':');
    if (i < 0) continue; // empty or malformed: nothing worth keeping
    final prop = d.substring(0, i).trim().toLowerCase();
    if (prop.isEmpty || prop.endsWith('-color') || _skinProps.contains(prop)) {
      continue;
    }
    kept.add(d.trim());
  }
  return kept.join('; ');
}

String _scrubTag(String tag) => tag.replaceAllMapped(_styleAttr, (m) {
      final kept = _keepDecls(m[3]!);
      return kept.isEmpty ? '' : '${m[1]}style=${m[2]}$kept${m[2]}';
    }).replaceAll(_skinAttrs, '');

/// Strip the source page's colours, backgrounds and fonts from [html], leaving
/// everything that carries meaning. See the note above for why and where.
String stripHtmlSkin(String html) {
  // Class-based rules first: Word and Excel put their cell and paragraph
  // styling in a <style> block rather than inline, and the selectors have to
  // survive or a pasted table loses its alignment and borders along with its
  // colours.
  final out = html.replaceAllMapped(
    _styleBlock,
    (m) => m[0]!.replaceFirst(m[1]!,
        m[1]!.replaceAllMapped(_cssBlock, (c) => '{${_keepDecls(c[1]!)}}')),
  );
  return out.replaceAllMapped(_htmlTag, (m) => _scrubTag(m[0]!));
}

// --- CF_HTML ----------------------------------------------------------------
//
// Windows wraps clipboard HTML in a byte-offset header:
//
//   Version:0.9
//   StartHTML:00000097
//   EndHTML:00000241
//   StartFragment:00000131
//   EndFragment:00000209
//   <html><body>
//   <!--StartFragment -->  ...the fragment...  <!--EndFragment-->
//   </body></html>
//
// Offsets are byte offsets into the UTF-8 payload, zero-padded to 8 digits, and
// the whole thing is null-terminated.
//
// super_clipboard implements this, but format_conversions.dart is not exported
// from the package, so it cannot be reached by name. Ours differs in one
// deliberate way: a malformed header returns null instead of throwing, because
// one app publishing a bad header must not break the capture ladder for every
// other app.
// https://learn.microsoft.com/en-us/windows/win32/dataxchg/html-clipboard-format

const _crlf = '\r\n';
const _fragmentOpen = '<html><body>$_crlf<!--StartFragment -->';
const _fragmentClose = '<!--EndFragment-->$_crlf</body>$_crlf</html>';

String _cfHtmlHeader({
  int startHtml = 0,
  int endHtml = 0,
  int startFragment = 0,
  int endFragment = 0,
  bool includeHtml = false,
}) {
  String n(int v) => v.toString().padLeft(8, '0');
  final b = StringBuffer()
    ..write('Version:0.9$_crlf')
    ..write('StartHTML:${n(startHtml)}$_crlf')
    ..write('EndHTML:${n(endHtml)}$_crlf')
    ..write('StartFragment:${n(startFragment)}$_crlf')
    ..write('EndFragment:${n(endFragment)}$_crlf');
  if (includeHtml) b.write(_fragmentOpen);
  return b.toString();
}

/// Frame an HTML fragment as CF_HTML bytes. Public for the Windows native write
/// path, which needs the bytes rather than a super_clipboard write.
Uint8List cfHtmlEncode(String html) {
  // Offsets are only stable once the header's own length is known, and the
  // length does not depend on the values because every number is padded to a
  // fixed 8 digits. So measure with placeholders, then fill in.
  final headerLen = utf8.encode(_cfHtmlHeader(includeHtml: true)).length;
  final startHtml = utf8.encode(_cfHtmlHeader()).length;
  final body = utf8.encode(const LineSplitter().convert(html).join(_crlf));
  final footer = utf8.encode(_fragmentClose);
  final total = headerLen + body.length + footer.length;
  final header = utf8.encode(_cfHtmlHeader(
    startHtml: startHtml,
    endHtml: total,
    startFragment: headerLen,
    endFragment: headerLen + body.length,
    includeHtml: true,
  ));

  final out = Uint8List(total + 1); // + null terminator
  out.setAll(0, header);
  out.setAll(header.length, body);
  out.setAll(header.length + body.length, footer);
  return out;
}

/// Pull the fragment back out of CF_HTML bytes. Null when the header is missing
/// or its offsets do not fit the payload.
String? cfHtmlDecode(Uint8List bytes) {
  final text = utf8.decode(bytes, allowMalformed: true);
  int? start;
  int? end;
  for (final line in const LineSplitter().convert(text)) {
    if (line.startsWith('StartFragment:')) {
      start = int.tryParse(line.substring('StartFragment:'.length).trim());
    } else if (line.startsWith('EndFragment:')) {
      end = int.tryParse(line.substring('EndFragment:'.length).trim());
    }
    if (start != null && end != null) break;
    // The header is the first few lines; the fragment itself can contain
    // anything, so stop looking once markup starts.
    if (line.startsWith('<')) break;
  }
  if (start == null || end == null) return null;
  if (start < 0 || end < start || end > bytes.length) return null;
  return utf8.decode(bytes.sublist(start, end), allowMalformed: true);
}

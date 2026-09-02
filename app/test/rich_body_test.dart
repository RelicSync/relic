// The pure half of rich text: the CF_HTML codec, the size cap, and the
// fingerprint that makes stale formatting inert.
//
// Nothing here touches a clipboard or a platform channel, so it runs anywhere.
// The clipboard interop itself is manual-matrix territory.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/models/rich_body.dart';
import 'package:relic_app/platform/rich_formats.dart';

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('CF_HTML', () {
    test('round-trips a fragment', () {
      const html = '<b>hello</b>';
      expect(cfHtmlDecode(cfHtmlEncode(html)), html);
    });

    test('round-trips non-ASCII, quotes and angle brackets in attributes', () {
      const html = '<a href="x?a=1&b=2" title="wörld">jörg &amp; co</a>';
      expect(cfHtmlDecode(cfHtmlEncode(html)), html);
    });

    test('offsets are byte offsets, not character offsets', () {
      // Four-byte astral chars ahead of the fragment would break any encoder
      // that padded offsets by string length.
      const html = '<p>🙂🙂 tail</p>';
      expect(cfHtmlDecode(cfHtmlEncode(html)), html);
    });

    test('newlines normalize to CRLF', () {
      expect(cfHtmlDecode(cfHtmlEncode('<p>a\nb</p>')), '<p>a\r\nb</p>');
    });

    test('the payload is null-terminated', () {
      expect(cfHtmlEncode('<i>x</i>').last, 0);
    });

    test('a malformed header returns null rather than throwing', () {
      expect(cfHtmlDecode(bytes('Version:0.9\r\n<html>no offsets</html>')),
          isNull);
      expect(cfHtmlDecode(bytes('')), isNull);
      expect(cfHtmlDecode(bytes('total garbage')), isNull);
    });

    test('offsets pointing past the payload return null', () {
      final broken = bytes(
        'Version:0.9\r\nStartHTML:00000097\r\nEndHTML:00000241\r\n'
        'StartFragment:00000131\r\nEndFragment:00099999\r\n<html></html>',
      );
      expect(cfHtmlDecode(broken), isNull);
    });

    test('decodes a payload framed the way browsers frame it', () {
      // Not our own encoder's output. Browsers pad offsets to 10 digits rather
      // than 8, write `<!--StartFragment-->` with no space before the dashes,
      // and put a CRLF between <html> and <body>. Decoding has to work off the
      // offsets alone, never off a shape we assume.
      //
      // Offsets: the header is 105 bytes, then `<html>\r\n<body>\r\n` (16) and
      // `<!--StartFragment-->` (20) put the fragment at 141; it is 13 bytes, so
      // EndFragment is 154; the closing markup ends the payload at 190.
      final browserish = bytes(
        'Version:0.9\r\n'
        'StartHTML:0000000105\r\n'
        'EndHTML:0000000190\r\n'
        'StartFragment:0000000141\r\n'
        'EndFragment:0000000154\r\n'
        '<html>\r\n<body>\r\n<!--StartFragment--><b>styled</b><!--EndFragment-->'
        '\r\n</body>\r\n</html>',
      );
      expect(cfHtmlDecode(browserish), '<b>styled</b>');
    });
  });

  group('fingerprint', () {
    test('is stable and differs on any edit', () {
      expect(richFingerprint('hello'), richFingerprint('hello'));
      expect(richFingerprint('hello'), isNot(richFingerprint('hellp')));
      expect(richFingerprint(''), isNot(richFingerprint(' ')));
    });

    test('catches a same-length edit deep inside a long string', () {
      // The whole reason this is a full pass and not RelicDb's sampled hash:
      // a sampled hash can miss exactly this.
      final a = '${'x' * 5000}a${'y' * 5000}';
      final b = '${'x' * 5000}b${'y' * 5000}';
      expect(a.length, b.length);
      expect(richFingerprint(a), isNot(richFingerprint(b)));
    });
  });

  group('RichBody.capture', () {
    test('keeps both flavors when they fit', () {
      final r = RichBody.capture(
          plain: 'hi', html: '<b>hi</b>', rtf: bytes(r'{\rtf1 hi}'));
      expect(r, isNotNull);
      expect(r!.html, '<b>hi</b>');
      expect(r.rtf, isNotNull);
      expect(r.h, richFingerprint('hi'));
    });

    test('returns null when there is nothing to keep', () {
      expect(RichBody.capture(plain: 'hi'), isNull);
      expect(RichBody.capture(plain: 'hi', html: '', rtf: Uint8List(0)),
          isNull);
    });

    test('over the cap it drops RTF and keeps HTML', () {
      final r = RichBody.capture(
        plain: 'hi',
        html: '<b>hi</b>',
        rtf: Uint8List(kRichMaxBytes), // alone this blows the cap
      );
      expect(r, isNotNull);
      expect(r!.html, '<b>hi</b>');
      expect(r.rtf, isNull, reason: 'HTML works on more platforms, so it wins');
    });

    test('over the cap with HTML alone it stores nothing', () {
      final r = RichBody.capture(plain: 'hi', html: 'x' * (kRichMaxBytes + 1));
      expect(r, isNull);
    });

    test('oversized RTF with no HTML stores nothing', () {
      expect(RichBody.capture(plain: 'hi', rtf: Uint8List(kRichMaxBytes)),
          isNull);
    });
  });

  group('json', () {
    test('round-trips both flavors byte-identically', () {
      final rtf = Uint8List.fromList([0x7b, 0x5c, 0x72, 0x74, 0x66, 0x00, 0xff]);
      final a = RichBody.capture(plain: 'p', html: '<i>p</i>', rtf: rtf)!;
      final b = RichBody.fromJson(a.toJson())!;
      expect(b.html, a.html);
      expect(b.rtf, orderedEquals(rtf));
      expect(b.h, a.h);
      expect(b, a);
    });

    test('round-trips through a JSON string, the way the DB column stores it',
        () {
      final a = RichBody.capture(plain: 'p', html: '<i>p</i>')!;
      expect(RichBody.fromJson(jsonEncode(a.toJson())), a);
    });

    test('omits absent flavors', () {
      final j = RichBody.capture(plain: 'p', html: '<i>p</i>')!.toJson();
      expect(j.containsKey('rtf'), isFalse);
      expect(j.containsKey('html'), isTrue);
    });

    test('malformed input is absent, not an exception', () {
      expect(RichBody.fromJson(null), isNull);
      expect(RichBody.fromJson('not json'), isNull);
      expect(RichBody.fromJson('{}'), isNull, reason: 'no fingerprint');
      expect(RichBody.fromJson({'h': 1}), isNull, reason: 'no flavors');
      expect(RichBody.fromJson({'h': 1, 'rtf': 'not base64!!'}), isNull);
    });

    test('an over-cap body arriving from a peer is refused on the way in', () {
      // A peer on a future build with a bigger cap, or a hostile server, must
      // not be able to make this device store an oversized blob in a text row.
      final hostile = {'h': 1, 'html': 'x' * (kRichMaxBytes + 1)};
      expect(RichBody.fromJson(hostile), isNull);
    });
  });

  group('forPlain', () {
    test('returns the body when the text is unchanged', () {
      final r = RichBody.capture(plain: 'hello', html: '<b>hello</b>')!;
      expect(r.forPlain('hello'), same(r));
    });

    test('returns null once the text has been edited', () {
      // This is the CLI hazard as a test: `relic edit` rewrites content and
      // knows nothing about the rich column, so the leftover formatting has to
      // go inert on its own.
      final r = RichBody.capture(plain: 'hello', html: '<b>hello</b>')!;
      expect(r.forPlain('hello, world'), isNull);
      expect(r.forPlain(null), isNull);
    });
  });

  group('format constants', () {
    // Guards the two regressions that are easy to reintroduce by "simplifying"
    // back to Formats.htmlText / Formats.rtf.
    test('RTF publishes the Windows registered name, not a MIME type', () {
      expect(kRelicRtf.windows!.encodingFormats, contains('Rich Text Format'));
      expect(kRelicRtf.windows!.encodingFormats,
          isNot(contains('application/rtf')));
    });

    test('RTF offers both Linux MIME types', () {
      expect(kRelicRtf.fallback.encodingFormats,
          containsAll(['text/rtf', 'application/rtf']));
    });

    test('HTML decodes only CF_HTML on Windows', () {
      expect(kRelicHtml.windows!.decodingFormats, ['HTML Format']);
      expect(kRelicHtml.windows!.decodingFormats, isNot(contains('text/html')));
    });

    test('iOS publishes the UTI names, both directions', () {
      // The iOS write path is the plugin one (clipboard_bridge), so a codec
      // that quietly lost its ios arm would fall back to MIME names UIKit
      // apps never look for. public.html / public.rtf are what Pages, Notes,
      // Mail and Safari read and write.
      expect(kRelicHtml.ios!.encodingFormats, ['public.html']);
      expect(kRelicHtml.ios!.decodingFormats, ['public.html']);
      expect(kRelicRtf.ios!.encodingFormats, ['public.rtf']);
      expect(kRelicRtf.ios!.decodingFormats, ['public.rtf']);
    });
  });

  // Copying out of a dark-themed page used to paste as white text in black
  // boxes: the browser publishes `color` and `background-color` on every span,
  // and Word's default is to keep source formatting. Nothing was broken, but it
  // is the wrong default for a clipboard manager, where you paste weeks later
  // into a document you were not thinking about when you copied.
  //
  // So the skin goes on the way out and the structure stays.
  group('stripHtmlSkin', () {
    test('drops the source page colours and keeps the words', () {
      const html = '<span style="color: #e6edf3; background-color: #0d1117">'
          'The open-source clipboard manager.</span>';
      final out = stripHtmlSkin(html);

      expect(out, isNot(contains('background-color')));
      expect(out, isNot(contains('#0d1117')));
      expect(out, contains('The open-source clipboard manager.'));
    });

    test('a style attribute left with nothing goes away entirely', () {
      final out = stripHtmlSkin('<p style="color:red">hi</p>');
      expect(out, '<p>hi</p>',
          reason: 'an empty style="" is litter, not a no-op');
    });

    test('keeps the declarations that carry meaning', () {
      final out = stripHtmlSkin(
          '<p style="font-weight: 700; color: red; text-align: center">x</p>');
      expect(out, contains('font-weight: 700'));
      expect(out, contains('text-align: center'));
      expect(out, isNot(contains('color')));
    });

    test('a link survives with its href intact', () {
      const html = '<a href="https://relic.space" style="color:#4493f8">'
          'relic.space</a>';
      final out = stripHtmlSkin(html);
      expect(out, contains('href="https://relic.space"'));
      expect(out, contains('relic.space</a>'));
      expect(out, isNot(contains('#4493f8')));
    });

    test('structure tags are never touched', () {
      const html = '<h2>Topics</h2><ul><li><b>a</b></li><li><i>b</i></li></ul>';
      expect(stripHtmlSkin(html), html);
    });

    test('the pre-CSS attribute spellings go too', () {
      final out = stripHtmlSkin(
          '<table><tr><td bgcolor="#000"><font color="red">x</font>'
          '</td></tr></table>');
      expect(out, isNot(contains('bgcolor')));
      expect(out, isNot(contains('"red"')));
      expect(out, contains('<table>'));
      expect(out, contains('x'));
    });

    test('a Word style block keeps its selectors and loses its colours', () {
      // Word and Excel put cell styling in a <style> block rather than inline.
      // The selectors have to survive or a pasted table loses its alignment and
      // borders along with its background.
      const html = '<style>td.x { color: #fff; text-align: right; '
          'border: 1px solid }</style><table><tr><td class="x">1</td></tr>'
          '</table>';
      final out = stripHtmlSkin(html);

      expect(out, contains('td.x {'), reason: 'the selector still applies');
      expect(out, contains('text-align: right'));
      expect(out, contains('border: 1px solid'));
      expect(out, isNot(contains('#fff')));
      expect(out, contains('class="x"'));
    });

    test('prose that talks about colour is left alone', () {
      // The scrub only ever rewrites inside a tag. Copying a CSS snippet out of
      // a docs page must not have its own text edited.
      const html = '<code>body { color = red; background = black }</code>';
      expect(stripHtmlSkin(html), html);
    });

    test('running it twice changes nothing the second time', () {
      const html = '<div style="color:#111; margin:4px"><b>x</b></div>';
      final once = stripHtmlSkin(html);
      expect(stripHtmlSkin(once), once);
    });

    test('every *-color property goes, not just the obvious one', () {
      // A real GitHub capture carried five different colour properties. The
      // rule is the suffix, so nobody has to keep the list in step with CSS.
      final out = stripHtmlSkin('<a style="text-decoration-color: #4493f8; '
          'border-color: #30363d; text-decoration-line: underline">x</a>');
      expect(out, contains('text-decoration-line: underline'));
      expect(out, isNot(contains('#4493f8')));
      expect(out, isNot(contains('#30363d')));
    });

    test('the shorthand forms go, not just the long ones', () {
      final out = stripHtmlSkin(
          '<p style="font: 12px Arial; background: #eee; padding: 2px">x</p>');
      expect(out, contains('padding: 2px'));
      expect(out, isNot(contains('Arial')));
      expect(out, isNot(contains('#eee')));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/models/rich_body.dart';

void main() {
  test('relative age is relative for 3 days, then the absolute date', () {
    const now = 10 * 365 * 86400;

    expect(relativeAge(now, now), 'just now');
    expect(relativeAge(now - 59, now), '59s');
    expect(relativeAge(now - 60, now), '1m');
    expect(relativeAge(now - 3599, now), '59m');
    expect(relativeAge(now - 3600, now), '1h');
    expect(relativeAge(now - 86399, now), '23h');
    expect(relativeAge(now - 86400, now), '1d');
    expect(relativeAge(now - 2 * 86400, now), '2d');
    // Past 3 days, it switches to the absolute capture date.
    final old = now - 3 * 86400;
    expect(relativeAge(old, now), formatCaptureDate(old));
    final older = now - 400 * 86400;
    expect(relativeAge(older, now), formatCaptureDate(older));
  });

  group('firstUrl / hasLink', () {
    Relic make({String? content, List<String> tags = const []}) => Relic(
          uid: 'u',
          createdAt: 0,
          updatedAt: 0,
          kind: Kind.string,
          source: Source.clipboard,
          promoted: false,
          byteSize: 0,
          content: content,
          tags: tags,
        );

    test('extracts a full https URL, even embedded in prose', () {
      expect(make(content: 'https://example.com/a?b=1').firstUrl,
          'https://example.com/a?b=1');
      expect(make(content: 'see https://relic.space/pricing for more').firstUrl,
          'https://relic.space/pricing');
    });

    test('strips trailing sentence punctuation', () {
      expect(make(content: 'go to https://relic.space.').firstUrl,
          'https://relic.space');
    });

    test('promotes a url-tagged bare domain to https', () {
      expect(make(content: 'example.com/path', tags: ['url']).firstUrl,
          'https://example.com/path');
    });

    test('no link for plain text or secrets', () {
      expect(make(content: 'just some notes').firstUrl, isNull);
      expect(make(content: 'just some notes').hasLink, isFalse);
      // A secret is never treated as an openable link.
      expect(make(content: 'https://example.com', tags: ['secret']).firstUrl,
          isNull);
    });
  });

  group('cleanDisplayText', () {
    test('strips leading list bullets and quote marks', () {
      expect(cleanDisplayText('- item'), 'item');
      expect(cleanDisplayText('• note'), 'note');
      expect(cleanDisplayText('> quoted'), 'quoted');
      expect(cleanDisplayText('  *  starred'), 'starred');
    });

    test('drops a stray one-letter fragment left by a mangled bullet', () {
      expect(cleanDisplayText('o 1.0.16+19 by'), '1.0.16+19 by');
    });

    test('preserves real leading words a/A/I', () {
      expect(cleanDisplayText('a quick fox'), 'a quick fox');
      expect(cleanDisplayText('I said'), 'I said');
    });

    test('all-punctuation falls back to the trimmed raw', () {
      expect(cleanDisplayText('---'), '---');
    });

    test('collapses internal whitespace and newlines', () {
      expect(cleanDisplayText('line1\n\nline2'), 'line1 line2');
      expect(cleanDisplayText('a\t b   c'), 'a b c');
    });
  });

  group('displayTitle wiring', () {
    Relic make({
      Kind kind = Kind.string,
      String? title,
      String? preview,
      String? content,
      String? filename,
    }) =>
        Relic(
          uid: 'u',
          createdAt: 0,
          updatedAt: 0,
          kind: kind,
          source: Source.clipboard,
          promoted: false,
          byteSize: 0,
          title: title,
          preview: preview,
          content: content,
          filename: filename,
        );

    test('an explicit title passes through untouched', () {
      expect(make(title: '- Keep this literal').displayTitle,
          '- Keep this literal');
    });

    test('preview and content are cleaned', () {
      expect(make(preview: '- item').displayTitle, 'item');
      expect(make(content: '> quoted').displayTitle, 'quoted');
    });

    test('a filename passes through untouched', () {
      expect(
        make(kind: Kind.file, filename: '.env').displayTitle,
        '.env',
      );
    });

    test('falls back to (untitled) when nothing usable', () {
      expect(make().displayTitle, '(untitled)');
    });
  });

  group('isUserTag', () {
    Relic make({List<String> userTags = const []}) => Relic(
          uid: 'u',
          createdAt: 0,
          updatedAt: 0,
          kind: Kind.string,
          source: Source.clipboard,
          promoted: false,
          byteSize: 0,
          userTags: userTags,
        );

    test('case-insensitive membership in userTags', () {
      final r = make(userTags: ['Work', 'Recipe']);
      expect(r.isUserTag('work'), isTrue);
      expect(r.isUserTag('WORK'), isTrue);
      expect(r.isUserTag('recipe'), isTrue);
      expect(r.isUserTag('url'), isFalse);
    });
  });

  group('rich text', () {
    Relic make({String? content, RichBody? rich, List<String> tags = const []}) =>
        Relic(
          uid: 'u',
          createdAt: 0,
          updatedAt: 0,
          kind: Kind.string,
          source: Source.clipboard,
          promoted: false,
          byteSize: 0,
          tags: tags,
          content: content,
          rich: rich,
        );

    test('toJson omits rich when absent and nests it when present', () {
      expect(make(content: 'hi').toJson().containsKey('rich'), isFalse);
      final rich = RichBody.capture(plain: 'hi', html: '<b>hi</b>')!;
      final j = make(content: 'hi', rich: rich).toJson();
      expect(j['rich'], rich.toJson());
    });

    test('richIfCurrent returns the body while the text is unchanged', () {
      final rich = RichBody.capture(plain: 'hi', html: '<b>hi</b>')!;
      expect(make(content: 'hi', rich: rich).richIfCurrent, rich);
    });

    test('editing the content makes leftover formatting inert', () {
      // The relic-cli hazard: its upsert writes `content` and does not list
      // `rich`, so the stale value survives in the row. It must not be pasted.
      final rich = RichBody.capture(plain: 'hi', html: '<b>hi</b>')!;
      final edited = make(content: 'hi', rich: rich).copyWith(content: 'bye');
      expect(edited.rich, isNotNull, reason: 'still stored');
      expect(edited.richIfCurrent, isNull, reason: 'but never served');
    });

    test('a secret never serves formatting, whatever is stored', () {
      // Second of the three enforcement points. Capture drops rich for a
      // secret, but a relic can also be marked secret AFTER capture, and
      // masking can be switched off and back on.
      final rich = RichBody.capture(plain: 'hi', html: '<b>hi</b>')!;
      final r = make(content: 'hi', rich: rich, tags: ['secret']);
      expect(r.isSecret, isTrue);
      expect(r.richIfCurrent, isNull);
    });

    test('copyWith carries rich through and clearRich drops it', () {
      final rich = RichBody.capture(plain: 'hi', html: '<b>hi</b>')!;
      final r = make(content: 'hi', rich: rich);
      expect(r.copyWith(title: 't').rich, rich);
      expect(r.copyWith(clearRich: true).rich, isNull);
    });
  });
}

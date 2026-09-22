// Naming a photo from the text read out of it.
//
// A photo shared from a phone arrives named after its file. Once a desktop has
// run OCR on it, the first real line of that text is a far better name, and it
// is deterministic: every device that looks at the same text lands on the same
// one, which is also how a later pass can tell that name apart from one the
// user typed.
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/models/relic.dart';

void main() {
  group('titleFromExtractedText', () {
    test('takes the first line that has words in it', () {
      expect(
        titleFromExtractedText('Blue Bottle Coffee\nOrder #4821\nTotal \$6.50'),
        'Blue Bottle Coffee',
      );
    });

    test('skips blank lines and lines with no letters', () {
      // A page number, a price, a divider: none of those is a name.
      expect(
        titleFromExtractedText('\n  \n12\n\$6.50\n----\nInvoice from Kessler Roofing'),
        'Invoice from Kessler Roofing',
      );
    });

    test('collapses the spacing OCR leaves behind', () {
      expect(
        titleFromExtractedText('  Blue   Bottle\tCoffee  '),
        'Blue Bottle Coffee',
      );
    });

    test('cuts a long line at a word boundary', () {
      final t = titleFromExtractedText(
        'The quick brown fox jumps over the lazy dog and keeps running '
        'through the field until it reaches the river',
      );
      expect(t, endsWith('…'));
      expect(t!.length, lessThanOrEqualTo(kExtractedTitleChars + 1));
      expect(t, isNot(contains(' …')), reason: 'no dangling space before the mark');
      expect(t, startsWith('The quick brown fox jumps over the lazy dog'));
    });

    test('a single letter is not a word', () {
      expect(titleFromExtractedText('A\n1\nx y'), 'x y');
    });

    test('nothing usable gives no title', () {
      expect(titleFromExtractedText(null), isNull);
      expect(titleFromExtractedText(''), isNull);
      expect(titleFromExtractedText('12\n\$6.50\n----'), isNull);
    });
  });

  group('isPlaceholderTitle', () {
    test('the filename and "Shared image" are placeholders', () {
      expect(
        isPlaceholderTitle(
          kind: Kind.photo,
          title: 'IMG_4821.jpg',
          filename: 'IMG_4821.jpg',
          content: null,
        ),
        isTrue,
      );
      expect(
        isPlaceholderTitle(
          kind: Kind.photo,
          title: kSharedImageTitle,
          filename: null,
          content: null,
        ),
        isTrue,
      );
    });

    test('a name built from the item\'s own text is a placeholder', () {
      expect(
        isPlaceholderTitle(
          kind: Kind.photo,
          title: 'Blue Bottle Coffee',
          filename: 'IMG_4821.jpg',
          content: 'Blue Bottle Coffee\nOrder #4821',
        ),
        isTrue,
      );
    });

    test('an empty title is a placeholder, a typed one is not', () {
      expect(
        isPlaceholderTitle(kind: Kind.photo, title: '  ', filename: null, content: null),
        isTrue,
      );
      expect(
        isPlaceholderTitle(
          kind: Kind.photo,
          title: 'Receipt for the client dinner',
          filename: 'IMG_4821.jpg',
          content: 'Blue Bottle Coffee\nOrder #4821',
        ),
        isFalse,
      );
    });

    test('only photos have placeholders', () {
      // A file's filename IS its headline, and text carries no filename.
      expect(
        isPlaceholderTitle(
          kind: Kind.file,
          title: 'invoice.pdf',
          filename: 'invoice.pdf',
          content: null,
        ),
        isFalse,
      );
      expect(
        isPlaceholderTitle(kind: Kind.string, title: null, filename: null, content: null),
        isFalse,
      );
    });
  });
}

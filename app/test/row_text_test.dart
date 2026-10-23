// What a list row says: the title over the start of the content, one line
// when there is no title, and never a secret's value.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/widgets/result_row.dart';
import 'package:relic_app/widgets/row_text.dart';

Relic _r(
  String content, {
  String? title,
  List<String> tags = const [],
  Kind kind = Kind.string,
  String? filename,
}) =>
    Relic(
      uid: 'u',
      createdAt: 1,
      updatedAt: 1,
      kind: kind,
      source: Source.clipboard,
      promoted: false,
      byteSize: content.length,
      content: content,
      preview: content,
      title: title,
      tags: tags,
      filename: filename,
    );

void main() {
  test('a titled item shows its title over the start of its text', () {
    final l = rowLines(_r('People who pair a phone in the first session keep it',
        title: 'Onboarding drop-off note'));
    expect(l.primary, 'Onboarding drop-off note');
    expect(l.secondary, startsWith('People who pair'));
  });

  test('titling off: the content is the one line, as before', () {
    final l = rowLines(_r('  - Thanks, talk soon'));
    expect(l.primary, 'Thanks, talk soon');
    expect(l.secondary, isNull);
  });

  test('a title that says what the text says shows once', () {
    final l = rowLines(_r('Thanks, talk soon!', title: 'Thanks talk soon'));
    expect(l.secondary, isNull);
  });

  test('a secret never puts its value in either line', () {
    final l = rowLines(_r('sk-proj-abc123', tags: const ['secret']));
    expect(l.primary, 'Secret');
    expect(l.secondary, isNull);
    expect(contentGlance(_r('sk-proj-abc123', tags: const ['secret'])), isNull);
  });

  test('links lose the scheme, www and the trailing slash', () {
    expect(shortUrl('https://www.hyperresearch.ai/search?q=a%20b/'),
        'hyperresearch.ai/search?q=a b');
    final l = rowLines(_r('https://hyperresearch.ai/',
        title: 'Hyperresearch Link', tags: const ['url']));
    expect(l.secondary, 'hyperresearch.ai');
    expect(l.secondaryMono, isTrue);
  });

  test('a long path keeps home as ~ and its last three parts', () {
    expect(
        shortPath(r'C:\Users\Jordan\PycharmProjects\relic\app\lib\ui\popup.dart',
            home: r'C:\Users\Jordan', max: 30),
        r'~\…\lib\ui\popup.dart');
    expect(shortPath('/home/j/a.txt', home: '/home/j'), '~/a.txt');
  });

  test('code shows its first non-blank line', () {
    final l = rowLines(_r('\n\n  final top = pad + _selected * h;\n  x();',
        title: 'Mini picker scroll offset math', tags: const ['code']));
    expect(l.secondary, 'final top = pad + _selected * h;');
  });

  test('a file whose title is not its name shows the name', () {
    final l = rowLines(
        _r('', title: 'Quarterly report', kind: Kind.file, filename: 'q3.pdf'));
    expect(l.secondary, 'q3.pdf');
  });

  test('only words the title lacks are marked, and a deep hit is brought in',
      () {
    const style = TextStyle();
    final none = highlightSpan('hyperresearch.ai/alternatives', ['hyperresearch'],
        style, const Color(0x55FFCC00),
        title: 'Hyperresearch alternative search link');
    expect(none.children, isNull, reason: 'the title already explains it');
    final deep = highlightSpan(
        'Kagi is great but slower and costs more. Perplexity Pro is \$20',
        ['perplexity'],
        style,
        const Color(0x55FFCC00),
        title: 'Competitor pricing notes');
    final text = deep.toPlainText();
    expect(text, startsWith('…'));
    expect(text, contains('Perplexity Pro'));
  });

  testWidgets('mini rows: two lines when titled, one when not', (t) async {
    Future<void> pump(Relic r) => t.pumpWidget(RelicTheme(
          colors: RelicColors.dark,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: MediaQuery(
              data: const MediaQueryData(),
              child: Material(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 340,
                    child: MiniResultRow(
                      relic: r,
                      selected: false,
                      imagePath: null,
                      onSelect: () {},
                      onActivate: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ));
    await pump(_r('People who pair a phone', title: 'Onboarding note'));
    expect(find.text('Onboarding note'), findsOneWidget);
    expect(find.text('People who pair a phone'), findsOneWidget);
    expect(t.getSize(find.byType(MiniResultRow)).height, MiniResultRow.height);

    await pump(_r('People who pair a phone'));
    expect(find.text('People who pair a phone'), findsOneWidget);

    await pump(_r('sk-proj-abc123', tags: const ['secret']));
    expect(find.textContaining('sk-proj'), findsNothing);
    expect(find.text('Secret'), findsOneWidget);
  });
}

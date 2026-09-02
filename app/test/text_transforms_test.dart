import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/text_transforms.dart';

void main() {
  group('copy-as transforms', () {
    test('upper / lower', () {
      expect(upperCase('Hello, wörld'), 'HELLO, WÖRLD');
      expect(lowerCase('Hello, WÖRLD'), 'hello, wörld');
    });

    test('title case capitalizes each word and lowers the rest', () {
      expect(titleCase('hello world'), 'Hello World');
      expect(titleCase('HELLO WORLD'), 'Hello World');
      expect(titleCase("it's a test"), "It's A Test");
      expect(titleCase('foo-bar (baz)'), 'Foo-bar (Baz)');
      expect(titleCase(''), '');
      expect(titleCase('123 abc'), '123 Abc');
    });

    test('single line collapses all whitespace runs', () {
      expect(singleLine('  a\n\nb\t c  '), 'a b c');
      expect(singleLine('one\r\ntwo'), 'one two');
      expect(singleLine('already flat'), 'already flat');
    });

    test('menu exposes the transforms in display order', () {
      // "Plain text" leads: it is the escape hatch from rich paste, so it is
      // the one people reach for most and it must not be buried.
      expect(copyAsTransforms.map((t) => t.$1).toList(),
          ['Plain text', 'UPPERCASE', 'lowercase', 'Title Case', 'Single line']);
    });

    test('plain text is the identity transform', () {
      // The stripping happens because the Copy-as menu writes through
      // putTextOnClipboard, which never carries the HTML/RTF flavors.
      expect(plainText('  Keep me  '), '  Keep me  ');
      expect(plainText(''), '');
    });
  });
}

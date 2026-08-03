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

    test('menu exposes four transforms in display order', () {
      expect(copyAsTransforms.map((t) => t.$1).toList(),
          ['UPPERCASE', 'lowercase', 'Title Case', 'Single line']);
    });
  });
}

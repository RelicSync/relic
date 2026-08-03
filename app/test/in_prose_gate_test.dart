import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/heuristic_tags.dart';

// inProseSearchTerms ran ~17 regexes over every relic's full text. Profiling
// found no single pathological pattern — just seventeen of them, at 2.1-2.4ms
// per 3KB relic, which made it the dominant cost of building the mobile search
// index and of every capture on every platform.
//
// It now takes ONE character sweep first and skips any scanner whose required
// characters are absent. That is only legitimate if a gate never changes what
// is emitted, so these tests come in pairs: the entity is still detected inside
// prose (the gate opened), and a near-miss that lacks the gating character
// still yields nothing (the gate didn't invent a match either).

void main() {
  group('the character gates never hide an entity', () {
    // Each case: prose containing the entity, and a term the scanner must emit.
    const cases = <String, ({String text, String term})>{
      'url': (text: 'see https://github.com/a/b for context', term: 'link'),
      'bare domain': (text: 'try spotify.com later today', term: 'website'),
      'email': (text: 'ping jo@example.com about it', term: 'mail'),
      'ip': (text: 'the box at 192.168.1.44 is down', term: 'ipaddress'),
      'uuid': (
        text: 'run id 550e8400-e29b-41d4-a716-446655440000 failed',
        term: 'guid'
      ),
      'mac': (text: 'nic 00:1B:44:11:3A:B7 dropped off', term: 'macaddress'),
      'card': (text: 'paid with 4111 1111 1111 1111 today', term: 'creditcard'),
      'win path': (text: r'saved to C:\Users\jo\notes.txt ok', term: 'filepath'),
      'unix path': (text: 'lives in /etc/nginx/nginx.conf now', term: 'folder'),
      'rel path': (text: 'edit app/lib/main.dart first', term: 'filepath'),
      'geo': (text: 'meet at 51.50722, -0.12750 tomorrow', term: 'coordinates'),
      'phone': (text: 'call 415-555-1234 when free', term: 'telephone'),
      'currency': (text: 'it came to \$1,299.00 all in', term: 'price'),
      'percent': (text: 'churn sits at 12.5% this month', term: 'percentage'),
      'time': (text: 'standup moved to 09:30 daily', term: 'clock'),
      'duration': (text: 'the job takes 45 minutes end to end', term: 'duration'),
      'measure': (text: 'the file is 240 mb compressed', term: 'measurement'),
    };

    cases.forEach((name, c) {
      test('$name is still found mid-prose', () {
        expect(inProseSearchTerms(c.text), contains(c.term),
            reason: 'the $name gate closed on text that should match');
      });
    });
  });

  group('the gates do not invent matches', () {
    // Text deliberately missing the gating character, where the scanner was
    // already meant to stay silent. Catches a gate written round the wrong
    // character — which would show up as terms appearing, not disappearing.
    test('prose with no digits yields no value-shape terms', () {
      final t = inProseSearchTerms(
          'a note about pricing and timing with no numerals at all');
      expect(t, isNot(contains('price')));
      expect(t, isNot(contains('clock')));
      expect(t, isNot(contains('duration')));
      expect(t, isNot(contains('measurement')));
      expect(t, isNot(contains('percentage')));
    });

    test('prose with no slash or backslash yields no path terms', () {
      expect(inProseSearchTerms('a note mentioning a folder and a file'),
          isNot(contains('filepath')));
    });

    test('prose with no at-sign yields no email terms', () {
      expect(inProseSearchTerms('mail me about the address on file'),
          isNot(contains('mail')));
    });

    test('a space-grouped id is not a phone number', () {
      // The pattern needs `[.-]` before the final four; the gate must not have
      // widened that to any separator.
      expect(inProseSearchTerms('order 123 456 7890 shipped'),
          isNot(contains('telephone')));
    });
  });

  test('an entity at the very end of long prose is still found', () {
    // Guards against "just cap the scan length", which would be a silent recall
    // loss rather than a speedup.
    final long = '${'lorem ipsum dolor sit amet ' * 400}ping jo@example.com';
    expect(inProseSearchTerms(long), contains('mail'));
  });

  test('a relic whose preview duplicates its content is not scanned twice', () {
    // _auxText drops a preview that content already contains. The terms must be
    // identical either way — this pins the dedup as a speed change only.
    const content = 'invoice for \$42.00 due 09:30 see /srv/app/bill.pdf';
    expect(inProseSearchTerms('$content $content'),
        unorderedEquals(inProseSearchTerms(content)));
  });
}

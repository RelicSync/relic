import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/heuristic_tags.dart';
import 'package:relic_app/data/tag_synonyms.dart';

void main() {
  group('number tag', () {
    test('fires on plain and separator-grouped digit runs', () {
      expect(detectTags('order id 32562002462497 shipped'), contains('number'));
      expect(detectTags('3256-2002-4624-97'), contains('number'));
      expect(detectTags('325 620 024'), contains('number'));
      expect(detectTags('12-345-678'), contains('number'));
      expect(detectTags('ref 9988776655 ok'), contains('number'));
      expect(detectTags('1,234,567'), contains('number')); // comma-grouped
    });

    test('long bare/grouped ids are number, not phone', () {
      expect(detectTags('32562002462497'), contains('number'));
      expect(detectTags('32562002462497'), isNot(contains('phone')));
      expect(detectTags('3256-2002-4624-97'), isNot(contains('phone')));
    });

    test('does not fire on short or broken runs', () {
      expect(detectTags('abc 123 def'), isNot(contains('number')));
      expect(detectTags('page 2 of 10'), isNot(contains('number')));
      expect(detectTags('12  34'), isNot(contains('number'))); // double space splits
    });

    test('structured non-numeric values suppress number', () {
      expect(detectTags('2024-01-15'), contains('date'));
      expect(detectTags('2024-01-15'), isNot(contains('number')));

      expect(detectTags('192.168.0.1'), contains('ip'));
      expect(detectTags('192.168.0.1'), isNot(contains('number')));

      expect(detectTags('a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6'), contains('hash'));
      expect(detectTags('a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6'),
          isNot(contains('number')));

      expect(detectTags('550e8400-e29b-41d4-a716-446655440000'),
          contains('uuid'));
      expect(detectTags('550e8400-e29b-41d4-a716-446655440000'),
          isNot(contains('number')));

      expect(detectTags('00:1A:2B:3C:4D:5E'), contains('mac'));
      expect(detectTags('00:1A:2B:3C:4D:5E'), isNot(contains('number')));

      expect(detectTags('v1.2.3'), contains('version'));
      expect(detectTags('v1.2.3'), isNot(contains('number')));

      expect(detectTags('https://example.com/page?id=12345678'),
          contains('url'));
      expect(detectTags('https://example.com/page?id=12345678'),
          isNot(contains('number')));
    });

    test('numeric identifiers also carry number (findable as a number)', () {
      expect(detectTags('4111 1111 1111 1111'), containsAll(['card', 'number']));
      expect(detectTags('+1 415 555 1234'), containsAll(['phone', 'number']));
      expect(detectTags('Your verification code is 482900'),
          containsAll(['otp', 'number']));
      expect(detectTags('1Z999AA10123456784'),
          containsAll(['tracking', 'number']));
    });
  });

  group('new semantic categories', () {
    test('currency', () {
      expect(detectTags(r'$1,299.00'), contains('currency'));
      expect(detectTags('€50'), contains('currency'));
      expect(detectTags('100 USD'), contains('currency'));
      expect(detectTags('USD 100'), contains('currency')); // code-prefixed
    });
    test('duration', () {
      expect(detectTags('takes 5 minutes'), contains('duration'));
      expect(detectTags('2 hours 30 minutes'), contains('duration'));
      expect(detectTags('3 days'), contains('duration'));
      expect(detectTags('45 secs'), contains('duration'));
    });
    test('percent', () {
      expect(detectTags('45%'), contains('percent'));
      expect(detectTags('12.5 percent'), contains('percent'));
    });
    test('time', () {
      expect(detectTags('meet at 14:30'), contains('time'));
      expect(detectTags('9:05 PM'), contains('time'));
    });
    test('measurement', () {
      expect(detectTags('5kg'), contains('measurement'));
      expect(detectTags('100 mb'), contains('measurement'));
      expect(detectTags('12.5 cm'), contains('measurement'));
      expect(detectTags('72°F'), contains('measurement'));
    });
    test('handle', () {
      expect(detectTags('ping @octocat please'), contains('handle'));
    });
    test('hashtag', () {
      expect(detectTags('shipping #flutter'), contains('hashtag'));
    });
  });

  group('new-category negatives', () {
    test('markdown heading is not a hashtag', () {
      expect(detectTags('# Heading'), isNot(contains('hashtag')));
    });
    test('hex color is not a hashtag', () {
      expect(detectTags('#fff'), contains('color'));
      expect(detectTags('#fff'), isNot(contains('hashtag')));
    });
    test('email is not a handle', () {
      expect(detectTags('user@example.com'), contains('email'));
      expect(detectTags('user@example.com'), isNot(contains('handle')));
    });
    test('plain count is not a measurement', () {
      expect(detectTags('5 minutes'), isNot(contains('measurement')));
    });
  });

  test('detectTags is deterministic', () {
    const input = 'balance 482900 as of 14:30 (+12%) @jordan #ops';
    expect(detectTags(input), detectTags(input));
  });

  test('combined semantic shapes co-exist', () {
    final tags = detectTags('balance 482900 as of 14:30 (+12%)');
    expect(tags, containsAll(['number', 'time', 'percent']));
  });

  group('value shapes fire only for naked / near-naked values', () {
    test('a long text mentioning a value is NOT that value', () {
      final doc = 'quarterly report: revenue grew to \$1.2M, churn fell 3%, '
          'the sprint took 2 weeks and the standup moved to 9:30am '
          '${'filler words to make this a real document ' * 5}';
      final tags = detectTags(doc);
      for (final t in [
        'currency', 'percent', 'duration', 'time', 'measurement', 'number',
      ]) {
        expect(tags, isNot(contains(t)), reason: t);
      }
    });

    test('multi-line text never earns value-shape tags', () {
      expect(detectTags('total\n\$14.99'), isNot(contains('currency')));
    });

    test('near-naked values still tag (a few words of context are fine)', () {
      expect(detectTags(r'Total: $1,299.99'), contains('currency'));
      expect(detectTags('15% off'), contains('percent'));
      expect(detectTags('2 hours 30 minutes'), contains('duration'));
      expect(detectTags('@jordan'), contains('handle'));
    });

    test('too many words around the value → no tag', () {
      expect(
        detectTags('your discount code saves you 25 percent at checkout '
            'through friday'),
        isNot(contains('percent')),
      );
    });

    test('color adjacency is gated the same way', () {
      expect(detectTags('background: teal'), contains('color'));
      final doc = 'a pixel art image of a wooden paneled vending machine, '
          'everything is black, the fill stroke is teal and the panels glow '
          'with a warm light in the corner of the arcade';
      expect(detectTags(doc), isNot(contains('color')));
    });

    test('detector re-audit round: secrets recall', () {
      // In-prose JWT must mask (curl commands, headers, .env lines).
      final jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0'
          '.SflKxwRJSMeKKF2QT4fwpM';
      expect(detectTags('curl -H "Authorization: Bearer $jwt"'),
          containsAll(['jwt', 'secret']));
      // Issuer-prefixed tokens.
      expect(detectTags('ghp_AbCdEf0123456789AbCdEf0123456789'),
          contains('secret'));
      expect(detectTags('token: xoxb-1234567890-abcdefghij'),
          contains('secret'));
      expect(detectTags('AIzaSyA1234567890abcdefghijklmnopqrstuv'),
          contains('secret'));
      expect(detectTags('glpat-AbCdEf0123456789AbCd'), contains('secret'));
    });

    test('detector re-audit round: sql/ticket/pluscode/ip FPs', () {
      expect(
          detectTags('Please select your seats early.\n'
              'Greetings from the whole team.'),
          isNot(contains('sql')));
      expect(detectTags('We will update the roadmap and set new goals.'),
          isNot(contains('sql')));
      expect(detectTags('select id, name from users where active = 1'),
          contains('sql'));
      expect(detectTags("UPDATE relics SET tags = 'x' WHERE uid = 1"),
          contains('sql'));
      expect(detectTags('We are SOC-2 compliant and use GPT-4 heavily.'),
          isNot(contains('ticket')));
      expect(detectTags('fixed in PROJ-1432 yesterday'), contains('ticket'));
      expect(detectTags('the sum 4567+89 equals 4656'),
          isNot(contains('location')));
      expect(detectTags('8FVC9G8F+6X'), contains('geo'));
      expect(detectTags('999.999.999.999'), isNot(contains('ip')));
      expect(detectTags('10.0.0.1'), contains('ip'));
    });

    test('detector re-audit round: unwrap + misc FPs', () {
      // Invisible bidi char (U+202C) from a web copy; trailing period.
      expect(detectTags('(406) 530-5734‬'), contains('phone'));
      expect(detectTags('douglas.butabi@gmail.com.'), contains('email'));
      // env below a shouted note line still counts.
      expect(
          detectTags('NOTE=this file is generated\nDATABASE_URL=postgres://x'),
          contains('env'));
      // Tab-indented / same-arity code is not a table.
      expect(detectTags('foo(a, b, c)\nbar(d, e, f)\nbaz(g, h, i)'),
          isNot(contains('csv')));
      // A source file:line reference is not a socket.
      expect(detectTags('the bug is in pipeline.rs:427 somewhere'),
          isNot(contains('port')));
      expect(detectTags('server listening on localhost:8080'),
          contains('port'));
      // All-hex English words are not commits.
      expect(detectTags('git blame says the file is defaced'),
          isNot(contains('commit')));
      // Accounting lines are not shell commands.
      expect(detectTags(r'$ 1,234.56 was charged to your card'),
          isNot(contains('command')));
      // Multi-line Windows path lists are not LaTeX.
      expect(
          detectTags('C:\\builds\\prod\\app.exe\nC:\\builds\\prod\\app.pdb'),
          isNot(contains('math')));
      // zł currency detection works (in prose terms).
      expect(inProseSearchTerms('that costs 10 zł in Krakow'),
          contains('money'));
    });

    test('verification round: adversarial follow-ups', () {
      // Filenames with TLD-colliding extensions are not links…
      for (final f in [
        'backup.sh', 'logo.ai', 'Safari.app', 'requirements.in', 'foo.cc',
        'Dockerfile.dev', 'build.info',
      ]) {
        expect(detectTags(f), isNot(contains('url')), reason: f);
      }
      // …but the same TLDs with real link evidence still are.
      expect(detectTags('devtools.fm/episode/91'), contains('url'));
      expect(detectTags('www.notion.sh'), isNot(contains('path')));
      // Malformed dotted quads are neither ip nor phone.
      expect(detectTags('999.999.999.999'), isNot(contains('phone')));
      expect(detectTags('192.168.001.001'), isNot(contains('phone')));
      // Clip-initial SQL needs no second token.
      expect(detectTags('SELECT id, name FROM users'), contains('sql'));
      expect(detectTags('SELECT count(*) FROM events'), contains('sql'));
      // Log/text line references are not sockets.
      expect(detectTags('tail server.log:1042 for the error'),
          isNot(contains('port')));
      // TSV with an empty first cell is still a table.
      expect(detectTags('a\tb\tc\n\te\tf'), contains('table'));
      // Digit-initial commands still count; prices still don't.
      expect(detectTags(r'$ 7z x backup.7z'), contains('command'));
      expect(detectTags(r'$ 1,234.56 was charged'), isNot(contains('command')));
      // "5 in the room" is English, not a measurement (in-prose terms).
      expect(inProseSearchTerms('there were 5 in the room when it started'),
          isNot(contains('measurement')));
      expect(inProseSearchTerms('the board is 24 cm wide'),
          contains('measurement'));
      // A bare domain's own path segment isn't a file path (in-prose terms).
      expect(
          inProseSearchTerms(
              'grab it from example.com/docs/guide.pdf when you can'),
          isNot(contains('filepath')));
    });

    test('detector re-audit round: whole-value url recall', () {
      expect(detectTags('copyc.at'), contains('url'));
      expect(detectTags('devtools.fm/episode/91'), contains('url'));
      expect(detectTags('relic://capture?text=hi'), contains('url'));
      // A bare domain with a file-ish path is a link, not a path.
      expect(detectTags('example.com/a/file.pdf'), isNot(contains('path')));
      // Plain words with a period are not urls.
      expect(detectTags('config.yaml'), isNot(contains('url')));
    });

    test('long texts stay findable by concept via in-prose terms', () {
      final doc = 'invoice notes: the deposit of \$500 clears friday, '
          'and the retainer covers 20% of scope '
          '${'more filler words for length ' * 4}';
      final terms = inProseSearchTerms(doc);
      expect(terms, containsAll(['money', 'price', 'percentage']));
    });
  });

  group('in-prose entity terms', () {
    test('surface link/url concept words for URLs anywhere in the text', () {
      expect(inProseSearchTerms('https://github.com/x/y'), contains('link'));
      expect(inProseSearchTerms('see https://github.com/x/y here'),
          contains('link'));
      expect(inProseSearchTerms('[y](https://github.com/x/y)'),
          contains('website'));
      expect(inProseSearchTerms('visit www.example.com'), contains('url'));
    });
    test('surface email concept words for embedded emails', () {
      expect(inProseSearchTerms('ping me at a@b.com ok'), contains('email'));
      expect(inProseSearchTerms('ping me at a@b.com ok'), contains('contact'));
    });
    test('empty for plain text with no entity', () {
      expect(inProseSearchTerms('just a plain note'), isEmpty);
      expect(inProseSearchTerms(null), isEmpty);
    });
  });

  group('tag synonyms', () {
    test('cover the new categories and stay concept-only', () {
      expect(tagSearchTerms('number'), contains('numeric'));
      expect(tagSearchTerms('url'), contains('link'));
      expect(tagSearchTerms('secret'), contains('password'));
      // The literal tag word must never appear in its own synonym list.
      for (final entry in kTagSynonyms.entries) {
        expect(entry.value, isNot(contains(entry.key)),
            reason: '${entry.key} lists itself as a synonym');
      }
    });
  });

  group('new entity detectors', () {
    test('doi / arxiv / orcid → academic tags', () {
      expect(detectTags('see 10.1000/xyz123 for details'),
          containsAll(['doi', 'paper']));
      expect(detectTags('arXiv:2301.01234'), containsAll(['arxiv', 'paper']));
      expect(detectTags('orcid.org/0000-0002-1825-0097'), contains('orcid'));
    });
    test('iban passes mod-97 and is bank, not secret', () {
      final tags = detectTags('GB82WEST12345698765432');
      expect(tags, containsAll(['iban', 'bank']));
      expect(tags, isNot(contains('secret')));
    });
    test('ssn is secret-class and suppresses number/phone', () {
      final tags = detectTags('123-45-6789');
      expect(tags, containsAll(['ssn', 'secret']));
      expect(tags, isNot(contains('number')));
      expect(tags, isNot(contains('phone')));
    });
    test('coordinates: DMS and plus code', () {
      expect(detectTags('''40°26'46"N 79°58'56"W'''), contains('geo'));
      expect(detectTags('plus code 87G8Q23F+GF'),
          containsAll(['location', 'geo']));
    });
    test('tables: markdown delimiter row and CSV', () {
      expect(detectTags('| a | b |\n| --- | --- |'),
          containsAll(['table', 'markdown']));
      expect(detectTags('a,b,c\n1,2,3\n4,5,6'), containsAll(['table', 'csv']));
    });
    test('isbn / swift are keyword-gated', () {
      expect(detectTags('ISBN 978-3-16-148410-0'),
          containsAll(['isbn', 'book']));
      expect(detectTags('SWIFT: DEUTDEFF'), containsAll(['swift', 'bank']));
    });
    test('vin passes its check digit', () {
      expect(detectTags('1HGBH41JXMN109186'),
          containsAll(['vin', 'vehicle']));
    });
    test('commit / port / env / math / coupon / routing', () {
      expect(detectTags('git commit a1b2c3d'), contains('commit'));
      expect(detectTags('running on localhost:8080'), contains('port'));
      expect(detectTags('export NODE_ENV=production'), contains('env'));
      expect(detectTags(r'the formula \frac{a}{b} here'), contains('math'));
      expect(detectTags('use code SAVE20 now'), contains('coupon'));
      expect(detectTags('routing 021000021'), containsAll(['routing', 'bank']));
    });
    test('ticket key vs standards prefix', () {
      expect(detectTags('fixed PROJ-123 today'), contains('ticket'));
      expect(detectTags('UTF-8 encoding'), isNot(contains('ticket')));
    });
    test('named color only whole-value or in context', () {
      expect(detectTags('teal'), contains('color'));
      expect(detectTags('background: teal'), contains('color'));
      expect(detectTags('she wore gold today'), isNot(contains('color')));
    });
    test('base64 blob vs a hex hash', () {
      expect(detectTags(base64Encode(utf8.encode('x' * 60))),
          contains('base64'));
      final hex = 'a' * 64;
      expect(detectTags(hex), contains('hash'));
      expect(detectTags(hex), isNot(contains('base64')));
    });
  });

  group('detector false-positive negatives', () {
    test('a bare 8-letter word is not swift', () {
      expect(detectTags('OVERVIEW'), isNot(contains('swift')));
    });
    test('a clock time is not a port', () {
      expect(detectTags('12:34'), isNot(contains('port')));
    });
  });

  group('in-prose structural scanners', () {
    test('embedded ip / uuid / mac / path / phone / card', () {
      expect(inProseSearchTerms('server at 192.168.1.1 down'), contains('ip'));
      expect(
          inProseSearchTerms('id 550e8400-e29b-41d4-a716-446655440000 here'),
          contains('uuid'));
      expect(inProseSearchTerms('mac 00:1A:2B:3C:4D:5E ok'), contains('mac'));
      expect(inProseSearchTerms(r'see C:\Users\x\file.txt'), contains('path'));
      expect(inProseSearchTerms('open /usr/local/bin/app now'), contains('path'));
      expect(inProseSearchTerms('call (555) 123-4567 today'), contains('phone'));
      expect(inProseSearchTerms('card 4111 1111 1111 1111 exp'), contains('card'));
    });
    test('gated scanners reject casual look-alikes', () {
      expect(inProseSearchTerms('coords 1.5, 2.5'), isNot(contains('geo')));
      expect(inProseSearchTerms('37.7749, -122.4194'), contains('geo'));
      expect(inProseSearchTerms('call 5551234567'), isNot(contains('phone')));
    });
  });

  group('domain → noun map', () {
    test('service nouns surface for embedded links', () {
      expect(inProseSearchTerms('watch https://youtu.be/abc123'),
          contains('video'));
      expect(inProseSearchTerms('repo https://github.com/x/y'),
          contains('repo'));
      expect(inProseSearchTerms('song https://open.spotify.com/track/x'),
          contains('song'));
    });
    test('scheme-less domains map too', () {
      final terms = inProseSearchTerms('go to spotify.com now');
      expect(terms, contains('song'));
      expect(terms, contains('link'));
    });
    test('risky short host is isolated (max.com is not x.com)', () {
      final terms = inProseSearchTerms('https://max.com/x');
      expect(terms, contains('movie'));
      expect(terms, isNot(contains('tweet')));
    });
  });

  group('detector FP fixes (audit regressions)', () {
    test('commit needs a hex letter, not a plain number/word', () {
      expect(detectTags('checkout aisle had 1000000 items'),
          isNot(contains('commit')));
      expect(detectTags('please head to the next page'),
          isNot(contains('commit')));
      expect(detectTags('git commit a1b2c3d'), contains('commit')); // still fires
    });
    test('coupon does not fire on error/status "code"', () {
      expect(detectTags('error code E5000'), isNot(contains('coupon')));
      expect(detectTags('the code review of PR12345'),
          isNot(contains('coupon')));
      expect(detectTags('use code SAVE20 now'), contains('coupon')); // still fires
    });
    test('swift needs an anchor, not just the word "swift"', () {
      expect(detectTags('Taylor Swift CONCERTS'), isNot(contains('swift')));
      expect(detectTags('Swift programming OVERVIEW'), isNot(contains('swift')));
      expect(detectTags('SWIFT: DEUTDEFF'), contains('swift')); // still fires
    });
    test('env ignores shouted note prefixes', () {
      expect(detectTags('IMPORTANT=READ THIS'), isNot(contains('env')));
      expect(detectTags('TODO=fix later'), isNot(contains('env')));
      expect(detectTags('export NODE_ENV=production'), contains('env'));
    });
    test('ticket skips highway/product prefixes', () {
      expect(detectTags('WD-40 spray'), isNot(contains('ticket')));
      expect(detectTags('US-101 highway'), isNot(contains('ticket')));
      expect(detectTags('fixed PROJ-123 today'), contains('ticket'));
    });
    test('math ignores windows path segments', () {
      final t = detectTags(r'C:\sum\data');
      expect(t, contains('path'));
      expect(t, isNot(contains('math')));
    });
    test('color: adjacency required; ambiguous whole-words excluded', () {
      expect(detectTags('theme park with orange groves'),
          isNot(contains('color')));
      expect(detectTags('background noise at the pink floyd concert'),
          isNot(contains('color')));
      expect(detectTags('gold'), isNot(contains('color'))); // ambiguous
      expect(detectTags('teal'), contains('color')); // unambiguous whole-value
      expect(detectTags('background: teal'), contains('color')); // adjacency
    });
    test('phone-in-prose rejects uniformly space-grouped ids', () {
      expect(inProseSearchTerms('SKU 100 200 3000'), isNot(contains('phone')));
      expect(inProseSearchTerms('order 123 456 7890 now'),
          isNot(contains('phone')));
      expect(inProseSearchTerms('call 415-555-1234'), contains('phone'));
    });
  });

  group('coverage additions', () {
    test('crypto wallets and diffs', () {
      expect(detectTags('0xde0B295669a9FD93d5F28D9Ec85E40f4cb697BAE'),
          containsAll(['wallet', 'crypto']));
      expect(detectTags('bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq'),
          contains('wallet'));
      expect(detectTags('diff --git a/x b/x\n@@ -1,2 +1,2 @@'),
          containsAll(['diff', 'code']));
    });
    test('new domains, regional TLD, and the aws mis-peel fix', () {
      expect(inProseSearchTerms('https://chatgpt.com/c/abc'), contains('chat'));
      expect(inProseSearchTerms('https://www.amazon.co.uk/dp/x'),
          contains('product')); // regional TLD no longer a blind spot
      final aws = inProseSearchTerms('https://aws.amazon.com/s3/');
      expect(aws, contains('console'));
      expect(aws, isNot(contains('product'))); // shadows the amazon.com mis-peel
    });
  });
}

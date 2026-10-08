// Copy context: the pure helpers, the browser link on the clipboard, the
// device-only table, and the repo's keep / never-for-secrets / forget rules.
//
// The repo cases need a sandbox:
//   RELIC_DATA_DIR=$(mktemp -d) flutter test test/copy_context_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/data/relic_db.dart';
import 'package:relic_app/models/copy_context.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/models/rich_body.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CopyContext', () {
    test('a selection matches the copy despite whitespace or a trailing newline', () {
      expect(CopyContext.sameSelection('sudo  systemctl\nrestart nginx', 'sudo systemctl restart nginx'), isTrue);
      expect(CopyContext.sameSelection('sudo systemctl restart nginx\r\n', 'sudo systemctl restart nginx'), isTrue);
      expect(CopyContext.sameSelection('something else entirely', 'sudo systemctl restart nginx'), isFalse);
      expect(CopyContext.sameSelection('', 'x'), isFalse);
      // a whole paragraph that merely contains the copy is a different selection
      expect(CopyContext.sameSelection('${'word ' * 40}150 mm/s', '150 mm/s'), isFalse);
    });

    test('splitAround needs exactly one occurrence', () {
      final c = CopyContext.splitAround('set the speed to 150 mm/s for the outer wall', '150 mm/s');
      expect(c?.before, 'set the speed to');
      expect(c?.after, 'for the outer wall');
      expect(CopyContext.splitAround('a 1 b 1 c', '1'), isNull);
      expect(CopyContext.splitAround('nothing here', 'missing'), isNull);
      expect(CopyContext.splitAround('only', 'only'), isNull, reason: 'no words around it');
    });

    test('trimmed keeps the nearest words and caps every field', () {
      final words = List.generate(200, (i) => 'w$i').join(' ');
      final t = CopyContext(title: '  T  ', before: words, after: words).trimmed();
      expect(t.title, 'T');
      expect(t.before.split(' ').first, 'w${200 - CopyContext.keepWords}');
      expect(t.before.split(' ').last, 'w199');
      expect(t.after.split(' ').first, 'w0');
      expect(t.after.split(' ').length, CopyContext.keepWords);
      expect(const CopyContext().isEmpty, isTrue);
      expect(const CopyContext(url: 'https://a.b').toJson(), {'url': 'https://a.b', 'before': '', 'after': ''});
    });
  });

  group('browser link on the clipboard', () {
    Uint8List cfHtml(String sourceUrl) => Uint8List.fromList(utf8.encode(
        'Version:0.9\r\nStartHTML:00000000\r\nEndHTML:00000000\r\n'
        'StartFragment:00000000\r\nEndFragment:00000000\r\n'
        'SourceURL:$sourceUrl\r\n<html><body><!--StartFragment-->x<!--EndFragment--></body></html>'));

    test('reads SourceURL from the CF_HTML header', () {
      expect(cfHtmlSourceUrl(cfHtml('https://stackoverflow.com/q/1?a=b')), 'https://stackoverflow.com/q/1?a=b');
    });

    test('ignores non-web sources and missing headers', () {
      expect(cfHtmlSourceUrl(cfHtml('file:///C:/notes.html')), isNull);
      expect(cfHtmlSourceUrl(cfHtml('about:blank')), isNull);
      expect(cfHtmlSourceUrl(Uint8List.fromList(utf8.encode('<b>no header</b>'))), isNull);
      expect(httpUrlOrNull('https://x.y/z\u0000'), 'https://x.y/z');
    });
  });

  group('RelicDb copy_context', () {
    test('round-trips, and dies with its relic', () {
      final db = RelicDb.memory();
      addTearDown(db.dispose);
      db.upsert(Relic(
        uid: 'u1', createdAt: 1, updatedAt: 1, kind: Kind.string, source: Source.clipboard,
        promoted: false, byteSize: 3, device: 'd', tags: const [], content: 'abc', preview: 'abc',
      ));
      db.setCopyContext('u1', const CopyContext(title: 'T', url: 'https://a.b', before: 'x', after: 'y'), 5);
      final got = db.copyContextOf('u1');
      expect((got?.title, got?.url, got?.before, got?.after), ('T', 'https://a.b', 'x', 'y'));
      db.delete('u1');
      expect(db.copyContextOf('u1'), isNull);
    });
  });

  final sandbox = Platform.environment['RELIC_DATA_DIR'];
  final guarded = sandbox == null || sandbox.toLowerCase().contains('roaming');

  test('repo: keeps context for a normal copy, never for a secret, forgets on off', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set — skipping repo test');
      return;
    }
    final repo = LocalDeskRepo();
    await repo.load();
    addTearDown(repo.dispose);
    repo.setMlEnrich(false);
    repo.setAiContext(true);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    const ctx = CopyContext(title: 'Deploy notes - Notion', before: 'reload the web server', after: 'then check');

    final plain = 'sudo systemctl restart nginx #$stamp';
    expect(repo.captureText(plain, context: ctx), isTrue);
    final uid = repo.all.firstWhere((r) => r.content == plain).uid;
    expect(repo.debugCopyContextOf(uid)?.title, 'Deploy notes - Notion');

    final secret = 'AKIAIOSFODNN7EXAMPLE$stamp';
    repo.captureText(secret, context: ctx);
    final s = repo.all.where((r) => r.content == secret).toList();
    if (s.isNotEmpty && s.first.isSecret) {
      expect(repo.debugCopyContextOf(s.first.uid), isNull);
    }

    repo.setAiContext(false);
    expect(repo.debugCopyContextOf(uid), isNull);
    final later = 'git push origin main #$stamp';
    repo.captureText(later, context: ctx);
    final laterUid = repo.all.firstWhere((r) => r.content == later).uid;
    expect(repo.debugCopyContextOf(laterUid), isNull, reason: 'off means nothing is kept');
    repo.setAiContext(true);
  });
}

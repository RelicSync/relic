// v13: an OpenAI project key saved before the detector knew the format is
// marked secret on upgrade, loses its formatting and copy context, and is
// queued to push so other devices mask it too.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/relic_db.dart';
import 'package:relic_app/models/copy_context.dart';
import 'package:relic_app/models/relic.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('an old unmasked sk-proj key is masked on upgrade', () {
    final dir = Directory.systemTemp.createTempSync('remask');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/relics.db';
    const key = 'sk-proj-FAKEfake_0123456789-FAKEfake_0123456789-FAKEfake_0123456789'; // scan-ok

    // A vault from before v13: the key stored as a plain item with context.
    final db = RelicDb.open(path);
    for (final (uid, content) in [('k', key), ('n', 'just a normal note about sk- prefixes')]) {
      db.upsert(Relic(
        uid: uid, createdAt: 1, updatedAt: 1, kind: Kind.string, source: Source.clipboard,
        promoted: false, byteSize: content.length, device: 'd', tags: const ['chrome'],
        content: content, preview: content,
      ));
      db.setCopyContext(uid, const CopyContext(title: 'API keys - OpenAI', before: 'x'), 1);
    }
    db.dispose();
    final raw = sqlite3.open(path)
      ..execute('''UPDATE relics SET tags = '["chrome"]' ''')
      ..execute('DELETE FROM pending_ops')
      ..execute('PRAGMA user_version = 12');
    raw.dispose();

    final up = RelicDb.open(path);
    addTearDown(up.dispose);
    expect(up.getByUid('k')!.isSecret, isTrue);
    expect(up.copyContextOf('k'), isNull);
    expect(up.getByUid('n')!.isSecret, isFalse);
    expect(up.copyContextOf('n'), isNotNull);
    final check = sqlite3.open(path);
    addTearDown(check.dispose);
    final ops = check.select("SELECT uid FROM pending_ops WHERE op = 'push'").map((r) => r['uid']).toList();
    expect(ops, ['k']);
  });
}

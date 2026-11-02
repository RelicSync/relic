// The cheap counts the popup reads on every build. They replaced walks over
// repo.all, which load the whole table, so they must give the same answers.
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/relic_db.dart';
import 'package:relic_app/models/relic.dart';

void main() {
  test('liveCount matches allRows and leaves held rows out', () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);
    expect(db.liveCount(), 0);
    db.upsert(_mk('u1', device: 'Desk'));
    db.upsert(_mk('u2', device: 'Desk'));
    expect(db.liveCount(), db.allRows().length);
    db.holdAll('supabase:other');
    db.upsert(_mk('u3', device: 'Desk'));
    expect(db.liveCount(), 1);
    expect(db.liveCount(), db.allRows().length);
  });

  test('anyFromOtherDevice agrees with walking allRows', () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);
    expect(db.anyFromOtherDevice('Desk'), isFalse);
    db.upsert(_mk('u1', device: 'Desk'));
    expect(db.anyFromOtherDevice('Desk'), isFalse);
    db.upsert(_mk('u2', device: 'Phone'));
    expect(db.anyFromOtherDevice('Desk'), isTrue);
    // A held row from another device is not one the popup can see.
    db.holdAll('supabase:other');
    db.upsert(_mk('u3', device: 'Desk'));
    expect(db.anyFromOtherDevice('Desk'), isFalse);
    // No device at all reads as another device, as `r.device != label` does.
    db.upsert(_mk('u4'));
    expect(db.anyFromOtherDevice('Desk'), isTrue);
  });

  test('countTags gives what countTag gives, one tag at a time', () {
    final db = RelicDb.memory();
    addTearDown(db.dispose);
    db.upsert(_mk('a', tags: ['ip', 'url']));
    db.upsert(_mk('b', tags: ['zip'], promoted: true));
    db.upsert(_mk('c', tags: ['Code'], userTags: ['snippet']));
    db.upsert(_mk('d', tags: ['100%_done']));
    const asked = ['ip', 'url', 'zip', 'code', 'snippet', '100%_done', 'none'];
    for (final vault in [false, true]) {
      final want = {
        for (final t in asked)
          if (db.countTag(t, vaultOnly: vault) > 0)
            t: db.countTag(t, vaultOnly: vault),
      };
      expect(db.countTags(asked, vaultOnly: vault), want);
    }
    expect(db.countTags(asked)['ip'], 1);
    expect(db.countTags(asked).containsKey('none'), isFalse);
  });
}

Relic _mk(String uid,
        {String? device,
        List<String> tags = const [],
        List<String> userTags = const [],
        bool promoted = false}) =>
    Relic(
      uid: uid,
      createdAt: 100,
      updatedAt: 100,
      kind: Kind.string,
      source: Source.clipboard,
      promoted: promoted,
      byteSize: 5,
      tags: tags,
      userTags: userTags,
      device: device,
      content: 'hello',
      preview: 'hello',
    );

// Two desktops that share a clipboard (Parsec, a remote desktop session) both
// capture the same copy before either sees the other's item, and sync then
// hands both to every device. RelicDb.mergeTwins folds such twins into one:
// the lowest uid wins, the rest are deleted with a tombstone, and what the
// user did to a loser rides over to the winner. These pin the rule, and that
// two desktops that start from opposite sides end on the same single row.
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/relic_db.dart';
import 'package:relic_app/models/relic.dart';

Relic _mk(
  String uid, {
  String content = 'npm run build -- --prod',
  String? device = 'Desktop',
  int createdAt = 1000,
  bool promoted = false,
  String? title,
  List<String> userTags = const [],
  Kind kind = Kind.string,
}) =>
    Relic(
      uid: uid,
      createdAt: createdAt,
      updatedAt: createdAt,
      kind: kind,
      source: Source.clipboard,
      promoted: promoted,
      byteSize: content.length,
      device: device,
      userTags: userTags,
      title: title,
      content: content,
      preview: content,
    );

List<String> _uids(RelicDb db) => [for (final r in db.allRows()) r.uid]..sort();

List<String> _ops(RelicDb db, String op) => [
      for (final o in db.pendingOps())
        if (o.op == op) o.uid,
    ]..sort();

void main() {
  test('one copy on two desktops folds into the lower uid', () {
    final db = RelicDb.memory();
    db.upsert(_mk('b-uid', device: 'Desktop', createdAt: 1000));
    db.upsert(_mk('a-uid', device: 'MULTIVAC-III', createdAt: 1002));

    final res = db.mergeTwins(2000, queueOps: true);

    expect(res.removed, ['b-uid']);
    expect(_uids(db), ['a-uid']);
    expect(_ops(db, 'delete'), ['b-uid']);
    // Nothing to carry over, so the winner is not pushed again.
    expect(_ops(db, 'push'), isEmpty);
    expect(db.getByUid('a-uid')!.updatedAt, 1002);
    // The tombstone guard holds the loser off until the server agrees.
    expect(db.hasPendingDelete('b-uid'), isTrue);
  });

  test('kept, title and tags on the loser survive on the winner', () {
    final db = RelicDb.memory();
    db.upsert(_mk('a-uid', device: 'Desktop'));
    db.upsert(_mk(
      'z-uid',
      device: 'Jordans-MacBook-Pro.local',
      createdAt: 1003,
      promoted: true,
      title: 'Prod build',
      userTags: ['deploy'],
    ));

    db.mergeTwins(2000, queueOps: true);

    final w = db.getByUid('a-uid')!;
    expect(db.getByUid('z-uid'), isNull);
    expect(w.promoted, isTrue);
    expect(w.title, 'Prod build');
    expect(w.userTags, ['deploy']);
    expect(w.updatedAt, 2000);
    expect(_ops(db, 'push'), ['a-uid']);
    expect(_ops(db, 'delete'), ['z-uid']);
  });

  test("the winner's own title stands and tags join without repeats", () {
    final w = _mk('a', title: 'mine', userTags: ['Work']);
    final merged = RelicDb.mergeTwinState(w, [
      _mk('b', title: 'theirs', userTags: ['work', 'cli']),
    ])!;
    expect(merged.title, 'mine');
    expect(merged.userTags, ['Work', 'cli']);
    expect(RelicDb.mergeTwinState(w, [_mk('b', userTags: ['work'])]), isNull);
  });

  test('two desktops starting from opposite sides end on the same row', () {
    // Desktop A captured a-uid and then pulled B's twin; B the other way
    // round, and B had kept its own copy before the pull.
    final mine = _mk('a-uid', device: 'Desktop', createdAt: 1000);
    final theirs = _mk('b-uid',
        device: 'MULTIVAC-III', createdAt: 1001, promoted: true);
    final a = RelicDb.memory()
      ..upsert(mine, queuePush: true)
      ..upsert(theirs);
    final b = RelicDb.memory()
      ..upsert(theirs, queuePush: true)
      ..upsert(mine);

    a.mergeTwins(5000, queueOps: true);
    b.mergeTwins(5000, queueOps: true);

    expect(_uids(a), ['a-uid']);
    expect(_uids(b), ['a-uid']);
    final ra = a.getByUid('a-uid')!;
    final rb = b.getByUid('a-uid')!;
    expect(ra.promoted, isTrue);
    expect(rb.promoted, isTrue);
    expect(ra.updatedAt, rb.updatedAt);
    // Both tombstone the same loser, and B's queued push of it is gone.
    expect(_ops(a, 'delete'), ['b-uid']);
    expect(_ops(b, 'delete'), ['b-uid']);
    expect(_ops(b, 'push'), ['a-uid']);
    // A second pass finds nothing: no delete-then-resurrect cycle.
    expect(a.mergeTwins(6000, queueOps: true).removed, isEmpty);
    expect(b.mergeTwins(6000, queueOps: true).removed, isEmpty);
  });

  test('three desktops on one clipboard make one group', () {
    final db = RelicDb.memory()
      ..upsert(_mk('c', device: 'one', createdAt: 1000))
      ..upsert(_mk('a', device: 'two', createdAt: 1001))
      ..upsert(_mk('b', device: 'three', createdAt: 1002));
    expect(db.twinGroups(), [
      ['a', 'b', 'c'],
    ]);
    db.mergeTwins(2000);
    expect(_uids(db), ['a']);
    // Without sync nothing is queued.
    expect(db.pendingOps(), isEmpty);
  });

  test('what is not a twin is left alone', () {
    final db = RelicDb.memory()
      // Same device: a pair the user made on purpose.
      ..upsert(_mk('s1', device: 'Desktop', content: 'same box'))
      ..upsert(_mk('s2', device: 'Desktop', content: 'same box'))
      // Too far apart to be one copy.
      ..upsert(_mk('f1', device: 'Desktop', content: 'later', createdAt: 0))
      ..upsert(_mk('f2',
          device: 'Laptop',
          content: 'later',
          createdAt: RelicDb.kTwinWindowSecs + 1))
      // A file item's content is a path, which can be another file there.
      ..upsert(_mk('p1', device: 'Desktop', content: r'C:\a.txt',
          kind: Kind.file))
      ..upsert(_mk('p2', device: 'Laptop', content: r'C:\a.txt',
          kind: Kind.file))
      // Different text.
      ..upsert(_mk('d1', device: 'Desktop', content: 'one'))
      ..upsert(_mk('d2', device: 'Laptop', content: 'two'))
      // An old row with no device named.
      ..upsert(_mk('n1', device: null, content: 'old'))
      ..upsert(_mk('n2', device: 'Laptop', content: 'old'));

    expect(db.twinGroups(), isEmpty);
    expect(db.mergeTwins(2000, queueOps: true).removed, isEmpty);
    expect(db.allRows().length, 10);
  });
}

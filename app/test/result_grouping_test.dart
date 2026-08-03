import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/result_grouping.dart';
import 'package:relic_app/models/relic.dart';

Relic _mk(
  String uid, {
  String? content,
  Kind kind = Kind.string,
  String? device,
  String? blobKey,
  bool promoted = false,
  int createdAt = 1000,
}) =>
    Relic(
      uid: uid,
      createdAt: createdAt,
      updatedAt: createdAt,
      kind: kind,
      source: Source.clipboard,
      promoted: promoted,
      byteSize: content?.length ?? 0,
      device: device,
      blobKey: blobKey,
      content: content,
      preview: content,
    );

void main() {
  test('identical text from two devices collapses into the first row', () {
    final rows = [
      _mk('a', content: 'https://relic.space/privacy', device: 'Desktop'),
      _mk('b', content: 'https://relic.space/privacy', device: 'MULTIVAC-III'),
      _mk('c', content: 'something else', device: 'Desktop'),
    ];
    final g = collapseDuplicates(rows);
    expect(g.map((e) => e.relic.uid), ['a', 'c']);
    expect(g.first.dupDevices, ['MULTIVAC-III']);
    expect(g[1].duplicates, isEmpty);
  });

  test('whitespace-only differences still collapse', () {
    final g = collapseDuplicates([
      _mk('a', content: 'hello world'),
      _mk('b', content: '  hello world\n'),
    ]);
    expect(g.map((e) => e.relic.uid), ['a']);
    expect(g.first.duplicates.map((d) => d.uid), ['b']);
  });

  test('a kept twin becomes the representative', () {
    final g = collapseDuplicates([
      _mk('hist', content: 'the same copy', device: 'Desktop'),
      _mk('kept', content: 'the same copy', device: 'MULTIVAC-III',
          promoted: true),
    ]);
    expect(g.single.relic.uid, 'kept',
        reason: 'star/keep/edit must act on the deliberately saved copy');
    expect(g.single.duplicates.map((d) => d.uid), ['hist']);
  });

  test('images and files never collapse, even with identical captions', () {
    final g = collapseDuplicates([
      _mk('p1', content: 'a screenshot of a screen', kind: Kind.photo,
          blobKey: 'k1'),
      _mk('p2', content: 'a screenshot of a screen', kind: Kind.photo,
          blobKey: 'k2'),
      _mk('t1', content: 'a screenshot of a screen', blobKey: 'k3'),
    ]);
    expect(g.length, 3, reason: 'same caption does not mean same thing');
  });

  test('empty content never collapses', () {
    final g = collapseDuplicates([
      _mk('a', content: ''),
      _mk('b', content: ''),
      _mk('c'),
    ]);
    expect(g.length, 3);
  });

  test('order is preserved and non-adjacent duplicates still fold', () {
    final g = collapseDuplicates([
      _mk('a', content: 'one'),
      _mk('b', content: 'two'),
      _mk('c', content: 'one', device: 'Phone'),
    ]);
    expect(g.map((e) => e.relic.uid), ['a', 'b']);
    expect(g.first.dupDevices, ['Phone']);
  });
}

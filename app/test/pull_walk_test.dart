// The pull state both repos keep across sync passes. The repo tests
// (sync_first_paint_test.dart, desk_reconnect_paint_test.dart) show a failed
// page being picked up where it was left; this pins the walk itself.
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/pull_walk.dart';

void main() {
  test('a cold pull walks the vault first, then everything, newest first',
      () {
    final w = PullWalk(since: 0);
    expect(w.query(), {
      'since': '0',
      'limit': '${PullWalk.firstPage}',
      'order': 'desc',
      'promoted': '1',
    });
    w.pageLanded('20:b', const Duration(seconds: 1));
    expect(w.query()['promoted'], '1');
    expect(w.query()['cursor'], '20:b');
    // The vault walk ends; the full walk starts from its own first page.
    w.pageLanded(null, const Duration(seconds: 1));
    expect(w.done, isFalse);
    expect(w.query().containsKey('promoted'), isFalse);
    expect(w.query().containsKey('cursor'), isFalse);
    w.pageLanded('10:a', const Duration(seconds: 1));
    expect(w.query()['cursor'], '10:a');
    w.pageLanded(null, const Duration(seconds: 1));
    expect(w.done, isTrue);
  });

  test('a pull with a cursor is one walk of everything', () {
    final w = PullWalk(since: 500);
    expect(w.query()['since'], '500');
    expect(w.query().containsKey('promoted'), isFalse);
    w.pageLanded(null, const Duration(seconds: 1));
    expect(w.done, isTrue);
  });

  test('pages grow while they come back quickly and shrink on a timeout', () {
    final w = PullWalk(since: 0);
    expect(w.pageSize, PullWalk.firstPage);
    w.pageLanded('a', const Duration(seconds: 1));
    expect(w.pageSize, PullWalk.firstPage * 2);
    w.pageLanded('b', const Duration(seconds: 1));
    w.pageLanded('c', const Duration(seconds: 1));
    expect(w.pageSize, PullWalk.maxPage);
    // A slow page that still landed keeps the size it had.
    w.pageLanded('d', const Duration(seconds: 8));
    expect(w.pageSize, PullWalk.maxPage);
    // The same page is asked for again, much smaller.
    final cursorBefore = w.query()['cursor'];
    w.pageTimedOut();
    expect(w.pageSize, PullWalk.maxPage ~/ 4);
    expect(w.query()['cursor'], cursorBefore);
    w.pageTimedOut();
    w.pageTimedOut();
    w.pageTimedOut();
    expect(w.pageSize, PullWalk.minPage);
  });

  test('the cursor it leaves behind is a second short of the newest row', () {
    final w = PullWalk(since: 0);
    w.saw(10);
    w.saw(30);
    w.saw(20);
    expect(w.nextSince, 29);
    // Nothing seen: nothing to move to.
    expect(PullWalk(since: 7).nextSince, 6);
  });
}

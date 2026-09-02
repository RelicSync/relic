// The sequential paste stack: queue several items, then paste them one at a
// time in order.
//
// All of it is repo-level, which is deliberate — the stack cannot live in the
// picker, because the popup clears its state on every close and the whole flow
// is "fill it, dismiss, drain it somewhere else". These tests pin that, plus
// the FIFO order and the flag gate.
//
//   RELIC_DATA_DIR=$(mktemp -d) flutter test test/paste_stack_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/models/relic.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sandbox = Platform.environment['RELIC_DATA_DIR'];
  final guarded =
      sandbox == null || sandbox.toLowerCase().contains('roaming');

  Relic mk(String uid) => Relic(
        uid: uid,
        createdAt: 0,
        updatedAt: 0,
        kind: Kind.string,
        source: Source.clipboard,
        promoted: false,
        byteSize: 0,
        content: uid,
      );

  Future<LocalDeskRepo> repo() async {
    final r = LocalDeskRepo();
    await r.load();
    r.setMlEnrich(false);
    r.clearStack();
    return r;
  }

  test('the flag is off by default and has a real setter', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final r = await repo();
    addTearDown(r.dispose);

    // feature_snippets is declared, persisted and read by nothing, with no
    // toggle anywhere. This one must not become a second of those.
    r.setPasteStack(false);
    expect(r.pasteStackOn, isFalse);
    r.setPasteStack(true);
    expect(r.pasteStackOn, isTrue);
    r.setPasteStack(false);
  });

  test('push, peek and pop are FIFO', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final r = await repo();
    addTearDown(r.dispose);

    expect(r.peekStack(), isNull);
    expect(r.popStack(), isNull, reason: 'popping an empty stack is a no-op');

    r.pushStack(mk('one'));
    r.pushStack(mk('two'));
    r.pushStack(mk('three'));
    expect(r.pasteStackDepth, 3);

    // Copy 1, 2, 3 then paste 1, 2, 3. Everyone calls it a stack; filling a
    // form needs a queue.
    expect(r.peekStack()!.uid, 'one');
    expect(r.popStack()!.uid, 'one');
    expect(r.popStack()!.uid, 'two');
    expect(r.popStack()!.uid, 'three');
    expect(r.pasteStackDepth, 0);
  });

  test('pushStackAll preserves the given order', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final r = await repo();
    addTearDown(r.dispose);

    r.pushStackAll([mk('a'), mk('b'), mk('c')]);
    expect(r.pasteStack.map((x) => x.uid), ['a', 'b', 'c']);

    r.pushStackAll(const []); // empty is a no-op, not a crash
    expect(r.pasteStackDepth, 3);
  });

  test('reverse, remove and clear', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final r = await repo();
    addTearDown(r.dispose);

    r.pushStackAll([mk('a'), mk('b'), mk('c')]);

    r.reverseStack();
    expect(r.pasteStack.map((x) => x.uid), ['c', 'b', 'a']);

    r.removeFromStack('b');
    expect(r.pasteStack.map((x) => x.uid), ['c', 'a']);
    r.removeFromStack('nope'); // unknown uid is a no-op
    expect(r.pasteStackDepth, 2);

    r.clearStack();
    expect(r.pasteStack, isEmpty);
  });

  test('the exposed list cannot be mutated from outside', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final r = await repo();
    addTearDown(r.dispose);

    r.pushStack(mk('a'));
    expect(() => r.pasteStack.add(mk('b')), throwsUnsupportedError);
  });

  test('turning the feature off empties the stack', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final r = await repo();
    addTearDown(r.dispose);

    r.setPasteStack(true);
    r.pushStackAll([mk('a'), mk('b')]);
    r.setPasteStack(false);
    expect(r.pasteStack, isEmpty,
        reason: 'the chords are gone, so a queue nobody can drain must not '
            'survive to change what a later paste does');
  });

  test('mutations notify, so the picker bar tracks the queue', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final r = await repo();
    addTearDown(r.dispose);

    var ticks = 0;
    void listener() => ticks++;
    r.addListener(listener);
    addTearDown(() => r.removeListener(listener));

    r.pushStack(mk('a'));
    expect(ticks, greaterThan(0));

    final afterPush = ticks;
    r.popStack();
    expect(ticks, greaterThan(afterPush));
  });

  test('the stack does not survive a restart', () async {
    if (guarded) {
      markTestSkipped('RELIC_DATA_DIR sandbox not set');
      return;
    }
    final a = await repo();
    a.setPasteStack(true);
    a.pushStackAll([mk('a'), mk('b')]);
    expect(a.pasteStackDepth, 2);
    a.dispose();

    // Session state on purpose, the same reasoning the pause state uses: a
    // machine restart must never come up with a stale queue armed.
    final b = LocalDeskRepo();
    await b.load();
    addTearDown(b.dispose);
    expect(b.pasteStack, isEmpty);
    expect(b.pasteStackOn, isTrue, reason: 'but the FLAG is remembered');
    b.setPasteStack(false);
  });
}

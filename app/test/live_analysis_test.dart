// An item open on screen has to keep up with its own analysis.
//
// Phones never run the models, so everything interesting about a captured
// screenshot — its generated title, its tags, the text OCR pulled out of it —
// is produced on a desktop and arrives later over the wire. The moment a user
// is most likely to be looking at an item is right after capturing it, which
// is exactly the window in which that analysis lands. The editor used to close
// over the relic it was opened with, so none of it ever appeared: the item sat
// there untitled and textless until the dialog was closed and reopened, with
// nothing on screen to suggest that would help.
//
// What must NOT happen is the mirror image: a pull overwriting a field the
// user is in the middle of editing. These tests pin both halves.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/repo.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/ui/dialogs.dart';
import 'package:relic_app/ui/popup.dart';

/// A repo whose stored copy of one item can be swapped out from under the UI,
/// the way a sync pull does. The visible list is deliberately left alone, so a
/// test that passes proves the dialog re-read the STORE rather than picking
/// something up from the row it was opened from.
class _LiveRepo extends MemoryRepo {
  final _tick = ValueNotifier<int>(0);
  final Map<String, Relic> _analysed = {};

  @override
  Listenable get changes => _tick;

  @override
  Relic? byUid(String uid) => _analysed[uid] ?? super.byUid(uid);

  /// Publish a new version of an item and ring the bell, as a pull would.
  void deliver(Relic r) {
    _analysed[r.uid] = r;
    _tick.value++;
  }

  @override
  Future<String?> textOf(Relic r) async => byUid(r.uid)?.content ?? r.content;
}

void main() {
  const uid = 'shot-1';

  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  // Recent, so it lands at the top of the seeded demo corpus and is on screen
  // to be tapped. Each delivered version bumps updatedAt, as a real one does.
  var version = 0;
  Relic shot({String? title, String? content, List<String> tags = const []}) =>
      Relic(
        uid: uid,
        createdAt: now - 60,
        updatedAt: now - 60 + version++,
        kind: Kind.string,
        source: Source.clipboard,
        promoted: true,
        byteSize: 8,
        device: 'phone',
        content: content ?? 'a receipt',
        title: title,
        tags: tags,
      );

  Future<_LiveRepo> seeded() async {
    final repo = _LiveRepo();
    await repo.load(); // seeds the demo corpus
    await repo.restore(shot());
    return repo;
  }

  Future<void> pump(WidgetTester tester, _LiveRepo repo) async {
    // Wide + touch: the two-pane layout, where a single tap opens the editor
    // in the detail pane (see two_pane_test).
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RelicTheme(
        colors: RelicColors.dark,
        isMobile: true,
        child: Scaffold(
          body: PopupView(repo: repo, onClose: () {}, onSettings: () {}),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.textContaining('a receipt', findRichText: true).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(EditDialog), findsOneWidget, reason: 'editor is open');
  }

  /// The editor's own text fields. Scoped to the dialog because the list beside
  /// it has a search box, which is also a TextField and comes first in the tree.
  Finder editorFields() => find.descendant(
      of: find.byType(EditDialog), matching: find.byType(TextField));

  /// Whether any field in the editor currently holds exactly this text.
  bool fieldHolds(WidgetTester tester, String s) => tester
      .widgetList<TextField>(editorFields())
      .any((f) => f.controller?.text == s);

  /// The title field. Field order in the editor is body, title, note, new-tag;
  /// pinned rather than trusted, because a field added above the title would
  /// otherwise send this test's keystrokes into the wrong box and let it pass
  /// for the wrong reason.
  Finder titleField(WidgetTester tester) {
    final fields = tester.widgetList<TextField>(editorFields()).toList();
    expect(fields[0].controller?.text, 'a receipt', reason: 'field 0: body');
    expect(fields[1].controller?.text, isEmpty, reason: 'field 1: title');
    return editorFields().at(1);
  }

  testWidgets('a title generated elsewhere reaches the open editor',
      (tester) async {
    final repo = await seeded();
    await pump(tester, repo);
    expect(fieldHolds(tester, 'Kessler Roofing invoice'), isFalse);

    repo.deliver(shot(title: 'Kessler Roofing invoice'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(fieldHolds(tester, 'Kessler Roofing invoice'), isTrue,
        reason: 'the analysis landed while the item was open, and showed');
  });

  testWidgets('OCR text arriving later shows without reopening the item',
      (tester) async {
    final repo = await seeded();
    await pump(tester, repo);
    expect(find.textContaining('TOTAL 41.20'), findsNothing);

    repo.deliver(shot(content: 'WHOLE FOODS TOTAL 41.20'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('TOTAL 41.20', findRichText: true), findsWidgets,
        reason: 'the extracted text is the whole point of opening a receipt');
  });

  testWidgets('a title the user is typing is never overwritten', (tester) async {
    final repo = await seeded();
    await pump(tester, repo);

    // Type a title, then let a generated one arrive a moment later.
    await tester.enterText(titleField(tester), 'Reimburse this');
    await tester.pump();

    repo.deliver(shot(title: 'Kessler Roofing invoice'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(fieldHolds(tester, 'Reimburse this'), isTrue,
        reason: 'the user was mid-edit; their words win');
    expect(fieldHolds(tester, 'Kessler Roofing invoice'), isFalse);
  });

  testWidgets('machine tags from the labeller appear on the open item',
      (tester) async {
    final repo = await seeded();
    await pump(tester, repo);
    expect(find.text('invoice'), findsNothing);

    repo.deliver(shot(tags: const ['invoice']));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('invoice'), findsWidgets);
  });

  testWidgets('an update for a different item is ignored', (tester) async {
    final repo = await seeded();
    await pump(tester, repo);

    repo.deliver(Relic(
      uid: 'someone-else',
      createdAt: 1,
      updatedAt: 2,
      kind: Kind.string,
      source: Source.clipboard,
      promoted: false,
      byteSize: 3,
      device: 'phone',
      content: 'unrelated',
      title: 'Not this one',
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(fieldHolds(tester, 'Not this one'), isFalse);
  });
}

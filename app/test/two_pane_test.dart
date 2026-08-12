// iPad/tablet two-pane layout (docs/apple-port-2026-08.md §5): at
// RelicTheme.isWideOf widths the touch UI splits into list + detail pane and
// _setDialog content renders in the pane instead of as a modal. The
// breakpoint must be width-derived and reactive (Split View can shrink a 13"
// iPad to 320dp), and desktop must be untouched.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/repo.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/ui/dialogs.dart';
import 'package:relic_app/ui/popup.dart';

void main() {
  Future<MemoryRepo> seededRepo() async {
    final repo = MemoryRepo();
    // load() seeds the demo corpus (replacing anything restored before it),
    // so add our marker relic after.
    await repo.load();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await repo.restore(Relic(
      uid: 'tp1',
      createdAt: now - 60,
      updatedAt: now - 60,
      kind: Kind.string,
      source: Source.clipboard,
      promoted: false,
      byteSize: 12,
      device: 'test',
      content: 'hello iPad',
    ));
    return repo;
  }

  Future<void> pumpPopup(WidgetTester tester, MemoryRepo repo,
      {required Size logical, required bool isMobile}) async {
    tester.view.physicalSize = logical;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RelicTheme(
        colors: RelicColors.dark,
        isMobile: isMobile,
        child: Scaffold(
          body: PopupView(repo: repo, onClose: () {}, onSettings: () {}),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('wide touch window renders the detail pane', (tester) async {
    final repo = await seededRepo();
    await pumpPopup(tester, repo,
        logical: const Size(1024, 768), isMobile: true);
    expect(find.text('Select an item'), findsOneWidget);
    expect(
        find.textContaining('hello iPad', findRichText: true), findsWidgets);
  });

  testWidgets('phone width keeps the single-column layout', (tester) async {
    final repo = await seededRepo();
    await pumpPopup(tester, repo,
        logical: const Size(360, 760), isMobile: true);
    expect(find.text('Select an item'), findsNothing);
  });

  testWidgets('desktop is never two-pane, even when wide', (tester) async {
    final repo = await seededRepo();
    await pumpPopup(tester, repo,
        logical: const Size(1024, 768), isMobile: false);
    expect(find.text('Select an item'), findsNothing);
  });

  testWidgets('tapping a row opens the editor in the pane, not a modal',
      (tester) async {
    final repo = await seededRepo();
    await pumpPopup(tester, repo,
        logical: const Size(1024, 768), isMobile: true);
    await tester.tap(
        find.textContaining('hello iPad', findRichText: true).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(EditDialog), findsOneWidget);
    // Still two-pane: the list stays interactive beside the editor.
    expect(find.text('Select an item'), findsNothing);
    expect(
        find.textContaining('hello iPad', findRichText: true), findsWidgets);
  });

  testWidgets('breakpoint is reactive: resizing the same tree flips layouts',
      (tester) async {
    final repo = await seededRepo();
    await pumpPopup(tester, repo,
        logical: const Size(1024, 768), isMobile: true);
    expect(find.text('Select an item'), findsOneWidget);
    // Split View: same app, now phone-narrow — must fall back to one column.
    // 320dp is the true narrow pane, and the rows have to survive it: the meta
    // line sheds chips into its "+N" there rather than overflowing.
    tester.view.physicalSize = const Size(320, 768);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Select an item'), findsNothing);
  });
}

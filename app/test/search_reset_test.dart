// Closing the window clears the search.
//
// The popup's State survives across summons (the window is hidden, not
// destroyed), so a query typed before a close was still sitting in the box
// when the window came back — sometimes minutes later, with most of the
// history filtered out of view and no memory of having typed it. A stale
// filter reads as missing data.
//
// desktop.dart's _hide now ticks resetSignal on EVERY close, not only the
// deliberate ones. This pins the receiving end: a tick puts the popup back in
// the default browse state.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/repo.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/ui/popup.dart';

void main() {
  Future<MemoryRepo> seededRepo() async {
    final repo = MemoryRepo();
    // load() seeds the demo corpus (replacing anything restored before it),
    // so add the marker relic after.
    await repo.load();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await repo.restore(Relic(
      uid: 'sr1',
      createdAt: now - 60,
      updatedAt: now - 60,
      kind: Kind.string,
      source: Source.clipboard,
      promoted: false,
      byteSize: 12,
      device: 'test',
      content: 'zarquon marker',
    ));
    return repo;
  }

  Future<TextEditingController> pumpPopup(
    WidgetTester tester,
    MemoryRepo repo,
    ValueNotifier<int> reset,
  ) async {
    tester.view.physicalSize = const Size(460, 560);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RelicTheme(
        colors: RelicColors.dark,
        child: Scaffold(
          body: PopupView(
            repo: repo,
            onClose: () {},
            onSettings: () {},
            resetSignal: reset,
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    return tester.widget<TextField>(find.byType(TextField).first).controller!;
  }

  testWidgets('a close clears the query and restores the full list',
      (tester) async {
    final repo = await seededRepo();
    final reset = ValueNotifier<int>(0);
    addTearDown(reset.dispose);
    final ctl = await pumpPopup(tester, repo, reset);

    final all = repo.visible.length;
    expect(all, greaterThan(1), reason: 'need a corpus to filter down from');

    await tester.enterText(find.byType(TextField).first, 'zarquon');
    await tester.pump(const Duration(milliseconds: 300)); // past the debounce
    expect(ctl.text, 'zarquon');
    expect(repo.visible.length, lessThan(all), reason: 'the query never ran');

    // The close. In the app this happens while the window is already hidden.
    reset.value++;
    await tester.pump(const Duration(milliseconds: 300));

    expect(ctl.text, isEmpty);
    expect(repo.visible.length, all);
  });

  testWidgets('a close with nothing typed is a no-op', (tester) async {
    final repo = await seededRepo();
    final reset = ValueNotifier<int>(0);
    addTearDown(reset.dispose);
    final ctl = await pumpPopup(tester, repo, reset);

    final all = repo.visible.length;
    reset.value++;
    await tester.pump(const Duration(milliseconds: 300));

    expect(ctl.text, isEmpty);
    expect(repo.visible.length, all);
  });

  testWidgets('repeated closes keep resetting, not just the first',
      (tester) async {
    // The tick is a counter, not a flag: every close has to land.
    final repo = await seededRepo();
    final reset = ValueNotifier<int>(0);
    addTearDown(reset.dispose);
    final ctl = await pumpPopup(tester, repo, reset);

    for (final q in ['zarquon', 'nothing-matches-this']) {
      await tester.enterText(find.byType(TextField).first, q);
      await tester.pump(const Duration(milliseconds: 300));
      expect(ctl.text, q);
      reset.value++;
      await tester.pump(const Duration(milliseconds: 300));
      expect(ctl.text, isEmpty, reason: 'the close after "$q" did not reset');
    }
  });
}

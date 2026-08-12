// Hardware keyboard on touch builds — an iPad with a Magic Keyboard
// (docs/apple-release-checklist.md §6). The desktop popup already answers
// type-to-search, Esc, arrows and Enter; the same handler has to behave on a
// RelicTheme.isMobile tree, where there is no window to close and the search
// box does not start focused. Everything here is driven by key events actually
// arriving, so a finger-only phone is unaffected.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/repo.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/ui/popup.dart';
import 'package:relic_app/widgets/result_row.dart';

/// Records what Enter put on the clipboard. The real path ends in a platform
/// channel the test host has no handler for, so the recording stops there.
class _Repo extends MemoryRepo {
  final copied = <String>[];

  @override
  Future<void> putOnClipboard(Relic r) async => copied.add(r.uid);
}

void main() {
  /// The demo corpus plus [extra] uniquely-titled rows (unique so
  /// collapseDuplicates never merges them and indexes stay predictable).
  Future<_Repo> seededRepo({int extra = 0}) async {
    final repo = _Repo();
    await repo.load();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (var i = 0; i < extra; i++) {
      await repo.restore(Relic(
        uid: 'hk$i',
        createdAt: now - 60 - i,
        updatedAt: now - 60 - i,
        kind: Kind.string,
        source: Source.clipboard,
        promoted: false,
        byteSize: 8,
        device: 'test',
        content: 'keyboard row $i',
      ));
    }
    return repo;
  }

  Future<int> pumpPopup(
    WidgetTester tester,
    _Repo repo, {
    required Size logical,
    required bool isMobile,
    List<int>? closes,
  }) async {
    var closed = 0;
    tester.view.physicalSize = logical;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RelicTheme(
        colors: RelicColors.dark,
        isMobile: isMobile,
        child: Scaffold(
          body: PopupView(
            repo: repo,
            onClose: () {
              closed++;
              closes?.add(closed);
            },
            onSettings: () {},
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    return closed;
  }

  FocusNode searchNode(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).first).focusNode!;

  /// PopupView.initState focuses the search box on desktop platforms, and the
  /// test host IS a desktop platform — a real iPad takes the Platform.isIOS
  /// branch and leaves the list focused. Reproduce the device state: drop the
  /// field's focus and arm the popup's own key-handling node, exactly as the
  /// autofocus would have on device.
  Future<void> asDevice(WidgetTester tester) async {
    searchNode(tester).unfocus();
    tester
        .widget<Focus>(find.byWidgetPredicate(
            (w) => w is Focus && w.focusNode?.debugLabel == 'popup-root'))
        .focusNode!
        .requestFocus();
    await tester.pump();
  }

  List<bool> selection(WidgetTester tester) =>
      [for (final r in tester.widgetList<ResultRow>(find.byType(ResultRow))) r.selected];

  const iPad = Size(834, 1112);
  const phone = Size(390, 844);

  testWidgets('typing on the list focuses search and inserts the character',
      (tester) async {
    final repo = await seededRepo();
    await pumpPopup(tester, repo, logical: iPad, isMobile: true);
    await asDevice(tester);
    expect(searchNode(tester).hasFocus, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ, character: 'q');
    await tester.pump(const Duration(milliseconds: 300));

    expect(searchNode(tester).hasFocus, isTrue,
        reason: 'the first keystroke must hand the keyboard to the search box');
    expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'q');
  });

  testWidgets('escape clears an active search instead of closing',
      (tester) async {
    final repo = await seededRepo();
    final closes = <int>[];
    await pumpPopup(tester, repo,
        logical: iPad, isMobile: true, closes: closes);
    await asDevice(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ, character: 'q');
    await tester.pump(const Duration(milliseconds: 300));
    final ctl = tester.widget<TextField>(find.byType(TextField).first).controller!;
    expect(ctl.text, 'q');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));

    expect(ctl.text, isEmpty);
    // The keyboard goes back to the list, so arrows work again straight away
    // (and any software keyboard drops).
    expect(searchNode(tester).hasFocus, isFalse);
    expect(closes, isEmpty, reason: 'touch builds have no window to close');
  });

  testWidgets('escape on an empty search never closes the touch UI',
      (tester) async {
    final repo = await seededRepo();
    final closes = <int>[];
    await pumpPopup(tester, repo,
        logical: phone, isMobile: true, closes: closes);
    await asDevice(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));

    expect(closes, isEmpty);
  });

  testWidgets('desktop escape still closes the window', (tester) async {
    final repo = await seededRepo();
    final closes = <int>[];
    await pumpPopup(tester, repo,
        logical: const Size(720, 640), isMobile: false, closes: closes);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));

    expect(closes, hasLength(1));
  });

  testWidgets('arrows move the selection highlight through the results',
      (tester) async {
    final repo = await seededRepo();
    await pumpPopup(tester, repo, logical: iPad, isMobile: true);
    await asDevice(tester);
    expect(selection(tester).indexOf(true), 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(selection(tester).indexOf(true), 2);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(selection(tester).indexOf(true), 1);

    // Clamped at the top: Up on the first row stays put, never wraps.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(selection(tester).indexOf(true), 0);
  });

  testWidgets('arrowing past the fold scrolls the selection into view',
      (tester) async {
    final repo = await seededRepo(extra: 20);
    await pumpPopup(tester, repo, logical: iPad, isMobile: true);
    await asDevice(tester);
    final scroll =
        tester.widget<Scrollable>(find.byType(Scrollable).last).controller!;
    expect(scroll.position.pixels, 0);

    for (var i = 0; i < 18; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.pump();

    expect(scroll.position.pixels, greaterThan(0),
        reason: 'the keyboard selection must not disappear below the fold');
    // And it really is on screen: the selected row is built and laid out.
    expect(selection(tester).where((s) => s).length, 1);
  });

  testWidgets('enter copies the arrow-selected relic', (tester) async {
    final repo = await seededRepo();
    await pumpPopup(tester, repo, logical: iPad, isMobile: true);
    await asDevice(tester);
    final second =
        tester.widgetList<ResultRow>(find.byType(ResultRow)).elementAt(1).relic;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 300));

    expect(repo.copied, [second.uid],
        reason: 'Enter must act on the highlighted row, not the first one');
    // Let the "Copied" toast expire so no timer outlives the tree.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('cmd+F focuses the search box with the query selected',
      (tester) async {
    final repo = await seededRepo();
    await pumpPopup(tester, repo, logical: iPad, isMobile: true);
    await asDevice(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ, character: 'q');
    await tester.pump(const Duration(milliseconds: 300));
    // Focus drifts back to the list (Esc, a closed sheet, a tap).
    await asDevice(tester);
    expect(searchNode(tester).hasFocus, isFalse);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF, character: 'f');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump(const Duration(milliseconds: 300));

    final ctl = tester.widget<TextField>(find.byType(TextField).first).controller!;
    expect(searchNode(tester).hasFocus, isTrue);
    expect(ctl.text, 'q', reason: 'the modifier must not type an "f"');
    expect(ctl.selection, const TextSelection(baseOffset: 0, extentOffset: 1),
        reason: 'the next keystroke should replace the whole query');
  });

  testWidgets('the keyboard still drives the list after a dialog closes',
      (tester) async {
    final repo = await seededRepo();
    await pumpPopup(tester, repo, logical: iPad, isMobile: true);
    await asDevice(tester);
    // Two-pane: a tap opens the relic in the detail pane, whose text field
    // takes the focus. Esc closes it. (Row 1, not row 0 — the selected row
    // shows its action cluster and a centered tap would hit a button.)
    await tester.tap(find.byType(ResultRow).at(1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Select an item'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Select an item'), findsOneWidget);

    // The dialog took the focus with it; the popup has to take it back or
    // every key from here on is swallowed by the enclosing scope.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(selection(tester).indexOf(true), 2);
  });

  testWidgets('touch alone is unchanged: no keys, no keyboard behavior',
      (tester) async {
    final repo = await seededRepo(extra: 4);
    final closes = <int>[];
    await pumpPopup(tester, repo,
        logical: phone, isMobile: true, closes: closes);
    await asDevice(tester);
    // Tap the third row: selection follows the finger, exactly as before.
    await tester.tap(find.byType(ResultRow).at(2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(selection(tester).indexOf(true), 2);
    expect(searchNode(tester).hasFocus, isFalse,
        reason: 'a tap on a row must never pop the software keyboard');
    expect(closes, isEmpty);
  });
}

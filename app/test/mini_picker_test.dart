// The mini picker's click model.
//
// The mini picker is the fastest path from "I need that thing" to the thing
// being in your document, so a click on a row pastes it. It used to be
// select-then-click-again, mirroring the full row, which made the compact
// window a slower version of the popup it was supposed to beat.
//
// The one thing a single click cannot serve is "nearly right, needs a change
// first", so each row carries a pencil. The mini window has no room for the
// editor, so the pencil asks the host to grow to the full popup FIRST and only
// then opens it.
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/widgets/result_row.dart';

void main() {
  final relic = Relic(
    uid: 'm1',
    createdAt: 1785000000,
    updatedAt: 1785000000,
    kind: Kind.string,
    source: Source.clipboard,
    promoted: false,
    byteSize: 12,
    content: 'gcloud auth application-default login',
  );

  Future<void> pumpMini(
    WidgetTester tester, {
    required VoidCallback onSelect,
    required VoidCallback onActivate,
    VoidCallback? onEdit,
    bool selected = false,
  }) => tester.pumpWidget(
    RelicTheme(
      colors: RelicColors.dark,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(),
          child: Material(
            child: SizedBox(
              width: 340,
              child: MiniResultRow(
                relic: relic,
                selected: selected,
                imagePath: null,
                onSelect: onSelect,
                onActivate: onActivate,
                onEdit: onEdit,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  // Hover, held, so the pencil is painted and stays painted.
  Future<TestGesture> hover(WidgetTester tester, Finder target) async {
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    addTearDown(g.removePointer);
    await tester.pump();
    await g.moveTo(tester.getCenter(target));
    await tester.pumpAndSettle();
    return g;
  }

  testWidgets('one click pastes, with no select-then-confirm step',
      (tester) async {
    var activated = 0;
    await pumpMini(tester,
        onSelect: () {}, onActivate: () => activated++, onEdit: () {});

    // The title, not the row: the row's far right is the pencil's slot.
    await tester.tap(find.textContaining('gcloud'));
    await tester.pump();
    expect(activated, 1, reason: 'a single click must activate');
  });

  testWidgets('the pencil edits and does NOT paste', (tester) async {
    // The regression that matters: the pencil sits inside the row's own tap
    // target, so if the inner gesture ever stops winning the arena, clicking
    // edit would paste the item and close the window instead.
    var activated = 0;
    var edited = 0;
    await pumpMini(tester,
        onSelect: () {},
        onActivate: () => activated++,
        onEdit: () => edited++,
        selected: true);

    await tester.tap(find.byIcon(LucideIcons.squarePen));
    await tester.pump();
    expect(edited, 1);
    expect(activated, 0, reason: 'the pencil must not fall through to paste');
  });

  testWidgets('the pencil shows on the selected row and on hover',
      (tester) async {
    final pencil = find.byIcon(LucideIcons.squarePen);

    // Selected: visible with no pointer involved, so the affordance is
    // discoverable by someone driving with the arrow keys.
    await pumpMini(tester,
        onSelect: () {}, onActivate: () {}, onEdit: () {}, selected: true);
    expect(pencil, findsOneWidget);

    // Unselected and unhovered: hidden, so seven other rows stay clean.
    await pumpMini(tester,
        onSelect: () {}, onActivate: () {}, onEdit: () {});
    expect(pencil, findsNothing);

    await hover(tester, find.byType(MiniResultRow));
    expect(pencil, findsOneWidget, reason: 'hover must reveal the pencil');
  });

  testWidgets('hovering a row selects it', (tester) async {
    // Otherwise the pointer and the arrow-key highlight disagree about which
    // item Enter would take.
    var selected = 0;
    await pumpMini(tester,
        onSelect: () => selected++, onActivate: () {}, onEdit: () {});

    await hover(tester, find.byType(MiniResultRow));
    expect(selected, 1);
  });

  testWidgets('the row reserves the pencil slot so titles never reflow',
      (tester) async {
    // The slot is held open whether or not the pencil is painted; without it
    // the title would resize under the pointer as it moves down the list.
    await pumpMini(tester,
        onSelect: () {}, onActivate: () {}, onEdit: () {});
    final cold = tester.getSize(find.textContaining('gcloud'));

    await hover(tester, find.byType(MiniResultRow));
    expect(tester.getSize(find.textContaining('gcloud')), cold);
  });

  testWidgets('no pencil at all when the host cannot expand', (tester) async {
    // Mobile passes no onExpand, so there is no host that can make room.
    await pumpMini(tester, onSelect: () {}, onActivate: () {});
    expect(find.byIcon(LucideIcons.squarePen), findsNothing);
  });
}

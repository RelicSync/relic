import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/widgets/result_row.dart';

/// Two row behaviours that were wrong in ways a screenshot wouldn't catch:
/// the double-click window was tighter than the OS setting, and there was no
/// sign that on-device analysis was running.
void main() {
  final relic = Relic(
    uid: 'u1',
    createdAt: 1785000000,
    updatedAt: 1785000000,
    kind: Kind.string,
    source: Source.clipboard,
    promoted: true,
    byteSize: 12,
    content: 'gcloud auth application-default login',
  );

  Future<void> pumpRow(
    WidgetTester tester, {
    required VoidCallback onSelect,
    required VoidCallback onEdit,
    bool analyzing = false,
  }) => tester.pumpWidget(
    RelicTheme(
      colors: RelicColors.dark,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(),
          child: Material(
            child: SizedBox(
              width: 600,
              child: ResultRow(
                relic: relic,
                selected: false,
                nowSecs: 1785000100,
                analyzing: analyzing,
                onSelect: onSelect,
                onCopy: () {},
                onPromoteToggle: () {},
                onEdit: onEdit,
                onDelete: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );

  // The row measures the gap with DateTime.now(), which ignores pump()'s fake
  // clock — pumping 900 ms still leaves the two taps microseconds apart in real
  // time. Only runAsync actually lets the wall clock move, so these waits are
  // real and the timings below mean what they say.
  Future<void> waitReal(WidgetTester tester, int ms) =>
      tester.runAsync(() => Future.delayed(Duration(milliseconds: ms)));

  group('double-click opens the edit screen', () {
    /// Windows' default double-click speed is 500 ms. The row used to use a
    /// 350 ms window, so an ordinary double-click at system speed registered as
    /// two selects and the edit screen never opened.
    testWidgets('at 400 ms apart — inside the OS window, outside the old one', (
      tester,
    ) async {
      var selects = 0, edits = 0;
      await pumpRow(
        tester,
        onSelect: () => selects++,
        onEdit: () => edits++,
      );

      await tester.tap(find.byType(ResultRow));
      await waitReal(tester, 400);
      await tester.tap(find.byType(ResultRow));
      await tester.pump();

      expect(edits, 1, reason: 'second tap within 500 ms must open the editor');
      expect(selects, 1, reason: 'only the first tap selects');
    });

    testWidgets('a single tap only selects', (tester) async {
      var selects = 0, edits = 0;
      await pumpRow(tester, onSelect: () => selects++, onEdit: () => edits++);

      await tester.tap(find.byType(ResultRow));
      await tester.pump();

      expect(selects, 1);
      expect(edits, 0);
    });

    testWidgets('two slow taps stay two selects', (tester) async {
      var selects = 0, edits = 0;
      await pumpRow(tester, onSelect: () => selects++, onEdit: () => edits++);

      await tester.tap(find.byType(ResultRow));
      await waitReal(tester, 900);
      await tester.tap(find.byType(ResultRow));
      await tester.pump();

      expect(edits, 0);
      expect(selects, 2);
    });
  });

  group('meta line at Split View widths', () {
    // Split View / Slide Over can hand the app 320dp, which leaves the meta
    // line ~130px — less than a device·age prefix plus two tag chips. Every
    // atom after the prefix used to be fixed-width, so the line overflowed
    // instead of shedding chips (docs/apple-port-2026-08.md §7).
    final crowded = Relic(
      uid: 'u2',
      createdAt: 1785000000,
      updatedAt: 1785000000,
      kind: Kind.string,
      source: Source.clipboard,
      promoted: true,
      byteSize: 12,
      content: 'gcloud auth application-default login',
      device: 'MULTIVAC-III',
      userTags: const ['business', 'receipts'],
      tags: const ['url', 'code'],
    );

    // Material hands its child tight constraints, so a bare SizedBox cannot
    // narrow the row — Align loosens them first, which is what makes this a
    // real 320dp pane and not an 800dp one.
    Future<void> pumpAt(WidgetTester tester, double width) =>
        tester.pumpWidget(
          RelicTheme(
            colors: RelicColors.dark,
            isMobile: true,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: MediaQuery(
                data: const MediaQueryData(),
                child: Material(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: width,
                      child: ResultRow(
                        relic: crowded,
                        selected: false,
                        nowSecs: 1785000100,
                        onSelect: () {},
                        onCopy: () {},
                        onPromoteToggle: () {},
                        onEdit: () {},
                        onDelete: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

    /// Tags the row admits to: the chips actually rendered plus however many
    /// the "+N" counter is standing in for. Dropping a chip must move it into
    /// the counter, never make it disappear.
    int tagsAccountedFor() {
      var n = 0;
      for (final label in ['business', 'receipts', '#url', '#code']) {
        n += find.text(label).evaluate().length;
      }
      final counters = find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').startsWith('+'),
      );
      for (final e in counters.evaluate()) {
        n += int.parse((e.widget as Text).data!.substring(1));
      }
      return n;
    }

    testWidgets('320dp (narrow Split View) does not overflow', (tester) async {
      await pumpAt(tester, 320);
      expect(tester.takeException(), isNull);
    });

    testWidgets('320dp keeps the prefix and folds unfittable chips into +N',
        (tester) async {
      await pumpAt(tester, 320);
      expect(find.textContaining('MULTIVAC-III'), findsOneWidget);
      expect(tagsAccountedFor(), 4);
    });

    testWidgets('700dp+ keeps the full meta line, unclipped', (tester) async {
      await pumpAt(tester, 760);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('MULTIVAC-III'), findsOneWidget);
      expect(find.text('business'), findsOneWidget);
      expect(find.text('receipts'), findsOneWidget);
      // Two chips is the cap; the rest collapse into the "+N" counter.
      expect(find.text('+2'), findsOneWidget);
      expect(tagsAccountedFor(), 4);
    });
  });

  group('analysis spinner', () {
    testWidgets('a queued item says so, with a spinner', (tester) async {
      await pumpRow(
        tester,
        onSelect: () {},
        onEdit: () {},
        analyzing: true,
      );

      expect(find.text('Analyzing…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('an analyzed item shows its meta line instead', (tester) async {
      await pumpRow(tester, onSelect: () {}, onEdit: () {});

      expect(find.text('Analyzing…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}

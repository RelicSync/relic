import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/ui/coach_marks.dart';

/// The coach card at the popup's real width: every step, both palettes, with
/// the Learn more link and the progress dots, must lay out without a single
/// pixel of overflow. The buttons used to bleed past the card edge on the
/// steps that showed Skip beside Next (Windows and macOS alike).
void main() {
  for (final colors in [RelicColors.light, RelicColors.dark]) {
    testWidgets(
      'coach card never overflows in ${colors.isDark ? 'dark' : 'light'} mode',
      (tester) async {
        tester.view.physicalSize = const Size(520, 620);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final anchor = GlobalKey();
        final capture = GlobalKey();
        final steps = [
          for (var i = 0; i < 9; i++)
            CoachStep(
              targetKey: anchor,
              title: 'Step ${i + 1} with a title that runs long',
              body:
                  'A body of the length the real steps use, three lines or so, '
                  'so the card is measured at its true height and not a stub.',
            ),
        ];
        var done = 0;
        await tester.pumpWidget(
          RelicTheme(
            colors: colors,
            child: MaterialApp(
              theme: materialThemeFor(colors),
              home: RepaintBoundary(
                key: capture,
                child: Stack(
                  children: [
                    Positioned(
                      left: 200,
                      top: 60,
                      child: SizedBox(key: anchor, width: 120, height: 32),
                    ),
                    Positioned.fill(
                      child: CoachMarks(
                        steps: steps,
                        helpKey: 'help.popup',
                        onDone: () => done++,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final shots = Platform.environment['RELIC_COACH_SCREENSHOTS'];
        for (var i = 0; i < steps.length; i++) {
          await tester.pump();
          expect(tester.takeException(), isNull, reason: 'step ${i + 1}');
          if (shots != null) {
            await tester.runAsync(() async {
              final boundary =
                  capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await boundary.toImage();
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$shots/coach-${colors.isDark ? 'dark' : 'light'}-${i + 1}.png',
              ).writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            });
          }
          await tester.tap(
            find.text(i == steps.length - 1 ? 'Got it' : 'Next'),
          );
        }
        await tester.pump();
        expect(done, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/ui/voice_offer.dart';

void main() {
  for (final colors in [RelicColors.light, RelicColors.dark]) {
    testWidgets(
      'Voice offer answers once in ${colors.isDark ? 'dark' : 'light'} mode',
      (tester) async {
        tester.view.physicalSize = const Size(560, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var accepted = 0, declined = 0;
        await tester.pumpWidget(
          RelicTheme(
            colors: colors,
            child: MaterialApp(
              theme: materialThemeFor(colors),
              home: Scaffold(
                body: VoiceOffer(
                  dark: colors.isDark,
                  onAccept: () => accepted++,
                  onDecline: () => declined++,
                ),
              ),
            ),
          ),
        );
        expect(find.text('Relic can take dictation now'), findsOneWidget);
        expect(find.textContaining('716 MB'), findsOneWidget);
        expect(find.textContaining('never sent anywhere'), findsOneWidget);
        await tester.tap(find.text('Turn on voice'));
        await tester.pump();
        expect(accepted, 1);
        expect(declined, 0);
        await tester.tap(find.text('Not now'));
        await tester.pump();
        expect(declined, 1);
      },
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/widgets/chrome.dart';

/// The global sync chip shows a determinate "Uploading NN%" while a blob is in
/// flight, taking precedence over the ordinary sync states.
void main() {
  Future<void> pumpHeader(WidgetTester tester, {double? uploadFraction}) async {
    await tester.pumpWidget(
      RelicTheme(
        colors: RelicColors.dark,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: SizedBox(
              width: 600,
              child: PopupHeader(
                sync: const SyncState(SyncKind.synced),
                uploadFraction: uploadFraction,
                onSettings: () {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('chip shows the rounded upload percentage', (tester) async {
    await pumpHeader(tester, uploadFraction: 0.42);
    expect(find.text('Uploading 42%'), findsOneWidget);
    expect(find.text('Synced'), findsNothing); // upload wins the chip
  });

  testWidgets('a just-started (0) upload reads as indeterminate', (tester) async {
    await pumpHeader(tester, uploadFraction: 0);
    expect(find.text('Uploading…'), findsOneWidget);
  });

  testWidgets('no upload → the ordinary synced state', (tester) async {
    await pumpHeader(tester);
    expect(find.text('Synced'), findsOneWidget);
    expect(find.textContaining('Uploading'), findsNothing);
  });
}

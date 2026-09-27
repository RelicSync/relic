// The empty list on a phone.
//
// In the 14 days to 2026-09-27, 12 accounts that only ever used a phone saved
// 1 item between them. They all got through sign-up and reached the list,
// which told them "Copy anything ... and it lands here automatically". A phone
// can't do that, so they copied something, saw nothing, and left. These tests
// pin the phone version: it names sharing and writing a note, and each has a
// button. The desktop keeps its own line.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/repo.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/ui/popup.dart';

class _EmptyRepo extends MemoryRepo {
  @override
  bool get coachMarksSeen => true;
  @override
  bool get keepHintShown => true;
}

void main() {
  const desktopLine =
      'Copy anything (text, an image, a file) and it lands here automatically.';

  Future<void> pump(
    WidgetTester tester, {
    VoidCallback? onNewNote,
    VoidCallback? onShareHelp,
    ValueNotifier<int?>? devices,
    double width = 400,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RelicTheme(
          colors: RelicColors.light,
          isMobile: true,
          child: Scaffold(
            body: PopupView(
              repo: _EmptyRepo(),
              onClose: () {},
              onSettings: () {},
              deviceCount: devices,
              thisDeviceLabel: 'Pixel',
              onNewNote: onNewNote,
              onShareHelp: onShareHelp,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('a phone says how things get in, with a button for each', (
    tester,
  ) async {
    var notes = 0;
    var help = 0;
    await pump(tester, onNewNote: () => notes++, onShareHelp: () => help++);

    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(find.textContaining('tap Share and pick Relic'), findsOneWidget);
    expect(find.text(desktopLine), findsNothing);

    await tester.tap(find.text('Write a note'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(notes, 1);

    await tester.tap(find.text('How to share to Relic'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(help, 1);
  });

  testWidgets('without the phone callbacks the desktop line stays', (
    tester,
  ) async {
    // Desktop width: the drop-files pill is sized for a window, not a phone.
    await pump(tester, width: 520);
    expect(find.text(desktopLine), findsOneWidget);
    expect(find.text('Write a note'), findsNothing);
  });

  testWidgets('a brand-new phone does not see the second-vault notice', (
    tester,
  ) async {
    final devices = ValueNotifier<int?>(1);
    addTearDown(devices.dispose);
    await pump(tester, onNewNote: () {}, devices: devices);
    expect(find.textContaining('second vault'), findsNothing);
    expect(find.text('Link it'), findsNothing);
  });
}

// The first question desktop onboarding asks.
//
// People were installing Relic on a second computer, making a brand new
// account, landing in an empty vault, and never finding the things they had
// saved. The flow now asks whether this is their first device before it asks
// how they want to sign in, and it stops them again if the account they signed
// in with turns out to be empty. These tests pin that routing.
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/onboarding/desktop_onboarding.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';

void main() {
  group('first step', () {
    test('a fresh start asks which device this is', () {
      expect(
        firstDesktopStep(
            startAtSignIn: false, startReturning: false, isMacOS: false),
        DesktopStep.doors,
      );
    });

    test('switch account still goes straight to the sign-in form', () {
      for (final returning in [true, false]) {
        for (final mac in [true, false]) {
          expect(
            firstDesktopStep(
                startAtSignIn: true, startReturning: returning, isMacOS: mac),
            DesktopStep.signIn,
            reason: 'startReturning=$returning isMacOS=$mac',
          );
        }
      }
    });

    test('a caller that already asked opens on sign-in choices', () {
      expect(
        firstDesktopStep(
            startAtSignIn: false, startReturning: true, isMacOS: false),
        DesktopStep.welcome,
      );
    });

    test('a Mac still opens on the Accessibility ask', () {
      for (final returning in [true, false]) {
        expect(
          firstDesktopStep(
              startAtSignIn: false, startReturning: returning, isMacOS: true),
          DesktopStep.accessibility,
          reason: 'startReturning=$returning',
        );
      }
    });
  });

  group('after the Accessibility ask', () {
    test('a first-run Mac lands on the doors', () {
      expect(stepAfterAccessibility(returning: false), DesktopStep.doors);
    });

    test('a Mac that was told the answer skips them', () {
      expect(stepAfterAccessibility(returning: true), DesktopStep.welcome);
    });
  });

  group('after sign-in', () {
    test('an account with a vault unlocks it', () {
      for (final returning in [true, false]) {
        expect(
          stepAfterAuth(existingVault: true, returning: returning),
          DesktopStep.chooser,
          reason: 'returning=$returning',
        );
      }
    });

    test('a first device with an empty account sets a passphrase', () {
      expect(
        stepAfterAuth(existingVault: false, returning: false),
        DesktopStep.oauthCreate,
      );
    });

    test('a second device with an empty account gets warned', () {
      expect(
        stepAfterAuth(existingVault: false, returning: true),
        DesktopStep.noVaultHere,
      );
    });
  });

  group('the doors on screen', () {
    /// Load the shipped fonts so the buttons measure at their real width. Same
    /// recipe as the screenshot harnesses; the test font is wide enough to
    /// overflow a label that fits fine in the app.
    Future<void> realFonts(WidgetTester tester) => tester.runAsync(() async {
          Future<void> load(String family, List<String> assets) async {
            final loader = FontLoader(family);
            for (final a in assets) {
              loader.addFont(rootBundle.load(a));
            }
            await loader.load();
          }

          await load(
              'StackSansHeadline', ['assets/fonts/StackSansHeadline.ttf']);
          await load('StackSansText', ['assets/fonts/StackSansText.ttf']);
          await load('JetBrainsMono', ['assets/fonts/JetBrainsMono.ttf']);
          await load('IBMPlexSans', ['assets/fonts/IBMPlexSans.ttf']);
        });

    Future<void> pump(WidgetTester tester) async {
      await realFonts(tester);
      tester.view.physicalSize = const Size(520, 620);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RelicTheme(
          colors: RelicColors.dark,
          isMobile: false,
          child: Scaffold(
            body: DesktopOnboarding(
              onSignInPassphrase: (_, _, _) async => null,
              onRecoveryKit: (_, _, _, _) async => null,
              onOAuthCreate: (_, _) async => null,
              onOAuthUnlock: (_, _) async => null,
              onOAuthRecoveryKit: (_, _, _) async => null,
              onPairedMk: (_, _) async => null,
              onCancel: () {},
              onTryDemo: () {},
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> tapText(WidgetTester tester, String label) async {
      final finder = find.text(label);
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('the question comes before the sign-in choices',
        (tester) async {
      await pump(tester);
      expect(find.text('Is this your first device?'), findsOneWidget);
      expect(find.text('Start a new vault'), findsOneWidget);
      expect(find.text('I already use Relic on another device'), findsOneWidget);
      // Nothing about how to sign in yet.
      expect(find.text('Create with email'), findsNothing);
      expect(find.text('Sign in with email'), findsNothing);
      // The escape hatches stay on the very first screen.
      expect(find.textContaining('Try the demo'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
    });

    testWidgets('a first device can still create an account', (tester) async {
      await pump(tester);
      await tapText(tester, 'Start a new vault');
      expect(find.text('Create with email'), findsOneWidget);
      expect(find.text('Sign in with email'), findsOneWidget);
    });

    testWidgets('a second device is only offered sign-in', (tester) async {
      await pump(tester);
      await tapText(tester, 'I already use Relic on another device');
      expect(find.text('Sign in with email'), findsOneWidget);
      expect(find.text('Create with email'), findsNothing);
      expect(
        find.text('Use the same Google, GitHub, Apple or email account as your '
            'other device.'),
        findsOneWidget,
      );
    });

    testWidgets('back returns to the question', (tester) async {
      await pump(tester);
      await tapText(tester, 'I already use Relic on another device');
      expect(find.text('Is this your first device?'), findsNothing);
      await tapText(tester, 'Back');
      expect(find.text('Is this your first device?'), findsOneWidget);
      expect(find.text('Sign in with email'), findsNothing);
    });
    // The widget opens on the macOS Accessibility ask there, which needs a
    // live TCC database; the pure functions above cover that branch.
  }, skip: Platform.isMacOS);
}

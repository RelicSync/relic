// The first question mobile onboarding asks, and what a pairing link changes.
//
// People were installing Relic on a phone, making a brand new account, landing
// in an empty vault, and never finding the things they had saved on their
// computer. The flow now asks whether this is their first device before it asks
// how they want to sign in, and it stops them again if the account they signed
// in with turns out to be empty. A link handed to the app by the OS answers the
// question for them and signs them in as the right account. These tests pin
// that routing.
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FontLoader, MethodChannel, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/pairing_link.dart';
import 'package:relic_app/onboarding/onboarding.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/widgets/brand.dart';

void main() {
  group('first step', () {
    test('a fresh start asks which device this is', () {
      expect(
        firstMobileStep(
            startAtSignIn: false, startReturning: false, hasPairingLink: false),
        MobileStep.doors,
      );
    });

    test('switch account still goes straight to the sign-in form', () {
      for (final returning in [true, false]) {
        for (final link in [true, false]) {
          expect(
            firstMobileStep(
                startAtSignIn: true,
                startReturning: returning,
                hasPairingLink: link),
            MobileStep.signIn,
            reason: 'startReturning=$returning hasPairingLink=$link',
          );
        }
      }
    });

    test('a caller that already asked opens on sign-in choices', () {
      expect(
        firstMobileStep(
            startAtSignIn: false, startReturning: true, hasPairingLink: false),
        MobileStep.welcome,
      );
    });

    test('a pairing link answers the question by itself', () {
      expect(
        firstMobileStep(
            startAtSignIn: false, startReturning: false, hasPairingLink: true),
        MobileStep.welcome,
      );
    });
  });

  group('after sign-in', () {
    test('a first device with an empty account sets a passphrase', () {
      for (final link in [true, false]) {
        expect(
          mobileStepAfterAuth(
              existingVault: false,
              returning: false,
              hasLink: link,
              linkExpired: false),
          MobileStep.oauthCreatePass,
          reason: 'hasLink=$link',
        );
      }
    });

    test('a second device with an empty account gets warned', () {
      for (final link in [true, false]) {
        expect(
          mobileStepAfterAuth(
              existingVault: false,
              returning: true,
              hasLink: link,
              linkExpired: false),
          MobileStep.noVaultHere,
          reason: 'hasLink=$link',
        );
      }
    });

    test('a live link joins without asking for a scan', () {
      expect(
        mobileStepAfterAuth(
            existingVault: true,
            returning: true,
            hasLink: true,
            linkExpired: false),
        MobileStep.joining,
      );
    });

    test('an expired link falls back to the scanner', () {
      expect(
        mobileStepAfterAuth(
            existingVault: true,
            returning: true,
            hasLink: true,
            linkExpired: true),
        MobileStep.scanQr,
      );
    });

    test('an account with a vault and no link picks how to unlock', () {
      for (final returning in [true, false]) {
        expect(
          mobileStepAfterAuth(
              existingVault: true,
              returning: returning,
              hasLink: false,
              linkExpired: false),
          MobileStep.unlockChooser,
          reason: 'returning=$returning',
        );
      }
    });
  });

  group('the doors on screen', () {
    // The device id lives in secure storage, which onboarding reads the moment
    // it mounts. Nothing here depends on the value, it just must not throw.
    const storage =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storage, (_) async => null);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storage, null);
    });

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

    Future<void> pump(WidgetTester tester,
        {bool startReturning = false, PairingLink? link}) async {
      await realFonts(tester);
      tester.view.physicalSize = const Size(430, 940);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RelicTheme(
          colors: RelicColors.dark,
          isMobile: true,
          child: OnboardingFlow(
            onConnected: (_) {},
            startReturning: startReturning,
            pairingLink: link,
            onBrowseOnly: () {},
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
      // Settle the step switcher's cross-fade, so the screen being left is
      // really gone rather than half faded out.
      await tester.pumpAndSettle();
    }

    testWidgets('the question comes before the sign-in choices',
        (tester) async {
      await pump(tester);
      expect(find.text('Is this your first device?'), findsOneWidget);
      expect(find.text('Start a new vault'), findsOneWidget);
      expect(find.text('I already use Relic on another device'), findsOneWidget);
      // Nothing about how to sign in yet.
      expect(find.byType(OAuthButton), findsNothing);
      expect(find.text('Create with email'), findsNothing);
      expect(find.text('Sign in with email'), findsNothing);
      // The quiet escape stays on the very first screen.
      expect(find.text('Not now'), findsOneWidget);
    });

    testWidgets('a first device can still create an account', (tester) async {
      await pump(tester);
      await tapText(tester, 'Start a new vault');
      expect(find.byType(OAuthButton), findsNWidgets(3));
      expect(find.text('Create with email'), findsOneWidget);
    });

    testWidgets('a second device is only offered sign-in', (tester) async {
      await pump(tester);
      await tapText(tester, 'I already use Relic on another device');
      expect(find.byType(OAuthButton), findsNWidgets(3));
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

    testWidgets('a caller that already asked opens on the returning welcome',
        (tester) async {
      await pump(tester, startReturning: true);
      expect(find.text('Is this your first device?'), findsNothing);
      expect(find.text('Sign in with the account\nyou use there.'),
          findsOneWidget);
      expect(find.text('Create with email'), findsNothing);
    });

    testWidgets('a pairing link fills in the account it came from',
        (tester) async {
      await pump(tester,
          link: const PairingLink(
              payload: 'relic-pair:v2:id:key:ah:hint', email: 'pat@example.com'));
      expect(find.text('Sign in with the account\nyou use there.'),
          findsOneWidget);
      await tapText(tester, 'Sign in with email');
      expect(find.text('pat@example.com'), findsOneWidget);
    });
    // The scanner step needs the camera plugin, so nothing here renders it.
  }, skip: Platform.isMacOS);
}

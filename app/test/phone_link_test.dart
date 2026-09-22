// The phone legs of the onboarding funnel (docs/onboarding-funnel-2026-09.md).
//
// Three things, all answering the same finding: a phone-only account dies
// inside a day, and the people who do own a desktop vault tend to sign up
// again on the phone instead of linking it.
//
//  1. A tapped pairing link opens onboarding on a phone with no vault, and
//     says so on a phone that already has one.
//  2. The second-vault notice now shows on a phone too.
//  3. The first-run screen tells a phone user what a phone actually does, and
//     offers to mail them the desktop link.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/repo.dart';
import 'package:relic_app/mobile.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/ui/phone_expectation.dart';
import 'package:relic_app/ui/popup.dart';

const _thisPhone = 'Jordan’s phone';

/// A connected repo whose second-vault pref is settable from the test.
class _PhoneRepo extends MemoryRepo {
  bool dismissed = false;

  @override
  bool get secondVaultNoticeDismissed => dismissed;
  @override
  Future<void> markSecondVaultNoticeDismissed() async => dismissed = true;
  @override
  bool get keepHintShown => true;
  @override
  bool get coachMarksSeen => true;
  @override
  AccountInfo? get account => const AccountInfo(
        tier: 'Free',
        usedBytes: 1200,
        quotaBytes: 262144000,
        vaultCount: 4,
        vaultCap: 100,
      );
}

void main() {
  group('a tapped pairing link', () {
    test('opens onboarding on a phone with no vault', () {
      expect(pairLinkAction(hasRepo: false, browseOnly: false),
          PairLinkAction.openOnboarding);
    });

    test('opens onboarding from the browse-only state', () {
      expect(pairLinkAction(hasRepo: false, browseOnly: true),
          PairLinkAction.openOnboarding);
    });

    test('says the phone is already linked when a vault is bound', () {
      expect(pairLinkAction(hasRepo: true, browseOnly: false),
          PairLinkAction.alreadyLinked);
    });

    test('browse-only wins even if a repo is somehow still around', () {
      expect(pairLinkAction(hasRepo: true, browseOnly: true),
          PairLinkAction.openOnboarding);
    });
  });

  group('the second-vault notice on a phone', () {
    const notice = 'Expecting things you saved on another device? '
        'You may have started a second vault.';

    Future<void> pump(
      WidgetTester tester,
      MemoryRepo repo, {
      required ValueNotifier<int?> devices,
      VoidCallback? onJoin,
    }) async {
      tester.view.physicalSize = const Size(390, 844); // a phone
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RelicTheme(
          colors: RelicColors.light,
          isMobile: true,
          child: Scaffold(
            body: PopupView(
              repo: repo,
              onClose: () {},
              onSettings: () {},
              deviceCount: devices,
              thisDeviceLabel: _thisPhone,
              onJoinExistingVault: onJoin ?? () {},
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> pad(MemoryRepo repo, {int count = 3}) async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      for (var i = 0; i < count; i++) {
        await repo.restore(Relic(
          uid: 'phone$i',
          createdAt: now - 100 - i,
          updatedAt: now - 100 - i,
          kind: Kind.string,
          source: Source.clipboard,
          promoted: false,
          byteSize: 12,
          device: _thisPhone,
          content: 'shared thing number $i',
        ));
      }
    }

    testWidgets('shows above the list at phone width', (tester) async {
      final repo = _PhoneRepo();
      await pad(repo);
      final devices = ValueNotifier<int?>(1);
      addTearDown(devices.dispose);
      await pump(tester, repo, devices: devices);

      expect(find.text(notice), findsOneWidget);
      expect(find.text('Link it'), findsOneWidget);
      // It sits above the list, not over it: nothing is clipped off-screen.
      expect(tester.getTopLeft(find.text(notice)).dy, greaterThanOrEqualTo(0));
      expect(tester.getBottomRight(find.text(notice)).dx, lessThanOrEqualTo(390));
    });

    testWidgets('Link it opens the returning door', (tester) async {
      final repo = _PhoneRepo();
      await pad(repo);
      final devices = ValueNotifier<int?>(1);
      addTearDown(devices.dispose);
      var joined = 0;
      await pump(tester, repo, devices: devices, onJoin: () => joined++);

      await tester.tap(find.text('Link it'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(joined, 1);
    });

    testWidgets('a second device on the account keeps it away', (tester) async {
      final repo = _PhoneRepo();
      await pad(repo);
      final devices = ValueNotifier<int?>(2);
      addTearDown(devices.dispose);
      await pump(tester, repo, devices: devices);
      expect(find.text(notice), findsNothing);
    });
  });

  group('the phone expectation screen', () {
    Future<void> pump(
      WidgetTester tester, {
      required Future<void> Function() onSend,
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RelicTheme(
          colors: RelicColors.light,
          isMobile: true,
          child: PhoneExpectationScreen(onSendDownloadLink: onSend),
        ),
      ));
      await tester.pump();
    }

    testWidgets('says what a phone does, and offers both ways on',
        (tester) async {
      await pump(tester, onSend: () async {});
      expect(find.text('Relic on a phone works differently'), findsOneWidget);
      expect(
          find.text(
              'On a computer, Relic saves what you copy by itself. '
              'On a phone, you share things to it on purpose. '
              'Your vault is the same on both.'),
          findsOneWidget);
      expect(find.text('Send me the download link'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
    });

    testWidgets('the button sends, and says so', (tester) async {
      var sent = 0;
      await pump(tester, onSend: () async => sent++);

      await tester.tap(find.text('Send me the download link'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(sent, 1);
      expect(find.text('Sent. Open it on your computer.'), findsOneWidget);
    });

    testWidgets('a refusal is shown in the words the server used',
        (tester) async {
      await pump(tester,
          onSend: () async => throw StateError('Already sent. Check your inbox.'));

      await tester.tap(find.text('Send me the download link'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Already sent. Check your inbox.'), findsOneWidget);
    });
  });
}

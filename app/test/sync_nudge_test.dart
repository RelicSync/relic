// The sync card above the list.
//
// Twelve phone-only accounts saved one item between them in the two weeks to
// 2026-09-27. They all got through sign-up; what they never got was the
// point: the computer captures, the phone reads. One screen said so during
// sign-up and nothing said it again. The card says it above the list, on
// either side, until the account has a second device, and "Not now" puts it
// off for a fortnight at a time.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/repo.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/ui/popup.dart';
import 'package:relic_app/ui/sync_nudge.dart';

/// A connected repo whose snooze is settable from the test.
class _NudgeRepo extends MemoryRepo {
  int snoozedUntil = 0;
  @override
  int get syncNudgeSnoozedUntil => snoozedUntil;
  @override
  Future<void> snoozeSyncNudge(int until) async => snoozedUntil = until;
  @override
  AccountInfo? get account => AccountInfo(
        tier: 'Free',
        usedBytes: 1200000,
        quotaBytes: 262144000,
        vaultCount: 0,
        vaultCap: 100,
      );
}

void main() {
  const phoneTitle = 'Relic is built for syncing with your computer';
  const desktopTitle = 'Get your clipboard on your phone';

  Future<void> pad(MemoryRepo repo, int count) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (var i = 0; i < count; i++) {
      await repo.restore(Relic(
        uid: 'pad$i',
        createdAt: now - 100 - i,
        updatedAt: now - 100 - i,
        kind: Kind.string,
        source: Source.clipboard,
        promoted: false,
        byteSize: 12,
        device: 'here',
        content: 'padding copy number $i',
      ));
    }
  }

  Future<void> pump(
    WidgetTester tester,
    MemoryRepo repo, {
    required ValueNotifier<int?> devices,
    required bool mobile,
    Future<void> Function()? onSendDownloadLink,
    VoidCallback? onAddDevice,
  }) async {
    tester.view.physicalSize =
        mobile ? const Size(360, 760) : const Size(520, 620);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RelicTheme(
        colors: RelicColors.light,
        isMobile: mobile,
        child: Scaffold(
          body: PopupView(
            repo: repo,
            onClose: () {},
            onSettings: () {},
            deviceCount: devices,
            onSendDownloadLink: onSendDownloadLink,
            onAddDevice: onAddDevice,
            onNewNote: mobile ? () {} : null,
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('the rule', () {
    test('a lone device that is connected sees the card', () {
      expect(
        showSyncNudge(
          connected: true,
          deviceCount: 1,
          itemCount: 0,
          snoozedUntil: 0,
          now: 1000,
          desktop: false,
        ),
        isTrue,
      );
    });

    test('a second device ends it, and an unknown count keeps it quiet', () {
      for (final count in [null, 0, 2, 5]) {
        expect(
          showSyncNudge(
            connected: true,
            deviceCount: count,
            itemCount: 0,
            snoozedUntil: 0,
            now: 1000,
            desktop: false,
          ),
          isFalse,
          reason: 'device count $count',
        );
      }
    });

    test('not now keeps it away until the snooze is over', () {
      expect(
        showSyncNudge(
          connected: true,
          deviceCount: 1,
          itemCount: 0,
          snoozedUntil: 2000,
          now: 1999,
          desktop: false,
        ),
        isFalse,
      );
      expect(
        showSyncNudge(
          connected: true,
          deviceCount: 1,
          itemCount: 0,
          snoozedUntil: 2000,
          now: 2000,
          desktop: false,
        ),
        isTrue,
      );
    });

    test('the desktop waits for a few saved items; the phone does not', () {
      expect(
        showSyncNudge(
          connected: true,
          deviceCount: 1,
          itemCount: syncNudgeDesktopMinItems - 1,
          snoozedUntil: 0,
          now: 1000,
          desktop: true,
        ),
        isFalse,
      );
      expect(
        showSyncNudge(
          connected: true,
          deviceCount: 1,
          itemCount: syncNudgeDesktopMinItems,
          snoozedUntil: 0,
          now: 1000,
          desktop: true,
        ),
        isTrue,
      );
    });

    test('nothing without a connected account', () {
      expect(
        showSyncNudge(
          connected: false,
          deviceCount: 1,
          itemCount: 50,
          snoozedUntil: 0,
          now: 1000,
          desktop: true,
        ),
        isFalse,
      );
    });
  });

  group('on a phone', () {
    testWidgets('the card sits above an empty list and sends the link',
        (tester) async {
      final repo = _NudgeRepo();
      var sent = 0;
      await pump(tester, repo,
          devices: ValueNotifier(1),
          mobile: true,
          onSendDownloadLink: () async => sent++);
      expect(find.text(phoneTitle), findsOneWidget);
      expect(find.text('Nothing here yet'), findsOneWidget);

      await tester.tap(find.text('Email me the link'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(sent, 1);
      expect(find.textContaining('Sent. Open it on your computer'),
          findsOneWidget);
      expect(find.text('Email me the link'), findsNothing,
          reason: 'one mail is enough; the button goes once it is sent');
    });

    testWidgets('a failed send says why and keeps the button', (tester) async {
      final repo = _NudgeRepo();
      await pump(tester, repo,
          devices: ValueNotifier(1),
          mobile: true,
          onSendDownloadLink: () async =>
              throw StateError('No connection. Try again in a moment.'));
      await tester.tap(find.text('Email me the link'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('No connection. Try again in a moment.'), findsOneWidget);
      expect(find.text('Email me the link'), findsOneWidget);
    });

    testWidgets('not now snoozes it for a fortnight', (tester) async {
      final repo = _NudgeRepo();
      await pump(tester, repo,
          devices: ValueNotifier(1),
          mobile: true,
          onSendDownloadLink: () async {});
      expect(find.text(phoneTitle), findsOneWidget);
      final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await tester.tap(find.text('Not now'));
      await tester.pump();
      expect(find.text(phoneTitle), findsNothing);
      expect(repo.snoozedUntil - before,
          closeTo(syncNudgeSnooze.inSeconds, 5));
    });

    testWidgets('a second device takes it down', (tester) async {
      final repo = _NudgeRepo();
      final devices = ValueNotifier<int?>(1);
      await pump(tester, repo,
          devices: devices, mobile: true, onSendDownloadLink: () async {});
      expect(find.text(phoneTitle), findsOneWidget);
      devices.value = 2;
      await tester.pump();
      expect(find.text(phoneTitle), findsNothing);
    });

    testWidgets('a phone that cannot send the link shows nothing',
        (tester) async {
      final repo = _NudgeRepo();
      await pump(tester, repo, devices: ValueNotifier(1), mobile: true);
      expect(find.text(phoneTitle), findsNothing);
    });
  });

  group('on a desktop', () {
    testWidgets('the card asks for a phone once a few things are saved',
        (tester) async {
      final repo = _NudgeRepo();
      await pad(repo, syncNudgeDesktopMinItems);
      var opened = 0;
      await pump(tester, repo,
          devices: ValueNotifier(1),
          mobile: false,
          onAddDevice: () => opened++);
      expect(find.text(desktopTitle), findsOneWidget);
      await tester.tap(find.text('Add a phone'));
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('an empty desktop vault is left alone', (tester) async {
      final repo = _NudgeRepo();
      await pump(tester, repo,
          devices: ValueNotifier(1), mobile: false, onAddDevice: () {});
      expect(find.text(desktopTitle), findsNothing);
    });
  });
}

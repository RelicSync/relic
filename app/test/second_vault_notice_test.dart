// The second vault, and the phone that was never added.
//
// 54 real accounts said the same thing twice: everybody who installs the
// desktop app saves something, and at least one person ended up with 462 items
// on Windows and an empty vault on their phone under a near-identical email.
// They signed up again instead of linking the phone. These tests pin the two
// desktop answers: a dismissible notice when this looks like a second vault,
// and a one-time nudge to add a phone once there is a vault worth carrying.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/repo.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/ui/popup.dart';

const _thisPc = 'this-pc';

/// A connected repo whose two new prefs are settable from the test.
class _NoticeRepo extends MemoryRepo {
  bool dismissed = false;
  bool nudgeShown = false;
  bool keepShown = true;
  bool coachSeen = true;
  int vaultCount = 4;

  @override
  bool get secondVaultNoticeDismissed => dismissed;
  @override
  Future<void> markSecondVaultNoticeDismissed() async => dismissed = true;
  @override
  bool get addPhoneNudgeShown => nudgeShown;
  @override
  Future<void> markAddPhoneNudgeShown() async => nudgeShown = true;
  @override
  bool get keepHintShown => keepShown;
  @override
  Future<void> markKeepHintShown() async => keepShown = true;
  @override
  bool get coachMarksSeen => coachSeen;
  @override
  AccountInfo? get account => AccountInfo(
        tier: 'Free',
        usedBytes: 1200000,
        quotaBytes: 262144000,
        vaultCount: vaultCount,
        vaultCap: 100,
      );
}

void main() {
  const notice = 'Expecting things you saved on another device? '
      'You may have started a second vault.';
  const nudge = 'Add your phone. Your vault travels with you.';

  /// [count] items, all saved on [device].
  Future<void> pad(MemoryRepo repo, {int count = 20, String device = _thisPc}) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (var i = 0; i < count; i++) {
      await repo.restore(Relic(
        uid: 'pad$i-$device',
        createdAt: now - 100 - i,
        updatedAt: now - 100 - i,
        kind: Kind.string,
        source: Source.clipboard,
        promoted: false,
        byteSize: 12,
        device: device,
        content: 'padding copy number $i',
      ));
    }
  }

  Future<void> pump(
    WidgetTester tester,
    MemoryRepo repo, {
    required ValueNotifier<int?> devices,
    String? label = _thisPc,
    VoidCallback? onAddDevice,
    VoidCallback? onJoin,
  }) async {
    tester.view.physicalSize = const Size(520, 620);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RelicTheme(
        colors: RelicColors.dark,
        isMobile: false,
        child: Scaffold(
          body: PopupView(
            repo: repo,
            onClose: () {},
            onSettings: () {},
            deviceCount: devices,
            thisDeviceLabel: label,
            onAddDevice: onAddDevice ?? () {},
            onJoinExistingVault: onJoin ?? () {},
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('the notice rule', () {
    test('fires for a connected, lone, all-local vault', () {
      expect(
        showSecondVaultNotice(
          connected: true,
          deviceCount: 1,
          anyFromOtherDevice: false,
          itemCount: 3,
          dismissed: false,
        ),
        isTrue,
      );
    });

    test('stays away when the vault is not connected', () {
      expect(
        showSecondVaultNotice(
          connected: false,
          deviceCount: 1,
          anyFromOtherDevice: false,
          itemCount: 3,
          dismissed: false,
        ),
        isFalse,
      );
    });

    test('stays away with a second device on the account', () {
      expect(
        showSecondVaultNotice(
          connected: true,
          deviceCount: 2,
          anyFromOtherDevice: false,
          itemCount: 3,
          dismissed: false,
        ),
        isFalse,
      );
    });

    test('stays away while the device count is unknown', () {
      expect(
        showSecondVaultNotice(
          connected: true,
          deviceCount: null,
          anyFromOtherDevice: false,
          itemCount: 3,
          dismissed: false,
        ),
        isFalse,
      );
    });

    test('stays away once something has arrived from elsewhere', () {
      expect(
        showSecondVaultNotice(
          connected: true,
          deviceCount: 1,
          anyFromOtherDevice: true,
          itemCount: 3,
          dismissed: false,
        ),
        isFalse,
      );
    });

    test('stays away once the list is long', () {
      expect(
        showSecondVaultNotice(
          connected: true,
          deviceCount: 1,
          anyFromOtherDevice: false,
          itemCount: secondVaultNoticeMaxItems,
          dismissed: false,
        ),
        isFalse,
      );
    });

    test('stays away once dismissed', () {
      expect(
        showSecondVaultNotice(
          connected: true,
          deviceCount: 1,
          anyFromOtherDevice: false,
          itemCount: 3,
          dismissed: true,
        ),
        isFalse,
      );
    });
  });

  group('the nudge rule', () {
    bool call({
      bool desktop = true,
      bool coachSeen = true,
      bool connected = true,
      int? deviceCount = 1,
      int itemCount = addPhoneNudgeThreshold,
      bool shown = false,
    }) =>
        showAddPhoneNudge(
          desktop: desktop,
          coachSeen: coachSeen,
          connected: connected,
          deviceCount: deviceCount,
          itemCount: itemCount,
          shown: shown,
        );

    test('fires at the threshold', () => expect(call(), isTrue));
    test('stays away on a phone', () => expect(call(desktop: false), isFalse));
    test('waits for the coach marks',
        () => expect(call(coachSeen: false), isFalse));
    test('stays away when not connected',
        () => expect(call(connected: false), isFalse));
    test('stays away with a second device',
        () => expect(call(deviceCount: 2), isFalse));
    test('stays away while the count is unknown',
        () => expect(call(deviceCount: null), isFalse));
    test('stays away one item short',
        () => expect(call(itemCount: addPhoneNudgeThreshold - 1), isFalse));
    test('stays away once shown', () => expect(call(shown: true), isFalse));
  });

  group('the notice on screen', () {
    testWidgets('shows, and dismissing it sticks', (tester) async {
      final repo = _NoticeRepo();
      await pad(repo, count: 3);
      final devices = ValueNotifier<int?>(1);
      addTearDown(devices.dispose);
      await pump(tester, repo, devices: devices);

      expect(find.text(notice), findsOneWidget);
      expect(find.text('Link it'), findsOneWidget);

      await tester.tap(find.byTooltip('Hide this'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(repo.dismissed, isTrue);
      expect(find.text(notice), findsNothing);
    });

    testWidgets('Link it opens the sign-in flow', (tester) async {
      final repo = _NoticeRepo();
      await pad(repo, count: 3);
      final devices = ValueNotifier<int?>(1);
      addTearDown(devices.dispose);
      var joined = 0;
      await pump(tester, repo, devices: devices, onJoin: () => joined++);

      await tester.tap(find.text('Link it'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(joined, 1);
    });

    testWidgets('one item from another device hides it', (tester) async {
      final repo = _NoticeRepo();
      await pad(repo, count: 3);
      await pad(repo, count: 1, device: 'someones-phone');
      final devices = ValueNotifier<int?>(1);
      addTearDown(devices.dispose);
      await pump(tester, repo, devices: devices);
      expect(find.text(notice), findsNothing);
    });

    testWidgets('a second device hides it', (tester) async {
      final repo = _NoticeRepo();
      await pad(repo, count: 3);
      final devices = ValueNotifier<int?>(2);
      addTearDown(devices.dispose);
      await pump(tester, repo, devices: devices);
      expect(find.text(notice), findsNothing);
    });

    testWidgets('an unknown device label hides it', (tester) async {
      final repo = _NoticeRepo();
      await pad(repo, count: 3);
      final devices = ValueNotifier<int?>(1);
      addTearDown(devices.dispose);
      await pump(tester, repo, devices: devices, label: null);
      expect(find.text(notice), findsNothing);
    });
  });

  group('the nudge on screen', () {
    testWidgets('fires once the vault is worth carrying', (tester) async {
      final repo = _NoticeRepo();
      await pad(repo);
      final devices = ValueNotifier<int?>(1);
      addTearDown(devices.dispose);
      var added = 0;
      await pump(tester, repo,
          devices: devices, onAddDevice: () => added++);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text(nudge), findsOneWidget);
      expect(repo.nudgeShown, isTrue);
      await tester.tap(find.text('Add a device'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(added, 1);
      await tester.pump(const Duration(seconds: 9)); // let the toast go
    });

    testWidgets('a second device keeps it quiet', (tester) async {
      final repo = _NoticeRepo();
      await pad(repo);
      final devices = ValueNotifier<int?>(2);
      addTearDown(devices.dispose);
      await pump(tester, repo, devices: devices);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(nudge), findsNothing);
      expect(repo.nudgeShown, isFalse);
    });

    testWidgets('a short list keeps it quiet', (tester) async {
      final repo = _NoticeRepo();
      await pad(repo, count: addPhoneNudgeThreshold - 1);
      final devices = ValueNotifier<int?>(1);
      addTearDown(devices.dispose);
      await pump(tester, repo, devices: devices);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(nudge), findsNothing);
      expect(repo.nudgeShown, isFalse);
    });

    testWidgets('the keep hint goes first, and alone', (tester) async {
      final repo = _NoticeRepo()
        ..keepShown = false
        ..vaultCount = 0;
      await pad(repo);
      final devices = ValueNotifier<int?>(1);
      addTearDown(devices.dispose);
      await pump(tester, repo, devices: devices);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('Nothing kept yet'), findsOneWidget);
      expect(find.text(nudge), findsNothing);
      expect(repo.nudgeShown, isFalse);
      await tester.pump(const Duration(seconds: 9)); // let the toast go
    });

    testWidgets('a late device count still gets its chance', (tester) async {
      final repo = _NoticeRepo();
      await pad(repo);
      final devices = ValueNotifier<int?>(null);
      addTearDown(devices.dispose);
      await pump(tester, repo, devices: devices);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(nudge), findsNothing);

      devices.value = 1;
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(nudge), findsOneWidget);
      await tester.pump(const Duration(seconds: 9)); // let the toast go
    });
  });
}

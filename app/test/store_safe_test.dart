// Store-safe (App Store 3.1.1 / 3.1.3(b)) gating: iOS builds must render no
// upgrade affordance and no purchase-steering copy anywhere. These tests pin
// the pieces that are testable off-device; the mobile settings sheet's PLAN
// block and snackbar copy are gated on the same [storeSafeBuild] predicate.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/device_directory.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/onboarding/add_device.dart';
import 'package:relic_app/platform/store_safe.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';

/// Words that must never render in a store-safe build's copy.
final _steering = RegExp(r'upgrade|pro\b|\bmax\b|price|\$', caseSensitive: false);

void main() {
  tearDown(() => debugStoreSafeOverride = null);

  group('storeSafeBuild', () {
    test('is false on the host platform and overridable for tests', () {
      expect(storeSafeBuild, isFalse); // tests run on desktop, not iOS
      debugStoreSafeOverride = true;
      expect(storeSafeBuild, isTrue);
    });
  });

  group('syncRejectionHint', () {
    test('store-safe hints carry no upgrade language for any status', () {
      for (final status in [0, 400, 402, 403, 409, 413]) {
        final hint = syncRejectionHint(status, storeSafe: true);
        if (hint != null) {
          expect(hint, isNot(matches(_steering)),
              reason: 'status $status: "$hint"');
        }
      }
    });

    test('store-safe hints still tell the user something actionable', () {
      expect(syncRejectionHint(402, storeSafe: true), isNotNull);
      expect(syncRejectionHint(413, storeSafe: true), isNotNull);
    });

    test('default (non-store-safe) copy is unchanged', () {
      expect(syncRejectionHint(402), 'Free up space or upgrade, then retry.');
      expect(syncRejectionHint(413),
          'Upgrade your plan to sync items this large.');
    });
  });

  group('device-cap dialog', () {
    final dir = DeviceDirectory(
        baseUrl: 'http://unused.invalid', bearer: () async => null, deviceId: 'd');
    const devices = [
      DeviceEntry(deviceId: 'a', label: 'Desktop', platform: 'windows'),
      DeviceEntry(deviceId: 'b', label: 'Phone', platform: 'android'),
    ];

    Future<void> pumpCapDialog(WidgetTester tester,
        {Future<void> Function()? onUpgrade, String upgradeLabel = ''}) async {
      await tester.pumpWidget(RelicTheme(
        colors: RelicColors.dark,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDeviceCapDialog(context,
                  directory: dir,
                  devices: devices,
                  label: 'iPhone',
                  platform: 'ios',
                  onUpgrade: onUpgrade,
                  upgradeLabel: upgradeLabel),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('renders no upgrade affordance when onUpgrade is null',
        (tester) async {
      await pumpCapDialog(tester, onUpgrade: null);
      expect(find.text('Device limit reached'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.textContaining(_steering, findRichText: true), findsNothing);
    });

    testWidgets('keeps the upgrade action for non-store-safe callers',
        (tester) async {
      await pumpCapDialog(tester,
          onUpgrade: () async {}, upgradeLabel: 'Upgrade');
      expect(find.widgetWithText(OutlinedButton, 'Upgrade'), findsOneWidget);
      expect(find.textContaining('or upgrade your plan'), findsOneWidget);
    });
  });
}

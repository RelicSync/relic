import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show FontLoader, MissingPluginException, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/recovery.dart';
import 'package:relic_app/onboarding/add_device.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';

/// Renders the settings drill-down screens (Devices, Security, Recovery kit)
/// at the desktop settings-window size (780x600 logical) so their sizing and
/// styling can be reviewed the same way as the gallery surfaces. Same MPO
/// rationale as screenshot_harness_test.dart: rasterize, don't window-capture.
///
///   `RELIC_SHOT_DIR=<dir> flutter test test/drilldown_screenshot_harness_test.dart`
void main() {
  final outDir = Platform.environment['RELIC_SHOT_DIR'];

  testWidgets('render settings drill-downs to PNGs', (tester) async {
    if (outDir == null || outDir.isEmpty) {
      markTestSkipped('RELIC_SHOT_DIR not set');
      return;
    }
    Directory(outDir).createSync(recursive: true);

    await tester.runAsync(() async {
      Future<void> load(String family, List<String> assets) async {
        final loader = FontLoader(family);
        for (final a in assets) {
          loader.addFont(rootBundle.load(a));
        }
        await loader.load();
      }

      await load('IBMPlexSans', ['assets/fonts/IBMPlexSans.ttf']);
      await load('IBMPlexMono', [
        'assets/fonts/IBMPlexMono-Regular.ttf',
        'assets/fonts/IBMPlexMono-Medium.ttf',
        'assets/fonts/IBMPlexMono-SemiBold.ttf',
        'assets/fonts/IBMPlexMono-Bold.ttf',
      ]);
      await load('packages/lucide_icons_flutter/Lucide',
          ['packages/lucide_icons_flutter/assets/lucide.ttf']);
      // These screens still use Material icons; load the real glyphs so the
      // review shots show what ships instead of tofu boxes.
      final mi = File(
          'C:/src/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf');
      if (mi.existsSync()) {
        final bytes = mi.readAsBytesSync();
        final loader = FontLoader('MaterialIcons')
          ..addFont(Future.value(ByteData.view(bytes.buffer)));
        await loader.load();
      }
    });

    debugDisableShadows = false;
    // Desktop settings window: 780x600 logical (desktop.dart _sizeWindow).
    tester.view.physicalSize = const Size(1560, 1200);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final mk = Uint8List.fromList(List.generate(32, (i) => i * 7 % 251));
    final kit = RecoveryKit.fromMk(mk, 'jordan@example.com');

    Widget host(RelicColors c, Widget screen, {bool mobile = false}) =>
        MaterialApp(
          debugShowCheckedModeBanner: false,
          builder: (context, child) => RelicTheme(
              colors: c,
              isMobile: mobile,
              child: child ?? const SizedBox.shrink()),
          home: RelicTheme(
            colors: c,
            isMobile: mobile,
            child: Material(color: c.base, child: screen),
          ),
        );

    const key = ValueKey('shot-root');
    Future<void> shot(String name, RelicColors c, Widget screen,
        {Future<void> Function()? interact, bool mobile = false}) async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: KeyedSubtree(
            key: ValueKey(name),
            child: host(c, screen, mobile: mobile),
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      // Let real async work (device-list fetch failures, PackageInfo) settle.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      if (interact != null) {
        await interact();
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 80));
        }
      }
      final e = tester.takeException();
      if (e != null && e is! MissingPluginException) {
        debugDisableShadows = true;
        throw e;
      }
      final boundary =
          tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File('$outDir/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      });
    }

    for (final dark in [true, false]) {
      final c = dark ? RelicColors.dark : RelicColors.light;
      final suffix = dark ? 'dark' : 'light';

      await shot(
        'drill-security-$suffix',
        c,
        SecurityScreen(
          masterKey: mk,
          accountEmail: 'jordan@example.com',
          onChangePassphrase: (_) async {},
          onChangeEmail: (_) async {},
          onSignOutEverywhere: () async {},
          onDisconnect: () {},
          onDeleteAccount: () async {},
        ),
      );

      await shot(
        'drill-security-passphrase-$suffix',
        c,
        SecurityScreen(
          masterKey: mk,
          accountEmail: 'jordan@example.com',
          onChangePassphrase: (_) async {},
          onChangeEmail: (_) async {},
          onSignOutEverywhere: () async {},
          onDisconnect: () {},
          onDeleteAccount: () async {},
        ),
        interact: () => tester.tap(find.text('Change vault passphrase')),
      );

      await shot(
        'drill-recovery-kit-$suffix',
        c,
        RecoveryKitScreen(kitText: kit, requireProof: false),
      );

      await shot(
        'drill-devices-$suffix',
        c,
        DevicesScreen(bearer: () async => null, masterKey: mk),
      );

      // Post-connect first-save flow: proof quiz enabled, shown in the
      // smaller 520x620 window desktop.dart sizes for the recovery kit.
      tester.view.physicalSize = const Size(1040, 1240);
      await shot(
        'drill-recovery-kit-proof-520-$suffix',
        c,
        RecoveryKitScreen(kitText: kit),
      );
      tester.view.physicalSize = const Size(1560, 1200);
    }

    // Phones share the restyled bodies inside the Scaffold hosting: render a
    // pair at phone metrics (360x760 logical) to catch mobile regressions.
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 3.0;
    await shot(
      'drill-security-mobile-dark',
      RelicColors.dark,
      SecurityScreen(
        masterKey: mk,
        accountEmail: 'jordan@example.com',
        onChangePassphrase: (_) async {},
        onChangeEmail: (_) async {},
        onSignOutEverywhere: () async {},
        onDisconnect: () {},
        onDeleteAccount: () async {},
      ),
      mobile: true,
    );
    await shot(
      'drill-recovery-kit-mobile-dark',
      RelicColors.dark,
      RecoveryKitScreen(kitText: kit, requireProof: false),
      mobile: true,
    );

    debugDisableShadows = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(days: 3));
  });
}

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show FontLoader, MissingPluginException, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/repo.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/ui/phone_expectation.dart';
import 'package:relic_app/ui/popup.dart';

/// Renders the sync onboarding surfaces to PNGs for design review: the phone
/// first-run screen, the phone list with the sync card above it, and the
/// desktop list with its card. Same technique as
/// mobile_screenshot_harness_test.dart; skipped unless RELIC_SHOT_DIR is set.
///
///   `RELIC_SHOT_DIR=<dir> flutter test test/sync_nudge_screenshot_test.dart`
void main() {
  final outDir = Platform.environment['RELIC_SHOT_DIR'];

  testWidgets('render the sync onboarding surfaces to PNGs', (tester) async {
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

      await load('StackSansHeadline', ['assets/fonts/StackSansHeadline.ttf']);
      await load('StackSansText', ['assets/fonts/StackSansText.ttf']);
      await load('JetBrainsMono', ['assets/fonts/JetBrainsMono.ttf']);
      await load('IBMPlexSans', ['assets/fonts/IBMPlexSans.ttf']);
      await load('IBMPlexMono', [
        'assets/fonts/IBMPlexMono-Regular.ttf',
        'assets/fonts/IBMPlexMono-Medium.ttf',
        'assets/fonts/IBMPlexMono-SemiBold.ttf',
        'assets/fonts/IBMPlexMono-Bold.ttf',
      ]);
      await load('packages/lucide_icons_flutter/Lucide',
          ['packages/lucide_icons_flutter/assets/lucide.ttf']);
    });

    debugDisableShadows = false;
    addTearDown(tester.view.reset);
    const key = ValueKey('shot-root');

    final emptyPhone = _ShotRepo();
    final fullPhone = _ShotRepo();
    final desk = _ShotRepo();
    await tester.runAsync(() async {
      await _pad(fullPhone, 6, device: 'Pixel');
      await _pad(desk, 9, device: 'DESKTOP-PC');
    });

    final shots = <String, ({Size size, bool mobile, Widget Function() build})>{
      'phoneFirstRun': (
        size: const Size(1080, 2280),
        mobile: true,
        build: () => PhoneExpectationScreen(
              onSendDownloadLink: () async {},
              onContinue: () {},
            ),
      ),
      'phoneListEmptyWithCard': (
        size: const Size(1080, 2280),
        mobile: true,
        build: () => PopupView(
              repo: emptyPhone,
              onClose: () {},
              onSettings: () {},
              deviceCount: ValueNotifier<int?>(1),
              onSendDownloadLink: () async {},
              onNewNote: () {},
              onShareHelp: () {},
            ),
      ),
      'phoneListWithCard': (
        size: const Size(1080, 2280),
        mobile: true,
        build: () => PopupView(
              repo: fullPhone,
              onClose: () {},
              onSettings: () {},
              deviceCount: ValueNotifier<int?>(1),
              onSendDownloadLink: () async {},
              onNewNote: () {},
              onShareHelp: () {},
            ),
      ),
      'desktopListWithCard': (
        size: const Size(1040, 1240),
        mobile: false,
        build: () => PopupView(
              repo: desk,
              onClose: () {},
              onSettings: () {},
              deviceCount: ValueNotifier<int?>(1),
              onAddDevice: () {},
            ),
      ),
    };

    for (final dark in [false, true]) {
      final c = dark ? RelicColors.dark : RelicColors.light;
      for (final entry in shots.entries) {
        final shot = entry.value;
        tester.view.physicalSize = shot.size;
        tester.view.devicePixelRatio = shot.mobile ? 3.0 : 2.0;
        await tester.pumpWidget(MaterialApp(
          key: ValueKey('${entry.key}-$dark'),
          debugShowCheckedModeBanner: false,
          home: RelicTheme(
            colors: c,
            isMobile: shot.mobile,
            child: RepaintBoundary(
              key: key,
              child: Scaffold(backgroundColor: c.base, body: shot.build()),
            ),
          ),
        ));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 120));
        }
        final e = tester.takeException();
        if (e != null && e is! MissingPluginException) {
          debugDisableShadows = true;
          throw e;
        }
        final boundary =
            tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2.0);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          final name = '${entry.key}-${dark ? 'dark' : 'light'}.png';
          await File('$outDir/$name').writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
    }
    debugDisableShadows = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(days: 3));
  });
}

/// A connected one-device account that has never put the card off.
class _ShotRepo extends MemoryRepo {
  @override
  int get syncNudgeSnoozedUntil => 0;
  @override
  AccountInfo? get account => AccountInfo(
        tier: 'Free',
        usedBytes: 1200000,
        quotaBytes: 262144000,
        vaultCount: 0,
        vaultCap: 100,
      );
}

Future<void> _pad(MemoryRepo repo, int count, {required String device}) async {
  const samples = [
    'Meeting moved to 3pm, room 4B',
    'https://github.com/RelicSync/relic/pull/57',
    'Order #48213 arrives Thursday',
    'const walk = PullWalk(since: 0);',
    'Gate code 7741#',
    'Flight BA 117, seat 14A, 7 Oct',
    'Pick up dry cleaning before 6',
    'Invoice INV-2026-0192 paid',
    'Call the dentist about the Tuesday slot',
  ];
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  for (var i = 0; i < count; i++) {
    await repo.restore(Relic(
      uid: 'shot$i',
      createdAt: now - 900 * (i + 1),
      updatedAt: now - 900 * (i + 1),
      kind: Kind.string,
      source: Source.clipboard,
      promoted: i == 1 || i == 4,
      byteSize: 24,
      device: device,
      content: samples[i % samples.length],
    ));
  }
}

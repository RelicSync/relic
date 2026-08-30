import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show FontLoader, MissingPluginException, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/main.dart';

/// Renders every gallery surface in both palettes to PNGs for design review.
/// Skipped unless RELIC_SHOT_DIR is set: the window-capture route can't see
/// Flutter's swapchain on machines where it lands in a hardware overlay plane
/// (MPO), so review screenshots are rasterized here instead, exactly like
/// golden tests.
///
///   `RELIC_SHOT_DIR=<dir> flutter test test/screenshot_harness_test.dart`
void main() {
  final outDir = Platform.environment['RELIC_SHOT_DIR'];

  testWidgets('render gallery surfaces to PNGs', (tester) async {
    if (outDir == null || outDir.isEmpty) {
      markTestSkipped('RELIC_SHOT_DIR not set');
      return;
    }
    Directory(outDir).createSync(recursive: true);

    // Real fonts: flutter_test does not load the app's fonts by itself, so
    // text would rasterize as solid boxes. Load IBM Plex + the Lucide icon
    // font from the asset bundle under the exact families the app uses.
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

    // Real shadows in the shots (flutter_test disables them for goldens).
    // Restored inline below: the binding's invariant check runs before
    // addTearDown callbacks, so a teardown reset still fails the test.
    debugDisableShadows = false;
    tester.view.physicalSize = const Size(2912, 1760);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    const key = ValueKey('shot-root');
    for (final dark in [true, false]) {
      for (final surface in Surface.values) {
        if (surface == Surface.connect) continue; // live-data surface
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: GalleryApp(
              // Unique key per shot: initialSurface/initialDark seed State
              // once, so a reused element would keep the first shot's config.
              key: ValueKey('${surface.name}-$dark'),
              initialSurface: surface,
              initialDark: dark,
            ),
          ),
        );
        // Let MemoryRepo load + FutureBuilders resolve; avoid pumpAndSettle
        // (long-lived toast timers never settle).
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 120));
        }
        // Image decoding is real async work that fake-async pumps never
        // deliver — give it a real event-loop window, then pump the frames
        // in which the decoded image paints.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        // The popup rows try to initialize the native drag plugin, which has
        // no implementation under flutter_test. Swallow just that.
        final e = tester.takeException();
        if (e != null && e is! MissingPluginException) {
          debugDisableShadows = true;
          throw e;
        }

        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(key),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          final name = '${surface.name}-${dark ? 'dark' : 'light'}.png';
          await File('$outDir/$name').writeAsBytes(
            bytes!.buffer.asUint8List(),
          );
        });
      }
    }
    debugDisableShadows = true;
    // The toasts surfaces enqueue day-long dismiss timers; advance fake time
    // so none are pending when the binding checks invariants.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(days: 3));
  });
}

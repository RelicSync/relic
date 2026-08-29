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
import 'package:relic_app/ui/dialogs.dart';
import 'package:relic_app/ui/popup.dart';

import 'shot_seed.dart';

/// Play-store screenshot harness: renders the mobile lens with REALISTIC demo
/// content at 3x pixel ratio (raw PNGs 1080x2280 phone / 1440x3039 tablet).
/// Same technique as mobile_screenshot_harness_test.dart (adb captures come
/// back black on Android); skipped unless RELIC_SHOT_DIR is set.
///
///   `RELIC_SHOT_DIR=<dir> flutter test test/store_screenshot_harness_test.dart`
void main() {
  final outDir = Platform.environment['RELIC_SHOT_DIR'];
  final webOutDir = Platform.environment['RELIC_WEB_SHOT_DIR'];

  testWidgets('render store screenshots to PNGs', (tester) async {
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
    });

    debugDisableShadows = false;
    addTearDown(tester.view.reset);

    final repo = StoreShotRepo();
    // Separate repo for the App Store secret shot: the extra secret item
    // must never leak into the other shots' seed (same rule as the website
    // pass below).
    final secretRepo = StoreShotRepo(includeSecret: true);
    await tester.runAsync(() async {
      await repo.preparePhoto();
      await repo.load();
      await secretRepo.preparePhoto();
      await secretRepo.load();
    });

    Relic pick(bool Function(Relic) test) => repo.all.firstWhere(test);
    final textRelic = pick((r) => r.uid == 'ein');
    final photoRelic = pick((r) => r.kind == Kind.photo);

    const key = ValueKey('store-shot-root');

    Future<void> renderShot({
      required String name,
      required RelicColors c,
      required Widget Function(RelicColors c) build,
      required Size physical,
      double dpr = 3.0,
      Future<void> Function()? interact,
    }) async {
      tester.view.physicalSize = physical;
      tester.view.devicePixelRatio = dpr;

      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey('store-$name'),
          debugShowCheckedModeBanner: false,
          home: RelicTheme(
            colors: c,
            isMobile: true,
            child: RepaintBoundary(
              key: key,
              child: Scaffold(
                backgroundColor: c.base,
                body: build(c),
              ),
            ),
          ),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 120));
        }
        // Real event-loop windows so Image.file decodes (fake async never
        // delivers it), then paint the decoded frames. Two rounds: the store
        // photo is 900x1260 and one 80ms window can miss the decode.
        for (var round = 0; round < 2; round++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 250)),
          );
          for (var i = 0; i < 3; i++) {
            await tester.pump(const Duration(milliseconds: 60));
          }
        }
      }

      await settle();
      if (interact != null) {
        await interact();
        await settle();
      }
      final e = tester.takeException();
      if (e != null && e is! MissingPluginException) {
        debugDisableShadows = true;
        throw e;
      }

      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(key),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: dpr);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File('$outDir/$name.png').writeAsBytes(
          bytes!.buffer.asUint8List(),
        );
      });
    }

    // Phone: 360x760 logical @3x -> 1080x2280 raw.
    const phone = Size(1080, 2280);
    // Tablet-proportioned pass: 480x1013 logical @3x -> 1440x3039 raw.
    const tablet = Size(1440, 3039);
    // Apple App Store required sets (docs/apple-port-2026-08.md §3c.1) — App
    // Store Connect scales every smaller device down from these two:
    // 6.9" iPhone: 440x956 logical @3x -> 1320x2868 raw.
    const iphone69 = Size(1320, 2868);
    // 13" iPad portrait: 1032x1376 logical @2x -> 2064x2752 raw.
    const ipad13 = Size(2064, 2752);

    Widget popup(RelicColors c) =>
        PopupView(repo: repo, onClose: () {}, onSettings: () {});
    Widget secretPopup(RelicColors c) =>
        PopupView(repo: secretRepo, onClose: () {}, onSettings: () {});

    // Warm-up render (discarded): primes the image cache so the photo row's
    // thumbnail is decoded by the time the first kept shot paints.
    await renderShot(
      name: 'warmup-discard',
      c: RelicColors.dark,
      build: popup,
      physical: phone,
    );
    File('$outDir/warmup-discard.png').deleteSync();

    // 1. Main timeline, dark (hero) + light.
    await renderShot(
      name: 'popup-dark',
      c: RelicColors.dark,
      build: popup,
      physical: phone,
    );
    await renderShot(
      name: 'popup-light',
      c: RelicColors.light,
      build: popup,
      physical: phone,
    );

    // 2. Search active (dark). Type into the search field; the popup's 140ms
    // debounce is covered by the settle() pumps.
    await renderShot(
      name: 'popup-search-dark',
      c: RelicColors.dark,
      build: popup,
      physical: phone,
      interact: () async {
        await tester.enterText(find.byType(TextField).first, 'business');
        await tester.pump(const Duration(milliseconds: 200));
      },
    );

    // 3. Edit dialog on a text relic with title/note/tags (dark).
    await renderShot(
      name: 'edit-text-dark',
      c: RelicColors.dark,
      build: (c) => _dialogHost(
        c,
        EditDialog(
          relic: textRelic,
          repo: repo,
          onCancel: () {},
          onCopy: () {},
          onDelete: () {},
          onShare: () {},
          onSave: (t, n, u, m, c2, a, rm) async {},
        ),
      ),
      physical: phone,
    );

    // 4. Edit dialog on the photo relic (dark).
    await renderShot(
      name: 'edit-image-dark',
      c: RelicColors.dark,
      build: (c) => _dialogHost(
        c,
        EditDialog(
          relic: photoRelic,
          repo: repo,
          onCancel: () {},
          onCopy: () {},
          onDelete: () {},
          onShare: () {},
          onSave: (t, n, u, m, c2, a, rm) async {},
        ),
      ),
      physical: phone,
    );

    // 5. Tablet-proportioned timeline (dark) — dropped later if it looks off.
    await renderShot(
      name: 'popup-dark-tablet',
      c: RelicColors.dark,
      build: popup,
      physical: tablet,
    );

    // 6. App Store set, 6.9" iPhone: hero + light + search, mirroring the
    // Play set above.
    await renderShot(
      name: 'appstore-popup-dark',
      c: RelicColors.dark,
      build: popup,
      physical: iphone69,
    );
    await renderShot(
      name: 'appstore-popup-light',
      c: RelicColors.light,
      build: popup,
      physical: iphone69,
    );
    await renderShot(
      name: 'appstore-search-dark',
      c: RelicColors.dark,
      build: popup,
      physical: iphone69,
      interact: () async {
        await tester.enterText(find.byType(TextField).first, 'business');
        await tester.pump(const Duration(milliseconds: 200));
      },
    );
    await renderShot(
      name: 'appstore-edit-text-dark',
      c: RelicColors.dark,
      build: (c) => _dialogHost(
        c,
        EditDialog(
          relic: textRelic,
          repo: repo,
          onCancel: () {},
          onCopy: () {},
          onDelete: () {},
          onShare: () {},
          onSave: (t, n, u, m, c2, a, rm) async {},
        ),
      ),
      physical: iphone69,
    );

    // 6b. Masked secret row (separate seed): the E2EE story shot for the
    // App Store set — dotted mask + Secret badge in the timeline.
    await renderShot(
      name: 'appstore-secret-dark',
      c: RelicColors.dark,
      build: secretPopup,
      physical: iphone69,
    );

    // 7. App Store set, 13" iPad: search active AND a relic open in the
    // detail pane, so both panes carry content (a bare two-pane timeline
    // read empty at 13").
    await renderShot(
      name: 'appstore-popup-dark-ipad13',
      c: RelicColors.dark,
      build: popup,
      physical: ipad13,
      dpr: 2.0,
      interact: () async {
        await tester.enterText(find.byType(TextField).first, 'business');
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(find.text('EIN').first);
        await tester.pump(const Duration(milliseconds: 200));
      },
    );

    debugDisableShadows = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(days: 3));
  });

  /// Website screenshot pass: the DESKTOP popup (RelicTheme isMobile: false)
  /// at the app's real "Standard" popup footprint — 520x680 logical, from
  /// PopupSize.standard in lib/data/local_desk_repo.dart — rendered at 2x
  /// (desktop is a 2x surface) so raws are 1040x1360. A separate env var keeps
  /// this pass' output apart from the Play-store raws above:
  ///
  ///   `RELIC_WEB_SHOT_DIR=<dir> flutter test test/store_screenshot_harness_test.dart`
  ///
  /// Both passes run when both env vars are set.
  testWidgets('render website desktop screenshots to PNGs', (tester) async {
    if (webOutDir == null || webOutDir.isEmpty) {
      markTestSkipped('RELIC_WEB_SHOT_DIR not set');
      return;
    }
    Directory(webOutDir).createSync(recursive: true);

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
    });

    debugDisableShadows = false;
    addTearDown(tester.view.reset);

    // Same business seed as the Play pass.
    final repo = StoreShotRepo();
    // SEPARATE repo for the masked shots: the extra secret item must never
    // leak into the mobile/Play seed.
    final secretRepo = StoreShotRepo(includeSecret: true);
    await tester.runAsync(() async {
      await repo.preparePhoto();
      await repo.load();
      await secretRepo.preparePhoto();
      await secretRepo.load();
    });

    const key = ValueKey('web-shot-root');

    Future<void> renderShot({
      required String name,
      required RelicColors c,
      required RelicRepo shotRepo,
      Future<void> Function()? interact,
    }) async {
      // PopupSize.standard (520x680) at 2x.
      tester.view.physicalSize = const Size(1040, 1360);
      tester.view.devicePixelRatio = 2.0;

      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey('web-$name'),
          debugShowCheckedModeBanner: false,
          home: RelicTheme(
            colors: c,
            isMobile: false,
            child: RepaintBoundary(
              key: key,
              child: Scaffold(
                backgroundColor: c.base,
                body: PopupView(
                  repo: shotRepo,
                  onClose: () {},
                  onSettings: () {},
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 120));
        }
        // Real event-loop windows so Image.file decodes (fake async never
        // delivers it), then paint the decoded frames — same dance as the
        // Play pass above.
        for (var round = 0; round < 2; round++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 250)),
          );
          for (var i = 0; i < 3; i++) {
            await tester.pump(const Duration(milliseconds: 60));
          }
        }
      }

      await settle();
      if (interact != null) {
        await interact();
        await settle();
      }
      final e = tester.takeException();
      if (e != null && e is! MissingPluginException) {
        debugDisableShadows = true;
        throw e;
      }

      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(key),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2.0);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File('$webOutDir/$name.png').writeAsBytes(
          bytes!.buffer.asUint8List(),
        );
      });
    }

    // Warm-up render (discarded): primes the image cache for the receipt
    // photo thumbnail before the first kept shot paints.
    await renderShot(name: 'warmup-discard', c: RelicColors.dark, shotRepo: repo);
    File('$webOutDir/warmup-discard.png').deleteSync();

    // 1. Desktop popup, dark, no search.
    await renderShot(name: 'desktop-popup-dark', c: RelicColors.dark, shotRepo: repo);

    // 2. Search active: 'office chair' surfaces the receipt-image row (both
    // terms live in the photo relic's title, see filterRelics in repo.dart).
    await renderShot(
      name: 'desktop-search-dark',
      c: RelicColors.dark,
      shotRepo: repo,
      interact: () async {
        await tester.enterText(find.byType(TextField).first, 'office chair');
        await tester.pump(const Duration(milliseconds: 200));
      },
    );

    // 3. Masked secret row (separate seed). Relic.isSecret is driven by the
    // machine tag 'secret' (models/relic.dart), which makes the row render
    // the dotted mask + key tile + Secret badge (widgets/result_row.dart).
    await renderShot(
      name: 'desktop-masked-dark',
      c: RelicColors.dark,
      shotRepo: secretRepo,
    );

    // 3b. Revealed state: double-tap the masked row (result_row.dart's manual
    // 350ms double-tap window) to open the unified edit screen, then hit its
    // Reveal control so the plaintext well shows.
    await renderShot(
      name: 'desktop-masked-revealed',
      c: RelicColors.dark,
      shotRepo: secretRepo,
      interact: () async {
        final row = find.text('•••• •••• •••• ••••');
        await tester.tap(row);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(row);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('Reveal'));
        await tester.pump(const Duration(milliseconds: 120));
      },
    );

    // 4. Light theme (site nice-to-have).
    await renderShot(name: 'desktop-light', c: RelicColors.light, shotRepo: repo);

    // 5. Vault scope: only the keepers. Framed in browser chrome by
    // compose_web_shots.py to stand in for the web vault gallery slot.
    await renderShot(
      name: 'desktop-vault-dark',
      c: RelicColors.dark,
      shotRepo: repo,
      interact: () async {
        await tester.tap(find.text('Vault'));
        await tester.pump(const Duration(milliseconds: 200));
      },
    );

    debugDisableShadows = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(days: 3));
  });
}

/// Mirrors the in-app dialog overlay (same as the mobile design harness).
Widget _dialogHost(RelicColors c, Widget dialog) => Container(
      color: c.base,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(14),
      child: dialog,
    );

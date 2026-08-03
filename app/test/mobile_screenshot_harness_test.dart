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

/// Renders the MOBILE lens (RelicTheme isMobile: true) at phone proportions to
/// PNGs for design review — the Android build can't be screenshotted over adb
/// (Impeller SurfaceView captures black). Same technique as
/// screenshot_harness_test.dart; skipped unless RELIC_SHOT_DIR is set.
///
///   `RELIC_SHOT_DIR=<dir> flutter test test/mobile_screenshot_harness_test.dart`
void main() {
  final outDir = Platform.environment['RELIC_SHOT_DIR'];

  testWidgets('render mobile surfaces to PNGs', (tester) async {
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

    // Phone-sized viewport (S21-class): 360 x 760 logical.
    debugDisableShadows = false;
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final repo = _MobileShotRepo();
    await tester.runAsync(repo.load);

    Relic pick(bool Function(Relic) test) => repo.all.firstWhere(test);
    final textRelic =
        pick((r) => r.kind == Kind.string && (r.content ?? '').isNotEmpty);
    final photoRelic = pick((r) => r.kind == Kind.photo);

    const key = ValueKey('mobile-shot-root');
    final shots = <String, Widget Function(RelicColors c)>{
      'mobilePopup': (c) => PopupView(repo: repo, onClose: () {}, onSettings: () {}),
      'mobileEdit': (c) => _dialogHost(c, EditDialog(
            relic: textRelic,
            repo: repo,
            onCancel: () {},
            onCopy: () {},
            onDelete: () {},
            onShare: () {},
            onSave: (t, n, u, m, c2, a, rm) async {},
          )),
      'mobileEditImage': (c) => _dialogHost(c, EditDialog(
            relic: photoRelic,
            repo: repo,
            onCancel: () {},
            onCopy: () {},
            onDelete: () {},
            onShare: () {},
            onSave: (t, n, u, m, c2, a, rm) async {},
          )),
    };

    for (final dark in [true, false]) {
      final c = dark ? RelicColors.dark : RelicColors.light;
      for (final entry in shots.entries) {
        await tester.pumpWidget(
          // Plain MaterialApp theme, matching the real mobile shell — the
          // dialogs' custom fields must not pick up an InputDecorationTheme.
          MaterialApp(
            key: ValueKey('${entry.key}-$dark'),
            debugShowCheckedModeBanner: false,
            home: RelicTheme(
              colors: c,
              isMobile: true,
              child: RepaintBoundary(
                key: key,
                child: Scaffold(
                  backgroundColor: c.base,
                  body: entry.value(c),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 120));
        }
        // Real event-loop window so Image.file decodes (fake async never
        // delivers it), then paint the decoded frames.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 60));
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
          final name = '${entry.key}-${dark ? 'dark' : 'light'}.png';
          await File('$outDir/$name').writeAsBytes(
            bytes!.buffer.asUint8List(),
          );
        });
      }
    }
    debugDisableShadows = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(days: 3));
  });
}

/// Mirrors the in-app dialog overlay: scrim over the base surface with the
/// dialog centered, so review shots match how the sheet actually presents.
Widget _dialogHost(RelicColors c, Widget dialog) => Container(
      color: c.base,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(14),
      child: dialog,
    );

/// MemoryRepo that serves a real decodable PNG for photo relics, written
/// synchronously (async IO never completes under the fake-async test zone).
class _MobileShotRepo extends MemoryRepo {
  String? _imagePath;

  @override
  String? localImagePath(Relic r) {
    if (r.kind != Kind.photo) return super.localImagePath(r);
    if (_imagePath == null) {
      try {
        final dir = Directory.systemTemp.createTempSync('relic_mshot_');
        final f = File('${dir.path}/preview.png');
        f.writeAsBytesSync(_kPngBytes);
        _imagePath = f.path;
      } catch (_) {}
    }
    return _imagePath;
  }
}

/// Minimal valid 8x8 RGB PNG (same bytes as the gallery fixture in main.dart).
const List<int> _kPngBytes = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x08,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x4B, 0x6D, 0x29, 0xDC,
  0x00, 0x00, 0x00, 0x11, 0x49, 0x44, 0x41, 0x54,
  0x78, 0xDA, 0x63, 0xD0, 0xF3, 0x8F, 0xC2, 0x8A,
  0x18, 0x86, 0x96, 0x04, 0x00, 0xF5, 0xF4, 0x35,
  0xC1, 0x01, 0x3B, 0x62, 0xFF,
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
  0xAE, 0x42, 0x60, 0x82,
];

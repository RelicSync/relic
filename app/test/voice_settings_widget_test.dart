import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/data/voice_controller.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/ui/voice_settings.dart';
import 'package:relic_app/widgets/controls.dart';

void main() {
  for (final colors in [RelicColors.light, RelicColors.dark]) {
    testWidgets(
      'Voice uses shared Settings controls in ${colors.isDark ? 'dark' : 'light'} mode',
      (tester) async {
        tester.view.physicalSize = const Size(640, 940);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repo = LocalDeskRepo();
        final voice = VoiceController(repo)
          ..ready = true
          ..enabled = true
          ..status = 'Ready'
          ..devices = [
            {'id': -1, 'name': 'System default microphone'},
            {'id': 1, 'name': 'USB microphone'},
          ]
          ..vocabulary = ['Claude'];
        final capture = GlobalKey();
        final scroll = ScrollController();
        final screenshots = Platform.environment['RELIC_VOICE_SCREENSHOTS'];
        if (screenshots != null) {
          await tester.runAsync(() async {
            for (final font in [
              'StackSansText',
              'StackSansHeadline',
              'JetBrainsMono',
            ]) {
              await (FontLoader(
                font,
              )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
            }
            await (FontLoader('packages/lucide_icons_flutter/Lucide')..addFont(
                  rootBundle.load(
                    'packages/lucide_icons_flutter/assets/lucide.ttf',
                  ),
                ))
                .load();
          });
        }
        await tester.pumpWidget(
          RelicTheme(
            colors: colors,
            child: MaterialApp(
              theme: materialThemeFor(colors),
              home: Scaffold(
                body: RepaintBoundary(
                  key: capture,
                  child: ColoredBox(
                    color: colors.base,
                    child: SingleChildScrollView(
                      controller: scroll,
                      padding: const EdgeInsets.all(24),
                      child: VoiceSettings(voice: voice),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SettingsToggle), findsNWidgets(3));
        expect(find.byType(SwitchListTile), findsNothing);
        final key = VoiceController.keyLabel;
        expect(find.text('$key shortcuts'), findsOneWidget);
        expect(find.textContaining('Hold $key to dictate.'), findsOneWidget);
        expect(find.text('PREFERRED SPELLING'), findsOneWidget);
        expect(find.text('WORD CORRECTIONS'), findsOneWidget);
        expect(find.text('Test microphone and transcription'), findsOneWidget);
        expect(find.textContaining('does not boost'), findsOneWidget);
        expect(tester.takeException(), isNull);
        Future<void> snapshot(String position) async {
          if (screenshots == null) return;
          await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              '$screenshots/voice-settings-${colors.isDark ? 'dark' : 'light'}-$position.png',
            ).writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }

        await snapshot('top');
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        await snapshot('bottom');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        scroll.dispose();
        voice.dispose();
        repo.dispose();
      },
    );
  }
}

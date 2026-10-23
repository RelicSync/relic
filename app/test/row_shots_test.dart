import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show FontLoader, MissingPluginException, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/widgets/result_row.dart';

/// Renders the mini picker rows and the main list rows to PNGs for design
/// review: title over the start of the content, untitled rows as one line,
/// and secrets masked. Skipped unless RELIC_SHOT_DIR is set.
///
///   `RELIC_SHOT_DIR=<dir> flutter test test/row_shots_test.dart`
void main() {
  final outDir = Platform.environment['RELIC_SHOT_DIR'];

  Relic r(String uid, String content,
          {String? title,
          List<String> tags = const [],
          Kind kind = Kind.string,
          bool promoted = false,
          List<String> userTags = const [],
          int ago = 60}) =>
      Relic(
        uid: uid,
        createdAt: 1792770000 - ago,
        updatedAt: 1792770000 - ago,
        kind: kind,
        source: Source.clipboard,
        promoted: promoted,
        byteSize: content.length,
        device: 'Desktop',
        content: content,
        preview: content,
        title: title,
        tags: tags,
        userTags: userTags,
      );

  final items = [
    r('a', 'People who pair a phone in the first session keep using Relic about three times longer.',
        title: 'Onboarding drop-off note', tags: const ['note'], ago: 180),
    r('b', 'https://www.hyperresearch.ai/search?q=perplexity+alternatives',
        title: 'Hyperresearch alternative search link', tags: const ['url'], ago: 720),
    r('c', '  final top = pad + _selected * MiniResultRow.height;\n  final bottom = top + h;',
        title: 'Mini picker scroll offset math', tags: const ['code', 'dart'],
        userTags: const ['snippet'], ago: 1560),
    r('d', r'C:\Users\Jordan\PycharmProjects\relic\app\lib\ui\popup.dart',
        title: 'Relic popup source file path', tags: const ['path'], ago: 2460),
    r('e', 'Payouts  Oct 21  \$1,284.50 to account ending 4417  Paid',
        title: 'Stripe payouts dashboard', kind: Kind.photo,
        tags: const ['screenshot', 'finance'], ago: 3600),
    r('f', 'sk-proj-FvgMnOQn6vxXaCXvY2ro', title: 'OpenAI API key',
        tags: const ['secret'], promoted: true, ago: 5000),
    r('g', 'ssh jordan@10.0.0.14 -p 2222', tags: const ['code'], ago: 7000),
    r('h', 'Thanks, talk soon!', title: 'Thanks, talk soon', ago: 9000),
  ];

  testWidgets('render picker rows to PNGs', (tester) async {
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

    final shots = <String, ({Size size, bool mobile, Widget Function() build})>{
      'mini': (
        size: const Size(340, 7 * MiniResultRow.height + 8),
        mobile: false,
        build: () => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
              child: Column(children: [
                for (var i = 0; i < 7; i++)
                  MiniResultRow(
                    relic: items[i],
                    selected: i == 1,
                    imagePath: null,
                    onSelect: () {},
                    onActivate: () {},
                    onEdit: () {},
                  ),
              ]),
            ),
      ),
      'mini-search': (
        size: const Size(340, 2 * MiniResultRow.height + 8),
        mobile: false,
        build: () => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
              child: Column(children: [
                for (final it in [
                  items[1],
                  r('k', 'Kagi is great but slower and costs more. Perplexity Pro is \$20 and wins on speed.',
                      title: 'Competitor pricing notes'),
                ])
                  MiniResultRow(
                    relic: it,
                    selected: false,
                    imagePath: null,
                    onSelect: () {},
                    onActivate: () {},
                    query: 'perplexity',
                  ),
              ]),
            ),
      ),
      'main': (
        size: Size(520, 8 * ResultRow.heightFor(false) + 24),
        mobile: false,
        build: () => Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                for (var i = 0; i < items.length; i++)
                  ResultRow(
                    relic: items[i],
                    selected: i == 1,
                    nowSecs: 1792770000,
                    onSelect: () {},
                    onCopy: () {},
                    onPromoteToggle: () {},
                    onEdit: () {},
                    onDelete: () {},
                  ),
              ]),
            ),
      ),
      'phone': (
        size: Size(400, 4 * ResultRow.heightFor(true) + 24),
        mobile: true,
        build: () => Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                for (final i in [0, 1, 3, 6])
                  ResultRow(
                    relic: items[i],
                    selected: false,
                    nowSecs: 1792770000,
                    onSelect: () {},
                    onCopy: () {},
                    onPromoteToggle: () {},
                    onEdit: () {},
                    onDelete: () {},
                  ),
              ]),
            ),
      ),
    };

    for (final entry in shots.entries) {
      for (final dark in [false, true]) {
        final shot = entry.value;
        final c = dark ? RelicColors.dark : RelicColors.light;
        tester.view.physicalSize = shot.size * 2;
        tester.view.devicePixelRatio = 2.0;
        await tester.pumpWidget(MaterialApp(
          key: ValueKey('${entry.key}-$dark'),
          debugShowCheckedModeBanner: false,
          home: RelicTheme(
            colors: c,
            isMobile: shot.mobile,
            child: RepaintBoundary(
              key: key,
              child: Scaffold(
                  backgroundColor: shot.mobile ? c.base : c.surface,
                  body: shot.build()),
            ),
          ),
        ));
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 120));
        }
        final e = tester.takeException();
        if (e != null && e is! MissingPluginException) throw e;
        final boundary =
            tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2.0);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await File('$outDir/${entry.key}-${dark ? 'dark' : 'light'}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
    }
    debugDisableShadows = true;
  });
}

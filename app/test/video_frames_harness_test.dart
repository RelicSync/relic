import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show FontLoader, LogicalKeyboardKey, MissingPluginException, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relic_app/data/repo.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/ui/connect_dialog.dart';
import 'package:relic_app/ui/dialogs.dart';
import 'package:relic_app/ui/onboarding.dart';
import 'package:relic_app/ui/popup.dart';
import 'package:relic_app/ui/share_dialog.dart';
import 'package:relic_app/widgets/controls.dart';
import 'package:relic_app/widgets/gem_toast.dart';
import 'package:relic_app/widgets/relic_mark.dart';

import 'shot_seed.dart';

/// Demo-video frame harness: renders the REAL widgets as 60fps PNG frame
/// sequences, one directory per scene, for the marketing demo video
/// (marketing/demo-video/plan.md). Same rasterization route as the
/// screenshot harnesses (window capture is defeated by MPO); the difference
/// is that every scene pumps a fixed 1/fps timestep and captures every frame,
/// with scripted acts (typing, taps, flings) firing at set timestamps.
///
///   `RELIC_VIDEO_DIR=<dir>` flutter test test/video_frames_harness_test.dart
///
/// Knobs:
///   RELIC_VIDEO_FPS     frames per second (default 60)
///   RELIC_VIDEO_SCENES  comma-separated scene filter (default: all)
///
/// Output: `<dir>/<scene>/frame_00001.png` … plus `<dir>/<scene>/meta.txt` with
/// `"fps <n>"` and `"size <w>x<h>"` for the compositor.
void main() {
  final outRoot = Platform.environment['RELIC_VIDEO_DIR'];
  final fps =
      int.tryParse(Platform.environment['RELIC_VIDEO_FPS'] ?? '') ?? 60;
  final onlyScenes = (Platform.environment['RELIC_VIDEO_SCENES'] ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet();

  testWidgets('render demo-video frame sequences', (tester) async {
    if (outRoot == null || outRoot.isEmpty) {
      markTestSkipped('RELIC_VIDEO_DIR not set');
      return;
    }
    Directory(outRoot).createSync(recursive: true);

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

    // Local health endpoint so the connect scene's "Test" earns a real green
    // "Reachable." dot without touching the network. flutter_test installs a
    // mock HttpClient that 400s everything, so swap in overrides that proxy
    // every http request to this server — the dialog can then show the pretty
    // demo address while the real component's real check succeeds.
    HttpServer? health;
    await tester.runAsync(() async {
      health = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      health!.listen((req) {
        req.response.statusCode = 200;
        req.response.write('ok');
        req.response.close();
      });
    });
    HttpOverrides.global = _ProxyToLoopback(health!.port);
    addTearDown(() => HttpOverrides.global = null);
    const demoServerUrl = 'http://192.168.1.10:8787';

    final repo = StoreShotRepo(extended: true);
    // agedEin: the recall scene searches this repo for the EIN captured (in
    // story time) months earlier; the main repo omits it so the capture scene
    // can copy it in live.
    final secretRepo =
        StoreShotRepo(extended: true, includeSecret: true, agedEin: true);
    final phoneRepo = StoreShotRepo(extended: true);
    await tester.runAsync(() async {
      await repo.preparePhoto();
      await repo.load();
      await secretRepo.preparePhoto();
      await secretRepo.load();
      await phoneRepo.preparePhoto();
      await phoneRepo.load();
    });

    const rootKey = ValueKey('video-root');
    final frameDur = Duration(microseconds: 1000000 ~/ fps);
    final failures = <String, Object>{};

    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      for (var round = 0; round < 2; round++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
      }
    }

    /// Render [build] at [logical]x[dpr], run [acts] at their timestamps, and
    /// capture every frame from t=0 to [length] into <outRoot>/<name>/.
    Future<void> record({
      required String name,
      required Widget Function(RelicColors c) build,
      required Duration length,
      List<(Duration, Future<void> Function())> acts = const [],
      Size logical = const Size(520, 680),
      double dpr = 2.0,
      double capRatio = 2.0,
      bool isMobile = false,
      bool discard = false,
    }) async {
      if (!discard && onlyScenes.isNotEmpty && !onlyScenes.contains(name)) {
        return;
      }
      final dir = Directory('$outRoot/$name');
      if (!discard) {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        dir.createSync(recursive: true);
      }

      tester.view.physicalSize =
          Size(logical.width * dpr, logical.height * dpr);
      tester.view.devicePixelRatio = dpr;

      const c = RelicColors.dark;
      await tester.pumpWidget(
        RepaintBoundary(
          key: rootKey,
          child: MaterialApp(
            key: ValueKey('video-$name'),
            debugShowCheckedModeBanner: false,
            home: RelicTheme(
              colors: c,
              isMobile: isMobile,
              child: Scaffold(
                backgroundColor: c.base,
                body: build(c),
              ),
            ),
          ),
        ),
      );
      await settle();

      final pending = [...acts]..sort((a, b) => a.$1.compareTo(b.$1));
      var t = Duration.zero;
      var fi = 0;
      var sceneSize = '';
      try {
        while (t < length) {
          while (pending.isNotEmpty && pending.first.$1 <= t) {
            await pending.removeAt(0).$2();
          }
          await tester.pump(frameDur);
          t += frameDur;

          final e = tester.takeException();
          if (e != null && e is! MissingPluginException) {
            failures[name] = e;
            break;
          }
          if (discard) continue;

          fi++;
          final boundary =
              tester.renderObject<RenderRepaintBoundary>(find.byKey(rootKey));
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: capRatio);
            sceneSize = '${image.width}x${image.height}';
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            image.dispose();
            await File(
                    '${dir.path}/frame_${fi.toString().padLeft(5, '0')}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
          });
        }
      } finally {
        if (!discard && fi > 0) {
          File('${dir.path}/meta.txt')
              .writeAsStringSync('fps $fps\nsize $sceneSize\nframes $fi\n');
        }
        // Flush timers (toasts, debounces, cursor blink) so the next
        // pumpWidget starts clean and the test can end without pending-timer
        // failures.
        tester.takeException();
        await tester.pump(const Duration(days: 3));
        tester.takeException();
      }
      debugPrint('scene $name: $fi frames');
    }

    Widget popup(
      RelicRepo r, {
      ValueListenable<bool>? mini,
      Future<void> Function()? onRefresh,
    }) =>
        PopupView(
          repo: r,
          onClose: () {},
          onSettings: () {},
          miniSignal: mini,
          onRefresh: onRefresh,
        );

    /// Progressive-prefix typing acts against the first visible TextField.
    /// Seeded jitter keeps the cadence human without wall-clock randomness.
    List<(Duration, Future<void> Function())> typing(
      String text,
      Duration start, {
      int seed = 1,
      int baseMs = 85,
      int fieldIndex = 0,
    }) {
      final rnd = math.Random(seed);
      final acts = <(Duration, Future<void> Function())>[];
      var at = start;
      for (var i = 1; i <= text.length; i++) {
        final prefix = text.substring(0, i);
        acts.add((
          at,
          () async {
            final fields = find.byType(TextField);
            if (fields.evaluate().length > fieldIndex) {
              await tester.enterText(fields.at(fieldIndex), prefix);
            }
          }
        ));
        at += Duration(milliseconds: baseMs + rnd.nextInt(70));
      }
      return acts;
    }

    Future<void> tapText(String label, {bool optional = false}) async {
      final f = find.text(label);
      if (f.evaluate().isEmpty) {
        if (!optional) debugPrint('tapText: "$label" not found');
        return;
      }
      await tester.tap(f.first, warnIfMissed: false);
    }

    // Warm-up render (discarded): primes the image cache for both
    // synthesized photos before the first kept frame paints.
    await record(
      name: 'warmup',
      build: (c) => popup(repo),
      length: const Duration(milliseconds: 300),
      discard: true,
    );

    // 0. THE STORY OPENER — capture + name, all on the "mock desktop". A fake
    // accountant email holds the EIN; a selection sweep + Ctrl+C chip simulate
    // the copy, then the chip itself MORPHS into the capture-and-annotate
    // chord (Ctrl+Shift+E) and the REAL EditDialog pops straight into edit
    // mode (title focused) — we type the label "EIN" and Save. The chip is
    // how the cut teaches the hotkey: in the scene, not in a caption. The
    // whole beat stays on the desktop; the app showcase begins at the next
    // scene (recall). Everything but the dialog is scenery.
    final selecting = ValueNotifier<bool>(false);
    final copied = ValueNotifier<bool>(false);
    final chipLabel = ValueNotifier<String>('Ctrl+C');
    final editOpen = ValueNotifier<bool>(false);
    // 0a-pre. AUTO-CAPTURE — the opener. Three things get copied off one
    // ordinary support page (a serial, a network key, a figure) and each one
    // simply lands: the only Relic UI on screen is the toast. This is the
    // "you already copied it" claim the website makes, shown rather than
    // asserted, and it has to come before any dialog does.
    final sweepStep = ValueNotifier<int>(0); // 0 none, 1 serial, 2 key
    final autoChip = ValueNotifier<int>(0);
    final toastN = ValueNotifier<int>(0);
    // The folder the download lands in: 0 closed, 1 open, 2 file clicked.
    final explorer = ValueNotifier<int>(0);
    final pressing = ValueNotifier<bool>(false); // the download button, clicked
    final relicIn = ValueNotifier<bool>(false);

    // The opener's own repo, empty of the things it is about to capture, so
    // the reveal at the end shows them ARRIVING rather than sitting there.
    final openRepo = StoreShotRepo(extended: true, agedEin: true);
    await tester.runAsync(() async {
      await openRepo.preparePhoto();
      await openRepo.load();
    });
    final openTick = ValueNotifier<int>(0);
    final openNow = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    Relic openItem(String uid, {String? title, String? content,
            String? filename, Kind kind = Kind.string, int bytes = 64,
            String? blobKey, List<String> tags = const []}) =>
        Relic(
          uid: uid,
          createdAt: openNow,
          updatedAt: openNow,
          kind: kind,
          source: Source.clipboard,
          promoted: false,
          byteSize: bytes,
          blobKey: blobKey,
          device: 'Windows PC',
          tags: tags,
          userTags: const [],
          title: title,
          content: content,
          filename: filename,
        );

    await record(
      name: 'auto-capture',
      build: (c) => _FakeDocsPage(
        imagePath: openRepo.manualPath,
        sweep: sweepStep,
        chip: autoChip,
        toast: toastN,
        explorer: explorer,
        pressing: pressing,
        relicIn: relicIn,
        relic: AnimatedBuilder(
          animation: openTick,
          builder: (_, _) => popup(openRepo),
        ),
      ),
      logical: const Size(1100, 780),
      // Two text copies, then the file. Three toasts inside five seconds read
      // as popcorn: the beat says "this happens on its own and you stop
      // thinking about it", which needs air.
      length: const Duration(milliseconds: 15400),
      acts: [
        (const Duration(milliseconds: 800), () async => sweepStep.value = 1),
        (const Duration(milliseconds: 1450), () async {
          autoChip.value = 1;
          toastN.value = 1;
          await openRepo.restore(openItem('o-serial',
              content: 'AS2-9F41-77KD', tags: const ['number']));
          openTick.value++;
        }),
        (const Duration(milliseconds: 3900), () async {
          sweepStep.value = 2;
          autoChip.value = 0;
        }),
        (const Duration(milliseconds: 4550), () async {
          autoChip.value = 2;
          toastN.value = 2;
          await openRepo.restore(openItem('o-key', content: 'sunlit-harbor-42'));
          openTick.value++;
        }),
        // A file, not text. The manual downloads, the folder it landed in
        // opens, the file gets CLICKED, and Ctrl+C on it is the same gesture
        // with the same result. That is the whole claim: a clipboard manager
        // keeps text, and this keeps whatever you copied.
        (const Duration(milliseconds: 5900), () async {
          sweepStep.value = 0;
          pressing.value = true;
        }),
        (const Duration(milliseconds: 6400), () async {
          pressing.value = false;
          explorer.value = 1;
        }),
        (const Duration(milliseconds: 7900), () async => explorer.value = 2),
        (const Duration(milliseconds: 8600), () async => autoChip.value = 4),
        (const Duration(milliseconds: 9300), () async {
          toastN.value = 3;
          await openRepo.restore(openItem('o-aurora',
              kind: Kind.file,
              title: 'Aurora S2 manual',
              filename: 'aurora-s2-manual.pdf',
              bytes: 2410000,
              blobKey: 'demo-aurora',
              tags: const ['document']));
          openTick.value++;
        }),
        (const Duration(milliseconds: 10400), () async {
          autoChip.value = 0;
          explorer.value = 0;
        }),
        // ...and here it all is, without anyone having filed anything.
        (const Duration(milliseconds: 11200), () async => relicIn.value = true),
      ],
    );

    final einNow = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // title/preview null => the dialog's title field opens EMPTY (the hotkey
    // flow: your next keystrokes ARE the label); content holds the number.
    final einRelic = Relic(
      uid: 'einNew',
      createdAt: einNow,
      updatedAt: einNow,
      kind: Kind.string,
      source: Source.clipboard,
      promoted: false,
      byteSize: 0,
      device: 'Windows PC',
      tags: const [],
      userTags: const [],
      content: '88-1402316',
      preview: null,
      title: null,
    );
    await record(
      name: 'capture',
      build: (c) => _FakeEmailPage(
        selecting: selecting,
        copied: copied,
        chipLabel: chipLabel,
        editOpen: editOpen,
        edit: EditDialog(
          relic: einRelic,
          repo: repo,
          autofocus: true,
          onCancel: () => editOpen.value = false,
          onCopy: () {},
          onDelete: () {},
          onSave: (title, note, userTags, machineTags, content, _, _) async {
            await repo.updateMeta(einRelic,
                title: title,
                note: note,
                userTags: userTags,
                tags: machineTags,
                content: content);
            editOpen.value = false;
          },
        ),
      ),
      logical: const Size(1100, 780),
      length: const Duration(milliseconds: 6800),
      acts: [
        (const Duration(milliseconds: 700), () async => selecting.value = true),
        (const Duration(milliseconds: 1500), () async => copied.value = true),
        // The copy chip becomes the hotkey chord, then the panel answers it.
        (
          const Duration(milliseconds: 2300),
          () async => chipLabel.value = 'Ctrl+Shift+E'
        ),
        (
          const Duration(milliseconds: 3000),
          () async {
            await repo.restore(einRelic);
            editOpen.value = true; // hotkey -> straight into edit mode
          }
        ),
        // Title field is autofocused; the typed characters land as the label.
        ...typing('EIN', const Duration(milliseconds: 3900),
            seed: 21, baseMs: 190, fieldIndex: 1),
        (const Duration(milliseconds: 5500), () async => tapText('Save')),
      ],
    );

    // 13c. INSTANT SYNC — rendered as TWO streams on one shared clock so the
    // compositor can seat each into the real device art the website hero
    // uses (macbook.webp / iphone.webp). Both are deterministic, so frame N
    // of one is genuinely frame N of the other: the arrival is still a
    // single continuous take, it is just composited into two screens.
    final syncDesk = StoreShotRepo(extended: true);
    final syncPhone = StoreShotRepo(extended: true);
    await tester.runAsync(() async {
      await syncDesk.preparePhoto();
      await syncDesk.load();
      await syncPhone.preparePhoto();
      await syncPhone.load();
    });
    final syncing = ValueNotifier<bool>(false);
    // PopupView does not repaint on a bare repo mutation in the harness, so
    // both streams rebuild off an explicit tick.
    final deskTick = ValueNotifier<int>(0);
    final phoneTick = ValueNotifier<int>(0);
    final syncNow = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    Relic syncItem() => Relic(
          uid: 'syncdemo',
          createdAt: syncNow,
          updatedAt: syncNow,
          kind: Kind.photo,
          source: Source.clipboard,
          promoted: false,
          byteSize: 742000,
          blobKey: 'demo-manual',
          device: 'Windows PC',
          tags: const ['screenshot'],
          userTags: const [],
          title: 'Setup guide',
          content: StoreShotRepo.manualOcrText,
        );
    const syncLen = Duration(milliseconds: 6200);

    await record(
      name: 'sync-desk',
      build: (c) => _Desktop(
        child: AnimatedBuilder(
          animation: deskTick,
          builder: (_, _) => popup(syncDesk),
        ),
      ),
      // The MacBook cutout's aspect (1.541) so the stream drops into the
      // screen with no crop, and no larger than it needs to be: every extra
      // logical pixel here shrinks the popup inside the laptop.
      logical: const Size(1140, 740),
      length: syncLen,
      acts: [
        (const Duration(milliseconds: 1300), () async {
          await syncDesk.restore(syncItem());
          deskTick.value++;
        }),
      ],
    );

    await record(
      name: 'sync-phone',
      build: (c) => AnimatedBuilder(
        animation: Listenable.merge([phoneTick, syncing]),
        builder: (_, _) => PopupView(
          repo: syncPhone,
          onClose: () {},
          onSettings: () {},
          syncing: syncing.value,
        ),
      ),
      // 0.4615, the iphone.webp screen aspect.
      logical: const Size(360, 780),
      dpr: 3.0,
      capRatio: 2.0,
      isMobile: true,
      length: syncLen,
      acts: [
        // The desktop copy landed at 1.3s; the phone wakes and has it by 2.2s.
        (const Duration(milliseconds: 1900), () async => syncing.value = true),
        (const Duration(milliseconds: 2200), () async {
          await syncPhone.restore(syncItem());
          phoneTick.value++;
        }),
        (const Duration(milliseconds: 3100), () async => syncing.value = false),
      ],
    );

    // Single-scene re-renders: every showcase scene assumes the captured EIN
    // exists (titled) in the main repo. If capture was filtered out, seed it.
    if (!repo.all.any((r) => r.uid == 'einNew')) {
      await repo.restore(Relic(
        uid: 'einNew',
        createdAt: einNow,
        updatedAt: einNow,
        kind: Kind.string,
        source: Source.clipboard,
        promoted: false,
        byteSize: 0,
        device: 'Windows PC',
        tags: const [],
        userTags: const [],
        title: 'EIN',
        content: '88-1402316',
        preview: '88-1402316',
      ));
    }

    // 0c. Recall: when you need it next (story time), search "EIN" over the
    // whole legacy vault, one aged result, tap it, Enter -> the real "Copied
    // to clipboard" toast.
    await record(
      name: 'recall',
      build: (c) => popup(secretRepo),
      length: const Duration(milliseconds: 5400),
      acts: [
        ...typing('EIN', const Duration(milliseconds: 800),
            seed: 22, baseMs: 170),
        (
          const Duration(milliseconds: 2600),
          () async => tapText('88-1402316', optional: true)
        ),
        (
          const Duration(milliseconds: 3600),
          () async => tester.sendKeyEvent(LogicalKeyboardKey.enter)
        ),
      ],
    );

    // 0c-bis. The same recall, in a window sized to what it found. The full
    // popup is a fixed 520x680, so a search with exactly one hit leaves two
    // thirds of it empty; that is honest but it photographs as an empty app.
    // Same repo, same query, same toast, in a short window that a still can
    // use. Video cuts should keep 'recall' above; this one is for stills.
    await record(
      name: 'recall-tight',
      build: (c) => popup(secretRepo),
      logical: const Size(520, 404),
      length: const Duration(milliseconds: 5400),
      acts: [
        ...typing('EIN', const Duration(milliseconds: 800),
            seed: 22, baseMs: 170),
        (
          const Duration(milliseconds: 2600),
          () async => tapText('88-1402316', optional: true)
        ),
        (
          const Duration(milliseconds: 3600),
          () async => tester.sendKeyEvent(LogicalKeyboardKey.enter)
        ),
      ],
    );

    // 0d. THE LOCAL MODELS NAMING THINGS — a screenshot lands with no title
    // and no tags, the row shows the SHIPPING "Analyzing..." spinner while the
    // on-device pass runs, and then the title and the tags simply appear.
    // "It reads your screenshots" was only ever half of it; the half people
    // care about is never having to name or file anything.
    final tagRepo = StoreShotRepo(extended: true, agedEin: true);
    await tester.runAsync(() async {
      await tagRepo.preparePhoto();
      await tagRepo.load();
    });
    // The seed's own boarding pass has to go: two identical passes stacked on
    // top of each other reads as a duplicate bug, not as one shot arriving.
    if (tagRepo.byUid('flight') case final f?) await tagRepo.delete(f);
    final tagTick = ValueNotifier<int>(0);
    final tagNow = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // uid 'flight' on purpose: StoreShotRepo.localImagePath keys the painted
    // boarding-pass image off that uid, and anything else falls through to the
    // generic receipt. A row captioned "Boarding pass" over a picture of a
    // receipt is the kind of detail that makes a promo shot look staged.
    final rawShot = Relic(
      uid: 'flight',
      createdAt: tagNow,
      updatedAt: tagNow,
      kind: Kind.photo,
      source: Source.clipboard,
      promoted: false,
      byteSize: 860000,
      blobKey: 'demo-flight',
      device: 'Windows PC',
      tags: const [],
      userTags: const [],
      content: null,
    );
    await record(
      name: 'autotag',
      build: (c) => AnimatedBuilder(
        animation: tagTick,
        builder: (_, _) => popup(tagRepo),
      ),
      length: const Duration(milliseconds: 6400),
      acts: [
        (const Duration(milliseconds: 900), () async {
          await tagRepo.restore(rawShot);
          tagRepo.analyzing.add('flight');
          tagTick.value++;
        }),
        // The pass finishes: a generated title, the machine tags, and the OCR
        // text that makes the picture searchable.
        (const Duration(milliseconds: 3400), () async {
          await tagRepo.updateMeta(
            rawShot,
            title: 'Boarding pass',
            tags: const ['screenshot', 'travel', 'document'],
            content: 'CONDOR AIR boarding pass PDX SEA flight CA 1042 '
                'gate B12 seat 14C boards 9:10 AM confirmation QX7-4NP',
          );
          tagRepo.analyzing.remove('flight');
          tagTick.value++;
        }),
      ],
    );

    // 1. History list: brief idle, then energetic scrolling through the
    // legacy vault.
    await record(
      name: 'history',
      build: (c) => popup(repo),
      length: const Duration(milliseconds: 5200),
      acts: [
        // Coordinate-based flings so they land on the LIST (the chip strip is
        // also a Scrollable and finder-based flings hit it first).
        (
          const Duration(milliseconds: 800),
          () async =>
              tester.flingFrom(const Offset(260, 480), const Offset(0, -420), 1600)
        ),
        (
          const Duration(milliseconds: 2200),
          () async =>
              tester.flingFrom(const Offset(260, 480), const Offset(0, -420), 1600)
        ),
        (
          const Duration(milliseconds: 3700),
          () async =>
              tester.flingFrom(const Offset(260, 480), const Offset(0, 900), 2400)
        ),
      ],
    );

    // 2. Select a history row (floating action card) and promote it to the
    // Vault: amber gem + "Promoted to Vault" toast.
    await record(
      name: 'promote',
      build: (c) => popup(repo),
      length: const Duration(milliseconds: 4400),
      acts: [
        (
          const Duration(milliseconds: 700),
          () async =>
              tapText('https://github.com/jordan-gibbs/relic', optional: true)
        ),
        (
          const Duration(milliseconds: 1500),
          () async {
            // The action cluster's vault-gem button: the only GhostButton
            // whose icon is the RelicMark.
            final gem = find.ancestor(
              of: find.byType(RelicMark),
              matching: find.byType(GhostButton),
            );
            if (gem.evaluate().isNotEmpty) {
              await tester.tap(gem.first, warnIfMissed: false);
            }
          }
        ),
      ],
    );

    // 3. Live keyword search: results filter as each character lands.
    await record(
      name: 'search-type',
      build: (c) => popup(repo),
      length: const Duration(milliseconds: 4400),
      acts: typing('office chair', const Duration(milliseconds: 700),
          seed: 3, baseMs: 80),
    );

    // 4. The on-device-AI proof: a text query surfaces an IMAGE row (the
    // boarding-pass "screenshot") because its OCR text is searchable — then we
    // OPEN it, and the real viewer shows the text the on-device OCR pulled out
    // of the picture in its "Extracted text" section.
    await record(
      name: 'search-ocr',
      build: (c) => popup(repo),
      length: const Duration(milliseconds: 6600),
      acts: [
        // Deliberately a phrase that exists ONLY inside the boarding-pass
        // image (shot_seed.manualOcrText / the painted photo), never in a
        // title or preview. A title match would prove nothing about OCR.
        ...typing('gate B12', const Duration(milliseconds: 700),
            seed: 4, baseMs: 95),
        (
          const Duration(milliseconds: 2800),
          () async {
            // Double-tap the image row -> the unified viewer opens on the
            // screenshot, with the recognized text below it.
            final row = find.text('Boarding pass');
            if (row.evaluate().isEmpty) return;
            await tester.tap(row.first, warnIfMissed: false);
            await tester.pump(const Duration(milliseconds: 60));
            await tester.tap(row.first, warnIfMissed: false);
          }
        ),
      ],
    );

    // 4b. THE SEARCH ITSELF — three queries that share NO words with the
    // things they find. This beat runs the SHIPPING ranking rather than the
    // gallery repo's substring filter: StoreShotRepo.enableHybridSearch puts a
    // real RelicDb behind setQuery, so what ranks here is
    // RelicDb.lexicalHybridUids — bm25 FTS, the trigram recall leg, tag-intent
    // and a recency prior, fused with weighted RRF. Nothing is staged; the
    // queries are typed and the algorithm answers.
    //
    //   "hex"         -> colour swatches (the tag is `color`)
    //   "money"       -> the dollar amounts (the tag is `currency`)
    //   "bording pas" -> Boarding pass, off two misspelled words
    final smartRepo = StoreShotRepo(extended: true, agedEin: true);
    await tester.runAsync(() async {
      await smartRepo.preparePhoto();
      await smartRepo.load();
      await smartRepo.enableHybridSearch();
    });
    addTearDown(smartRepo.disposeHybrid);
    await record(
      name: 'search-smart',
      build: (c) => popup(smartRepo),
      length: const Duration(milliseconds: 11800),
      acts: [
        ...typing('hex', const Duration(milliseconds: 700), seed: 7, baseMs: 105),
        (const Duration(milliseconds: 3200), () async {
          final f = find.byType(TextField);
          if (f.evaluate().isNotEmpty) await tester.enterText(f.first, '');
        }),
        ...typing('money', const Duration(milliseconds: 3700), seed: 8, baseMs: 100),
        (const Duration(milliseconds: 6900), () async {
          final f = find.byType(TextField);
          if (f.evaluate().isNotEmpty) await tester.enterText(f.first, '');
        }),
        ...typing('bording pas', const Duration(milliseconds: 7400),
            seed: 9, baseMs: 95),
      ],
    );

    // 4c. Dates the way people say them. The box parses a date phrase out of
    // the query (app/lib/data/temporal_parser.dart), lifts it into a removable
    // gold chip, and searches only what is left over. Nothing is staged: the
    // sentence is typed and the parser answers, so the rows that come back are
    // genuinely the ones from that month.
    await record(
      name: 'search-date',
      build: (c) => popup(smartRepo),
      length: const Duration(milliseconds: 6600),
      acts: typing('screenshots from 3 months ago',
          const Duration(milliseconds: 800), seed: 11, baseMs: 78),
    );

    // 5. Operator search: tag: filter typed live.
    await record(
      name: 'search-tag',
      build: (c) => popup(repo),
      length: const Duration(milliseconds: 4600),
      acts: typing('tag:receipt', const Duration(milliseconds: 700),
          seed: 5, baseMs: 80),
    );

    // 6. Collection facet chips (driven by the machine tags the local AI
    // writes): the chip strip itself IS the proof — a dozen smart categories
    // with live counts. Slide the strip so the categories parade by, tap
    // Screenshots, and the list snaps to the shots the on-device AI tagged;
    // scroll through them so the beat stays alive.
    await record(
      name: 'facets',
      build: (c) => popup(repo),
      length: const Duration(milliseconds: 5400),
      acts: [
        // Fling FROM a known chip so the gesture lands on the horizontal strip
        // (a coordinate fling can hit the results list instead).
        (
          const Duration(milliseconds: 700),
          () async {
            final links = find.text('Links');
            if (links.evaluate().isNotEmpty) {
              await tester.fling(links.first, const Offset(-300, 0), 900);
            }
          }
        ),
        (
          const Duration(milliseconds: 2000),
          () async => tapText('Screenshots', optional: true)
        ),
        // The strip collapses once a facet is active; the shots now fill the
        // list — scroll through the auto-tagged wall of thumbnails.
        (
          const Duration(milliseconds: 3300),
          () async => tester.flingFrom(
              const Offset(280, 430), const Offset(0, -360), 1400)
        ),
        (
          const Duration(milliseconds: 4400),
          () async => tester.flingFrom(
              const Offset(280, 430), const Offset(0, -300), 1300)
        ),
      ],
    );

    // 7. Vault scope: just the keepers.
    await record(
      name: 'vault',
      build: (c) => popup(repo),
      length: const Duration(milliseconds: 2600),
      acts: [
        (const Duration(milliseconds: 700), () async => tapText('Vault')),
      ],
    );

    // 9. Share dialog: focus the ONE-TIME encrypted link. A file relic (the
    // invoice) isn't QR-eligible, so the dialog skips the offline-QR block and
    // goes straight to the link: pick a short expiry (1 hour), turn on
    // One-time view, Create link -> the real created-link state shows the URL,
    // QR, and the "One-time view · expires …" caption (dies after one reveal).
    await record(
      name: 'share',
      build: (c) => Center(
        child: Padding(
          padding: const EdgeInsets.all(14),
          // Fade/scale-in so the dialog opens deliberately, then holds on the
          // options (the "encrypted on this device, key never reaches the
          // server" preamble) before the link is created.
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            builder: (_, v, child) => Opacity(
              opacity: v,
              child: Transform.scale(scale: 0.97 + 0.03 * v, child: child),
            ),
            child: ShareDialog(
              relic: repo.all.firstWhere((r) => r.uid == 'invoice'),
              repo: repo,
              onClose: () {},
            ),
          ),
        ),
      ),
      logical: const Size(520, 720),
      length: const Duration(milliseconds: 7000),
      acts: [
        (
          const Duration(milliseconds: 2100),
          () async => tapText('1 hour', optional: true)
        ),
        (
          const Duration(milliseconds: 3200),
          () async => tapText('One-time view', optional: true)
        ),
        (
          const Duration(milliseconds: 4400),
          () async => tapText('Create link', optional: true)
        ),
      ],
    );

    // 10. Recovery kit: "RELIC KEEPS NO COPY · STORE IT OFFLINE". Mostly a
    // hold; motion comes from the compositor's slow zoom.
    await record(
      name: 'recovery',
      build: (c) => const Center(child: RecoveryKitView()),
      length: const Duration(milliseconds: 3000),
    );

    // 11. Connect dialog: cloud vs self-host chooser, then the self-host form
    // with a real (loopback) health check going green.
    await record(
      name: 'connect',
      build: (c) => const SizedBox.expand(),
      length: const Duration(milliseconds: 8600),
      acts: [
        (
          const Duration(milliseconds: 200),
          () async {
            final ctx = tester.element(find.byType(Scaffold).first);
            // Unawaited: resolves when the dialog pops at the end of the scene.
            // ignore: unawaited_futures
            showConnectDialog(
              ctx,
              colors: RelicColors.dark,
              onCloud: () {},
              onSelfHost: (url, pass, secret) async {
                await Future<void>.delayed(const Duration(milliseconds: 600));
                return null;
              },
            );
          }
        ),
        (
          const Duration(milliseconds: 1000),
          () async => tapText('Your own server')
        ),
        (const Duration(milliseconds: 1800), () async => tapText('Next')),
        ...typing(demoServerUrl, const Duration(milliseconds: 2400),
            seed: 11, baseMs: 30),
        (const Duration(milliseconds: 4200), () async => tapText('Test')),
        ...typing('correct-horse-battery-staple',
            const Duration(milliseconds: 5400),
            seed: 12, baseMs: 28, fieldIndex: 1),
        (const Duration(milliseconds: 7400), () async => tapText('Connect')),
      ],
    );

    // 12. Mini picker IN CONTEXT — the payoff of the opener: a vendor
    // onboarding form asks for the EIN captured (in story time) back in
    // scene 0. The Ctrl+Shift+Space chip pops on the focused field, the
    // picker opens at the caret, typing "EIN" surfaces the named entry,
    // Enter pastes it into the form.
    // The picker has to SEARCH, not just reveal what is already on top. With
    // the freshly captured EIN the entry was the first row before a key was
    // pressed, which made the query decorative. The aged seed buries it ~8
    // months down, so typing "ein" is what surfaces it.
    final miniRepo = StoreShotRepo(extended: true, agedEin: true);
    await tester.runAsync(() async {
      await miniRepo.preparePhoto();
      await miniRepo.load();
    });
    final miniOpen = ValueNotifier<bool>(false);
    final miniChip = ValueNotifier<bool>(false);
    final formValue = ValueNotifier<String>('');
    // Full list, then the hug as "ein" narrows it: 50px of search field plus
    // ~32px a row.
    final miniHeight = ValueNotifier<double>(196);
    await record(
      name: 'mini',
      build: (c) => _FakeEinFormPage(
        formValue: formValue,
        miniOpen: miniOpen,
        miniHeight: miniHeight,
        hotkeyChip: miniChip,
        mini: PopupView(
          repo: miniRepo,
          onClose: () {},
          onSettings: () {},
          miniSignal: miniOpen,
          onPick: () {
            formValue.value = '88-1402316';
            miniOpen.value = false;
            miniChip.value = false; // the chord did its job; clear the field
            miniHeight.value = 196; // reset for a single-scene re-render
          },
        ),
      ),
      logical: const Size(1100, 780),
      length: const Duration(milliseconds: 6000),
      acts: [
        // The chord chip first, then the picker answers it.
        (const Duration(milliseconds: 700), () async => miniChip.value = true),
        (
          const Duration(milliseconds: 1400),
          () async => miniOpen.value = true
        ),
        ...typing('ein', const Duration(milliseconds: 2300),
            seed: 13, baseMs: 150),
        // Hug down as the query narrows, the way the real window does.
        (const Duration(milliseconds: 2500), () async => miniHeight.value = 140),
        (const Duration(milliseconds: 2900), () async => miniHeight.value = 86),
        (
          const Duration(milliseconds: 4100),
          () async => tester.sendKeyEvent(LogicalKeyboardKey.enter)
        ),
      ],
    );

    // 13a. Cross-device, part one — the physical act on the DESKTOP: a device
    // manual (quick-start guide) open in the browser, then a Win+Shift+S-style
    // snip (screen dims, a selection grows over the guide, a shutter flash)
    // captures it. The same image lands on the phone next.
    final snip = ValueNotifier<int>(0); // 0 idle, 1 dragging, 2 flash/captured
    await record(
      name: 'screenshot',
      build: (c) => _FakeSnip(
        imagePath: repo.manualPath,
        snip: snip,
      ),
      logical: const Size(1100, 780),
      length: const Duration(milliseconds: 4600),
      acts: [
        (const Duration(milliseconds: 900), () async => snip.value = 1),
        (const Duration(milliseconds: 1900), () async => snip.value = 2),
      ],
    );

    // 13b. Cross-device, part two — the PHONE: the snipped image arrives
    // INSTANTLY (a live push, no pull/refresh), then a double-tap opens it in
    // view mode (the real viewer) to see the full screenshot.
    final phoneSyncing = ValueNotifier<bool>(false);
    await record(
      name: 'phone',
      build: (c) => ValueListenableBuilder<bool>(
        valueListenable: phoneSyncing,
        builder: (_, syncing, _) => PopupView(
          repo: phoneRepo,
          onClose: () {},
          onSettings: () {},
          syncing: syncing,
        ),
      ),
      logical: const Size(360, 760),
      dpr: 3.0,
      capRatio: 2.0,
      isMobile: true,
      length: const Duration(milliseconds: 6400),
      acts: [
        (
          const Duration(milliseconds: 1400),
          () async {
            // Live push: the item lands and the sync pulse flips on in the
            // same beat, so it simply appears at the top.
            final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            await phoneRepo.restore(Relic(
              uid: 'manual',
              createdAt: now,
              updatedAt: now,
              kind: Kind.photo,
              source: Source.clipboard,
              promoted: false,
              byteSize: 742000,
              blobKey: 'demo-manual',
              device: 'Windows PC',
              tags: const ['screenshot'],
              userTags: const [],
              title: 'Speaker setup guide',
              content: StoreShotRepo.manualOcrText,
            ));
            phoneSyncing.value = true;
          }
        ),
        (
          const Duration(milliseconds: 2200),
          () async => phoneSyncing.value = false,
        ),
        (
          const Duration(milliseconds: 3600),
          () async {
            // Double-tap the fresh row -> the real viewer (unified edit
            // screen) opens on the image.
            final row = find.text('Speaker setup guide');
            if (row.evaluate().isEmpty) return;
            await tester.tap(row.first, warnIfMissed: false);
            await tester.pump(const Duration(milliseconds: 60));
            await tester.tap(row.first, warnIfMissed: false);
          }
        ),
      ],
    );

    await tester.runAsync(() async => health?.close(force: true));
    debugDisableShadows = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(days: 3));

    if (failures.isNotEmpty) {
      fail('scenes failed: ${failures.entries.map((e) => '${e.key}: ${e.value}').join('; ')}');
    }
  }, timeout: const Timeout(Duration(minutes: 60)));
}

/// The capture scene's scenery: browser chrome + an opened accountant email
/// holding the EIN. [selecting] animates a selection highlight across the EIN
/// line, [copied] fades in a key chip whose text tracks [chipLabel] (Ctrl+C,
/// then the capture chord), and [editOpen] pops the REAL EditDialog (passed
/// as [edit]) straight into edit mode over the desktop, as the
/// capture-and-annotate hotkey would.
class _FakeEmailPage extends StatelessWidget {
  final ValueListenable<bool> selecting;
  final ValueListenable<bool> copied;
  final ValueListenable<String> chipLabel;
  final ValueListenable<bool> editOpen;
  final Widget edit;
  const _FakeEmailPage({
    required this.selecting,
    required this.copied,
    required this.chipLabel,
    required this.editOpen,
    required this.edit,
  });

  static const _ink = Color(0xFF1C2128);
  // The hotkey chip is Relic UI, not the fake page: brand Ink, and the
  // mono the app actually ships.
  static const _chipInk = Color(0xFF111110);
  static const _dim = Color(0xFF6A7280);
  static const _select = Color(0xFFB8D7FB);

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Column(children: [
        // Browser chrome (same look as the booking page).
        Container(
          height: 46,
          color: const Color(0xFF2A2E35),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            for (final c in const [
              Color(0xFFE5655C),
              Color(0xFFE0A63C),
              Color(0xFF57B85F)
            ])
              Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(color: c, shape: BoxShape.circle),
              ),
            const SizedBox(width: 14),
            Expanded(
              child: Container(
                height: 30,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF3A3F47),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Text(
                  'mail.example/inbox',
                  style: TextStyle(
                    fontFamily: 'IBMPlexMono',
                    fontSize: 12.5,
                    color: Color(0xFFC9CED6),
                  ),
                ),
              ),
            ),
          ]),
        ),
        Expanded(
          child: Container(
            color: const Color(0xFFF2F4F7),
            alignment: const Alignment(-0.45, -0.4),
            child: Container(
              width: 560,
              padding: const EdgeInsets.all(30),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFFFF),
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x1A1C2128),
                    blurRadius: 30,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Your EIN is ready',
                      style: TextStyle(
                          fontFamily: 'IBMPlexSans',
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                          color: _ink)),
                  const SizedBox(height: 8),
                  const Text('Priya Shah · priya@ledgerandoak.example',
                      style: TextStyle(
                          fontFamily: 'IBMPlexSans', fontSize: 12.5, color: _dim)),
                  const SizedBox(height: 16),
                  Container(height: 1, color: const Color(0xFFE4E8ED)),
                  const SizedBox(height: 18),
                  _para('Hi Jordan,'),
                  const SizedBox(height: 12),
                  _para('The IRS assigned the EIN for Maplewood Studio LLC '
                      'this morning. You\'ll want it for the W-9 and the '
                      'bank paperwork:'),
                  const SizedBox(height: 16),
                  // The EIN line: selection highlight sweeps across on cue,
                  // and the Ctrl+C chip fades in beside it.
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: selecting,
                      builder: (_, on, _) => TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: on ? 1 : 0),
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeInOut,
                        builder: (_, v, _) => Stack(children: [
                          Positioned.fill(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: FractionallySizedBox(
                                widthFactor: v,
                                heightFactor: 1,
                                child: const ColoredBox(color: _select),
                              ),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            child: Text('88-1402316',
                                style: TextStyle(
                                    fontFamily: 'IBMPlexMono',
                                    fontSize: 21,
                                    fontWeight: FontWeight.w600,
                                    color: _ink)),
                          ),
                        ]),
                      ),
                    ),
                    const SizedBox(width: 14),
                    ValueListenableBuilder<bool>(
                      valueListenable: copied,
                      builder: (_, on, _) => AnimatedOpacity(
                        opacity: on ? 1 : 0,
                        duration: const Duration(milliseconds: 220),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: _chipInk,
                            borderRadius: BorderRadius.circular(7),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x33111110),
                                blurRadius: 12,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          // The label morphs (Ctrl+C -> the capture chord):
                          // the chip teaches the hotkey inside the scene.
                          child: ValueListenableBuilder<String>(
                            valueListenable: chipLabel,
                            builder: (_, label, _) => AnimatedSize(
                              duration: const Duration(milliseconds: 240),
                              curve: Curves.easeOutCubic,
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 240),
                                child: Text(label,
                                    key: ValueKey(label),
                                    style: const TextStyle(
                                        fontFamily: 'JetBrainsMono',
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFFF1F1EF))),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  _para('I\'ll take care of the state filing. Shout if you '
                      'need anything else.'),
                  const SizedBox(height: 12),
                  _para('Priya'),
                ],
              ),
            ),
          ),
        ),
      ]),
      // The real EditDialog, popped into edit mode over the desktop by the
      // capture-and-annotate hotkey: dim scrim + a scale/fade-in.
      ValueListenableBuilder<bool>(
        valueListenable: editOpen,
        builder: (_, open, _) => !open
            ? const SizedBox.shrink()
            : Positioned.fill(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  builder: (_, v, child) => ColoredBox(
                    color: Color.fromRGBO(6, 8, 12, 0.5 * v),
                    child: Center(
                      child: Opacity(
                        opacity: v,
                        child: Transform.scale(
                          scale: 0.96 + 0.04 * v,
                          child: child,
                        ),
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: edit,
                  ),
                ),
              ),
      ),
    ]);
  }

  static Widget _para(String t) => Text(t,
      style: const TextStyle(
          fontFamily: 'IBMPlexSans',
          fontSize: 13.5,
          height: 1.55,
          color: _ink));
}

/// The cross-device scene's desktop half: a "maps" page in browser chrome
/// with a Win+Shift+S-style region snip over it. [snip]: 0 idle, 1 dragging
/// (screen dims, a selection grows across the map), 2 captured (shutter
/// flash). The map image is the SAME one that lands on the phone next.
class _FakeSnip extends StatelessWidget {
  final String? imagePath;
  final ValueListenable<int> snip;
  const _FakeSnip({required this.imagePath, required this.snip});

  // Page coords (1100x780 logical): the map image, and the selection region
  // (image + a small margin) the snip grows to.
  static const _imgRect = Rect.fromLTWH(400, 208, 300, 420);
  static const _sel = Rect.fromLTWH(384, 194, 332, 448);

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      const Positioned.fill(child: ColoredBox(color: Color(0xFFE7ECF2))),
      // Browser chrome.
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: Container(
          height: 46,
          color: const Color(0xFF2A2E35),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            for (final c in const [
              Color(0xFFE5655C),
              Color(0xFFE0A63C),
              Color(0xFF57B85F)
            ])
              Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(color: c, shape: BoxShape.circle),
              ),
            const SizedBox(width: 14),
            Expanded(
              child: Container(
                height: 30,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF3A3F47),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Text('support.aurora.example/s2/setup',
                    style: TextStyle(
                        fontFamily: 'IBMPlexMono',
                        fontSize: 12.5,
                        color: Color(0xFFC9CED6))),
              ),
            ),
          ]),
        ),
      ),
      // The map/directions screenshot (the very image that lands on the phone).
      if (imagePath != null)
        Positioned.fromRect(
          rect: _imgRect,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x22000000),
                    blurRadius: 24,
                    offset: Offset(0, 8)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(File(imagePath!), fit: BoxFit.cover),
            ),
          ),
        ),
      // Snip overlay: dim + growing selection, then a shutter flash.
      Positioned.fill(
        child: ValueListenableBuilder<int>(
          valueListenable: snip,
          builder: (_, phase, _) {
            if (phase == 0) return const SizedBox.shrink();
            return Stack(children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: phase >= 1 ? 1.0 : 0.0),
                duration: const Duration(milliseconds: 620),
                curve: Curves.easeOut,
                builder: (_, p, _) =>
                    CustomPaint(painter: _SnipPainter(_sel, p), size: Size.infinite),
              ),
              if (phase == 2)
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.85, end: 0.0),
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOut,
                  builder: (_, f, _) => IgnorePointer(
                    child: ColoredBox(color: Color.fromRGBO(255, 255, 255, f)),
                  ),
                ),
            ]);
          },
        ),
      ),
    ]);
  }
}

class _SnipPainter extends CustomPainter {
  final Rect target;
  final double p; // 0..1 drag progress
  _SnipPainter(this.target, this.p);

  @override
  void paint(Canvas canvas, Size size) {
    final sel = Rect.fromLTWH(
        target.left, target.top, target.width * p, target.height * p);
    final dim = Paint()..color = const Color(0x73060810); // ~0.45 black
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, sel.top), dim);
    canvas.drawRect(Rect.fromLTRB(0, sel.bottom, size.width, size.height), dim);
    canvas.drawRect(Rect.fromLTRB(0, sel.top, sel.left, sel.bottom), dim);
    canvas.drawRect(
        Rect.fromLTRB(sel.right, sel.top, size.width, sel.bottom), dim);
    canvas.drawRect(
        sel,
        Paint()
          ..color = const Color(0xFFECB857)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    if (p < 0.999) {
      final cx = sel.right, cy = sel.bottom;
      final ch = Paint()
        ..color = const Color(0xFFFFFFFF)
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(cx - 10, cy), Offset(cx + 10, cy), ch);
      canvas.drawLine(Offset(cx, cy - 10), Offset(cx, cy + 10), ch);
    }
  }

  @override
  bool shouldRepaint(_SnipPainter old) => old.p != p || old.target != target;
}

/// The simulated "online form" the mini picker pastes into: browser chrome +
/// a light vendor-onboarding page with a focused EIN field — the form that
/// (in story time) asks for the number captured in the opener. [hotkeyChip]
/// fades in a Ctrl+Shift+Space key chip on the field, teaching the chord
/// inside the scene. Everything here is scenery; the picker overlaid on it
/// is the real component.
class _FakeEinFormPage extends StatelessWidget {
  final ValueNotifier<String> formValue;
  final ValueNotifier<bool> miniOpen;
  final ValueNotifier<double> miniHeight;
  final ValueNotifier<bool> hotkeyChip;
  final Widget mini;
  const _FakeEinFormPage({
    required this.formValue,
    required this.miniOpen,
    required this.miniHeight,
    required this.hotkeyChip,
    required this.mini,
  });

  static const _ink = Color(0xFF1C2128);
  // The hotkey chip is Relic UI, not the fake page: brand Ink, and the
  // mono the app actually ships.
  static const _chipInk = Color(0xFF111110);
  static const _dim = Color(0xFF6A7280);
  static const _line = Color(0xFFD4D9E0);
  static const _blue = Color(0xFF2563EB);

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Column(children: [
        // Browser chrome.
        Container(
          height: 46,
          color: const Color(0xFF2A2E35),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            for (final c in const [
              Color(0xFFE5655C),
              Color(0xFFE0A63C),
              Color(0xFF57B85F)
            ])
              Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(color: c, shape: BoxShape.circle),
              ),
            const SizedBox(width: 14),
            Expanded(
              child: Container(
                height: 30,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF3A3F47),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Text(
                  'ledgerly.example/vendor-onboarding',
                  style: TextStyle(
                    fontFamily: 'IBMPlexMono',
                    fontSize: 12.5,
                    color: Color(0xFFC9CED6),
                  ),
                ),
              ),
            ),
          ]),
        ),
        // Page.
        Expanded(
          child: Container(
            color: const Color(0xFFF2F4F7),
            // Raised above center so the picker has room to open downward.
            alignment: const Alignment(0, -0.55),
            child: Container(
              width: 460,
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFFFF),
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x1A1C2128),
                    blurRadius: 30,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Set up payouts',
                      style: TextStyle(
                          fontFamily: 'IBMPlexSans',
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: _ink)),
                  const SizedBox(height: 4),
                  const Text('We need your business details for the W-9.',
                      style: TextStyle(
                          fontFamily: 'IBMPlexSans',
                          fontSize: 13,
                          color: _dim)),
                  const SizedBox(height: 20),
                  _label('BUSINESS NAME'),
                  _field(
                    const Text('Maplewood Studio LLC',
                        style: TextStyle(
                            fontFamily: 'IBMPlexSans',
                            fontSize: 14,
                            color: _ink)),
                    focused: false,
                  ),
                  const SizedBox(height: 14),
                  _label('EMPLOYER IDENTIFICATION NUMBER (EIN)'),
                  ValueListenableBuilder<String>(
                    valueListenable: formValue,
                    builder: (_, v, _) => _field(
                      v.isEmpty
                          ? Container(width: 2, height: 18, color: _blue)
                          : Text(v,
                              style: const TextStyle(
                                  fontFamily: 'IBMPlexMono',
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600,
                                  color: _ink)),
                      focused: true,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Container(
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _blue,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('Continue',
                        style: TextStyle(
                            fontFamily: 'IBMPlexSans',
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFFFFFFF))),
                  ),
                ],
              ),
            ),
          ),
        ),
      ]),
      // The chord chip on the focused field: same ink-pill language as the
      // opener's Ctrl+C chip, so the two hotkeys read as one family.
      Positioned(
        left: 588,
        top: 350,
        child: ValueListenableBuilder<bool>(
          valueListenable: hotkeyChip,
          builder: (_, on, _) => AnimatedOpacity(
            opacity: on ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _chipInk,
                borderRadius: BorderRadius.circular(7),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33111110),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: const Text('Ctrl+Shift+Space',
                  style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFF1F1EF))),
            ),
          ),
        ),
      ),
      // The real mini picker, anchored at the focused field's caret. The
      // shipping window RE-HUGS itself to the result count as you type
      // (app/lib/desktop.dart, "re-hug the window to the result count"), so
      // the height is animated here too. A fixed box is what the scene used
      // to do, and it left a dead void under the one surviving row once the
      // query filtered down, which reads as an unfinished surface.
      ValueListenableBuilder<bool>(
        valueListenable: miniOpen,
        builder: (_, open, _) => open
            ? Positioned(
                left: 348,
                top: 384,
                width: 340,
                child: ValueListenableBuilder<double>(
                  valueListenable: miniHeight,
                  builder: (_, h, _) => AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    height: h,
                    child: mini,
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
    ]);
  }

  static Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t,
            style: const TextStyle(
                fontFamily: 'IBMPlexSans',
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
                color: _dim)),
      );

  static Widget _field(Widget child, {required bool focused}) => Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: focused ? _blue : _line,
            width: focused ? 1.6 : 1,
          ),
        ),
        child: child,
      );
}

/// Restores REAL sockets under flutter_test's HTTP mock, proxying every
/// plain-http request to the local health server so the connect scene's
/// "Test" succeeds against the demo address.
class _ProxyToLoopback extends HttpOverrides {
  final int port;
  _ProxyToLoopback(this.port);

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      // super, not HttpClient(): the constructor consults the overrides and
      // would recurse straight back here.
      super.createHttpClient(context)
        ..findProxy = (_) => 'PROXY 127.0.0.1:$port';
}


/// The auto-capture opener's surface: an ordinary third-party support page
/// with three copyable machine facts on it (a serial, a network key, a
/// figure). [sweep] selects one region at a time, [chip] pops the Ctrl+C
/// keycap beside it, and [toast] fires the REAL gem toast, which is the only
/// piece of Relic in the whole scene.
class _FakeDocsPage extends StatelessWidget {
  final String? imagePath;
  final ValueNotifier<int> sweep;
  final ValueNotifier<int> chip;
  final ValueNotifier<int> toast;

  /// The page's download button under the pointer, mid-click.
  final ValueNotifier<bool> pressing;

  /// The folder the download lands in: 0 closed, 1 open, 2 the file is
  /// clicked. The manual is a FILE, and copying a file has to look like
  /// copying a file: you open where it went, you click it, you press Ctrl+C.
  final ValueNotifier<int> explorer;

  /// Slides the real Relic popup in over the page at the end of the beat: the
  /// three things that were copied, already there, nothing filed by hand.
  final ValueNotifier<bool> relicIn;
  final Widget relic;

  const _FakeDocsPage({
    required this.imagePath,
    required this.sweep,
    required this.chip,
    required this.toast,
    required this.explorer,
    required this.pressing,
    required this.relicIn,
    required this.relic,
  });

  static const _ink = Color(0xFF1C2128);
  static const _dim = Color(0xFF6A7280);
  static const _select = Color(0xFFBFDBFE);
  // The keycap is Relic UI, not the fake page: brand Ink and the app's mono.
  static const _chipInk = Color(0xFF111110);

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Column(children: [
        Container(
          height: 46,
          color: const Color(0xFF2A2E35),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            for (final c in const [
              Color(0xFFE5655C),
              Color(0xFFE0A63C),
              Color(0xFF57B85F)
            ])
              Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(color: c, shape: BoxShape.circle),
              ),
            const SizedBox(width: 14),
            Expanded(
              child: Container(
                height: 30,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF3A3F47),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Text('support.aurora.example/s2/setup',
                    style: TextStyle(
                        fontFamily: 'IBMPlexMono',
                        fontSize: 12.5,
                        color: Color(0xFFC9CED6))),
              ),
            ),
          ]),
        ),
        Expanded(
          child: Container(
            color: const Color(0xFFF2F4F7),
            alignment: const Alignment(0, -0.30),
            child: Container(
              width: 560,
              padding: const EdgeInsets.all(30),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFFFF),
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x141C2128),
                    blurRadius: 30,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Aurora S2 · Finish setup',
                      style: TextStyle(
                          fontFamily: 'IBMPlexSans',
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: _ink)),
                  const SizedBox(height: 18),
                  _row('SERIAL NUMBER', 'AS2-9F41-77KD', 1),
                  const SizedBox(height: 14),
                  _row('NETWORK KEY', 'sunlit-harbor-42', 2),
                  const SizedBox(height: 18),
                  _figure(),
                  const SizedBox(height: 20),
                  _downloadButton(),
                ],
              ),
            ),
          ),
        ),
      ]),
      Positioned.fill(child: _explorer()),
      // The product itself, sliding in over the page. Everything above this
      // line is scenery; this is the only Relic UI in the beat besides the
      // toast.
      Positioned(
        right: 0,
        top: 0,
        bottom: 0,
        child: ValueListenableBuilder<bool>(
          valueListenable: relicIn,
          builder: (_, inn, child) => AnimatedSlide(
            offset: inn ? Offset.zero : const Offset(1.06, 0),
            duration: const Duration(milliseconds: 620),
            curve: Curves.easeOutCubic,
            child: child,
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 34),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x4D000000),
                      blurRadius: 46,
                      offset: Offset(0, 18),
                    ),
                  ],
                ),
                child: SizedBox(width: 468, height: 640, child: relic),
              ),
            ),
          ),
        ),
      ),
      // The real toast, bottom-right the way the desktop one sits over the
      // corner of the screen. Keyed by fire count so each copy re-runs it.
      Positioned(
        right: 34,
        bottom: 10,
        width: 150,
        height: 150,
        child: ValueListenableBuilder<int>(
          valueListenable: toast,
          builder: (_, n, _) => n == 0
              ? const SizedBox.shrink()
              : GemToast(key: ValueKey('toast-$n'), onDone: () {}),
        ),
      ),
    ]);
  }

  /// The page's own download control. Nothing to do with Relic — it is how
  /// the manual gets onto the machine in the first place.
  Widget _downloadButton() => ValueListenableBuilder<bool>(
        valueListenable: pressing,
        builder: (_, down, _) => Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: down ? const Color(0xFF1D4ED8) : const Color(0xFF2563EB),
                borderRadius: BorderRadius.circular(7),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(LucideIcons.download, size: 15, color: Colors.white),
                SizedBox(width: 8),
                Text('Download the S2 manual (PDF)',
                    style: TextStyle(
                        fontFamily: 'IBMPlexSans',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.white)),
              ]),
            ),
            if (down)
              const Positioned(left: 118, top: 22, child: _Pointer()),
          ],
        ),
      );

  /// The folder the manual landed in, opened over the page. The file gets
  /// clicked and the Ctrl+C chip pops on the ROW, not on the page: the point
  /// of the beat is that copying a file is the same gesture as copying a line
  /// of text, and it has to be shown as the gesture people actually make.
  Widget _explorer() => ValueListenableBuilder<int>(
        valueListenable: explorer,
        builder: (_, v, _) => IgnorePointer(
          child: AnimatedOpacity(
            opacity: v == 0 ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            child: AnimatedScale(
              scale: v == 0 ? 0.97 : 1,
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              child: Align(
                alignment: const Alignment(-0.14, 0.30),
                child: Container(
                  width: 624,
                  height: 318,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFBFBFD),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: const Color(0xFFD3D7DE)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x331C2128),
                        blurRadius: 46,
                        offset: Offset(0, 20),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(children: [
                      Column(children: [
                        _explorerBar(),
                        _explorerHead(),
                        _fileRow('aurora-s2-manual.pdf', 'Just now', '2.4 MB',
                            badge: 'PDF',
                            badgeColor: const Color(0xFFE5655C),
                            selected: v >= 2),
                        _fileRow('aurora-s2-firmware.zip', '12 Aug', '8.1 MB',
                            badge: 'ZIP', badgeColor: const Color(0xFF8A93A0)),
                        _fileRow('invoice-april.pdf', '9 Aug', '118 KB',
                            badge: 'PDF', badgeColor: const Color(0xFFE5655C)),
                        _fileRow('setup-notes.txt', '2 Aug', '3 KB',
                            badge: 'TXT', badgeColor: const Color(0xFF57B85F)),
                      ]),
                      // The pointer, parked on the row it just clicked.
                      Positioned(
                        left: 212,
                        top: 88,
                        child: AnimatedOpacity(
                          opacity: v >= 2 ? 1 : 0,
                          duration: const Duration(milliseconds: 140),
                          child: const _Pointer(),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  Widget _explorerBar() => Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: const BoxDecoration(
          color: Color(0xFFF1F2F5),
          border: Border(bottom: BorderSide(color: Color(0xFFE1E4EA))),
        ),
        child: Row(children: [
          const Icon(LucideIcons.arrowLeft, size: 15, color: _dim),
          const SizedBox(width: 16),
          const Icon(LucideIcons.arrowRight, size: 15, color: Color(0xFFC0C6CF)),
          const SizedBox(width: 16),
          Expanded(
            child: Container(
              height: 26,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: const Color(0xFFDCE0E6)),
              ),
              child: const Row(children: [
                Icon(LucideIcons.folder, size: 13, color: Color(0xFF8A93A0)),
                SizedBox(width: 9),
                Text('This PC  ›  Downloads',
                    style: TextStyle(
                        fontFamily: 'IBMPlexSans', fontSize: 12, color: _ink)),
              ]),
            ),
          ),
        ]),
      );

  static const _colHead = TextStyle(
      fontFamily: 'IBMPlexSans',
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: _dim);

  Widget _explorerHead() => Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFE8EAEF))),
        ),
        child: const Row(children: [
          Expanded(child: Text('Name', style: _colHead)),
          SizedBox(width: 108, child: Text('Date modified', style: _colHead)),
          SizedBox(
              width: 64,
              child: Text('Size', style: _colHead, textAlign: TextAlign.right)),
        ]),
      );

  Widget _fileRow(String name, String when, String size,
          {required String badge,
          required Color badgeColor,
          bool selected = false}) =>
      Container(
        height: 44,
        margin: const EdgeInsets.fromLTRB(8, 2, 8, 0),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFCFE3FF) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: selected
                  ? const Color(0xFF7FB2F0)
                  : Colors.transparent),
        ),
        child: Row(children: [
          Container(
            width: 25,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: badgeColor,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(badge,
                style: const TextStyle(
                    fontFamily: 'IBMPlexSans',
                    fontSize: 7.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(name,
                style: TextStyle(
                    fontFamily: 'IBMPlexSans',
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: _ink)),
          ),
          SizedBox(
            width: 108,
            child: Text(when,
                style: const TextStyle(
                    fontFamily: 'IBMPlexSans', fontSize: 12, color: _dim)),
          ),
          SizedBox(
            width: 64,
            child: Text(size,
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontFamily: 'IBMPlexSans', fontSize: 12, color: _dim)),
          ),
          if (selected) _chipFor(4),
        ]),
      );

  Widget _figure() => ValueListenableBuilder<int>(
        valueListenable: sweep,
        builder: (_, step, _) => Row(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 320),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: step == 3 ? const Color(0xFF2563EB) : Colors.transparent,
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: imagePath == null
                  ? const SizedBox(width: 168, height: 112)
                  : Image.file(File(imagePath!),
                      width: 168, height: 112, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Text('Pair the speaker from the Aurora app, then keep this '
                'page handy for the network key.',
                style: TextStyle(
                    fontFamily: 'IBMPlexSans',
                    fontSize: 12.5,
                    height: 1.5,
                    color: _dim)),
          ),
          _chipFor(3),
        ]),
      );

  Widget _row(String label, String value, int step) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(label,
                style: const TextStyle(
                    fontFamily: 'IBMPlexSans',
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                    color: _dim)),
          ),
          Row(mainAxisSize: MainAxisSize.min, children: [
            ValueListenableBuilder<int>(
              valueListenable: sweep,
              builder: (_, cur, _) => TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: cur == step ? 1 : 0),
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOut,
                builder: (_, v, _) => Stack(children: [
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: v,
                        heightFactor: 1,
                        child: const ColoredBox(color: _select),
                      ),
                    ),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                    child: Text(value,
                        style: const TextStyle(
                            fontFamily: 'IBMPlexMono',
                            fontSize: 19,
                            fontWeight: FontWeight.w600,
                            color: _ink)),
                  ),
                ]),
              ),
            ),
            _chipFor(step),
          ]),
        ],
      );

  Widget _chipFor(int step) => ValueListenableBuilder<int>(
        valueListenable: chip,
        builder: (_, cur, _) => AnimatedOpacity(
          opacity: cur == step ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: Container(
            margin: const EdgeInsets.only(left: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _chipInk,
              borderRadius: BorderRadius.circular(7),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33111110),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: const Text('Ctrl+C',
                style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFF1F1EF))),
          ),
        ),
      );
}

/// A mouse pointer, drawn rather than iconified so it stays crisp at the
/// scale the compositor blows the frame up to.
class _Pointer extends StatelessWidget {
  const _Pointer();

  @override
  Widget build(BuildContext context) => const SizedBox(
      width: 17, height: 25, child: CustomPaint(painter: _PointerPainter()));
}

class _PointerPainter extends CustomPainter {
  const _PointerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final p = Path()
      ..moveTo(0, 0)
      ..lineTo(0, h * 0.78)
      ..lineTo(w * 0.29, h * 0.585)
      ..lineTo(w * 0.50, h)
      ..lineTo(w * 0.72, h * 0.905)
      ..lineTo(w * 0.51, h * 0.505)
      ..lineTo(w * 0.88, h * 0.475)
      ..close();
    canvas.drawPath(
        p,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..strokeJoin = StrokeJoin.round);
    canvas.drawPath(p, Paint()..color = const Color(0xFF111110));
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

/// A plain desktop behind the popup: the Relic window floats on a wallpaper
/// rather than filling the laptop screen, which is what it actually looks
/// like. The gradient is a wallpaper, not product UI.
class _Desktop extends StatelessWidget {
  final Widget child;
  const _Desktop({required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF2E2E29), Color(0xFF171714)],
        ),
      ),
      child: Center(
        child: SizedBox(width: 520, height: 680, child: child),
      ),
    );
  }
}

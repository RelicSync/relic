import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show FontLoader, LogicalKeyboardKey, MissingPluginException, rootBundle;
import 'package:flutter_test/flutter_test.dart';
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
        ...typing('boarding pass', const Duration(milliseconds: 700),
            seed: 4, baseMs: 80),
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
    final miniOpen = ValueNotifier<bool>(false);
    final miniChip = ValueNotifier<bool>(false);
    final formValue = ValueNotifier<String>('');
    await record(
      name: 'mini',
      build: (c) => _FakeEinFormPage(
        formValue: formValue,
        miniOpen: miniOpen,
        hotkeyChip: miniChip,
        mini: PopupView(
          repo: repo,
          onClose: () {},
          onSettings: () {},
          miniSignal: miniOpen,
          onPick: () {
            formValue.value = '88-1402316';
            miniOpen.value = false;
            miniChip.value = false; // the chord did its job; clear the field
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
                            color: _ink,
                            borderRadius: BorderRadius.circular(7),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x331C2128),
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
                                        fontFamily: 'IBMPlexMono',
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFFF2F4F7))),
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
  final ValueNotifier<bool> hotkeyChip;
  final Widget mini;
  const _FakeEinFormPage({
    required this.formValue,
    required this.miniOpen,
    required this.hotkeyChip,
    required this.mini,
  });

  static const _ink = Color(0xFF1C2128);
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
                color: _ink,
                borderRadius: BorderRadius.circular(7),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x331C2128),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: const Text('Ctrl+Shift+Space',
                  style: TextStyle(
                      fontFamily: 'IBMPlexMono',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFF2F4F7))),
            ),
          ),
        ),
      ),
      // The real mini picker, anchored at the focused field's caret.
      ValueListenableBuilder<bool>(
        valueListenable: miniOpen,
        builder: (_, open, _) => open
            ? Positioned(left: 348, top: 384, width: 340, height: 196, child: mini)
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

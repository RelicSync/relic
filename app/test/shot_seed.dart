import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:relic_app/data/repo.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/widgets/chrome.dart' show Scope;

/// MemoryRepo seeded with store-quality demo content (mixed vault + history)
/// and synthesized photos. Shared by the Play/website screenshot harnesses and
/// the demo-video frame harness. Seeding goes through the public [restore]
/// adder since the backing list is private to MemoryRepo.
class StoreShotRepo extends MemoryRepo {
  /// Website desktop pass only: appends one fictional secret-tagged item
  /// (masked row). The Play-store seed keeps the default (false) so the extra
  /// item never appears in the mobile shots.
  final bool includeSecret;

  /// Demo-video pass only: appends extra items (a second synthesized
  /// "screenshot" photo with OCR-style note text, machine-tagged rows that
  /// light up the collection facet chips, a file row). The Play/website
  /// screenshot seeds keep the default (false) so published stills never
  /// change under this file.
  final bool extended;

  /// Demo-video story arc: with [extended], the curated EIN item is normally
  /// OMITTED (the capture scene copies it in live, so it must not pre-exist);
  /// [agedEin] instead includes it aged ~8 months for the recall scene's
  /// "months later, still there" search. Non-extended (store stills) keeps
  /// the original recent EIN row untouched.
  final bool agedEin;

  StoreShotRepo({
    this.includeSecret = false,
    this.extended = false,
    this.agedEin = false,
  });

  String? _imagePath;
  String? _flightPath;
  String? _manualPath;

  /// The painted device-manual screenshot, so the demo-video "screenshot on
  /// your desktop" scene can display the very same image that then lands on the
  /// phone (visual continuity for the cross-device beat).
  String? get manualPath => _manualPath;

  // Demo-video share beat: a real ShareLink without touching the network, so
  // the ShareDialog reaches its created-link state (URL + QR + expiry caption)
  // deterministically. Only the extended (video) seed enables sharing.
  @override
  bool get canShare => extended;

  @override
  Future<ShareLink> createShare(
    Relic r, {
    required Duration ttl,
    required bool oneTime,
  }) async {
    // A beat of "Encrypting…" before the link resolves.
    await Future<void>.delayed(const Duration(milliseconds: 420));
    final expires =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000) + ttl.inSeconds;
    return ShareLink(
      'https://relic.space/s/9f2ac4e1b7#k=Xr7Qm2',
      expiresAt: expires,
      oneTime: oneTime,
    );
  }

  /// Painted screenshot variants for the generated legacy-vault photos, so
  /// scrolling doesn't repeat one thumbnail. Index = uid suffix % length.
  final List<String> _variants = [];

  int get _nowS => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  @override
  String? localImagePath(Relic r) {
    if (r.kind != Kind.photo) return super.localImagePath(r);
    if (r.uid == 'flight') return _flightPath;
    if (r.uid == 'manual') return _manualPath;
    if (r.uid.startsWith('gp') && _variants.isNotEmpty) {
      final i = int.tryParse(r.uid.substring(2)) ?? 0;
      return _variants[i % _variants.length];
    }
    return _imagePath;
  }

  /// Paint a portrait paper receipt so image rows and the image edit dialog
  /// read as a "receipt screenshot" (fictional store, mono type, fake
  /// barcode). With [extended], also paints a dark boarding-pass "app
  /// screenshot". Must run inside runAsync (real event loop) so the PNG
  /// encodes complete.
  Future<void> preparePhoto() async {
    _imagePath = await _paintReceipt();
    if (extended) {
      _flightPath = await _paintBoardingPass();
      _manualPath = await _paintManual();
      _variants.addAll([
        await _paintReceiptVariant('NORTHGATE HARDWARE', 'Beaverton OR', [
          ('WOOD SCREWS 100CT', '8.49'),
          ('WALL ANCHORS', '5.29'),
          ('LEVEL 24IN', '21.00'),
        ], '34.78', 11),
        await _paintReceiptVariant('LUNA COFFEE ROASTERS', 'Portland OR', [
          ('ETHIOPIA 12OZ', '18.50'),
          ('FILTERS 100', '6.25'),
        ], '24.75', 12),
        await _paintReceiptVariant('PIONEER PARKING', 'Portland OR', [
          ('ZONE C · 4 HRS', '14.00'),
        ], '14.00', 13),
        await _paintPassVariant('SEA', 'DEN', 'CA 2210', 'C4', '22A', 'RM8-1LK', 21),
        await _paintPassVariant('PDX', 'SFO', 'CA 884', 'B7', '9F', 'TN2-9WV', 22),
        await _paintCodeShot('deploy.yml', [
          'name: deploy',
          'on:',
          '  push:',
          '    branches: [main]',
          'jobs:',
          '  build:',
          '    runs-on: ubuntu-24.04',
          '    steps:',
          '      - uses: actions/checkout@v4',
          '      - run: npm ci && npm run build',
        ], 31),
        await _paintCodeShot('tiers.ts', [
          'export const TIERS = {',
          "  free: { shareBytes: 5e6 },",
          "  pro:  { shareBytes: 25e9 },",
          "  max:  { shareBytes: 100e9 },",
          '} as const',
          '',
          'export function capFor(tier: Tier) {',
          '  return TIERS[tier].shareBytes',
          '}',
        ], 32),
        await _paintChatShot(41),
      ]);
    }

    // Pre-decode into the ImageCache so the very first shot's Image.file
    // resolves synchronously (a pending decode paints nothing and gets
    // evicted when the warmup tree is torn down). Must run inside runAsync.
    // Two keys per image: the plain FileImage (result rows) and the
    // cacheWidth: 900 ResizeImage the EditDialog's image well uses.
    for (final p in [_imagePath, _flightPath, _manualPath, ..._variants]) {
      if (p == null) continue;
      final f = File(p);
      await _preDecode(FileImage(f));
      await _preDecode(ResizeImage.resizeIfNeeded(900, null, FileImage(f)));
    }
  }

  static Future<void> _preDecode(ImageProvider provider) async {
    final stream = provider.resolve(ImageConfiguration.empty);
    final done = Completer<void>();
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      info.dispose();
      if (!done.isCompleted) done.complete();
    }, onError: (e, _) {
      if (!done.isCompleted) done.completeError(e);
    });
    stream.addListener(listener);
    await done.future;
    stream.removeListener(listener);
  }

  static Future<String> _writePng(ui.Image img, String name) async {
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    final dir = Directory.systemTemp.createTempSync('relic_store_shot_');
    final f = File('${dir.path}/$name');
    f.writeAsBytesSync(bytes!.buffer.asUint8List());
    return f.path;
  }

  static Future<String> _paintReceipt() async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    const w = 900.0, h = 1260.0;
    const paper = Color(0xFFFAF7F0);
    const ink = Color(0xFF3A362E);

    // Paper (full bleed).
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, w, h),
      Paint()..color = paper,
    );

    void line(
      String s,
      double y, {
      double size = 38,
      FontWeight weight = FontWeight.w500,
      bool center = false,
    }) {
      final tp = TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(
            fontFamily: 'IBMPlexMono',
            fontSize: size,
            fontWeight: weight,
            color: ink,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(center ? (w - tp.width) / 2 : 96, y));
    }

    void dashes(double y) {
      final p = Paint()..color = ink;
      for (var x = 96.0; x < w - 96; x += 26) {
        canvas.drawRect(Rect.fromLTWH(x, y, 15, 3), p);
      }
    }

    line('CASCADE OFFICE SUPPLY', 64,
        size: 44, weight: FontWeight.w700, center: true);
    line('412 Alder St, Portland OR', 132, size: 34, center: true);
    dashes(212);
    line('TASK CHAIR  BLK   189.00', 254);
    line('DESK MAT          24.50', 314);
    line('FELT PADS 8CT      6.99', 374);
    dashes(452);
    line('SUBTOTAL         220.49', 494);
    line('TAX                0.00', 554);
    line('TOTAL            220.49', 614, weight: FontWeight.w700);
    dashes(692);
    line('VISA ****4482', 734);
    line('THANK YOU', 812, center: true);

    // Fake barcode: a row of random-width vertical bars.
    final rnd = math.Random(42);
    final bar = Paint()..color = const Color(0xFF14120E);
    var bx = 160.0;
    while (bx < w - 160) {
      final bw = 4.0 + rnd.nextInt(10);
      if (rnd.nextDouble() < 0.62) {
        canvas.drawRect(Rect.fromLTWH(bx, 940, bw, 170), bar);
      }
      bx += bw + 5;
    }

    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    return _writePng(img, 'trail-photo.png');
  }

  /// A dark airline-app "screenshot": boarding pass card on a phone-dark
  /// backdrop. Fictional airline, mono type, fake QR block. The matching
  /// relic carries the pass text in its note (standing in for OCR text) so
  /// searching e.g. "boarding" surfaces an image row.
  static Future<String> _paintBoardingPass() async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    const w = 900.0, h = 1260.0;
    const bg = Color(0xFF101418);
    const card = Color(0xFF1B2129);
    const ink = Color(0xFFE8EDF2);
    const dim = Color(0xFF8B96A3);
    const brand = Color(0xFF4FA3E3);

    canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = bg);
    final cardRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(70, 90, w - 140, h - 180),
      const Radius.circular(28),
    );
    canvas.drawRRect(cardRect, Paint()..color = card);

    void text(
      String s,
      double x,
      double y, {
      double size = 36,
      FontWeight weight = FontWeight.w500,
      Color color = ink,
      bool mono = true,
      bool center = false,
    }) {
      final tp = TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(
            fontFamily: mono ? 'IBMPlexMono' : 'IBMPlexSans',
            fontSize: size,
            fontWeight: weight,
            color: color,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(center ? (w - tp.width) / 2 : x, y));
    }

    text('CONDOR AIR', 0, 150,
        size: 40, weight: FontWeight.w700, color: brand, center: true);
    text('BOARDING PASS', 0, 210, size: 28, color: dim, center: true);
    text('PDX', 130, 300, size: 96, weight: FontWeight.w700);
    text('SEA', w - 130 - 3 * 58.0, 300, size: 96, weight: FontWeight.w700);
    // Route arrow.
    final arrow = Paint()
      ..color = dim
      ..strokeWidth = 5;
    canvas.drawLine(const Offset(400, 360), const Offset(500, 360), arrow);
    canvas.drawLine(const Offset(500, 360), const Offset(478, 342), arrow);
    canvas.drawLine(const Offset(500, 360), const Offset(478, 378), arrow);

    text('FLIGHT', 130, 470, size: 24, color: dim);
    text('CA 1042', 130, 506, size: 40, weight: FontWeight.w600);
    text('GATE', 420, 470, size: 24, color: dim);
    text('B12', 420, 506, size: 40, weight: FontWeight.w600);
    text('SEAT', 640, 470, size: 24, color: dim);
    text('14C', 640, 506, size: 40, weight: FontWeight.w600);
    text('BOARDS', 130, 600, size: 24, color: dim);
    text('9:10 AM', 130, 636, size: 40, weight: FontWeight.w600);
    text('CONF', 420, 600, size: 24, color: dim);
    text('QX7-4NP', 420, 636, size: 40, weight: FontWeight.w600);

    // Fake QR: seeded random block grid.
    final rnd = math.Random(7);
    final qr = Paint()..color = ink;
    const cell = 16.0;
    const qx = (w - 21 * cell) / 2, qy = 760.0;
    for (var r = 0; r < 21; r++) {
      for (var c = 0; c < 21; c++) {
        final finder = (r < 5 && c < 5) ||
            (r < 5 && c > 15) ||
            (r > 15 && c < 5);
        final on = finder
            ? (r == 0 || r == 4 || c == 0 || c == 4 || (r == 2 && c == 2)) ||
                (r == 0 || r == 4 || c == 16 || c == 20 || (r == 2 && c == 18)) &&
                    c > 15 ||
                (r == 16 || r == 20 || c == 0 || c == 4 || (r == 18 && c == 2)) &&
                    r > 15
            : rnd.nextDouble() < 0.45;
        if (on) {
          canvas.drawRect(
              Rect.fromLTWH(qx + c * cell, qy + r * cell, cell - 2, cell - 2),
              qr);
        }
      }
    }
    text('CONDOR.EXAMPLE/CHECKIN', 0, 1130, size: 22, color: dim, center: true);

    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    return _writePng(img, 'flight-pass.png');
  }

  /// The OCR text of the device-manual screenshot, kept in one place so the
  /// painted image and the relic's searchable/extracted `content` stay in sync
  /// (the OCR beat opens a screenshot and shows this exact text in the modal).
  static const manualOcrText =
      'AURORA S2 Wireless Speaker · Quick Start Guide\n'
      '1. Hold Power for 3 seconds until the ring glows amber.\n'
      '2. Open the Aurora app and tap Add Device.\n'
      '3. Enter your Wi-Fi password when the ring pulses.\n'
      '4. Say "Aurora, play music" to test the speaker.\n'
      'Reset: hold Volume down and Power together for 10 seconds.';

  /// A device-manual "screenshot": a light quick-start guide with a small
  /// line-art speaker diagram and numbered setup steps — the kind of reference
  /// you screenshot on your computer and want on your phone later. Fictional
  /// product (no real brand). Text mirrors [manualOcrText].
  static Future<String> _paintManual() async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    const w = 900.0, h = 1260.0;
    const page = Color(0xFFF3F5F8);
    const card = Color(0xFFFFFFFF);
    const ink = Color(0xFF1C2128);
    const dim = Color(0xFF6A7280);
    const accent = Color(0xFFDAA43E);
    const device = Color(0xFF2A2E35);

    canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = page);

    void text(
      String s,
      double x,
      double y, {
      double size = 30,
      FontWeight weight = FontWeight.w500,
      Color color = ink,
      bool mono = false,
      double? maxWidth,
    }) {
      final tp = TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(
            fontFamily: mono ? 'IBMPlexMono' : 'IBMPlexSans',
            fontSize: size,
            fontWeight: weight,
            color: color,
            height: 1.35,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxWidth ?? (w - 120));
      tp.paint(canvas, Offset(x, y));
    }

    // Header.
    text('AURORA S2', 60, 66, size: 40, weight: FontWeight.w700);
    text('Wireless Speaker · Quick Start Guide', 60, 122,
        size: 26, color: dim);

    // Illustration panel with a simple line-art speaker.
    final panel = RRect.fromRectAndRadius(
        const Rect.fromLTWH(60, 190, w - 120, 360), const Radius.circular(24));
    canvas.drawRRect(panel, Paint()..color = card);
    canvas.drawRRect(
        panel,
        Paint()
          ..color = const Color(0xFFE4E8ED)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    // Speaker body (rounded pill) centered in the panel.
    const cx = w / 2;
    final body = RRect.fromRectAndRadius(
        const Rect.fromLTWH(cx - 90, 240, 180, 250), const Radius.circular(90));
    canvas.drawRRect(body, Paint()..color = device);
    // Top control ring (amber) + power dot.
    canvas.drawCircle(const Offset(cx, 300), 44,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8);
    canvas.drawCircle(const Offset(cx, 300), 12, Paint()..color = accent);
    // Speaker grille lines.
    final grille = Paint()
      ..color = const Color(0xFF565B63)
      ..strokeWidth = 4;
    for (var gy = 380.0; gy <= 460; gy += 20) {
      canvas.drawLine(Offset(cx - 54, gy), Offset(cx + 54, gy), grille);
    }
    // Callout labels with leader lines.
    void callout(String label, Offset from, Offset to, {bool left = true}) {
      final p = Paint()
        ..color = dim
        ..strokeWidth = 2;
      canvas.drawLine(from, to, p);
      canvas.drawCircle(from, 4, Paint()..color = accent);
      final tp = TextPainter(
        text: TextSpan(
            text: label,
            style: const TextStyle(
                fontFamily: 'IBMPlexSans', fontSize: 22, color: ink)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas,
          Offset(left ? to.dx - tp.width - 10 : to.dx + 10, to.dy - 14));
    }

    callout('Power', const Offset(cx, 300), const Offset(cx - 150, 260));
    callout('Volume', const Offset(cx - 40, 470), const Offset(cx - 150, 470));
    callout('LED ring', const Offset(cx + 30, 300), const Offset(cx + 150, 260),
        left: false);
    callout('Mic', const Offset(cx + 40, 470), const Offset(cx + 150, 470),
        left: false);

    // Numbered setup steps.
    var y = 610.0;
    const steps = [
      'Hold Power for 3 seconds until the ring glows amber.',
      'Open the Aurora app and tap Add Device.',
      'Enter your Wi-Fi password when the ring pulses.',
      'Say "Aurora, play music" to test the speaker.',
    ];
    for (var i = 0; i < steps.length; i++) {
      canvas.drawCircle(Offset(84, y + 18), 22, Paint()..color = accent);
      final num = TextPainter(
        text: TextSpan(
            text: '${i + 1}',
            style: const TextStyle(
                fontFamily: 'IBMPlexSans',
                fontSize: 26,
                fontWeight: FontWeight.w700,
                color: Color(0xFFFFFFFF))),
        textDirection: TextDirection.ltr,
      )..layout();
      num.paint(canvas, Offset(84 - num.width / 2, y + 3));
      text(steps[i], 132, y, size: 29, weight: FontWeight.w500, maxWidth: 700);
      y += 108;
    }

    // Reset note.
    y += 6;
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(60, y, w - 120, 96), const Radius.circular(16)),
        Paint()..color = const Color(0xFFEDEFF3));
    text('RESET', 84, y + 20, size: 20, weight: FontWeight.w700, color: dim);
    text('Hold Volume down and Power together for 10 seconds.', 84, y + 48,
        size: 24, color: ink, maxWidth: 720);

    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    return _writePng(img, 'manual.png');
  }

  /// A parameterized paper receipt (same style as the curated one).
  static Future<String> _paintReceiptVariant(
    String store,
    String addr,
    List<(String, String)> lines,
    String total,
    int seed,
  ) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    const w = 900.0, h = 1260.0;
    canvas.drawRect(const Rect.fromLTWH(0, 0, w, h),
        Paint()..color = const Color(0xFFFAF7F0));
    const ink = Color(0xFF3A362E);

    void line(String s, double y,
        {double size = 38,
        FontWeight weight = FontWeight.w500,
        bool center = false}) {
      final tp = TextPainter(
        text: TextSpan(
            text: s,
            style: TextStyle(
                fontFamily: 'IBMPlexMono',
                fontSize: size,
                fontWeight: weight,
                color: ink)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(center ? (w - tp.width) / 2 : 96, y));
    }

    void dashes(double y) {
      final p = Paint()..color = ink;
      for (var x = 96.0; x < w - 96; x += 26) {
        canvas.drawRect(Rect.fromLTWH(x, y, 15, 3), p);
      }
    }

    line(store, 64, size: 42, weight: FontWeight.w700, center: true);
    line(addr, 132, size: 34, center: true);
    dashes(212);
    var y = 254.0;
    for (final (name, price) in lines) {
      line('${name.padRight(18)}$price', y);
      y += 60;
    }
    dashes(y + 18);
    line('TOTAL${''.padRight(13)}$total', y + 60, weight: FontWeight.w700);
    line('THANK YOU', y + 160, center: true);

    final rnd = math.Random(seed);
    final bar = Paint()..color = const Color(0xFF14120E);
    var bx = 160.0;
    while (bx < w - 160) {
      final bw = 4.0 + rnd.nextInt(10);
      if (rnd.nextDouble() < 0.62) {
        canvas.drawRect(Rect.fromLTWH(bx, 940, bw, 170), bar);
      }
      bx += bw + 5;
    }
    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    return _writePng(img, 'receipt-$seed.png');
  }

  /// A recolored boarding-pass variant (route/flight/seat differ).
  static Future<String> _paintPassVariant(
    String from,
    String to,
    String flight,
    String gate,
    String seat,
    String conf,
    int seed,
  ) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    const w = 900.0, h = 1260.0;
    const bg = Color(0xFF101418);
    const card = Color(0xFF1B2129);
    const ink = Color(0xFFE8EDF2);
    const dim = Color(0xFF8B96A3);
    const brand = Color(0xFF4FA3E3);

    canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = bg);
    canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(70, 90, w - 140, h - 180),
            const Radius.circular(28)),
        Paint()..color = card);

    void text(String s, double x, double y,
        {double size = 36,
        FontWeight weight = FontWeight.w500,
        Color color = ink,
        bool center = false}) {
      final tp = TextPainter(
        text: TextSpan(
            text: s,
            style: TextStyle(
                fontFamily: 'IBMPlexMono',
                fontSize: size,
                fontWeight: weight,
                color: color)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(center ? (w - tp.width) / 2 : x, y));
    }

    text('CONDOR AIR', 0, 150,
        size: 40, weight: FontWeight.w700, color: brand, center: true);
    text('BOARDING PASS', 0, 210, size: 28, color: dim, center: true);
    text(from, 130, 300, size: 96, weight: FontWeight.w700);
    text(to, w - 130 - 3 * 58.0, 300, size: 96, weight: FontWeight.w700);
    text('FLIGHT', 130, 470, size: 24, color: dim);
    text(flight, 130, 506, size: 40, weight: FontWeight.w600);
    text('GATE', 420, 470, size: 24, color: dim);
    text(gate, 420, 506, size: 40, weight: FontWeight.w600);
    text('SEAT', 640, 470, size: 24, color: dim);
    text(seat, 640, 506, size: 40, weight: FontWeight.w600);
    text('CONF', 130, 600, size: 24, color: dim);
    text(conf, 130, 636, size: 40, weight: FontWeight.w600);

    final rnd = math.Random(seed);
    final qr = Paint()..color = ink;
    const cell = 16.0;
    const qx = (w - 21 * cell) / 2, qy = 760.0;
    for (var r = 0; r < 21; r++) {
      for (var c = 0; c < 21; c++) {
        if (rnd.nextDouble() < 0.45) {
          canvas.drawRect(
              Rect.fromLTWH(qx + c * cell, qy + r * cell, cell - 2, cell - 2),
              qr);
        }
      }
    }
    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    return _writePng(img, 'pass-$seed.png');
  }

  /// A dark code-editor "screenshot" (title bar + line numbers + mono code).
  static Future<String> _paintCodeShot(
      String filename, List<String> lines, int seed) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    const w = 1200.0, h = 800.0;
    canvas.drawRect(const Rect.fromLTWH(0, 0, w, h),
        Paint()..color = const Color(0xFF14181D));
    canvas.drawRect(const Rect.fromLTWH(0, 0, w, 64),
        Paint()..color = const Color(0xFF1B2026));
    // Traffic dots.
    for (final (i, c) in const [
      (0, Color(0xFFE5655C)),
      (1, Color(0xFFE0A63C)),
      (2, Color(0xFF57B85F)),
    ]) {
      canvas.drawCircle(Offset(36.0 + i * 34, 32), 9, Paint()..color = c);
    }
    void text(String s, double x, double y, Color color, {double size = 26}) {
      final tp = TextPainter(
        text: TextSpan(
            text: s,
            style: TextStyle(
                fontFamily: 'IBMPlexMono', fontSize: size, color: color)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x, y));
    }

    text(filename, 150, 20, const Color(0xFF9AA5B0), size: 24);
    const palette = [
      Color(0xFFC792EA),
      Color(0xFF82AAFF),
      Color(0xFFC3E88D),
      Color(0xFFD6DEEB),
      Color(0xFFECC48D),
    ];
    final rnd = math.Random(seed);
    for (var i = 0; i < lines.length; i++) {
      final y = 100.0 + i * 52;
      text('${i + 1}'.padLeft(2), 28, y, const Color(0xFF3E4750));
      text(lines[i], 100, y, palette[rnd.nextInt(palette.length)]);
    }
    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    return _writePng(img, 'code-$seed.png');
  }

  /// A light chat-app "screenshot" (bubbles left/right).
  static Future<String> _paintChatShot(int seed) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    const w = 900.0, h = 1100.0;
    canvas.drawRect(const Rect.fromLTWH(0, 0, w, h),
        Paint()..color = const Color(0xFFF0F2F5));
    const msgs = [
      (false, 'Gate code for the studio?'),
      (true, '#4482, same as the mailbox'),
      (false, 'Perfect. Loading dock or front?'),
      (true, 'Front. Ring twice, ask for Dana'),
      (false, 'On my way, 20 min out'),
    ];
    var y = 80.0;
    for (final (mine, s) in msgs) {
      final tp = TextPainter(
        text: TextSpan(
            text: s,
            style: const TextStyle(
                fontFamily: 'IBMPlexSans',
                fontSize: 30,
                color: Color(0xFF1B1E23))),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 520);
      final bw = tp.width + 56, bh = tp.height + 44;
      final x = mine ? w - 60 - bw : 60.0;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, bw, bh), const Radius.circular(26)),
        Paint()..color = mine ? const Color(0xFFCDE4C6) : const Color(0xFFFFFFFF),
      );
      tp.paint(canvas, Offset(x + 28, y + 22));
      y += bh + 26;
    }
    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    return _writePng(img, 'chat-$seed.png');
  }

  @override
  Future<void> load() async {
    final now = _nowS;
    Relic mk(
      String uid,
      Kind kind,
      int agoSecs, {
      String? content,
      String? title,
      String? note,
      String? preview,
      String? device,
      String? filename,
      bool promoted = false,
      List<String> tags = const [],
      List<String> userTags = const [],
      int bytes = 0,
      String? blobKey,
    }) =>
        Relic(
          uid: uid,
          createdAt: now - agoSecs,
          updatedAt: now - agoSecs,
          kind: kind,
          source: Source.clipboard,
          promoted: promoted,
          byteSize: bytes,
          device: device,
          blobKey: blobKey,
          filename: filename,
          tags: tags,
          userTags: userTags,
          title: title,
          note: note,
          content: content,
          preview: preview ?? content,
        );

    final items = <Relic>[
      if (!extended || agedEin)
        mk(
          'ein',
          Kind.string,
          // Extended (video recall scene): ~8 months old, so the search-it-up
          // beat shows a genuinely aged row. Store stills: recent, top row.
          extended ? 20800000 : 150,
          // Short on purpose: the selected row's action cluster leaves little
          // title width at phone size, and a mid-word fade reads like a bug.
          title: 'EIN',
          content: '88-1402316',
          note: 'Maplewood Studio LLC. Use for W-9s and bank forms.',
          promoted: true,
          userTags: ['business', 'tax'],
          device: 'Windows PC',
        ),
      if (includeSecret)
        mk(
          'stripekey',
          Kind.string,
          700,
          title: 'Stripe key',
          content:
              'sk_live_51NxKq2Lr8pVWm4YtCd7uHb3Jf9AzEs6oGnMxQw1TyU0iCr5vXe2k',
          tags: ['secret'],
          promoted: true,
          device: 'Windows PC',
        ),
      mk(
        'meet',
        Kind.string,
        1500,
        content: 'https://meet.google.com/kxv-dqti-hjy',
        device: 'Windows PC',
      ),
      mk(
        'photo',
        Kind.photo,
        2700,
        title: 'Office chair receipt',
        bytes: 1240000,
        blobKey: 'demo',
        // No 'receipt' auto tag: the photo row's meta line has ~123px at
        // phone size and two chips ('business' + '#receipt') overflow it.
        userTags: ['business'],
        device: 'Pixel 9',
        promoted: true,
      ),
      mk(
        'phone',
        Kind.string,
        5400,
        title: 'Business line',
        content: '+1 (503) 555-0142',
        promoted: true,
        userTags: ['business'],
        device: 'Windows PC',
      ),
      mk(
        'tracking',
        Kind.string,
        9000,
        content: 'UPS 1Z 999 AA1 01 2345 6784',
        device: 'Pixel 9',
      ),
      mk(
        'address',
        Kind.string,
        14400,
        title: 'Registered agent address',
        content: '742 Maplewood Ave, Suite 3B, Portland, OR 97205',
        promoted: true,
        device: 'Windows PC',
      ),
      mk(
        'git',
        Kind.string,
        26000,
        content: 'git rebase --onto main feature~3 feature',
        device: 'Windows PC',
      ),
      mk(
        'gate',
        Kind.string,
        90000,
        title: 'Storage unit gate code',
        content: '#4482',
        promoted: true,
        device: 'Pixel 9',
      ),
      mk(
        'insurance',
        Kind.string,
        180000,
        title: 'Dental insurance',
        content: 'Group GRP-88214-OR · Member 004-2213-887',
        promoted: true,
        device: 'Windows PC',
      ),
      // ------------------------------------------------------------------
      // Demo-video extras. Machine tags here are the ones the collection
      // facet strip counts (popup _kCollections), so the chips populate.
      if (extended) ...[
        mk(
          'flight',
          Kind.photo,
          400,
          title: 'Boarding pass',
          // sift's OCR text lives in `content` so it's both searchable AND
          // shown in the viewer's "Extracted text" section (the OCR beat opens
          // this screenshot to reveal the recognized text).
          content:
              'CONDOR AIR boarding pass PDX SEA flight CA 1042 gate B12 seat 14C boards 9:10 AM confirmation QX7-4NP',
          bytes: 860000,
          blobKey: 'demo-flight',
          tags: ['screenshot'],
          device: 'Pixel 9',
        ),
        mk(
          'repo',
          Kind.string,
          1100,
          content: 'https://github.com/jordan-gibbs/relic',
          tags: ['url'],
          device: 'Windows PC',
        ),
        mk(
          'compose',
          Kind.string,
          2000,
          title: 'Self-host server',
          content: 'docker compose up -d relic-server',
          tags: ['code'],
          promoted: true,
          device: 'Windows PC',
        ),
        mk(
          'amber',
          Kind.string,
          3600,
          title: 'Brand amber',
          content: '#DAA43E',
          tags: ['color'],
          promoted: true,
          device: 'Windows PC',
        ),
        mk(
          'hotel',
          Kind.string,
          7000,
          title: 'Hotel receipt',
          content: 'Fairhaven Inn · 2 nights · \$189.00 · folio 55213',
          tags: ['receipt', 'currency'],
          device: 'Pixel 9',
        ),
        mk(
          'invoice',
          Kind.file,
          12000,
          title: 'Studio invoice',
          filename: 'maplewood-invoice-0042.pdf',
          bytes: 182000,
          blobKey: 'demo-invoice',
          tags: ['document'],
          promoted: true,
          device: 'Windows PC',
        ),
        mk(
          'confirm',
          Kind.string,
          2400,
          title: 'Flight confirmation',
          content: 'QX7-4NP',
          promoted: true,
          device: 'Pixel 9',
        ),
        mk(
          'wifi',
          Kind.string,
          20000,
          title: 'Studio Wi-Fi',
          content: 'relic-guest / amber4482',
          device: 'Windows PC',
        ),
      ],
    ];
    for (final r in items) {
      await restore(r);
    }
    if (extended) {
      for (final r in _legacyVault(mk)) {
        await restore(r);
      }
    }
    await setQuery('', Scope.all);
  }

  /// ~8,000 fabricated items spanning two years, so the vault reads as a
  /// long-lived daily driver: facet chips get real counts, scrolling never
  /// bottoms out, and machine tags (#url/#code/#screenshot/...) are
  /// everywhere. Deterministic (seeded) so frames are reproducible. Word
  /// blocklist: nothing here may contain "office", "chair", "boarding",
  /// "pass", "meet", or "qx" — those belong to the scripted search scenes.
  List<Relic> _legacyVault(
    Relic Function(
      String uid,
      Kind kind,
      int agoSecs, {
      String? content,
      String? title,
      String? note,
      String? preview,
      String? device,
      String? filename,
      bool promoted,
      List<String> tags,
      List<String> userTags,
      int bytes,
      String? blobKey,
    }) mk,
  ) {
    final rnd = math.Random(20260721);
    T pick<T>(List<T> l) => l[rnd.nextInt(l.length)];
    String digits(int n) =>
        List.generate(n, (_) => rnd.nextInt(10)).join();

    const orgs = ['vercel', 'cloudflare', 'flutter', 'supabase', 'tailwindlabs',
      'ziglang', 'astral-sh', 'denoland', 'sqlite', 'grafana'];
    const repos = ['edge-runtime', 'workers-sdk', 'engine', 'realtime', 'cli',
      'router', 'toolchain', 'docs', 'examples', 'bench'];
    const svcs = ['stripe', 'resend', 'sentry', 'notion', 'linear', 'figma'];
    const cmds = [
      'git stash pop',
      'git log --oneline -20',
      'docker compose logs -f worker',
      'npx wrangler d1 migrations apply prod',
      'flutter build windows --release',
      'npm run build && npm run preview',
      'kubectl rollout status deploy/api',
      'ssh deploy@axiom-vps',
      'rg -n "TODO" src/',
      'ffprobe -show_streams in.mp4',
      'tar -xzf backup-2025.tar.gz',
      'python -m http.server 8080',
    ];
    const noteLines = [
      'Ask Dana about the retainer before Friday',
      'Renew the LLC registration in March',
      'Dentist moved to Tuesday 9:30',
      'Warranty claim number for the standing desk',
      'Landlord said paint swatches due by the 15th',
      'Book the cabin for the long weekend',
      'Return the HDMI capture card',
      'Quarterly estimated tax due June 15',
    ];
    const titles = [
      'Server IP', 'Locker combo', 'VIN number', 'Passport number',
      'Frequent flyer', 'Library card', 'Warranty ID', 'Model number',
      'License plate', 'Blood donor ID', 'Gym door code', 'Printer WPS pin',
    ];
    const streets = ['Alder', 'Burnside', 'Couch', 'Division', 'Hawthorne',
      'Belmont', 'Killingsworth', 'Fremont'];
    const domains = ['maplewood.studio', 'gmail.com', 'fastmail.com',
      'condorair.example', 'northgate.example'];
    const names = ['dana', 'sam', 'jordan', 'alex', 'casey', 'robin', 'kit'];
    const docs = ['quarterly-report', 'lease-agreement', 'w9-2025',
      'insurance-card', 'onboarding-deck', 'brand-guide', 'invoice-0', 'sow-final'];
    const exts = ['pdf', 'docx', 'xlsx', 'zip', 'pptx'];
    // Variant index -> content-appropriate tags + title (order matches
    // _variants). Titles avoid the scripted-search blocklist words.
    const photoTags = [
      ['screenshot', 'receipt'],
      ['screenshot', 'receipt'],
      ['screenshot', 'receipt'],
      ['screenshot'],
      ['screenshot'],
      ['screenshot', 'code'],
      ['screenshot', 'code'],
      ['screenshot', 'chat'],
    ];
    const photoTitles = [
      'Hardware receipt',
      'Coffee receipt',
      'Parking receipt',
      'Flight to Denver',
      'Flight to SFO',
      'deploy.yml',
      'tiers.ts',
      'Chat with Dana',
    ];

    (String?, String, List<String>) genString() {
      switch (rnd.nextInt(12)) {
        case 0:
          return (null, 'https://github.com/${pick(orgs)}/${pick(repos)}', ['url']);
        case 1:
          return (null, 'https://${pick(svcs)}.com/docs/${pick(repos)}', ['url']);
        case 2:
          return (null, pick(cmds), ['code']);
        case 3:
          final hex = (rnd.nextInt(0xFFFFFF) | 0x202020)
              .toRadixString(16)
              .padLeft(6, '0')
              .toUpperCase();
          return (null, '#$hex', ['color']);
        case 4:
          return (null, '${pick(names)}@${pick(domains)}', ['email']);
        case 5:
          return ('OTP', '${digits(3)} ${digits(3)}', ['otp']);
        case 6:
          return (null, '1Z ${digits(3)} ${digits(3)} ${digits(2)} ${digits(4)} ${digits(3)}', ['tracking']);
        case 7:
          return (null, '\$${rnd.nextInt(400) + 8}.${digits(2)} · ${pick(['refund', 'deposit', 'invoice', 'split'])}', ['currency']);
        case 8:
          return (null, '${rnd.nextInt(4800) + 100} ${pick(streets)} St, Portland, OR 972${digits(2)}', ['address']);
        case 9:
          return (null, '+1 (503) 555-0${digits(3)}', const []);
        case 10:
          return (null, pick(noteLines), ['todo']);
        default:
          return (pick(titles), '${digits(4)}-${digits(4)}-${digits(2)}', const []);
      }
    }

    final out = <Relic>[];
    const total = 8000;
    for (var i = 0; i < total; i++) {
      // Ages from ~5h to ~2y, denser toward now (quadratic spread).
      final t = (i + 1) / total;
      final ago = (18000 + t * t * 63000000).round() + rnd.nextInt(9000);
      final device = rnd.nextDouble() < 0.62 ? 'Windows PC' : 'Pixel 9';
      final promoted = rnd.nextDouble() < 0.18;
      final roll = rnd.nextDouble();
      if (roll < 0.18) {
        final v = rnd.nextInt(photoTags.length);
        // uid encodes the variant: gpN % variants.length == v (localImagePath).
        out.add(mk(
          'gp${i * photoTags.length + v}',
          Kind.photo,
          ago,
          title: photoTitles[v],
          bytes: 400000 + rnd.nextInt(2400000),
          blobKey: 'gen-$i',
          tags: photoTags[v],
          device: device,
          promoted: promoted,
        ));
      } else if (roll < 0.26) {
        out.add(mk(
          'gf$i',
          Kind.file,
          ago,
          filename: '${pick(docs)}${rnd.nextInt(90)}.${pick(exts)}',
          bytes: 90000 + rnd.nextInt(9000000),
          blobKey: 'genf-$i',
          tags: const ['document'],
          device: device,
          promoted: promoted,
        ));
      } else {
        final (title, content, tags) = genString();
        out.add(mk(
          'gs$i',
          Kind.string,
          ago,
          title: title,
          content: content,
          tags: tags,
          device: device,
          promoted: promoted,
        ));
      }
    }
    return out;
  }
}

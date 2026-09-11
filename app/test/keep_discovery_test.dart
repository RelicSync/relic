// Keep, said out loud.
//
// Nobody on the free plan was keeping anything, and the audit said why: the
// gem never named itself, the row menu had no Keep, no key kept, and the
// Vault's empty state said "copy anything and it lands here". These tests pin
// the four fixes and the one-time hint that points at them.
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/repo.dart';
import 'package:relic_app/models/relic.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/ui/popup.dart';

/// A repo the hint can fire on: never shown, nothing kept, a long list.
class _HintRepo extends MemoryRepo {
  bool shown = false;
  @override
  bool get keepHintShown => shown;
  @override
  Future<void> markKeepHintShown() async => shown = true;
  @override
  AccountInfo? get account => const AccountInfo(
        tier: 'Free',
        usedBytes: 1200000,
        quotaBytes: 262144000,
        vaultCount: 0,
        vaultCap: 25,
      );
  @override
  String? get keepHotkeyLabel => 'Ctrl + Shift + W';
}

void main() {
  Future<void> pump(WidgetTester tester, MemoryRepo repo) async {
    tester.view.physicalSize = const Size(520, 620);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RelicTheme(
        colors: RelicColors.dark,
        isMobile: false,
        child: Scaffold(
          body: PopupView(repo: repo, onClose: () {}, onSettings: () {}),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Twenty more plain copies, so the list is long enough for the hint.
  Future<void> pad(MemoryRepo repo) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (var i = 0; i < 20; i++) {
      await repo.restore(Relic(
        uid: 'pad$i',
        createdAt: now - 100 - i,
        updatedAt: now - 100 - i,
        kind: Kind.string,
        source: Source.clipboard,
        promoted: false,
        byteSize: 12,
        device: 'test',
        content: 'padding copy number $i',
      ));
    }
  }

  int kept(MemoryRepo repo) => repo.all.where((r) => r.promoted).length;

  testWidgets('the gem on the selected row says what it does', (tester) async {
    final repo = MemoryRepo();
    await repo.load();
    await pump(tester, repo);
    // The first row is selected on open, so its action cluster is up.
    expect(
      find.byTooltip('Keep forever').evaluate().length +
          find.byTooltip('Take out of the Vault').evaluate().length,
      1,
    );
  });

  testWidgets('Ctrl+K keeps the selected row', (tester) async {
    final repo = MemoryRepo();
    await repo.load();
    await pump(tester, repo);
    final before = kept(repo);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 300));

    // One row changed hands, whichever way it was facing.
    expect((kept(repo) - before).abs(), 1);
    await tester.pump(const Duration(seconds: 3)); // let the toast go
  });

  testWidgets('the row menu offers Keep', (tester) async {
    final repo = MemoryRepo();
    await repo.load();
    await pump(tester, repo);
    final before = kept(repo);

    // Right-click the first row.
    final row = find.byType(ListView);
    final gesture = await tester.startGesture(
      tester.getTopLeft(row) + const Offset(120, 24),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));

    final keep = find.text('Keep forever');
    final unkeep = find.text('Take out of the Vault');
    expect(keep.evaluate().length + unkeep.evaluate().length, 1);
    await tester.tap(keep.evaluate().isNotEmpty ? keep : unkeep);
    await tester.pump(const Duration(milliseconds: 300));
    expect((kept(repo) - before).abs(), 1);
    await tester.pump(const Duration(seconds: 3)); // let the toast go
  });

  testWidgets('the Vault with nothing kept says how to keep', (tester) async {
    final repo = MemoryRepo();
    await repo.load();
    for (final r in repo.all.where((r) => r.promoted).toList()) {
      await repo.promote(r, false);
    }
    await pump(tester, repo);

    await tester.tap(find.text('Vault'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Nothing kept yet'), findsOneWidget);
    expect(find.textContaining('Select a row and click the gem'), findsOneWidget);
    expect(find.text('How the Vault works'), findsOneWidget);
  });

  group('the one-time hint', () {
    testWidgets('fires once the list is long and nothing is kept', (tester) async {
      final repo = _HintRepo();
      await repo.load();
      for (final r in repo.all.where((r) => r.promoted).toList()) {
        await repo.promote(r, false);
      }
      await pad(repo);
      await pump(tester, repo);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('Nothing kept yet. Select a row'), findsOneWidget);
      expect(find.text('Learn more'), findsOneWidget);
      expect(repo.shown, isTrue);
      await tester.pump(const Duration(seconds: 9)); // let the toast go
    });

    testWidgets('stays quiet on a short list', (tester) async {
      final repo = _HintRepo();
      await repo.load();
      await pump(tester, repo);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Nothing kept yet. Select a row'), findsNothing);
      expect(repo.shown, isFalse);
    });

    testWidgets('stays quiet once shown', (tester) async {
      final repo = _HintRepo()..shown = true;
      await repo.load();
      await pad(repo);
      await pump(tester, repo);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Nothing kept yet. Select a row'), findsNothing);
    });
  });
}

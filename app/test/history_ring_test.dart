// The free history ring, said out loud.
//
// The ring is the only free-tier wall real people hit, and until now it was
// silent: the server dropped the oldest copies and the only symptom was a
// search that came up empty. These tests pin the four surfaces that say so
// (the strip, the search dead end, the list footer, the sync chip), the source
// tag each one puts on a checkout, and the two places nothing may render: a
// store-safe build and a self-hosted server.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relic_app/data/repo.dart';
import 'package:relic_app/platform/store_safe.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/ui/popup.dart';
import 'package:relic_app/widgets/chrome.dart';

/// A repo whose account (and so whose ring state) the test sets. Everything
/// else is the demo corpus, so the list has rows to put a footer under.
class _RingRepo extends MemoryRepo {
  _RingRepo(this._account);
  AccountInfo? _account;
  set accountInfo(AccountInfo? a) => _account = a;

  @override
  AccountInfo? get account => _account;

  // Sync is on, so the header chip is live and tappable.
  @override
  bool get syncEnabled => true;

  // The same derivation the real repo uses, so the chip test exercises the
  // shipped rule rather than a copy of it.
  @override
  SyncState get sync => ringSyncState(_account) ?? const SyncState(SyncKind.synced);
}

AccountInfo _acct({
  String tier = 'Free',
  int historyCount = 0,
  int? historyCap,
  int evictedCount = 0,
}) =>
    AccountInfo(
      tier: tier,
      usedBytes: 1200000,
      quotaBytes: 262144000,
      vaultCount: 3,
      vaultCap: 25,
      historyCount: historyCount,
      historyCap: historyCap,
      evictedCount: evictedCount,
    );

void main() {
  tearDown(() => debugStoreSafeOverride = null);

  /// Build the popup at desktop proportions. [upgrades] collects the source of
  /// every upgrade the surfaces start; a null [upgrades] means no onUpgrade at
  /// all, which is how iOS ships.
  Future<void> pump(
    WidgetTester tester,
    _RingRepo repo, {
    List<String>? upgrades,
    bool mobile = false,
    ValueListenable<bool>? mini,
  }) async {
    tester.view.physicalSize = mobile ? const Size(360, 760) : const Size(520, 620);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RelicTheme(
        colors: RelicColors.dark,
        isMobile: mobile,
        child: Scaffold(
          body: PopupView(
            repo: repo,
            onClose: () {},
            onSettings: () {},
            miniSignal: mini,
            onUpgrade:
                upgrades == null ? null : (s) async => upgrades.add(s),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Load the shipped fonts so a wrap-and-fit assertion measures the real
  /// glyphs. Same recipe as the screenshot harnesses.
  Future<void> realFonts(WidgetTester tester) => tester.runAsync(() async {
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
      });

  Future<_RingRepo> repoWith(AccountInfo? a) async {
    final repo = _RingRepo(a);
    await repo.load();
    return repo;
  }

  // The footer is the last row of the list, so it has to be scrolled into
  // view before it is built.
  Future<void> toFooter(WidgetTester tester, Finder f) async {
    final list = find.byType(ListView);
    for (var i = 0; i < 15 && f.evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -320));
      await tester.pump();
    }
  }

  // A search that cannot match anything, to reach the dead end.
  Future<void> searchNothing(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).first, 'zzqqxx-nothing');
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('the strip', () {
    testWidgets('says nothing with room to spare', (tester) async {
      final repo = await repoWith(_acct(historyCount: 100, historyCap: 500));
      await pump(tester, repo, upgrades: []);

      expect(find.textContaining('waiting'), findsNothing);
      expect(find.text('Upgrade'), findsNothing);
      expect(find.textContaining('nearly full'), findsNothing);

      await searchNothing(tester);
      expect(find.textContaining('free plan'), findsNothing);
    });

    testWidgets('warns as the ring fills', (tester) async {
      final repo = await repoWith(_acct(historyCount: 450, historyCap: 500));
      await pump(tester, repo, upgrades: []);

      expect(
        find.text('History is nearly full. After 500 copies the oldest ones '
            'stop showing.'),
        findsOneWidget,
      );
      expect(find.text('Upgrade'), findsOneWidget);
      // Nothing has dropped off yet, so there is nothing to fold away and no
      // footer to write.
      expect(find.byIcon(LucideIcons.chevronUp), findsNothing);
      expect(find.textContaining('End of your free history'), findsNothing);
    });

    testWidgets('counts what is waiting, and folds down', (tester) async {
      final repo =
          await repoWith(_acct(historyCount: 500, historyCap: 500, evictedCount: 312));
      await pump(tester, repo, upgrades: []);

      expect(
        find.text('312 older copies are waiting for you. The free plan shows '
            'your last 500.'),
        findsOneWidget,
      );

      await tester.tap(find.byIcon(LucideIcons.chevronUp));
      await tester.pump();
      expect(find.text('312 older copies waiting'), findsOneWidget);
      expect(find.textContaining('The free plan shows your last'), findsNothing);
      // Folded is not dismissed: the button is still there.
      expect(find.text('Upgrade'), findsWidgets);

      await tester.tap(find.byIcon(LucideIcons.chevronDown));
      await tester.pump();
      expect(find.textContaining('waiting for you'), findsOneWidget);
    });

    testWidgets('reads as one copy when only one is waiting', (tester) async {
      final repo =
          await repoWith(_acct(historyCount: 500, historyCap: 500, evictedCount: 1));
      await pump(tester, repo, upgrades: []);

      expect(
        find.text('1 older copy is waiting for you. The free plan shows your '
            'last 500.'),
        findsOneWidget,
      );
      final footer = find.text('End of your free history. 1 more is waiting.');
      await toFooter(tester, footer);
      expect(footer, findsOneWidget);

      await tester.tap(find.byIcon(LucideIcons.chevronUp));
      await tester.pump();
      expect(find.text('1 older copy waiting'), findsOneWidget);

      await searchNothing(tester);
      expect(
        find.textContaining('1 older copy is not searchable on the free plan.'),
        findsOneWidget,
      );
    });

    testWidgets('starts folded on a phone', (tester) async {
      final repo =
          await repoWith(_acct(historyCount: 500, historyCap: 500, evictedCount: 7));
      await pump(tester, repo, upgrades: [], mobile: true);

      expect(find.text('7 older copies waiting'), findsOneWidget);
      expect(find.byIcon(LucideIcons.chevronDown), findsOneWidget);
    });

    testWidgets('says the whole line on a phone once unfolded', (tester) async {
      // The test font draws every glyph as a wide box, so this one layout
      // question needs the fonts the app really ships.
      await realFonts(tester);
      final repo = await repoWith(
          _acct(historyCount: 500, historyCap: 500, evictedCount: 312));
      await pump(tester, repo, upgrades: [], mobile: true);
      await tester.tap(find.byIcon(LucideIcons.chevronDown));
      await tester.pump();

      // 360 dp wide, two buttons on the row: the sentence that names the cap
      // has to wrap onto a third line rather than lose its second half.
      const line = '312 older copies are waiting for you. The free plan shows '
          'your last 500.';
      final paragraph = tester.renderObject<RenderParagraph>(find.text(line));
      expect(paragraph.didExceedMaxLines, isFalse);

      // The footer sits beside its own Upgrade, so it wraps rather than
      // dropping the count.
      const footer = 'End of your free history. 312 more are waiting.';
      await toFooter(tester, find.text(footer));
      final tail = tester.renderObject<RenderParagraph>(find.text(footer));
      expect(tail.didExceedMaxLines, isFalse);
    });

    testWidgets('rides above the list in the mini picker too', (tester) async {
      final repo =
          await repoWith(_acct(historyCount: 500, historyCap: 500, evictedCount: 7));
      final mini = ValueNotifier<bool>(true);
      addTearDown(mini.dispose);
      await pump(tester, repo, upgrades: [], mini: mini);

      // Folded by default, since the picker is meant to be all list.
      expect(find.text('7 older copies waiting'), findsOneWidget);
      // The mini picker has no header, and no footer either: the strip is the
      // whole story there.
      expect(find.byType(PopupHeader), findsNothing);
      expect(find.textContaining('End of your free history'), findsNothing);
    });
  });

  group('the other surfaces', () {
    testWidgets('the dead end, the footer and the chip', (tester) async {
      final repo =
          await repoWith(_acct(historyCount: 500, historyCap: 500, evictedCount: 312));
      await pump(tester, repo, upgrades: []);

      // The footer sits under the last row of the list.
      final footer =
          find.text('End of your free history. 312 more are waiting.');
      await toFooter(tester, footer);
      expect(footer, findsOneWidget);

      // The chip counts what is in view against what the plan keeps.
      expect(find.text('500 / 500'), findsOneWidget);

      await searchNothing(tester);
      expect(
        find.textContaining(
            '312 older copies are not searchable on the free plan.'),
        findsOneWidget,
      );
    });

    testWidgets('each button tags its own source', (tester) async {
      final sources = <String>[];
      final repo =
          await repoWith(_acct(historyCount: 500, historyCap: 500, evictedCount: 312));
      await pump(tester, repo, upgrades: sources);

      await tester.tap(find.text('Upgrade').first);
      await tester.pump();
      expect(sources, ['ring_strip']);

      final footer =
          find.text('End of your free history. 312 more are waiting.');
      await toFooter(tester, footer);
      await tester.tap(footer);
      await tester.pump();
      expect(sources.last, 'ring_footer');

      await tester.tap(find.text('500 / 500'));
      await tester.pump();
      expect(sources.last, 'ring_chip');

      await searchNothing(tester);
      await tester.tap(find.textContaining('not searchable on the free plan'));
      await tester.pump();
      expect(sources.last, 'ring_search');
      expect(sources, ['ring_strip', 'ring_footer', 'ring_chip', 'ring_search']);
    });
  });

  group('where nothing may render', () {
    testWidgets('no onUpgrade means no surface at all', (tester) async {
      final repo =
          await repoWith(_acct(historyCount: 500, historyCap: 500, evictedCount: 312));
      await pump(tester, repo); // upgrades: null, the way iOS ships

      expect(find.textContaining('waiting'), findsNothing);
      expect(find.textContaining('Upgrade'), findsNothing);
      expect(find.textContaining('free plan'), findsNothing);

      await searchNothing(tester);
      expect(find.textContaining('free plan'), findsNothing);
    });

    testWidgets('a store-safe build renders none of it', (tester) async {
      debugStoreSafeOverride = true;
      final acct =
          _acct(historyCount: 500, historyCap: 500, evictedCount: 312);
      final repo = await repoWith(acct);
      // The host passes null on a store-safe build; this mirrors mobile.dart
      // and desktop.dart.
      await pump(tester, repo, upgrades: storeSafeBuild ? null : []);

      expect(find.textContaining('waiting'), findsNothing);
      expect(find.textContaining('Upgrade'), findsNothing);
      expect(find.textContaining('free plan'), findsNothing);
      // The chip is the one ring surface the popup does not own, so check the
      // rule itself: it never reaches historyFull here.
      expect(ringSyncState(acct), isNull);
      expect(repo.sync.kind, SyncKind.synced);
      // And Settings has no history line to print either: the line itself is
      // null here, so no pane can render it and the account footer stays put.
      expect(acct.historyLine, isNull);
      expect(acct.footer.contains('History'), isFalse);
      expect(find.textContaining('History 500 / 500'), findsNothing);
    });

    testWidgets('a self-hosted server has no ring to talk about',
        (tester) async {
      // Self-host enrolls the account at max: no cap, nothing evicted.
      final acct = AccountInfo(
        tier: 'Max',
        usedBytes: 4200000,
        quotaBytes: 0,
        vaultCount: 9,
      );
      final repo = await repoWith(acct);
      await pump(tester, repo, upgrades: []);

      expect(acct.isFree, isFalse);
      expect(acct.ringWarming, isFalse);
      expect(acct.ringCapped, isFalse);
      expect(acct.historyLine, isNull);
      // The footer line Settings shows says nothing about history.
      expect(acct.footer.contains('History'), isFalse);
      expect(ringSyncState(acct), isNull);
      expect(repo.sync.kind, SyncKind.synced);

      expect(find.textContaining('waiting'), findsNothing);
      expect(find.text('Upgrade'), findsNothing);
      expect(find.textContaining('End of your free history'), findsNothing);

      await searchNothing(tester);
      expect(find.textContaining('free plan'), findsNothing);
    });

    test('an old server sends none of the fields and nothing breaks', () {
      const a = AccountInfo(
        tier: 'Free',
        usedBytes: 10,
        quotaBytes: 262144000,
        vaultCount: 1,
        vaultCap: 25,
      );
      expect(a.isFree, isFalse);
      expect(a.ringCapped, isFalse);
      expect(a.historyLine, isNull);
      expect(ringSyncState(a), isNull);
      expect(ringNoticeBody(a, 'acct', <String>{}), isNull);
    });
  });

  group('the notification', () {
    test('fires once at the first evicted copy, then stays quiet', () {
      final sent = <String>{};
      final first = ringNoticeBody(
          _acct(historyCount: 500, historyCap: 500, evictedCount: 1),
          'acct-a',
          sent);
      expect(first,
          'Relic stopped showing your oldest copies. Open Relic to keep them.');

      // The next pull found four more gone. Already said.
      expect(
        ringNoticeBody(
            _acct(historyCount: 500, historyCap: 500, evictedCount: 5),
            'acct-a',
            sent),
        isNull,
      );

      // A hundred is worth saying once.
      final hundred = ringNoticeBody(
          _acct(historyCount: 500, historyCap: 500, evictedCount: 100),
          'acct-a',
          sent);
      expect(hundred,
          '100 of your copies are now out of reach. Open Relic to keep them.');
      expect(
        ringNoticeBody(
            _acct(historyCount: 500, historyCap: 500, evictedCount: 140),
            'acct-a',
            sent),
        isNull,
      );
    });

    test('straight past a hundred says it once, not twice', () {
      final sent = <String>{};
      final a = _acct(historyCount: 500, historyCap: 500, evictedCount: 300);
      expect(ringNoticeBody(a, 'acct-b', sent),
          '100 of your copies are now out of reach. Open Relic to keep them.');
      expect(ringNoticeBody(a, 'acct-b', sent), isNull);
    });

    test('another account starts fresh', () {
      final sent = <String>{};
      final a = _acct(historyCount: 500, historyCap: 500, evictedCount: 2);
      expect(ringNoticeBody(a, 'acct-a', sent), isNotNull);
      expect(ringNoticeBody(a, 'acct-a', sent), isNull);
      expect(ringNoticeBody(a, 'acct-b', sent), isNotNull);
    });

    test('a plan with no ring never fires', () {
      expect(
        ringNoticeBody(
            _acct(tier: 'Pro', historyCount: 9000), 'acct-c', <String>{}),
        isNull,
      );
      expect(ringNoticeBody(null, 'acct-c', <String>{}), isNull);
    });
  });

  group('the Settings plan line', () {
    test('counts what is in view, and what is waiting', () {
      expect(_acct(historyCount: 500, historyCap: 500, evictedCount: 312).historyLine,
          'History 500 / 500 · 312 waiting');
      // Nothing waiting yet: no tail.
      expect(_acct(historyCount: 450, historyCap: 500).historyLine,
          'History 450 / 500');
    });
  });
}

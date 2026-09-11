// The free history ring, made visible.
//
// Round one said how many copies were waiting. Round two shows them: greyed,
// dated rows at the end of the list and inside a date search, and the price
// of getting them back on the strip and the footer. These tests pin what a
// ghost row is allowed to say (a date, nothing else), where it may sit (after
// the last real row, never in the mini picker), which searches it joins (a
// date, never a text search), and that the price only appears once billing
// has answered.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/repo.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/ui/popup.dart';

/// A repo whose ring state and waiting list the test sets. The rest is the
/// demo corpus, so the list has real rows for the ghosts to sit under.
class _GhostRepo extends MemoryRepo {
  _GhostRepo(this._account, this._waiting);
  final AccountInfo? _account;
  final List<WaitingCopy> _waiting;

  @override
  AccountInfo? get account => _account;
  @override
  List<WaitingCopy> get waiting => _waiting;
  @override
  bool get syncEnabled => true;
}

/// The same, with billing that answers: one Pro plan at $7 a month.
class _PricedRepo extends _GhostRepo implements BillingRepo {
  _PricedRepo(super.account, super.waiting);
  int plansAsked = 0;

  @override
  Future<List<BillingPlan>> billingPlans() async {
    plansAsked++;
    return const [
      BillingPlan(priceId: 'price_pro_m', tier: 'pro', interval: 'month', amount: 700),
      BillingPlan(priceId: 'price_pro_y', tier: 'pro', interval: 'year', amount: 6000),
    ];
  }

  @override
  Future<String?> checkoutUrl(String priceId, {String? source}) async => null;
  @override
  Future<String?> upgradeUrl([String? source]) async => null;
  @override
  Future<String?> portalUrl() async => null;
}

AccountInfo _capped(int evicted) => AccountInfo(
      tier: 'Free',
      usedBytes: 1200000,
      quotaBytes: 262144000,
      vaultCount: 0,
      vaultCap: 25,
      historyCount: 500,
      historyCap: 500,
      evictedCount: evicted,
    );

int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Noon yesterday, local time: inside "yesterday" whatever the clock says.
int get _yesterdayNoon {
  final t = DateTime.now();
  return DateTime(t.year, t.month, t.day - 1, 12).millisecondsSinceEpoch ~/ 1000;
}

List<WaitingCopy> _ghosts({int old = 5, int yesterday = 0}) => [
      for (var i = 0; i < yesterday; i++)
        WaitingCopy(uid: 'y$i', createdAt: _yesterdayNoon - i * 60),
      for (var i = 0; i < old; i++)
        WaitingCopy(uid: 'o$i', createdAt: _now - (20 + i) * 86400),
    ];

void main() {
  Future<void> pump(
    WidgetTester tester,
    MemoryRepo repo, {
    List<String>? upgrades,
    ValueNotifier<bool>? mini,
  }) async {
    tester.view.physicalSize = const Size(520, 620);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RelicTheme(
        colors: RelicColors.dark,
        isMobile: false,
        child: Scaffold(
          body: PopupView(
            repo: repo,
            onClose: () {},
            onSettings: () {},
            miniSignal: mini,
            onUpgrade: upgrades == null ? null : (s) async => upgrades.add(s),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> toEnd(WidgetTester tester, Finder f) async {
    final list = find.byType(ListView);
    for (var i = 0; i < 15 && f.evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -320));
      await tester.pump();
    }
  }

  final ghostTitle = find.textContaining('A copy from ');
  final ghostMeta = find.text('Waiting behind the free plan');

  group('ghost rows', () {
    testWidgets('three sit above the footer while browsing', (tester) async {
      final sources = <String>[];
      final repo = _GhostRepo(_capped(312), _ghosts(old: 5));
      await repo.load();
      await pump(tester, repo, upgrades: sources);

      final footer = find.text('End of your free history. 312 more are waiting.');
      await toEnd(tester, footer);
      expect(footer, findsOneWidget);
      // Three of the five, and each one is a date and a label, nothing else.
      expect(ghostTitle, findsNWidgets(3));
      expect(ghostMeta, findsNWidgets(3));

      await tester.tap(ghostTitle.first);
      await tester.pump();
      expect(sources, ['ring_ghost']);
    });

    testWidgets('a date search shows the ones from that time', (tester) async {
      final repo = _GhostRepo(_capped(312), _ghosts(old: 5, yesterday: 2));
      await repo.load();
      await pump(tester, repo, upgrades: []);

      // Nothing in the corpus matches this word, so the search dead-ends,
      // and the dead end counts the copies from yesterday, not all 312.
      await tester.enterText(find.byType(TextField).first, 'zzqqxx yesterday');
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.textContaining('2 copies from that time are waiting behind the free plan.'),
        findsOneWidget,
      );
    });

    testWidgets('a text search shows none', (tester) async {
      final repo = _GhostRepo(_capped(312), _ghosts(old: 5));
      await repo.load();
      await pump(tester, repo, upgrades: []);

      await tester.enterText(find.byType(TextField).first, 'zzqqxx-nothing');
      await tester.pump(const Duration(milliseconds: 400));
      expect(ghostTitle, findsNothing);
      // The general line still stands: nothing could say whether they match.
      expect(
        find.textContaining('312 older copies are not searchable on the free plan.'),
        findsOneWidget,
      );
    });

    testWidgets('never without an upgrade host, never in the mini picker',
        (tester) async {
      final repo = _GhostRepo(_capped(312), _ghosts(old: 5));
      await repo.load();
      await pump(tester, repo); // upgrades: null, the way iOS ships
      await toEnd(tester, ghostTitle);
      expect(ghostTitle, findsNothing);

      await pump(tester, repo, upgrades: [], mini: ValueNotifier(true));
      await toEnd(tester, ghostTitle);
      expect(ghostTitle, findsNothing);
    });
  });

  group('the price', () {
    testWidgets('names the plan once billing answers', (tester) async {
      final repo = _PricedRepo(_capped(312), _ghosts(old: 5));
      await repo.load();
      await pump(tester, repo, upgrades: []);
      await tester.pump();

      expect(repo.plansAsked, 1);
      expect(
        find.text('312 older copies are waiting for you. Pro keeps every copy for \$7 a month.'),
        findsOneWidget,
      );
      final footer = find.text('312 more are waiting. Pro brings them back for \$7 a month.');
      await toEnd(tester, footer);
      expect(footer, findsOneWidget);
    });

    testWidgets('stays out of the sentence when billing has nothing to say',
        (tester) async {
      final repo = _GhostRepo(_capped(312), _ghosts(old: 5));
      await repo.load();
      await pump(tester, repo, upgrades: []);
      expect(
        find.text('312 older copies are waiting for you. The free plan shows your last 500.'),
        findsOneWidget,
      );
    });

    testWidgets('is never asked for without an upgrade host', (tester) async {
      final repo = _PricedRepo(_capped(312), _ghosts(old: 5));
      await repo.load();
      await pump(tester, repo);
      await tester.pump();
      expect(repo.plansAsked, 0);
    });

    test('priceSentence says it the way a person would', () {
      const m = BillingPlan(priceId: 'a', tier: 'pro', interval: 'month', amount: 700);
      const y = BillingPlan(priceId: 'b', tier: 'pro', interval: 'year', amount: 6000);
      const odd = BillingPlan(priceId: 'c', tier: 'pro', interval: 'month', amount: 799);
      const unknown = BillingPlan(priceId: 'd', tier: 'pro');
      expect(m.priceSentence, '\$7 a month');
      expect(y.priceSentence, '\$60 a year');
      expect(odd.priceSentence, '\$7.99 a month');
      expect(unknown.priceSentence, isNull);
    });
  });
}

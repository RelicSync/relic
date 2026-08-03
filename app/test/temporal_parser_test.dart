import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/temporal_parser.dart';

void main() {
  // Frozen clock: Sunday 21 June 2026, 14:30 local.
  final now = DateTime(2026, 6, 21, 14, 30);
  int s(int y, int m, int d) =>
      DateTime(y, m, d).millisecondsSinceEpoch ~/ 1000;
  final t = s(2026, 6, 22); // start of tomorrow — the "recent" cap

  void expectRange(
    String q, {
    int? after,
    required int before,
    required String residual,
  }) {
    final r = parseTemporal(q, now: now);
    expect(r.range, isNotNull, reason: 'expected a range for "$q"');
    expect(r.range!.after, after, reason: 'after for "$q"');
    expect(r.range!.before, before, reason: 'before for "$q"');
    expect(r.residual, residual, reason: 'residual for "$q"');
  }

  void expectNone(String q) {
    final r = parseTemporal(q, now: now);
    expect(r.range, isNull, reason: 'expected no range for "$q"');
    expect(r.residual, q, reason: 'residual unchanged for "$q"');
  }

  group('singletons', () {
    test('today', () =>
        expectRange('today', after: s(2026, 6, 21), before: t, residual: ''));
    test('from yesterday (strip connective)', () => expectRange(
        'screenshots from yesterday',
        after: s(2026, 6, 20),
        before: s(2026, 6, 21),
        residual: 'screenshots'));
    test('from guard keeps source connective', () => expectRange(
        'email from John yesterday',
        after: s(2026, 6, 20),
        before: s(2026, 6, 21),
        residual: 'email from John'));
    test('tomorrow → no match', () => expectNone('tomorrow notes'));
    test('since yesterday', () => expectRange('since yesterday',
        after: s(2026, 6, 20), before: t, residual: ''));
  });

  group('rolling vs calendar windows', () {
    test('last 7 days', () => expectRange('last 7 days',
        after: s(2026, 6, 14), before: t, residual: ''));
    test('past 3 weeks', () => expectRange('invoices past 3 weeks',
        after: s(2026, 5, 31), before: t, residual: 'invoices'));
    test('last 6 months', () => expectRange('report last 6 months',
        after: s(2025, 12, 1), before: t, residual: 'report'));
    test('this week', () => expectRange('this week',
        after: s(2026, 6, 15), before: t, residual: ''));
    test('this month', () => expectRange('this month',
        after: s(2026, 6, 1), before: t, residual: ''));
    test('this year', () => expectRange('this year',
        after: s(2026, 1, 1), before: t, residual: ''));
    test('last week (calendar)', () => expectRange('photos last week',
        after: s(2026, 6, 8), before: s(2026, 6, 15), residual: 'photos'));
    test('last month (calendar)', () => expectRange('last month',
        after: s(2026, 5, 1), before: s(2026, 6, 1), residual: ''));
    test('last year (calendar)', () => expectRange('last year',
        after: s(2025, 1, 1), before: s(2026, 1, 1), residual: ''));
  });

  group('N units ago (buckets)', () {
    test('3 days ago', () => expectRange('3 days ago',
        after: s(2026, 6, 18), before: s(2026, 6, 19), residual: ''));
    test('2 weeks ago', () => expectRange('2 weeks ago',
        after: s(2026, 6, 1), before: s(2026, 6, 8), residual: ''));
    test('5 months ago', () => expectRange('5 months ago',
        after: s(2026, 1, 1), before: s(2026, 2, 1), residual: ''));
    test('2 years ago', () => expectRange('2 years ago',
        after: s(2024, 1, 1), before: s(2025, 1, 1), residual: ''));
    test('a month ago', () => expectRange('a month ago',
        after: s(2026, 5, 1), before: s(2026, 6, 1), residual: ''));
  });

  group('vague', () {
    test('a few months ago', () => expectRange('invoice from a few months ago',
        after: s(2026, 2, 1), before: s(2026, 6, 1), residual: 'invoice'));
    test('a few days ago', () => expectRange('a few days ago',
        after: s(2026, 6, 16), before: s(2026, 6, 20), residual: ''));
    test('bare months ago (open-ended older)', () => expectRange('stuff months ago',
        after: null, before: s(2026, 4, 1), residual: 'stuff'));
    test('a while ago', () => expectRange('a while ago',
        after: null, before: s(2026, 5, 22), residual: ''));
    test('ages ago', () => expectRange('ages ago',
        after: null, before: s(2026, 3, 23), residual: ''));
    test('recently', () => expectRange('recently',
        after: s(2026, 5, 22), before: t, residual: ''));
    test('recently mid-sentence', () => expectRange('screenshots recently uploaded',
        after: s(2026, 5, 22), before: t, residual: 'screenshots uploaded'));
  });

  group('months & years', () {
    test('in June (clamped)', () => expectRange('in June',
        after: s(2026, 6, 1), before: t, residual: ''));
    test('in March guarded by connective', () => expectRange('notes in March about taxes',
        after: s(2026, 3, 1), before: s(2026, 4, 1), residual: 'notes about taxes'));
    test('bare march → no match', () => expectNone('march budget'));
    test('June 2026 (clamped)', () => expectRange('June 2026',
        after: s(2026, 6, 1), before: t, residual: ''));
    test('last June', () => expectRange('last June',
        after: s(2025, 6, 1), before: s(2025, 7, 1), residual: ''));
    test('in 2025', () => expectRange('in 2025',
        after: s(2025, 1, 1), before: s(2026, 1, 1), residual: ''));
  });

  group('comparators', () {
    test('before 2025', () => expectRange('before 2025',
        after: null, before: s(2025, 1, 1), residual: ''));
    test('since 2024', () => expectRange('since 2024',
        after: s(2024, 1, 1), before: t, residual: ''));
    test('after March 2025', () => expectRange('after March 2025',
        after: s(2025, 4, 1), before: t, residual: ''));
    test('before June 2026', () => expectRange('before June 2026 receipts',
        after: null, before: s(2026, 6, 1), residual: 'receipts'));
    test('from June to August 2026 (clamped)', () => expectRange(
        'from June to August 2026',
        after: s(2026, 6, 1), before: t, residual: ''));
    test('from 2024 to 2025', () => expectRange('from 2024 to 2025 logs',
        after: s(2024, 1, 1), before: s(2026, 1, 1), residual: 'logs'));
  });

  group('explicit dates', () {
    test('June 20', () => expectRange('June 20',
        after: s(2026, 6, 20), before: s(2026, 6, 21), residual: ''));
    test('ISO 2026-06-20', () => expectRange('2026-06-20',
        after: s(2026, 6, 20), before: s(2026, 6, 21), residual: ''));
    test('US slash 06/20/2026', () => expectRange('06/20/2026',
        after: s(2026, 6, 20), before: s(2026, 6, 21), residual: ''));
    test('D/M swap 20/06/2026', () => expectRange('20/06/2026',
        after: s(2026, 6, 20), before: s(2026, 6, 21), residual: ''));
    test('impossible slash → no match', () => expectNone('13/13/2026'));
    test('Feb 29 2025 invalid → no match', () => expectNone('Feb 29 2025'));
  });

  group('bare year (plausible past year filters)', () {
    test('trailing year with terms', () => expectRange('trip photo 2024',
        after: s(2024, 1, 1), before: s(2025, 1, 1), residual: 'trip photo'));
    test('bare year mid-text', () => expectRange('error 2025 log',
        after: s(2025, 1, 1), before: s(2026, 1, 1), residual: 'error log'));
    test('implausible 4-digit number is not a year', () =>
        expectNone('room 1450 key'));
    test('future year → no match', () => expectNone('budget 2030'));
  });

  group('negatives & guards', () {
    test('number without unit', () => expectNone('top 5 results'));
    test('modal "may"', () => expectNone('I may go later'));
    test('no temporal', () => expectNone('meeting recap'));
    test('possessive yesterdays', () => expectNone('yesterdays plan'));
  });

  group('first-match-only (v1)', () {
    test('two phrases → leftmost wins', () => expectRange(
        'photos from last week and last month',
        after: s(2026, 6, 8),
        before: s(2026, 6, 15),
        residual: 'photos and last month'));
  });
}

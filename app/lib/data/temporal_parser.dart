// Offline, deterministic natural-language date parser for the search box.
//
// Pulls a date/time expression out of a free-text query, resolves it to a
// half-open [after, before) range (epoch seconds, in DateRange) and returns the
// residual query with the temporal phrase removed. No AI, no network, no
// dependencies. `now` is injected for testability — never read the clock here.
//
// Conventions (see the design doc):
// - Half-open intervals [after, before), local wall-clock.
// - All boundary math goes through the DateTime(y, m, d) constructor so month
//   and year overflow normalise (Jan-1 → Dec prev year, etc.) and DST can't
//   shift a "day"; never Duration(days:) for calendar units.
// - Past-only archive: future-leaning phrases resolve to no match (null range,
//   text untouched).
import '../models/relic.dart' show DateRange;

/// Tunable constants for vague expressions and the slash-date locale.
class TemporalConfig {
  final int recentDays; // "recently" / "lately" trailing window
  final int fewDays; // "a few days ago" lower edge (days back)
  final int fewWeeksDays; // "a few weeks ago" lower edge (days back)
  final int fewMonths; // "a few months ago" lower edge (months back)
  final int fewYears; // "a few years ago" lower edge (years back)
  final int whileAgoDays; // "a while ago" cutoff (older-than, days)
  final int agesAgoDays; // "ages ago" cutoff (older-than, days)
  final int monthsAgoMonths; // bare "months ago" cutoff (older-than, months)

  const TemporalConfig({
    this.recentDays = 30,
    this.fewDays = 5,
    this.fewWeeksDays = 28,
    this.fewMonths = 4,
    this.fewYears = 4,
    this.whileAgoDays = 30,
    this.agesAgoDays = 90,
    this.monthsAgoMonths = 2,
  });
}

/// Result of [parseTemporal]. [range] is null when no temporal phrase was found
/// (or it resolved into the future); [residual] then equals the input.
class TemporalParse {
  final DateRange? range;
  final String residual;
  final String matchedText;
  final double confidence;

  const TemporalParse({
    this.range,
    required this.residual,
    this.matchedText = '',
    this.confidence = 1.0,
  });

  bool get hasRange => range != null && !range!.isEmpty;
  bool get isOpenEndedOlder => range != null && range!.isOpenEndedOlder;
}

// --- pure date helpers (constructor-normalised; DST-safe) ---

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime _addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);
DateTime _firstOfMonth(int year, int month) => DateTime(year, month, 1);
DateTime _startOfMonth(DateTime d) => DateTime(d.year, d.month, 1);
DateTime _startOfYear(DateTime d) => DateTime(d.year, 1, 1);
DateTime _startOfWeek(DateTime d, int weekStart) =>
    _addDays(_startOfDay(d), -((d.weekday - weekStart + 7) % 7));

int _secs(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

bool _validYmd(int y, int m, int d) {
  final dt = DateTime(y, m, d);
  return dt.year == y && dt.month == m && dt.day == d;
}

const _monthAlt =
    'jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|'
    'aug(?:ust)?|sept|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?';

int? _monthNum(String s) {
  final w = s.toLowerCase();
  const order = [
    'jan', 'feb', 'mar', 'apr', 'may', 'jun',
    'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
  ];
  final key = w.length >= 3 ? w.substring(0, 3) : w;
  final i = order.indexOf(key);
  return i < 0 ? null : i + 1;
}

int? _numWord(String s) {
  final w = s.trim().toLowerCase();
  final n = int.tryParse(w);
  if (n != null) return n;
  const words = {
    'a': 1, 'an': 1, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5,
    'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10, 'eleven': 11,
    'twelve': 12,
  };
  return words[w];
}

/// 'd' | 'w' | 'mo' | 'y' for a unit word, else null.
String? _unit(String u) {
  final w = u.toLowerCase();
  if (w.startsWith('day')) return 'd';
  if (w.startsWith('week')) return 'w';
  if (w.startsWith('month')) return 'mo';
  if (w.startsWith('year')) return 'y';
  return null;
}

int _inferYear(int month, DateTime now) =>
    month <= now.month ? now.year : now.year - 1;

/// A raw resolved range before clamping. [after] null ⇒ open-ended older.
class _Raw {
  final DateTime? after;
  final DateTime before;
  const _Raw(this.after, this.before);
}

/// A matched rule hit: the raw range and the char span it covered.
class _Hit {
  final _Raw raw;
  final int start;
  final int end;
  const _Hit(this.raw, this.start, this.end);
}

/// Operand bucket for comparator / from…to rules.
class _Bucket {
  final DateTime start;
  final DateTime endExcl;
  const _Bucket(this.start, this.endExcl);
}

/// Parse a comparator/range operand ("today", "yesterday", a month (+year), a
/// year, or an ISO date) into its bucket. [yearHint] supplies the year for a
/// bare month name (used by from…to when only the second operand has a year).
_Bucket? _parseOperand(String raw, DateTime now, {int? yearHint}) {
  final s = raw.trim().toLowerCase();
  final d0 = _startOfDay(now);
  if (s == 'today') return _Bucket(d0, _addDays(d0, 1));
  if (s == 'yesterday') return _Bucket(_addDays(d0, -1), d0);

  // ISO yyyy-mm(-dd)
  final iso = RegExp(r'^(\d{4})-(\d{2})(?:-(\d{2}))?$').firstMatch(s);
  if (iso != null) {
    final y = int.parse(iso.group(1)!);
    final m = int.parse(iso.group(2)!);
    if (m < 1 || m > 12) return null;
    if (iso.group(3) != null) {
      final d = int.parse(iso.group(3)!);
      if (!_validYmd(y, m, d)) return null;
      return _Bucket(DateTime(y, m, d), DateTime(y, m, d + 1));
    }
    return _Bucket(_firstOfMonth(y, m), _firstOfMonth(y, m + 1));
  }

  // month (+ optional year)
  final mon = RegExp('^($_monthAlt)\\.?(?:\\s+(\\d{4}))?\$').firstMatch(s);
  if (mon != null) {
    final m = _monthNum(mon.group(1)!)!;
    final y = mon.group(2) != null
        ? int.parse(mon.group(2)!)
        : (yearHint ?? _inferYear(m, now));
    return _Bucket(_firstOfMonth(y, m), _firstOfMonth(y, m + 1));
  }

  // bare year
  final yr = RegExp(r'^(\d{4})$').firstMatch(s);
  if (yr != null) {
    final y = int.parse(yr.group(1)!);
    return _Bucket(DateTime(y, 1, 1), DateTime(y + 1, 1, 1));
  }
  return null;
}

const _opPattern =
    '(?:\\d{4}-\\d{2}(?:-\\d{2})?|(?:$_monthAlt)\\.?(?:\\s+\\d{4})?|\\d{4}|today|yesterday)';

/// Parse a date expression out of [query]. See [TemporalParse].
TemporalParse parseTemporal(
  String query, {
  DateTime? now,
  int weekStart = DateTime.monday,
  TemporalConfig config = const TemporalConfig(),
}) {
  final n = now ?? DateTime.now();
  final lower = query.toLowerCase();
  final d0 = _startOfDay(n);
  final t = _addDays(d0, 1); // start of tomorrow — the universal "recent" cap

  // Each rule: a regex + a resolver producing a raw range (null ⇒ skip).
  final rules = <(RegExp, _Raw? Function(RegExpMatch))>[
    // 1. ISO date / year-month
    (
      RegExp(r'\b(\d{4})-(\d{2})(?:-(\d{2}))?\b'),
      (m) {
        final y = int.parse(m.group(1)!), mo = int.parse(m.group(2)!);
        if (mo < 1 || mo > 12) return null;
        if (m.group(3) != null) {
          final d = int.parse(m.group(3)!);
          if (!_validYmd(y, mo, d)) return null;
          return _Raw(DateTime(y, mo, d), DateTime(y, mo, d + 1));
        }
        return _Raw(_firstOfMonth(y, mo), _firstOfMonth(y, mo + 1));
      },
    ),

    // 2. from X to Y
    (
      RegExp(
        '\\bfrom\\s+($_opPattern)\\s+(?:to|through|thru|until|-|–|—)\\s+($_opPattern)\\b',
      ),
      (m) {
        final b = _parseOperand(m.group(2)!, n);
        if (b == null) return null;
        final a = _parseOperand(m.group(1)!, n, yearHint: b.start.year);
        if (a == null) return null;
        return _Raw(a.start, b.endExcl);
      },
    ),

    // 3. comparator + operand. NOTE: "from" is deliberately NOT here — bare
    //    "from yesterday"/"from June" reads as the period itself with "from" as a
    //    strip-connective (see _residual), while "from X to Y" is rule 2. Only
    //    "since" carries the open-ended inclusive-start meaning.
    (
      RegExp(
        '\\b(before|after|since|until|up\\s+to|as\\s+of)\\s+($_opPattern)\\b',
      ),
      (m) {
        final op = _parseOperand(m.group(2)!, n);
        if (op == null) return null;
        final kw = m.group(1)!.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
        switch (kw) {
          case 'before':
          case 'until':
          case 'up to':
            return _Raw(null, op.start);
          case 'after':
            return _Raw(op.endExcl, t);
          default: // since / as of
            return _Raw(op.start, t);
        }
      },
    ),

    // 4. slash date M/D(/Y)  (US default, with a D/M swap guard)
    (
      RegExp(r'\b(\d{1,2})/(\d{1,2})(?:/(\d{4}))?\b(?!\d)'),
      (m) {
        var mo = int.parse(m.group(1)!);
        var d = int.parse(m.group(2)!);
        if (mo > 12 && d <= 12) {
          final tmp = mo;
          mo = d;
          d = tmp;
        }
        final y = m.group(3) != null ? int.parse(m.group(3)!) : _inferYear(mo, n);
        if (mo < 1 || mo > 12 || !_validYmd(y, mo, d)) return null;
        return _Raw(DateTime(y, mo, d), DateTime(y, mo, d + 1));
      },
    ),

    // 5. month + day (+year), or day + month (+year)
    (
      RegExp(
        '\\b(?:in\\s+)?($_monthAlt)\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:,?\\s+(\\d{4}))?\\b(?!\\d)',
      ),
      (m) {
        final mo = _monthNum(m.group(1)!)!;
        final d = int.parse(m.group(2)!);
        final y = m.group(3) != null ? int.parse(m.group(3)!) : _inferYear(mo, n);
        if (!_validYmd(y, mo, d)) return null;
        return _Raw(DateTime(y, mo, d), DateTime(y, mo, d + 1));
      },
    ),
    (
      RegExp(
        '\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+($_monthAlt)(?:,?\\s+(\\d{4}))?\\b(?!\\d)',
      ),
      (m) {
        final d = int.parse(m.group(1)!);
        final mo = _monthNum(m.group(2)!)!;
        final y = m.group(3) != null ? int.parse(m.group(3)!) : _inferYear(mo, n);
        if (!_validYmd(y, mo, d)) return null;
        return _Raw(DateTime(y, mo, d), DateTime(y, mo, d + 1));
      },
    ),

    // 6. month + year
    (
      RegExp('\\b(?:in\\s+)?($_monthAlt)\\.?\\s+(\\d{4})\\b'),
      (m) {
        final mo = _monthNum(m.group(1)!)!;
        final y = int.parse(m.group(2)!);
        return _Raw(_firstOfMonth(y, mo), _firstOfMonth(y, mo + 1));
      },
    ),

    // 7. N units ago
    (
      RegExp(
        r'\b(\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s+(day|week|month|year)s?\s+ago\b',
      ),
      (m) {
        final k = _numWord(m.group(1)!);
        final u = _unit(m.group(2)!);
        if (k == null || u == null) return null;
        switch (u) {
          case 'd':
            return _Raw(_addDays(d0, -k), _addDays(d0, -(k - 1)));
          case 'w':
            final sw = _startOfWeek(n, weekStart);
            return _Raw(_addDays(sw, -7 * k), _addDays(sw, -7 * (k - 1)));
          case 'mo':
            return _Raw(
              _firstOfMonth(n.year, n.month - k),
              _firstOfMonth(n.year, n.month - (k - 1)),
            );
          default: // y
            return _Raw(DateTime(n.year - k, 1, 1), DateTime(n.year - (k - 1), 1, 1));
        }
      },
    ),

    // 8. "a few / several / couple units ago" — band
    (
      RegExp(
        r'\b(?:a\s+)?(few|several|couple(?:\s+of)?)\s+(day|week|month|year)s?\s+ago\b',
      ),
      (m) {
        final u = _unit(m.group(2)!);
        if (u == null) return null;
        switch (u) {
          case 'd':
            return _Raw(_addDays(d0, -config.fewDays), _addDays(d0, -1));
          case 'w':
            return _Raw(_addDays(d0, -config.fewWeeksDays), _addDays(d0, -7));
          case 'mo':
            return _Raw(
              _firstOfMonth(n.year, n.month - config.fewMonths),
              _firstOfMonth(n.year, n.month),
            );
          default: // y
            return _Raw(DateTime(n.year - config.fewYears, 1, 1), DateTime(n.year - 1, 1, 1));
        }
      },
    ),

    // 9. bare vague-older
    (
      RegExp(
        r'\b((?:months?|years?)\s+ago|a\s+while\s+ago|a\s+long\s+time\s+ago|ages\s+ago)\b',
      ),
      (m) {
        final phrase = m.group(1)!.toLowerCase();
        if (phrase.startsWith('month')) {
          return _Raw(null, _firstOfMonth(n.year, n.month - config.monthsAgoMonths));
        }
        if (phrase.startsWith('year')) {
          return _Raw(null, DateTime(n.year - 1, 1, 1));
        }
        if (phrase.startsWith('ages')) {
          return _Raw(null, _addDays(d0, -config.agesAgoDays));
        }
        return _Raw(null, _addDays(d0, -config.whileAgoDays)); // a while / long time
      },
    ),

    // 10. last/past N units — rolling
    (
      RegExp(
        r'\b(?:last|past)\s+(\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s+(day|week|month|year)s?\b',
      ),
      (m) {
        final k = _numWord(m.group(1)!);
        final u = _unit(m.group(2)!);
        if (k == null || u == null) return null;
        switch (u) {
          case 'd':
            return _Raw(_addDays(d0, -k), t);
          case 'w':
            return _Raw(_addDays(d0, -7 * k), t);
          case 'mo':
            return _Raw(_firstOfMonth(n.year, n.month - k), t);
          default: // y
            return _Raw(DateTime(n.year - k, 1, 1), t);
        }
      },
    ),

    // 11. this week/month/year
    (
      RegExp(r'\bthis\s+(week|month|year)\b'),
      (m) {
        switch (_unit(m.group(1)!)) {
          case 'w':
            return _Raw(_startOfWeek(n, weekStart), t);
          case 'mo':
            return _Raw(_startOfMonth(n), t);
          default: // y
            return _Raw(_startOfYear(n), t);
        }
      },
    ),

    // 12. last <month> — most recent past occurrence
    (
      RegExp('\\blast\\s+($_monthAlt)\\b'),
      (m) {
        final mo = _monthNum(m.group(1)!)!;
        final y = mo >= n.month ? n.year - 1 : n.year;
        return _Raw(_firstOfMonth(y, mo), _firstOfMonth(y, mo + 1));
      },
    ),

    // 13. last week/month/year — calendar
    (
      RegExp(r'\blast\s+(week|month|year)\b'),
      (m) {
        switch (_unit(m.group(1)!)) {
          case 'w':
            final sw = _startOfWeek(n, weekStart);
            return _Raw(_addDays(sw, -7), sw);
          case 'mo':
            return _Raw(
              _firstOfMonth(n.year, n.month - 1),
              _firstOfMonth(n.year, n.month),
            );
          default: // y
            return _Raw(DateTime(n.year - 1, 1, 1), DateTime(n.year, 1, 1));
        }
      },
    ),

    // 14. named singletons
    (
      RegExp(r'\b(today|yesterday|tomorrow|the\s+other\s+day)\b'),
      (m) {
        final w = m.group(1)!.toLowerCase();
        if (w == 'today') return _Raw(d0, t);
        if (w == 'yesterday') return _Raw(_addDays(d0, -1), d0);
        if (w == 'tomorrow') return _Raw(t, _addDays(t, 1)); // future → clamped out
        return _Raw(_addDays(d0, -3), t); // the other day
      },
    ),

    // 15. soft-recent
    (
      RegExp(r'\b(recently|lately|just\s+now|moments?\s+ago)\b'),
      (m) {
        final w = m.group(1)!.toLowerCase();
        if (w.startsWith('just') || w.startsWith('moment')) {
          return _Raw(_addDays(d0, -1), t);
        }
        return _Raw(_addDays(d0, -config.recentDays), t);
      },
    ),

    // 16. bare month name (guarded: "may"/"march" need an "in" connective).
    //     `(?!\s+\d)` keeps it from grabbing the month of a failed explicit date
    //     like "Feb 29 2025" (which must resolve to no match, not "Feb").
    (
      RegExp('\\b(in\\s+)?($_monthAlt)\\b(?!\\s+\\d)'),
      (m) {
        final hasIn = m.group(1) != null;
        final word = m.group(2)!.toLowerCase();
        if (!hasIn && (word.startsWith('may') || word.startsWith('mar'))) {
          return null; // guard the high-risk bare tokens
        }
        final mo = _monthNum(word)!;
        final y = _inferYear(mo, n);
        return _Raw(_firstOfMonth(y, mo), _firstOfMonth(y, mo + 1));
      },
    ),

    // 17. "in <year>"
    (
      RegExp(r'\bin\s+(\d{4})\b'),
      (m) {
        final y = int.parse(m.group(1)!);
        return _Raw(DateTime(y, 1, 1), DateTime(y + 1, 1, 1));
      },
    ),

    // 18. bare year — last resort, so explicit forms above win. Only a plausible
    //     past year (1970..now) counts; the visible removable chip is the safety
    //     net for the occasional ID/quantity false positive (e.g. "error 2025").
    //     Lookbehinds keep it from pulling a year out of a malformed explicit
    //     date: not after "/" or "-" (slash/ISO dates) nor a "<day> " run
    //     (the tail of "Feb 29 2025").
    (
      RegExp(r'(?<![/\-])(?<!\d\s)\b(\d{4})\b'),
      (m) {
        final y = int.parse(m.group(1)!);
        if (y < 1970 || y > n.year) return null;
        return _Raw(DateTime(y, 1, 1), DateTime(y + 1, 1, 1));
      },
    ),
  ];

  for (final (re, resolve) in rules) {
    for (final m in re.allMatches(lower)) {
      final raw = resolve(m);
      if (raw == null) continue;
      // Clamp the upper bound into the past; drop fully-future phrases.
      var before = raw.before;
      if (before.isAfter(t)) before = t;
      final after = raw.after;
      if (after != null && !after.isBefore(before)) continue; // empty / future
      final range = DateRange(
        after: after == null ? null : _secs(after),
        before: _secs(before),
      );
      return TemporalParse(
        range: range,
        residual: _residual(query, m.start, m.end),
        matchedText: query.substring(m.start, m.end),
      );
    }
  }

  return TemporalParse(residual: query);
}

/// Remove `[start, end)` plus a directly-preceding binding connective, then
/// tidy the whitespace seam.
String _residual(String original, int start, int end) {
  var left = original.substring(0, start);
  final right = original.substring(end);
  left = left.replaceFirst(
    RegExp(r'(?:\b(?:from|since|in|on|during|as of|back in)\s+)$',
        caseSensitive: false),
    '',
  );
  return '$left $right'.replaceAll(RegExp(r'\s+'), ' ').trim();
}

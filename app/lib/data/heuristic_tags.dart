import 'dart:convert';

import 'domain_concepts.dart'; // kDomainConcepts, for the in-prose domain→noun map

/// Deterministic, client-side subtype tags — the app-side source of truth for
/// tagging, so the whole stream (not just the enriched vault) is richly faceted
/// at capture time. Pure and ML-independent, so it runs identically on desktop
/// and the mobile lens (both [LocalDeskRepo] and [WorkerRepo]).
///
/// NOTE: the Rust `relic-core` Stage-A detector emits only a small subset of
/// this vocabulary and lags it; no live capture path uses that detector today,
/// so don't assume 1:1 parity with it.

/// Every tag [detectTags] can emit — the deterministic-detector vocabulary.
/// Migrations use this to know which stored tags are OURS to re-evaluate when
/// detectors change; sift ML tags, extension chips, capture seeds
/// (photo/screenshot), and source-app tags belong to other producers and must
/// never be stripped by a detector re-run.
const Set<String> kDetectorTags = {
  'url', 'email', 'ip', 'color', 'uuid', 'date', 'version', 'path', 'mac',
  'hash', 'geo', 'card', 'iban', 'bank', 'vin', 'vehicle', 'postcode', 'ssn',
  'secret', 'phone', 'base64', 'jwt', 'json', 'markdown', 'code', 'todo',
  'sql', 'xml', 'html', 'error', 'command', 'tracking', 'otp', 'receipt',
  'address', 'graph', 'currency', 'percent', 'duration', 'time',
  'measurement', 'handle', 'hashtag', 'doi', 'arxiv', 'paper', 'orcid',
  'location', 'table', 'csv', 'isbn', 'book', 'swift', 'commit', 'port',
  'hexdump', 'env', 'math', 'ticket', 'routing', 'coupon', 'wallet', 'crypto',
  'diff', 'number',
};

// Whole-value structural facts (the entire trimmed content is this thing).
// Any `scheme://`, not just http(s) — copied deep links (relic://, slack://)
// are links too.
final _url = RegExp(r'^[a-z][a-z0-9+.-]*://\S+$', caseSensitive: false);
// A whole-value scheme-less domain ("copyc.at", "devtools.fm/episode/91") is
// a link the user copied without its scheme. TLD-gated, but broader than the
// in-prose allowlist — as the ENTIRE clip, "word.word" shapes are far less
// ambiguous than mid-sentence ones.
final _bareDomainValue = RegExp(
  r'^(?:www\.)?(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+'
  r'(?:com|org|net|io|co|dev|app|ai|edu|gov|info|xyz|uk|ca|de|fr|jp|au|nl|eu'
  r'|at|in|ch|fm|me|tv|to|ly|gg|be|us|se|no|it|es|pl|br|sh|st|is|cc|ee)'
  r'(?:/\S*)?$',
  caseSensitive: false,
);
// TLDs that are ALSO common file extensions ("backup.sh", "logo.ai",
// "requirements.in", "foo.cc", "Dockerfile.dev"): a bare two-label value with
// one of these needs extra link evidence (a path, www., or a subdomain).
const _collisionTlds = {'sh', 'app', 'ai', 'in', 'cc', 'pl', 'dev', 'st', 'info'};

/// Whole-value scheme-less link check with the filename-collision gate.
bool _isBareDomainValue(String v) {
  if (!_bareDomainValue.hasMatch(v)) return false;
  final host = v.split('/').first.toLowerCase();
  final tld = host.substring(host.lastIndexOf('.') + 1);
  if (!_collisionTlds.contains(tld)) return true;
  return v.contains('/') ||
      host.startsWith('www.') ||
      host.split('.').length >= 3;
}
final _email = RegExp(r'^[\w.+-]+@[\w-]+(\.[\w-]+)+$');
// Octet-range-checked, or 4-part versions ("1.0.0.0") and junk
// ("999.999.999.999") read as IPs. 0-255 per octet, no leading-zero rule
// (people paste 010.0.0.1 rarely enough to ignore).
final _ipv4 = RegExp(
  r'^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$',
);
final _color = RegExp(
  r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$',
);
final _uuidRe = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final _isoDate = RegExp(
  r'^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+-]\d{2}:?\d{2})?)?$',
);
final _version = RegExp(r'^v?\d+\.\d+(\.\d+)?([-+][0-9A-Za-z.]+)?$');
// Leading "(" accepted — "(406) 530-5734" is the most common US formatting.
final _phone = RegExp(r'^\+?[\d(][\d\s().-]{6,}$');
final _winPath = RegExp(r'^([a-zA-Z]:\\|\\\\)[^\n]+$');
final _unixPath = RegExp(r'^(/|~/|\./)[^\n ]+$');
// Secret-class.
final _jwt = RegExp(r'^eyJ[\w-]+\.[\w-]+\.[\w-]*$');
// A JWT pasted INSIDE longer text (a curl command, an Authorization header,
// an .env line) must still mask — three dot-separated base64url segments
// starting `eyJ` are near-zero FP at these lengths.
final _jwtInProse = RegExp(r'\beyJ[\w-]{10,}\.[\w-]{10,}\.[\w-]{5,}');
final _awsKey = RegExp(r'\bAKIA[0-9A-Z]{16}\b');
// Stripe-style keys, INCLUDING the two-segment real-world form: the actual
// format is sk_live_<token>/sk_test_<token>, whose second underscore broke a
// bare [A-Za-z0-9]{16,} class — the most common paste never matched.
final _skKey =
    RegExp(r'\b(sk|pk|rk)_(live_|test_|prod_)?[A-Za-z0-9]{16,}\b');
// Issuer-prefixed tokens — namespaced by their issuers precisely so they're
// greppable, which makes them near-zero-FP masking wins: GitHub (ghp_/gho_/
// ghu_/ghs_/ghr_ + fine-grained github_pat_), Slack (xoxb-/xoxa-/xoxp-/
// xoxr-/xoxs-), Google API (AIza…), GitLab (glpat-), npm (npm_).
final _prefixedToken = RegExp(
  r'\bgh[pousr]_[A-Za-z0-9]{20,}\b'
  r'|\bgithub_pat_[A-Za-z0-9_]{20,}\b'
  r'|\bxox[baprs]-[A-Za-z0-9-]{10,}\b'
  r'|\bAIza[0-9A-Za-z_-]{35}\b'
  r'|\bglpat-[\w-]{20,}\b'
  r'|\bnpm_[A-Za-z0-9]{36}\b',
);
// Content shapes (may span lines).
final _mdMarkers = RegExp(
  r'(^|\n)#{1,6}\s|```|\[[^\]]+\]\([^)]+\)',
  multiLine: true,
);
final _codeHint = RegExp(
  r'(^|\n)\s*(import |from |def |class |function |public |private |const |let |var |#include|package |func |fn |return |</?[a-z][\w-]*>)|=>|;\s*$',
  multiLine: true,
);
// More whole-value structural facts.
final _mac = RegExp(r'^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$');
final _hashHex = RegExp(r'^([0-9a-f]{32}|[0-9a-f]{40}|[0-9a-f]{64})$');
final _geo = RegExp(r'^[-+]?\d{1,2}\.\d+,\s?[-+]?\d{1,3}\.\d+$');
final _card = RegExp(r'^\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{4}$');
// A relative file path ending in an extension (absolute paths use _win/_unix).
final _relPath = RegExp(r'^[\w.-]+(/[\w.-]+)+\.[A-Za-z0-9]{1,8}$');
// More content shapes (may span lines). Each is keyword/shape-gated to keep
// false positives low.
final _todo = RegExp(r'(^|\n)\s*[-*]\s\[[ xX]\]\s', multiLine: true);
// SQL needs more than "select … from" somewhere in the text — English prose
// contains both words constantly ("Please select your seats early. Greetings
// from the whole team"). The SELECT arm bounds the gap and demands a second
// SQL token; UPDATE demands the `SET col =` shape immediately after one
// identifier. The unambiguous statement heads stay as-is.
final _sql = RegExp(
  r'\b(insert\s+into|delete\s+from|create\s+(table|index|database)'
  r'|alter\s+table|drop\s+(table|index|database))\b'
  r'|\bselect\s+\*\s+from\b'
  // A clip that STARTS with select is SQL without needing a second token —
  // "SELECT id, name FROM users" is the most common paste; prose FPs come
  // from mid-text matches, not clip-initial ones.
  r'|^\s*select\b[\s\S]{1,400}?\bfrom\s+[\w."`(]'
  r'|\bselect\b[\s\S]{1,160}?\bfrom\s+[\w."`]+[\s\S]{0,160}?'
  r'(\bwhere\b|\bjoin\b|\border\s+by\b|\bgroup\s+by\b|\blimit\b|;)'
  r'|\bupdate\s+[\w."`]+\s+set\s+[\w"`]+\s*=',
  caseSensitive: false,
);
final _xml = RegExp(r'^\s*<\?xml|<\w+:\w+[ >]');
final _html = RegExp(
  r'<!DOCTYPE html|<([a-z][\w-]*)(\s[^>]*)?>[\s\S]*?</\1>',
  caseSensitive: false,
);
final _stack = RegExp(
  r'^\s*(Traceback \(most recent call last\)|at [\w.$]+\([\w.]+:\d+\)|File ".+", line \d+|[\w.]+(Error|Exception):)',
  multiLine: true,
);
// The `$ cmd` prompt arm requires a non-digit after the dollar — or a
// digit-initial WORD followed by an argument (`$ 7z x backup.7z`) — so
// accounting lines ("$ 1,234.56 was charged") don't read as shell commands.
final _command = RegExp(
  r'(^|\n)\s*(\$\s+([^\d\s]|\d\w*\s+\S)|sudo\s+\S|(git|npm|pnpm|yarn|docker|kubectl|brew|apt|pip|curl|ssh|cargo)\s+\w)',
  multiLine: true,
);
final _track = RegExp(r'\b1Z[0-9A-Z]{16}\b'); // UPS, zero-FP
final _trackKw = RegExp(r'(tracking|fedex|usps|dhl)', caseSensitive: false);
final _trackNum = RegExp(r'\b\d{12,22}\b');
final _otpKw = RegExp(
  r'(verification|one[- ]?time|security|login|auth)\s+code|code\s+is\s+\d{4,8}|\b\d{4,8}\b\s+is\s+your',
  caseSensitive: false,
);
final _otpNum = RegExp(r'\b\d{4,8}\b');
final _receipt = RegExp(
  r'(total|subtotal|amount due|grand total)\s*:?\s*[\$€£]\s?\d[\d,]*\.\d{2}',
  caseSensitive: false,
);
final _address = RegExp(
  r'\d{1,6}\s+([A-Z][a-z]+\s){1,3}(St|Street|Ave|Avenue|Blvd|Rd|Road|Dr|Drive|Ln|Lane|Ct|Way|Pl|Place)\b[\s\S]{0,80}?,\s*[A-Z]{2}\s+\d{5}(-\d{4})?',
);
// Graph / diagram source: Mermaid, Graphviz DOT, and GraphQL.
final _graph = RegExp(
  r'(^|\n)\s*(graph\s+(TB|TD|BT|RL|LR)\b|flowchart\s+(TB|TD|BT|RL|LR)\b|sequenceDiagram\b|classDiagram\b|stateDiagram(-v2)?\b|erDiagram\b|gantt\b|journey\b|(strict\s+)?(di)?graph\s+[\w"]*\s*\{)',
  multiLine: true,
);
final _graphql = RegExp(
  r'(^|\n)\s*(query|mutation|subscription)\s+(\w+\s*)?[({]',
  multiLine: true,
);
// Semantic value shapes (may appear anywhere in the text).
final _currency = RegExp(
  r'[$€£¥₹₩₽฿₺₪₴₦₨﷼]\s?\d[\d,]*(\.\d+)?'
  r'|\bR\$\s?\d[\d,]*(\.\d+)?' // Brazilian real
  r'|\b\d[\d,]*(\.\d+)?\s?(USD|EUR|GBP|JPY|CAD|AUD|CHF|CNY|INR|KRW|BRL|RUB'
  r'|MXN|SEK|NOK|DKK|PLN|ZAR|SGD|HKD|NZD|TRY|dollars?|euros?|pounds?|kr|Rs)\b'
  // zł separately: Dart's ASCII \b never matches after the non-ASCII ł, so a
  // trailing boundary makes the branch dead code. The digit prefix is gate
  // enough (and "10 złoty" is still currency).
  r'|\b\d[\d,]*(\.\d+)?\s?zł'
  r'|\b(USD|EUR|GBP|JPY|CAD|AUD|CHF|CNY|INR|KRW|BRL|RUB|MXN)\s?\d[\d,]*(\.\d+)?',
);
// A length of time ("5 minutes", "2 hours", "3 days") — distinct from a clock
// time. Worded units only (compact "5m"/"5h" would collide with measurements).
final _duration = RegExp(
  r'\b\d+(\.\d+)?\s?'
  r'(sec(?:ond)?s?|min(?:ute)?s?|h(?:ou)?rs?|days?|weeks?|months?|years?|yrs?)\b',
  caseSensitive: false,
);
final _percent = RegExp(
  r'\b\d{1,3}(\.\d+)?\s?%|\b\d+(\.\d+)?\s?percent\b',
  caseSensitive: false,
);
final _time = RegExp(
  r'\b([01]?\d|2[0-3]):[0-5]\d(:[0-5]\d)?\s?([AaPp][Mm])?\b|\b\d{1,2}\s?[AaPp][Mm]\b',
);
final _measure = RegExp(
  r'\b\d+(\.\d+)?\s?'
  r'(mm|cm|km|kg|mg|ml|kb|mb|gb|tb|hz|khz|mhz|ghz|px|pt|kph|mph|fps'
  r'|m|g|l|in|ft|yd|mi|lb|lbs|oz)\b'
  r'|\b\d+(\.\d+)?\s?°[CF]?',
  caseSensitive: false,
);
// In-prose variant for search-term emission: drops the space-separated
// ambiguous units (in/m/g/l) — "there were 5 in the room" is English, not
// inches. The compact forms ("5in", "3m") still count.
final _measureInProse = RegExp(
  r'\b\d+(\.\d+)?\s?'
  r'(mm|cm|km|kg|mg|ml|kb|mb|gb|tb|hz|khz|mhz|ghz|px|pt|kph|mph|fps'
  r'|ft|yd|mi|lb|lbs|oz)\b'
  r'|\b\d+(\.\d+)?(in|m|g|l)\b'
  r'|\b\d+(\.\d+)?\s?°[CF]?',
  caseSensitive: false,
);
final _handle = RegExp(r'(^|\s)@[A-Za-z0-9_]{2,}\b'); // social mention, not an email
final _hashtag = RegExp(r'(^|\s)#[A-Za-z][A-Za-z0-9_]+\b'); // letter-led; excludes "# Heading"/#fff
// A run of digits with at most one space/dash/comma between adjacent digits —
// so grouped numbers (3256-2002-4624-97, 325 620 024, 1,234,567) count as one.
final _numRun = RegExp(r'\d(?:[, -]?\d)*');

/// True when the text holds a digit run of >= 6 digits (separators ignored).
bool _hasNumber(String s) {
  for (final m in _numRun.allMatches(s)) {
    if (_digitCount(m.group(0)!) >= 6) return true;
  }
  return false;
}

/// Structured values that are NOT plain numbers and so suppress the generic
/// `number` tag (a date / version / id / url shouldn't surface under a "number"
/// search just because it embeds a long digit run). Numeric identifiers (phone,
/// card, otp, tracking) are deliberately absent — they ARE numbers and also get
/// tagged `number` so they're findable that way.
const _specificDigit = {
  'date', 'version', 'uuid', 'mac', 'hash', 'ip', 'url', 'email', 'path',
  'ssn', 'iban', 'vin', 'routing', 'wallet',
};

/// Strip a layer or two of wrapping quotes/brackets so a quoted value like
/// `"app/foo.png"` or `<https://x>` is still recognized by the anchored
/// structural detectors (which match the whole value).
// Zero-width / bidi control characters that ride along with web copies and
// silently defeat the `$`-anchored whole-value regexes (a real phone ending in
// U+202C detects as nothing).
final _invisibles = RegExp(r'[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]');

String _unwrap(String s) {
  const open = '"\'`<(';
  const close = '"\'`>)';
  var v = s.replaceAll(_invisibles, '').trim();
  for (var i = 0; i < 2 && v.length >= 2; i++) {
    final k = open.indexOf(v[0]);
    if (k >= 0 && v.endsWith(close[k])) {
      v = v.substring(1, v.length - 1).trim();
    } else {
      break;
    }
  }
  // One trailing sentence punctuation mark isn't part of a value —
  // "jane@doe.com." is still an email.
  if (v.length > 2 && (v.endsWith('.') || v.endsWith(','))) {
    v = v.substring(0, v.length - 1);
  }
  return v;
}

/// Luhn check for a 16-digit card number (digits + optional space/dash).
bool _luhnOk(String s) {
  final d = s.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.length != 16) return false;
  var sum = 0;
  var alt = false;
  for (var i = d.length - 1; i >= 0; i--) {
    var n = d.codeUnitAt(i) - 0x30;
    if (alt && (n *= 2) > 9) n -= 9;
    sum += n;
    alt = !alt;
  }
  return sum % 10 == 0;
}

int _digitCount(String s) =>
    s.runes.where((r) => r >= 0x30 && r <= 0x39).length;

bool _looksJson(String s) {
  if (s.length < 2) return false;
  final first = s[0], last = s[s.length - 1];
  if (!((first == '{' && last == '}') || (first == '[' && last == ']'))) {
    return false;
  }
  try {
    jsonDecode(s);
    return true;
  } catch (_) {
    return false;
  }
}

// ── New entity detectors (see detectTags emissions) ────────────────────────
// Academic / identifiers (scan-anywhere; each keyword-anchored or shape-unique).
final _doi = RegExp(r'\b10\.\d{4,9}/[-._;()/:A-Za-z0-9]+');
final _arxiv = RegExp(
  r'\barxiv[:\s/]\s*(?:\d{4}\.\d{4,5}(?:v\d+)?|[a-z-]+(?:\.[A-Z]{2})?/\d{7})',
  caseSensitive: false,
);
final _orcid = RegExp(
  r'\borcid(?:\.org/|[:\s]+)\s*(?:\d{4}-){3}\d{3}[\dxX]\b',
  caseSensitive: false,
);
// Whole-value bank / id shapes (checked against the unwrapped value `v`).
final _iban = RegExp(r'^[A-Z]{2}\d{2}[A-Z0-9 ]{11,32}$');
final _ssn = RegExp(r'^(?!000|666|9\d\d)\d{3}-(?!00)\d{2}-(?!0000)\d{4}$');
final _vin = RegExp(r'^[A-HJ-NPR-Za-hj-npr-z0-9]{17}$');
final _postUk = RegExp(r'^[A-Za-z]{1,2}\d[A-Za-z\d]?\s?\d[A-Za-z]{2}$');
final _postCa =
    RegExp(r'^[A-CEGHJ-NPR-TVXYa-ceghj-npr-tvxy]\d[A-Za-z]\s?\d[A-Za-z]\d$');
final _base64 = RegExp(r'^[A-Za-z0-9+/]{64,}={0,2}$');
final _nonHex = RegExp(r'[G-Zg-z+/=]');
// Coordinates (DMS glyphs) and Open Location / plus codes.
final _dms = RegExp(
  r'''\d{1,3}\s?°\s?\d{1,2}\s?['′]\s?(?:\d{1,2}(?:\.\d+)?\s?["″])?\s?[NSEWnsew]\b''',
);
// Plus codes are canonically UPPERCASE and always carry letters at real-world
// lengths — case-sensitivity plus a required letter keeps arithmetic
// ("4567+89") and lowercase words from reading as locations.
final _plusCode = RegExp(
  r'\b(?=[23456789CFGHJMPQRVWX]*[CFGHJMPQRVWX])'
  r'[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3}\b',
);
// Tabular / markdown table.
final _mdTable = RegExp(r'(^|\n)[ \t]*\|?[ \t]*:?-{3,}:?[ \t]*\|[ \t]*:?-{3,}:?');
// Keyword-gated (bare shape too ambiguous without the keyword).
final _isbnKw = RegExp(r'\bISBN(?:[-\s]?1[03])?\b', caseSensitive: false);
final _isbnNum = RegExp(r'\b(?:97[89][-\s]?)?(?:\d[-\s]?){9}[\dxX]\b');
// SWIFT/BIC — the bare 8-char code is any uppercase word ("OVERVIEW",
// "CONCERTS"), so require a `SWIFT:`/`BIC:` or "swift code X" anchor. The code
// group is case-sensitive uppercase; the keyword casings are spelled out so the
// keyword stays case-insensitive without also lowercasing the code.
final _swift = RegExp(
  r'(?:SWIFT|Swift|swift|BIC|Bic|bic)(?:\s+[Cc]ode)?\s*:\s*'
  r'([A-Z]{6}[A-Z0-9]{2}(?:[A-Z0-9]{3})?)\b'
  r'|(?:SWIFT|Swift|swift|BIC|Bic|bic)\s+[Cc]ode\s+'
  r'([A-Z]{6}[A-Z0-9]{2}(?:[A-Z0-9]{3})?)\b',
);
final _gitKw = RegExp(
  r'\b(commit|sha\d*|revision|cherry-pick|rebase|git\s+\w+)\b',
  caseSensitive: false,
);
// Require at least one hex LETTER so a plain decimal number (a price, an id,
// "1000000") isn't read as a commit SHA. `sha\d*` in the keyword also lets
// "sha256:" match (the `\bsha\b` form missed it).
// Real SHAs at 7+ chars virtually always mix letters AND digits — requiring
// both keeps all-hex English words ("defaced", "acceded") from reading as
// commits.
final _shaHex =
    RegExp(r'\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\d)[0-9a-f]{7,40}\b');
final _routingKw = RegExp(r'\b(routing|aba|rtn)\b', caseSensitive: false);
final _routingNum = RegExp(r'\b\d{9}\b');
final _couponKw = RegExp(
  r'\b(coupon|promo(?:\s?code)?|voucher|discount|use\s+code)\b',
  caseSensitive: false,
);
final _couponCode = RegExp(r'\b(?=[A-Z0-9]*[A-Z])(?=[A-Z0-9]*\d)[A-Z0-9]{4,15}\b');
// Crypto wallet addresses — shape-unique, near-zero FP (0x+40hex; bech32 bc1…).
final _ethAddr = RegExp(r'\b0x[a-fA-F0-9]{40}\b');
final _btcAddr = RegExp(r'\bbc1[a-z0-9]{25,62}\b');
// Unified diff / patch markers — distinctive, low FP.
final _diff = RegExp(
  r'(^|\n)(diff --git |@@ -\d+(,\d+)? \+\d+(,\d+)? @@|index [0-9a-f]{7,}\.\.)',
);
// host:port — host must be localhost / IPv4 / dotted-domain (kills HH:MM, ratios).
final _hostPort = RegExp(
  r'\b(localhost|(?:\d{1,3}\.){3}\d{1,3}|[a-z0-9-]+(?:\.[a-z0-9-]+)+)'
  r':(?:6553[0-5]|655[0-2]\d|65[0-4]\d\d|6[0-4]\d{3}|[1-9]\d{0,3})\b',
  caseSensitive: false,
);
// Source-file line references (`pipeline.rs:427`, `server.log:1042`) look
// exactly like host:port — a "host" whose last label is a code/text file
// extension isn't one.
final _codeFileHost = RegExp(
  r'\.(rs|py|ts|tsx|js|jsx|mjs|go|dart|cs|java|kt|kts|cpp|cc|c|h|hpp|rb|php'
  r'|swift|scala|sh|ps1|vue|svelte|sql|yml|yaml|toml|json|xml|html|css|md'
  r'|log|txt|csv|lock|conf|cfg|ini|ex|exs|erl|lua|jl|zig|tf)$',
);
final _hexdump =
    RegExp(r'(^|\n)[0-9a-fA-F]{6,8}[:\s]\s+(?:[0-9a-fA-F]{2}\s){4,}');
final _envVar = RegExp(r'(?:^|\n)[ \t]*(?:export\s+)?([A-Z][A-Z0-9_]{2,})=\S');
// Shouted note prefixes ("IMPORTANT=…", "TODO=…") that are not env config.
const _envStop = {
  'IMPORTANT', 'TODO', 'NOTE', 'NOTES', 'WARNING', 'FIXME', 'HACK', 'XXX',
  'TBD', 'WIP', 'FYI', 'PS', 'NB', 'RE', 'ASAP', 'ERROR', 'INFO', 'DEBUG',
};
// Issue keys need 2+ digits: single-digit CAPS-dash tokens are standards and
// product names (SOC-2, GPT-4, WCAG-2), not tickets; real trackers are well
// past #9 by the time anyone pastes a key.
final _ticket = RegExp(r'\b([A-Z]{2,10})-(\d{2,})\b');
final _math = RegExp(
  r'\\(?:frac|sqrt|sum|int|prod|lim|alpha|beta|gamma|delta|theta|lambda|sigma'
  r'|pi|infty|partial|nabla|cdot|times|leq|geq|neq|approx|begin|end)\b'
  r'|\\\[|\\\]|\\\(|\\\)|\$\$[^$]+\$\$',
);
// Named CSS colors: fire only when the whole value IS a (non-ambiguous) color
// name, or a color name sits DIRECTLY ADJACENT to a color-context word
// ("background: teal", "orange fill") — never mere co-occurrence in a blob
// ("theme park with orange groves" must NOT tag color).
final _colorAdj = RegExp(
  r'\b(?:colou?rs?|background|foreground|shade|hue|swatch|palette|hex|rgba?'
  r'|paint|fill|stroke|theme)\b[\s:=(-]+([a-z]{3,20})\b'
  r'|\b([a-z]{3,20})[\s:=)-]+(?:colou?rs?|background|foreground|shade|hue'
  r'|swatch|palette|hex|rgba?|paint|fill|stroke|theme)\b',
  caseSensitive: false,
);

/// Prefixes that look like ticket keys (`ABC-123`) but aren't — standards,
/// codecs, formats. Guards the `_ticket` scan.
const _ticketStop = {
  'UTF', 'ISO', 'RFC', 'COVID', 'SARS', 'IPV', 'SHA', 'MD', 'WIN', 'ES', 'ECMA',
  'ISBN', 'EAN', 'UPC', 'USB', 'SATA', 'PCI', 'DDR', 'CAT', 'RJ', 'ISS', 'GMT',
  'UTC', 'ID', 'PO', 'IMG', 'MP', 'MPEG', 'JPEG', 'WWII', 'WWI', 'ITU', 'ANSI',
  'IEC', 'DIN', 'EN',
  // highways / products / aircraft: US-101, WD-40, KC-135, AS-201, SR-99
  'US', 'WD', 'KC', 'AS', 'MW', 'SR', 'MC',
  // model names / standards / vulns: GPT-4o? (GPT-35), SOC-2, DSS-40,
  // WCAG-21, CVE-2024-…, RTX-4090, GTX-1080
  'GPT', 'SOC', 'DSS', 'WCAG', 'CVE', 'RTX', 'GTX',
};

/// CSS4 named colors (lowercased). Used only via the whole-value / color-context
/// paths above, never free-scanned.
const _cssColors = {
  'aliceblue', 'antiquewhite', 'aqua', 'aquamarine', 'azure', 'beige', 'bisque',
  'black', 'blanchedalmond', 'blue', 'blueviolet', 'brown', 'burlywood',
  'cadetblue', 'chartreuse', 'chocolate', 'coral', 'cornflowerblue', 'cornsilk',
  'crimson', 'cyan', 'darkblue', 'darkcyan', 'darkgoldenrod', 'darkgray',
  'darkgreen', 'darkkhaki', 'darkmagenta', 'darkolivegreen', 'darkorange',
  'darkorchid', 'darkred', 'darksalmon', 'darkseagreen', 'darkslateblue',
  'darkslategray', 'darkturquoise', 'darkviolet', 'deeppink', 'deepskyblue',
  'dimgray', 'dodgerblue', 'firebrick', 'floralwhite', 'forestgreen', 'fuchsia',
  'gainsboro', 'ghostwhite', 'gold', 'goldenrod', 'gray', 'green', 'greenyellow',
  'honeydew', 'hotpink', 'indianred', 'indigo', 'ivory', 'khaki', 'lavender',
  'lavenderblush', 'lawngreen', 'lemonchiffon', 'lightblue', 'lightcoral',
  'lightcyan', 'lightgoldenrodyellow', 'lightgray', 'lightgreen', 'lightpink',
  'lightsalmon', 'lightseagreen', 'lightskyblue', 'lightslategray',
  'lightsteelblue', 'lightyellow', 'lime', 'limegreen', 'linen', 'magenta',
  'maroon', 'mediumaquamarine', 'mediumblue', 'mediumorchid', 'mediumpurple',
  'mediumseagreen', 'mediumslateblue', 'mediumspringgreen', 'mediumturquoise',
  'mediumvioletred', 'midnightblue', 'mintcream', 'mistyrose', 'moccasin',
  'navajowhite', 'navy', 'oldlace', 'olive', 'olivedrab', 'orange', 'orangered',
  'orchid', 'palegoldenrod', 'palegreen', 'paleturquoise', 'palevioletred',
  'papayawhip', 'peachpuff', 'peru', 'pink', 'plum', 'powderblue', 'purple',
  'rebeccapurple', 'red', 'rosybrown', 'royalblue', 'saddlebrown', 'salmon',
  'sandybrown', 'seagreen', 'seashell', 'sienna', 'silver', 'skyblue',
  'slateblue', 'slategray', 'snow', 'springgreen', 'steelblue', 'tan', 'teal',
  'thistle', 'tomato', 'turquoise', 'violet', 'wheat', 'white', 'whitesmoke',
  'yellow', 'yellowgreen',
};

/// CSS color names whose everyday meaning (metal, fruit, name, weather) makes a
/// bare whole-value match too noisy — these are allowed only via the adjacent
/// color-context path, not as a standalone value.
const _ambiguousColor = {
  'gold', 'orange', 'tan', 'navy', 'plum', 'olive', 'peru', 'lime', 'snow',
  'coral', 'salmon', 'chocolate', 'tomato', 'wheat', 'sienna',
};

/// ISO-13616 mod-97 checksum for an IBAN candidate.
bool _ibanOk(String raw) {
  final s = raw.replaceAll(' ', '').toUpperCase();
  if (s.length < 15 || s.length > 34) return false;
  if (!RegExp(r'^[A-Z]{2}\d{2}[A-Z0-9]+$').hasMatch(s)) return false;
  final rearranged = s.substring(4) + s.substring(0, 4);
  var rem = 0;
  for (final cu in rearranged.codeUnits) {
    final v = (cu >= 0x41 && cu <= 0x5A) ? cu - 0x41 + 10 : cu - 0x30; // A→10
    if (v >= 10) rem = (rem * 10 + v ~/ 10) % 97;
    rem = (rem * 10 + v % 10) % 97;
  }
  return rem == 1;
}

/// VIN position-9 check digit (ISO 3779), so a random 17-char token can't match.
bool _vinOk(String raw) {
  final s = raw.toUpperCase();
  const t = {
    'A': 1, 'B': 2, 'C': 3, 'D': 4, 'E': 5, 'F': 6, 'G': 7, 'H': 8, 'J': 1,
    'K': 2, 'L': 3, 'M': 4, 'N': 5, 'P': 7, 'R': 9, 'S': 2, 'T': 3, 'U': 4,
    'V': 5, 'W': 6, 'X': 7, 'Y': 8, 'Z': 9,
  };
  const w = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2];
  var sum = 0;
  for (var i = 0; i < 17; i++) {
    final c = s.codeUnitAt(i);
    final val = (c >= 0x30 && c <= 0x39) ? c - 0x30 : (t[s[i]] ?? -1);
    if (val < 0) return false;
    sum += val * w[i];
  }
  final r = sum % 11;
  return s[8] == (r == 10 ? 'X' : '$r');
}

/// ABA (US bank routing) mod-10 weighted checksum on a 9-digit string.
bool _abaOk(String d) {
  final n = d.codeUnits.map((c) => c - 0x30).toList();
  final sum =
      3 * (n[0] + n[3] + n[6]) + 7 * (n[1] + n[4] + n[7]) + (n[2] + n[5] + n[8]);
  return sum % 10 == 0;
}

/// True when [s] looks like consistent tabular data: TSV (≥1 tab, identical per
/// line) or CSV (≥3 rows, identical comma count ≥2). Prose commas vary per line.
bool _looksTabular(String s) {
  final lines = s.split('\n').where((l) => l.trim().isNotEmpty).toList();
  if (lines.length < 2) return false;
  // Leading tabs are indentation ONLY when every line is indented (Makefile
  // recipes, Go bodies) — a lone leading tab is an empty first CELL in a
  // spreadsheet copy, so trimming unconditionally would break real TSVs.
  final allIndented =
      lines.every((l) => l.startsWith('\t') || l.startsWith(' '));
  final tabs = lines
      .map((l) => '\t'.allMatches(allIndented ? l.trimLeft() : l).length)
      .toList();
  if (tabs.first >= 1 && tabs.every((c) => c == tabs.first)) return true; // TSV
  // Same-comma-count lines also describe argument lists — code isn't a CSV.
  // Two gates: explicit code markers anywhere, and call-shaped lines
  // (`foo(a, b, c)` — every line ending in a closing paren).
  if (lines.length >= 3 && !_codeHint.hasMatch(s)) {
    final callish =
        lines.every((l) => RegExp(r'\)[,;]?\s*$').hasMatch(l.trimRight()));
    if (!callish) {
      final commas = lines.map((l) => ','.allMatches(l).length).toList();
      if (commas.first >= 2 && commas.every((c) => c == commas.first)) {
        return true;
      }
    }
  }
  return false;
}

// ── In-prose entity scanners ───────────────────────────────────────────────
// Match an entity ANYWHERE in the text, not just as the whole trimmed value
// (the anchored `_url`/`_email`/… above only fire on a whole-value clip). This
// is what makes an IP / UUID / path / phone embedded in a longer note findable.
// Precision over recall: this runs on everything copied.
final _urlInProse = RegExp(r'(https?://|www\.)\S+', caseSensitive: false);
final _emailInProse = RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+');
// IPv4: four 0-255 octets, bounded so it can't sit inside a longer dotted run
// (1.2.3.4.5) or a 3-part version (1.2.3).
final _ipInProse = RegExp(
  r'(?<![\w.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}'
  r'(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\w.])',
);
final _uuidInProse = RegExp(
  r'(?<![0-9a-fA-F-])'
  r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  r'(?![0-9a-fA-F-])',
);
final _macInProse = RegExp(
  r'(?<![0-9A-Fa-f:-])(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:-])',
);
// Geo: two decimals, comma-separated, ≥4 fractional digits each (so "1.5, 2.5"
// doesn't register).
final _geoInProse =
    RegExp(r'(?<![\d.])[-+]?\d{1,2}\.\d{4,},\s?[-+]?\d{1,3}\.\d{4,}(?![\d.])');
// Windows drive path (C:\…) or UNC (\\…). Double-quoted to embed the quote char.
final _winPathInProse = RegExp("(?<![\\w])(?:[a-zA-Z]:\\\\|\\\\\\\\)[^\\s\"<>|]+");
// Unix absolute / ~ / . path, ≥2 segments. Lookbehind rejects a slash after a
// word char, so URLs (http://), "and/or", "2024/01/02" never match.
final _unixPathInProse = RegExp(r'(?<![\w:/~.])[~.]?(?:/[\w.-]+){2,}/?(?![\w])');
// Bare relative path with extension (app/lib/foo.dart) — gated on "no URL".
final _relPathInProse =
    RegExp(r'(?<![\w/])[\w.-]+(?:/[\w.-]+)+\.[A-Za-z0-9]{1,8}(?![\w])');
// Credit card: grouped 4×4; every match Luhn-checked before emitting.
final _cardInProse = RegExp(r'(?<!\d)\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{4}(?!\d)');
// Phone: requires 3-3-4 grouping and/or +cc — never a bare digit run.
// Require a dash/dot before the final 4 digits (not a plain space) so uniformly
// space-grouped ids ("SKU 100 200 3000", "order 123 456 7890") don't read as a
// phone; real copied phones use "(555) 123-4567" / "415-555-1234" / "+1…".
final _phoneInProse = RegExp(
  r'(?<![\w.])(?:\+\d{1,3}[ .-]?)?\(?\d{3}\)?[ .-]\d{3}[.-]\d{4}(?!\d)',
);
// Scheme-less domain, TLD-allowlisted so "Node.js"/"main.py"/"README.md" don't
// match. Enriches search terms only (adds no tag).
final _bareDomain = RegExp(
  r'\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+'
  r'(?:com|org|net|io|co|dev|app|ai|edu|gov|info|xyz|uk|ca|de|fr|jp|au|nl|eu)\b',
  caseSensitive: false,
);

/// Parse the host from a matched URL/domain substring: strips scheme, `www.`,
/// userinfo, path/query/fragment, and port; lowercases. Null when empty.
String? _hostFromUrl(String url) {
  var u = url.trim();
  final scheme = u.indexOf('://');
  if (scheme >= 0) u = u.substring(scheme + 3);
  if (u.toLowerCase().startsWith('www.')) u = u.substring(4);
  final end = u.indexOf(RegExp(r'[/?#\s]'));
  if (end >= 0) u = u.substring(0, end);
  final at = u.indexOf('@');
  if (at >= 0) u = u.substring(at + 1);
  final colon = u.indexOf(':');
  if (colon >= 0) u = u.substring(0, colon);
  u = u.toLowerCase();
  return u.isEmpty ? null : u;
}

/// Service-noun concepts for a host, trying the full host then peeling the
/// leftmost label (`gist.github.com` → `github.com`). Exact-key lookup, so the
/// map's short/ambiguous hosts (`x.com`, `t.co`) never match a substring.
Iterable<String> _domainConceptsFor(String host) {
  var h = host;
  while (true) {
    final hit = kDomainConcepts[h];
    if (hit != null) return hit;
    final dot = h.indexOf('.');
    if (dot < 0) return const [];
    h = h.substring(dot + 1);
  }
}

/// Concept search-terms for structural entities found ANYWHERE in [content]
/// (embedded, markdown, mid-sentence), so a link/IP/path/phone mentioned inside
/// a snippet is still findable even though it isn't the whole value (and so
/// never earned a whole-value tag). Deterministic, ML-independent; [relic_db]
/// appends these to the FTS/trigram body. Mirrors [tagSearchTerms].
List<String> inProseSearchTerms(String? content) {
  if (content == null || content.isEmpty) return const [];
  final out = <String>{}; // dedupes across scanners
  // ONE character sweep, then skip every scanner whose required characters are
  // absent. See [_Charset]: this is a pure speed gate, never a behaviour one.
  final has = _Charset.of(content);

  // ── URLs + domain→noun map ──
  // "https?://" needs a colon, "www." needs a dot.
  if ((has.colon || has.dot) && _urlInProse.hasMatch(content)) {
    out.addAll(const ['url', 'link', 'website', 'hyperlink', 'web']);
    for (final m in _urlInProse.allMatches(content)) {
      final host = _hostFromUrl(m.group(0)!);
      if (host != null) out.addAll(_domainConceptsFor(host));
    }
  }
  // Scheme-less domains (spotify.com typed bare) — generic link terms + the
  // service map, but only when a real scheme URL wasn't already the source.
  if (has.dot) {
    for (final m in _bareDomain.allMatches(content)) {
      out.addAll(const ['url', 'link', 'website', 'web']);
      final host = _hostFromUrl(m.group(0)!);
      if (host != null) out.addAll(_domainConceptsFor(host));
    }
  }
  if (has.at && _emailInProse.hasMatch(content)) {
    out.addAll(const ['email', 'address', 'contact', 'mail']);
  }

  // ── TIER A structural scanners (low FP) ──
  if (has.digit && has.dot && _ipInProse.hasMatch(content)) {
    out.addAll(const ['ip', 'ipaddress', 'network', 'host']);
  }
  // Hex quads joined by literal hyphens.
  if (has.hyphen && _uuidInProse.hasMatch(content)) {
    out.addAll(const ['uuid', 'guid', 'identifier']);
  }
  // Octets joined by [:-].
  if ((has.colon || has.hyphen) && _macInProse.hasMatch(content)) {
    out.addAll(const ['mac', 'macaddress', 'hardware']);
  }
  if (has.digit) {
    for (final m in _cardInProse.allMatches(content)) {
      if (_luhnOk(m.group(0)!)) {
        out.addAll(const ['card', 'creditcard', 'payment']);
        break;
      }
    }
  }
  if ((has.backslash && _winPathInProse.hasMatch(content)) ||
      (has.slash && _unixPathInProse.hasMatch(content))) {
    out.addAll(const ['path', 'file', 'directory', 'folder', 'filepath']);
  }

  // ── TIER B scanners (behind precision gates) ──
  // Two decimals separated by a comma.
  if (has.digit &&
      has.dot &&
      has.comma &&
      _geoInProse.hasMatch(content)) {
    out.addAll(const ['geo', 'coordinates', 'location', 'gps']);
  }
  // The final group is `[.-]\d{4}`, so a space-only grouping can't be a phone.
  if (has.digit &&
      (has.hyphen || has.dot) &&
      _phoneInProse.hasMatch(content)) {
    out.addAll(const ['phone', 'telephone', 'number', 'contact']);
  }
  // Value shapes mentioned mid-text: the TAGS are gated to near-naked values,
  // so these terms keep long texts findable by concept ("price", "time",
  // "percentage") without mislabeling the whole clip. Every branch of each of
  // these four requires a digit — symbol-only text ("$", "%") is not a value.
  if (has.digit) {
    if (_currency.hasMatch(content)) {
      out.addAll(const ['currency', 'money', 'price', 'amount', 'cost']);
    }
    if (_percent.hasMatch(content)) {
      out.addAll(const ['percent', 'percentage']);
    }
    if (_time.hasMatch(content)) {
      out.addAll(const ['time', 'clock']);
    }
    if (_duration.hasMatch(content)) {
      out.addAll(const ['duration']);
    }
    if (_measureInProse.hasMatch(content)) {
      out.addAll(const ['measurement']);
    }
  }
  // Relative a/b/file.ext — with URL AND bare-domain substrings removed
  // first, so a link's own path ("example.com/docs/guide.pdf") can't
  // masquerade as a file path but a REAL path co-existing with a link
  // (commit messages, PR text) still counts.
  //
  // Gated hard because it is the single most expensive scanner here: without
  // the gate it rewrites the whole string TWICE before matching, on every
  // relic, whether or not a slash exists anywhere in it.
  if (has.slash &&
      has.dot &&
      !out.contains('path') &&
      _relPathInProse.hasMatch(
          content.replaceAll(_urlInProse, ' ').replaceAll(_bareDomain, ' '))) {
    out.addAll(const ['path', 'file', 'directory', 'folder', 'filepath']);
  }

  return out.toList();
}

/// Which characters a text contains, from a single pass over it.
///
/// Seventeen in-prose scanners each walking the whole string was measured at
/// 2.1–2.4ms per 3KB relic, which made it the dominant cost of building the
/// mobile search index (2658ms of a 2900ms build for 1000 relics) and of every
/// capture on every platform. No single regex was pathological; there were just
/// seventeen of them.
///
/// Every scanner needs specific characters to match at all: a phone number
/// cannot exist without a digit, a path without a slash, an email without '@'.
/// One sweep answers that for all of them at once.
///
/// A flag may gate a scanner ONLY when its pattern provably cannot match
/// without that character. A gate must never change what is emitted, only how
/// quickly the same answer is reached.
class _Charset {
  final bool digit;
  final bool at;
  final bool dot;
  final bool comma;
  final bool colon;
  final bool hyphen;
  final bool slash;
  final bool backslash;

  const _Charset._(this.digit, this.at, this.dot, this.comma, this.colon,
      this.hyphen, this.slash, this.backslash);

  factory _Charset.of(String s) {
    var digit = false,
        at = false,
        dot = false,
        comma = false,
        colon = false,
        hyphen = false,
        slash = false,
        backslash = false;
    for (var i = 0; i < s.length; i++) {
      switch (s.codeUnitAt(i)) {
        case >= 0x30 && <= 0x39: // 0-9
          digit = true;
        case 0x40: // @
          at = true;
        case 0x2E: // .
          dot = true;
        case 0x2C: // ,
          comma = true;
        case 0x3A: // :
          colon = true;
        case 0x2D: // -
          hyphen = true;
        case 0x2F: // /
          slash = true;
        case 0x5C: // \
          backslash = true;
      }
    }
    return _Charset._(
        digit, at, dot, comma, colon, hyphen, slash, backslash);
  }
}

/// Deterministic subtype tags for a piece of text — structural facts (url,
/// path, hash, …), secret-class markers, and content shapes (json, code, sql,
/// graph, …). Includes `secret` when a secret-class pattern is found; callers
/// that don't mask secrets can strip it.
List<String> detectTags(String t) {
  final s = t.trim();
  final tags = <String>[];
  void add(String tag) {
    if (!tags.contains(tag)) tags.add(tag);
  }

  // A whole-value structural fact only makes sense for a single-line value.
  // Unwrap surrounding quotes/brackets first so `"app/foo.png"` still reads as
  // a path (the structural regexes are anchored to the whole value).
  if (!s.contains('\n')) {
    final v = _unwrap(s);
    if (_url.hasMatch(v) || _isBareDomainValue(v)) add('url');
    if (_email.hasMatch(v)) add('email');
    if (_ipv4.hasMatch(v)) add('ip');
    if (_color.hasMatch(v)) add('color');
    if (_uuidRe.hasMatch(v)) add('uuid');
    if (_isoDate.hasMatch(v)) {
      add('date');
    } else if (_version.hasMatch(v)) {
      add('version');
    }
    // A bare domain with a path ("example.com/a/file.pdf") is a link, not a
    // relative file path — url wins.
    if (!tags.contains('url') &&
        (_winPath.hasMatch(v) || _unixPath.hasMatch(v) || _relPath.hasMatch(v))) {
      add('path');
    }
    if (_mac.hasMatch(v)) add('mac');
    if (_hashHex.hasMatch(v)) add('hash');
    if (_geo.hasMatch(v)) add('geo');
    if (_card.hasMatch(v) && _luhnOk(v)) add('card');
    if (_iban.hasMatch(v) && _ibanOk(v)) {
      add('iban');
      add('bank');
    }
    if (_vin.hasMatch(v) && _vinOk(v)) {
      add('vin');
      add('vehicle');
    }
    if (_postUk.hasMatch(v) || _postCa.hasMatch(v)) add('postcode');
    if (_cssColors.contains(v.toLowerCase()) &&
        !_ambiguousColor.contains(v.toLowerCase())) {
      add('color');
    }
    // base64 blob: long, length%4==0, and must hold a non-hex char so a 64-hex
    // hash or a pure-digit run can't masquerade as one (a JWT's dots exclude it).
    if (v.length % 4 == 0 && _base64.hasMatch(v) && _nonHex.hasMatch(v)) {
      add('base64');
    }
    // SSN — emit `secret` too so masking hides it; BEFORE the phone check so a
    // 3-2-4 SSN doesn't get claimed as a phone number.
    if (_ssn.hasMatch(v)) {
      add('ssn');
      add('secret');
    }
    // phone only when nothing else claimed the value and it's phone-shaped: 7–13
    // digits, and a long bare run (>11 digits, no separators) is treated as an
    // id/number, not a phone. Dotted quads that failed the ip octet check
    // ("999.999.999.999", "192.168.001.001") are malformed IPs, not phones.
    if (tags.isEmpty &&
        _phone.hasMatch(v) &&
        !RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(v)) {
      final digits = _digitCount(v);
      final hasSep = RegExp(r'[\s().+-]').hasMatch(v);
      if (digits >= 7 && digits <= 13 && (hasSep || digits <= 11)) add('phone');
    }
  }

  // Secrets (anywhere in the text). JWT is both its own tag and secret-class —
  // whether it IS the clip or sits inside one (a curl command must mask too).
  if (_jwt.hasMatch(s) || _jwtInProse.hasMatch(s)) {
    add('jwt');
    add('secret');
  }
  if (_awsKey.hasMatch(s) ||
      _skKey.hasMatch(s) ||
      _prefixedToken.hasMatch(s) ||
      (s.contains('-----BEGIN') && s.contains('PRIVATE KEY'))) {
    add('secret');
  }

  // Content shapes.
  if (_looksJson(s)) add('json');
  if (_mdMarkers.hasMatch(s)) add('markdown');
  if (_codeHint.hasMatch(s)) add('code');
  if (_todo.hasMatch(s)) add('todo');
  if (_sql.hasMatch(s)) add('sql');
  if (_xml.hasMatch(s)) add('xml');
  if (_html.hasMatch(s)) add('html');
  if (_stack.hasMatch(s)) add('error');
  if (_command.hasMatch(s)) add('command');
  if (_track.hasMatch(s) || (_trackKw.hasMatch(s) && _trackNum.hasMatch(s))) {
    add('tracking');
  }
  if (_otpKw.hasMatch(s) && _otpNum.hasMatch(s)) add('otp');
  if (_receipt.hasMatch(s)) add('receipt');
  if (_address.hasMatch(s)) add('address');
  if (_graph.hasMatch(s) || _graphql.hasMatch(s)) add('graph');

  // Semantic value shapes — gated to naked / near-naked values: these tags
  // say what a clip IS, not what a long text happens to mention. A three-page
  // note with one "30%" inside is a note, not a `percent` (the icon and chip
  // follow the tag, so a stray match used to relabel the whole clip). Long
  // texts stay findable by concept via the in-prose terms instead.
  final valueShaped = !s.contains('\n') &&
      s.length <= 48 &&
      s.split(RegExp(r'\s+')).length <= 7;
  if (valueShaped) {
    if (_currency.hasMatch(s)) add('currency');
    if (_percent.hasMatch(s)) add('percent');
    if (_duration.hasMatch(s)) add('duration');
    if (_time.hasMatch(s)) add('time');
    if (_measure.hasMatch(s)) add('measurement');
    if (_handle.hasMatch(s)) add('handle');
    // A hex color (#fff / #aabbcc) is already tagged `color`; don't double-tag
    // it as a hashtag.
    if (_hashtag.hasMatch(s) && !tags.contains('color')) add('hashtag');
  }

  // Entity / content detectors (scan-anywhere; keyword- or shape-gated). `paper`
  // and `bank` are chip-unifying tags; the rest lean on synonyms for concepts.
  if (_doi.hasMatch(s)) {
    add('doi');
    add('paper');
  }
  if (_arxiv.hasMatch(s)) {
    add('arxiv');
    add('paper');
  }
  if (_orcid.hasMatch(s)) add('orcid');
  if (_dms.hasMatch(s)) add('geo');
  if (_plusCode.hasMatch(s)) {
    add('location');
    add('geo');
  }
  if (_mdTable.hasMatch(s)) {
    add('table');
    add('markdown');
  }
  if (_isbnKw.hasMatch(s) && _isbnNum.hasMatch(s)) {
    add('isbn');
    add('book');
  }
  if (_swift.hasMatch(s)) {
    add('swift');
    add('bank');
  }
  if (_gitKw.hasMatch(s) && _shaHex.hasMatch(s)) add('commit');
  for (final m in _hostPort.allMatches(s)) {
    // `pipeline.rs:427` is a file:line reference, not a socket.
    if (!_codeFileHost.hasMatch(m.group(1)!.toLowerCase())) {
      add('port');
      break;
    }
  }
  if (_hexdump.hasMatch(s)) add('hexdump');
  // ALL matches, not just the first — one shouted "NOTE=…" line above a real
  // .env block must not suppress the tag.
  for (final m in _envVar.allMatches(s)) {
    if (!_envStop.contains(m.group(1))) {
      add('env');
      break;
    }
  }
  // Guard against LaTeX-command false hits on Windows path segments (C:\sum\…,
  // C:\builds\prod\…) — whole-value paths carry the tag; multi-line path lists
  // don't, so check the shape directly.
  if (_math.hasMatch(s) &&
      !tags.contains('path') &&
      !_winPathInProse.hasMatch(s)) {
    add('math');
  }
  if (_looksTabular(s)) {
    add('table');
    add('csv');
  }
  for (final m in _ticket.allMatches(s)) {
    if (!_ticketStop.contains(m.group(1))) {
      add('ticket');
      break;
    }
  }
  if (_routingKw.hasMatch(s)) {
    for (final m in _routingNum.allMatches(s)) {
      if (_abaOk(m.group(0)!)) {
        add('routing');
        add('bank');
        break;
      }
    }
  }
  if (_couponKw.hasMatch(s) && _couponCode.hasMatch(s)) add('coupon');
  if (_ethAddr.hasMatch(s) || _btcAddr.hasMatch(s)) {
    add('wallet');
    add('crypto');
  }
  if (_diff.hasMatch(s)) {
    add('diff');
    add('code');
  }
  // Named color adjacent to a color-context word (whole-value css-name handled
  // in the block above). Adjacency — not mere co-occurrence — is the gate, and
  // like the value shapes it only fires for near-naked values: a long design
  // doc that mentions "background: green" is a doc, not a color.
  if (valueShaped && !tags.contains('color')) {
    for (final m in _colorAdj.allMatches(s)) {
      final w = (m.group(1) ?? m.group(2))?.toLowerCase();
      if (w != null && _cssColors.contains(w)) {
        add('color');
        break;
      }
    }
  }

  // `number` last — only for naked/near-naked values (same gate as the value
  // shapes: a document containing digits is not "a number"), and only when no
  // more-specific digit-based tag already claimed the value (phone/card/otp/
  // tracking/ip/hash/uuid/mac/version/date).
  if (valueShaped && !tags.any(_specificDigit.contains) && _hasNumber(s)) {
    add('number');
  }

  return tags;
}

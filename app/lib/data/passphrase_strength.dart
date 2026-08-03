import 'dart:math';

import 'wordlist.dart';

/// A conservative, dependency-free passphrase-strength estimator for the vault
/// passphrase (the secret that derives the encryption key). It is deliberately
/// pessimistic: it never rewards a passphrase it cannot explain, and it caps the
/// visible bands well below the true entropy of a long diceware phrase so the
/// meter reads "Strong" rather than a meaningless five-digit bit count.
///
/// Two independent models run and the larger wins:
///   (a) a diceware path — if every whitespace-separated token is a word from
///       the EFF short wordlist, the phrase earns `words * log2(1296)` bits;
///   (b) a character path — `length * log2(pool)` over the observed character
///       classes (lowercase 26, uppercase 26, digits 10, symbols ~33), halved
///       when the input is a single dictionary word or one of the worst-known
///       passwords.
/// Nothing here blocks submission; it only drives the meter and the nudge.

final double _bitsPerDicewareWord = log(1296) / ln2; // log2(1296) ~= 10.34

/// The character-class pool sizes used by the character path. Symbols is a
/// deliberately rough ~33 (printable ASCII punctuation plus space).
const int _lowerPool = 26;
const int _upperPool = 26;
const int _digitPool = 10;
const int _symbolPool = 33;

/// A small embedded list of the worst-known passwords. Membership halves the
/// character-path estimate. Lowercase; comparison is case-insensitive.
const List<String> worstPasswords = [
  'password', 'passw0rd', 'password1', 'password123', '123456', '1234567',
  '12345678', '123456789', '1234567890', '12345', '111111', '000000',
  'qwerty', 'qwertyuiop', 'qwerty123', 'abc123', 'a1b2c3', 'letmein',
  'welcome', 'welcome1', 'admin', 'admin123', 'root', 'toor', 'login',
  'iloveyou', 'monkey', 'dragon', 'sunshine', 'princess', 'football',
  'baseball', 'superman', 'batman', 'trustno1', 'master', 'shadow',
  'michael', 'jennifer', 'hunter2', 'starwars', 'whatever', 'access',
  'flower', 'freedom', 'ninja', 'secret', 'changeme', 'default', 'test',
];

final Set<String> _worstSet = worstPasswords.toSet();

double _log2(num x) => log(x) / ln2;

/// The diceware estimate: if the phrase is entirely EFF-wordlist words, each
/// word is worth `log2(1296)` bits; otherwise 0 (this model does not apply).
double dicewareBits(String passphrase) {
  final tokens = passphrase
      .trim()
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return 0;
  for (final t in tokens) {
    if (!effShortWordSet.contains(t.toLowerCase())) return 0;
  }
  return tokens.length * _bitsPerDicewareWord;
}

/// The character-class estimate: `length * log2(pool)`, halved when the input is
/// a single dictionary word or a worst-known password.
double charClassBits(String passphrase) {
  if (passphrase.isEmpty) return 0;
  var pool = 0;
  if (passphrase.contains(RegExp('[a-z]'))) pool += _lowerPool;
  if (passphrase.contains(RegExp('[A-Z]'))) pool += _upperPool;
  if (passphrase.contains(RegExp('[0-9]'))) pool += _digitPool;
  if (passphrase.contains(RegExp('[^a-zA-Z0-9]'))) pool += _symbolPool;
  if (pool == 0) return 0;
  var bits = passphrase.length * _log2(pool);

  final trimmed = passphrase.trim();
  final lower = trimmed.toLowerCase();
  final singleWord = !trimmed.contains(RegExp(r'\s')) &&
      effShortWordSet.contains(lower);
  if (singleWord || _worstSet.contains(lower)) bits *= 0.5;
  return bits;
}

/// The final estimate: the larger of the two models.
double estimateEntropyBits(String passphrase) =>
    max(dicewareBits(passphrase), charClassBits(passphrase));

/// The four strength bands the meter renders.
enum PassphraseBand { weak, okay, strong, excellent }

/// Map an entropy estimate to a band: <40 weak, 40-59 okay, 60-79 strong,
/// >=80 excellent.
PassphraseBand bandForBits(double bits) {
  if (bits < 40) return PassphraseBand.weak;
  if (bits < 60) return PassphraseBand.okay;
  if (bits < 80) return PassphraseBand.strong;
  return PassphraseBand.excellent;
}

/// A computed strength result: the raw bits, its band, and display helpers.
class PassphraseStrength {
  final double bits;
  final PassphraseBand band;
  const PassphraseStrength(this.bits, this.band);

  /// The one-word label shown next to the bar.
  String get label => switch (band) {
        PassphraseBand.weak => 'Weak',
        PassphraseBand.okay => 'Okay',
        PassphraseBand.strong => 'Strong',
        PassphraseBand.excellent => 'Excellent',
      };

  /// A 0..1 fill for the meter bar, saturating at the 80-bit "Excellent" line.
  double get fraction => (bits / 80).clamp(0.0, 1.0);

  /// Weak passphrases earn a one-line nudge under the meter.
  bool get needsNudge => band == PassphraseBand.weak;
}

/// Estimate the strength of [passphrase].
PassphraseStrength estimatePassphrase(String passphrase) {
  final bits = estimateEntropyBits(passphrase);
  return PassphraseStrength(bits, bandForBits(bits));
}

/// Build a suggested passphrase of [wordCount] words drawn from the EFF short
/// wordlist and joined with single spaces. [rng] defaults to a CSPRNG
/// ([Random.secure]); tests inject a seeded [Random] for determinism.
String suggestPassphrase({Random? rng, int wordCount = 5}) {
  final r = rng ?? Random.secure();
  return List.generate(
    wordCount,
    (_) => effShortWordlist[r.nextInt(effShortWordlist.length)],
  ).join(' ');
}

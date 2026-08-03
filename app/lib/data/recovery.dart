import 'dart:typed_data';

import 'package:hashlib/hashlib.dart';

/// Crockford base32 (https://www.crockford.com/base32.html): the digits
/// `0-9A-Z` minus `I L O U`, uppercase, no padding. MSB-first 5-bit packing.
/// Decode is human-tolerant: it ignores spaces/hyphens, accepts lower case, and
/// folds the look-alikes `I`/`L` → `1` and `O` → `0` (but `U` stays invalid, so
/// it can never be confused with `V`).
class Crockford {
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// True if [ch] is a single canonical Crockford symbol (`0-9A-Z` minus
  /// `I L O U`). Callers that validate an already-[normalize]d string use this
  /// per symbol; it does not itself fold look-alikes.
  static bool isSymbol(String ch) => ch.length == 1 && _alphabet.contains(ch);

  static String encode(Uint8List data) {
    final out = StringBuffer();
    int buffer = 0;
    int bits = 0;
    for (final b in data) {
      buffer = (buffer << 8) | b;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        out.write(_alphabet[(buffer >> bits) & 0x1f]);
      }
      buffer &= (1 << bits) - 1;
    }
    if (bits > 0) {
      out.write(_alphabet[(buffer << (5 - bits)) & 0x1f]);
    }
    return out.toString();
  }

  /// Human-tolerant normalization of a single group/token for comparison (used
  /// by the recovery-kit re-entry proof): upper-case, drop spaces/hyphens/line
  /// breaks, and fold the look-alikes `I`/`L` → `1` and `O` → `0`, exactly as
  /// [decode] does per symbol. Does not validate the alphabet — it only puts two
  /// strings into the same canonical form so a match tolerates the same mistakes
  /// decode forgives.
  static String normalize(String s) {
    final out = StringBuffer();
    for (final rune in s.toUpperCase().runes) {
      final ch = String.fromCharCode(rune);
      if (ch == ' ' || ch == '-' || ch == '\n' || ch == '\r' || ch == '\t') {
        continue;
      }
      out.write((ch == 'I' || ch == 'L')
          ? '1'
          : ch == 'O'
              ? '0'
              : ch);
    }
    return out.toString();
  }

  /// Decode a Crockford string → bytes. Throws [FormatException] on any symbol
  /// outside the alphabet (after normalization). Trailing sub-byte bits are
  /// dropped, mirroring [encode]'s zero padding.
  static Uint8List decode(String s) {
    final out = <int>[];
    int buffer = 0;
    int bits = 0;
    for (final rune in s.toUpperCase().runes) {
      final ch = String.fromCharCode(rune);
      if (ch == ' ' || ch == '-' || ch == '\n' || ch == '\r' || ch == '\t') {
        continue;
      }
      final norm = (ch == 'I' || ch == 'L')
          ? '1'
          : ch == 'O'
              ? '0'
              : ch;
      final val = _alphabet.indexOf(norm);
      if (val < 0) throw FormatException('invalid base32 symbol: $ch');
      buffer = (buffer << 5) | val;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buffer >> bits) & 0xff);
        buffer &= (1 << bits) - 1;
      }
    }
    return Uint8List.fromList(out);
  }
}

/// Why a [RecoveryKit.parse] failed. [format] = this is not a Relic kit (the
/// `relic-mk-v1` tag is missing) — show "that doesn't look like a recovery
/// kit". [checksum] = it IS a kit but the key bytes don't add up (a mistype or
/// dropped character) — show "this kit looks mistyped, check it again".
enum RecoveryKitError { format, checksum }

class RecoveryKitException implements Exception {
  final RecoveryKitError kind;
  const RecoveryKitException(this.kind);
  @override
  String toString() => 'RecoveryKitException($kind)';
}

/// The printable/downloadable recovery kit (`docs/crypto.md`, doc 13 §2.4/§6).
/// It is the raw 32-byte master key in Crockford base32, plus a 2-byte checksum
/// so a mistyped kit fails cleanly instead of silently yielding a wrong key.
///
/// Format (`relic-mk-v1`):
/// ```
/// relic-mk-v1
/// email: jordan@example.com
/// XXXX XXXX XXXX XXXX XXXX XXXX XXXX XXXX XXXX XXXX XXXX XXXX XXXX XXXX
/// ```
/// 14 groups of 4: the first 13 (52 chars) are the master key, the last group
/// (4 chars) is the checksum. The checksum is over the key bytes only, so it
/// survives an email change and validates the key itself.
class RecoveryKit {
  static const formatTag = 'relic-mk-v1';

  /// Render the kit text for the given master key and account email.
  static String fromMk(Uint8List mk, String email) {
    final body = Crockford.encode(mk) + _checksum(mk); // 52 + 4 = 56 chars
    final groups = <String>[];
    for (var i = 0; i < body.length; i += 4) {
      groups.add(body.substring(i, i + 4));
    }
    return 'relic-mk-v1\nemail: $email\n${groups.join(' ')}\n';
  }

  /// The whitespace-separated key-line groups of a rendered kit (14 groups of 4
  /// from [fromMk]). Used by the re-entry proof to quiz the user on a couple of
  /// groups. Returns an empty list if the text has no group line.
  static List<String> groups(String kitText) {
    final lines = kitText
        .trim()
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return const [];
    return lines.last.split(RegExp(r'\s+')).where((g) => g.isNotEmpty).toList();
  }

  /// Parse kit text back to the master key (+ the email it carried). Throws a
  /// [RecoveryKitException] with [RecoveryKitError.format] when the `relic-mk-v1`
  /// tag is absent, or [RecoveryKitError.checksum] when the key body is the wrong
  /// length, undecodable, or fails the checksum.
  static ({Uint8List mk, String email}) parse(String text) {
    final raw = text.trim();
    if (!raw.toLowerCase().contains(formatTag)) {
      throw const RecoveryKitException(RecoveryKitError.format);
    }

    final emailMatch =
        RegExp(r'email:\s*(\S+)', caseSensitive: false).firstMatch(raw);
    final email = emailMatch?.group(1) ?? '';

    // Strip the tag and the whole email line, then keep only base32 symbols.
    var body = raw
        .replaceAll(RegExp('relic-mk-v1', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'email:\s*\S+', caseSensitive: false), ' ');
    final filtered =
        body.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').toUpperCase();
    if (filtered.length != 56) {
      throw const RecoveryKitException(RecoveryKitError.checksum);
    }

    final Uint8List mk;
    final Uint8List ck;
    try {
      mk = Crockford.decode(filtered.substring(0, 52));
      ck = Crockford.decode(filtered.substring(52));
    } on FormatException {
      throw const RecoveryKitException(RecoveryKitError.checksum);
    }
    if (mk.length != 32 || ck.length < 2) {
      throw const RecoveryKitException(RecoveryKitError.checksum);
    }
    final expect = _checksumBytes(mk);
    if (ck[0] != expect[0] || ck[1] != expect[1]) {
      throw const RecoveryKitException(RecoveryKitError.checksum);
    }
    return (mk: mk, email: email);
  }

  static Uint8List _checksumBytes(Uint8List mk) =>
      Uint8List.fromList(sha256.convert(mk).bytes.sublist(0, 2));

  static String _checksum(Uint8List mk) => Crockford.encode(_checksumBytes(mk));
}

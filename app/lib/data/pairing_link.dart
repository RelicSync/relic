/// https pairing links (docs/onboarding-funnel-2026-09.md, Workstream C).
///
/// The desktop's Add a device screen used to show a bare `relic-pair:v2:…`
/// string in its QR. Only Relic's own scanner could read it, so it did nothing
/// for a phone that had not installed Relic yet, and nothing for a person who
/// was about to pick the wrong door. The QR now carries the same payload inside
/// a real URL:
///
///     https://relic.space/pair#relic-pair:v2:<id>:<key>:<ah>:<hint>&t=<secs>&e=<email>
///
/// Everything after the `#` is a fragment. Browsers never send a fragment to
/// the server, so the channel key stays between the two devices, exactly as it
/// did in the bare QR. `t` is when the code was minted (unix seconds) so the
/// joining device can say "expired" without a relay round trip; `e` is the
/// account email so the phone can preselect the right identity (`login_hint`).
///
/// A phone camera resolves the URL on its own. With Relic installed, the OS
/// hands the link to the app (Universal Links / App Links) and pairing starts.
/// Without it, the web page opens and offers the store.
///
/// The bare string is still accepted everywhere: old desktops keep showing it,
/// and `relic://pair#<same fragment>` is the custom-scheme fallback the web
/// page uses when the OS did not claim the https link.
class PairingLink {
  /// The bare payload, `relic-pair:v2:…` (or v1). Feed this to
  /// `PairingCrypto.parseQr` / `NewDevicePairing.fromQr`.
  final String payload;

  /// When the trusted device minted the code, if the link carried it.
  final DateTime? issuedAt;

  /// The trusted device's account email, if the link carried it.
  final String? email;

  const PairingLink({required this.payload, this.issuedAt, this.email});

  static const host = 'relic.space';
  static const path = '/pair';
  static const https = 'https://$host$path';
  static const scheme = 'relic';

  /// How long a minted code stays live: the relay slots expire at ~120 s and
  /// the pollers give up at 110 s (`pairing.dart`). A link older than this is
  /// dead on arrival and the joining device should ask for a fresh scan.
  static const Duration codeLife = Duration(seconds: 120);

  static const _payloadPrefix = 'relic-pair:';

  /// Wrap a bare payload in the https link.
  static String build(String payload,
      {DateTime? issuedAt, String? email}) {
    assert(payload.startsWith(_payloadPrefix));
    final b = StringBuffer(https)
      ..write('#')
      ..write(payload);
    if (issuedAt != null) {
      b
        ..write('&t=')
        ..write(issuedAt.toUtc().millisecondsSinceEpoch ~/ 1000);
    }
    if (email != null && email.isNotEmpty) {
      b
        ..write('&e=')
        ..write(Uri.encodeQueryComponent(email));
    }
    return b.toString();
  }

  /// The custom-scheme twin of [build] for the same fragment
  /// (`relic://pair#…`). The web page uses it as a fallback.
  static String toCustomScheme(String link) {
    final i = link.indexOf('#');
    if (i < 0) return link;
    return '$scheme://pair${link.substring(i)}';
  }

  /// True when [raw] is a bare pairing payload or a pairing link of either
  /// scheme. Cheap enough for a scanner's per-frame filter.
  static bool looksLikePairing(String raw) {
    final s = raw.trim();
    if (s.startsWith(_payloadPrefix)) return true;
    return parse(s) != null;
  }

  /// Parse a scanned or tapped string. Accepts the bare payload, the https
  /// link and the `relic://pair` fallback. Null when it is none of those.
  static PairingLink? parse(String raw) {
    final s = raw.trim();
    if (s.startsWith(_payloadPrefix)) return PairingLink(payload: s);
    final Uri uri;
    try {
      uri = Uri.parse(s);
    } on FormatException {
      return null;
    }
    return fromUri(uri);
  }

  /// [parse] for a [Uri] the OS already delivered (app_links).
  static PairingLink? fromUri(Uri uri) {
    final isHttps = uri.scheme == 'https' &&
        (uri.host == host || uri.host == 'www.$host') &&
        (uri.path == path || uri.path == '$path/');
    final isCustom = uri.scheme == scheme && uri.host == 'pair';
    if (!isHttps && !isCustom) return null;
    final frag = uri.fragment;
    if (!frag.startsWith(_payloadPrefix)) return null;
    final parts = frag.split('&');
    DateTime? issuedAt;
    String? email;
    for (final kv in parts.skip(1)) {
      final eq = kv.indexOf('=');
      if (eq <= 0) continue;
      final k = kv.substring(0, eq);
      final v = kv.substring(eq + 1);
      switch (k) {
        case 't':
          final secs = int.tryParse(v);
          if (secs != null && secs > 0) {
            issuedAt =
                DateTime.fromMillisecondsSinceEpoch(secs * 1000, isUtc: true);
          }
        case 'e':
          try {
            final d = Uri.decodeQueryComponent(v);
            if (d.isNotEmpty) email = d;
          } on FormatException {
            // A mangled email only loses the login hint. Pairing still works.
          } on ArgumentError {
            // Same: the hint is a nicety, the payload is the point.
          }
      }
    }
    return PairingLink(payload: parts.first, issuedAt: issuedAt, email: email);
  }

  /// The bare payload inside [raw], or [raw] unchanged when it is not a link.
  /// `PairingCrypto.parseQr` calls this first, so every parser accepts both.
  static String unwrap(String raw) => parse(raw)?.payload ?? raw;

  /// True when the link carried a mint time and that time is past [codeLife].
  /// A link without a mint time is never called expired here; the relay
  /// decides (a timeout).
  bool isExpired({DateTime? now}) {
    final at = issuedAt;
    if (at == null) return false;
    return (now ?? DateTime.now()).toUtc().difference(at) > codeLife;
  }
}

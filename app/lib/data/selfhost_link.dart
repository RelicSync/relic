/// The self-host config-transfer payload (shown as a QR on a connected device,
/// scanned on a new one). It carries ONLY the server address, plus an optional
/// enrollment secret — never the passphrase. The passphrase is the vault key and
/// must stay user-held, so a scanned device still types it; the QR only removes
/// the miserable part (typing an IP like `http://192.168.1.10:8799` on a phone).
///
/// Uses the app's `relic://` deep-link convention (see `mobile.dart` `_handleUri`),
/// so a scanned string is also a tappable link.
class SelfHostLink {
  /// Prefix a scanner can filter on (alongside the pairing `relic-pair:` prefix).
  static const prefix = 'relic://selfhost';

  /// `relic://selfhost?url=<pct-encoded>[&secret=<enrollSecret>]`.
  static String build(String url, {String? secret}) => Uri(
        scheme: 'relic',
        host: 'selfhost',
        queryParameters: {
          'url': url,
          if (secret != null && secret.isNotEmpty) 'secret': secret,
        },
      ).toString();

  /// Parse a scanned/tapped payload back to its parts. Null if it isn't a
  /// self-host link or has no url.
  static ({String url, String? secret})? parse(String raw) {
    final Uri uri;
    try {
      uri = Uri.parse(raw.trim());
    } catch (_) {
      return null;
    }
    if (uri.scheme != 'relic' || uri.host != 'selfhost') return null;
    final url = uri.queryParameters['url'];
    if (url == null || url.isEmpty) return null;
    final secret = uri.queryParameters['secret'];
    return (url: url, secret: (secret != null && secret.isNotEmpty) ? secret : null);
  }
}

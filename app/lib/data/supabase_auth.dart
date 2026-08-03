import 'dart:convert';
import 'dart:math';

import 'package:hashlib/hashlib.dart' show sha256;
import 'package:http/http.dart' as http;

import 'net.dart';

/// A third-party identity provider Supabase can broker (OAuth). We open the
/// system browser to Supabase's authorize endpoint for one of these; the vault
/// passphrase is still separate (auth != vault key).
enum SupabaseProvider { google, github, apple }

/// Thrown by [SupabaseAuth.signUp] when the project has email confirmation on:
/// the account exists but no session is issued until the user clicks the link in
/// their inbox. Typed (not a bare message) so the create flows can route to a
/// dedicated "confirm your email" step instead of leaking a string into an error
/// banner and discarding the passphrase the user already chose.
class EmailConfirmationPending implements Exception {
  final String email;
  const EmailConfirmationPending(this.email);
  @override
  String toString() => 'EmailConfirmationPending($email)';
}

/// Minimal, dependency-free Supabase Auth (GoTrue REST) client. Email/password
/// sign-in/up/refresh, PLUS browser OAuth (PKCE) — just enough to obtain a
/// short-lived access token to use as the Worker bearer. The vault passphrase is
/// NEVER sent here (auth identity is separate from the E2E vault key).
///
/// The project sits behind the custom domain `auth.relic.space` (so OAuth
/// consent screens show our domain, not *.supabase.co); the publishable (anon)
/// key is client-safe.
class SupabaseAuth {
  static const url = 'https://auth.relic.space';
  static const anonKey = 'sb_publishable_2f4qy-xGASvRRIjpl0Lwzw_8RyWakUe';

  static Uri _u(String p) => Uri.parse('$url/auth/v1$p');
  static Map<String, String> get _headers =>
      {'apikey': anonKey, 'Content-Type': 'application/json'};

  static Future<SupabaseSession> signIn(String email, String password) async {
    final r = await http.post(
      _u('/token?grant_type=password'),
      headers: _headers,
      body: jsonEncode({'email': email, 'password': password}),
    ).timeout(kNetTimeout);
    return _sessionOrThrow(r);
  }

  // --- Browser OAuth (PKCE) --------------------------------------------------
  // Flow: newCodeVerifier() → open authorizeUrl(...) in the system browser →
  // provider redirects back to `redirectTo` with `?code=...` → exchangeCode().
  // Callback capture (loopback on desktop, relic:// deep link on mobile) lives
  // in oauth_flow.dart; this class just builds the URLs and does the exchange.

  static String _providerName(SupabaseProvider p) => switch (p) {
        SupabaseProvider.google => 'google',
        SupabaseProvider.github => 'github',
        SupabaseProvider.apple => 'apple',
      };

  /// A high-entropy PKCE code verifier (RFC 7636): base64url of 32 random bytes,
  /// unpadded (43 chars, all in the allowed set).
  static String newCodeVerifier() {
    final r = Random.secure();
    final bytes = List<int>.generate(32, (_) => r.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  /// The S256 challenge: base64url(sha256(verifier)), unpadded.
  static String codeChallenge(String verifier) =>
      base64UrlEncode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');

  /// The GoTrue authorize URL that starts a provider login. The browser opens
  /// this; on success the provider redirects to [redirectTo] with `?code=...`.
  static Uri authorizeUrl(
    SupabaseProvider provider,
    String redirectTo,
    String challenge,
  ) =>
      _u('/authorize').replace(queryParameters: {
        'provider': _providerName(provider),
        'redirect_to': redirectTo,
        'code_challenge': challenge,
        'code_challenge_method': 's256',
      });

  /// Exchange the authorization [code] for a session (PKCE). [codeVerifier] must
  /// be the one whose challenge was sent to [authorizeUrl].
  static Future<SupabaseSession> exchangeCode(String code, String codeVerifier) async {
    final r = await http.post(
      _u('/token?grant_type=pkce'),
      headers: _headers,
      body: jsonEncode({'auth_code': code, 'code_verifier': codeVerifier}),
    ).timeout(kNetTimeout);
    return _sessionOrThrow(r);
  }

  /// Sign up. If the project requires email confirmation, no session is returned
  /// yet — we throw a typed [EmailConfirmationPending] so callers can send the
  /// user to a confirm-your-email step (and resend the link) rather than losing
  /// the passphrase they already picked.
  static Future<SupabaseSession> signUp(String email, String password) async {
    final r = await http.post(
      _u('/signup'),
      headers: _headers,
      body: jsonEncode({'email': email, 'password': password}),
    ).timeout(kNetTimeout);
    final j = _decode(r);
    if (r.statusCode >= 400) throw _msg(j, 'Sign-up failed.');
    if (j['access_token'] == null) {
      throw EmailConfirmationPending(email);
    }
    return SupabaseSession.fromJson(j);
  }

  /// Re-send the sign-up confirmation email (GoTrue `/resend`, `type=signup`).
  /// Used by the confirm-your-email step when the first link did not arrive.
  /// Throws a friendly message on failure.
  static Future<void> resendSignupConfirmation(String email) async {
    final r = await http.post(
      _u('/resend'),
      headers: _headers,
      body: jsonEncode({'type': 'signup', 'email': email}),
    ).timeout(kNetTimeout);
    if (r.statusCode >= 400) {
      throw _msg(_decode(r), 'Could not resend the confirmation email.');
    }
  }

  /// Change the signed-in user's login (account) email. Secure email change is
  /// enabled on the project, so GoTrue emails a confirmation link to BOTH the
  /// current and the new address; the change only takes effect once both are
  /// confirmed. This is the account identity email, separate from the vault
  /// passphrase (never touched here). Throws a friendly message on failure.
  static Future<void> changeEmail(String accessToken, String email) async {
    final r = await http.put(
      _u('/user'),
      headers: {..._headers, 'Authorization': 'Bearer $accessToken'},
      body: jsonEncode({'email': email}),
    ).timeout(kNetTimeout);
    if (r.statusCode >= 400) {
      throw _msg(_decode(r), 'Could not update the email.');
    }
  }

  /// Send a password-reset email (GoTrue `/recover`). The link lands on the
  /// reset page at relic.space/reset (must be in the project's redirect
  /// allow-list), where the user sets the new password. Throws a friendly
  /// message on failure.
  static Future<void> sendPasswordReset(String email) async {
    final r = await http.post(
      _u('/recover').replace(
        queryParameters: {'redirect_to': 'https://relic.space/reset'},
      ),
      headers: _headers,
      body: jsonEncode({'email': email}),
    ).timeout(kNetTimeout);
    if (r.statusCode >= 400) {
      throw _msg(_decode(r), 'Could not send the reset email.');
    }
  }

  static Future<SupabaseSession> refresh(String refreshToken) async {
    final r = await http.post(
      _u('/token?grant_type=refresh_token'),
      headers: _headers,
      body: jsonEncode({'refresh_token': refreshToken}),
    ).timeout(kNetTimeout);
    return _sessionOrThrow(r);
  }

  /// Global sign-out (docs/cloudflare/13 §7): revoke EVERY refresh token for
  /// this user at the IdP, so all other devices lose the ability to mint a new
  /// access token once their current one expires. This is the account-wide kill
  /// switch that complements the per-device remove (which only bites clients
  /// sending `X-Relic-Device`). It also invalidates this device's own refresh
  /// token, so the caller should treat it as "sign out here too". Best-effort:
  /// GoTrue returns 204 on success; a network failure throws.
  static Future<void> signOutGlobal(String accessToken) async {
    final r = await http.post(
      _u('/logout?scope=global'),
      headers: {..._headers, 'Authorization': 'Bearer $accessToken'},
    ).timeout(kNetTimeout);
    if (r.statusCode >= 400) {
      throw _msg(_decode(r), 'Could not sign out other devices.');
    }
  }

  static SupabaseSession _sessionOrThrow(http.Response r) {
    final j = _decode(r);
    if (r.statusCode >= 400 || j['access_token'] == null) {
      throw _msg(j, 'Authentication failed.');
    }
    return SupabaseSession.fromJson(j);
  }

  static Map<String, dynamic> _decode(http.Response r) {
    try {
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }

  static String _msg(Map<String, dynamic> j, String fallback) {
    final m = j['msg'] ?? j['error_description'] ?? j['error'] ?? j['message'];
    return (m is String && m.isNotEmpty) ? m : fallback;
  }
}

class SupabaseSession {
  final String accessToken;
  final String refreshToken;
  final int expiresAt; // epoch seconds
  final String userId; // the stable 'sub' — used for the crypto scope
  final String? email;
  const SupabaseSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.userId,
    this.email,
  });

  factory SupabaseSession.fromJson(Map<String, dynamic> j) {
    final user = j['user'] as Map<String, dynamic>?;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expiresAt = (j['expires_at'] as num?)?.toInt() ??
        now + ((j['expires_in'] as num?)?.toInt() ?? 3600);
    return SupabaseSession(
      accessToken: j['access_token'] as String,
      refreshToken: j['refresh_token'] as String? ?? '',
      expiresAt: expiresAt,
      userId: (user?['id'] as String?) ?? '',
      email: user?['email'] as String?,
    );
  }
}

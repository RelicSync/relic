import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:url_launcher/url_launcher.dart';

import '../platform/apple_ids.dart';
import 'supabase_auth.dart';

/// Runs a browser OAuth (PKCE) login and returns the resulting [SupabaseSession].
/// Opens Supabase's authorize URL and catches the callback:
///   - Desktop: system browser + a one-shot 127.0.0.1 loopback HTTP server (no
///     OS registration).
///   - iOS:     an in-app ASWebAuthenticationSession, which hands the callback
///     URL straight back to us (no deep link, no Safari round trip).
///   - Android: system browser + the `relic://auth-callback` deep link,
///     delivered by mobile.dart's app_links handler via [deliverMobileCallback].
///
/// Only the account login goes through here; the vault passphrase is handled
/// separately by the onboarding flow (auth != vault key).
class OAuthFlow {
  static const _timeout = Duration(minutes: 3);

  /// The redirect Supabase sends the code back to on mobile. Registered as an
  /// Info.plist URL type / Android intent filter under [relicUrlScheme].
  static const _mobileRedirect = '$relicUrlScheme://auth-callback';

  // Android: the in-flight login's callback sink, fed by deliverMobileCallback.
  static Completer<Uri>? _mobilePending;

  /// Called by mobile.dart's deep-link handler for `relic://auth-callback?...`.
  /// iOS never needs this — its callback comes back through the auth session —
  /// but a stray link there is still harmless.
  static void deliverMobileCallback(Uri uri) {
    final c = _mobilePending;
    if (c != null && !c.isCompleted) c.complete(uri);
  }

  static Future<SupabaseSession> signInWithProvider(
    SupabaseProvider provider, {
    required bool desktop,
  }) {
    final verifier = SupabaseAuth.newCodeVerifier();
    final challenge = SupabaseAuth.codeChallenge(verifier);
    return desktop
        ? _desktop(provider, verifier, challenge)
        : _mobile(provider, verifier, challenge);
  }

  // --- Desktop: ephemeral loopback listener ---------------------------------
  static Future<SupabaseSession> _desktop(
    SupabaseProvider provider,
    String verifier,
    String challenge,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirect = 'http://127.0.0.1:${server.port}/callback';
      final authorize = SupabaseAuth.authorizeUrl(provider, redirect, challenge);
      if (!await launchUrl(authorize, mode: LaunchMode.externalApplication)) {
        throw 'Could not open the browser.';
      }
      // The browser may hit /favicon.ico etc.; wait for the real /callback.
      final done = Completer<Uri>();
      final sub = server.listen((req) {
        final u = req.uri;
        final isCallback = u.path == '/callback' &&
            (u.queryParameters.containsKey('code') ||
                u.queryParameters.containsKey('error'));
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write(isCallback ? _closePage(u.queryParameters.containsKey('code')) : '');
        req.response.close();
        if (isCallback && !done.isCompleted) done.complete(u);
      });
      try {
        final u = await done.future.timeout(_timeout);
        return _exchange(u, verifier);
      } on TimeoutException {
        throw 'Sign-in timed out. Please try again.';
      } finally {
        await sub.cancel();
      }
    } finally {
      await server.close(force: true);
    }
  }

  // --- Mobile ---------------------------------------------------------------
  static Future<SupabaseSession> _mobile(
    SupabaseProvider provider,
    String verifier,
    String challenge,
  ) {
    final authorize =
        SupabaseAuth.authorizeUrl(provider, _mobileRedirect, challenge);
    return Platform.isIOS
        ? _iosAuthSession(authorize, verifier)
        : _androidDeepLink(authorize, verifier);
  }

  /// iOS: an in-app ASWebAuthenticationSession. The sheet belongs to Relic, so
  /// iOS delivers the `relic://auth-callback` redirect back to the session as a
  /// return value instead of bouncing out to Safari and back through an "Open
  /// this page in Relic?" prompt. Same code, same [_exchange] afterwards.
  ///
  /// No [_timeout] here on purpose: the sheet is modal and the user is looking
  /// at it, so it ends when they finish or dismiss it — a background timer
  /// firing under a live sheet would only produce a phantom error.
  static Future<SupabaseSession> _iosAuthSession(
    Uri authorize,
    String verifier,
  ) async {
    final String callback;
    try {
      callback = await FlutterWebAuth2.authenticate(
        url: authorize.toString(),
        callbackUrlScheme: relicUrlScheme,
      );
    } on PlatformException catch (e) {
      // Swiping the sheet away is a normal way to back out, not a failure:
      // same mild wording _exchange uses for a callback with no code.
      if (e.code == 'CANCELED') throw 'Sign-in was cancelled.';
      throw e.message ?? 'Could not open the sign-in page.';
    }
    return _exchange(Uri.parse(callback), verifier);
  }

  // Android: system browser + the relic://auth-callback deep link.
  static Future<SupabaseSession> _androidDeepLink(
    Uri authorize,
    String verifier,
  ) async {
    final completer = Completer<Uri>();
    _mobilePending = completer;
    try {
      if (!await launchUrl(authorize, mode: LaunchMode.externalApplication)) {
        throw 'Could not open the browser.';
      }
      try {
        final u = await completer.future.timeout(_timeout);
        return _exchange(u, verifier);
      } on TimeoutException {
        throw 'Sign-in timed out. Please try again.';
      }
    } finally {
      if (identical(_mobilePending, completer)) _mobilePending = null;
    }
  }

  static Future<SupabaseSession> _exchange(Uri callback, String verifier) {
    final code = callback.queryParameters['code'];
    if (code == null) {
      throw callback.queryParameters['error_description'] ??
          callback.queryParameters['error'] ??
          'Sign-in was cancelled.';
    }
    return SupabaseAuth.exchangeCode(code, verifier);
  }

  static String _closePage(bool ok) => '''
<!doctype html><meta charset="utf-8"><title>Relic</title>
<body style="font-family:system-ui;background:#16130E;color:#F2ECDD;display:grid;place-items:center;height:100vh;margin:0">
<div style="text-align:center">
<h2 style="color:#DAA43E">${ok ? 'Signed in' : 'Sign-in failed'}</h2>
<p>You can close this tab and return to Relic.</p>
</div></body>''';
}

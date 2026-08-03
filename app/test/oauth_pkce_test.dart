import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hashlib/hashlib.dart' show sha256;
import 'package:relic_app/data/supabase_auth.dart';

void main() {
  test('code verifier is unpadded base64url, >= 43 chars', () {
    final v = SupabaseAuth.newCodeVerifier();
    expect(v.contains('='), isFalse);
    expect(v.length, greaterThanOrEqualTo(43));
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(v), isTrue);
  });

  test('challenge is unpadded base64url(sha256(verifier)) — RFC 7636 S256', () {
    final v = SupabaseAuth.newCodeVerifier();
    final expected =
        base64UrlEncode(sha256.convert(utf8.encode(v)).bytes).replaceAll('=', '');
    expect(SupabaseAuth.codeChallenge(v), expected);
  });

  test('verifiers are random per call', () {
    expect(SupabaseAuth.newCodeVerifier(), isNot(SupabaseAuth.newCodeVerifier()));
  });

  test('authorizeUrl carries provider + PKCE params', () {
    final u = SupabaseAuth.authorizeUrl(
        SupabaseProvider.google, 'relic://auth-callback', 'CHALLENGE');
    expect(u.toString(),
        startsWith('https://auth.relic.space/auth/v1/authorize'));
    expect(u.queryParameters['provider'], 'google');
    expect(u.queryParameters['redirect_to'], 'relic://auth-callback');
    expect(u.queryParameters['code_challenge'], 'CHALLENGE');
    expect(u.queryParameters['code_challenge_method'], 's256');
  });

  test('provider names map correctly', () {
    expect(SupabaseAuth.authorizeUrl(SupabaseProvider.github, 'x', 'y')
        .queryParameters['provider'], 'github');
    expect(SupabaseAuth.authorizeUrl(SupabaseProvider.apple, 'x', 'y')
        .queryParameters['provider'], 'apple');
  });
}

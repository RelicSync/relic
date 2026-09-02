import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/local_desk_repo.dart';
import 'package:relic_app/data/worker_repo.dart';
import 'package:relic_app/onboarding/add_device.dart';

void main() {
  group('emailConfirmMatches (delete-account confirm field)', () {
    test('matches case-insensitively and trims whitespace', () {
      expect(emailConfirmMatches('user@example.com', 'user@example.com'), isTrue);
      expect(emailConfirmMatches('USER@Example.com', 'user@example.com'), isTrue);
      expect(emailConfirmMatches('  user@example.com  ', 'user@example.com'),
          isTrue);
    });

    test('rejects a different address', () {
      expect(emailConfirmMatches('other@example.com', 'user@example.com'),
          isFalse);
      expect(emailConfirmMatches('', 'user@example.com'), isFalse);
    });

    test('an empty account email never matches (guards a null session)', () {
      expect(emailConfirmMatches('', ''), isFalse);
      expect(emailConfirmMatches('user@example.com', ''), isFalse);
      expect(emailConfirmMatches('', '   '), isFalse);
    });
  });

  group('isEmailUnverifiedBody (verify-to-sync banner flag)', () {
    test('true only for the worker email_unverified payload', () {
      const body =
          '{"error":"email_unverified","message":"Confirm your email to start syncing."}';
      expect(WorkerRepo.isEmailUnverifiedBody(body), isTrue);
      // Lockstep: both hosts must decide identically.
      expect(LocalDeskRepo.isEmailUnverifiedBody(body), isTrue);
    });

    test('false for other errors, empty, or non-JSON bodies', () {
      for (final body in <String>[
        '{"error":"rate_limited"}',
        '{"message":"nope"}',
        '{}',
        '',
        'not json at all',
        '[1,2,3]',
      ]) {
        expect(WorkerRepo.isEmailUnverifiedBody(body), isFalse, reason: body);
        expect(LocalDeskRepo.isEmailUnverifiedBody(body), isFalse, reason: body);
      }
    });
  });

  // Removing a device now signs the whole account out at the IdP, so the worker
  // answers 401 session_revoked to tokens minted before the removal. Both hosts
  // have to recognise it: the sync loop turns every other non-200 into
  // "offline", and a revoked session that reads as "offline" never recovers,
  // because the refresh token went with it.
  group('isSessionRevokedBody (signed-out banner flag)', () {
    test('true only for the worker session_revoked payload', () {
      const body =
          '{"error":"session_revoked","message":"signed out on this account; sign in again"}';
      expect(WorkerRepo.isSessionRevokedBody(body), isTrue);
      // Lockstep: both hosts must decide identically.
      expect(LocalDeskRepo.isSessionRevokedBody(body), isTrue);
    });

    test('false for other errors, empty, or non-JSON bodies', () {
      for (final body in <String>[
        // The ordinary 401. A refresh usually cures this one, so it must NOT
        // trip the banner or drop the refresh token.
        '{"error":"unauthorized","message":"missing bearer token"}',
        '{"error":"device_revoked"}',
        '{"error":"email_unverified"}',
        '{"message":"nope"}',
        '{}',
        '',
        'not json at all',
        '[1,2,3]',
      ]) {
        expect(WorkerRepo.isSessionRevokedBody(body), isFalse, reason: body);
        expect(LocalDeskRepo.isSessionRevokedBody(body), isFalse, reason: body);
      }
    });
  });
}

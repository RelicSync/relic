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
}

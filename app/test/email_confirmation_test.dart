import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/data/supabase_auth.dart';

void main() {
  group('EmailConfirmationPending', () {
    test('is an Exception that carries the signed-up email', () {
      const e = EmailConfirmationPending('user@example.com');
      expect(e, isA<Exception>());
      expect(e.email, 'user@example.com');
    });

    test('is distinguishable by type in a catch, not by string match', () {
      // This mirrors how the create flows route: they catch the typed
      // exception to show the confirm-your-email step, and fall through to a
      // generic error banner for anything else.
      Object? routed;
      try {
        throw const EmailConfirmationPending('a@b.co');
      } on EmailConfirmationPending catch (e) {
        routed = e.email;
      } catch (_) {
        routed = 'generic';
      }
      expect(routed, 'a@b.co');

      String? banner;
      try {
        throw 'Some other failure.';
      } on EmailConfirmationPending {
        banner = 'confirm-step';
      } catch (e) {
        banner = e.toString();
      }
      expect(banner, 'Some other failure.');
    });
  });
}

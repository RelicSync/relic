import 'package:flutter_test/flutter_test.dart';

import 'package:relic_app/onboarding/desktop_onboarding.dart';

/// The macOS Accessibility ask is the only step desktop onboarding opens on
/// conditionally, so the gate is a pure function and its contract is pinned
/// here: Mac-only, missing-grant-only, and never on the guided "switch
/// account" entry.
void main() {
  test('a Mac without the grant opens on the ask', () {
    expect(
      shouldShowAccessibilityIntro(
          isMacOS: true, trusted: false, startAtSignIn: false),
      isTrue,
    );
  });

  test('a Mac that already granted goes straight to welcome', () {
    expect(
      shouldShowAccessibilityIntro(
          isMacOS: true, trusted: true, startAtSignIn: false),
      isFalse,
    );
  });

  test('switch account skips the ask even when the grant is missing', () {
    expect(
      shouldShowAccessibilityIntro(
          isMacOS: true, trusted: false, startAtSignIn: true),
      isFalse,
    );
  });

  test('non-Mac desktops never see the step', () {
    for (final trusted in [true, false]) {
      for (final signIn in [true, false]) {
        expect(
          shouldShowAccessibilityIntro(
              isMacOS: false, trusted: trusted, startAtSignIn: signIn),
          isFalse,
          reason: 'trusted=$trusted startAtSignIn=$signIn',
        );
      }
    }
  });
}

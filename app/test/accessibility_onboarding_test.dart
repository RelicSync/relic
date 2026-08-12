import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:relic_app/onboarding/desktop_onboarding.dart';

/// The macOS Accessibility ask is the only step desktop onboarding opens on
/// conditionally, so the gate is a pure function and its contract is pinned
/// here: Mac-only, missing-grant-only, and never on the guided "switch
/// account" entry. The grant watcher that pulls the app back out of the
/// background afterwards is pinned below it (fake timers, injected probe — no
/// Mac and no live TCC database needed).
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

  // testWidgets (not test) for the fake clock: pump() drives the watcher's
  // periodic timer, and a watcher that forgot to stop fails the test with a
  // pending timer.
  group('grant watcher', () {
    late int probes;
    late int granted;
    late bool trusted;
    late AccessibilityGrantWatcher watcher;

    setUp(() {
      probes = 0;
      granted = 0;
      trusted = false;
      watcher = AccessibilityGrantWatcher(
        probe: () async {
          probes++;
          return trusted;
        },
        onGranted: () => granted++,
      );
    });

    Future<void> tick(WidgetTester tester, int seconds) async {
      for (var i = 0; i < seconds; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
    }

    testWidgets('flipping the switch brings the flow forward', (tester) async {
      await tester.pumpWidget(const SizedBox());
      watcher.start();
      await tick(tester, 3);
      expect(granted, 0);
      expect(probes, 3);

      trusted = true;
      await tick(tester, 1);
      expect(granted, 1);
      expect(watcher.watching, isFalse);

      // Stopped means stopped: no second advance, no further channel hops.
      await tick(tester, 5);
      expect(granted, 1);
      expect(probes, 4);
    });

    testWidgets('a user who never comes back stops being polled',
        (tester) async {
      await tester.pumpWidget(const SizedBox());
      watcher.start();
      await tick(tester, AccessibilityGrantWatcher.window.inSeconds - 1);
      expect(watcher.watching, isTrue);

      await tick(tester, 1);
      expect(watcher.watching, isFalse);
      expect(granted, 0);
    });

    testWidgets('a second trip out restarts rather than stacking timers',
        (tester) async {
      await tester.pumpWidget(const SizedBox());
      watcher.start();
      await tick(tester, 2);
      watcher.start();
      await tick(tester, 2);
      expect(probes, 4, reason: 'two timers would probe twice per second');

      trusted = true;
      await tick(tester, 1);
      expect(granted, 1);
    });

    testWidgets('cancel stops the poll', (tester) async {
      await tester.pumpWidget(const SizedBox());
      watcher.start();
      await tick(tester, 2);
      watcher.cancel();
      trusted = true;
      await tick(tester, 5);
      expect(probes, 2);
      expect(granted, 0);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';
import 'package:relic_app/widgets/controls.dart';

/// [GhostButton] is a GestureDetector, not a Material button. The 2026 restyle
/// replaced every FilledButton/TextButton/OutlinedButton in onboarding and the
/// dialogs with it, so if it ever stops being focusable those screens become
/// keyboard-unreachable — silently, because nothing else in the suite presses a
/// key at one.
void main() {
  Widget host(Widget child) => MaterialApp(
        home: RelicTheme(
          colors: RelicColors.light,
          child: Scaffold(body: Center(child: child)),
        ),
      );

  testWidgets('takes keyboard focus and activates on Enter and Space',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(
      GhostButton(label: 'Continue', onTap: () => taps++),
    ));

    // Tab reaches it.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final node = Focus.of(
      tester.element(find.text('Continue')),
      scopeOk: true,
    );
    expect(node.hasFocus, isTrue,
        reason: 'Tab should move focus onto the button');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(taps, 1, reason: 'Enter should activate a focused ghost button');

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(taps, 2, reason: 'Space should activate a focused ghost button');
  });

  testWidgets('a disabled button is skipped by focus traversal',
      (tester) async {
    await tester.pumpWidget(host(
      const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GhostButton(label: 'Disabled', onTap: null),
          GhostButton(label: 'Enabled', onTap: _noop),
        ],
      ),
    ));

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    expect(
      Focus.of(tester.element(find.text('Enabled')), scopeOk: true).hasFocus,
      isTrue,
      reason: 'focus should land on the enabled button, not the disabled one',
    );
  });
}

void _noop() {}

import 'package:flutter_test/flutter_test.dart';

import 'package:relic_app/ui/actionable_notification.dart';

/// Every notification Relic shows with something behind the click was a dead
/// end on Linux: local_notifier's Linux plugin only ever reports explicit
/// action buttons, never a body click. These pin the shape that fixes it.
void main() {
  // Constructing a LocalNotification registers a listener on local_notifier's
  // method channel, which needs the binding up first.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Linux gets an explicit action button, because a body click is inert',
      () {
    final n = actionableNotification(
      title: 'Relic 1.2.3 is available',
      body: 'notes',
      actionLabel: 'Update',
      onActivate: () {},
      isLinux: true,
    );
    expect(n.actions, isNotNull);
    expect(n.actions!.single.text, 'Update');
    expect(n.actions!.single.type, 'button');
  });

  test('Windows and macOS take the body click, so no button is added', () {
    final n = actionableNotification(
      title: 'Relic 1.2.3 is available',
      body: 'notes',
      actionLabel: 'Update',
      onActivate: () {},
      isLinux: false,
    );
    expect(n.actions, isNull);
  });

  test('either delivery runs the same intent, exactly once per activation', () {
    var fired = 0;
    for (final linux in [true, false]) {
      final n = actionableNotification(
        title: 't',
        body: 'b',
        actionLabel: 'Go',
        onActivate: () => fired++,
        isLinux: linux,
      );
      n.onClick!();
      n.onClickAction!(0);
    }
    expect(fired, 4);
  });
}

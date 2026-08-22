import 'package:local_notifier/local_notifier.dart';

/// A native notification whose click actually does something on every desktop.
///
/// Windows and macOS report a click on the notification BODY, so `onClick` is
/// all they need. Linux never reports one: local_notifier's Linux plugin wires
/// `notify_notification_add_action` and nothing else, so a notification with no
/// declared actions is inert no matter where the user clicks it. Every
/// notification Relic showed with something behind the click — the update
/// offer, a due reminder — was therefore a dead end on Linux.
///
/// Worse for the update offer specifically: the fallback is the tray entry, and
/// stock GNOME has no tray at all (see platform/tray_support.dart). An inert
/// notification there means an update the user is told about and cannot take.
///
/// So on Linux the same intent is offered as an explicit action button, which
/// GNOME and KDE both draw on the banner. [actionLabel] is what that button
/// says; it is unused on the platforms that take a body click.
LocalNotification actionableNotification({
  required String title,
  required String body,
  required String actionLabel,
  required void Function() onActivate,
  required bool isLinux,
}) {
  final n = LocalNotification(
    title: title,
    body: body,
    actions: isLinux ? [LocalNotificationAction(text: actionLabel)] : null,
  );
  // Both are set on every platform: whichever one the desktop delivers runs
  // the same intent, and there is only ever one action.
  n.onClick = onActivate;
  n.onClickAction = (_) => onActivate();
  return n;
}

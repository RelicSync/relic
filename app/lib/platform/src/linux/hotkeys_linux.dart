import 'package:flutter/services.dart';

/// Global hotkey registration on Linux, over our own X11 bridge
/// (linux/runner/hotkeys.cc — change the two together).
///
/// Relic uses neither hotkey_manager nor keybinder here. hotkey_manager_linux
/// passes Flutter's physical keyCode to gtk_accelerator_name() as if it were a
/// GDK keyval, so Ctrl+Shift+Space registers as `<Primary><Shift>KP_Space` (the
/// keypad key) and never fires; it also reports success even when the grab was
/// refused, which left Relic's "these hotkeys failed" surface permanently
/// empty. keybinder-3.0 grabs correctly but cannot dispatch a Shift+printable
/// chord at all, which is every Relic default except the summon chord. Both
/// verified on Ubuntu 24.04/Xorg; see hotkeys.cc for the mechanism.
///
/// Here Dart builds the accelerator itself ([linuxAccelerator]) and the bridge
/// reports the real outcome.
const _ch = MethodChannel('relic/hotkeys');

/// Why a hotkey did not register. [taken] is the common one: another client
/// already holds that grab (desktop shells claim a lot of Ctrl+Shift chords).
enum HotkeyFailure { none, unmappable, taken, unavailable }

HotkeyFailure _failureFrom(String? reason) => switch (reason) {
      null || 'ok' => HotkeyFailure.none,
      'unmappable' => HotkeyFailure.unmappable,
      'taken' => HotkeyFailure.taken,
      _ => HotkeyFailure.unavailable,
    };

/// Bind [accelerator] (GTK syntax, e.g. `<Control><Shift>space`). The bridge
/// keys callbacks by [id]. Never throws: a dead channel is [unavailable].
Future<HotkeyFailure> register(String id, String accelerator) async {
  try {
    final r = await _ch.invokeMethod<String>(
        'register', {'id': id, 'accelerator': accelerator});
    return _failureFrom(r);
  } catch (_) {
    return HotkeyFailure.unavailable;
  }
}

Future<void> unregisterAll() async {
  try {
    await _ch.invokeMethod<void>('unregisterAll');
  } catch (_) {
    // best effort; the bridge drops everything on exit anyway
  }
}

/// Route key-down callbacks. [onDown] receives the id passed to [register].
void listen(void Function(String id) onDown) {
  _ch.setMethodCallHandler((call) async {
    if (call.method == 'onKeyDown') {
      final id = call.arguments is Map ? call.arguments['id'] : null;
      if (id is String) onDown(id);
    }
    return null;
  });
}

#ifndef RUNNER_HOTKEYS_H_
#define RUNNER_HOTKEYS_H_

#include <flutter_linux/flutter_linux.h>

// Registers the "relic/hotkeys" channel: global hotkey grabs via XGrabKey on
// the root window, with the real bind outcome reported back. See hotkeys.cc
// for why this exists rather than using hotkey_manager or keybinder.
void relic_hotkeys_register(FlBinaryMessenger* messenger);

// X server timestamp of the last hotkey we dispatched, or 0 before the first
// one. window_focus.cc needs it: asking to focus a window is only honoured by
// the window manager when it can be told WHEN the user asked, and the hotkey
// press is the only moment Relic has that answer first-hand.
guint32 relic_hotkeys_last_event_time();

#endif  // RUNNER_HOTKEYS_H_

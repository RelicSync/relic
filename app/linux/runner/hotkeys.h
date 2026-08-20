#ifndef RUNNER_HOTKEYS_H_
#define RUNNER_HOTKEYS_H_

#include <flutter_linux/flutter_linux.h>

// Registers the "relic/hotkeys" channel: global hotkey grabs via XGrabKey on
// the root window, with the real bind outcome reported back. See hotkeys.cc
// for why this exists rather than using hotkey_manager or keybinder.
void relic_hotkeys_register(FlBinaryMessenger* messenger);

#endif  // RUNNER_HOTKEYS_H_

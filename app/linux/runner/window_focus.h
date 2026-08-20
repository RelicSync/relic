#ifndef RUNNER_WINDOW_FOCUS_H_
#define RUNNER_WINDOW_FOCUS_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Registers the "relic/window_focus" channel: claim the keyboard for [window]
// using the timestamp of the hotkey that summoned it. See window_focus.cc for
// why show()+focus() alone is not enough on a modern X11 desktop.
void relic_window_focus_register(FlBinaryMessenger* messenger, GtkWindow* window);

#endif  // RUNNER_WINDOW_FOCUS_H_

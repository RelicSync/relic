#ifndef RUNNER_CLIPBOARD_WATCH_H_
#define RUNNER_CLIPBOARD_WATCH_H_

#include <flutter_linux/flutter_linux.h>

// Registers the "relic/clipboard_watch" channel, which tells Dart when the
// CLIPBOARD selection changes owner. See clipboard_watch.cc for why this
// exists rather than using the clipboard_watcher plugin on Linux.
void relic_clipboard_watch_register(FlBinaryMessenger* messenger);

#endif  // RUNNER_CLIPBOARD_WATCH_H_

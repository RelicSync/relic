#ifndef RUNNER_DESKTOP_ENV_H_
#define RUNNER_DESKTOP_ENV_H_

#include <flutter_linux/flutter_linux.h>

// Registers relic/desktop_env: facts about the running desktop that Dart
// cannot see from dart:io. Currently one — whether anything is listening for
// tray icons.
void relic_desktop_env_register(FlBinaryMessenger* messenger);

#endif  // RUNNER_DESKTOP_ENV_H_

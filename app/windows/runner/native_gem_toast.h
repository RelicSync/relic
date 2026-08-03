#ifndef RUNNER_NATIVE_GEM_TOAST_H_
#define RUNNER_NATIVE_GEM_TOAST_H_

#include <windows.h>

// Shows a short, click-through, per-pixel-alpha gem flourish in a native layered
// window. This deliberately does not use Flutter window transparency, which is
// unreliable on Windows because Flutter renders into a child swapchain.
bool ShowNativeGemToast(HWND owner);

#endif  // RUNNER_NATIVE_GEM_TOAST_H_

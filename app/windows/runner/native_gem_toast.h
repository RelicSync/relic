#ifndef RUNNER_NATIVE_GEM_TOAST_H_
#define RUNNER_NATIVE_GEM_TOAST_H_

#include <windows.h>
#include <string>

// Shows a short, click-through, per-pixel-alpha gem flourish in a native layered
// window. This deliberately does not use Flutter window transparency, which is
// unreliable on Windows because Flutter renders into a child swapchain.
bool ShowNativeGemToast(HWND owner);

// Voice-reactive mark with a slow recording shadow or fast processing shadow. No text.
bool ShowNativeVoiceToast(HWND target, bool recording);
void UpdateNativeVoiceLevel(double level);
void HideNativeVoiceToast();

#endif  // RUNNER_NATIVE_GEM_TOAST_H_

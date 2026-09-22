#pragma once
#include <windows.h>
#include <future>

struct VoiceTextContext {
  bool leading_space = false;
  bool protected_field = false;
  bool known = false;
};

// Read-only, bounded to the character before the insertion/replacement point.
// Runs on a shared background thread. Unsupported providers leave spacing unchanged.
std::future<VoiceTextContext> ReadVoiceTextContextAsync(HWND expected_window);
void ShutdownVoiceTextContext();
bool VoiceWhitespace(wchar_t character);

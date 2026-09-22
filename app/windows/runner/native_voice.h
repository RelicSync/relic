#pragma once
#include <windows.h>
#include <flutter/binary_messenger.h>
#include <optional>

void InitializeNativeVoice(HWND owner, flutter::BinaryMessenger* messenger);
void DisposeNativeVoice();
std::optional<LRESULT> HandleNativeVoiceMessage(UINT message, WPARAM wparam, LPARAM lparam);

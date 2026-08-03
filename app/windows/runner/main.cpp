#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <stdlib.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Single-instance guard. A second copy (e.g. a double-click, or the
  // run-at-login entry firing while the tray copy is already resident) must
  // not start: two processes writing the same SQLite WAL risks corruption and
  // spawns a duplicate tray icon. If we lose the race, ask the running copy to
  // surface its window (best-effort, via a broadcast registered message) and
  // exit quietly. The mutex is held for this process's lifetime; the OS
  // releases it on exit.
  // The mutex name includes RELIC_DATA_DIR (sanitized) when set, so a
  // sandboxed/portable instance — which uses a separate data dir + SQLite DB —
  // runs alongside the normal instance instead of just re-focusing it. Same DB =
  // same mutex = single instance (the WAL-safety reason); different DB = safe to
  // coexist.
  std::wstring mutex_name = L"Relic-SingleInstance";
  wchar_t *data_dir = nullptr;
  size_t data_dir_len = 0;
  if (::_wdupenv_s(&data_dir, &data_dir_len, L"RELIC_DATA_DIR") == 0 &&
      data_dir != nullptr && data_dir[0] != L'\0') {
    mutex_name += L"-";
    for (wchar_t *p = data_dir; *p; ++p) {
      wchar_t c = *p;
      const bool ok = (c >= L'A' && c <= L'Z') || (c >= L'a' && c <= L'z') ||
                      (c >= L'0' && c <= L'9');
      mutex_name += ok ? c : L'_';
    }
  }
  if (data_dir != nullptr) {
    free(data_dir);
  }
  HANDLE instance_mutex = ::CreateMutexW(nullptr, TRUE, mutex_name.c_str());
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    UINT show_msg = ::RegisterWindowMessageW(L"RelicShowExisting");
    ::PostMessage(HWND_BROADCAST, show_msg, 0, 0);
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"relic_app", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}

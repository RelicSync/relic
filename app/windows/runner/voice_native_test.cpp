// Separate test executable. Test-tagged injected input is accepted ONLY in this
// translation unit; the shipping hook continues to ignore all injected input.
#define RELIC_VOICE_TEST
#include "native_voice.cpp"
#include <cassert>
#include <iostream>
#include <thread>

namespace {
bool saw_alt_chord = false;
WNDPROC original_edit = nullptr;
LRESULT CALLBACK EditProc(HWND window, UINT msg, WPARAM wp, LPARAM lp) {
  if ((msg == WM_SYSKEYDOWN || msg == WM_KEYDOWN) && wp == 'X') saw_alt_chord = (GetKeyState(VK_MENU) & 0x8000) != 0;
  return CallWindowProc(original_edit, window, msg, wp, lp);
}
LRESULT CALLBACK FixtureProc(HWND window, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_SYSKEYDOWN && wp == 'X') saw_alt_chord = (GetKeyState(VK_MENU) & 0x8000) != 0;
  if (auto handled = HandleNativeVoiceMessage(msg, wp, lp)) return *handled;
  return DefWindowProc(window, msg, wp, lp);
}
void Pump(int ms) {
  const auto end = GetTickCount64() + ms;
  do {
    MSG message;
    while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message); DispatchMessage(&message);
    }
    Sleep(2);
  } while (GetTickCount64() < end);
}
class InsertionReply : public flutter::MethodResult<Value> {
 public:
  InsertionReply(bool* done, std::string* outcome) : done_(done), outcome_(outcome) {}
 protected:
  void SuccessInternal(const Value* result) override {
    *outcome_ = std::get<std::string>(*result); *done_ = true;
  }
  void ErrorInternal(const std::string&, const std::string&, const Value*) override { assert(false); }
  void NotImplementedInternal() override { assert(false); }
 private:
  bool* done_;
  std::string* outcome_;
};
std::string InsertAndPump(const std::string& text) {
  bool done = false; std::string outcome;
  BeginInsertion(text, std::make_unique<InsertionReply>(&done, &outcome));
  const auto deadline = GetTickCount64() + 2000;
  while (!done && GetTickCount64() < deadline) Pump(5);
  assert(done);
  return outcome;
}
void Key(WORD key, bool down) {
  INPUT in{}; in.type = INPUT_KEYBOARD; in.ki.wVk = key;
  in.ki.dwExtraInfo = 0x564f4943;
  in.ki.dwFlags = (key == VK_RMENU || key == VK_RCONTROL ? KEYEVENTF_EXTENDEDKEY : 0) | (down ? 0 : KEYEVENTF_KEYUP);
  assert(SendInput(1, &in, sizeof(INPUT)) == 1);
  Pump(15);
}
}
int main(int argc, char** argv) {
  const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  assert(SUCCEEDED(com));
  if (argc > 1 && std::string(argv[1]) == "--terminal-test") {
    HWND terminal = nullptr;
    EnumWindows([](HWND window, LPARAM out) -> BOOL {
      wchar_t title[256]{}; GetWindowTextW(window, title, 256);
      if (IsWindowVisible(window) && wcsstr(title, L"Relic Voice Terminal Fixture") && App(window) == "windowsterminal.exe") {
        *reinterpret_cast<HWND*>(out) = window; return FALSE;
      }
      return TRUE;
    }, reinterpret_cast<LPARAM>(&terminal));
    if (!terminal) return 3;
    const DWORD active_thread = GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
    const DWORD fixture_thread = GetCurrentThreadId();
    const bool attached = active_thread != fixture_thread && AttachThreadInput(fixture_thread, active_thread, TRUE);
    SetForegroundWindow(terminal);
    if (attached) AttachThreadInput(fixture_thread, active_thread, FALSE);
    Pump(100);
    if (GetForegroundWindow() != terminal) return 5;
    Snapshot();
    const auto before = GetClipboardSequenceNumber();
    const auto outcome = InsertAndPump("Ask Claude about my tennis shoes. 42");
    Pump(100);
    std::cout << outcome << "\n";
    CoUninitialize();
    return outcome == "sent" && before == GetClipboardSequenceNumber() ? 0 : 4;
  }
  if (argc > 1 && std::string(argv[1]) == "--browser-test") {
    HWND browser = nullptr;
    EnumWindows([](HWND window, LPARAM out) -> BOOL {
      wchar_t title[256]{}; GetWindowTextW(window, title, 256);
      if (IsWindowVisible(window) && wcsstr(title, L"Relic Voice Compatibility") && (App(window) == "msedge.exe" || App(window) == "chrome.exe")) {
        *reinterpret_cast<HWND*>(out) = window; return FALSE;
      }
      return TRUE;
    }, reinterpret_cast<LPARAM>(&browser));
    if (!browser) return 3;
    SetForegroundWindow(browser); Pump(100);
    if (GetForegroundWindow() != browser) return 5;
    Snapshot();
    const auto before = GetClipboardSequenceNumber();
    const auto outcome = InsertAndPump("Ask Claude about my tennis shoes. 42");
    Pump(100);
    std::cout << outcome << "\n";
    CoUninitialize();
    return outcome == "sent" && before == GetClipboardSequenceNumber() ? 0 : 4;
  }

  blocked = {"notepad", "msedge"};
  assert(AppBlocked("notepad.exe"));
  assert(AppBlocked("msedge.exe"));
  assert(!AppBlocked("code.exe"));
  blocked.clear();
  _set_error_mode(_OUT_TO_STDERR);
  _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);
  WNDCLASS wc{}; wc.lpfnWndProc = FixtureProc; wc.hInstance = GetModuleHandle(nullptr); wc.lpszClassName = L"RelicVoiceFixture";
  RegisterClass(&wc);
  HWND window = CreateWindow(wc.lpszClassName, L"Relic Voice isolated test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
    100,100,600,200,nullptr,nullptr,wc.hInstance,nullptr);
  HWND edit = CreateWindow(L"EDIT", L"", WS_CHILD | WS_VISIBLE | ES_MULTILINE,10,10,560,120,window,nullptr,wc.hInstance,nullptr);
  original_edit = reinterpret_cast<WNDPROC>(SetWindowLongPtr(edit, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(EditProc)));
  owner = window;
  ShowWindow(window,SW_SHOWNORMAL);
  // The test runner may be a background terminal. Attach only long enough to
  // foreground this fixture, then verify focus before injecting any keys.
  const DWORD foreground_thread = GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
  const DWORD fixture_thread = GetCurrentThreadId();
  const bool attached = foreground_thread != fixture_thread &&
      AttachThreadInput(fixture_thread, foreground_thread, TRUE);
  SetForegroundWindow(window); SetFocus(edit);
  if (attached) AttachThreadInput(fixture_thread, foreground_thread, FALSE);
  Pump(100);
  assert(GetForegroundWindow() == window);
  SetEnabled(true);
  assert(enabled);
  Key(VK_RMENU,true); Pump(230);
  assert(gesture.state == relic_voice::State::held);
  Key(VK_RMENU,false);
  assert(gesture.state == relic_voice::State::processing);
  Snapshot(); valid_target = true; // The fixture is in-process, unlike real targets.
  const auto sequence = GetClipboardSequenceNumber();
  assert(InsertAndPump("Ask Claude about the tennis shoes.") == "sent"); Pump(100);
  wchar_t text[256]{}; GetWindowTextW(edit,text,256);
  assert(std::wstring(text) == L"Ask Claude about the tennis shoes. ");
  assert(GetClipboardSequenceNumber() == sequence);
  assert(Insert("duplicate") == "target_changed");
  auto spacing = [&](const wchar_t* initial, int start, int end, const wchar_t* expected, const char* spoken = "more") {
    SetWindowTextW(edit, initial); SendMessageW(edit, EM_SETSEL, start, end); Pump(60);
    Snapshot(); valid_target = true;
    assert(InsertAndPump(spoken) == "sent"); Pump(40);
    GetWindowTextW(edit, text, 256);
    if (std::wstring(text) != expected) std::cerr << "Fixture mismatch: initial=" << Utf8(initial) << " expected=" << Utf8(expected) << " actual=" << Utf8(text) << std::endl;
    assert(std::wstring(text) == expected);
    assert(GetClipboardSequenceNumber() == sequence);
  };
  // Every insertion ends with one space and never adds a leading one.
  spacing(L"", 0, 0, L"more ");
  spacing(L"Existing. ", 10, 10, L"Existing. more ");
  spacing(L"Old", 0, 0, L"more Old");
  spacing(L"Old", 0, 3, L"more ");
  spacing(L"Keep old ending", 5, 8, L"Keep more ending");
  spacing(L"Existing.", 9, 9, L"Existing. more ", " more");
  spacing(L"", 0, 0, L"more ", "more ");
  std::cout << "Trailing space and selection replacement checks passed" << std::endl;
  gesture.Complete();
  Key(VK_RMENU,true); Key(VK_RMENU,false); Pump(40);
  Key(VK_RMENU,true); Key(VK_RMENU,false);
  assert(gesture.state == relic_voice::State::latched);
  Key(VK_RMENU,true); Key(VK_RMENU,false);
  assert(gesture.state == relic_voice::State::processing);
  gesture.Complete();
  Key(VK_LMENU,true); Pump(220);
  assert(gesture.state == relic_voice::State::idle);
  Key('X',true); Key('X',false); Key(VK_LMENU,false);
  Key(VK_LCONTROL,true); Key(VK_RMENU,true); Pump(230);
  assert(gesture.note && gesture.state == relic_voice::State::held);
  Key(VK_ESCAPE,true); Key(VK_ESCAPE,false); Key(VK_RMENU,false); Key(VK_LCONTROL,false);
  assert(gesture.state == relic_voice::State::idle);
  // Exercise the same-timestamp Ctrl + Right Alt pair emitted by AltGr.
  // It must remain dictation, including a double tap, not become a voice note.
  auto altgr_down = [] {
    INPUT pair[2]{};
    const DWORD time = GetTickCount();
    for (auto& input : pair) {
      input.type = INPUT_KEYBOARD; input.ki.time = time;
      input.ki.dwExtraInfo = 0x564f4943;
    }
    pair[0].ki.wVk = VK_LCONTROL;
    pair[1].ki.wVk = VK_RMENU; pair[1].ki.dwFlags = KEYEVENTF_EXTENDEDKEY;
    assert(SendInput(2, pair, sizeof(INPUT)) == 2); Pump(15);
  };
  altgr_down(); Pump(230);
  assert(!gesture.note && gesture.state == relic_voice::State::held);
  Key(VK_RMENU,false); Key(VK_LCONTROL,false); gesture.Complete();
  altgr_down(); Key(VK_RMENU,false); Key(VK_LCONTROL,false);
  altgr_down(); Key(VK_RMENU,false); Key(VK_LCONTROL,false);
  assert(!gesture.note && gesture.state == relic_voice::State::latched);
  altgr_down(); Key(VK_RMENU,false); Key(VK_LCONTROL,false);
  assert(gesture.state == relic_voice::State::processing);
  gesture.Complete();
  Key(VK_LCONTROL,true); altgr_down(); Pump(230);
  assert(gesture.note && gesture.state == relic_voice::State::held);
  Key(VK_RMENU,false); Key(VK_LCONTROL,false); gesture.Complete();
  // A real Alt chord must reach the target with its modifier, in order.
  Key(VK_RMENU,true); Key('X',true); Key('X',false); Key(VK_RMENU,false);
  Pump(50);
  assert(saw_alt_chord);
  assert(!(GetAsyncKeyState(VK_RMENU) & 0x8000));
  assert(gesture.state == relic_voice::State::idle);
  // A normal Alt tap opens the OS menu loop. Escape from a second thread so
  // the fixture does not wait for a human to close that real native menu.
  std::thread close_menu([] {
    Sleep(550);
    INPUT keys[2]{};
    for (auto& key : keys) { key.type = INPUT_KEYBOARD; key.ki.wVk = VK_ESCAPE; }
    keys[1].ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(2, keys, sizeof(INPUT));
  });
  Key(VK_RMENU,true); Key(VK_RMENU,false); Pump(650);
  close_menu.join();
  assert(gesture.state == relic_voice::State::idle);
  assert(!(GetAsyncKeyState(VK_RMENU) & 0x8000));
  Key(VK_ESCAPE,true); Key(VK_ESCAPE,false);
  SetForegroundWindow(window); SetFocus(edit); Pump(40);
  // Voice-reactive mark must not activate its window or change focus.
  RECT work{}; SystemParametersInfo(SPI_GETWORKAREA,0,&work,0);
  SetWindowPos(window,nullptr,work.left+(work.right-work.left-600)/2,work.bottom-360,600,320,SWP_NOZORDER | SWP_NOACTIVATE);
  assert(ShowNativeVoiceToast(window,true));
  const HWND popup = FindWindowW(L"RelicNativeGemToast", L"Relic Voice");
  assert(popup != nullptr);
  std::cout << "Recording silence shown" << std::endl;
  Pump(900);
  std::cout << "Recording quiet speech shown" << std::endl;
  for (int i = 0; i < 12; ++i) { UpdateNativeVoiceLevel(0.006); Pump(100); }
  std::cout << "Recording loud speech shown" << std::endl;
  for (int i = 0; i < 12; ++i) { UpdateNativeVoiceLevel(0.12); Pump(100); }
  std::cout << "Recording silence returned" << std::endl;
  for (int i = 0; i < 12; ++i) { UpdateNativeVoiceLevel(0.0); Pump(100); }
  assert(GetForegroundWindow() == window && Focus(window) == edit);
  assert(GetForegroundWindow() == window && Focus(window) == edit);
  assert(ShowNativeVoiceToast(window,false));
  std::cout << "Transcribing shadow shown" << std::endl;
  Pump(1600);
  assert(GetForegroundWindow() == window && Focus(window) == edit);
  HideNativeVoiceToast();
  assert(!IsWindow(popup));
  UpdateNativeVoiceLevel(1.0);
  assert(FindWindowW(L"RelicNativeGemToast", L"Relic Voice") == nullptr);
  Snapshot(); valid_target = true;
  Key(VK_LSHIFT,true);
  assert(Insert("must not type") == "modifiers_held");
  Key(VK_LSHIFT,false);
  SetEnabled(false);
  DestroyWindow(window);
  CoUninitialize();
  std::cout << "Native Right Alt hold/latch, Ctrl mode, Left Alt passthrough, AltGr, Escape, focus, Unicode insertion and clipboard checks passed\n";
}

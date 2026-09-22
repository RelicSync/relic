#include "native_voice.h"
#include "native_gem_toast.h"
#include "voice_gesture.h"
#include <chrono>
#include <future>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <memory>
#include <string>
#include <vector>
#include <wtsapi32.h>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Action = relic_voice::Action;
constexpr UINT kDispatch = WM_APP + 171;
constexpr UINT_PTR kTimer = 9171;
constexpr ULONG_PTR kOwnInput = 0x52454c56;
constexpr DWORD kVoiceAlt = VK_RMENU;
DWORD left_ctrl_down_at = 0;
bool left_ctrl_down_seen = false;
HWND owner = nullptr;
HHOOK hook = nullptr;
HHOOK mouse_hook = nullptr;
std::unique_ptr<flutter::MethodChannel<Value>> channel;
relic_voice::Gesture gesture;
bool enabled = false, valid_target = false, finishing = false;
HWND target = nullptr, focus = nullptr;
DWORD target_pid = 0, clipboard_at_start = 0;
std::string target_app;
std::vector<std::string> blocked;
uint64_t target_generation = 0;
bool VoiceWhitespace(wchar_t character) {
  return character == L' ' || character == L'\t' || character == L'\n' || character == L'\r' || character == L'\u00a0';
}

std::wstring Wide(const std::string& s) {
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring out(n, 0);
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n);
  return out;
}
std::string Utf8(const std::wstring& s) {
  const int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0, nullptr, nullptr);
  std::string out(n, 0);
  WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n, nullptr, nullptr);
  return out;
}
std::string App(HWND hwnd) {
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  wchar_t path[32768]; DWORD size = 32768;
  const bool ok = process && QueryFullProcessImageNameW(process, 0, path, &size);
  if (process) CloseHandle(process);
  if (!ok) return {};
  std::wstring name(path, size);
  name = name.substr(name.find_last_of(L"\\/") + 1);
  std::transform(name.begin(), name.end(), name.begin(), ::towlower);
  return Utf8(name);
}
HWND Focus(HWND hwnd) {
  GUITHREADINFO info{}; info.cbSize = sizeof(info);
  const DWORD thread = GetWindowThreadProcessId(hwnd, nullptr);
  return thread && GetGUIThreadInfo(thread, &info) ? info.hwndFocus : nullptr;
}
bool Password(HWND hwnd) {
  wchar_t cls[80]{};
  GetClassNameW(hwnd, cls, 80);
  return (_wcsicmp(cls, L"Edit") == 0 || wcsstr(cls, L"RichEdit")) && (GetWindowLongPtr(hwnd, GWL_STYLE) & ES_PASSWORD);
}
void Snapshot() {
  ++target_generation;
  target = GetForegroundWindow(); focus = Focus(target);
  GetWindowThreadProcessId(target, &target_pid);
  target_app = App(target);
  valid_target = target && target != owner && target_pid != GetCurrentProcessId() && focus && !Password(focus);
  clipboard_at_start = GetClipboardSequenceNumber();
  finishing = false;
}
bool AppBlocked(std::string app) {
  // Existing Relic exclusions are normalized executable stems, without .exe.
  if (app.size() >= 4 && app.compare(app.size() - 4, 4, ".exe") == 0) app.resize(app.size() - 4);
  return std::find(blocked.begin(), blocked.end(), app) != blocked.end();
}
bool Blocked() { return AppBlocked(target_app); }
void Emit(const std::string& event) {
  if (channel) channel->InvokeMethod("event", std::make_unique<Value>(Map{
    {Value("event"), Value(event)}, {Value("note"), Value(gesture.note)},
    {Value("waiting"), Value(gesture.state == relic_voice::State::waiting)},
    {Value("app"), Value(target_app)}, {Value("can_insert"), Value(valid_target)}}));
}
void ReplayAlt(bool up) {
  INPUT input{}; input.type = INPUT_KEYBOARD;
  input.ki.wVk = kVoiceAlt; input.ki.dwExtraInfo = kOwnInput;
  input.ki.dwFlags = KEYEVENTF_EXTENDEDKEY | (up ? KEYEVENTF_KEYUP : 0);
  SendInput(1, &input, sizeof(INPUT));
}
void Dispatch(const relic_voice::Decision& d) {
  for (auto action : d.actions) {
    if (action == Action::alt_down) { ReplayAlt(false); continue; }
    if (action == Action::alt_tap) { ReplayAlt(false); ReplayAlt(true); continue; }
    if (action == Action::candidate) Snapshot();
    if (action == Action::stop_no_insert) valid_target = false;
    if (action == Action::stop || action == Action::stop_no_insert) finishing = true;
    PostMessage(owner, kDispatch, static_cast<WPARAM>(action), 0);
  }
}
LRESULT CALLBACK Keyboard(int code, WPARAM message, LPARAM data) {
  if (code != HC_ACTION || !enabled) return CallNextHookEx(hook, code, message, data);
  const auto& key = *reinterpret_cast<KBDLLHOOKSTRUCT*>(data);
  if (key.flags & LLKHF_INJECTED) {
#ifdef RELIC_VOICE_TEST
    if (key.dwExtraInfo != 0x564f4943)
#endif
      return CallNextHookEx(hook, code, message, data);
  }
  const bool down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
  relic_voice::Decision d;
  if (key.vkCode == VK_LCONTROL) {
    if (down && !left_ctrl_down_seen) left_ctrl_down_at = key.time;
    left_ctrl_down_seen = down;
  }
  if (key.vkCode == kVoiceAlt) {
    // AltGr layouts precede Right Alt with a same-timestamp Left Ctrl event.
    // Only a Ctrl held before that pair selects voice-note mode.
    const bool ctrl = (GetAsyncKeyState(VK_LCONTROL) & 0x8000) != 0 &&
        (!left_ctrl_down_seen || left_ctrl_down_at != key.time);
    bool eligible = !(GetAsyncKeyState(VK_SHIFT) & 0x8000) && !(GetAsyncKeyState(VK_LWIN) & 0x8000) && !(GetAsyncKeyState(VK_RWIN) & 0x8000) && !(GetAsyncKeyState(VK_RCONTROL) & 0x8000) && !(GetAsyncKeyState(VK_LMENU) & 0x8000);
    if (down && !gesture.alt_down && !ctrl && gesture.state == relic_voice::State::idle) {
      const auto app = App(GetForegroundWindow());
      if (AppBlocked(app)) eligible = false;
    }
    d = gesture.Alt(down, ctrl, eligible, GetTickCount64());
  } else {
    if (down && key.vkCode == VK_TAB && gesture.state != relic_voice::State::idle) valid_target = false;
    if (down && finishing && key.vkCode != VK_LCONTROL && key.vkCode != VK_RCONTROL) valid_target = false;
    // A synthesized AltGr Ctrl must not interrupt the double-tap window.
    if (key.vkCode != VK_LCONTROL) d = gesture.Other(down, key.vkCode == VK_ESCAPE);
  }
  Dispatch(d);
  return d.swallow ? 1 : CallNextHookEx(hook, code, message, data);
}
LRESULT CALLBACK Mouse(int code, WPARAM message, LPARAM data) {
  if (code == HC_ACTION && (finishing || gesture.state == relic_voice::State::held || gesture.state == relic_voice::State::latched) && (message == WM_LBUTTONDOWN || message == WM_RBUTTONDOWN || message == WM_MOUSEWHEEL)) valid_target = false;
  return CallNextHookEx(mouse_hook, code, message, data);
}
void SetEnabled(bool value) {
  ++target_generation;
  enabled = value;
  if (hook) { UnhookWindowsHookEx(hook); hook = nullptr; }
  if (mouse_hook) { UnhookWindowsHookEx(mouse_hook); mouse_hook = nullptr; }
  KillTimer(owner, kTimer);
  if (gesture.forwarding && gesture.alt_down && !(GetAsyncKeyState(kVoiceAlt) & 0x8000)) ReplayAlt(true);
  gesture = {}; finishing = false; valid_target = false; left_ctrl_down_seen = false;
  if (value) {
    hook = SetWindowsHookEx(WH_KEYBOARD_LL, Keyboard, GetModuleHandle(nullptr), 0);
    mouse_hook = SetWindowsHookEx(WH_MOUSE_LL, Mouse, GetModuleHandle(nullptr), 0);
    enabled = hook && mouse_hook;
    SetTimer(owner, kTimer, 20, nullptr);
  }
}
std::string InsertionFailure() {
  DWORD pid = 0; GetWindowThreadProcessId(target, &pid);
  if (!valid_target || !IsWindow(target) || pid != target_pid || GetForegroundWindow() != target || Focus(target) != focus || Password(focus)) return "target_changed";
  if (GetClipboardSequenceNumber() != clipboard_at_start) return "clipboard_changed";
  for (int key : {VK_LMENU, VK_RMENU, VK_LCONTROL, VK_RCONTROL, VK_LSHIFT, VK_RSHIFT, VK_LWIN, VK_RWIN}) {
    if (GetAsyncKeyState(key) & 0x8000) return "modifiers_held";
  }
  return {};
}
std::string Insert(const std::string& text) {
  const auto failure = InsertionFailure();
  if (!failure.empty()) return failure;
  auto wide = Wide(text);
  if (wide.empty() || wide.size() > 16000) return "unsupported";
  // Every dictation ends with one space, so the next one (or typing) never
  // runs into it. Only the keystrokes get it; the saved transcript is unchanged.
  if (!VoiceWhitespace(wide.back())) wide.push_back(L' ');
  std::vector<INPUT> inputs;
  inputs.reserve(wide.size() * 2);
  for (wchar_t ch : wide) {
    // Never send Return/Tab commands to a chat or terminal. Spoken text is one paragraph.
    if (ch == L'\n' || ch == L'\r' || ch == L'\t') ch = L' ';
    INPUT input{}; input.type = INPUT_KEYBOARD;
    input.ki.wScan = ch; input.ki.dwFlags = KEYEVENTF_UNICODE; input.ki.dwExtraInfo = kOwnInput;
    inputs.push_back(input); input.ki.dwFlags |= KEYEVENTF_KEYUP; inputs.push_back(input);
  }
  valid_target = false;  // exactly one attempt, including a partial SendInput result
  const bool sent = SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT)) == inputs.size();
  return sent ? "sent" : "blocked";
}
void BeginInsertion(const std::string& text, std::unique_ptr<flutter::MethodResult<Value>> reply) {
  reply->Success(Value(Insert(text)));
}
}  // namespace

void InitializeNativeVoice(HWND window, flutter::BinaryMessenger* messenger) {
  owner = window;
  WTSRegisterSessionNotification(owner, NOTIFY_FOR_THIS_SESSION);
  channel = std::make_unique<flutter::MethodChannel<Value>>(messenger, "relic/voice", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const flutter::MethodCall<Value>& call, std::unique_ptr<flutter::MethodResult<Value>> result) {
    const Map* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    const auto str = [&](const char* key) { if (!args) return std::string{}; auto it = args->find(Value(key)); return it != args->end() && std::holds_alternative<std::string>(it->second) ? std::get<std::string>(it->second) : std::string{}; };
    if (call.method_name() == "enable") {
      SetEnabled(call.arguments() && std::get<bool>(*call.arguments())); result->Success(Value(enabled));
    } else if (call.method_name() == "blocklist") {
      blocked.clear();
      if (call.arguments()) for (const auto& item : std::get<flutter::EncodableList>(*call.arguments())) blocked.push_back(std::get<std::string>(item));
      result->Success();
    } else if (call.method_name() == "complete") {
      ++target_generation;
      gesture.Complete(); finishing = false; valid_target = false; result->Success();
    } else if (call.method_name() == "processing") {
      gesture.state = relic_voice::State::processing; finishing = true;
      result->Success();
    } else if (call.method_name() == "start") {
      if (!enabled || gesture.state != relic_voice::State::idle) { result->Success(Value(false)); return; }
      gesture.note = str("mode") == "voice_note";
      gesture.state = relic_voice::State::latched;
      Snapshot();
      Emit("candidate"); Emit("latched"); result->Success(Value(true));
    } else if (call.method_name() == "insert") {
      BeginInsertion(str("text"), std::move(result));
    } else if (call.method_name() == "level") {
      const auto* level = call.arguments() ? std::get_if<double>(call.arguments()) : nullptr;
      UpdateNativeVoiceLevel(level ? *level : 0.0);
      result->Success();
    } else if (call.method_name() == "overlay") {
      const auto phase = str("phase");
      if (phase == "recording" || phase == "processing") ShowNativeVoiceToast(target ? target : owner, phase == "recording");
      else HideNativeVoiceToast();
      result->Success();
    } else { result->NotImplemented(); }
  });
}
void DisposeNativeVoice() {
  SetEnabled(false); HideNativeVoiceToast();
  KillTimer(owner, kTimer);
  WTSUnRegisterSessionNotification(owner);
  if (channel) channel->SetMethodCallHandler(nullptr);
  channel.reset();
}
std::optional<LRESULT> HandleNativeVoiceMessage(UINT message, WPARAM wparam, LPARAM) {
  if (message == WM_TIMER && wparam == kTimer) {
    if (enabled) Dispatch(gesture.Tick(GetTickCount64()));
    return 0;
  }
  if (message == kDispatch) {
    const auto action = static_cast<Action>(wparam);
    if (action == Action::candidate && !gesture.note && Blocked()) {
      gesture.Complete(); valid_target = false; Emit("blocked"); return 0;
    }
    const char* name = action == Action::candidate ? "candidate" : action == Action::held ? "held" : action == Action::latched ? "latched" : action == Action::cancel ? "cancel" : "stop";
    Emit(name); return 0;
  }
  if ((message == WM_WTSSESSION_CHANGE && wparam == WTS_SESSION_LOCK) || (message == WM_POWERBROADCAST && wparam == PBT_APMSUSPEND)) {
    Emit("cancel"); gesture.Complete(); finishing = false; valid_target = false; HideNativeVoiceToast();
  }
  return std::nullopt;
}

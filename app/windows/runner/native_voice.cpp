#include "native_voice.h"
#include "native_gem_toast.h"
#include "voice_gesture.h"
#include <atomic>
#include <chrono>
#include <future>
#include <mutex>
#include <thread>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <memory>
#include <string>
#include <vector>
#include <wtsapi32.h>

// Threading. The keyboard and mouse hooks run on their own thread that does
// nothing else. Windows holds EVERY keystroke on the machine until a
// low-level hook answers, and quietly lets the key through when it answers
// too late. On the platform thread (which also runs Dart) any busy moment made
// the hook late: dictated text trickled in a letter at a time behind a
// backlog of keys, and a Right Alt press that leaked through had its release
// hidden, which left Right Alt held down for every app.
//
// `state_mutex` guards the gesture and the target snapshot. The hook thread
// holds it for microseconds; the platform thread only for the length of a
// method call. Nothing holding it ever waits on the other thread. Events for
// Dart are posted to the platform window and emitted there.

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Action = relic_voice::Action;
using State = relic_voice::State;
constexpr UINT kDispatch = WM_APP + 171;
constexpr UINT kInsertDone = WM_APP + 172;
constexpr ULONG_PTR kOwnInput = 0x52454c56;  // voice key replays
constexpr ULONG_PTR kOwnText = 0x52454c54;   // dictated text
constexpr size_t kBatch = 32;              // UTF-16 units per SendInput batch
constexpr DWORD kBatchWaitMs = 2000;
constexpr WPARAM kBlockedEvent = 100;
constexpr LPARAM kNoteFlag = 1, kWaitingFlag = 2, kCanInsertFlag = 4;

std::mutex state_mutex;
// The key that dictates, chosen in Voice settings. Only keys that are safe to
// hold and to double-tap are accepted (see VoiceKeyAllowed). Guarded by
// state_mutex; the hook copies it once per event.
DWORD voice_key = VK_RMENU;
DWORD left_ctrl_down_at = 0;
bool left_ctrl_down_seen = false;
HWND owner = nullptr;
std::unique_ptr<flutter::MethodChannel<Value>> channel;
relic_voice::Gesture gesture;
std::atomic<bool> enabled{false};
bool valid_target = false, finishing = false;
HWND target = nullptr, focus = nullptr;
DWORD target_pid = 0, clipboard_at_start = 0;
std::string target_app;
std::vector<std::string> blocked;
uint64_t target_generation = 0;

// Hook thread.
std::thread hook_thread;
DWORD hook_thread_id = 0;
HHOOK hook = nullptr, mouse_hook = nullptr;  // touched only on the hook thread
std::atomic<DWORD> last_hook_call{0};
std::atomic<uint32_t> own_text_seen{0};
std::atomic<uint32_t> hook_reinstalls{0};

// Insertion runs on its own short-lived thread and reports back here.
std::atomic<bool> inserting{false}, insert_interrupted{false};
std::thread insert_thread;
std::mutex insert_mutex;
std::string insert_outcome;
std::unique_ptr<flutter::MethodResult<Value>> insert_reply;

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
bool SystemKeyDown(DWORD vk) { return (GetAsyncKeyState(static_cast<int>(vk)) & 0x8000) != 0; }
bool VoiceKeyAllowed(DWORD vk) {
  switch (vk) {
    case VK_RMENU: case VK_RCONTROL: case VK_CAPITAL: case VK_APPS:
    case VK_INSERT: case VK_SCROLL: case VK_PAUSE: return true;
    default: return false;
  }
}
// Keys whose physical scan code carries the E0 prefix, so a replay reads the
// same to the target app as the real key did.
bool Extended(DWORD vk) {
  return vk == VK_RMENU || vk == VK_RCONTROL || vk == VK_APPS || vk == VK_INSERT;
}
// Callers hold state_mutex.
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
LPARAM Flags() {
  return (gesture.note ? kNoteFlag : 0) | (gesture.state == State::waiting ? kWaitingFlag : 0) |
         (valid_target ? kCanInsertFlag : 0);
}
// Platform thread only.
void Emit(const std::string& event, LPARAM flags) {
  std::string app;
  { std::lock_guard<std::mutex> lock(state_mutex); app = target_app; }
  if (channel) channel->InvokeMethod("event", std::make_unique<Value>(Map{
    {Value("event"), Value(event)}, {Value("note"), Value((flags & kNoteFlag) != 0)},
    {Value("waiting"), Value((flags & kWaitingFlag) != 0)},
    {Value("app"), Value(app)}, {Value("can_insert"), Value((flags & kCanInsertFlag) != 0)}}));
}
void ReplayKey(DWORD vk, bool up) {
  INPUT input{}; input.type = INPUT_KEYBOARD;
  input.ki.wVk = static_cast<WORD>(vk); input.ki.dwExtraInfo = kOwnInput;
  input.ki.dwFlags = (Extended(vk) ? KEYEVENTF_EXTENDEDKEY : 0) | (up ? KEYEVENTF_KEYUP : 0);
  SendInput(1, &input, sizeof(INPUT));
}
// Callers hold state_mutex. Voice key replays are collected, not sent, so they
// go out after the lock is released (still before the hook returns).
void Dispatch(const relic_voice::Decision& d, std::vector<bool>* replays) {
  for (auto action : d.actions) {
    if (action == Action::alt_down) { replays->push_back(false); continue; }
    if (action == Action::alt_tap) { replays->push_back(false); replays->push_back(true); continue; }
    if (action == Action::candidate) {
      Snapshot();
      if (!gesture.note && Blocked()) {
        gesture.Complete(); valid_target = false;
        PostMessage(owner, kDispatch, kBlockedEvent, Flags());
        return;
      }
    }
    if (action == Action::stop_no_insert) valid_target = false;
    if (action == Action::stop || action == Action::stop_no_insert) finishing = true;
    PostMessage(owner, kDispatch, static_cast<WPARAM>(action), Flags());
  }
}
void Replay(DWORD vk, const std::vector<bool>& replays) {
  for (bool up : replays) ReplayKey(vk, up);
}
LRESULT CALLBACK Keyboard(int code, WPARAM message, LPARAM data) {
  last_hook_call = GetTickCount();
  if (code != HC_ACTION || !enabled) return CallNextHookEx(nullptr, code, message, data);
  const auto& key = *reinterpret_cast<KBDLLHOOKSTRUCT*>(data);
  if (key.flags & LLKHF_INJECTED) {
    if (key.dwExtraInfo == kOwnText) own_text_seen.fetch_add(1);
#ifdef RELIC_VOICE_TEST
    if (key.dwExtraInfo != 0x564f4943)
#endif
      return CallNextHookEx(nullptr, code, message, data);
  }
  const bool down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
  // A person typing while dictated text is still going out: stop sending, or
  // the two streams interleave (and a held Ctrl turns letters into commands).
  if (down && inserting) insert_interrupted = true;
  const uint64_t now = relic_voice::EventTime(GetTickCount64(), GetTickCount(), key.time);
  std::vector<bool> replays;
  bool swallow = false;
  DWORD vk;
  {
    std::lock_guard<std::mutex> lock(state_mutex);
    vk = voice_key;
    relic_voice::Decision d;
    if (key.vkCode == VK_LCONTROL) {
      if (down && !left_ctrl_down_seen) left_ctrl_down_at = key.time;
      left_ctrl_down_seen = down;
    }
    if (key.vkCode == vk) {
      // AltGr layouts precede Right Alt with a same-timestamp Left Ctrl event.
      // Only a Ctrl held before that pair selects voice-note mode.
      const bool ctrl = (GetAsyncKeyState(VK_LCONTROL) & 0x8000) != 0 &&
          (vk != VK_RMENU || !left_ctrl_down_seen || left_ctrl_down_at != key.time);
      // Another modifier held means a shortcut, not dictation. Left Ctrl is
      // the voice-note modifier and the voice key never counts against itself.
      bool eligible = !(GetAsyncKeyState(VK_SHIFT) & 0x8000);
      for (DWORD other : {VK_LWIN, VK_RWIN, VK_RCONTROL, VK_LMENU, VK_RMENU}) {
        if (other != vk && SystemKeyDown(other)) eligible = false;
      }
      if (down && !gesture.alt_down && !ctrl && gesture.state == State::idle) {
        const auto app = App(GetForegroundWindow());
        if (AppBlocked(app)) eligible = false;
      }
      d = gesture.Alt(down, ctrl, eligible, now);
      swallow = relic_voice::SafeSwallow(d.swallow, down, SystemKeyDown(vk));
    } else {
      if (down && key.vkCode == VK_TAB && gesture.state != State::idle) valid_target = false;
      if (down && finishing && key.vkCode != VK_LCONTROL && key.vkCode != VK_RCONTROL) valid_target = false;
      // A synthesized AltGr Ctrl must not interrupt the double-tap window.
      if (key.vkCode != VK_LCONTROL) d = gesture.Other(down, key.vkCode == VK_ESCAPE);
      swallow = d.swallow;
    }
    Dispatch(d, &replays);
  }
  Replay(vk, replays);
  return swallow ? 1 : CallNextHookEx(nullptr, code, message, data);
}
LRESULT CALLBACK Mouse(int code, WPARAM message, LPARAM data) {
  last_hook_call = GetTickCount();
  if (code == HC_ACTION && (message == WM_LBUTTONDOWN || message == WM_RBUTTONDOWN || message == WM_MOUSEWHEEL)) {
    if (message != WM_MOUSEWHEEL && inserting) insert_interrupted = true;
    std::lock_guard<std::mutex> lock(state_mutex);
    if (finishing || gesture.state == State::held || gesture.state == State::latched) valid_target = false;
  }
  return CallNextHookEx(nullptr, code, message, data);
}
bool InstallHooks() {
  if (hook) UnhookWindowsHookEx(hook);
  if (mouse_hook) UnhookWindowsHookEx(mouse_hook);
  hook = SetWindowsHookEx(WH_KEYBOARD_LL, Keyboard, GetModuleHandle(nullptr), 0);
  mouse_hook = SetWindowsHookEx(WH_MOUSE_LL, Mouse, GetModuleHandle(nullptr), 0);
  return hook && mouse_hook;
}
void HookThread(std::promise<bool> ready) {
  MSG msg;
  PeekMessage(&msg, nullptr, WM_USER, WM_USER, PM_NOREMOVE);  // create the queue before anyone posts to it
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
  last_hook_call = GetTickCount();
  const bool ok = InstallHooks();
  ready.set_value(ok);
  const UINT_PTR tick = ok ? SetTimer(nullptr, 0, 20, nullptr) : 0;
  uint64_t last_watch = GetTickCount64(), last_reinstall = 0;
  while (ok && GetMessage(&msg, nullptr, 0, 0) > 0) {
    if (msg.message != WM_TIMER || msg.wParam != tick) { DispatchMessage(&msg); continue; }
    const uint64_t now = GetTickCount64();
    std::vector<bool> replays;
    DWORD vk;
    {
      std::lock_guard<std::mutex> lock(state_mutex);
      vk = voice_key;
      if (enabled) Dispatch(gesture.Tick(now), &replays);
    }
    Replay(vk, replays);
    // Watchdog. Windows removes a hook that times out without telling anyone.
    // Input the system saw that neither hook did means ours are gone: put
    // them back. A false alarm costs one reinstall, at most every 10 s.
    if (now - last_watch >= 1000) {
      last_watch = now;
      LASTINPUTINFO input{sizeof(input)};
      if (GetLastInputInfo(&input) && static_cast<LONG>(input.dwTime - last_hook_call.load()) > 2000 &&
          now - last_reinstall >= 10000) {
        last_reinstall = now;
        if (InstallHooks()) { last_hook_call = GetTickCount(); ++hook_reinstalls; }
      }
    }
  }
  if (tick) KillTimer(nullptr, tick);
  if (hook) { UnhookWindowsHookEx(hook); hook = nullptr; }
  if (mouse_hook) { UnhookWindowsHookEx(mouse_hook); mouse_hook = nullptr; }
}
void StopHookThread() {
  if (!hook_thread.joinable()) return;
  PostThreadMessage(hook_thread_id, WM_QUIT, 0, 0);
  hook_thread.join();
  hook_thread_id = 0;
}
void SetEnabled(bool value) {
  enabled = false;
  StopHookThread();  // no hook runs past this line
  bool involved;
  DWORD vk;
  {
    std::lock_guard<std::mutex> lock(state_mutex);
    vk = voice_key;
    ++target_generation;
    involved = gesture.alt_down || gesture.owned_alt || gesture.forwarding;
    gesture = {}; finishing = false; valid_target = false; left_ctrl_down_seen = false;
  }
  // Never leave the voice key held down for other apps once this hook is gone:
  // always when Voice turns off or Relic quits, and on a restart whenever the
  // gesture had a hand in the key. If a finger really is on it, its own
  // release passes straight through and does no harm.
  if (SystemKeyDown(vk) && (!value || involved)) ReplayKey(vk, true);
  if (!value) return;
  std::promise<bool> ready;
  auto installed = ready.get_future();
  hook_thread = std::thread(HookThread, std::move(ready));
  hook_thread_id = GetThreadId(hook_thread.native_handle());
  if (installed.get()) enabled = true;
  else StopHookThread();
}
// Callers hold state_mutex.
std::string InsertionFailure() {
  DWORD pid = 0; GetWindowThreadProcessId(target, &pid);
  if (!valid_target || !IsWindow(target) || pid != target_pid || GetForegroundWindow() != target || Focus(target) != focus || Password(focus)) return "target_changed";
  if (GetClipboardSequenceNumber() != clipboard_at_start) return "clipboard_changed";
  for (int key : {VK_LMENU, VK_RMENU, VK_LCONTROL, VK_RCONTROL, VK_LSHIFT, VK_RSHIFT, VK_LWIN, VK_RWIN}) {
    if (GetAsyncKeyState(key) & 0x8000) return "modifiers_held";
  }
  return {};
}
// Types `text` into the snapshotted target. Any thread; blocks until done.
// With the hook running the text goes out in small batches and each batch is
// seen through the hook before the next one, so a click to another window or
// a key the person presses stops the rest instead of spraying it elsewhere.
std::string Insert(const std::string& text) {
  HWND want_target, want_focus;
  {
    std::lock_guard<std::mutex> lock(state_mutex);
    const auto failure = InsertionFailure();
    if (!failure.empty()) return failure;
    valid_target = false;  // exactly one attempt, including a partial one
    want_target = target; want_focus = focus;
  }
  auto wide = Wide(text);
  if (wide.empty() || wide.size() > 16000) return "unsupported";
  // Every dictation ends with one space, so the next one (or typing) never
  // runs into it. Only the keystrokes get it; the saved transcript is unchanged.
  if (!VoiceWhitespace(wide.back())) wide.push_back(L' ');
  // Never send Return/Tab commands to a chat or terminal. Spoken text is one paragraph.
  for (auto& ch : wide) if (ch == L'\n' || ch == L'\r' || ch == L'\t') ch = L' ';
  const bool watched = enabled.load();
  insert_interrupted = false;
  inserting = true;
  std::string outcome = "sent";
  for (size_t from = 0; from < wide.size();) {
    const size_t n = watched ? relic_voice::NextBatch(wide, from, kBatch) : wide.size() - from;
    if (from > 0) {
      if (insert_interrupted) { outcome = "interrupted"; break; }
      if (GetForegroundWindow() != want_target || Focus(want_target) != want_focus) { outcome = "target_changed"; break; }
    }
    std::vector<INPUT> inputs;
    inputs.reserve(n * 2);
    for (size_t i = from; i < from + n; ++i) {
      INPUT input{}; input.type = INPUT_KEYBOARD;
      input.ki.wScan = wide[i]; input.ki.dwFlags = KEYEVENTF_UNICODE; input.ki.dwExtraInfo = kOwnText;
      inputs.push_back(input); input.ki.dwFlags |= KEYEVENTF_KEYUP; inputs.push_back(input);
    }
    const uint32_t expect = own_text_seen.load() + static_cast<uint32_t>(inputs.size());
    if (SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT)) != inputs.size()) { outcome = "blocked"; break; }
    from += n;
    if (!watched) break;
    const uint64_t deadline = GetTickCount64() + kBatchWaitMs;
    while (static_cast<int32_t>(own_text_seen.load() - expect) < 0) {
      if (GetTickCount64() > deadline || !enabled) { outcome = "blocked"; from = wide.size(); break; }
      Sleep(1);
    }
  }
  inserting = false;
  return outcome;
}
void FinishInsertion() {
  if (insert_thread.joinable()) insert_thread.join();
  std::string outcome;
  { std::lock_guard<std::mutex> lock(insert_mutex); outcome = insert_outcome; }
  if (auto reply = std::move(insert_reply)) reply->Success(Value(outcome));
}
void BeginInsertion(const std::string& text, std::unique_ptr<flutter::MethodResult<Value>> reply) {
  if (insert_reply) { reply->Success(Value("busy")); return; }
  if (insert_thread.joinable()) insert_thread.join();
  insert_reply = std::move(reply);
  insert_thread = std::thread([text] {
    const auto outcome = Insert(text);
    { std::lock_guard<std::mutex> lock(insert_mutex); insert_outcome = outcome; }
    PostMessage(owner, kInsertDone, 0, 0);
  });
}
const char* EventName(WPARAM event) {
  if (event == kBlockedEvent) return "blocked";
  switch (static_cast<Action>(event)) {
    case Action::candidate: return "candidate";
    case Action::held: return "held";
    case Action::latched: return "latched";
    case Action::cancel: return "cancel";
    default: return "stop";
  }
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
      SetEnabled(call.arguments() && std::get<bool>(*call.arguments())); result->Success(Value(enabled.load()));
    } else if (call.method_name() == "key") {
      // Takes effect between gestures only; a take in progress keeps its key.
      const auto* vk = call.arguments() ? std::get_if<int32_t>(call.arguments()) : nullptr;
      bool changed = false;
      if (vk && VoiceKeyAllowed(static_cast<DWORD>(*vk))) {
        std::lock_guard<std::mutex> lock(state_mutex);
        if (gesture.state == State::idle && !gesture.alt_down) {
          voice_key = static_cast<DWORD>(*vk);
          changed = true;
        }
      }
      result->Success(Value(changed));
    } else if (call.method_name() == "blocklist") {
      std::lock_guard<std::mutex> lock(state_mutex);
      blocked.clear();
      if (call.arguments()) for (const auto& item : std::get<flutter::EncodableList>(*call.arguments())) blocked.push_back(std::get<std::string>(item));
      result->Success();
    } else if (call.method_name() == "complete") {
      std::lock_guard<std::mutex> lock(state_mutex);
      ++target_generation;
      // A first tap that is waiting for its second one belongs to the key
      // gesture, not to the session Dart is finishing. Resetting it here made
      // a double tap miss whenever the worker's idle report beat the second
      // tap. Left alone, it latches or times out on its own.
      if (gesture.state != State::waiting) gesture.Complete();
      finishing = false; valid_target = false; result->Success();
    } else if (call.method_name() == "processing") {
      std::lock_guard<std::mutex> lock(state_mutex);
      gesture.state = State::processing; finishing = true;
      result->Success();
    } else if (call.method_name() == "start") {
      LPARAM flags = 0;
      {
        std::lock_guard<std::mutex> lock(state_mutex);
        if (!enabled || gesture.state != State::idle) { result->Success(Value(false)); return; }
        gesture.note = str("mode") == "voice_note";
        gesture.state = State::latched;
        Snapshot();
        flags = Flags();
      }
      Emit("candidate", flags); Emit("latched", flags); result->Success(Value(true));
    } else if (call.method_name() == "insert") {
      BeginInsertion(str("text"), std::move(result));
    } else if (call.method_name() == "level") {
      const auto* level = call.arguments() ? std::get_if<double>(call.arguments()) : nullptr;
      UpdateNativeVoiceLevel(level ? *level : 0.0);
      result->Success();
    } else if (call.method_name() == "overlay") {
      const auto phase = str("phase");
      HWND anchor;
      { std::lock_guard<std::mutex> lock(state_mutex); anchor = target ? target : owner; }
      if (phase == "recording" || phase == "processing") ShowNativeVoiceToast(anchor, phase == "recording");
      else HideNativeVoiceToast();
      result->Success();
    } else { result->NotImplemented(); }
  });
}
void DisposeNativeVoice() {
  SetEnabled(false); HideNativeVoiceToast();
  if (insert_thread.joinable()) insert_thread.join();
  insert_reply.reset();
  WTSUnRegisterSessionNotification(owner);
  if (channel) channel->SetMethodCallHandler(nullptr);
  channel.reset();
}
std::optional<LRESULT> HandleNativeVoiceMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kDispatch) { Emit(EventName(wparam), lparam); return 0; }
  if (message == kInsertDone) { FinishInsertion(); return 0; }
  if ((message == WM_WTSSESSION_CHANGE && wparam == WTS_SESSION_LOCK) || (message == WM_POWERBROADCAST && wparam == PBT_APMSUSPEND)) {
    LPARAM flags;
    {
      std::lock_guard<std::mutex> lock(state_mutex);
      gesture.Complete(); finishing = false; valid_target = false;
      flags = Flags();
    }
    Emit("cancel", flags); HideNativeVoiceToast();
  }
  return std::nullopt;
}

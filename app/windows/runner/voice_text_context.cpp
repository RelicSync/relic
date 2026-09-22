#include "voice_text_context.h"
#include <UIAutomation.h>
#include <wrl/client.h>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>

using Microsoft::WRL::ComPtr;

bool VoiceWhitespace(wchar_t character) {
  WORD type = 0;
  return GetStringTypeW(CT_CTYPE1, &character, 1, &type) && (type & C1_SPACE);
}

namespace {
HWND NativeEditFocus(HWND window) {
  GUITHREADINFO info{}; info.cbSize = sizeof(info);
  const DWORD thread = GetWindowThreadProcessId(window, nullptr);
  if (!thread || !GetGUIThreadInfo(thread, &info)) return nullptr;
  wchar_t name[80]{};
  GetClassNameW(info.hwndFocus, name, 80);
  return _wcsicmp(name, L"Edit") == 0 || wcsstr(name, L"RichEdit") ? info.hwndFocus : nullptr;
}
VoiceTextContext ReadContext(IUIAutomation2* automation, HWND expected_window) {
  if (GetForegroundWindow() != expected_window) return {};
  if (!automation) return {};
  ComPtr<IUIAutomationElement> element;
  // Classic edit controls have their own HWND. Resolving it directly avoids
  // the slower global accessibility focus search used for web/custom editors.
  const HWND edit = NativeEditFocus(expected_window);
  const HRESULT found = edit ? automation->ElementFromHandle(edit, &element) :
      automation->GetFocusedElement(&element);
  if (FAILED(found) || !element) return {};
  BOOL password = TRUE;
  if (FAILED(element->get_CurrentIsPassword(&password))) return {};
  if (password) return {false, true};
  ComPtr<IUIAutomationTextPattern> pattern;
  if (FAILED(element->GetCurrentPatternAs(UIA_TextPatternId,
      IID_PPV_ARGS(&pattern))) || !pattern) return {};
  ComPtr<IUIAutomationTextRangeArray> selections;
  if (FAILED(pattern->GetSelection(&selections)) || !selections) return {};
  int count = 0;
  if (FAILED(selections->get_Length(&count)) || count != 1) return {};
  ComPtr<IUIAutomationTextRange> range;
  if (FAILED(selections->GetElement(0, &range)) || !range) return {};
  // This changes only our range object, never the editor's caret or selection.
  if (FAILED(range->MoveEndpointByRange(TextPatternRangeEndpoint_End,
      range.Get(), TextPatternRangeEndpoint_Start))) return {};
  int moved = 0;
  if (FAILED(range->MoveEndpointByUnit(TextPatternRangeEndpoint_Start,
      TextUnit_Character, -1, &moved))) return {};
  if (moved == 0) return {false, false, true};  // start of field
  if (moved != -1) return {};
  BSTR preceding = nullptr;
  if (FAILED(range->GetText(8, &preceding))) return {};
  const UINT length = preceding ? SysStringLen(preceding) : 0;
  // Includes surrogate pairs and combining characters, but refuses truncated
  // ranges from providers that substitute a larger text unit for a character.
  const bool space = length > 0 && length < 8 && !VoiceWhitespace(preceding[length - 1]);
  SysFreeString(preceding);
  if (edit) {
    if (NativeEditFocus(expected_window) != edit || GetForegroundWindow() != expected_window) return {};
    return {space, false, length > 0 && length < 8};
  }
  ComPtr<IUIAutomationElement> current;
  BOOL same = FALSE;
  if (FAILED(automation->GetFocusedElement(&current)) || !current ||
      FAILED(automation->CompareElements(element.Get(), current.Get(), &same)) ||
      !same || GetForegroundWindow() != expected_window) return {};
  return {space, false, length > 0 && length < 8};
}
// Keep the accessibility client on one MTA thread. Creating and tearing down
// COM for every utterance can cost more than the text lookup itself.
class ContextWorker {
 public:
  ContextWorker() : thread_([this] { Run(); }) {}
  ~ContextWorker() {
    { std::lock_guard<std::mutex> lock(mutex_); stopping_ = true; }
    changed_.notify_one();
    thread_.join();
  }
  std::future<VoiceTextContext> Read(HWND window) {
    auto job = std::make_shared<Job>(); job->window = window;
    auto result = job->answer.get_future();
    { std::lock_guard<std::mutex> lock(mutex_); next_ = job; }
    changed_.notify_one();
    return result;
  }
 private:
  struct Job { HWND window = nullptr; std::promise<VoiceTextContext> answer; };
  void Run() {
    const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ComPtr<IUIAutomation2> automation;
    if (SUCCEEDED(initialized)) {
      CoCreateInstance(__uuidof(CUIAutomation8), nullptr,
          CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&automation));
      if (automation) {
        automation->put_ConnectionTimeout(100);
        automation->put_TransactionTimeout(100);
      }
    }
    for (;;) {
      std::shared_ptr<Job> job;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        changed_.wait(lock, [this] { return stopping_ || next_; });
        if (stopping_ && !next_) break;
        job = std::move(next_);
      }
      VoiceTextContext context;
      try { context = ReadContext(automation.Get(), job->window); } catch (...) {}
      job->answer.set_value(context);
    }
    automation.Reset();
    if (SUCCEEDED(initialized)) CoUninitialize();
  }
  std::mutex mutex_;
  std::condition_variable changed_;
  bool stopping_ = false;
  std::shared_ptr<Job> next_;
  std::thread thread_;
};
std::unique_ptr<ContextWorker> worker;
}  // namespace

std::future<VoiceTextContext> ReadVoiceTextContextAsync(HWND expected_window) {
  if (!worker) worker = std::make_unique<ContextWorker>();
  return worker->Read(expected_window);
}
void ShutdownVoiceTextContext() { worker.reset(); }

#include "lumora_links.h"

#include <cstdint>  // binary_messenger.h uses uint8_t without including it

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cwchar>
#include <cwctype>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace lumora_links {
namespace {

using flutter::EncodableList;
using flutter::EncodableValue;
using Channel = flutter::MethodChannel<EncodableValue>;

constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";  // win32_window.cpp
constexpr wchar_t kInstanceProp[] = L"LumoraInstance";
constexpr ULONG_PTR kCopyDataTag = 0x4C4D524B;  // "LMRK"
constexpr size_t kMaxLink = 4096;
constexpr size_t kMaxQueued = 8;

HANDLE g_mutex = nullptr;  // held for the whole process lifetime

struct State {
  HWND window = nullptr;
  std::unique_ptr<Channel> channel;
  bool dart_ready = false;
  std::vector<std::string> queued;  // links that came before Dart listened
};
State* g_state = nullptr;

// FNV-1a of the data folder (case-insensitive); the default folder is 0.
uint64_t DataDirHash() {
  std::vector<wchar_t> buf(32768);
  const DWORD n = GetEnvironmentVariableW(L"LUMORA_DATA_DIR", buf.data(), static_cast<DWORD>(buf.size()));
  if (n == 0 || n >= buf.size()) return 0;
  uint64_t h = 1469598103934665603ULL;
  for (DWORD i = 0; i < n; i++) {
    h ^= static_cast<uint64_t>(std::towlower(static_cast<wint_t>(buf[i])));
    h *= 1099511628211ULL;
  }
  return h ? h : 1;
}

// Window property value marking a Lumora main window for that data folder.
HANDLE InstanceTag() {
  const uint64_t h = DataDirHash();
  return reinterpret_cast<HANDLE>(static_cast<uintptr_t>(h ? h : 0x4C756D6FULL));
}

std::wstring MutexName() {
  wchar_t name[96];
  swprintf(name, 96, L"Local\\LumoraSingleInstance-%016llx", static_cast<unsigned long long>(DataDirHash()));
  return name;
}

// "lumora://…" (scheme in any case) → normalised link; anything else → "".
std::string AsLink(const std::string& arg) {
  static const char kScheme[] = "lumora://";
  const size_t n = sizeof(kScheme) - 1;
  if (arg.size() <= n || arg.size() > kMaxLink) return std::string();
  for (size_t i = 0; i < n; i++) {
    const char c = arg[i] >= 'A' && arg[i] <= 'Z' ? static_cast<char>(arg[i] - 'A' + 'a') : arg[i];
    if (c != kScheme[i]) return std::string();
  }
  return kScheme + arg.substr(n);
}

struct FindCtx {
  HANDLE tag;
  HWND found;
};

BOOL CALLBACK FindProc(HWND hwnd, LPARAM lparam) {
  auto* ctx = reinterpret_cast<FindCtx*>(lparam);
  wchar_t cls[64] = {};
  if (GetClassNameW(hwnd, cls, 64) == 0 || wcscmp(cls, kWindowClass) != 0) return TRUE;
  if (GetPropW(hwnd, kInstanceProp) != ctx->tag) return TRUE;
  ctx->found = hwnd;
  return FALSE;
}

HWND FindInstanceWindow() {
  FindCtx ctx{InstanceTag(), nullptr};
  EnumWindows(FindProc, reinterpret_cast<LPARAM>(&ctx));
  return ctx.found;
}

void BringToFront(HWND window) {
  if (IsIconic(window)) {
    ShowWindow(window, SW_RESTORE);
  } else if (IsWindowVisible(window)) {
    ShowWindow(window, SW_SHOW);
  }  // still hidden: Flutter shows it after its first frame
  SetForegroundWindow(window);
}

void Deliver(const std::string& link) {
  if (!g_state) return;
  if (g_state->channel && g_state->dart_ready) {
    g_state->channel->InvokeMethod("open", std::make_unique<EncodableValue>(link));
  } else if (g_state->queued.size() < kMaxQueued) {
    g_state->queued.push_back(link);
  }
}

}  // namespace

bool HandOffToRunningInstance(const std::vector<std::string>& args) {
  if (g_mutex) return false;
  // Owned by this (main) thread while Lumora runs; a later launch waiting on it
  // gets it once this process is gone.
  g_mutex = CreateMutexW(nullptr, TRUE, MutexName().c_str());
  if (!g_mutex || GetLastError() != ERROR_ALREADY_EXISTS) return false;  // first instance

  std::string link;
  for (const auto& a : args) {
    link = AsLink(a);
    if (!link.empty()) break;
  }
  // The other Lumora may still be creating its window, or be shutting down.
  for (int i = 0; i < 50; i++) {
    const HWND target = FindInstanceWindow();
    if (target) {
      DWORD pid = 0;
      GetWindowThreadProcessId(target, &pid);
      AllowSetForegroundWindow(pid);
      COPYDATASTRUCT data = {};
      data.dwData = kCopyDataTag;
      data.cbData = static_cast<DWORD>(link.size());
      data.lpData = link.empty() ? nullptr : const_cast<char*>(link.data());
      DWORD_PTR answer = 0;
      SendMessageTimeoutW(target, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG | SMTO_BLOCK,
                          5000, &answer);
      BringToFront(target);
      return true;
    }
    const DWORD w = WaitForSingleObject(g_mutex, 200);
    if (w == WAIT_OBJECT_0 || w == WAIT_ABANDONED) return false;  // it exited: we are the instance now
  }
  return true;  // running but unresponsive: do not open a second copy on the same data
}

void RegisterWindow(HWND window, flutter::BinaryMessenger* messenger) {
  if (!g_state) g_state = new State();
  g_state->window = window;
  SetPropW(window, kInstanceProp, InstanceTag());
  // Let a launch from a different integrity level (e.g. an elevated installer) reach us.
  ChangeWindowMessageFilterEx(window, WM_COPYDATA, MSGFLT_ALLOW, nullptr);
  g_state->dart_ready = false;
  g_state->channel =
      std::make_unique<Channel>(messenger, "lumora/links", &flutter::StandardMethodCodec::GetInstance());
  g_state->channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call, std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() != "ready") {
          result->NotImplemented();
          return;
        }
        // Dart listens now: hand over what arrived before.
        EncodableList links;
        for (auto& l : g_state->queued) links.emplace_back(std::move(l));
        g_state->queued.clear();
        g_state->dart_ready = true;
        result->Success(EncodableValue(std::move(links)));
      });
}

bool HandleCopyData(HWND window, LPARAM lparam) {
  const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
  if (!data || data->dwData != kCopyDataTag) return false;
  std::string link;
  if (data->lpData && data->cbData > 0 && data->cbData <= kMaxLink) {
    link = AsLink(std::string(static_cast<const char*>(data->lpData), data->cbData));
  }
  BringToFront(window);
  if (!link.empty()) Deliver(link);
  return true;
}

void Shutdown() {
  if (!g_state) return;
  if (g_state->window) RemovePropW(g_state->window, kInstanceProp);
  g_state->window = nullptr;
  if (g_state->channel) g_state->channel->SetMethodCallHandler(nullptr);
  g_state->channel.reset();
  g_state->dart_ready = false;
}

}  // namespace lumora_links

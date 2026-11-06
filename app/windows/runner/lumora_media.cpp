// `lumora/media` channel for Windows (decoder: lumora_media.h).
//
// Threads:
//  - platform thread: the method channel and every MethodResult. Flutter only
//    accepts channel traffic there.
//  - one worker thread (started on first use): decodes queued files one after
//    the other with WIC, so a large HEIC never freezes the window.
// The worker keeps finished JPEGs by request id and posts a registered window
// message (id in WPARAM) to the Flutter window; FlutterWindow::MessageHandler
// passes it to HandleWindowMessage, which answers on the platform thread. No
// pointers travel through the message queue.
#include "lumora_media.h"

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace lumora_media {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Channel = flutter::MethodChannel<EncodableValue>;
using Result = flutter::MethodResult<EncodableValue>;

struct Job {
  uint64_t id = 0;
  std::wstring path;
  int max_side = 0;
};

// Shared with the worker thread (guarded by |mu|).
struct Worker {
  std::mutex mu;
  std::condition_variable wake;
  std::deque<Job> jobs;
  std::map<uint64_t, std::vector<uint8_t>> finished;  // empty vector = not decodable
  HWND window = nullptr;  // nullptr after Shutdown(): results are dropped
  bool started = false;
};

// Platform thread only.
struct State {
  std::unique_ptr<Channel> channel;
  std::map<uint64_t, std::unique_ptr<Result>> pending;
  uint64_t next_id = 1;
};

// Never freed: the detached worker may still be decoding at process exit.
Worker* g_worker = nullptr;
State* g_state = nullptr;
UINT g_reply_message = 0;

void WorkerMain(Worker* w) {
  // COM for WIC once for this thread (DecodeToJpeg's own init then nests).
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  for (;;) {
    Job job;
    {
      std::unique_lock<std::mutex> lock(w->mu);
      w->wake.wait(lock, [w] { return !w->jobs.empty(); });
      job = std::move(w->jobs.front());
      w->jobs.pop_front();
    }
    std::vector<uint8_t> jpeg;
    if (!DecodeToJpeg(job.path, job.max_side, &jpeg)) jpeg.clear();
    std::lock_guard<std::mutex> lock(w->mu);
    if (!w->window) continue;  // window closed meanwhile
    w->finished[job.id] = std::move(jpeg);
    // A failed post (queue full) is retried by the next finished job; the
    // handler drains everything that is ready.
    PostMessageW(w->window, g_reply_message, static_cast<WPARAM>(job.id), 0);
  }
}

const EncodableValue* Arg(const EncodableMap* args, const char* key) {
  if (!args) return nullptr;
  const auto it = args->find(EncodableValue(key));
  return it == args->end() ? nullptr : &it->second;
}

void HandleCall(const flutter::MethodCall<EncodableValue>& call, std::unique_ptr<Result> result) {
  if (call.method_name() != "heicToJpeg") {
    result->NotImplemented();
    return;
  }
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  std::string path;
  int max_side = 0;
  if (const auto* v = Arg(args, "path")) {
    if (const auto* s = std::get_if<std::string>(v)) path = *s;
  }
  if (const auto* v = Arg(args, "maxSide")) {
    if (const auto* i = std::get_if<int32_t>(v)) max_side = *i;
    if (const auto* l = std::get_if<int64_t>(v)) max_side = *l > 1 << 20 ? 1 << 20 : static_cast<int>(*l);
  }
  if (path.empty() || !g_worker) {
    result->Success();  // null → "Mở bằng ứng dụng khác" fallback
    return;
  }
  const uint64_t id = g_state->next_id++;
  {
    std::lock_guard<std::mutex> lock(g_worker->mu);
    if (!g_worker->window) {
      result->Success();
      return;
    }
    g_worker->jobs.push_back(Job{id, Utf8ToWide(path), max_side});
    if (!g_worker->started) {
      g_worker->started = true;
      std::thread(WorkerMain, g_worker).detach();
    }
  }
  g_state->pending[id] = std::move(result);
  g_worker->wake.notify_one();
}

}  // namespace

void RegisterChannel(flutter::BinaryMessenger* messenger, HWND window) {
  if (!g_reply_message) {
    g_reply_message = RegisterWindowMessageW(L"LumoraMediaDecoded");
    if (!g_reply_message) g_reply_message = WM_APP + 0x44;
  }
  if (!g_state) g_state = new State();
  if (!g_worker) g_worker = new Worker();
  {
    std::lock_guard<std::mutex> lock(g_worker->mu);
    g_worker->window = window;
  }
  g_state->channel =
      std::make_unique<Channel>(messenger, "lumora/media", &flutter::StandardMethodCodec::GetInstance());
  g_state->channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call, std::unique_ptr<Result> result) {
        HandleCall(call, std::move(result));
      });
}

bool HandleWindowMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (!g_reply_message || message != g_reply_message) return false;
  if (!g_state || !g_worker) return true;
  // Everything finished so far (a lost post is caught up by a later one).
  std::map<uint64_t, std::vector<uint8_t>> ready;
  {
    std::lock_guard<std::mutex> lock(g_worker->mu);
    ready.swap(g_worker->finished);
  }
  for (auto& entry : ready) {
    const auto it = g_state->pending.find(entry.first);
    if (it == g_state->pending.end()) continue;
    std::unique_ptr<Result> result = std::move(it->second);
    g_state->pending.erase(it);
    if (entry.second.empty()) {
      result->Success();
    } else {
      result->Success(EncodableValue(std::move(entry.second)));
    }
  }
  return true;
}

void Shutdown() {
  if (!g_state) return;
  if (g_worker) {
    std::lock_guard<std::mutex> lock(g_worker->mu);
    g_worker->window = nullptr;
    g_worker->jobs.clear();
    g_worker->finished.clear();
  }
  std::map<uint64_t, std::unique_ptr<Result>> pending;
  pending.swap(g_state->pending);
  for (auto& entry : pending) entry.second->Success();
  if (g_state->channel) g_state->channel->SetMethodCallHandler(nullptr);
  g_state->channel.reset();
}

}  // namespace lumora_media

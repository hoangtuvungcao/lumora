// Windows camera capture for calls (channel "lumora/camera").
//
// A Media Foundation source reader converts whatever the webcam delivers
// (MJPG, YUY2, NV12...) to NV12, and every frame is pushed straight into the
// core with lumora_push_camera_yuv: no copies, no Dart in the hot path.
//
// Threads:
//  - platform thread: the method channel, replies and onError. Flutter only
//    accepts channel traffic there.
//  - control thread: runs supported/start/stop/switch one at a time, so a
//    fast start -> stop -> start can never race, and slow device opens never
//    freeze the UI.
//  - capture thread (one per session): opens the device, then loops on the
//    synchronous ReadSample until asked to stop.
// Workers hand results back through a hidden message-only window owned by
// the platform thread (PostMessage wakes it, it runs queued closures).
// Pending MethodResults never leave the platform thread; workers only refer
// to them by id.
//
// Media Foundation is loaded at runtime: Windows "N" editions ship without
// it, and a static import would stop the whole app from launching there.
#include "lumora_camera.h"

#include <windows.h>
#include <devpropdef.h>
#include <cfgmgr32.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <shellapi.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "lumora_media.h"  // Com<T>, Utf8ToWide

namespace lumora_camera {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using lumora_media::Com;
using Channel = flutter::MethodChannel<EncodableValue>;
using Result = flutter::MethodResult<EncodableValue>;
using std::chrono::milliseconds;

// lumora_push_camera_yuv from lumora_ffi.dll.
typedef int32_t (*PushFn)(uint32_t width, uint32_t height, const uint8_t* y, uint32_t y_stride, const uint8_t* u,
                          uint32_t u_stride, const uint8_t* v, uint32_t v_stride, uint32_t uv_pixel_stride,
                          uint32_t rotation);

constexpr DWORD kVideoStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
constexpr DWORD kAllStreams = static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS);
constexpr UINT kRunTasks = WM_APP + 0x43;  // only our message-only window gets it

template <class F>
bool Resolve(HMODULE module, const char* name, F* out) {
  const FARPROC proc = module ? GetProcAddress(module, name) : nullptr;
  // Via void(*)() so neither MSVC nor GCC complains about the function cast.
  *out = reinterpret_cast<F>(reinterpret_cast<void (*)()>(proc));
  return proc != nullptr;
}

HMODULE LoadSystemDll(const wchar_t* name) {
  // System32 only: never pick up a planted DLL from the app directory.
  return LoadLibraryExW(name, nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
}

// ---------------------------------------------------------------------------
// Runtime-loaded APIs.

struct MfApi {
  HRESULT(STDAPICALLTYPE* Startup)(ULONG, DWORD) = nullptr;
  HRESULT(STDAPICALLTYPE* Shutdown)() = nullptr;
  HRESULT(STDAPICALLTYPE* CreateAttributes)(IMFAttributes**, UINT32) = nullptr;
  HRESULT(STDAPICALLTYPE* CreateMediaType)(IMFMediaType**) = nullptr;
  HRESULT(STDAPICALLTYPE* EnumDeviceSources)(IMFAttributes*, IMFActivate***, UINT32*) = nullptr;
  HRESULT(STDAPICALLTYPE* CreateSourceReaderFromMediaSource)(IMFMediaSource*, IMFAttributes*,
                                                              IMFSourceReader**) = nullptr;
  bool ok = false;
};

MfApi LoadMf() {
  MfApi api;
  const HMODULE plat = LoadSystemDll(L"mfplat.dll");
  const HMODULE mf = LoadSystemDll(L"mf.dll");
  const HMODULE rw = LoadSystemDll(L"mfreadwrite.dll");
  api.ok = Resolve(plat, "MFStartup", &api.Startup) && Resolve(plat, "MFShutdown", &api.Shutdown) &&
           Resolve(plat, "MFCreateAttributes", &api.CreateAttributes) &&
           Resolve(plat, "MFCreateMediaType", &api.CreateMediaType) &&
           Resolve(mf, "MFEnumDeviceSources", &api.EnumDeviceSources) &&
           Resolve(rw, "MFCreateSourceReaderFromMediaSource", &api.CreateSourceReaderFromMediaSource);
  return api;
}

const MfApi& Mf() {
  static const MfApi api = LoadMf();  // thread-safe static init; DLLs stay loaded
  return api;
}

// cfgmgr32 (declared by hand: older SDK / mingw headers lack some of these).
struct CmApi {
  CONFIGRET(WINAPI* GetInterfaceProperty)(LPCWSTR, const DEVPROPKEY*, DEVPROPTYPE*, PBYTE, PULONG, ULONG) = nullptr;
  CONFIGRET(WINAPI* LocateDevNode)(DEVINST*, LPWSTR, ULONG) = nullptr;
  CONFIGRET(WINAPI* GetDevNodeProperty)(DEVINST, const DEVPROPKEY*, DEVPROPTYPE*, PBYTE, PULONG, ULONG) = nullptr;
};

const CmApi& Cm() {
  static const CmApi api = [] {
    CmApi a;
    const HMODULE cm = LoadSystemDll(L"cfgmgr32.dll");
    Resolve(cm, "CM_Get_Device_Interface_PropertyW", &a.GetInterfaceProperty);
    Resolve(cm, "CM_Locate_DevNodeW", &a.LocateDevNode);
    Resolve(cm, "CM_Get_DevNode_PropertyW", &a.GetDevNodeProperty);
    return a;
  }();
  return api;
}

// DEVPKEY_Device_InstanceId / DEVPKEY_Device_PhysicalDeviceLocation, spelled
// out so no INITGUID / devpkey.h definition juggling is needed.
const DEVPROPKEY kInstanceIdKey = {{0x78c34fc8, 0x104a, 0x4aca, {0x9e, 0xa4, 0x52, 0x4d, 0x52, 0x99, 0x6e, 0x57}}, 256};
// MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING / MF_LOW_LATENCY (Win8+).
// Local copies: not every SDK's mfuuid.lib carries these two.
const GUID kAdvancedVideoProcessing = {0x0f81da2c, 0xb537, 0x4672, {0xa8, 0xb2, 0xa6, 0x81, 0xb1, 0x73, 0x07, 0xa3}};
const GUID kLowLatency = {0x9c27891a, 0xed7a, 0x40e1, {0x88, 0xe8, 0xb2, 0x27, 0x27, 0xa0, 0x24, 0xee}};
const DEVPROPKEY kLocationKey = {{0x540b947e, 0x8b40, 0x45bc, {0xa8, 0xa2, 0x6a, 0x0b, 0x89, 0x4c, 0xbd, 0xa2}}, 9};

// "front"/"back" from the ACPI _PLD panel of the camera (set on tablets and
// laptops with built-in cameras), "" when unknown.
std::string PanelFacing(const std::wstring& link) {
  const CmApi& cm = Cm();
  BYTE pld[64] = {};
  ULONG size = sizeof(pld);
  DEVPROPTYPE type = 0;
  bool found = cm.GetInterfaceProperty &&
               cm.GetInterfaceProperty(link.c_str(), &kLocationKey, &type, pld, &size, 0) == CR_SUCCESS;
  if (!found && cm.GetInterfaceProperty && cm.LocateDevNode && cm.GetDevNodeProperty) {
    // The location usually lives on the device node, not on the interface.
    wchar_t instance[512] = {};
    ULONG bytes = sizeof(instance);
    DEVINST node = 0;
    if (cm.GetInterfaceProperty(link.c_str(), &kInstanceIdKey, &type, reinterpret_cast<PBYTE>(instance), &bytes,
                                0) == CR_SUCCESS &&
        type == DEVPROP_TYPE_STRING && cm.LocateDevNode(&node, instance, CM_LOCATE_DEVNODE_NORMAL) == CR_SUCCESS) {
      size = sizeof(pld);
      found = cm.GetDevNodeProperty(node, &kLocationKey, &type, pld, &size, 0) == CR_SUCCESS;
    }
  }
  if (!found || type != DEVPROP_TYPE_BINARY || size < 9) return std::string();
  // _PLD bits 67..69 = panel: 4 front, 5 back (0..3 top/bottom/left/right).
  const int panel = (pld[8] >> 3) & 0x7;
  if (panel == 4) return "front";
  if (panel == 5) return "back";
  return std::string();
}

// ---------------------------------------------------------------------------
// Devices.

class Devices {
 public:
  Devices() = default;
  Devices(const Devices&) = delete;
  Devices& operator=(const Devices&) = delete;
  ~Devices() {
    for (UINT32 i = 0; i < count_; ++i) {
      if (list_[i]) list_[i]->Release();
    }
    CoTaskMemFree(list_);
  }

  // Needs COM + MFStartup on the calling thread.
  HRESULT Enumerate() {
    const MfApi& mf = Mf();
    if (!mf.ok) return E_NOTIMPL;
    Com<IMFAttributes> attrs;
    HRESULT hr = mf.CreateAttributes(attrs.Put(), 1);
    if (SUCCEEDED(hr)) hr = attrs->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    if (SUCCEEDED(hr)) hr = mf.EnumDeviceSources(attrs.Get(), &list_, &count_);
    if (FAILED(hr)) {
      list_ = nullptr;
      count_ = 0;
      return hr;
    }
    for (UINT32 i = 0; i < count_; ++i) {
      std::wstring symlink;
      WCHAR* text = nullptr;
      UINT32 length = 0;
      if (SUCCEEDED(list_[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &text,
                                                 &length))) {
        symlink.assign(text, length);
        CoTaskMemFree(text);
      }
      std::string side = symlink.empty() ? std::string() : PanelFacing(symlink);
      // No panel info (typical desktop webcam): first camera is "front".
      if (side.empty()) side = i == 0 ? "front" : "back";
      links_.push_back(symlink);
      facings_.push_back(side);
    }
    return S_OK;
  }

  UINT32 count() const { return count_; }
  IMFActivate* at(UINT32 i) const { return list_[i]; }
  const std::wstring& link(UINT32 i) const { return links_[i]; }
  const std::string& facing(UINT32 i) const { return facings_[i]; }

 private:
  IMFActivate** list_ = nullptr;
  UINT32 count_ = 0;
  std::vector<std::wstring> links_;
  std::vector<std::string> facings_;
};

// ---------------------------------------------------------------------------
// Session state shared by the control and capture threads.

struct Target {
  std::string facing = "front";
  UINT32 width = 1280;
  UINT32 height = 720;
  UINT32 fps = 30;
  bool next = false;   // switch: take the camera after `after`
  std::wstring after;  // symbolic link of the current camera
};

struct OpenResult {
  bool ok = false;
  std::string error = "failed";
  std::string facing = "front";
  int32_t cameras = 0;
  std::wstring link;
};

class Session {
 public:
  explicit Session(uint64_t session_id) : id(session_id) {}

  const uint64_t id;
  std::atomic<bool> stop{false};
  std::thread thread;

  // Capture thread: keep a reference so Abort() can unblock a stuck ReadSample.
  bool AttachSource(IMFMediaSource* source) {
    std::lock_guard<std::mutex> lock(mu_);
    if (aborted_) return false;
    ReleaseSourceLocked();
    source->AddRef();
    source_ = source;
    return true;
  }

  void ReleaseSource() {
    std::lock_guard<std::mutex> lock(mu_);
    ReleaseSourceLocked();
  }

  // Any thread. Shutting the source down makes a blocked ReadSample return
  // MF_E_SHUTDOWN; used only when a device stops delivering frames.
  void Abort() {
    stop.store(true);
    std::lock_guard<std::mutex> lock(mu_);
    aborted_ = true;
    if (source_) source_->Shutdown();
  }

  void Publish(const OpenResult& r) {
    std::lock_guard<std::mutex> lock(mu_);
    result_ = r;
    opened_ = true;
    cv_.notify_all();
  }

  void Partial(int32_t cameras, const std::string& facing) {
    std::lock_guard<std::mutex> lock(mu_);
    result_.cameras = cameras;
    result_.facing = facing;
  }

  void MarkDone() {
    std::lock_guard<std::mutex> lock(mu_);
    done_ = true;
    cv_.notify_all();
  }

  // Waits for Publish(); `cancel` (polled) ends the wait early.
  bool WaitOpened(milliseconds timeout, const std::atomic<bool>* cancel) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    std::unique_lock<std::mutex> lock(mu_);
    while (!opened_) {
      if (cancel && cancel->load()) return false;
      const auto now = std::chrono::steady_clock::now();
      if (now >= deadline) return false;
      cv_.wait_until(lock, (std::min)(deadline, now + milliseconds(50)));
    }
    return true;
  }

  bool WaitDone(milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mu_);
    return cv_.wait_for(lock, timeout, [this] { return done_; });
  }

  OpenResult result() {
    std::lock_guard<std::mutex> lock(mu_);
    OpenResult r = result_;
    if (!opened_) {
      r.ok = false;
      r.error = "failed";
    }
    return r;
  }

 private:
  void ReleaseSourceLocked() {
    if (source_) {
      source_->Shutdown();
      source_->Release();
      source_ = nullptr;
    }
  }

  std::mutex mu_;
  std::condition_variable cv_;
  IMFMediaSource* source_ = nullptr;
  bool aborted_ = false;
  bool opened_ = false;
  bool done_ = false;
  OpenResult result_;
};

// Implemented after State.
void Reply(int64_t call, EncodableValue value);
void EmitError(uint64_t session, const std::string& code, const std::string& message);

// ---------------------------------------------------------------------------
// Capture (runs on the capture thread).

std::string Describe(HRESULT hr) {
  char text[48];
  snprintf(text, sizeof(text), "Media Foundation error 0x%08lX", static_cast<unsigned long>(hr));
  return text;
}

bool IsGone(HRESULT hr) {
  return hr == MF_E_VIDEO_RECORDING_DEVICE_INVALIDATED || hr == HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED) ||
         hr == HRESULT_FROM_WIN32(ERROR_DEVICE_REMOVED) || hr == HRESULT_FROM_WIN32(ERROR_GEN_FAILURE) ||
         hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) || hr == MF_E_END_OF_STREAM;
}

// start error codes: permission | no_camera | busy | failed
std::string OpenError(HRESULT hr) {
  if (hr == E_ACCESSDENIED) return "permission";  // Settings > Privacy > Camera is off
  if (hr == MF_E_HW_MFT_FAILED_START_STREAMING || hr == MF_E_VIDEO_RECORDING_DEVICE_PREEMPTED ||
      hr == HRESULT_FROM_WIN32(ERROR_SHARING_VIOLATION) || hr == HRESULT_FROM_WIN32(ERROR_BUSY)) {
    return "busy";  // another app holds the camera exclusively
  }
  if (IsGone(hr)) return "no_camera";
  return "failed";
}

// onError codes: permission | disconnected | failed
std::string StreamError(HRESULT hr) {
  if (hr == E_ACCESSDENIED) return "permission";
  if (IsGone(hr)) return "disconnected";
  return "failed";
}

// Lower is better. Frame rate first (a 10 fps 720p YUY2 mode is worse than
// MJPG 720p30), then height near the target (never far above 1.5x), 16:9,
// and formats that need the least conversion.
double Score(UINT32 w, UINT32 h, double fps, const GUID& subtype, const Target& t) {
  double s = 0;
  const double want_fps = t.fps;
  if (fps + 0.5 < want_fps) {
    s += (want_fps - fps) * 1000;
  } else {
    s += (fps - want_fps) * 4;  // 60 fps only costs CPU, the encoder runs at ~30
  }
  const double want_h = t.height;
  const double max_h = want_h * 1.5;  // 720p target -> up to 1080p
  const double hh = h;
  if (hh < want_h) {
    s += (want_h - hh) * 8;
  } else if (hh <= max_h) {
    s += hh - want_h;
  } else {
    s += (max_h - want_h) + (hh - max_h) * 4;
  }
  if (static_cast<uint64_t>(w) * t.height != static_cast<uint64_t>(h) * t.width) s += 60;
  if (subtype == MFVideoFormat_NV12) {
    // already what we want
  } else if (subtype == MFVideoFormat_YUY2 || subtype == MFVideoFormat_I420 || subtype == MFVideoFormat_IYUV) {
    s += 25;
  } else if (subtype == MFVideoFormat_MJPG) {
    s += 40;
  } else {
    s += 120;  // H.264 / RGB / exotic: works through MFTs but costs more
  }
  return s;
}

HRESULT SetOutput(IMFSourceReader* reader, IMFMediaType* native, const GUID& subtype) {
  Com<IMFMediaType> out;
  HRESULT hr = Mf().CreateMediaType(out.Put());
  if (SUCCEEDED(hr)) hr = out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (SUCCEEDED(hr)) hr = out->SetGUID(MF_MT_SUBTYPE, subtype);
  // Same size and rate as the device mode: the processor converts colour
  // only, it never scales (the core downscales when it has to).
  UINT32 a = 0, b = 0;
  if (SUCCEEDED(hr) && native && SUCCEEDED(MFGetAttributeSize(native, MF_MT_FRAME_SIZE, &a, &b))) {
    hr = MFSetAttributeSize(out.Get(), MF_MT_FRAME_SIZE, a, b);
  }
  if (SUCCEEDED(hr) && native && SUCCEEDED(MFGetAttributeRatio(native, MF_MT_FRAME_RATE, &a, &b))) {
    hr = MFSetAttributeRatio(out.Get(), MF_MT_FRAME_RATE, a, b);
  }
  if (SUCCEEDED(hr)) hr = out->SetUINT32(MF_MT_INTERLACE_MODE, static_cast<UINT32>(MFVideoInterlace_Progressive));
  if (SUCCEEDED(hr)) hr = reader->SetCurrentMediaType(kVideoStream, nullptr, out.Get());
  return hr;
}

bool IsYuv420(IMFMediaType* type) {
  GUID subtype = {};
  if (FAILED(type->GetGUID(MF_MT_SUBTYPE, &subtype))) return false;
  return subtype == MFVideoFormat_NV12 || subtype == MFVideoFormat_I420 || subtype == MFVideoFormat_IYUV;
}

HRESULT ConfigureReader(IMFSourceReader* reader, const Target& t) {
  struct Candidate {
    double score;
    DWORD index;
  };
  std::vector<Candidate> modes;
  for (DWORD i = 0;; ++i) {
    Com<IMFMediaType> type;
    if (FAILED(reader->GetNativeMediaType(kVideoStream, i, type.Put()))) break;  // MF_E_NO_MORE_TYPES
    UINT32 w = 0, h = 0, num = 0, den = 0;
    GUID subtype = {};
    if (FAILED(MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &w, &h)) || w == 0 || h == 0) continue;
    MFGetAttributeRatio(type.Get(), MF_MT_FRAME_RATE, &num, &den);
    type->GetGUID(MF_MT_SUBTYPE, &subtype);
    const double fps = den ? static_cast<double>(num) / den : 0.0;
    modes.push_back({Score(w, h, fps, subtype, t), i});
  }
  std::stable_sort(modes.begin(), modes.end(),
                   [](const Candidate& x, const Candidate& y) { return x.score < y.score; });

  HRESULT hr = MF_E_INVALIDMEDIATYPE;
  // A few attempts cover modes no decoder/processor can turn into 4:2:0.
  for (size_t k = 0; k < modes.size() && k < 4; ++k) {
    Com<IMFMediaType> native;
    hr = reader->GetNativeMediaType(kVideoStream, modes[k].index, native.Put());
    if (SUCCEEDED(hr)) hr = reader->SetCurrentMediaType(kVideoStream, nullptr, native.Get());
    if (FAILED(hr)) {
      if (hr == E_ACCESSDENIED) return hr;
      continue;
    }
    // Device already gives 4:2:0: output = native, no converter in the path.
    if (IsYuv420(native.Get())) return S_OK;
    hr = SetOutput(reader, native.Get(), MFVideoFormat_NV12);
    if (FAILED(hr)) hr = SetOutput(reader, native.Get(), MFVideoFormat_I420);
    if (SUCCEEDED(hr)) return hr;
  }
  if (modes.empty()) {
    // Device lists no modes: keep its default, converting only if needed.
    Com<IMFMediaType> current;
    if (SUCCEEDED(reader->GetCurrentMediaType(kVideoStream, current.Put())) && IsYuv420(current.Get())) return S_OK;
    hr = SetOutput(reader, nullptr, MFVideoFormat_NV12);
  }
  return hr;
}

// Current output layout. NV12/I420 from MF are always top-down.
struct Format {
  UINT32 coded_h = 0;  // allocated rows: chroma starts after these
  UINT32 width = 0;    // visible, even
  UINT32 height = 0;
  UINT32 x = 0;  // visible origin (even)
  UINT32 y = 0;
  LONG stride = 0;  // fallback pitch for buffers without IMF2DBuffer
  bool nv12 = true;
  uint32_t flags = 0;  // rotation argument: 0 degrees, | 0x10000 when full range
};

HRESULT ReadFormat(IMFSourceReader* reader, Format* f) {
  Com<IMFMediaType> type;
  HRESULT hr = reader->GetCurrentMediaType(kVideoStream, type.Put());
  if (FAILED(hr)) return hr;
  GUID subtype = {};
  type->GetGUID(MF_MT_SUBTYPE, &subtype);
  if (subtype == MFVideoFormat_NV12) {
    f->nv12 = true;
  } else if (subtype == MFVideoFormat_I420 || subtype == MFVideoFormat_IYUV) {
    f->nv12 = false;
  } else {
    return MF_E_INVALIDMEDIATYPE;
  }
  // Most webcams deliver video range (16..235); MJPG decoded output may be
  // full range. 0x10000 = LUMORA_CAMERA_FULL_RANGE (the core maps it).
  f->flags = MFGetAttributeUINT32(type.Get(), MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235) == MFNominalRange_0_255
                 ? 0x10000u
                 : 0u;
  UINT32 w = 0, h = 0;
  hr = MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &w, &h);
  if (FAILED(hr) || w < 2 || h < 2) return MF_E_INVALIDMEDIATYPE;
  f->coded_h = h;
  f->x = 0;
  f->y = 0;
  f->width = w;
  f->height = h;
  // Decoders may pad (1920x1088) and describe the real picture here.
  MFVideoArea area = {};
  if (SUCCEEDED(type->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, reinterpret_cast<UINT8*>(&area), sizeof(area),
                              nullptr)) &&
      area.OffsetX.value >= 0 && area.OffsetY.value >= 0 && area.Area.cx > 1 && area.Area.cy > 1) {
    const UINT32 ox = static_cast<UINT32>(area.OffsetX.value) & ~1u;
    const UINT32 oy = static_cast<UINT32>(area.OffsetY.value) & ~1u;
    const UINT32 cx = static_cast<UINT32>(area.Area.cx);
    const UINT32 cy = static_cast<UINT32>(area.Area.cy);
    if (ox + cx <= w && oy + cy <= h) {
      f->x = ox;
      f->y = oy;
      f->width = cx;
      f->height = cy;
    }
  }
  f->width &= ~1u;
  f->height &= ~1u;
  UINT32 stride = 0;
  f->stride = SUCCEEDED(type->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride)) ? static_cast<LONG>(static_cast<INT32>(stride))
                                                                          : static_cast<LONG>(w);
  return S_OK;
}

void PushSample(IMFSample* sample, const Format& f, PushFn push) {
  Com<IMFMediaBuffer> buffer;
  DWORD count = 0;
  sample->GetBufferCount(&count);
  // One buffer is the norm; anything else is merged (a copy, but rare).
  const HRESULT hr = count == 1 ? sample->GetBufferByIndex(0, buffer.Put()) : sample->ConvertToContiguousBuffer(buffer.Put());
  if (FAILED(hr)) return;

  Com<IMF2DBuffer> buffer2d;
  BYTE* base = nullptr;
  LONG pitch = 0;
  bool locked2d = false;
  if (SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(buffer2d.Put()))) &&
      SUCCEEDED(buffer2d->Lock2D(&base, &pitch))) {
    locked2d = true;  // real pitch, no copy even for GPU-backed buffers
  } else {
    DWORD max_len = 0, len = 0;
    if (FAILED(buffer->Lock(&base, &max_len, &len))) return;
    pitch = f.stride;
    const uint64_t need = static_cast<uint64_t>(pitch > 0 ? pitch : 0) * f.coded_h * 3 / 2;
    if (pitch <= 0 || len < need) {
      buffer->Unlock();
      return;
    }
  }

  if (pitch > 0) {  // bottom-up never happens for 4:2:0; skip it if it does
    const uint32_t p = static_cast<uint32_t>(pitch);
    const uint8_t* y = base + static_cast<size_t>(f.y) * p + f.x;
    const uint8_t* chroma = base + static_cast<size_t>(f.coded_h) * p;
    if (f.nv12) {
      const uint8_t* uv = chroma + static_cast<size_t>(f.y / 2) * p + f.x;
      push(f.width, f.height, y, p, uv, p, uv + 1, p, 2, f.flags);
    } else {
      const uint32_t cp = p / 2;
      const uint8_t* u = chroma + static_cast<size_t>(f.y / 2) * cp + f.x / 2;
      const uint8_t* v = chroma + static_cast<size_t>(f.coded_h / 2) * cp + static_cast<size_t>(f.y / 2) * cp + f.x / 2;
      push(f.width, f.height, y, p, u, cp, v, cp, 1, f.flags);
    }
  }

  if (locked2d) {
    buffer2d->Unlock2D();
  } else {
    buffer->Unlock();
  }
}

// Opens one device and waits for its first frame: a privacy block or a busy
// camera often only shows up there, and start must report it.
HRESULT OpenDevice(Session* s, IMFActivate* device, const Target& t, PushFn push, IMFSourceReader** out,
                   Format* format) {
  *out = nullptr;
  const MfApi& mf = Mf();
  Com<IMFMediaSource> source;
  HRESULT hr = device->ActivateObject(IID_PPV_ARGS(source.Put()));
  if (FAILED(hr)) return hr;
  if (!s->AttachSource(source.Get())) {
    source->Shutdown();
    device->ShutdownObject();
    return MF_E_SHUTDOWN;
  }

  Com<IMFAttributes> attrs;
  Com<IMFSourceReader> reader;
  hr = mf.CreateAttributes(attrs.Put(), 2);
  // The plain ENABLE_VIDEO_PROCESSING only does YUV -> RGB32; the advanced
  // one adds the MJPG/YUY2 -> NV12 conversions webcams need.
  if (SUCCEEDED(hr)) hr = attrs->SetUINT32(kAdvancedVideoProcessing, TRUE);
  // Hand frames out as soon as they exist instead of buffering for playback.
  if (SUCCEEDED(hr)) attrs->SetUINT32(kLowLatency, TRUE);
  if (SUCCEEDED(hr)) hr = mf.CreateSourceReaderFromMediaSource(source.Get(), attrs.Get(), reader.Put());
  if (SUCCEEDED(hr)) hr = reader->SetStreamSelection(kAllStreams, FALSE);
  if (SUCCEEDED(hr)) hr = reader->SetStreamSelection(kVideoStream, TRUE);
  if (SUCCEEDED(hr)) hr = ConfigureReader(reader.Get(), t);
  if (SUCCEEDED(hr)) hr = ReadFormat(reader.Get(), format);

  bool got_frame = false;
  for (int i = 0; SUCCEEDED(hr) && !got_frame && i < 64; ++i) {
    DWORD index = 0, flags = 0;
    LONGLONG timestamp = 0;
    Com<IMFSample> sample;
    hr = reader->ReadSample(kVideoStream, 0, &index, &flags, &timestamp, sample.Put());
    if (FAILED(hr)) break;
    if (flags & MF_SOURCE_READERF_ERROR) {
      hr = E_FAIL;
    } else if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      hr = MF_E_END_OF_STREAM;
    } else if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
      hr = ReadFormat(reader.Get(), format);
    }
    if (SUCCEEDED(hr) && sample) {
      PushSample(sample.Get(), *format, push);
      got_frame = true;
    }
  }
  if (SUCCEEDED(hr) && !got_frame) hr = E_FAIL;

  if (FAILED(hr)) {
    reader.Reset();
    s->ReleaseSource();
    device->ShutdownObject();
    return hr;
  }
  *out = reader.Get();
  (*out)->AddRef();
  return S_OK;
}

void StreamLoop(Session* s, IMFSourceReader* reader, Format format, PushFn push) {
  while (!s->stop.load()) {
    DWORD index = 0, flags = 0;
    LONGLONG timestamp = 0;
    Com<IMFSample> sample;
    HRESULT hr = reader->ReadSample(kVideoStream, 0, &index, &flags, &timestamp, sample.Put());
    if (s->stop.load()) break;
    if (SUCCEEDED(hr) && (flags & MF_SOURCE_READERF_ERROR)) hr = E_FAIL;
    if (SUCCEEDED(hr) && (flags & MF_SOURCE_READERF_ENDOFSTREAM)) hr = MF_E_END_OF_STREAM;  // device went away
    if (SUCCEEDED(hr) && (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED)) hr = ReadFormat(reader, &format);
    if (FAILED(hr)) {
      EmitError(s->id, StreamError(hr), Describe(hr));
      return;
    }
    if (sample) PushSample(sample.Get(), format, push);  // null = stream tick (gap)
  }
}

void CaptureMain(std::shared_ptr<Session> s, Target t, PushFn push) {
  const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const MfApi& mf = Mf();
  const HRESULT up = mf.ok ? mf.Startup(MF_VERSION, MFSTARTUP_LITE) : E_NOTIMPL;
  {
    Devices devices;
    Com<IMFSourceReader> reader;
    Format format;
    OpenResult r;
    r.facing = t.facing;
    HRESULT hr = SUCCEEDED(up) ? devices.Enumerate() : up;
    const UINT32 n = SUCCEEDED(hr) ? devices.count() : 0;
    r.cameras = static_cast<int32_t>(n);
    if (FAILED(hr)) {
      r.error = "failed";
    } else if (n == 0) {
      r.error = "no_camera";
    } else {
      // Try order: switch -> the cameras after the current one, ending with
      // the current one as a fallback; start -> matching facing first.
      std::vector<UINT32> order;
      if (t.next) {
        UINT32 start = 0;
        for (UINT32 i = 0; i < n; ++i) {
          if (!t.after.empty() && devices.link(i) == t.after) start = i + 1;
        }
        for (UINT32 k = 0; k < n; ++k) order.push_back((start + k) % n);
      } else {
        for (UINT32 i = 0; i < n; ++i) {
          if (devices.facing(i) == t.facing) order.push_back(i);
        }
        for (UINT32 i = 0; i < n; ++i) {
          if (devices.facing(i) != t.facing) order.push_back(i);
        }
      }
      for (UINT32 i : order) {
        if (s->stop.load()) break;
        r.facing = devices.facing(i);
        s->Partial(r.cameras, r.facing);
        hr = OpenDevice(s.get(), devices.at(i), t, push, reader.Put(), &format);
        if (SUCCEEDED(hr)) {
          r.ok = true;
          r.error.clear();
          r.link = devices.link(i);
          break;
        }
        r.error = OpenError(hr);
        if (r.error == "permission") break;  // same answer for every camera
      }
    }
    s->Publish(r);
    if (r.ok) StreamLoop(s.get(), reader.Get(), format, push);
    reader.Reset();      // stops streaming
    s->ReleaseSource();  // device closed: camera light off
  }
  if (SUCCEEDED(up)) mf.Shutdown();
  if (SUCCEEDED(co)) CoUninitialize();
  s->MarkDone();
}

// ---------------------------------------------------------------------------
// Control thread.

EncodableValue StatusMap(const std::string& facing, int32_t cameras) {
  return EncodableValue(EncodableMap{{EncodableValue("facing"), EncodableValue(facing)},
                                     {EncodableValue("cameras"), EncodableValue(cameras)}});
}

EncodableValue StartMap(bool ok, const std::string& error, const std::string& facing, int32_t cameras) {
  EncodableMap map{{EncodableValue("ok"), EncodableValue(ok)},
                   {EncodableValue("facing"), EncodableValue(facing)},
                   {EncodableValue("cameras"), EncodableValue(cameras)}};
  if (!ok) map[EncodableValue("error")] = EncodableValue(error);
  return EncodableValue(map);
}

class Controller {
 public:
  explicit Controller(std::atomic<uint64_t>* active) : active_(active), thread_(&Controller::Run, this) {}
  Controller(const Controller&) = delete;
  Controller& operator=(const Controller&) = delete;

  // Platform thread. Ends any capture; bounded by the Retire() timeouts.
  ~Controller() {
    {
      std::lock_guard<std::mutex> lock(mu_);
      quit_ = true;
    }
    quitting_.store(true);
    cv_.notify_all();
    if (thread_.joinable()) thread_.join();
  }

  void Enqueue(std::function<void()> task) {
    std::lock_guard<std::mutex> lock(mu_);
    tasks_.push_back(std::move(task));
    cv_.notify_one();
  }

  // The methods below run on the control thread (via Enqueue).

  void Supported(int64_t call) {
    Devices devices;
    const bool any = SUCCEEDED(devices.Enumerate()) && devices.count() > 0;
    Reply(call, EncodableValue(any));
  }

  void Start(int64_t call, const Target& t, PushFn push) {
    push_ = push;
    target_ = t;
    Retire();
    const OpenResult r = Launch(t);
    Reply(call, StartMap(r.ok, r.error, r.facing, r.cameras));
  }

  void Stop(int64_t call) {
    Retire();
    Reply(call, EncodableValue());
  }

  void Switch(int64_t call) {
    Devices devices;
    const UINT32 n = SUCCEEDED(devices.Enumerate()) ? devices.count() : 0;
    const int32_t cameras = static_cast<int32_t>(n);
    if (!session_ || n <= 1 || !push_) {
      // Idle or a single camera: nothing to switch to.
      const std::string facing = session_ ? facing_ : (n > 0 ? devices.facing(0) : std::string("front"));
      Reply(call, StatusMap(facing, cameras));
      return;
    }
    Target t = target_;
    t.next = true;
    t.after = link_;
    const std::string previous = facing_;
    Retire();
    const OpenResult r = Launch(t);
    if (r.ok) {
      Reply(call, StatusMap(r.facing, r.cameras));
    } else {
      // Every camera (including the old one) failed: the call has no video.
      Reply(call, StatusMap(previous, cameras));
      EmitError(0, r.error == "permission" ? "permission" : "failed", "camera switch failed: " + r.error);
    }
  }

 private:
  void Run() {
    const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const MfApi& mf = Mf();
    const HRESULT up = mf.ok ? mf.Startup(MF_VERSION, MFSTARTUP_LITE) : E_NOTIMPL;
    for (;;) {
      std::function<void()> task;
      {
        std::unique_lock<std::mutex> lock(mu_);
        cv_.wait(lock, [this] { return quit_ || !tasks_.empty(); });
        if (quit_) break;  // leftover calls are answered by Shutdown()
        task = std::move(tasks_.front());
        tasks_.pop_front();
      }
      task();
    }
    Retire();
    if (SUCCEEDED(up)) mf.Shutdown();
    if (SUCCEEDED(co)) CoUninitialize();
  }

  // Starts a capture thread and waits until it streams (or gives up).
  OpenResult Launch(const Target& t) {
    auto s = std::make_shared<Session>(++next_session_);
    active_->store(s->id);
    s->thread = std::thread(CaptureMain, s, t, push_);
    // Open + first frame normally takes well under 2 s; a camera that never
    // delivers is shut down so start can answer "failed" instead of hanging.
    if (!s->WaitOpened(milliseconds(10000), &quitting_)) {
      s->Abort();
      s->WaitOpened(milliseconds(3000), nullptr);
    }
    OpenResult r = s->result();
    if (r.ok && !quitting_.load()) {
      session_ = s;
      facing_ = r.facing;
      link_ = r.link;
    } else {
      r.ok = false;
      Join(s);
    }
    return r;
  }

  void Retire() {
    if (!session_) return;
    std::shared_ptr<Session> s = std::move(session_);
    session_.reset();
    Join(s);
  }

  void Join(const std::shared_ptr<Session>& s) {
    uint64_t expected = s->id;
    active_->compare_exchange_strong(expected, 0);  // silence its late errors
    s->stop.store(true);
    // ReadSample returns within a frame; a wedged driver gets its source shut
    // down, and as a last resort the thread is left behind (it owns `s`).
    if (!s->WaitDone(milliseconds(1500))) {
      s->Abort();
      if (!s->WaitDone(milliseconds(3000))) {
        s->thread.detach();
        return;
      }
    }
    s->thread.join();
  }

  std::atomic<uint64_t>* active_;
  std::mutex mu_;
  std::condition_variable cv_;
  std::deque<std::function<void()>> tasks_;
  bool quit_ = false;
  std::atomic<bool> quitting_{false};

  // Control thread only.
  std::shared_ptr<Session> session_;
  Target target_;
  PushFn push_ = nullptr;
  std::string facing_ = "front";
  std::wstring link_;
  uint64_t next_session_ = 0;

  std::thread thread_;  // last: starts after everything above exists
};

// ---------------------------------------------------------------------------
// Platform-thread bridge.

LRESULT CALLBACK BridgeProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

class Bridge {
 public:
  bool Create() {
    if (hwnd_) return true;
    static const wchar_t kClass[] = L"LumoraCameraBridge";
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = BridgeProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kClass;
    RegisterClassExW(&wc);  // ERROR_CLASS_ALREADY_EXISTS on re-register is fine
    // Message-only: invisible, no taskbar entry, receives PostMessage.
    const HWND hwnd = CreateWindowExW(0, kClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, wc.hInstance, nullptr);
    std::lock_guard<std::mutex> lock(mu_);
    hwnd_ = hwnd;
    return hwnd != nullptr;
  }

  void Destroy() {
    HWND hwnd = nullptr;
    std::deque<std::function<void()>> dropped;
    {
      std::lock_guard<std::mutex> lock(mu_);
      hwnd = hwnd_;
      hwnd_ = nullptr;
      posted_ = false;
      dropped.swap(tasks_);
    }
    if (hwnd) DestroyWindow(hwnd);
  }

  bool ok() const { return hwnd_ != nullptr; }  // platform thread only

  // Any thread. Dropped after Destroy().
  void Post(std::function<void()> task) {
    std::lock_guard<std::mutex> lock(mu_);
    if (!hwnd_) return;
    tasks_.push_back(std::move(task));
    // One wake-up per batch; retried on the next Post if the queue was full.
    if (!posted_) posted_ = PostMessageW(hwnd_, kRunTasks, 0, 0) != FALSE;
  }

  void Drain() {
    std::deque<std::function<void()>> batch;
    {
      std::lock_guard<std::mutex> lock(mu_);
      batch.swap(tasks_);
      posted_ = false;
    }
    for (auto& task : batch) task();
  }

 private:
  std::mutex mu_;
  HWND hwnd_ = nullptr;
  bool posted_ = false;
  std::deque<std::function<void()>> tasks_;
};

struct State {
  Bridge bridge;
  std::unique_ptr<Channel> channel;
  std::map<int64_t, std::unique_ptr<Result>> pending;  // platform thread only
  int64_t next_call = 1;
  std::atomic<uint64_t> active{0};  // the session allowed to send onError
  std::unique_ptr<Controller> controller;
};

// Never freed: worker threads may still Post() during process teardown.
State* g_state = nullptr;

LRESULT CALLBACK BridgeProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kRunTasks) {
    if (g_state) g_state->bridge.Drain();
    return 0;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

void Reply(int64_t call, EncodableValue value) {
  g_state->bridge.Post([call, value]() {
    auto& pending = g_state->pending;
    const auto it = pending.find(call);
    if (it == pending.end()) return;
    std::unique_ptr<Result> result = std::move(it->second);
    pending.erase(it);
    result->Success(value);
  });
}

// `session` 0 = always deliver; otherwise only while that session is current,
// so a stopped or replaced camera cannot raise a stale error.
void EmitError(uint64_t session, const std::string& code, const std::string& message) {
  g_state->bridge.Post([session, code, message]() {
    State& st = *g_state;
    if (!st.channel || (session != 0 && st.active.load() != session)) return;
    st.channel->InvokeMethod("onError", std::make_unique<EncodableValue>(EncodableMap{
                                            {EncodableValue("code"), EncodableValue(code)},
                                            {EncodableValue("message"), EncodableValue(message)},
                                        }));
  });
}

// ---------------------------------------------------------------------------
// Method handling (platform thread).

const EncodableValue* Arg(const EncodableMap* args, const char* key) {
  if (!args) return nullptr;
  const auto it = args->find(EncodableValue(key));
  return it == args->end() ? nullptr : &it->second;
}

int64_t ArgInt(const EncodableMap* args, const char* key, int64_t fallback, int64_t lo, int64_t hi) {
  const EncodableValue* v = Arg(args, key);
  int64_t n = fallback;
  if (const auto* i32 = v ? std::get_if<int32_t>(v) : nullptr) {
    n = *i32;
  } else if (const auto* i64 = v ? std::get_if<int64_t>(v) : nullptr) {
    n = *i64;
  }
  return n < lo || n > hi ? fallback : n;
}

std::string ArgString(const EncodableMap* args, const char* key) {
  const EncodableValue* v = Arg(args, key);
  const auto* s = v ? std::get_if<std::string>(v) : nullptr;
  return s ? *s : std::string();
}

bool RegistryDenies(HKEY root, const wchar_t* path) {
  wchar_t value[32] = {};
  DWORD size = sizeof(value);
  if (RegGetValueW(root, path, L"Value", RRF_RT_REG_SZ, nullptr, value, &size) != ERROR_SUCCESS) return false;
  return CompareStringOrdinal(value, -1, L"Deny", -1, TRUE) == CSTR_EQUAL;
}

// Windows has no prompt, only the Settings > Privacy > Camera switches:
// device-wide (HKLM), all apps (HKCU) and desktop apps (NonPackaged).
// When one is off the user must flip it there, hence "blocked".
std::string PermissionState() {
  static const wchar_t kStore[] =
      L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\webcam";
  static const wchar_t kDesktop[] =
      L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\webcam\\NonPackaged";
  if (RegistryDenies(HKEY_LOCAL_MACHINE, kStore) || RegistryDenies(HKEY_CURRENT_USER, kStore) ||
      RegistryDenies(HKEY_CURRENT_USER, kDesktop)) {
    return "blocked";
  }
  return "granted";
}

PushFn ResolvePush(const std::string& lib) {
  // Dart has already loaded lumora_ffi.dll from the exe directory.
  HMODULE module = GetModuleHandleW(L"lumora_ffi.dll");
  if (!module && !lib.empty()) module = LoadLibraryW(lumora_media::Utf8ToWide(lib).c_str());
  PushFn push = nullptr;
  Resolve(module, "lumora_push_camera_yuv", &push);  // missing: core built without media
  return push;
}

void HandleCall(const flutter::MethodCall<EncodableValue>& call, std::unique_ptr<Result> result) {
  State& st = *g_state;
  const std::string& method = call.method_name();
  const auto* args = std::get_if<EncodableMap>(call.arguments());

  if (method == "permission" || method == "request") {
    result->Success(EncodableValue(PermissionState()));
    return;
  }
  if (method == "openSettings") {
    const HINSTANCE h =
        ShellExecuteW(nullptr, L"open", L"ms-settings:privacy-webcam", nullptr, nullptr, SW_SHOWNORMAL);
    result->Success(EncodableValue(reinterpret_cast<INT_PTR>(h) > 32));
    return;
  }
  if (method != "supported" && method != "start" && method != "stop" && method != "switch") {
    result->NotImplemented();
    return;
  }
  if (method == "stop" && !st.controller) {
    result->Success();  // never started: nothing to release
    return;
  }

  Target target;
  PushFn push = nullptr;
  if (method == "start") {
    target.facing = ArgString(args, "facing") == "back" ? "back" : "front";
    target.width = static_cast<UINT32>(ArgInt(args, "width", 1280, 16, 7680));
    target.height = static_cast<UINT32>(ArgInt(args, "height", 720, 16, 4320));
    target.fps = static_cast<UINT32>(ArgInt(args, "fps", 30, 1, 240));
    push = ResolvePush(ArgString(args, "lib"));
    if (!push || !Mf().ok || !st.bridge.ok()) {
      result->Success(StartMap(false, "failed", target.facing, 0));
      return;
    }
  }
  if (!st.bridge.ok()) {
    if (method == "supported") {
      result->Success(EncodableValue(false));
    } else if (method == "switch") {
      result->Success(StatusMap("front", 0));
    } else {
      result->Success();
    }
    return;
  }

  if (!st.controller) st.controller = std::make_unique<Controller>(&st.active);
  const int64_t id = st.next_call++;
  st.pending.emplace(id, std::move(result));
  Controller* c = st.controller.get();
  if (method == "supported") {
    c->Enqueue([c, id] { c->Supported(id); });
  } else if (method == "start") {
    c->Enqueue([c, id, target, push] { c->Start(id, target, push); });
  } else if (method == "stop") {
    c->Enqueue([c, id] { c->Stop(id); });
  } else {
    c->Enqueue([c, id] { c->Switch(id); });
  }
}

}  // namespace

void RegisterChannel(flutter::BinaryMessenger* messenger) {
  if (!g_state) g_state = new State();
  State& st = *g_state;
  st.bridge.Create();
  st.channel = std::make_unique<Channel>(messenger, "lumora/camera", &flutter::StandardMethodCodec::GetInstance());
  st.channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call, std::unique_ptr<Result> result) {
        HandleCall(call, std::move(result));
      });
}

void Shutdown() {
  if (!g_state) return;
  State& st = *g_state;
  st.controller.reset();  // joins the control + capture threads: camera off
  st.active.store(0);
  st.bridge.Destroy();    // late worker posts are dropped from here on
  // Answer what is still in flight while the engine can take it.
  std::map<int64_t, std::unique_ptr<Result>> pending;
  pending.swap(st.pending);
  for (auto& entry : pending) entry.second->Error("failed", "window closed");
  if (st.channel) st.channel->SetMethodCallHandler(nullptr);
  st.channel.reset();
}

}  // namespace lumora_camera

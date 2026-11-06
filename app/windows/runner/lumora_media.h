// `lumora/media.heicToJpeg` for Windows: decodes HEIC/HEIF (iPhone photos)
// with WIC, which works when the system has Microsoft's "HEIF Image
// Extensions" (+ "HEVC Video Extensions") installed. Otherwise the call
// returns null and the Dart side shows its friendly fallback with
// "Mở bằng ứng dụng khác". Output: JPEG q0.92, orientation applied, no
// metadata copied (no GPS).
#ifndef RUNNER_LUMORA_MEDIA_H_
#define RUNNER_LUMORA_MEDIA_H_

#include <windows.h>
#include <propidl.h>
#include <shlwapi.h>
#include <wincodec.h>

#include <cstdint>
#include <string>
#include <vector>

#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "ole32.lib")

namespace lumora_media {

// Minimal COM smart pointer (keeps the runner free of WRL/ATL).
template <class T>
class Com {
 public:
  Com() = default;
  ~Com() { Reset(); }
  Com(const Com&) = delete;
  Com& operator=(const Com&) = delete;
  T** Put() {
    Reset();
    return &p_;
  }
  T* Get() const { return p_; }
  T* operator->() const { return p_; }
  explicit operator bool() const { return p_ != nullptr; }
  void Reset() {
    if (p_) p_->Release();
    p_ = nullptr;
  }

 private:
  T* p_ = nullptr;
};

inline std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &w[0], n);
  return w;
}

// EXIF-style orientation (1..8) → WIC transform.
inline WICBitmapTransformOptions TransformFor(int orientation) {
  switch (orientation) {
    case 2: return WICBitmapTransformFlipHorizontal;
    case 3: return WICBitmapTransformRotate180;
    case 4: return WICBitmapTransformFlipVertical;
    case 5: return static_cast<WICBitmapTransformOptions>(WICBitmapTransformRotate90 | WICBitmapTransformFlipHorizontal);
    case 6: return WICBitmapTransformRotate90;
    case 7: return static_cast<WICBitmapTransformOptions>(WICBitmapTransformRotate270 | WICBitmapTransformFlipHorizontal);
    case 8: return WICBitmapTransformRotate270;
    default: return WICBitmapTransformRotate0;
  }
}

// Decodes any WIC-readable image file to JPEG. Returns false when no codec
// is installed for it (e.g. HEIF without the Store extension). Slow (a 12 MP
// HEIC takes ~0.5 s): call it from a worker thread, never the platform thread.
// Initialises COM on the calling thread for the duration of the call.
inline bool DecodeToJpeg(const std::wstring& path, int max_side, std::vector<uint8_t>* out) {
  const HRESULT co = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  bool ok = false;
  do {
    Com<IWICImagingFactory> factory;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_IWICImagingFactory,
                                reinterpret_cast<void**>(factory.Put())))) break;
    Com<IWICBitmapDecoder> decoder;
    if (FAILED(factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand,
                                                  decoder.Put()))) break;
    Com<IWICBitmapFrameDecode> frame;
    if (FAILED(decoder->GetFrame(0, frame.Put()))) break;

    IWICBitmapSource* source = frame.Get();

    // Orientation (System.Photo.Orientation covers JPEG EXIF and HEIF).
    int orientation = 1;
    Com<IWICMetadataQueryReader> query;
    if (SUCCEEDED(frame->GetMetadataQueryReader(query.Put())) && query) {
      PROPVARIANT v;
      PropVariantInit(&v);
      if (SUCCEEDED(query->GetMetadataByName(L"System.Photo.Orientation", &v)) && v.vt == VT_UI2) orientation = v.uiVal;
      PropVariantClear(&v);
    }
    Com<IWICBitmapFlipRotator> rotator;
    if (orientation > 1 && orientation <= 8 && SUCCEEDED(factory->CreateBitmapFlipRotator(rotator.Put())) &&
        SUCCEEDED(rotator->Initialize(source, TransformFor(orientation)))) {
      source = rotator.Get();
    }

    UINT w = 0, h = 0;
    if (FAILED(source->GetSize(&w, &h)) || w == 0 || h == 0) break;
    Com<IWICBitmapScaler> scaler;
    const UINT long_side = w > h ? w : h;
    if (max_side > 0 && long_side > static_cast<UINT>(max_side) && SUCCEEDED(factory->CreateBitmapScaler(scaler.Put()))) {
      const double s = static_cast<double>(max_side) / long_side;
      const UINT nw = static_cast<UINT>(w * s + 0.5) > 0 ? static_cast<UINT>(w * s + 0.5) : 1;
      const UINT nh = static_cast<UINT>(h * s + 0.5) > 0 ? static_cast<UINT>(h * s + 0.5) : 1;
      if (SUCCEEDED(scaler->Initialize(source, nw, nh, WICBitmapInterpolationModeFant))) {
        source = scaler.Get();
        w = nw;
        h = nh;
      }
    }

    Com<IWICFormatConverter> converter;
    if (FAILED(factory->CreateFormatConverter(converter.Put()))) break;
    if (FAILED(converter->Initialize(source, GUID_WICPixelFormat24bppBGR, WICBitmapDitherTypeNone, nullptr, 0.0,
                                     WICBitmapPaletteTypeCustom))) break;

    Com<IStream> stream;
    *stream.Put() = SHCreateMemStream(nullptr, 0);
    if (!stream) break;
    Com<IWICBitmapEncoder> encoder;
    if (FAILED(factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, encoder.Put()))) break;
    if (FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache))) break;
    Com<IWICBitmapFrameEncode> frame_out;
    Com<IPropertyBag2> props;
    if (FAILED(encoder->CreateNewFrame(frame_out.Put(), props.Put()))) break;
    if (props) {
      PROPBAG2 option = {};
      option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
      VARIANT q;
      VariantInit(&q);
      q.vt = VT_R4;
      q.fltVal = 0.92f;
      props->Write(1, &option, &q);
    }
    if (FAILED(frame_out->Initialize(props.Get()))) break;
    if (FAILED(frame_out->SetSize(w, h))) break;
    WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
    if (FAILED(frame_out->SetPixelFormat(&format))) break;
    if (FAILED(frame_out->WriteSource(converter.Get(), nullptr))) break;
    if (FAILED(frame_out->Commit()) || FAILED(encoder->Commit())) break;

    STATSTG stat = {};
    if (FAILED(stream->Stat(&stat, STATFLAG_NONAME))) break;
    const LARGE_INTEGER zero = {};
    if (FAILED(stream->Seek(zero, STREAM_SEEK_SET, nullptr))) break;
    out->resize(static_cast<size_t>(stat.cbSize.QuadPart));
    ULONG read = 0;
    if (FAILED(stream->Read(out->data(), static_cast<ULONG>(out->size()), &read)) || read != out->size()) break;
    ok = !out->empty();
  } while (false);
  if (SUCCEEDED(co)) CoUninitialize();
  return ok;
}

}  // namespace lumora_media

#ifndef LUMORA_MEDIA_NO_FLUTTER
namespace flutter {
class BinaryMessenger;
}

namespace lumora_media {

// Registers the `lumora/media` channel (lumora_media.cpp). Call once on the
// platform thread after RegisterPlugins(). Decoding runs on a worker thread;
// replies come back through |window|'s message queue (HandleWindowMessage).
void RegisterChannel(flutter::BinaryMessenger* messenger, HWND window);

// FlutterWindow::MessageHandler: answers finished decodes. True if |message|
// was ours.
bool HandleWindowMessage(UINT message, WPARAM wparam, LPARAM lparam);

// Answers pending calls and drops the channel while the engine is still alive
// (FlutterWindow::OnDestroy). A decode in progress finishes in the background
// and is discarded.
void Shutdown();

}  // namespace lumora_media
#endif  // LUMORA_MEDIA_NO_FLUTTER

#endif  // RUNNER_LUMORA_MEDIA_H_

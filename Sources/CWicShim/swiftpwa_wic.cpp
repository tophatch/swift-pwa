#include "swiftpwa_wic.h"

#ifdef _WIN32

// windows.h defines min/max as macros, which collide with std::max below and
// fail with a bewildering "expected unqualified-id" pointing at minwindef.h.
#define NOMINMAX

#include <windows.h>
#include <wincodec.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

// COM is initialised per call rather than once: these run on whatever thread
// the bridge's cooperative pool picks, not the UI thread that already
// initialised an apartment. RPC_E_CHANGED_MODE means someone got there first
// with a different model, which is fine to work under — we just must not
// balance it with an uninitialise we didn't earn.
struct ComScope {
    bool owned = false;

    ComScope() {
        HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        owned = SUCCEEDED(hr);
    }

    ~ComScope() {
        if (owned) CoUninitialize();
    }
};

template <typename T>
void release(T *&ptr) {
    if (ptr) {
        ptr->Release();
        ptr = nullptr;
    }
}

IWICImagingFactory *make_factory() {
    IWICImagingFactory *factory = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&factory));
    return SUCCEEDED(hr) ? factory : nullptr;
}

std::string narrow(const WCHAR *wide) {
    if (!wide) return {};
    int needed = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
    if (needed <= 1) return {};
    std::string out(static_cast<size_t>(needed - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, out.data(), needed, nullptr, nullptr);
    return out;
}

unsigned char *decode_rgb_impl(const unsigned char *data, int len, int max_side,
                               int *out_w, int *out_h, int *out_len) {
    if (!data || len <= 0 || !out_w || !out_h || !out_len) return nullptr;

    ComScope com;
    IWICImagingFactory *factory = make_factory();
    if (!factory) return nullptr;

    IWICStream *stream = nullptr;
    IWICBitmapDecoder *decoder = nullptr;
    IWICBitmapFrameDecode *frame = nullptr;
    IWICBitmapScaler *scaler = nullptr;
    IWICFormatConverter *converter = nullptr;
    unsigned char *result = nullptr;

    do {
        if (FAILED(factory->CreateStream(&stream))) break;
        if (FAILED(stream->InitializeFromMemory(const_cast<BYTE *>(data),
                                                static_cast<DWORD>(len))))
            break;
        // A machine with no decoder for this container fails here, which is the
        // "no HEVC extension installed" case and must read as an ordinary
        // failure rather than a crash.
        if (FAILED(factory->CreateDecoderFromStream(
                stream, nullptr, WICDecodeMetadataCacheOnLoad, &decoder)))
            break;
        if (FAILED(decoder->GetFrame(0, &frame))) break;

        UINT width = 0, height = 0;
        if (FAILED(frame->GetSize(&width, &height)) || width == 0 || height == 0) break;

        IWICBitmapSource *source = frame;
        if (max_side > 0) {
            UINT longest = std::max(width, height);
            if (longest > static_cast<UINT>(max_side)) {
                double scale = static_cast<double>(max_side) / static_cast<double>(longest);
                UINT target_w = std::max<UINT>(1, static_cast<UINT>(width * scale + 0.5));
                UINT target_h = std::max<UINT>(1, static_cast<UINT>(height * scale + 0.5));
                if (FAILED(factory->CreateBitmapScaler(&scaler))) break;
                if (FAILED(scaler->Initialize(frame, target_w, target_h,
                                              WICBitmapInterpolationModeFant)))
                    break;
                source = scaler;
                width = target_w;
                height = target_h;
            }
        }

        // Normalise whatever the file was (paletted, CMYK, 10-bit HDR HEIF, …)
        // to the packed RGB the rest of the package speaks.
        if (FAILED(factory->CreateFormatConverter(&converter))) break;
        if (FAILED(converter->Initialize(source, GUID_WICPixelFormat24bppRGB,
                                         WICBitmapDitherTypeNone, nullptr, 0.0,
                                         WICBitmapPaletteTypeCustom)))
            break;

        const UINT stride = width * 3;
        const size_t total = static_cast<size_t>(stride) * height;
        if (total == 0 || total > static_cast<size_t>(INT_MAX)) break;

        auto *buffer = static_cast<unsigned char *>(std::malloc(total));
        if (!buffer) break;
        if (FAILED(converter->CopyPixels(nullptr, stride,
                                         static_cast<UINT>(total), buffer))) {
            std::free(buffer);
            break;
        }

        *out_w = static_cast<int>(width);
        *out_h = static_cast<int>(height);
        *out_len = static_cast<int>(total);
        result = buffer;
    } while (false);

    release(converter);
    release(scaler);
    release(frame);
    release(decoder);
    release(stream);
    release(factory);
    return result;
}

unsigned char *encode_rgb_impl(const unsigned char *pixels, int width, int height,
                               int is_jpeg, int quality, int *out_len) {
    if (!pixels || width <= 0 || height <= 0 || !out_len) return nullptr;

    ComScope com;
    IWICImagingFactory *factory = make_factory();
    if (!factory) return nullptr;

    IStream *stream = nullptr;
    IWICBitmapEncoder *encoder = nullptr;
    IWICBitmapFrameEncode *frame = nullptr;
    IPropertyBag2 *props = nullptr;
    unsigned char *result = nullptr;

    do {
        if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) break;
        const GUID &container = is_jpeg ? GUID_ContainerFormatJpeg : GUID_ContainerFormatPng;
        if (FAILED(factory->CreateEncoder(container, nullptr, &encoder))) break;
        if (FAILED(encoder->Initialize(stream, WICBitmapEncoderNoCache))) break;
        if (FAILED(encoder->CreateNewFrame(&frame, &props))) break;

        if (is_jpeg && props) {
            PROPBAG2 option = {};
            option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
            VARIANT value;
            VariantInit(&value);
            value.vt = VT_R4;
            int clamped = quality < 1 ? 1 : (quality > 100 ? 100 : quality);
            value.fltVal = static_cast<float>(clamped) / 100.0f;
            props->Write(1, &option, &value);
            VariantClear(&value);
        }
        if (FAILED(frame->Initialize(props))) break;
        if (FAILED(frame->SetSize(static_cast<UINT>(width), static_cast<UINT>(height)))) break;

        WICPixelFormatGUID format = GUID_WICPixelFormat24bppRGB;
        if (FAILED(frame->SetPixelFormat(&format))) break;

        const UINT stride = static_cast<UINT>(width) * 3;
        const UINT total = stride * static_cast<UINT>(height);
        if (FAILED(frame->WritePixels(static_cast<UINT>(height), stride, total,
                                      const_cast<BYTE *>(pixels))))
            break;
        if (FAILED(frame->Commit())) break;
        if (FAILED(encoder->Commit())) break;

        HGLOBAL handle = nullptr;
        if (FAILED(GetHGlobalFromStream(stream, &handle)) || !handle) break;
        SIZE_T size = GlobalSize(handle);
        if (size == 0 || size > static_cast<SIZE_T>(INT_MAX)) break;
        void *locked = GlobalLock(handle);
        if (!locked) break;
        auto *buffer = static_cast<unsigned char *>(std::malloc(size));
        if (buffer) {
            std::memcpy(buffer, locked, size);
            *out_len = static_cast<int>(size);
            result = buffer;
        }
        GlobalUnlock(handle);
    } while (false);

    release(props);
    release(frame);
    release(encoder);
    release(stream);
    release(factory);
    return result;
}

int decode_extensions_impl(char *buf, int buf_len) {
    if (!buf || buf_len <= 0) return 0;

    ComScope com;
    IWICImagingFactory *factory = make_factory();
    if (!factory) return 0;

    IEnumUnknown *enumerator = nullptr;
    std::vector<std::string> extensions;

    if (SUCCEEDED(factory->CreateComponentEnumerator(
            WICDecoder, WICComponentEnumerateDefault, &enumerator))) {
        IUnknown *element = nullptr;
        ULONG fetched = 0;
        while (enumerator->Next(1, &element, &fetched) == S_OK && fetched == 1) {
            IWICBitmapDecoderInfo *info = nullptr;
            if (SUCCEEDED(element->QueryInterface(IID_PPV_ARGS(&info)))) {
                UINT needed = 0;
                info->GetFileExtensions(0, nullptr, &needed);
                if (needed > 0) {
                    std::vector<WCHAR> wide(needed);
                    UINT written = 0;
                    if (SUCCEEDED(info->GetFileExtensions(needed, wide.data(), &written))) {
                        // WIC hands back ".png,.jpg" — split, drop the dot,
                        // lowercase, so the list matches the extension spelling
                        // the rest of the package uses.
                        std::string all = narrow(wide.data());
                        size_t start = 0;
                        while (start <= all.size()) {
                            size_t comma = all.find(',', start);
                            std::string one = all.substr(
                                start, comma == std::string::npos ? std::string::npos : comma - start);
                            if (!one.empty() && one[0] == '.') one.erase(0, 1);
                            std::transform(one.begin(), one.end(), one.begin(),
                                           [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
                            if (!one.empty() &&
                                std::find(extensions.begin(), extensions.end(), one) == extensions.end()) {
                                extensions.push_back(one);
                            }
                            if (comma == std::string::npos) break;
                            start = comma + 1;
                        }
                    }
                }
                release(info);
            }
            release(element);
            fetched = 0;
        }
        release(enumerator);
    }
    release(factory);

    std::sort(extensions.begin(), extensions.end());
    std::string joined;
    for (const auto &ext : extensions) {
        if (!joined.empty()) joined.push_back(',');
        joined += ext;
    }
    int copy = static_cast<int>(joined.size());
    if (copy > buf_len - 1) copy = buf_len - 1;
    if (copy > 0) std::memcpy(buf, joined.data(), static_cast<size_t>(copy));
    buf[copy] = '\0';
    return copy;
}

} // namespace

extern "C" {

unsigned char *swiftpwa_wic_decode_rgb(const unsigned char *data, int len,
                                       int max_side, int *out_w, int *out_h,
                                       int *out_len) {
    try {
        return decode_rgb_impl(data, len, max_side, out_w, out_h, out_len);
    } catch (...) {
        return nullptr;
    }
}

unsigned char *swiftpwa_wic_encode_rgb(const unsigned char *pixels, int width,
                                       int height, int is_jpeg, int quality,
                                       int *out_len) {
    try {
        return encode_rgb_impl(pixels, width, height, is_jpeg, quality, out_len);
    } catch (...) {
        return nullptr;
    }
}

int swiftpwa_wic_decode_extensions(char *buf, int buf_len) {
    try {
        return decode_extensions_impl(buf, buf_len);
    } catch (...) {
        return 0;
    }
}

void swiftpwa_wic_free(unsigned char *data) {
    std::free(data);
}

} // extern "C"

#endif // _WIN32

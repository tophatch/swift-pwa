// swiftpwa_toast — C++/WinRT implementation of the toast shim. See
// `include/swiftpwa_toast.h` for the rationale + ABI.
//
// We construct the toast XML by hand (against the `ToastGeneric`
// schema) rather than going through `ToastNotificationManager.
// GetTemplateContent(...)`, because the templates ship a default
// `<audio>` element that Win11 treats as opt-out for the
// "silent" case, and editing the template's DOM in C++/WinRT to
// remove it is more code than just emitting the right XML up front.

#if defined(_WIN32) || defined(_WIN64)

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include "swiftpwa_toast.h"

#include <windows.h>
#include <roapi.h>

#include <winrt/base.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.UI.Notifications.h>

#include <atomic>
#include <mutex>
#include <string>

namespace WUN = winrt::Windows::UI::Notifications;
namespace WDX = winrt::Windows::Data::Xml::Dom;

namespace {

std::mutex g_mu;
std::wstring g_aumid;
std::atomic<bool> g_initialized{false};

// XML escaper for toast template strings. The `ToastGeneric` schema
// is plain XML, so we have to escape `& < > " '` in user-supplied
// text. CreateTextNode-style construction would do this for us, but
// building each text element through the Xml DOM API roughly triples
// the line count for no real benefit.
std::wstring escape_xml(const wchar_t *src) {
    std::wstring out;
    if (!src) return out;
    for (const wchar_t *p = src; *p; ++p) {
        switch (*p) {
            case L'&':  out += L"&amp;";  break;
            case L'<':  out += L"&lt;";   break;
            case L'>':  out += L"&gt;";   break;
            case L'"':  out += L"&quot;"; break;
            case L'\'': out += L"&apos;"; break;
            default:    out += *p;        break;
        }
    }
    return out;
}

std::wstring build_toast_xml(
    const wchar_t *title, const wchar_t *body, bool silent) {
    std::wstring xml = L"<toast>";
    xml += L"<visual><binding template='ToastGeneric'>";
    xml += L"<text>" + escape_xml(title) + L"</text>";
    if (body && *body) {
        xml += L"<text>" + escape_xml(body) + L"</text>";
    }
    xml += L"</binding></visual>";
    if (silent) {
        xml += L"<audio silent='true'/>";
    }
    xml += L"</toast>";
    return xml;
}

// Convert wide string to winrt::hstring without going through the
// implicit `winrt::param::hstring` overload (which on some toolchains
// makes a temporary that doesn't survive `ToastNotification` ctor).
winrt::hstring to_hstring(std::wstring_view sv) {
    return winrt::hstring{ sv };
}

} // namespace

extern "C" int32_t swiftpwa_toast_init(const wchar_t *aumid) {
    if (!aumid || !*aumid) return E_INVALIDARG;
    // RoInitialize is required before any WinRT call. WindowsAppRuntime
    // calls OleInitialize (apartment-threaded, equivalent for our
    // purposes), but WinRT is happy to be re-initialized on the same
    // thread; we tolerate `RPC_E_CHANGED_MODE` since the WinRT calls
    // we make work fine on either STA or MTA.
    HRESULT hr = RoInitialize(RO_INIT_SINGLETHREADED);
    if (FAILED(hr) && hr != static_cast<HRESULT>(0x80010106) /* RPC_E_CHANGED_MODE */) {
        return static_cast<int32_t>(hr);
    }
    {
        std::lock_guard<std::mutex> lock(g_mu);
        g_aumid.assign(aumid);
    }
    g_initialized.store(true, std::memory_order_release);
    return 0;
}

extern "C" int32_t swiftpwa_toast_available(void) {
    if (!g_initialized.load(std::memory_order_acquire)) return 0;
    // Probe by attempting to manufacture a notifier. If the runtime
    // doesn't have ToastNotificationManager (e.g. Windows Server Core
    // without the Desktop Experience) the catch surfaces and we fall
    // back. We do NOT cache the result — the WinRT activation cost is
    // negligible compared to the toast send itself, and caching
    // requires more state we don't otherwise need.
    try {
        std::wstring aumid;
        {
            std::lock_guard<std::mutex> lock(g_mu);
            aumid = g_aumid;
        }
        auto _ = WUN::ToastNotificationManager::CreateToastNotifier(to_hstring(aumid));
        return 1;
    } catch (...) {
        return 0;
    }
}

extern "C" int32_t swiftpwa_toast_send(
    const wchar_t *tag, const wchar_t *title, const wchar_t *body, int32_t silent) {
    if (!g_initialized.load(std::memory_order_acquire)) return E_NOT_VALID_STATE;
    try {
        std::wstring aumid;
        {
            std::lock_guard<std::mutex> lock(g_mu);
            aumid = g_aumid;
        }
        auto notifier = WUN::ToastNotificationManager::CreateToastNotifier(to_hstring(aumid));

        WDX::XmlDocument doc;
        doc.LoadXml(to_hstring(build_toast_xml(title, body, silent != 0)));

        WUN::ToastNotification toast{ doc };
        if (tag && *tag) {
            // Tag length cap: WinRT throws on tags > 64 chars. Truncate.
            std::wstring t{ tag };
            if (t.size() > 64) t.resize(64);
            toast.Tag(to_hstring(t));
        }
        notifier.Show(toast);
        return 0;
    } catch (winrt::hresult_error const &e) {
        fprintf(stderr,
                "swift-pwa: toast Show failed: 0x%08X\n",
                static_cast<unsigned int>(e.code().value));
        return static_cast<int32_t>(e.code().value);
    } catch (...) {
        return E_FAIL;
    }
}

extern "C" int32_t swiftpwa_toast_remove(const wchar_t *tag) {
    if (!g_initialized.load(std::memory_order_acquire)) return E_NOT_VALID_STATE;
    if (!tag || !*tag) return E_INVALIDARG;
    try {
        std::wstring aumid;
        {
            std::lock_guard<std::mutex> lock(g_mu);
            aumid = g_aumid;
        }
        auto history = WUN::ToastNotificationManager::History();
        history.Remove(to_hstring(tag), to_hstring(L""), to_hstring(aumid));
        return 0;
    } catch (winrt::hresult_error const &e) {
        return static_cast<int32_t>(e.code().value);
    } catch (...) {
        return E_FAIL;
    }
}

#else // !_WIN32

#include "swiftpwa_toast.h"

extern "C" int32_t swiftpwa_toast_init(const wchar_t *) { return -1; }
extern "C" int32_t swiftpwa_toast_available(void) { return 0; }
extern "C" int32_t swiftpwa_toast_send(const wchar_t *, const wchar_t *, const wchar_t *, int32_t) { return -1; }
extern "C" int32_t swiftpwa_toast_remove(const wchar_t *) { return -1; }

#endif // _WIN32

// swiftpwa_webview2 — implementation. See `include/swiftpwa_webview2.h`
// for the C ABI exposed to the `SwiftPWAWindows` Swift target.
//
// This file is the only place in the package that touches the WebView2
// COM API directly. Everything else goes through the flat C surface.
//
// Conventions:
//   - All pointers crossing the C boundary are owned by exactly one
//     side at a time: handles returned from `_create_*` are owned by
//     Swift until released; user-data pointers passed to callbacks are
//     opaque to us.
//   - We never throw exceptions across the C boundary. Failures from
//     the underlying COM call are propagated as the HRESULT.
//   - Callbacks fire on the UI thread (the thread that called the
//     create function), the same thread WebView2 dispatches its own
//     COM events on. Swift's `MainThread` hook is wired around the
//     Win32 message pump on that thread, so callback bodies can
//     freely re-enter the shim.

#if defined(_WIN32) || defined(_WIN64)

// Use Unicode APIs and pull in the WinSDK before WebView2.h.
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include "swiftpwa_webview2.h"

#include <windows.h>
#include <objbase.h>
#include <wrl.h>
#include <wil/com.h>
#include <WebView2.h>
#include <WebView2EnvironmentOptions.h>

#include <atomic>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Make;

// MARK: - Opaque types

// `swiftpwa_w2_env` and `swiftpwa_w2_controller` are the public opaque
// types declared in the header. Define them here as aliases for tagged
// COM pointer wrappers so the lifetime rules are visible at a glance.
struct swiftpwa_w2_env {
    ComPtr<ICoreWebView2Environment> com;
};

struct swiftpwa_w2_controller {
    ComPtr<ICoreWebView2Controller> com;
    // Cached view pointer for `swiftpwa_w2_controller_view`. Holds a
    // strong ref so a Swift caller that keeps the view handle alive
    // beyond `controller_release` doesn't see a dangling pointer.
    // (In practice the Swift side releases controller and view at the
    // same time, but the rule is "release in any order".)
    ComPtr<ICoreWebView2> view_strong;
    // Tokens for event subscriptions, kept so we can unsubscribe on
    // close. The C ABI doesn't expose a separate "unsubscribe" call
    // because the Swift side always tears down view + controller
    // together; tracking tokens here keeps the cleanup correct.
    EventRegistrationToken web_message_token{};
    EventRegistrationToken web_resource_token{};
    bool web_message_subscribed = false;
    bool web_resource_subscribed = false;
};

// `swiftpwa_w2_view` is just a re-tag of the controller's view pointer
// — never owned independently. We hand back the same ICoreWebView2
// raw pointer wrapped in a tagged struct so the Swift side has a
// distinct type.
struct swiftpwa_w2_view {
    ICoreWebView2 *raw;
    // Back-reference to the owning controller, used by
    // `swiftpwa_w2_resource_respond` to look up the deferred request.
    swiftpwa_w2_controller *owner;
};

// MARK: - Per-controller state for resource interception
//
// `WebResourceRequested` fires on the UI thread. We surface each call
// to Swift with a numeric `request_token` and stash the live
// `ICoreWebView2WebResourceRequestedEventArgs` in this map; the Swift
// side then calls `swiftpwa_w2_resource_respond(token, …)` and we
// look up the args, build a response, and complete it.
//
// The map is keyed per-view (not global) — both because the request
// args belong to a specific view and because the Swift side might
// have multiple windows open at once. Tokens are monotonically
// assigned per view.
struct PendingResource {
    ComPtr<ICoreWebView2WebResourceRequestedEventArgs> args;
    // The `Deferral` token: WebResourceRequested defers the response
    // when we acknowledge that we want to handle it asynchronously.
    ComPtr<ICoreWebView2Deferral> deferral;
};

struct ViewExtension {
    std::mutex mu;
    std::unordered_map<uint64_t, PendingResource> pending;
    std::atomic<uint64_t> next_token{1};

    // Cached for `swiftpwa_w2_resource_respond`: the WebView2
    // environment used to manufacture the response object via
    // `CreateWebResourceResponse`.
    ComPtr<ICoreWebView2Environment> env;

    swiftpwa_w2_resource_cb resource_cb = nullptr;
    void *resource_user = nullptr;

    swiftpwa_w2_message_cb message_cb = nullptr;
    void *message_user = nullptr;
};

// We keep the per-view extension as a side-table keyed by the
// underlying ICoreWebView2 raw pointer. WebView2 doesn't expose a
// general user-data slot, and adding it to the controller struct is
// awkward because the Swift side hands the view around independently.
// The map is small (one entry per open window) and accessed only from
// the UI thread, so a single global mutex is fine.
namespace {
std::mutex g_view_table_mu;
std::unordered_map<ICoreWebView2 *, std::unique_ptr<ViewExtension>> g_view_table;

ViewExtension &get_or_create_extension(ICoreWebView2 *view) {
    std::lock_guard<std::mutex> lock(g_view_table_mu);
    auto it = g_view_table.find(view);
    if (it == g_view_table.end()) {
        it = g_view_table.emplace(view, std::make_unique<ViewExtension>()).first;
    }
    return *it->second;
}

void drop_extension(ICoreWebView2 *view) {
    std::lock_guard<std::mutex> lock(g_view_table_mu);
    g_view_table.erase(view);
}

// Convert a UTF-16 wide string to UTF-8. Returns an empty string on
// failure rather than propagating an error — callers only use this
// for diagnostic / payload strings, never for control flow.
std::string wide_to_utf8(LPCWSTR w) {
    if (!w) return {};
    int len = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    if (len <= 0) return {};
    std::string s;
    s.resize(static_cast<size_t>(len - 1)); // exclude trailing NUL
    // `&s[0]` rather than `s.data()` — MSVC's C++17 surface picks the
    // const overload of `data()` for non-const strings on some
    // releases, which can't satisfy WideCharToMultiByte's mutable
    // `LPSTR` out-param.
    WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], len, nullptr, nullptr);
    return s;
}

std::wstring utf8_to_wide(const char *s) {
    if (!s) return {};
    int len = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    if (len <= 0) return {};
    std::wstring w;
    w.resize(static_cast<size_t>(len - 1));
    MultiByteToWideChar(CP_UTF8, 0, s, -1, &w[0], len);
    return w;
}
} // namespace

// MARK: - Environment

extern "C" void swiftpwa_w2_create_environment(
    const wchar_t *user_data_folder,
    swiftpwa_w2_env_ready_cb cb,
    void *user) {
    if (!cb) return;

    auto handler = Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
        [cb, user](HRESULT hr, ICoreWebView2Environment *env) -> HRESULT {
            if (FAILED(hr) || env == nullptr) {
                cb(nullptr, static_cast<int32_t>(hr), user);
                return S_OK;
            }
            auto *out = new swiftpwa_w2_env{};
            out->com = env;
            cb(out, 0, user);
            return S_OK;
        });

    HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(
        nullptr, user_data_folder, nullptr, handler.Get());
    if (FAILED(hr)) {
        cb(nullptr, static_cast<int32_t>(hr), user);
    }
}

extern "C" void swiftpwa_w2_env_release(swiftpwa_w2_env *env) {
    delete env;
}

// MARK: - Controller

extern "C" void swiftpwa_w2_create_controller(
    swiftpwa_w2_env *env,
    void *parent_hwnd,
    swiftpwa_w2_controller_ready_cb cb,
    void *user) {
    if (!env || !env->com || !cb) {
        if (cb) cb(nullptr, static_cast<int32_t>(E_INVALIDARG), user);
        return;
    }

    HWND hwnd = reinterpret_cast<HWND>(parent_hwnd);
    ComPtr<ICoreWebView2Environment> env_ref = env->com;
    auto handler = Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
        [cb, user, env_ref](HRESULT hr, ICoreWebView2Controller *ctrl) -> HRESULT {
            if (FAILED(hr) || ctrl == nullptr) {
                cb(nullptr, static_cast<int32_t>(hr), user);
                return S_OK;
            }
            auto *out = new swiftpwa_w2_controller{};
            out->com = ctrl;
            ComPtr<ICoreWebView2> view;
            if (SUCCEEDED(ctrl->get_CoreWebView2(&view))) {
                out->view_strong = view;
                // Pre-cache the env on the view extension so
                // `swiftpwa_w2_resource_respond` can build responses
                // without re-querying.
                ViewExtension &ext = get_or_create_extension(view.Get());
                {
                    std::lock_guard<std::mutex> lock(ext.mu);
                    ext.env = env_ref;
                }
                // Surface failed navigations on stderr so a 404 / CORS
                // / virtual-host-mapping miss doesn't just render blank.
                // Successful navigations stay quiet.
                EventRegistrationToken navTok{};
                view->add_NavigationCompleted(
                    Callback<ICoreWebView2NavigationCompletedEventHandler>(
                        [](ICoreWebView2 *, ICoreWebView2NavigationCompletedEventArgs *args) -> HRESULT {
                            BOOL success = FALSE;
                            COREWEBVIEW2_WEB_ERROR_STATUS status = COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
                            args->get_IsSuccess(&success);
                            args->get_WebErrorStatus(&status);
                            if (!success) {
                                fprintf(stderr,
                                        "swift-pwa: NavigationCompleted failed (status=%d)\n",
                                        static_cast<int>(status));
                            }
                            return S_OK;
                        }).Get(),
                    &navTok);
            }
            cb(out, 0, user);
            return S_OK;
        });

    HRESULT hr = env->com->CreateCoreWebView2Controller(hwnd, handler.Get());
    if (FAILED(hr)) {
        cb(nullptr, static_cast<int32_t>(hr), user);
    }
}

extern "C" void swiftpwa_w2_controller_release(swiftpwa_w2_controller *ctrl) {
    if (!ctrl) return;
    if (ctrl->view_strong) {
        ICoreWebView2 *raw = ctrl->view_strong.Get();
        if (ctrl->web_message_subscribed) {
            raw->remove_WebMessageReceived(ctrl->web_message_token);
        }
        if (ctrl->web_resource_subscribed) {
            raw->remove_WebResourceRequested(ctrl->web_resource_token);
        }
        drop_extension(raw);
    }
    delete ctrl;
}

extern "C" void swiftpwa_w2_controller_set_bounds(
    swiftpwa_w2_controller *ctrl,
    int32_t left, int32_t top, int32_t right, int32_t bottom) {
    if (!ctrl || !ctrl->com) return;
    RECT r{left, top, right, bottom};
    HRESULT hr = ctrl->com->put_Bounds(r);
    if (FAILED(hr)) {
        fprintf(stderr, "swift-pwa: put_Bounds(%d,%d,%d,%d) failed: 0x%08X\n",
                left, top, right, bottom, static_cast<unsigned int>(hr));
    }
}

extern "C" void swiftpwa_w2_controller_set_visible(
    swiftpwa_w2_controller *ctrl, int visible) {
    if (!ctrl || !ctrl->com) return;
    ctrl->com->put_IsVisible(visible ? TRUE : FALSE);
}

extern "C" void swiftpwa_w2_controller_close(swiftpwa_w2_controller *ctrl) {
    if (!ctrl || !ctrl->com) return;
    ctrl->com->Close();
}

extern "C" swiftpwa_w2_view *swiftpwa_w2_controller_view(swiftpwa_w2_controller *ctrl) {
    if (!ctrl || !ctrl->view_strong) return nullptr;
    // Ownership: the returned `swiftpwa_w2_view` is a thin tagged
    // pointer; lifetime is bounded by the controller. We allocate one
    // per call so the Swift side can free it independently, but the
    // underlying ICoreWebView2 ref is shared.
    auto *out = new swiftpwa_w2_view{};
    out->raw = ctrl->view_strong.Get();
    out->owner = ctrl;
    return out;
}

// MARK: - View

extern "C" void swiftpwa_w2_view_navigate(swiftpwa_w2_view *view, const wchar_t *url) {
    if (!view || !view->raw || !url) return;
    HRESULT hr = view->raw->Navigate(url);
    if (FAILED(hr)) {
        fprintf(stderr, "swift-pwa: Navigate failed: 0x%08X\n",
                static_cast<unsigned int>(hr));
    }
}

extern "C" void swiftpwa_w2_view_add_script_on_document_created(
    swiftpwa_w2_view *view, const wchar_t *script) {
    if (!view || !view->raw || !script) return;
    // The async handler is only used to surface the script id, which
    // we don't need; pass a no-op completer.
    view->raw->AddScriptToExecuteOnDocumentCreated(
        script,
        Callback<ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler>(
            [](HRESULT, LPCWSTR) -> HRESULT { return S_OK; }).Get());
}

extern "C" void swiftpwa_w2_view_execute_script(
    swiftpwa_w2_view *view, const wchar_t *script,
    swiftpwa_w2_eval_complete_cb cb, void *user) {
    if (!cb) return;
    if (!view || !view->raw || !script) {
        cb(nullptr, "view or script is null", user);
        return;
    }
    HRESULT hr = view->raw->ExecuteScript(
        script,
        Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
            [cb, user](HRESULT inner_hr, LPCWSTR result) -> HRESULT {
                if (FAILED(inner_hr)) {
                    char buf[64];
                    snprintf(buf, sizeof(buf), "ExecuteScript failed: 0x%08X",
                             static_cast<unsigned int>(inner_hr));
                    cb(nullptr, buf, user);
                    return S_OK;
                }
                std::string utf8 = wide_to_utf8(result);
                cb(utf8.empty() ? nullptr : utf8.c_str(), nullptr, user);
                return S_OK;
            }).Get());
    if (FAILED(hr)) {
        char buf[64];
        snprintf(buf, sizeof(buf), "ExecuteScript dispatch failed: 0x%08X",
                 static_cast<unsigned int>(hr));
        cb(nullptr, buf, user);
    }
}

extern "C" void swiftpwa_w2_view_post_web_message_string(
    swiftpwa_w2_view *view, const wchar_t *message) {
    if (!view || !view->raw || !message) return;
    view->raw->PostWebMessageAsString(message);
}

extern "C" void swiftpwa_w2_view_open_devtools(swiftpwa_w2_view *view) {
    if (!view || !view->raw) return;
    HRESULT hr = view->raw->OpenDevToolsWindow();
    if (FAILED(hr)) {
        fprintf(stderr, "swift-pwa: OpenDevToolsWindow failed: 0x%08X\n",
                static_cast<unsigned int>(hr));
    }
}

extern "C" void swiftpwa_w2_view_set_web_message_handler(
    swiftpwa_w2_view *view,
    swiftpwa_w2_message_cb cb,
    void *user) {
    if (!view || !view->raw) return;
    ViewExtension &ext = get_or_create_extension(view->raw);
    {
        std::lock_guard<std::mutex> lock(ext.mu);
        ext.message_cb = cb;
        ext.message_user = user;
    }
    if (view->owner && view->owner->web_message_subscribed) return;

    EventRegistrationToken token{};
    HRESULT hr = view->raw->add_WebMessageReceived(
        Callback<ICoreWebView2WebMessageReceivedEventHandler>(
            [view](ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *args) -> HRESULT {
                wil::unique_cotaskmem_string raw;
                // `TryGetWebMessageAsString` returns S_OK with a NULL
                // string when the JS side sent a non-string (e.g.
                // `postMessage({...})`). bridge.js always sends the
                // already-stringified envelope, so non-strings are an
                // error case we silently drop.
                if (FAILED(args->TryGetWebMessageAsString(&raw)) || !raw) return S_OK;
                std::string utf8 = wide_to_utf8(raw.get());
                ViewExtension &ext = get_or_create_extension(view->raw);
                swiftpwa_w2_message_cb cb_local = nullptr;
                void *user_local = nullptr;
                {
                    std::lock_guard<std::mutex> lock(ext.mu);
                    cb_local = ext.message_cb;
                    user_local = ext.message_user;
                }
                if (cb_local) cb_local(utf8.c_str(), user_local);
                return S_OK;
            }).Get(),
        &token);
    if (SUCCEEDED(hr) && view->owner) {
        view->owner->web_message_token = token;
        view->owner->web_message_subscribed = true;
    }
}

extern "C" void swiftpwa_w2_view_map_virtual_host(
    swiftpwa_w2_view *view,
    const wchar_t *host_name,
    const wchar_t *folder_path,
    int access_kind) {
    if (!view || !view->raw || !host_name || !folder_path) return;
    // SetVirtualHostNameToFolderMapping is on ICoreWebView2_3 (or the
    // matching versioned interface). Query for the highest one we can.
    ComPtr<ICoreWebView2_3> v3;
    HRESULT qi = view->raw->QueryInterface(IID_PPV_ARGS(&v3));
    if (FAILED(qi)) {
        fprintf(stderr, "swift-pwa: QueryInterface(ICoreWebView2_3) failed: 0x%08X "
                        "— virtual host mapping unavailable on this WebView2 build\n",
                static_cast<unsigned int>(qi));
        return;
    }
    COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND kind =
        access_kind == 0 ? COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY
                         : access_kind == 1
                             ? COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW
                             : COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS;
    HRESULT hr = v3->SetVirtualHostNameToFolderMapping(host_name, folder_path, kind);
    if (FAILED(hr)) {
        fprintf(stderr, "swift-pwa: SetVirtualHostNameToFolderMapping failed: 0x%08X\n",
                static_cast<unsigned int>(hr));
    }
}

extern "C" void swiftpwa_w2_view_intercept_resources(
    swiftpwa_w2_view *view,
    const wchar_t *url_filter,
    swiftpwa_w2_resource_cb cb,
    void *user) {
    if (!view || !view->raw || !cb || !url_filter) return;

    ViewExtension &ext = get_or_create_extension(view->raw);
    {
        std::lock_guard<std::mutex> lock(ext.mu);
        ext.resource_cb = cb;
        ext.resource_user = user;
    }
    view->raw->AddWebResourceRequestedFilter(
        url_filter, COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);

    if (view->owner && view->owner->web_resource_subscribed) return;

    EventRegistrationToken token{};
    HRESULT hr = view->raw->add_WebResourceRequested(
        Callback<ICoreWebView2WebResourceRequestedEventHandler>(
            [view](ICoreWebView2 *, ICoreWebView2WebResourceRequestedEventArgs *args) -> HRESULT {
                ViewExtension &ext = get_or_create_extension(view->raw);
                ComPtr<ICoreWebView2WebResourceRequest> req;
                if (FAILED(args->get_Request(&req)) || !req) return S_OK;
                wil::unique_cotaskmem_string uri_w;
                if (FAILED(req->get_Uri(&uri_w)) || !uri_w) return S_OK;
                std::string uri = wide_to_utf8(uri_w.get());

                // Defer the request so we can answer asynchronously.
                ComPtr<ICoreWebView2Deferral> deferral;
                args->GetDeferral(&deferral);

                uint64_t token = ext.next_token.fetch_add(1);
                {
                    std::lock_guard<std::mutex> lock(ext.mu);
                    ext.pending.emplace(
                        token,
                        PendingResource{ComPtr<ICoreWebView2WebResourceRequestedEventArgs>(args),
                                        deferral});
                }

                swiftpwa_w2_resource_cb cb_local = nullptr;
                void *user_local = nullptr;
                {
                    std::lock_guard<std::mutex> lock(ext.mu);
                    cb_local = ext.resource_cb;
                    user_local = ext.resource_user;
                }
                if (cb_local) cb_local(uri.c_str(), token, user_local);
                return S_OK;
            }).Get(),
        &token);
    if (SUCCEEDED(hr) && view->owner) {
        view->owner->web_resource_token = token;
        view->owner->web_resource_subscribed = true;
    }
}

extern "C" void swiftpwa_w2_resource_respond(
    swiftpwa_w2_view *view,
    uint64_t request_token,
    int32_t status,
    const char *mime_type,
    const uint8_t *body,
    int32_t body_len) {
    if (!view || !view->raw) return;
    ViewExtension &ext = get_or_create_extension(view->raw);
    PendingResource pending;
    {
        std::lock_guard<std::mutex> lock(ext.mu);
        auto it = ext.pending.find(request_token);
        if (it == ext.pending.end()) return;
        pending = std::move(it->second);
        ext.pending.erase(it);
    }

    ComPtr<ICoreWebView2Environment> env;
    {
        std::lock_guard<std::mutex> lock(ext.mu);
        env = ext.env;
    }
    if (!env) {
        if (pending.deferral) pending.deferral->Complete();
        return;
    }

    // Wrap the bytes in an IStream the runtime can read.
    HGLOBAL h = nullptr;
    if (body && body_len > 0) {
        h = GlobalAlloc(GMEM_MOVEABLE, static_cast<SIZE_T>(body_len));
        if (h) {
            void *dst = GlobalLock(h);
            if (dst) {
                std::memcpy(dst, body, static_cast<size_t>(body_len));
                GlobalUnlock(h);
            }
        }
    }
    ComPtr<IStream> stream;
    if (h) {
        // CreateStreamOnHGlobal takes ownership when fDeleteOnRelease is TRUE.
        if (FAILED(CreateStreamOnHGlobal(h, TRUE, &stream))) {
            GlobalFree(h);
        }
    }

    std::wstring headers;
    if (mime_type && *mime_type) {
        headers = L"Content-Type: " + utf8_to_wide(mime_type);
    }

    ComPtr<ICoreWebView2WebResourceResponse> response;
    HRESULT hr = env->CreateWebResourceResponse(
        stream.Get(),
        status,
        status >= 200 && status < 300 ? L"OK" : L"Not Found",
        headers.empty() ? L"" : headers.c_str(),
        &response);
    if (SUCCEEDED(hr) && response) {
        pending.args->put_Response(response.Get());
    }
    if (pending.deferral) pending.deferral->Complete();
}

// MARK: - Win32 helpers

extern "C" int swiftpwa_track_popup_menu(
    void *menu, unsigned int flags,
    int x, int y, void *hwnd) {
    return static_cast<int>(TrackPopupMenu(
        reinterpret_cast<HMENU>(menu), flags, x, y, 0,
        reinterpret_cast<HWND>(hwnd), nullptr));
}

// MARK: - Runtime detection

extern "C" swiftpwa_w2_hresult swiftpwa_w2_check_runtime(void) {
    LPWSTR version = nullptr;
    HRESULT hr = GetAvailableCoreWebView2BrowserVersionString(nullptr, &version);
    if (version) CoTaskMemFree(version);
    return static_cast<int32_t>(hr);
}

#else // !_WIN32

// Non-Windows builds keep the symbols visible so the package compiles
// when the platform-condition guards in Package.swift exclude the
// real implementation. None of these are reachable at runtime — the
// `SwiftPWAWindows` target is gated to `os(Windows)` — but they let
// the file be present in the target's source list unconditionally
// without breaking the macOS / Linux build.

#include "swiftpwa_webview2.h"
#include <stddef.h>

extern "C" void swiftpwa_w2_create_environment(const wchar_t *, swiftpwa_w2_env_ready_cb, void *) {}
extern "C" void swiftpwa_w2_env_release(swiftpwa_w2_env *) {}
extern "C" void swiftpwa_w2_create_controller(swiftpwa_w2_env *, void *, swiftpwa_w2_controller_ready_cb, void *) {}
extern "C" void swiftpwa_w2_controller_release(swiftpwa_w2_controller *) {}
extern "C" void swiftpwa_w2_controller_set_bounds(swiftpwa_w2_controller *, int32_t, int32_t, int32_t, int32_t) {}
extern "C" void swiftpwa_w2_controller_set_visible(swiftpwa_w2_controller *, int) {}
extern "C" void swiftpwa_w2_controller_close(swiftpwa_w2_controller *) {}
extern "C" swiftpwa_w2_view *swiftpwa_w2_controller_view(swiftpwa_w2_controller *) { return NULL; }
extern "C" void swiftpwa_w2_view_navigate(swiftpwa_w2_view *, const wchar_t *) {}
extern "C" void swiftpwa_w2_view_add_script_on_document_created(swiftpwa_w2_view *, const wchar_t *) {}
extern "C" void swiftpwa_w2_view_execute_script(swiftpwa_w2_view *, const wchar_t *, swiftpwa_w2_eval_complete_cb, void *) {}
extern "C" void swiftpwa_w2_view_post_web_message_string(swiftpwa_w2_view *, const wchar_t *) {}
extern "C" void swiftpwa_w2_view_open_devtools(swiftpwa_w2_view *) {}
extern "C" void swiftpwa_w2_view_set_web_message_handler(swiftpwa_w2_view *, swiftpwa_w2_message_cb, void *) {}
extern "C" void swiftpwa_w2_view_map_virtual_host(swiftpwa_w2_view *, const wchar_t *, const wchar_t *, int) {}
extern "C" void swiftpwa_w2_view_intercept_resources(swiftpwa_w2_view *, const wchar_t *, swiftpwa_w2_resource_cb, void *) {}
extern "C" void swiftpwa_w2_resource_respond(swiftpwa_w2_view *, uint64_t, int32_t, const char *, const uint8_t *, int32_t) {}
extern "C" int swiftpwa_track_popup_menu(void *, unsigned int, int, int, void *) { return 0; }
extern "C" swiftpwa_w2_hresult swiftpwa_w2_check_runtime(void) { return -1; }

#endif // _WIN32

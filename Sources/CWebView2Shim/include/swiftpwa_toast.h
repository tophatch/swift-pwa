// swiftpwa_toast — WinRT toast notifications via
// `Windows.UI.Notifications.ToastNotificationManager`.
//
// Why a C shim and not the swift-winrt projections directly: swift-winrt
// requires generating WinRT projections from `.winmd` files at build
// time and pulling in the projection package into our SwiftPM graph.
// Our WinRT surface area here is tiny (one notifier, one XML payload,
// one event) — the cost of the projection toolchain isn't worth the
// few lines of C++/WinRT we'd save. So we keep the WinRT calls behind
// a flat C ABI, the same way `swiftpwa_webview2.h` keeps WebView2's
// COM/WRL behind one. C++/WinRT itself is header-only and ships with
// the Windows SDK, so this doesn't add any external dependencies.
//
// Lives in the same target as the WebView2 shim (CWebView2Shim) so we
// don't grow another Swift system-library target for a single .cpp.

#ifndef SWIFT_PWA_TOAST_SHIM_H
#define SWIFT_PWA_TOAST_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Initialize the toast subsystem with an AppUserModelID. Must be called
// once at startup, before any `swiftpwa_toast_send` call. The AUMID is
// what Windows uses to attribute the notification: without it,
// `ToastNotificationManager.CreateToastNotifier()` raises
// `E_INVALIDARG` from an unpackaged executable.
//
// Returns 0 on success, non-zero HRESULT otherwise.
int32_t swiftpwa_toast_init(const wchar_t *aumid);

// Returns 1 if the toast subsystem is initialized AND the runtime has
// `Windows.UI.Notifications.ToastNotificationManager` available; 0
// otherwise. Used by the Swift side to decide whether to take the
// WinRT path or fall back to `Shell_NotifyIconW` balloons.
int32_t swiftpwa_toast_available(void);

// Send a toast.
//
//   tag:           replace-by-id key. Pass empty string to skip
//                  replacement (each call yields a new toast).
//   title:         heading text (single line, ~40 chars on Win11).
//   body:          body text (1-2 lines on Win11). May be empty.
//   silent:        non-zero to suppress the audio cue.
//
// Returns 0 on success, non-zero on failure (logs the HRESULT to stderr).
int32_t swiftpwa_toast_send(
    const wchar_t *tag,
    const wchar_t *title,
    const wchar_t *body,
    int32_t silent);

// Remove a previously-shown toast from Action Center by tag. No-op if
// no toast with that tag is present. Returns 0 on success.
int32_t swiftpwa_toast_remove(const wchar_t *tag);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // SWIFT_PWA_TOAST_SHIM_H

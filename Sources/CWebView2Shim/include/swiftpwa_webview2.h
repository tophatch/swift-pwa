// swiftpwa_webview2 — flat C ABI over Microsoft Edge WebView2 (COM/C++).
//
// WebView2 is COM-only; the headers in `WebView2.h` expose interfaces
// like `ICoreWebView2Environment`, `ICoreWebView2Controller`, and
// `ICoreWebView2`. The Swift-Win32 importer can talk to plain C, but
// calling COM virtual tables, implementing event-handler interfaces,
// and managing AddRef/Release would be miserable from Swift. So the
// COM dance lives in `swiftpwa_webview2.cpp` and we expose this small
// flat C surface for the `SwiftPWAWindows` Swift target to call.
//
// All `*_release` functions are paired with the constructors that
// returned the opaque handle. Callbacks always run on the UI thread
// (the thread that called `swiftpwa_w2_create_environment`), the same
// thread WebView2 dispatches its own COM events on.

#ifndef SWIFT_PWA_WEBVIEW2_SHIM_H
#define SWIFT_PWA_WEBVIEW2_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handles. Real types live in the .cpp:
//   swiftpwa_w2_env        wraps ICoreWebView2Environment
//   swiftpwa_w2_controller wraps ICoreWebView2Controller
//   swiftpwa_w2_view       wraps ICoreWebView2 (a non-owning alias —
//                          its lifetime follows the controller).
typedef struct swiftpwa_w2_env swiftpwa_w2_env;
typedef struct swiftpwa_w2_controller swiftpwa_w2_controller;
typedef struct swiftpwa_w2_view swiftpwa_w2_view;

// HRESULT (S_OK == 0) returned from the underlying COM call. Anything
// non-zero is an error; the Swift side surfaces it via BridgeError.
typedef int32_t swiftpwa_w2_hresult;

// `env_ready` and `controller_ready` are one-shot — they fire exactly
// once for each create-* call.
typedef void (*swiftpwa_w2_env_ready_cb)(
    swiftpwa_w2_env *env, swiftpwa_w2_hresult hr, void *user);

typedef void (*swiftpwa_w2_controller_ready_cb)(
    swiftpwa_w2_controller *ctrl, swiftpwa_w2_hresult hr, void *user);

// `web_message_received` fires whenever the page calls
// `window.chrome.webview.postMessage(string)`. The string is UTF-8
// encoded JSON (we instruct bridge.js to call `postMessage` with the
// already-stringified envelope). The pointer is valid only for the
// duration of the callback — copy it if needed.
typedef void (*swiftpwa_w2_message_cb)(const char *utf8_json, void *user);

// `eval_complete` fires when ExecuteScript resolves. `result_json` is
// either NULL or the script's JSON-stringified return value (UTF-8).
// `error_message` is NULL on success or a UTF-8 description on failure.
// Both pointers are valid only for the duration of the callback.
typedef void (*swiftpwa_w2_eval_complete_cb)(
    const char *result_json, const char *error_message, void *user);

// `web_resource_requested` is the hook for the `pwa://` virtual scheme.
// `uri` is UTF-8. The Swift side responds via `swiftpwa_w2_resource_respond`
// using the `request_token` it received here.
typedef void (*swiftpwa_w2_resource_cb)(
    const char *uri, uint64_t request_token, void *user);

// MARK: - Environment

// Bootstrap a WebView2 environment. The user-data folder is where
// WebView2 stores its IndexedDB, cookies, cache, etc. Pass NULL for
// the default (`%LOCALAPPDATA%/<exe>/EBWebView`).
//
// Must be called from a thread with a Win32 message loop — the Swift
// side's `WindowsAppRuntime` ensures this.
void swiftpwa_w2_create_environment(
    const wchar_t *user_data_folder /* nullable */,
    swiftpwa_w2_env_ready_cb cb,
    void *user);

void swiftpwa_w2_env_release(swiftpwa_w2_env *env);

// MARK: - Controller (per-window WebView2 host)

// Attach a controller to `parent_hwnd`. The controller owns the
// `ICoreWebView2` view, which becomes available once `cb` fires.
void swiftpwa_w2_create_controller(
    swiftpwa_w2_env *env,
    void *parent_hwnd /* HWND */,
    swiftpwa_w2_controller_ready_cb cb,
    void *user);

void swiftpwa_w2_controller_release(swiftpwa_w2_controller *ctrl);

// Resize the WebView2 host to fill the given client rect. Coordinates
// are pixel offsets within the parent HWND.
void swiftpwa_w2_controller_set_bounds(
    swiftpwa_w2_controller *ctrl,
    int32_t left, int32_t top, int32_t right, int32_t bottom);

// Show / hide the WebView2 host. Hidden controllers stop rendering.
void swiftpwa_w2_controller_set_visible(swiftpwa_w2_controller *ctrl, int visible);

// Close the controller. Releases the WebView2 process for this window;
// must be called before the parent HWND is destroyed.
void swiftpwa_w2_controller_close(swiftpwa_w2_controller *ctrl);

swiftpwa_w2_view *swiftpwa_w2_controller_view(swiftpwa_w2_controller *ctrl);

// MARK: - View

void swiftpwa_w2_view_navigate(swiftpwa_w2_view *view, const wchar_t *url);

// Inject a script that runs at document-start in every frame, every
// navigation. Call this once with `bridge.js` source after the
// controller is ready.
void swiftpwa_w2_view_add_script_on_document_created(
    swiftpwa_w2_view *view, const wchar_t *script);

// Run `script` once and resolve the callback with its JSON-encoded
// result.
void swiftpwa_w2_view_execute_script(
    swiftpwa_w2_view *view, const wchar_t *script,
    swiftpwa_w2_eval_complete_cb cb, void *user);

// Send a string from the host into the page. JS receives it as a
// `message` event on `window.chrome.webview`.
void swiftpwa_w2_view_post_web_message_string(
    swiftpwa_w2_view *view, const wchar_t *message);

// Subscribe to inbound web messages. Replaces any prior subscription.
void swiftpwa_w2_view_set_web_message_handler(
    swiftpwa_w2_view *view,
    swiftpwa_w2_message_cb cb,
    void *user);

// Map a virtual host (e.g. "localhost") to a folder on disk. Combined
// with a webview navigation to `https://<host>/...` this is enough for
// shipping a static bundle without the full WebResourceRequested
// dance. WebView2 enforces same-origin via the synthetic host.
//
// `access_kind`: 0 = Deny, 1 = Allow, 2 = AllowDenyCors. We default to
// AllowDenyCors so JS modules load without surprises.
void swiftpwa_w2_view_map_virtual_host(
    swiftpwa_w2_view *view,
    const wchar_t *host_name,
    const wchar_t *folder_path,
    int access_kind);

// Pop WebView2's built-in DevTools window in a separate top-level
// window. Useful as a "is the runtime even alive" diagnostic; safe
// to wire to a debug-only key handler in production code.
void swiftpwa_w2_view_open_devtools(swiftpwa_w2_view *view);

// Subscribe to WebResourceRequested for a URL filter (e.g. `"pwa://*"`).
// The Swift side answers each request via `swiftpwa_w2_resource_respond`.
//
// We always filter on `COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL`.
void swiftpwa_w2_view_intercept_resources(
    swiftpwa_w2_view *view,
    const wchar_t *url_filter,
    swiftpwa_w2_resource_cb cb,
    void *user);

// Respond to a previously-intercepted request. `body` is `body_len`
// raw bytes (NULL + 0 for an empty body). `mime_type` is UTF-8
// (e.g. `"text/html; charset=utf-8"`). `status` is an HTTP-style
// integer (200 / 404 / ...). The shim copies `body` and `mime_type`,
// so the caller can free its buffers immediately.
void swiftpwa_w2_resource_respond(
    swiftpwa_w2_view *view,
    uint64_t request_token,
    int32_t status,
    const char *mime_type,
    const uint8_t *body,
    int32_t body_len);

// MARK: - Win32 helpers
//
// These aren't WebView2-specific, but live here so we don't need a
// second C target just to expose one or two functions Swift's WinSDK
// overlay imports the wrong type for.

/// `TrackPopupMenu` returns the chosen item id when called with
/// `TPM_RETURNCMD`, but Swift 6.3.1's WinSDK overlay imports the
/// function as returning `Bool`, dropping the id. We re-expose it
/// with an `int` return so `SystemTray` can read the chosen command.
///
/// `menu` is `HMENU`, `hwnd` is `HWND`. `nReserved` and `lprc`
/// (rarely used) default to 0 / NULL.
int swiftpwa_track_popup_menu(
    void *menu, unsigned int flags,
    int x, int y, void *hwnd);

// MARK: - WebView2 runtime detection

// Returns 0 if a WebView2 Runtime is installed and usable, otherwise
// a non-zero hresult (COREWEBVIEW2_E_RUNTIME_NOT_FOUND on a fresh
// Windows 10 box, etc.). Useful for the CLI / startup code to print
// a friendly install hint before attempting `create_environment`.
swiftpwa_w2_hresult swiftpwa_w2_check_runtime(void);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // SWIFT_PWA_WEBVIEW2_SHIM_H

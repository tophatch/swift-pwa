// swiftpwa_android.h - JNI boundary between the Swift runtime and the
// Kotlin host activity. Header is exposed to Swift verbatim; flat C ABI
// throughout. See Sources/SwiftPWAAndroid/AndroidAppRuntime.swift for
// the Swift side and the Kotlin scaffold templates under
// SwiftPWACLISupport for the Java/Kotlin side.
//
// Two directions of traffic across the boundary:
//
//   Java -> Swift (inbound):
//     The Kotlin Activity registers a `JavascriptInterface` whose
//     methods JNI-call back into us; this file exports the C symbols
//     those JNI methods bind to. Swift registers handlers via
//     `swiftpwa_android_set_inbound_handler` etc.
//
//   Swift -> Java (outbound):
//     Swift calls flat C functions here, which look up cached
//     `jclass`/`jmethodID` references and invoke into the JVM via
//     the cached `JavaVM*`. Cached references are populated on first
//     call from the UI thread (where the Activity binds them).
//
// The shim deliberately does NOT take a dependency on swift-jni or
// any C++/JNI helper layer — same reasoning as `CWebView2Shim` not
// pulling in swift-winrt: the surface is small enough (one webview,
// one main-thread post path) that hand-rolled JNI is simpler than
// wiring up a code generator.

#ifndef SWIFTPWA_ANDROID_H
#define SWIFTPWA_ANDROID_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

// Opaque handles. These are `jobject` global refs under the hood;
// laundered through `void *` so Swift doesn't need to import jni.h.
typedef void *swiftpwa_android_webview;

// Emit a log line under tag "swift-pwa" at INFO level. Wraps
// `__android_log_print` so the Swift side has a working
// alternative to `FileHandle.standardError` (which goes to /dev/null
// for app processes on Android). Safe to call from any thread; no
// JVM attachment required.
void swiftpwa_android_log(const char *message_utf8);

// ---------------------------------------------------------------------
// Inbound: Java -> Swift trampolines.
//
// The JNI methods on the Kotlin `SwiftPWABridge` interface call these
// from binder threads (NOT the UI thread). Swift's registered handler
// is responsible for hopping to its own concurrency domain if needed.
//
// `json_utf8` is a NUL-terminated UTF-8 string owned by the JVM for
// the duration of the call; copy if you need to retain it.
// ---------------------------------------------------------------------

typedef void (*swiftpwa_android_inbound_fn)(const char *json_utf8, void *user);

void swiftpwa_android_set_inbound_handler(swiftpwa_android_inbound_fn handler,
                                          void *user);

// Called by the Kotlin host (`SwiftPWABridge.deliver`) on the binder
// thread. Looks up the registered handler and dispatches.
void swiftpwa_android_dispatch_inbound(const char *json_utf8);

// ---------------------------------------------------------------------
// Outbound: Swift -> Java.
//
// Swift calls these from any thread; the shim hops to the JVM main
// thread (via `Handler(Looper.getMainLooper()).post`) before driving
// the WebView API, which is main-thread-only.
// ---------------------------------------------------------------------

// Bind the Kotlin-side `SwiftPWABridge` instance for this process.
// Called from JNI (`Java_dev_swiftpwa_runtime_SwiftPWABridge_nativeAttach`)
// when the Activity creates its bridge object. `bridge_ref` is a JNI
// global ref the shim retains until `swiftpwa_android_detach_bridge`.
void swiftpwa_android_attach_bridge(void *bridge_ref);
void swiftpwa_android_detach_bridge(void);

// Returns 1 if a Kotlin-side bridge is currently attached, 0 otherwise.
// Swift code uses this to decide whether to drop outbound frames
// (during teardown, before the Activity binds, etc.) instead of
// crashing in the JNI call path.
int swiftpwa_android_bridge_is_attached(void);

// Post `json_utf8` to the page via WebView's
// `evaluateJavascript("globalThis.__SWIFT_PWA__.__deliver(...)")`.
// Hops to UI thread internally.
void swiftpwa_android_post_to_page(const char *json_utf8);

// Run `WebView.loadUrl(url)` (`url` is a `https://swift-pwa.local/...`
// or remote URL). Hops to UI thread internally.
void swiftpwa_android_load_url(const char *url_utf8);

// Run `Activity.setTitle(title)`, which updates the action-bar /
// task-list label. Hops to UI thread internally. No-op on apps that
// hide the action bar via theme.
void swiftpwa_android_set_title(const char *title_utf8);

// Toggle immersive / fullscreen mode by hiding (or showing) the
// system bars (status + navigation) via
// `WindowInsetsControllerCompat`. `on != 0` hides the bars and lets
// the WebView draw edge-to-edge; `on == 0` restores the default
// fitted-system-windows layout. Hops to UI thread internally.
void swiftpwa_android_set_fullscreen(int on);

// Spawn a new Activity hosting a separate WebView seeded with the
// content described by `config_json_utf8` (a JSON object with at
// least a `url` field; optional `title`). The new Activity becomes
// the foreground bridge — outbound calls reach the spawned WebView
// until the user navigates back. The Kotlin side does the
// `startActivity` with `FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_MULTIPLE_TASK`
// so each spawn gets its own task entry in the platform's recents
// list. Hops to UI thread internally. No-op when no bridge is
// attached (Activity hasn't reached `onCreate` yet).
void swiftpwa_android_spawn_window(const char *config_json_utf8);

// Run `WebView.evaluateJavascript(snippet, callback)`. The result
// callback fires on UI thread; the shim trampolines it back to
// `done` on whatever thread invoked the JVM (typically the binder
// pool). `result_json_utf8` is NULL if the JS expression returned
// `undefined`; `error_utf8` is NULL on success.
typedef void (*swiftpwa_android_eval_done_fn)(const char *result_json_utf8,
                                              const char *error_utf8,
                                              void *user);

void swiftpwa_android_evaluate_js(const char *snippet_utf8,
                                  swiftpwa_android_eval_done_fn done,
                                  void *user);

// Open the native WebView DevTools (Chrome remote-debug bridge). The
// Kotlin side gates this on `setWebContentsDebuggingEnabled(true)` in
// the Application class — only effective on debug builds.
void swiftpwa_android_open_devtools(void);

// ---------------------------------------------------------------------
// Generic Swift -> Kotlin RPC for the System* plugins (clipboard,
// notifications, dialog, biometrics, updater install).
//
// Method names are short identifiers like "clipboard.read" and
// "dialog.confirm"; the Kotlin side dispatches on the string. Args
// are JSON; result is JSON (or NULL); errors come back as a UTF-8
// message string (NULL on success). The Kotlin side hops to the UI
// thread internally where the underlying Android API requires it
// (most do); Swift callers can invoke from any thread.
//
// One generic entry point keeps the JNI surface small — adding a new
// plugin method is a one-case addition to the Kotlin dispatch
// `when` rather than a new C function + JNI binding pair.
// ---------------------------------------------------------------------

typedef void (*swiftpwa_android_rpc_done_fn)(const char *result_json_or_null,
                                             const char *error_or_null,
                                             void *user);

void swiftpwa_android_rpc(const char *method_utf8,
                          const char *args_json_utf8,
                          swiftpwa_android_rpc_done_fn done,
                          void *user);

// ---------------------------------------------------------------------
// Host event channel: Swift <- Kotlin (one-way push, no reply).
//
// Used by Kotlin code paths that observe asynchronous platform state
// outside the JS bridge envelope or the request/response RPC shape —
// most notably `BroadcastReceiver` callbacks for the updater
// `PackageInstaller.STATUS_*` lifecycle. A single Swift-side
// dispatcher is registered at runtime startup; it routes by the
// `channel` field embedded in the JSON payload to whichever plugin
// is interested.
//
// `json_utf8` is a NUL-terminated UTF-8 string owned by the JVM for
// the duration of the call; copy if you need to retain it.
// ---------------------------------------------------------------------

typedef void (*swiftpwa_android_host_event_fn)(const char *json_utf8, void *user);

void swiftpwa_android_set_host_event_handler(swiftpwa_android_host_event_fn handler,
                                             void *user);

// Called by Kotlin via JNI on a binder thread when a host-side
// event needs to reach Swift. Routes through the registered handler;
// no-op if nothing is registered.
void swiftpwa_android_dispatch_host_event(const char *json_utf8);

// ---------------------------------------------------------------------
// Main-thread dispatch hook. `MainThread.run` on Android calls
// `swiftpwa_android_post_main`, which retains the boxed closure and
// posts a runnable to `Handler(Looper.getMainLooper())`. The runnable's
// JNI callback fires `swiftpwa_android_run_main_box`, which transfers
// ownership back to Swift.
// ---------------------------------------------------------------------

typedef void (*swiftpwa_android_main_fn)(void *box);

// Set once, at startup, from the Swift side. Swift owns the box; the
// shim only ferries the pointer.
void swiftpwa_android_set_main_runner(swiftpwa_android_main_fn run);

// Called from Swift's `MainThread` hook. The shim posts a Java
// `Runnable` which, when run, JNI-calls back into
// `swiftpwa_android_run_main_box`.
void swiftpwa_android_post_main(void *box);

// Invoked by the JVM-side `Runnable.run()` JNI trampoline.
void swiftpwa_android_run_main_box(void *box);

// ---------------------------------------------------------------------
// Lifecycle.
// ---------------------------------------------------------------------

// Set by Swift; called by JNI when the Activity is destroyed.
typedef void (*swiftpwa_android_quit_fn)(int exit_code, void *user);

void swiftpwa_android_set_quit_handler(swiftpwa_android_quit_fn handler,
                                       void *user);

// Called from JNI on Activity teardown; Swift's quit handler unblocks
// the `AppRuntime.run(_:)` semaphore.
void swiftpwa_android_dispatch_quit(int exit_code);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // SWIFTPWA_ANDROID_H

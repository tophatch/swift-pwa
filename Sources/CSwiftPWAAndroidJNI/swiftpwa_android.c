// swiftpwa_android.c - JNI boundary implementation. See
// include/swiftpwa_android.h for the contract.
//
// Implementation notes:
//
//   - We cache the `JavaVM*` in `JNI_OnLoad`. Per-thread JNIEnv is
//     attached on demand via `AttachCurrentThread`; threads spawned
//     by Swift's cooperative pool are not initially JVM threads.
//
//   - The Kotlin side (`SwiftPWABridge`) holds the WebView + Handler.
//     We hold a global ref to the bridge object and call its
//     methods (`postToPage`, `loadUrl`, `evaluateJs`, `runOnMain`)
//     from Swift. The Java methods themselves do the
//     `runOnUiThread` hop using Android's `Handler`.
//
//   - The shim deliberately keeps no synchronization primitives
//     beyond an atomic-ish `bridge_ref` pointer. Set/cleared at
//     Activity attach/detach; reads under contention return either
//     "previous bridge" (best effort) or NULL. We accept a tiny
//     window of potential UB at teardown rather than introducing
//     a per-call mutex.

#include "include/swiftpwa_android.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// JNI is only meaningful on Android; on host platforms (compiled as
// part of `swift build` from a Mac/Linux/Windows dev box) the .c
// compiles to an empty TU so the package graph stays whole.
#ifdef __ANDROID__

#include <jni.h>
#include <android/log.h>

#define LOG_TAG "swift-pwa"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ---------------------------------------------------------------------
// Global state. All globals are touched from JNI threads (binder
// pool) and from Swift's cooperative pool, so we use atomic ops
// where the data type allows.
// ---------------------------------------------------------------------

static JavaVM *g_vm = NULL;

// Global ref to the Kotlin-side `SwiftPWABridge` instance. Set on
// `attach_bridge`, cleared on `detach_bridge`. `_Atomic` so the
// detach path doesn't have to synchronize with concurrent posters.
static _Atomic(jobject) g_bridge_ref = NULL;

// Cached method IDs on the bridge class. Populated lazily on first
// call from a JNI-attached thread.
static jmethodID g_mid_post_to_page    = NULL;
static jmethodID g_mid_load_url        = NULL;
static jmethodID g_mid_set_title       = NULL;
static jmethodID g_mid_set_fullscreen  = NULL;
static jmethodID g_mid_spawn_window    = NULL;
static jmethodID g_mid_evaluate_js     = NULL;
static jmethodID g_mid_open_devtools   = NULL;
static jmethodID g_mid_run_on_main     = NULL;
static jmethodID g_mid_rpc_call        = NULL;

// Inbound (Java -> Swift) callback registered by Swift.
static swiftpwa_android_inbound_fn g_inbound_fn = NULL;
static void *g_inbound_user = NULL;

// Quit (JNI -> Swift) callback registered by Swift.
static swiftpwa_android_quit_fn g_quit_fn = NULL;
static void *g_quit_user = NULL;

// Main-thread runner registered by Swift.
static swiftpwa_android_main_fn g_main_fn = NULL;

// Host event channel (Kotlin -> Swift, no reply) registered by Swift.
static swiftpwa_android_host_event_fn g_host_event_fn = NULL;
static void *g_host_event_user = NULL;

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

static JNIEnv *attach_env(int *did_attach) {
    *did_attach = 0;
    if (!g_vm) return NULL;
    JNIEnv *env = NULL;
    jint rc = (*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6);
    if (rc == JNI_EDETACHED) {
        if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) == JNI_OK) {
            *did_attach = 1;
        } else {
            return NULL;
        }
    } else if (rc != JNI_OK) {
        return NULL;
    }
    return env;
}

static void detach_env(int did_attach) {
    if (did_attach && g_vm) {
        (*g_vm)->DetachCurrentThread(g_vm);
    }
}

static int cache_method_ids(JNIEnv *env, jobject bridge) {
    jclass cls = (*env)->GetObjectClass(env, bridge);
    if (!cls) return 0;
    g_mid_post_to_page  = (*env)->GetMethodID(env, cls, "postToPage",  "(Ljava/lang/String;)V");
    g_mid_load_url      = (*env)->GetMethodID(env, cls, "loadUrl",     "(Ljava/lang/String;)V");
    g_mid_set_title     = (*env)->GetMethodID(env, cls, "setTitle",    "(Ljava/lang/String;)V");
    g_mid_set_fullscreen = (*env)->GetMethodID(env, cls, "setFullscreen", "(Z)V");
    g_mid_spawn_window  = (*env)->GetMethodID(env, cls, "spawnWindow",  "(Ljava/lang/String;)V");
    // `evaluateJs(String snippet, long callback, long user)` — the two
    // longs carry a function pointer and an opaque user pointer that
    // the Java side hands back to us when it invokes
    // `Java_dev_swiftpwa_runtime_SwiftPWABridge_nativeEvalDone`.
    g_mid_evaluate_js   = (*env)->GetMethodID(env, cls, "evaluateJs",  "(Ljava/lang/String;JJ)V");
    g_mid_open_devtools = (*env)->GetMethodID(env, cls, "openDevTools","()V");
    // `runOnMain(long box)` — the box is the Swift-side closure pointer.
    g_mid_run_on_main   = (*env)->GetMethodID(env, cls, "runOnMain",   "(J)V");
    // `rpcCall(String method, String argsJson, long callback, long user)`
    // — generic dispatch entry point for the System* plugins.
    g_mid_rpc_call      = (*env)->GetMethodID(env, cls, "rpcCall",
                            "(Ljava/lang/String;Ljava/lang/String;JJ)V");
    (*env)->DeleteLocalRef(env, cls);
    return g_mid_post_to_page && g_mid_load_url && g_mid_set_title &&
           g_mid_set_fullscreen && g_mid_spawn_window && g_mid_evaluate_js &&
           g_mid_open_devtools && g_mid_run_on_main && g_mid_rpc_call;
}

// ---------------------------------------------------------------------
// JNI_OnLoad
// ---------------------------------------------------------------------

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    g_vm = vm;
    return JNI_VERSION_1_6;
}

// ---------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------

void swiftpwa_android_log(const char *message_utf8) {
    if (!message_utf8) return;
    __android_log_print(ANDROID_LOG_INFO, LOG_TAG, "%s", message_utf8);
}

// ---------------------------------------------------------------------
// Inbound: Java -> Swift
// ---------------------------------------------------------------------

void swiftpwa_android_set_inbound_handler(swiftpwa_android_inbound_fn handler,
                                          void *user) {
    g_inbound_fn = handler;
    g_inbound_user = user;
}

void swiftpwa_android_dispatch_inbound(const char *json_utf8) {
    if (g_inbound_fn) {
        g_inbound_fn(json_utf8, g_inbound_user);
    }
}

// JNI entry: Kotlin's `SwiftPWABridge.nativeIngest(String json)` lands
// here. Class name + method name are pinned by Java's name-mangling.
JNIEXPORT void JNICALL
Java_dev_swiftpwa_runtime_SwiftPWABridge_nativeIngest(JNIEnv *env,
                                                       jobject self,
                                                       jstring json) {
    (void)self;
    if (!json) return;
    const char *utf = (*env)->GetStringUTFChars(env, json, NULL);
    if (!utf) return;
    swiftpwa_android_dispatch_inbound(utf);
    (*env)->ReleaseStringUTFChars(env, json, utf);
}

// JNI entry: bridge attach. Caches the global ref and method IDs.
JNIEXPORT void JNICALL
Java_dev_swiftpwa_runtime_SwiftPWABridge_nativeAttach(JNIEnv *env,
                                                      jobject self,
                                                      jobject bridge) {
    (void)self;
    if (!bridge) return;
    jobject gref = (*env)->NewGlobalRef(env, bridge);
    if (!gref) return;
    if (!cache_method_ids(env, gref)) {
        (*env)->DeleteGlobalRef(env, gref);
        LOGE("nativeAttach: failed to cache bridge method IDs");
        return;
    }
    // Replace any prior bridge ref atomically.
    jobject prev = atomic_exchange(&g_bridge_ref, gref);
    if (prev) {
        (*env)->DeleteGlobalRef(env, prev);
    }
    LOGI("bridge attached");
}

// JNI entry: bridge detach. Releases the global ref.
JNIEXPORT void JNICALL
Java_dev_swiftpwa_runtime_SwiftPWABridge_nativeDetach(JNIEnv *env,
                                                      jobject self) {
    (void)self;
    jobject prev = atomic_exchange(&g_bridge_ref, NULL);
    if (prev) {
        (*env)->DeleteGlobalRef(env, prev);
    }
}

void swiftpwa_android_attach_bridge(void *bridge_ref) {
    // Allow Swift to install a pre-globalized ref directly. Rare; the
    // JNI entry above is the normal path.
    jobject prev = atomic_exchange(&g_bridge_ref, (jobject)bridge_ref);
    if (prev) {
        int attached = 0;
        JNIEnv *env = attach_env(&attached);
        if (env) {
            (*env)->DeleteGlobalRef(env, prev);
            detach_env(attached);
        }
    }
}

void swiftpwa_android_detach_bridge(void) {
    jobject prev = atomic_exchange(&g_bridge_ref, NULL);
    if (prev) {
        int attached = 0;
        JNIEnv *env = attach_env(&attached);
        if (env) {
            (*env)->DeleteGlobalRef(env, prev);
            detach_env(attached);
        }
    }
}

int swiftpwa_android_bridge_is_attached(void) {
    return atomic_load(&g_bridge_ref) != NULL ? 1 : 0;
}

// ---------------------------------------------------------------------
// Outbound: Swift -> Java
// ---------------------------------------------------------------------

void swiftpwa_android_post_to_page(const char *json_utf8) {
    if (!json_utf8) return;
    jobject bridge = atomic_load(&g_bridge_ref);
    if (!bridge || !g_mid_post_to_page) return;
    int attached = 0;
    JNIEnv *env = attach_env(&attached);
    if (!env) return;
    jstring jstr = (*env)->NewStringUTF(env, json_utf8);
    if (jstr) {
        (*env)->CallVoidMethod(env, bridge, g_mid_post_to_page, jstr);
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionDescribe(env);
            (*env)->ExceptionClear(env);
        }
        (*env)->DeleteLocalRef(env, jstr);
    }
    detach_env(attached);
}

void swiftpwa_android_load_url(const char *url_utf8) {
    if (!url_utf8) return;
    jobject bridge = atomic_load(&g_bridge_ref);
    if (!bridge || !g_mid_load_url) return;
    int attached = 0;
    JNIEnv *env = attach_env(&attached);
    if (!env) return;
    jstring jstr = (*env)->NewStringUTF(env, url_utf8);
    if (jstr) {
        (*env)->CallVoidMethod(env, bridge, g_mid_load_url, jstr);
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionDescribe(env);
            (*env)->ExceptionClear(env);
        }
        (*env)->DeleteLocalRef(env, jstr);
    }
    detach_env(attached);
}

void swiftpwa_android_set_title(const char *title_utf8) {
    if (!title_utf8) return;
    jobject bridge = atomic_load(&g_bridge_ref);
    if (!bridge || !g_mid_set_title) return;
    int attached = 0;
    JNIEnv *env = attach_env(&attached);
    if (!env) return;
    jstring jstr = (*env)->NewStringUTF(env, title_utf8);
    if (jstr) {
        (*env)->CallVoidMethod(env, bridge, g_mid_set_title, jstr);
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionDescribe(env);
            (*env)->ExceptionClear(env);
        }
        (*env)->DeleteLocalRef(env, jstr);
    }
    detach_env(attached);
}

void swiftpwa_android_set_fullscreen(int on) {
    jobject bridge = atomic_load(&g_bridge_ref);
    if (!bridge || !g_mid_set_fullscreen) return;
    int attached = 0;
    JNIEnv *env = attach_env(&attached);
    if (!env) return;
    (*env)->CallVoidMethod(env, bridge, g_mid_set_fullscreen, on ? JNI_TRUE : JNI_FALSE);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    detach_env(attached);
}

void swiftpwa_android_spawn_window(const char *config_json_utf8) {
    if (!config_json_utf8) return;
    jobject bridge = atomic_load(&g_bridge_ref);
    if (!bridge || !g_mid_spawn_window) return;
    int attached = 0;
    JNIEnv *env = attach_env(&attached);
    if (!env) return;
    jstring jstr = (*env)->NewStringUTF(env, config_json_utf8);
    if (jstr) {
        (*env)->CallVoidMethod(env, bridge, g_mid_spawn_window, jstr);
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionDescribe(env);
            (*env)->ExceptionClear(env);
        }
        (*env)->DeleteLocalRef(env, jstr);
    }
    detach_env(attached);
}

// Heap-boxed pair carried through `evaluateJs`'s long arguments.
struct eval_box {
    swiftpwa_android_eval_done_fn done;
    void *user;
};

void swiftpwa_android_evaluate_js(const char *snippet_utf8,
                                  swiftpwa_android_eval_done_fn done,
                                  void *user) {
    if (!snippet_utf8 || !done) {
        if (done) done(NULL, "swiftpwa: bridge not attached", user);
        return;
    }
    jobject bridge = atomic_load(&g_bridge_ref);
    if (!bridge || !g_mid_evaluate_js) {
        done(NULL, "swiftpwa: bridge not attached", user);
        return;
    }
    int attached = 0;
    JNIEnv *env = attach_env(&attached);
    if (!env) {
        done(NULL, "swiftpwa: failed to attach JNIEnv", user);
        return;
    }
    struct eval_box *box = (struct eval_box *)malloc(sizeof(*box));
    if (!box) {
        done(NULL, "swiftpwa: out of memory", user);
        detach_env(attached);
        return;
    }
    box->done = done;
    box->user = user;
    jstring jstr = (*env)->NewStringUTF(env, snippet_utf8);
    if (jstr) {
        (*env)->CallVoidMethod(env, bridge, g_mid_evaluate_js,
                               jstr,
                               (jlong)(uintptr_t)box,
                               (jlong)0);
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionDescribe(env);
            (*env)->ExceptionClear(env);
            // Don't free `box` here — Java may still call us back; if
            // the JNI call genuinely failed we leak one struct per
            // invocation, which is acceptable for an exceptional path.
        }
        (*env)->DeleteLocalRef(env, jstr);
    } else {
        free(box);
        done(NULL, "swiftpwa: failed to allocate JNI string", user);
    }
    detach_env(attached);
}

// JNI entry: Kotlin calls back here when `evaluateJavascript` resolves.
JNIEXPORT void JNICALL
Java_dev_swiftpwa_runtime_SwiftPWABridge_nativeEvalDone(JNIEnv *env,
                                                        jobject self,
                                                        jstring result_or_null,
                                                        jstring error_or_null,
                                                        jlong   box_ptr,
                                                        jlong   user_ptr) {
    (void)self;
    (void)user_ptr;
    struct eval_box *box = (struct eval_box *)(uintptr_t)box_ptr;
    if (!box) return;
    const char *result_utf = NULL;
    const char *error_utf = NULL;
    if (result_or_null) {
        result_utf = (*env)->GetStringUTFChars(env, result_or_null, NULL);
    }
    if (error_or_null) {
        error_utf = (*env)->GetStringUTFChars(env, error_or_null, NULL);
    }
    box->done(result_utf, error_utf, box->user);
    if (result_utf) (*env)->ReleaseStringUTFChars(env, result_or_null, result_utf);
    if (error_utf)  (*env)->ReleaseStringUTFChars(env, error_or_null, error_utf);
    free(box);
}

void swiftpwa_android_open_devtools(void) {
    jobject bridge = atomic_load(&g_bridge_ref);
    if (!bridge || !g_mid_open_devtools) return;
    int attached = 0;
    JNIEnv *env = attach_env(&attached);
    if (!env) return;
    (*env)->CallVoidMethod(env, bridge, g_mid_open_devtools);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
    }
    detach_env(attached);
}

// ---------------------------------------------------------------------
// Generic RPC: Swift -> Kotlin -> Android API -> result JSON
// ---------------------------------------------------------------------

// Heap-boxed pair carried through `rpcCall`'s long arguments. Matches
// the shape of `eval_box`; same lifecycle — the Kotlin side calls
// `nativeRpcDone` exactly once per `rpcCall`, and that call frees the
// box.
struct rpc_box {
    swiftpwa_android_rpc_done_fn done;
    void *user;
};

void swiftpwa_android_rpc(const char *method_utf8,
                          const char *args_json_utf8,
                          swiftpwa_android_rpc_done_fn done,
                          void *user) {
    if (!method_utf8 || !done) {
        if (done) done(NULL, "swiftpwa: invalid arguments to rpc()", user);
        return;
    }
    jobject bridge = atomic_load(&g_bridge_ref);
    if (!bridge || !g_mid_rpc_call) {
        done(NULL, "swiftpwa: bridge not attached", user);
        return;
    }
    int attached = 0;
    JNIEnv *env = attach_env(&attached);
    if (!env) {
        done(NULL, "swiftpwa: failed to attach JNIEnv", user);
        return;
    }
    struct rpc_box *box = (struct rpc_box *)malloc(sizeof(*box));
    if (!box) {
        done(NULL, "swiftpwa: out of memory", user);
        detach_env(attached);
        return;
    }
    box->done = done;
    box->user = user;
    jstring jmethod = (*env)->NewStringUTF(env, method_utf8);
    jstring jargs = args_json_utf8 ? (*env)->NewStringUTF(env, args_json_utf8) : NULL;
    if (!jmethod) {
        free(box);
        done(NULL, "swiftpwa: failed to allocate JNI method string", user);
        detach_env(attached);
        return;
    }
    (*env)->CallVoidMethod(env, bridge, g_mid_rpc_call,
                           jmethod, jargs,
                           (jlong)(uintptr_t)box,
                           (jlong)0);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        // The Kotlin side may not have invoked `nativeRpcDone` if the
        // call faulted before reaching its own try/catch. Fail the
        // continuation here so Swift doesn't hang. The Kotlin-side
        // wrapper *does* try/catch and report errors via
        // `nativeRpcDone`, so this branch is the safety net for
        // pre-dispatch faults (NewStringUTF OOM in JVM, etc.).
        free(box);
        done(NULL, "swiftpwa: rpc dispatch threw a JVM exception", user);
    }
    if (jmethod) (*env)->DeleteLocalRef(env, jmethod);
    if (jargs)   (*env)->DeleteLocalRef(env, jargs);
    detach_env(attached);
}

// JNI entry: Kotlin invokes this exactly once per `rpcCall` to deliver
// the result (or error) back to the Swift continuation.
JNIEXPORT void JNICALL
Java_dev_swiftpwa_runtime_SwiftPWABridge_nativeRpcDone(JNIEnv *env,
                                                       jobject self,
                                                       jstring result_or_null,
                                                       jstring error_or_null,
                                                       jlong   box_ptr,
                                                       jlong   user_ptr) {
    (void)self;
    (void)user_ptr;
    struct rpc_box *box = (struct rpc_box *)(uintptr_t)box_ptr;
    if (!box) return;
    const char *result_utf = NULL;
    const char *error_utf = NULL;
    if (result_or_null) {
        result_utf = (*env)->GetStringUTFChars(env, result_or_null, NULL);
    }
    if (error_or_null) {
        error_utf = (*env)->GetStringUTFChars(env, error_or_null, NULL);
    }
    box->done(result_utf, error_utf, box->user);
    if (result_utf) (*env)->ReleaseStringUTFChars(env, result_or_null, result_utf);
    if (error_utf)  (*env)->ReleaseStringUTFChars(env, error_or_null, error_utf);
    free(box);
}

// ---------------------------------------------------------------------
// Host event channel (Kotlin -> Swift, one-way)
// ---------------------------------------------------------------------

void swiftpwa_android_set_host_event_handler(swiftpwa_android_host_event_fn handler,
                                             void *user) {
    g_host_event_fn = handler;
    g_host_event_user = user;
}

void swiftpwa_android_dispatch_host_event(const char *json_utf8) {
    if (g_host_event_fn && json_utf8) {
        g_host_event_fn(json_utf8, g_host_event_user);
    }
}

// JNI entry: Kotlin's `SwiftPWABridge.nativeHostEvent(String json)`
// lands here from a binder / broadcast-receiver thread.
JNIEXPORT void JNICALL
Java_dev_swiftpwa_runtime_SwiftPWABridge_nativeHostEvent(JNIEnv *env,
                                                          jobject self,
                                                          jstring json) {
    (void)self;
    if (!json) return;
    const char *utf = (*env)->GetStringUTFChars(env, json, NULL);
    if (!utf) return;
    swiftpwa_android_dispatch_host_event(utf);
    (*env)->ReleaseStringUTFChars(env, json, utf);
}

// ---------------------------------------------------------------------
// Main-thread dispatch
// ---------------------------------------------------------------------

void swiftpwa_android_set_main_runner(swiftpwa_android_main_fn run) {
    g_main_fn = run;
}

void swiftpwa_android_post_main(void *box) {
    jobject bridge = atomic_load(&g_bridge_ref);
    if (!bridge || !g_mid_run_on_main) {
        // No bridge yet — drop on the floor. Caller's invariant is
        // that they install the bridge before posting; if they didn't,
        // we'd otherwise leak the box.
        if (g_main_fn) g_main_fn(box); // best-effort: run inline
        return;
    }
    int attached = 0;
    JNIEnv *env = attach_env(&attached);
    if (!env) {
        if (g_main_fn) g_main_fn(box);
        return;
    }
    (*env)->CallVoidMethod(env, bridge, g_mid_run_on_main, (jlong)(uintptr_t)box);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    detach_env(attached);
}

void swiftpwa_android_run_main_box(void *box) {
    if (g_main_fn) g_main_fn(box);
}

// JNI entry: Kotlin's `Runnable.run()` JNI-calls into here.
JNIEXPORT void JNICALL
Java_dev_swiftpwa_runtime_SwiftPWABridge_nativeRunMain(JNIEnv *env,
                                                       jobject self,
                                                       jlong box_ptr) {
    (void)env;
    (void)self;
    swiftpwa_android_run_main_box((void *)(uintptr_t)box_ptr);
}

// ---------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------

void swiftpwa_android_set_quit_handler(swiftpwa_android_quit_fn handler,
                                       void *user) {
    g_quit_fn = handler;
    g_quit_user = user;
}

void swiftpwa_android_dispatch_quit(int exit_code) {
    if (g_quit_fn) g_quit_fn(exit_code, g_quit_user);
}

JNIEXPORT void JNICALL
Java_dev_swiftpwa_runtime_SwiftPWABridge_nativeQuit(JNIEnv *env,
                                                    jobject self,
                                                    jint exit_code) {
    (void)env;
    (void)self;
    swiftpwa_android_dispatch_quit((int)exit_code);
}

#else // !__ANDROID__

// Host-platform stubs. These let the C target compile to an empty
// object on dev machines so the rest of the package graph stays
// whole; none of these are reachable since the Swift backend is
// itself `#if os(Android)`-guarded.

void swiftpwa_android_log(const char *m) { (void)m; }
void swiftpwa_android_set_inbound_handler(swiftpwa_android_inbound_fn h, void *u) { (void)h; (void)u; }
void swiftpwa_android_dispatch_inbound(const char *j) { (void)j; }
void swiftpwa_android_attach_bridge(void *b) { (void)b; }
void swiftpwa_android_detach_bridge(void) {}
int  swiftpwa_android_bridge_is_attached(void) { return 0; }
void swiftpwa_android_post_to_page(const char *j) { (void)j; }
void swiftpwa_android_load_url(const char *u) { (void)u; }
void swiftpwa_android_set_title(const char *t) { (void)t; }
void swiftpwa_android_set_fullscreen(int o) { (void)o; }
void swiftpwa_android_spawn_window(const char *c) { (void)c; }
void swiftpwa_android_evaluate_js(const char *s, swiftpwa_android_eval_done_fn d, void *u) {
    if (d) d(NULL, "swiftpwa: not running on Android", u);
    (void)s;
}
void swiftpwa_android_open_devtools(void) {}
void swiftpwa_android_rpc(const char *m, const char *a, swiftpwa_android_rpc_done_fn d, void *u) {
    (void)m; (void)a;
    if (d) d(NULL, "swiftpwa: not running on Android", u);
}
void swiftpwa_android_set_main_runner(swiftpwa_android_main_fn r) { (void)r; }
void swiftpwa_android_post_main(void *b) { (void)b; }
void swiftpwa_android_run_main_box(void *b) { (void)b; }
void swiftpwa_android_set_quit_handler(swiftpwa_android_quit_fn h, void *u) { (void)h; (void)u; }
void swiftpwa_android_dispatch_quit(int c) { (void)c; }
void swiftpwa_android_set_host_event_handler(swiftpwa_android_host_event_fn h, void *u) {
    (void)h; (void)u;
}
void swiftpwa_android_dispatch_host_event(const char *j) { (void)j; }

#endif // __ANDROID__

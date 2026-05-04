#ifndef SWIFT_PWA_WEBKITGTK_SHIM_H
#define SWIFT_PWA_WEBKITGTK_SHIM_H

#include <webkit2/webkit2.h>
#include <jsc/jsc.h>

/// Returns the GType name of a GObject instance, or NULL.
/// Owned by GLib — do *not* free the returned pointer.
static inline const char *swiftpwa_gobject_type_name(gpointer instance) {
    if (!instance) return NULL;
    return g_type_name(G_TYPE_FROM_INSTANCE(instance));
}

/// Extracts the JS string from the `script-message-received` signal's
/// value argument.
///
/// On webkit2gtk-4.1 the value is a `WebKitJavascriptResult*` — a
/// `G_DEFINE_BOXED_TYPE` (i.e. *not* a GObject, so
/// `G_TYPE_FROM_INSTANCE` reads garbage off its first field).
/// On webkit2gtk-6.0 it's a `JSCValue*` (a real GObject).
///
/// We can't safely runtime-detect between the two with a type check
/// because boxed pointers aren't GTypeInstances. Instead we trust the
/// compile-time ABI: when built against webkit2gtk-4.1 we treat the
/// arg as a WebKitJavascriptResult and unwrap. (When/if we add
/// webkit2gtk-6.0 support this shim ships in a separate target.)
///
/// Returned string is freshly allocated; caller must `g_free` it.
static inline char *swiftpwa_extract_message_string(gpointer arg) {
    if (!arg) return NULL;
    JSCValue *value = webkit_javascript_result_get_js_value((WebKitJavascriptResult *)arg);
    return value ? jsc_value_to_string(value) : NULL;
}

/// Async-evaluate callback dispatched from `swiftpwa_evaluate_javascript`.
/// `json` is a freshly-allocated JSON serialization of the result, or
/// NULL if there was no result. `error` is a freshly-allocated GError
/// message, or NULL on success. Exactly one of the two will be non-NULL
/// (or both NULL for `undefined`). Callee must `g_free` whichever it
/// receives.
typedef void (*swiftpwa_eval_callback)(char *json, char *error, void *user_data);

typedef struct {
    swiftpwa_eval_callback cb;
    void *user_data;
} swiftpwa_eval_box;

/// GAsyncReadyCallback trampoline. Hidden from Swift; only the
/// public wrapper below is meant to be called from Swift code.
static inline void swiftpwa_eval_finish(
    GObject *source,
    GAsyncResult *result,
    gpointer user_data
) {
    swiftpwa_eval_box *box = (swiftpwa_eval_box *)user_data;
    swiftpwa_eval_callback cb = box->cb;
    void *swift_ud = box->user_data;
    g_free(box);

    GError *error = NULL;
    JSCValue *value = webkit_web_view_evaluate_javascript_finish(
        WEBKIT_WEB_VIEW(source), result, &error
    );

    char *err_msg = NULL;
    char *json = NULL;
    if (error) {
        err_msg = g_strdup(error->message);
        g_error_free(error);
    } else if (value) {
        // jsc_value_to_json returns NULL for `undefined`, which is what
        // we want — a side-effecting snippet should resolve to `nil`.
        json = jsc_value_to_json(value, 0);
        g_object_unref(value);
    }
    cb(json, err_msg, swift_ud);
}

/// Async-evaluate `js` on `web_view`. The callback is dispatched on
/// the GMainContext that's active when this function is called (i.e.
/// the GTK main thread, since that's where we route Swift calls via
/// `MainThread.run`). Both strings handed to `cb` are heap-allocated;
/// the callee owns them and must `g_free` whichever is non-NULL.
static inline void swiftpwa_evaluate_javascript(
    WebKitWebView *web_view,
    const char *js,
    swiftpwa_eval_callback cb,
    void *user_data
) {
    swiftpwa_eval_box *box = (swiftpwa_eval_box *)g_malloc0(sizeof(swiftpwa_eval_box));
    box->cb = cb;
    box->user_data = user_data;
    webkit_web_view_evaluate_javascript(
        web_view, js, -1, NULL, NULL, NULL,
        swiftpwa_eval_finish, box
    );
}

#endif

#ifndef SWIFT_PWA_WEBKITGTK6_SHIM_H
#define SWIFT_PWA_WEBKITGTK6_SHIM_H

#include <webkit/webkit.h>
#include <jsc/jsc.h>

// Forward declarations for the WebKit types we reference from Swift.
// In webkitgtk-6.0 the umbrella `<webkit/webkit.h>` reaches them via
// `G_DECLARE_FINAL_TYPE` macros — but Swift's clang importer doesn't
// always pick up types defined that way through transitive includes,
// and emits "cannot find type 'WebKitUserContentManager' in scope" /
// "WebKitURISchemeRequest" at the Swift-side use sites. Re-declaring
// them here gives the importer a direct anchor; the typedefs are
// identical to what the WebKit headers produce, so C11 accepts the
// duplicate.
typedef struct _WebKitUserContentManager WebKitUserContentManager;
typedef struct _WebKitURISchemeRequest WebKitURISchemeRequest;
typedef struct _WebKitWebView WebKitWebView;

/// Returns the GType name of a GObject instance, or NULL.
/// Owned by GLib — do *not* free the returned pointer.
static inline const char *swiftpwa_gobject_type_name(gpointer instance) {
    if (!instance) return NULL;
    return g_type_name(G_TYPE_FROM_INSTANCE(instance));
}

/// Extracts the JS string from a `script-message-received::<name>`
/// signal's value argument.
///
/// On webkit2gtk-4.1 this argument was a `WebKitJavascriptResult*`
/// (boxed type) that you had to unwrap. On webkitgtk-6.0 the signal
/// passes a `JSCValue*` directly — a real GObject — so this is just a
/// thin wrapper around `jsc_value_to_string`. The function exists in
/// both shims so the Swift backend can call the same name regardless
/// of ABI.
///
/// Returned string is freshly allocated; caller must `g_free` it.
static inline char *swiftpwa_extract_message_string(gpointer arg) {
    if (!arg) return NULL;
    return jsc_value_to_string((JSCValue *)arg);
}

/// `webkit_web_view_new_with_user_content_manager` was removed in
/// webkitgtk-6.0; construction goes through `g_object_new` with the
/// content manager as a property.
static inline GtkWidget *swiftpwa_web_view_new_with_user_content_manager(
    WebKitUserContentManager *ucm
) {
    return GTK_WIDGET(g_object_new(
        WEBKIT_TYPE_WEB_VIEW,
        "user-content-manager", ucm,
        NULL
    ));
}

/// Async-evaluate callback dispatched from `swiftpwa_evaluate_javascript`.
typedef void (*swiftpwa_eval_callback)(char *json, char *error, void *user_data);

typedef struct {
    swiftpwa_eval_callback cb;
    void *user_data;
} swiftpwa_eval_box;

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
        json = jsc_value_to_json(value, 0);
        g_object_unref(value);
    }
    cb(json, err_msg, swift_ud);
}

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

/// Wrapper around `webkit_user_content_manager_register_script_message_handler`,
/// which takes an extra `world_name` argument in webkitgtk-6.0 (NULL =
/// default JS world). Wrapping it keeps the Swift backend's call site
/// identical between the two ABIs.
static inline void swiftpwa_register_script_message_handler(
    WebKitUserContentManager *ucm,
    const char *name
) {
    webkit_user_content_manager_register_script_message_handler(ucm, name, NULL);
}

#endif

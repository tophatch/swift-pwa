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

#endif

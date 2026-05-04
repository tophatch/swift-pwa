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

/// Extracts a JS string value from whatever the
/// `script-message-received` signal hands us.
///
/// WebKitGTK 4.1 *still* passes `WebKitJavascriptResult*` here despite
/// the header symbol being deprecated (the JSCValue-direct variant
/// arrived in webkit2gtk-6.0). 2.40+ also added the JSC variant for
/// some signals. We handle both at runtime by introspecting GType.
///
/// Returned string is freshly allocated by `jsc_value_to_string`; the
/// caller must `g_free` it. Returns NULL on unrecognised types.
static inline char *swiftpwa_extract_message_string(gpointer arg) {
    if (!arg) return NULL;
    GType type = G_TYPE_FROM_INSTANCE(arg);
    if (g_type_is_a(type, JSC_TYPE_VALUE)) {
        return jsc_value_to_string((JSCValue *)arg);
    }
    if (type == webkit_javascript_result_get_type()) {
        JSCValue *value = webkit_javascript_result_get_js_value((WebKitJavascriptResult *)arg);
        return value ? jsc_value_to_string(value) : NULL;
    }
    g_warning("swift-pwa: unexpected signal arg type: %s",
              g_type_name(type) ? g_type_name(type) : "(unknown)");
    return NULL;
}

#endif

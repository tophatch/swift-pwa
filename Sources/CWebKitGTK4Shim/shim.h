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
/// WebKitGTK 4.1 still passes `WebKitJavascriptResult*` (the
/// JSCValue-direct variant arrived in webkit2gtk-6.0); this shim
/// handles both at runtime via GType introspection.
///
/// Returned string is freshly allocated by `jsc_value_to_string`; the
/// caller must `g_free` it. Returns NULL on unrecognised types.
static inline char *swiftpwa_extract_message_string(gpointer arg) {
    if (!arg) return NULL;

    // Use G_TYPE_CHECK_INSTANCE_TYPE (which guards against bad
    // pointers via the standard GObject macro layer) rather than
    // raw G_TYPE_FROM_INSTANCE comparisons.
    if (G_TYPE_CHECK_INSTANCE_TYPE(arg, JSC_TYPE_VALUE)) {
        return jsc_value_to_string((JSCValue *)arg);
    }
    if (G_TYPE_CHECK_INSTANCE_TYPE(arg, webkit_javascript_result_get_type())) {
        JSCValue *value = webkit_javascript_result_get_js_value((WebKitJavascriptResult *)arg);
        return value ? jsc_value_to_string(value) : NULL;
    }

    // Diagnostic — include the raw GType integer and pointer so we
    // can identify exotic boxed types.
    GType t = G_TYPE_FROM_INSTANCE(arg);
    const char *name = g_type_name(t);
    g_warning("swift-pwa: unexpected script-message arg: gtype=%lu name=%s ptr=%p",
              (unsigned long)t, name ? name : "(null)", arg);
    return NULL;
}

#endif

#ifndef SWIFT_PWA_GTK3_SHIM_H
#define SWIFT_PWA_GTK3_SHIM_H

#include <gtk/gtk.h>
#include <gio/gio.h>

/// Extract the geometry from a `configure-event` `GdkEvent`. We accept
/// `gpointer` because Swift's clang importer treats `GdkEvent` (a
/// tagged union) as opaque, so reading `event->configure.*` straight
/// from Swift isn't reliable across versions. Caller must only invoke
/// this with an event whose `type == GDK_CONFIGURE`.
static inline void swiftpwa_event_configure_extents(
    gpointer event,
    int *out_x, int *out_y,
    int *out_width, int *out_height
) {
    if (!event) return;
    GdkEventConfigure *cfg = (GdkEventConfigure *)event;
    if (out_x) *out_x = cfg->x;
    if (out_y) *out_y = cfg->y;
    if (out_width) *out_width = cfg->width;
    if (out_height) *out_height = cfg->height;
}

/// Swift-side quit-accelerator callback. Invoked on the GTK main
/// thread when the user presses Ctrl+Q.
typedef void (*swiftpwa_accel_callback)(void *user_data);

typedef struct {
    swiftpwa_accel_callback cb;
    void *user_data;
} swiftpwa_accel_box;

/// GClosure marshaller — adapts the accel-group callback signature to
/// the Swift-friendly `swiftpwa_accel_callback`.
static gboolean swiftpwa_accel_trampoline(
    GtkAccelGroup *accel_group,
    GObject *acceleratable,
    guint keyval,
    GdkModifierType modifier,
    gpointer user_data
) {
    (void)accel_group; (void)acceleratable; (void)keyval; (void)modifier;
    swiftpwa_accel_box *box = (swiftpwa_accel_box *)user_data;
    box->cb(box->user_data);
    return TRUE;
}

static void swiftpwa_accel_box_free(gpointer data, GClosure *closure) {
    (void)closure;
    g_free(data);
}

/// Wire Ctrl+Q on `grp` to invoke `cb(user_data)`. Accelerator groups
/// are dispatched ahead of focus-based event delivery, so this fires
/// even when the WebKit page has focus on a text input.
static inline void swiftpwa_accel_connect_quit(
    GtkAccelGroup *grp,
    swiftpwa_accel_callback cb,
    void *user_data
) {
    swiftpwa_accel_box *box = (swiftpwa_accel_box *)g_malloc0(sizeof(swiftpwa_accel_box));
    box->cb = cb;
    box->user_data = user_data;
    GClosure *closure = g_cclosure_new(
        G_CALLBACK(swiftpwa_accel_trampoline),
        box,
        swiftpwa_accel_box_free
    );
    gtk_accel_group_connect(
        grp,
        GDK_KEY_q,
        GDK_CONTROL_MASK,
        GTK_ACCEL_VISIBLE,
        closure
    );
}

// ---------------------------------------------------------------------
// Clipboard helpers (GTK3 / GtkClipboard).
//
// `GDK_SELECTION_CLIPBOARD` is a macro that expands to a non-constant
// expression Swift's clang importer doesn't always pick up, so the
// default-clipboard accessor lives in C. The rest of the wrappers exist
// to give the GTK4 backend a matching call surface (the GTK4 side has
// to wrap async APIs anyway).
// ---------------------------------------------------------------------

static inline GtkClipboard *swiftpwa_clipboard_default(void) {
    return gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
}

static inline void swiftpwa_clipboard_set_text(GtkClipboard *cb, const char *text) {
    gtk_clipboard_set_text(cb, text, -1);
}

/// Synchronously read clipboard text. Returns a freshly allocated
/// string (caller must `g_free`) or NULL when the clipboard does not
/// hold text. Internally spins a nested main loop.
static inline char *swiftpwa_clipboard_wait_for_text(GtkClipboard *cb) {
    return gtk_clipboard_wait_for_text(cb);
}

/// Relinquish our ownership of the clipboard. As on most X11 / Wayland
/// stacks this only clears the local owner; another app's content (if
/// any) remains the system-wide value of the selection.
static inline void swiftpwa_clipboard_clear(GtkClipboard *cb) {
    gtk_clipboard_clear(cb);
}

// Tray-state functions (`swiftpwa_tray_*`) used to live here on top
// of `GtkStatusIcon`; they moved to `Sources/CAyatanaAppIndicator3Shim`
// when the GTK3 backend switched to AppIndicator (StatusNotifierItem),
// which works on GNOME / Wayland / KDE without the legacy Xembed tray.

// ---------------------------------------------------------------------
// Notifications (org.freedesktop.Notifications via D-Bus).
//
// We hit the freedesktop.org notification spec directly through GIO
// rather than depending on libnotify or libayatana-appindicator. Every
// modern Linux desktop ships a notification daemon listening on the
// session bus, so this works on GNOME / KDE / Sway / etc. without any
// extra system-side install.
// ---------------------------------------------------------------------

/// Send a desktop notification synchronously. Returns 0 and writes a
/// freshly-allocated notification id (the daemon's `uint32`, stringified)
/// to `*id_out` on success. Returns -1 and writes a freshly-allocated
/// error message to `*err_out` on failure. Either out-pointer may be
/// NULL if the caller doesn't need it. The strings the callee writes
/// are owned by the caller and must be `g_free`d.
static inline int swiftpwa_notify_send(
    const char *app_name,
    const char *title,
    const char *body,
    int play_sound,
    char **id_out,
    char **err_out
) {
    GError *err = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
    if (!bus) {
        if (err_out) {
            *err_out = err ? g_strdup(err->message) : g_strdup("g_bus_get_sync failed");
        }
        if (err) g_error_free(err);
        return -1;
    }

    // Empty actions list — actions / replies are out of scope for v0.2.
    GVariant *actions_v = g_variant_new_strv(NULL, 0);

    // Hints. Only `sound-name` is set when the caller asked for it;
    // the daemon falls back to a default chime for that hint.
    GVariantBuilder hints;
    g_variant_builder_init(&hints, G_VARIANT_TYPE("a{sv}"));
    if (play_sound) {
        g_variant_builder_add(
            &hints, "{sv}",
            "sound-name", g_variant_new_string("message-new-instant")
        );
    }
    GVariant *hints_v = g_variant_builder_end(&hints);

    GVariant *params = g_variant_new(
        "(susss@as@a{sv}i)",
        app_name ? app_name : "",
        (guint32)0,    // replaces_id (0 = new notification)
        "",            // app_icon
        title ? title : "",
        body ? body : "",
        actions_v,
        hints_v,
        (gint32)-1     // expire_timeout (-1 = daemon default)
    );

    GVariant *result = g_dbus_connection_call_sync(
        bus,
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "Notify",
        params,
        G_VARIANT_TYPE("(u)"),
        G_DBUS_CALL_FLAGS_NONE,
        5000,
        NULL,
        &err
    );
    g_object_unref(bus);

    if (!result) {
        if (err_out) {
            *err_out = err ? g_strdup(err->message) : g_strdup("Notify call failed");
        }
        if (err) g_error_free(err);
        return -1;
    }
    guint32 id = 0;
    g_variant_get(result, "(u)", &id);
    g_variant_unref(result);
    if (id_out) *id_out = g_strdup_printf("%u", id);
    return 0;
}

#endif

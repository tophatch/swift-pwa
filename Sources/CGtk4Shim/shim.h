#ifndef SWIFT_PWA_GTK4_SHIM_H
#define SWIFT_PWA_GTK4_SHIM_H

#include <gtk/gtk.h>
#include <gio/gio.h>

/// Swift-side quit-shortcut callback. Invoked on the GTK main thread
/// when the user presses Ctrl+Q.
typedef void (*swiftpwa_shortcut_callback)(void *user_data);

typedef struct {
    swiftpwa_shortcut_callback cb;
    void *user_data;
} swiftpwa_shortcut_box;

/// `GtkShortcutFunc` marshaller — adapts the GTK4 callback-action
/// signature to the Swift-friendly `swiftpwa_shortcut_callback`.
static gboolean swiftpwa_shortcut_trampoline(
    GtkWidget *widget,
    GVariant *args,
    gpointer user_data
) {
    (void)widget; (void)args;
    swiftpwa_shortcut_box *box = (swiftpwa_shortcut_box *)user_data;
    box->cb(box->user_data);
    return TRUE;
}

static void swiftpwa_shortcut_box_free(gpointer data) {
    g_free(data);
}

/// Install Ctrl+Q on `window` via a `GtkShortcutController` in
/// `GTK_SHORTCUT_SCOPE_GLOBAL` scope, so the binding fires regardless
/// of which child widget currently has focus (including a focused
/// `<input>` inside the embedded WebKit view). On activation
/// `cb(user_data)` runs on the GTK main thread.
static inline void swiftpwa_window_install_quit_shortcut(
    GtkWindow *window,
    swiftpwa_shortcut_callback cb,
    void *user_data
) {
    swiftpwa_shortcut_box *box = (swiftpwa_shortcut_box *)g_malloc0(sizeof(swiftpwa_shortcut_box));
    box->cb = cb;
    box->user_data = user_data;

    GtkShortcutTrigger *trigger = gtk_shortcut_trigger_parse_string("<Control>q");
    GtkShortcutAction *action = gtk_callback_action_new(
        swiftpwa_shortcut_trampoline,
        box,
        swiftpwa_shortcut_box_free
    );
    GtkShortcut *shortcut = gtk_shortcut_new(trigger, action);

    GtkEventController *ctrl = gtk_shortcut_controller_new();
    gtk_shortcut_controller_set_scope(
        GTK_SHORTCUT_CONTROLLER(ctrl),
        GTK_SHORTCUT_SCOPE_GLOBAL
    );
    gtk_shortcut_controller_add_shortcut(
        GTK_SHORTCUT_CONTROLLER(ctrl),
        shortcut
    );
    gtk_widget_add_controller(GTK_WIDGET(window), ctrl);
}

/// `gtk_init` is void/no-args in GTK4 (vs. `gtk_init(&argc, &argv)` on
/// GTK3). Swift's clang importer doesn't always pick up no-arg C
/// functions cleanly when there's a macro shim involved, so we expose
/// our own thin wrapper.
static inline void swiftpwa_gtk_init(void) {
    gtk_init();
}

// ---------------------------------------------------------------------
// Clipboard helpers (GTK4 / GdkClipboard).
//
// GTK4 dropped GtkClipboard in favour of GdkClipboard, whose only read
// API is async (`gdk_clipboard_read_text_async`). We expose the same
// `swiftpwa_clipboard_*` shape as the GTK3 shim so the Swift backend's
// SystemClipboard implementations stay symmetric, with the read
// surface bridging the GAsyncResult callback into a Swift continuation.
// ---------------------------------------------------------------------

static inline GdkClipboard *swiftpwa_clipboard_default(void) {
    GdkDisplay *d = gdk_display_get_default();
    if (!d) return NULL;
    return gdk_display_get_clipboard(d);
}

static inline void swiftpwa_clipboard_set_text(GdkClipboard *cb, const char *text) {
    gdk_clipboard_set_text(cb, text);
}

/// Async-read callback. Exactly one of `text` / `err` will be non-NULL
/// (or both NULL when the clipboard does not hold text). Whichever is
/// non-NULL is heap-allocated; the callee owns it and must `g_free`.
typedef void (*swiftpwa_clipboard_text_callback)(char *text, char *err, void *user_data);

typedef struct {
    swiftpwa_clipboard_text_callback cb;
    void *user_data;
} swiftpwa_clipboard_text_box;

static inline void swiftpwa_clipboard_text_finish(
    GObject *source,
    GAsyncResult *result,
    gpointer user_data
) {
    swiftpwa_clipboard_text_box *box = (swiftpwa_clipboard_text_box *)user_data;
    swiftpwa_clipboard_text_callback cb = box->cb;
    void *swift_ud = box->user_data;
    g_free(box);

    GError *error = NULL;
    char *text = gdk_clipboard_read_text_finish(
        GDK_CLIPBOARD(source), result, &error
    );
    char *err_msg = NULL;
    if (error) {
        err_msg = g_strdup(error->message);
        g_error_free(error);
    }
    cb(text, err_msg, swift_ud);
}

/// Async-read clipboard text. The callback fires on the GMainContext
/// active when the call is made (i.e. the GTK main thread, since the
/// Swift backend hops there via `MainThread.run` before invoking this).
static inline void swiftpwa_clipboard_read_text(
    GdkClipboard *cb,
    swiftpwa_clipboard_text_callback callback,
    void *user_data
) {
    swiftpwa_clipboard_text_box *box =
        (swiftpwa_clipboard_text_box *)g_malloc0(sizeof(swiftpwa_clipboard_text_box));
    box->cb = callback;
    box->user_data = user_data;
    gdk_clipboard_read_text_async(cb, NULL, swiftpwa_clipboard_text_finish, box);
}

/// GTK4 has no `gdk_clipboard_clear`; the documented way to relinquish
/// ownership is to set a NULL content provider.
static inline void swiftpwa_clipboard_clear(GdkClipboard *cb) {
    gdk_clipboard_set_content(cb, NULL);
}

// ---------------------------------------------------------------------
// Notifications (org.freedesktop.Notifications via D-Bus).
//
// Identical to the GTK3 shim — the freedesktop notification spec is
// independent of GTK version, and using GIO's D-Bus directly avoids a
// libnotify / libayatana-appindicator runtime dependency.
// ---------------------------------------------------------------------

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

    GVariant *actions_v = g_variant_new_strv(NULL, 0);

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
        (guint32)0,
        "",
        title ? title : "",
        body ? body : "",
        actions_v,
        hints_v,
        (gint32)-1
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

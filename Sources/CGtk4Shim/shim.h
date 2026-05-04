#ifndef SWIFT_PWA_GTK4_SHIM_H
#define SWIFT_PWA_GTK4_SHIM_H

#include <gtk/gtk.h>

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

#endif

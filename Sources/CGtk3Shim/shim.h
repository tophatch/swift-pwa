#ifndef SWIFT_PWA_GTK3_SHIM_H
#define SWIFT_PWA_GTK3_SHIM_H

#include <gtk/gtk.h>

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

#endif

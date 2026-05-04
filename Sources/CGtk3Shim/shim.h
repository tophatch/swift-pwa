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

// ---------------------------------------------------------------------
// Tray (GtkStatusIcon + GtkMenu).
//
// `GtkStatusIcon` is deprecated in GTK 3.14+ but is still the simplest
// system-tray surface that works on most desktops without dragging in
// libayatana-appindicator. We confine the entire state machine —
// status icon, currently-attached menu, signal trampolines — to the C
// shim and expose just an opaque `swiftpwa_tray *` plus a single event
// callback to Swift, so the deprecation warnings stay localized here
// (suppressed via the surrounding `_Pragma`).
// ---------------------------------------------------------------------

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

/// Tray-event kinds reported through the Swift callback.
///   0 = click on the icon (only when no menu is currently attached)
///   1 = menu item activated; `id` is the item's stable identifier
typedef void (*swiftpwa_tray_event_cb)(int kind, const char *id, void *user_data);

typedef struct _swiftpwa_tray {
    GtkStatusIcon *icon;
    GtkWidget *menu;       // currently-attached GtkMenu (or NULL)
    GtkWidget *pending;    // GtkMenu being built between clear + commit
    swiftpwa_tray_event_cb cb;
    void *user_data;
} swiftpwa_tray;

typedef struct {
    char *id;
    swiftpwa_tray *tray;
} swiftpwa_tray_item_box;

static void swiftpwa_tray_item_box_free(gpointer data, GClosure *closure) {
    (void)closure;
    swiftpwa_tray_item_box *b = (swiftpwa_tray_item_box *)data;
    if (b) { g_free(b->id); g_free(b); }
}

static void swiftpwa_tray_activate(GtkStatusIcon *icon, gpointer user_data) {
    (void)icon;
    swiftpwa_tray *t = (swiftpwa_tray *)user_data;
    if (t->menu) {
        // With a menu attached, treat left-click as a popup so the user
        // doesn't need to right-click on touchpad-only setups.
        gtk_menu_popup_at_pointer(GTK_MENU(t->menu), NULL);
    } else {
        t->cb(0, NULL, t->user_data);
    }
}

static void swiftpwa_tray_popup_menu(
    GtkStatusIcon *icon, guint button, guint time, gpointer user_data
) {
    (void)icon; (void)button; (void)time;
    swiftpwa_tray *t = (swiftpwa_tray *)user_data;
    if (t->menu) gtk_menu_popup_at_pointer(GTK_MENU(t->menu), NULL);
}

static void swiftpwa_tray_menu_item_activate(GtkMenuItem *item, gpointer user_data) {
    (void)item;
    swiftpwa_tray_item_box *b = (swiftpwa_tray_item_box *)user_data;
    if (b && b->tray) b->tray->cb(1, b->id, b->tray->user_data);
}

static inline swiftpwa_tray *swiftpwa_tray_new(
    swiftpwa_tray_event_cb cb, void *user_data
) {
    swiftpwa_tray *t = (swiftpwa_tray *)g_malloc0(sizeof(swiftpwa_tray));
    t->cb = cb;
    t->user_data = user_data;
    t->icon = gtk_status_icon_new();
    g_signal_connect(t->icon, "activate", G_CALLBACK(swiftpwa_tray_activate), t);
    g_signal_connect(t->icon, "popup-menu", G_CALLBACK(swiftpwa_tray_popup_menu), t);
    return t;
}

static inline void swiftpwa_tray_free(swiftpwa_tray *t) {
    if (!t) return;
    if (t->menu) gtk_widget_destroy(t->menu);
    if (t->pending) gtk_widget_destroy(t->pending);
    if (t->icon) g_object_unref(t->icon);
    g_free(t);
}

static inline void swiftpwa_tray_set_icon_path(swiftpwa_tray *t, const char *path) {
    if (t && t->icon) gtk_status_icon_set_from_file(t->icon, path);
}

static inline void swiftpwa_tray_set_tooltip(swiftpwa_tray *t, const char *text) {
    if (t && t->icon) gtk_status_icon_set_tooltip_text(t->icon, text);
}

static inline void swiftpwa_tray_set_visible(swiftpwa_tray *t, int visible) {
    if (t && t->icon) gtk_status_icon_set_visible(t->icon, visible ? TRUE : FALSE);
}

/// Begin building a new menu. Discards any in-progress draft.
static inline void swiftpwa_tray_menu_begin(swiftpwa_tray *t) {
    if (t->pending) gtk_widget_destroy(t->pending);
    t->pending = gtk_menu_new();
}

static inline void swiftpwa_tray_menu_append_item(
    swiftpwa_tray *t, const char *id, const char *label, int enabled
) {
    if (!t->pending) t->pending = gtk_menu_new();
    GtkWidget *item = gtk_menu_item_new_with_label(label);
    if (!enabled) gtk_widget_set_sensitive(item, FALSE);
    swiftpwa_tray_item_box *box =
        (swiftpwa_tray_item_box *)g_malloc0(sizeof(swiftpwa_tray_item_box));
    box->id = g_strdup(id ? id : "");
    box->tray = t;
    g_signal_connect_data(
        item, "activate",
        G_CALLBACK(swiftpwa_tray_menu_item_activate),
        box, swiftpwa_tray_item_box_free, 0
    );
    gtk_menu_shell_append(GTK_MENU_SHELL(t->pending), item);
    gtk_widget_show(item);
}

static inline void swiftpwa_tray_menu_append_separator(swiftpwa_tray *t) {
    if (!t->pending) t->pending = gtk_menu_new();
    GtkWidget *sep = gtk_separator_menu_item_new();
    gtk_menu_shell_append(GTK_MENU_SHELL(t->pending), sep);
    gtk_widget_show(sep);
}

/// Swap in the pending menu, destroying the previous one. If no items
/// were appended, removes any existing menu (left-click then emits a
/// `.click` event instead of opening a menu).
static inline void swiftpwa_tray_menu_commit(swiftpwa_tray *t) {
    if (t->menu) gtk_widget_destroy(t->menu);
    t->menu = t->pending;
    t->pending = NULL;
    if (t->menu) {
        // The menu was created floating; sink the ref so we own it
        // until our explicit destroy.
        g_object_ref_sink(t->menu);
    }
}

#pragma GCC diagnostic pop

#endif

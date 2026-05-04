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

#endif

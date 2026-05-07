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

/// Wire Ctrl+Alt+J on `grp` to invoke `cb(user_data)`. Mirror of
/// `swiftpwa_accel_connect_quit` but bound to the cross-platform
/// DevTools shortcut. `user_data` is typically the owning
/// `GTKWindow` pointer so the Swift trampoline can dispatch into
/// `webView.openDevTools()` on the right window.
static inline void swiftpwa_accel_connect_devtools(
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
        GDK_KEY_j,
        GDK_CONTROL_MASK | GDK_MOD1_MASK, /* Mod1 = Alt */
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
// Dialogs (GtkMessageDialog + GtkFileChooserDialog).
//
// Both APIs are variadic in C — `gtk_message_dialog_new(parent, flags,
// type, buttons, format, ...)` and `gtk_file_chooser_dialog_new(title,
// parent, action, button1, response1, ..., NULL)` — and Swift's clang
// importer does not surface variadic C functions cleanly, so we wrap
// each in a fixed-arity helper.
//
// The widgets returned are GObjects; Swift owns the reference and is
// expected to `gtk_widget_destroy` after `gtk_dialog_run` returns.
// ---------------------------------------------------------------------

/// Severity hint that maps onto `GtkMessageType`. Mirrors `DialogKind`
/// on the Swift side so we don't import the GTK enum directly.
typedef enum {
    SWIFTPWA_DIALOG_INFO = 0,
    SWIFTPWA_DIALOG_WARNING = 1,
    SWIFTPWA_DIALOG_ERROR = 2,
} swiftpwa_dialog_kind;

static inline GtkMessageType swiftpwa_dialog_message_type(swiftpwa_dialog_kind kind) {
    switch (kind) {
        case SWIFTPWA_DIALOG_WARNING: return GTK_MESSAGE_WARNING;
        case SWIFTPWA_DIALOG_ERROR:   return GTK_MESSAGE_ERROR;
        default:                      return GTK_MESSAGE_INFO;
    }
}

/// Create a one-button (OK) message dialog and run it modally. Caller
/// destroys the returned widget. Title is set on the underlying
/// `GtkWindow`; the message is the dialog's primary text. `parent` may
/// be NULL.
static inline GtkWidget *swiftpwa_message_dialog_new(
    GtkWindow *parent,
    swiftpwa_dialog_kind kind,
    const char *title,
    const char *message
) {
    GtkWidget *dialog = gtk_message_dialog_new(
        parent,
        GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT,
        swiftpwa_dialog_message_type(kind),
        GTK_BUTTONS_OK,
        "%s", message ? message : ""
    );
    if (title) gtk_window_set_title(GTK_WINDOW(dialog), title);
    return dialog;
}

/// Create a two-button (Cancel / OK) confirm dialog. `ok_label` /
/// `cancel_label` may be NULL to use the platform defaults. Returns
/// `TRUE` from `swiftpwa_dialog_run` when the user picks OK.
static inline GtkWidget *swiftpwa_confirm_dialog_new(
    GtkWindow *parent,
    swiftpwa_dialog_kind kind,
    const char *title,
    const char *message,
    const char *ok_label,
    const char *cancel_label
) {
    GtkWidget *dialog = gtk_message_dialog_new(
        parent,
        GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT,
        swiftpwa_dialog_message_type(kind),
        GTK_BUTTONS_NONE,
        "%s", message ? message : ""
    );
    gtk_dialog_add_button(
        GTK_DIALOG(dialog),
        cancel_label ? cancel_label : "_Cancel",
        GTK_RESPONSE_CANCEL
    );
    gtk_dialog_add_button(
        GTK_DIALOG(dialog),
        ok_label ? ok_label : "_OK",
        GTK_RESPONSE_OK
    );
    gtk_dialog_set_default_response(GTK_DIALOG(dialog), GTK_RESPONSE_OK);
    if (title) gtk_window_set_title(GTK_WINDOW(dialog), title);
    return dialog;
}

/// Run the dialog modally (nested main loop) and return the response
/// code. Pumps events on the GTK main thread; safe to call only from
/// the GTK main thread.
static inline int swiftpwa_dialog_run(GtkWidget *dialog) {
    return (int)gtk_dialog_run(GTK_DIALOG(dialog));
}

static inline void swiftpwa_widget_destroy(GtkWidget *widget) {
    gtk_widget_destroy(widget);
}

/// File-chooser actions. Matches `GtkFileChooserAction` constants.
typedef enum {
    SWIFTPWA_FILE_CHOOSER_OPEN = 0,
    SWIFTPWA_FILE_CHOOSER_SAVE = 1,
    SWIFTPWA_FILE_CHOOSER_SELECT_FOLDER = 2,
} swiftpwa_file_chooser_action;

static inline GtkFileChooserAction swiftpwa_file_chooser_action_map(
    swiftpwa_file_chooser_action action
) {
    switch (action) {
        case SWIFTPWA_FILE_CHOOSER_SAVE:          return GTK_FILE_CHOOSER_ACTION_SAVE;
        case SWIFTPWA_FILE_CHOOSER_SELECT_FOLDER: return GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER;
        default:                                  return GTK_FILE_CHOOSER_ACTION_OPEN;
    }
}

/// Create a file-chooser dialog with Cancel / OK buttons. The dialog
/// is wired in modal mode; the caller runs it via
/// `swiftpwa_dialog_run` (which returns `GTK_RESPONSE_OK` on success)
/// and reads the chosen path via `swiftpwa_file_chooser_get_filenames`
/// or `gtk_file_chooser_get_filename`.
static inline GtkWidget *swiftpwa_file_chooser_dialog_new(
    GtkWindow *parent,
    swiftpwa_file_chooser_action action,
    const char *title,
    int allow_multiple
) {
    GtkWidget *dialog = gtk_file_chooser_dialog_new(
        title ? title : "",
        parent,
        swiftpwa_file_chooser_action_map(action),
        "_Cancel", GTK_RESPONSE_CANCEL,
        action == SWIFTPWA_FILE_CHOOSER_SAVE ? "_Save" : "_Open", GTK_RESPONSE_OK,
        (const char *)NULL
    );
    if (allow_multiple) {
        gtk_file_chooser_set_select_multiple(GTK_FILE_CHOOSER(dialog), TRUE);
    }
    if (action == SWIFTPWA_FILE_CHOOSER_SAVE) {
        gtk_file_chooser_set_do_overwrite_confirmation(GTK_FILE_CHOOSER(dialog), TRUE);
    }
    return dialog;
}

static inline void swiftpwa_file_chooser_set_current_folder(GtkWidget *dialog, const char *folder) {
    if (folder) gtk_file_chooser_set_current_folder(GTK_FILE_CHOOSER(dialog), folder);
}

static inline void swiftpwa_file_chooser_set_current_name(GtkWidget *dialog, const char *name) {
    if (name) gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(dialog), name);
}

/// Add a file filter with `name` (e.g. "Images") and a list of glob
/// patterns (e.g. "*.png"). `patterns` is a NULL-terminated array of
/// C strings; each is added via `gtk_file_filter_add_pattern`.
static inline void swiftpwa_file_chooser_add_filter(
    GtkWidget *dialog,
    const char *name,
    const char *const *patterns
) {
    GtkFileFilter *filter = gtk_file_filter_new();
    if (name) gtk_file_filter_set_name(filter, name);
    if (patterns) {
        for (const char *const *p = patterns; *p; ++p) {
            gtk_file_filter_add_pattern(filter, *p);
        }
    }
    gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(dialog), filter);
}

/// Read all selected paths (single-select dialogs return one). Caller
/// receives a freshly-allocated NULL-terminated `char **` array; both
/// the array and the strings inside it are owned by the caller and
/// must be freed via `g_strfreev`. Returns NULL when no files were
/// selected.
static inline char **swiftpwa_file_chooser_get_filenames(GtkWidget *dialog) {
    GSList *list = gtk_file_chooser_get_filenames(GTK_FILE_CHOOSER(dialog));
    if (!list) return NULL;
    guint n = g_slist_length(list);
    char **out = (char **)g_malloc0(sizeof(char *) * (n + 1));
    guint i = 0;
    for (GSList *node = list; node; node = node->next) {
        out[i++] = (char *)node->data; /* Transfer ownership to `out`. */
    }
    g_slist_free(list); /* Items themselves are now owned by `out`. */
    return out;
}

/// Convenience for save dialogs / single-select directory pickers,
/// where the caller wants exactly one path. Returns a freshly
/// allocated string the caller must `g_free`, or NULL when nothing
/// was selected.
static inline char *swiftpwa_file_chooser_get_filename(GtkWidget *dialog) {
    return gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog));
}

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

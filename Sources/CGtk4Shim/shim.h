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

/// Install Ctrl+Alt+J on `window` to fire `cb(user_data)` — the
/// cross-platform DevTools accelerator. Same scope (global) as the
/// quit shortcut so it works while a focused webview input has
/// keyboard.
static inline void swiftpwa_window_install_devtools_shortcut(
    GtkWindow *window,
    swiftpwa_shortcut_callback cb,
    void *user_data
) {
    swiftpwa_shortcut_box *box = (swiftpwa_shortcut_box *)g_malloc0(sizeof(swiftpwa_shortcut_box));
    box->cb = cb;
    box->user_data = user_data;

    GtkShortcutTrigger *trigger = gtk_shortcut_trigger_parse_string("<Control><Alt>j");
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
// Dialogs (GtkAlertDialog + GtkFileDialog, GTK 4.10+).
//
// GTK4 dropped `GtkMessageDialog` and deprecated `gtk_dialog_run`; the
// modern alternatives (`GtkAlertDialog` / `GtkFileDialog`) are both
// async with `GAsyncReadyCallback` continuations and `_finish`
// completers, the same shape as the clipboard helpers above. We expose
// each `*_new` + `*_run` pair to Swift via a fixed-arity wrapper so
// the variadic / GListModel / GFile glue stays in C.
// ---------------------------------------------------------------------

typedef enum {
    SWIFTPWA_DIALOG_INFO = 0,
    SWIFTPWA_DIALOG_WARNING = 1,
    SWIFTPWA_DIALOG_ERROR = 2,
} swiftpwa_dialog_kind;

/// Result handed to alert / confirm callbacks. `button` is the index of
/// the chosen button (matches `gtk_alert_dialog_choose_finish`); -1 on
/// dismiss (Esc / window close).
typedef void (*swiftpwa_alert_callback)(int button, char *err, void *user_data);

typedef struct {
    swiftpwa_alert_callback cb;
    void *user_data;
} swiftpwa_alert_box;

static void swiftpwa_alert_finish(
    GObject *source,
    GAsyncResult *result,
    gpointer user_data
) {
    swiftpwa_alert_box *box = (swiftpwa_alert_box *)user_data;
    swiftpwa_alert_callback cb = box->cb;
    void *swift_ud = box->user_data;
    g_free(box);

    GError *error = NULL;
    int button = (int)gtk_alert_dialog_choose_finish(
        GTK_ALERT_DIALOG(source), result, &error
    );
    char *err_msg = NULL;
    if (error) {
        // GTK_DIALOG_ERROR_DISMISSED / _CANCELLED is the user pressing
        // Esc — surface it as `button = -1`, no error string. Other
        // errors flow through.
        if (error->domain == GTK_DIALOG_ERROR &&
            (error->code == GTK_DIALOG_ERROR_DISMISSED ||
             error->code == GTK_DIALOG_ERROR_CANCELLED)) {
            button = -1;
        } else {
            err_msg = g_strdup(error->message);
        }
        g_error_free(error);
    }
    cb(button, err_msg, swift_ud);
}

/// Run an alert / confirm dialog. `buttons` is a NULL-terminated array
/// of label strings. `default_btn` (-1 to skip) marks the "primary"
/// button; `cancel_btn` (-1 to skip) marks the "Esc dismisses to this
/// button" button.
static inline void swiftpwa_alert_dialog_run(
    GtkWindow *parent,
    swiftpwa_dialog_kind kind,
    const char *title,
    const char *message,
    const char *const *buttons,
    int default_btn,
    int cancel_btn,
    swiftpwa_alert_callback cb,
    void *user_data
) {
    GtkAlertDialog *dialog = gtk_alert_dialog_new("%s", message ? message : "");
    if (title) gtk_alert_dialog_set_message(dialog, title);
    if (title && message) gtk_alert_dialog_set_detail(dialog, message);
    gtk_alert_dialog_set_modal(dialog, TRUE);
    if (buttons) gtk_alert_dialog_set_buttons(dialog, buttons);
    if (default_btn >= 0) gtk_alert_dialog_set_default_button(dialog, default_btn);
    if (cancel_btn >= 0) gtk_alert_dialog_set_cancel_button(dialog, cancel_btn);
    (void)kind; /* GtkAlertDialog has no severity hint; reserved for future use. */

    swiftpwa_alert_box *box = (swiftpwa_alert_box *)g_malloc0(sizeof(swiftpwa_alert_box));
    box->cb = cb;
    box->user_data = user_data;
    gtk_alert_dialog_choose(dialog, parent, NULL, swiftpwa_alert_finish, box);
    g_object_unref(dialog);
}

// File-dialog actions (mirrors the GTK3 shim's enum).
typedef enum {
    SWIFTPWA_FILE_DIALOG_OPEN = 0,
    SWIFTPWA_FILE_DIALOG_SAVE = 1,
    SWIFTPWA_FILE_DIALOG_SELECT_FOLDER = 2,
    SWIFTPWA_FILE_DIALOG_OPEN_MULTIPLE = 3,
    SWIFTPWA_FILE_DIALOG_SELECT_FOLDER_MULTIPLE = 4,
} swiftpwa_file_dialog_action;

/// Result handed to file-dialog callbacks. On success, `paths` is a
/// freshly-allocated NULL-terminated array of C strings (the callee
/// owns it; free with `g_strfreev`). On failure / cancel, `paths` is
/// NULL. `err` is non-NULL only on a real error (cancel surfaces as
/// `paths == NULL`, `err == NULL`); when it's set, the callee owns
/// the string.
typedef void (*swiftpwa_file_dialog_callback)(char **paths, char *err, void *user_data);

typedef struct {
    swiftpwa_file_dialog_action action;
    swiftpwa_file_dialog_callback cb;
    void *user_data;
} swiftpwa_file_dialog_box;

static char *swiftpwa_file_to_path(GFile *file) {
    if (!file) return NULL;
    return g_file_get_path(file);
}

static void swiftpwa_file_dialog_finish(
    GObject *source,
    GAsyncResult *result,
    gpointer user_data
) {
    swiftpwa_file_dialog_box *box = (swiftpwa_file_dialog_box *)user_data;
    swiftpwa_file_dialog_callback cb = box->cb;
    void *swift_ud = box->user_data;
    swiftpwa_file_dialog_action action = box->action;
    g_free(box);

    GError *error = NULL;
    char **paths = NULL;
    char *err_msg = NULL;
    GtkFileDialog *dialog = GTK_FILE_DIALOG(source);

    if (action == SWIFTPWA_FILE_DIALOG_OPEN_MULTIPLE ||
        action == SWIFTPWA_FILE_DIALOG_SELECT_FOLDER_MULTIPLE) {
        GListModel *model = (action == SWIFTPWA_FILE_DIALOG_SELECT_FOLDER_MULTIPLE)
            ? gtk_file_dialog_select_multiple_folders_finish(dialog, result, &error)
            : gtk_file_dialog_open_multiple_finish(dialog, result, &error);
        if (model) {
            guint n = g_list_model_get_n_items(model);
            paths = (char **)g_malloc0(sizeof(char *) * (n + 1));
            for (guint i = 0; i < n; ++i) {
                GFile *f = (GFile *)g_list_model_get_item(model, i);
                paths[i] = swiftpwa_file_to_path(f);
                if (f) g_object_unref(f);
            }
            g_object_unref(model);
        }
    } else {
        GFile *file = NULL;
        switch (action) {
            case SWIFTPWA_FILE_DIALOG_OPEN:
                file = gtk_file_dialog_open_finish(dialog, result, &error);
                break;
            case SWIFTPWA_FILE_DIALOG_SAVE:
                file = gtk_file_dialog_save_finish(dialog, result, &error);
                break;
            case SWIFTPWA_FILE_DIALOG_SELECT_FOLDER:
                file = gtk_file_dialog_select_folder_finish(dialog, result, &error);
                break;
            default: break;
        }
        if (file) {
            paths = (char **)g_malloc0(sizeof(char *) * 2);
            paths[0] = swiftpwa_file_to_path(file);
            paths[1] = NULL;
            g_object_unref(file);
        }
    }

    if (error) {
        // Same dismissed/cancelled handling as the alert shim — surface
        // it as a plain "no selection" rather than an error string so
        // the Swift side can branch on `paths == NULL`.
        if (!(error->domain == GTK_DIALOG_ERROR &&
              (error->code == GTK_DIALOG_ERROR_DISMISSED ||
               error->code == GTK_DIALOG_ERROR_CANCELLED))) {
            err_msg = g_strdup(error->message);
        }
        g_error_free(error);
    }
    cb(paths, err_msg, swift_ud);
}

/// Build a `GListStore` of `GtkFileFilter` from a list of (name,
/// patterns) pairs. `filter_names` and `filter_patterns` are parallel
/// arrays of length `n_filters`; each `filter_patterns[i]` is itself a
/// NULL-terminated C-string array. The returned store has one ref;
/// `gtk_file_dialog_set_filters` will retain it as needed.
static inline GListStore *swiftpwa_file_dialog_build_filters(
    int n_filters,
    const char *const *filter_names,
    const char *const *const *filter_patterns
) {
    if (n_filters <= 0) return NULL;
    GListStore *store = g_list_store_new(GTK_TYPE_FILE_FILTER);
    for (int i = 0; i < n_filters; ++i) {
        GtkFileFilter *f = gtk_file_filter_new();
        if (filter_names && filter_names[i]) {
            gtk_file_filter_set_name(f, filter_names[i]);
        }
        if (filter_patterns && filter_patterns[i]) {
            for (const char *const *p = filter_patterns[i]; *p; ++p) {
                gtk_file_filter_add_pattern(f, *p);
            }
        }
        g_list_store_append(store, f);
        g_object_unref(f);
    }
    return store;
}

/// Run a file dialog (`open` / `save` / `select_folder` /
/// `open_multiple`). `initial_folder` and `initial_name` may be NULL.
/// `filters` may be NULL (no filtering). The callback fires on the
/// GMainContext active when this is called (i.e. the GTK main thread,
/// since `MainThread.run` got us here).
static inline void swiftpwa_file_dialog_run(
    GtkWindow *parent,
    swiftpwa_file_dialog_action action,
    const char *title,
    const char *initial_folder,
    const char *initial_name,
    GListStore *filters,
    swiftpwa_file_dialog_callback cb,
    void *user_data
) {
    GtkFileDialog *dialog = gtk_file_dialog_new();
    if (title) gtk_file_dialog_set_title(dialog, title);
    if (initial_folder) {
        GFile *f = g_file_new_for_path(initial_folder);
        gtk_file_dialog_set_initial_folder(dialog, f);
        g_object_unref(f);
    }
    if (initial_name) gtk_file_dialog_set_initial_name(dialog, initial_name);
    if (filters) gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));

    swiftpwa_file_dialog_box *box = (swiftpwa_file_dialog_box *)g_malloc0(sizeof(swiftpwa_file_dialog_box));
    box->action = action;
    box->cb = cb;
    box->user_data = user_data;

    switch (action) {
        case SWIFTPWA_FILE_DIALOG_OPEN:
            gtk_file_dialog_open(dialog, parent, NULL, swiftpwa_file_dialog_finish, box);
            break;
        case SWIFTPWA_FILE_DIALOG_OPEN_MULTIPLE:
            gtk_file_dialog_open_multiple(dialog, parent, NULL, swiftpwa_file_dialog_finish, box);
            break;
        case SWIFTPWA_FILE_DIALOG_SAVE:
            gtk_file_dialog_save(dialog, parent, NULL, swiftpwa_file_dialog_finish, box);
            break;
        case SWIFTPWA_FILE_DIALOG_SELECT_FOLDER:
            gtk_file_dialog_select_folder(dialog, parent, NULL, swiftpwa_file_dialog_finish, box);
            break;
        case SWIFTPWA_FILE_DIALOG_SELECT_FOLDER_MULTIPLE:
            gtk_file_dialog_select_multiple_folders(dialog, parent, NULL, swiftpwa_file_dialog_finish, box);
            break;
    }
    g_object_unref(dialog);
    if (filters) g_object_unref(filters);
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

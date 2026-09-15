#ifndef SWIFT_PWA_GTK4_SHIM_H
#define SWIFT_PWA_GTK4_SHIM_H

#include <gtk/gtk.h>
#include <gio/gio.h>
// `g_unix_fd_add`, used to watch libdispatch's main-queue eventfd from
// the GTK main loop so an app's own `@MainActor` code runs (#216).
#include <glib-unix.h>

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

/// Swift-side undo/redo callback: `redo` is non-zero for Ctrl+Shift+Z.
typedef void (*swiftpwa_undo_callback)(void *user_data, int redo);

typedef struct {
    swiftpwa_undo_callback cb;
    void *user_data;
} swiftpwa_undo_box;

static void swiftpwa_undo_box_free(gpointer data) {
    g_free(data);
}

static gboolean swiftpwa_undo_key_pressed(
    GtkEventControllerKey *controller,
    guint keyval,
    guint keycode,
    GdkModifierType state,
    gpointer user_data
) {
    (void)controller;
    (void)keycode;
    swiftpwa_undo_box *box = (swiftpwa_undo_box *)user_data;
    if (!box) return FALSE;
    if (!(state & GDK_CONTROL_MASK)) return FALSE;
    if (gdk_keyval_to_lower(keyval) != GDK_KEY_z) return FALSE;
    box->cb(box->user_data, (state & GDK_SHIFT_MASK) ? 1 : 0);
    return TRUE;
}

/// Wire Ctrl+Z / Ctrl+Shift+Z on `window` to `cb`, **after** the page has had
/// its chance.
///
/// Deliberately a key controller in the **bubble** phase rather than a
/// `GtkShortcutController` like the quit / DevTools bindings. Those use
/// `GTK_SHORTCUT_SCOPE_GLOBAL` precisely so they fire over a focused text
/// input; undo must not, or a page implementing its own — a drawing or editing
/// app, the kind most likely to want Ctrl+Z — would never see the key. Bubble
/// runs after the focused widget (the WebKit view, which asks the page), so
/// this only fires on a key nothing else claimed. That matches macOS, where
/// the page keeps a Cmd+Z it calls `preventDefault` on.
static inline void swiftpwa_window_connect_undo(
    GtkWindow *window,
    swiftpwa_undo_callback cb,
    void *user_data
) {
    swiftpwa_undo_box *box = (swiftpwa_undo_box *)g_malloc0(sizeof(swiftpwa_undo_box));
    box->cb = cb;
    box->user_data = user_data;

    GtkEventController *ctrl = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(ctrl, GTK_PHASE_BUBBLE);
    g_signal_connect_data(
        ctrl,
        "key-pressed",
        G_CALLBACK(swiftpwa_undo_key_pressed),
        box,
        (GClosureNotify)swiftpwa_undo_box_free,
        (GConnectFlags)0
    );
    gtk_widget_add_controller(GTK_WIDGET(window), ctrl);
}

/// GDK keyval for a key name ("Return", "Left") — 0 if GDK doesn't know it.
/// Wrapped because the GTK4 backend has no other reason to import gdkkeysyms.
static inline unsigned int swiftpwa_gtk4_keyval_from_name(const char *name) {
    return (unsigned int)gdk_keyval_from_name(name);
}

/// GDK keyval for a Unicode scalar — how an ordinary character is spelled.
static inline unsigned int swiftpwa_gtk4_keyval_from_unicode(unsigned int scalar) {
    return (unsigned int)gdk_unicode_to_keyval((guint32)scalar);
}

// MARK: - Synthetic input (app driver)
//
// GTK4 removed every way to fabricate an event: `GdkEvent` is opaque with no
// public constructors, and `gtk_main_do_event` is gone. `gdk_display_put_event`
// survives with nothing to put in it. So unlike the GTK3 backend — which pushes
// events straight into GTK's own dispatch — the only route left on GTK4 is the
// display server's own test extension, XTEST.
//
// That is a genuinely different kind of input and the capability report says so:
// XTEST events enter at the *server*, so the target window has to hold input
// focus and the real pointer really moves. It also means X11 only; a native
// Wayland session can't be driven this way (XWayland clients can). Under Xvfb —
// where CI runs, and where there is no input device at all — it works, which is
// the case this exists for.
//
// libXtst is loaded with `dlopen` rather than linked: it is not a GTK
// dependency, and making the whole Linux backend fail to link on a box without
// it would be a poor trade for a dev-only verb. Absent, the backend reports no
// input support and every request is refused rather than silently dropped.

#ifdef GDK_WINDOWING_X11

#include <dlfcn.h>

// X11 and GDK-X11 are declared here by hand rather than by including
// <gdk/x11/gdkx.h>.
//
// That header drags in Xlib.h, which typedefs `Window` — and the Swift importer
// exports every name in this module, so `Window` then collides with swift-pwa's
// own `Window` protocol and *every* Linux file referring to one stops compiling
// with "'Window' is ambiguous for type lookup". Declaring the four symbols we
// use keeps X11's namespace out of Swift entirely. `Display *` is opaque to us,
// so `void *` is ABI-identical, and an XID is an `unsigned long` by definition.
extern void *gdk_x11_display_get_xdisplay(GdkDisplay *display);
extern unsigned long gdk_x11_surface_get_xid(GdkSurface *surface);

typedef int (*swiftpwa_xtest_key_fn)(void *, unsigned int, int, unsigned long);
typedef int (*swiftpwa_xtest_button_fn)(void *, unsigned int, int, unsigned long);
typedef int (*swiftpwa_xtest_motion_fn)(void *, int, int, int, unsigned long);
typedef unsigned long (*swiftpwa_x_root_fn)(void *);
typedef int (*swiftpwa_x_translate_fn)(
    void *, unsigned long, unsigned long, int, int, int *, int *, unsigned long *);

typedef struct {
    int loaded;                       // 1 once we've tried; 0 before
    swiftpwa_xtest_key_fn key;
    swiftpwa_xtest_button_fn button;
    swiftpwa_xtest_motion_fn motion;
    swiftpwa_x_root_fn root;
    swiftpwa_x_translate_fn translate;
} swiftpwa_xtest_api;

static swiftpwa_xtest_api swiftpwa_xtest = {0, NULL, NULL, NULL, NULL, NULL};

/// Resolve XTEST once. Every symbol has to be present or the whole thing stays
/// unavailable: a half-loaded API would let a key event through and drop a
/// pointer event, which is worse than refusing both.
static void swiftpwa_xtest_load(void) {
    if (swiftpwa_xtest.loaded) return;
    swiftpwa_xtest.loaded = 1;

    void *xtst = dlopen("libXtst.so.6", RTLD_LAZY | RTLD_LOCAL);
    if (!xtst) return;
    // libX11 is already in the process — GTK's X11 backend links it — so this
    // hands back the same instance rather than a second copy.
    void *x11 = dlopen("libX11.so.6", RTLD_LAZY | RTLD_LOCAL);
    if (!x11) return;

    swiftpwa_xtest.key = (swiftpwa_xtest_key_fn)dlsym(xtst, "XTestFakeKeyEvent");
    swiftpwa_xtest.button = (swiftpwa_xtest_button_fn)dlsym(xtst, "XTestFakeButtonEvent");
    swiftpwa_xtest.motion = (swiftpwa_xtest_motion_fn)dlsym(xtst, "XTestFakeMotionEvent");
    swiftpwa_xtest.root = (swiftpwa_x_root_fn)dlsym(x11, "XDefaultRootWindow");
    swiftpwa_xtest.translate = (swiftpwa_x_translate_fn)dlsym(x11, "XTranslateCoordinates");

    if (!swiftpwa_xtest.key || !swiftpwa_xtest.button || !swiftpwa_xtest.motion
        || !swiftpwa_xtest.root || !swiftpwa_xtest.translate) {
        swiftpwa_xtest.key = NULL;
        swiftpwa_xtest.button = NULL;
        swiftpwa_xtest.motion = NULL;
    }
}

/// `GDK_IS_X11_DISPLAY` without the header: the X11 backend registers its
/// GTypes by name whether or not we can see the macro.
static int swiftpwa_is_gtype(gpointer instance, const char *type_name) {
    if (!instance) return 0;
    GType wanted = g_type_from_name(type_name);
    return wanted != 0 && g_type_is_a(G_OBJECT_TYPE(instance), wanted);
}

static void *swiftpwa_xdisplay(GtkWidget *widget) {
    GdkDisplay *display = gtk_widget_get_display(widget);
    if (!swiftpwa_is_gtype(display, "GdkX11Display")) return NULL;
    return gdk_x11_display_get_xdisplay(display);
}

/// The keycode carrying `keyval` on the active keymap, and (if `level` is
/// non-NULL) the shift level it sits at — 0 if the layout has no key for it.
///
/// GDK's keymap rather than `XKeysymToKeycode`: it answers the level too, and
/// it costs no link-time dependency on libX11. The level matters because a
/// keysym reachable only with Shift held needs Shift actually pressed, or the
/// server delivers the unshifted character and a test asserting on `:` quietly
/// receives `;`.
static unsigned int swiftpwa_x11_keycode(GdkDisplay *display, unsigned int keyval, int *level) {
    GdkKeymapKey *keys = NULL;
    int n_keys = 0;
    if (!gdk_display_map_keyval(display, keyval, &keys, &n_keys) || n_keys == 0) {
        g_free(keys);
        return 0;
    }
    unsigned int keycode = (unsigned int)keys[0].keycode;
    if (level) *level = keys[0].level;
    g_free(keys);
    return keycode;
}

/// Whether this build, this box and this session can synthesize input.
///
/// All three have to hold: the X11 backend compiled into GDK, libXtst present,
/// and the app actually running on X11 rather than Wayland. A Wayland session
/// answers 0 even though the first two are true.
static inline int swiftpwa_x11_input_available(GtkWidget *widget) {
    swiftpwa_xtest_load();
    if (!swiftpwa_xtest.key) return 0;
    return swiftpwa_xdisplay(widget) != NULL;
}

/// Press (`phase` 0) or release (`phase` 1) the key carrying `keyval`.
///
/// Returns 0 if the keyval isn't on the active keymap at all.
static inline int swiftpwa_x11_send_key(
    GtkWidget *widget, int phase, unsigned int keyval, unsigned int gdk_state
) {
    swiftpwa_xtest_load();
    void *dpy = swiftpwa_xdisplay(widget);
    if (!dpy || !swiftpwa_xtest.key) return 0;

    GdkDisplay *display = gtk_widget_get_display(widget);
    int level = 0;
    unsigned int keycode = swiftpwa_x11_keycode(display, keyval, &level);
    if (keycode == 0) return 0;

    // Modifiers are pressed around the key the way a keyboard produces them,
    // rather than passed as a state mask: XTEST has no state field, the server
    // derives it from which modifier keys are physically down.
    unsigned int mods[4];
    int n_mods = 0;
    if ((gdk_state & GDK_CONTROL_MASK) != 0) {
        mods[n_mods++] = swiftpwa_x11_keycode(display, GDK_KEY_Control_L, NULL);
    }
    if ((gdk_state & GDK_SHIFT_MASK) != 0 || level > 0) {
        mods[n_mods++] = swiftpwa_x11_keycode(display, GDK_KEY_Shift_L, NULL);
    }
    if ((gdk_state & GDK_ALT_MASK) != 0) {
        mods[n_mods++] = swiftpwa_x11_keycode(display, GDK_KEY_Alt_L, NULL);
    }
    if ((gdk_state & GDK_SUPER_MASK) != 0) {
        mods[n_mods++] = swiftpwa_x11_keycode(display, GDK_KEY_Super_L, NULL);
    }
    // A modifier missing from the keymap would otherwise be sent as keycode 0,
    // which the server reads as a real key and delivers as nonsense.
    for (int i = 0; i < n_mods; i++) {
        if (mods[i] == 0) return 0;
    }

    if (phase == 0) {
        for (int i = 0; i < n_mods; i++) swiftpwa_xtest.key(dpy, mods[i], 1, 0);
        swiftpwa_xtest.key(dpy, keycode, 1, 0);
    } else {
        swiftpwa_xtest.key(dpy, keycode, 0, 0);
        for (int i = n_mods - 1; i >= 0; i--) swiftpwa_xtest.key(dpy, mods[i], 0, 0);
    }
    gdk_display_flush(display);
    return 1;
}

/// Press / release / move the pointer at widget-relative `x`,`y`.
///
/// XTEST takes root-window coordinates, so the widget's position on screen has
/// to be resolved for real — the surface's X id plus the widget's offset inside
/// it, scaled to device pixels. Guessing any part of that lands the click
/// somewhere else on a HiDPI display or under a header bar.
static inline int swiftpwa_x11_send_pointer(
    GtkWidget *widget, int phase, double x, double y, int button
) {
    swiftpwa_xtest_load();
    void *dpy = swiftpwa_xdisplay(widget);
    if (!dpy || !swiftpwa_xtest.motion) return 0;

    GtkNative *native = gtk_widget_get_native(widget);
    if (!native) return 0;
    GdkSurface *surface = gtk_native_get_surface(native);
    if (!swiftpwa_is_gtype(surface, "GdkX11Surface")) return 0;

    // Widget-local to surface-local: the widget sits below a header bar, and
    // the native's own origin is offset inside the surface again.
    graphene_point_t local = GRAPHENE_POINT_INIT((float)x, (float)y);
    graphene_point_t in_native;
    if (!gtk_widget_compute_point(widget, GTK_WIDGET(native), &local, &in_native)) return 0;
    double nx = 0, ny = 0;
    gtk_native_get_surface_transform(native, &nx, &ny);

    int scale = gdk_surface_get_scale_factor(surface);
    if (scale < 1) scale = 1;
    int sx = (int)((in_native.x + nx) * scale);
    int sy = (int)((in_native.y + ny) * scale);

    unsigned long xid = gdk_x11_surface_get_xid(surface);
    unsigned long root = swiftpwa_xtest.root(dpy);
    int rx = 0, ry = 0;
    unsigned long child = 0;
    if (!swiftpwa_xtest.translate(dpy, xid, root, sx, sy, &rx, &ry, &child)) return 0;

    // Move first even for a press: XTEST's button event carries no position, so
    // the server uses wherever the pointer already is.
    swiftpwa_xtest.motion(dpy, -1, rx, ry, 0);
    if (phase == 0) {
        swiftpwa_xtest.button(dpy, (unsigned int)button, 1, 0);
    } else if (phase == 1) {
        swiftpwa_xtest.button(dpy, (unsigned int)button, 0, 0);
    }
    gdk_display_flush(gtk_widget_get_display(widget));
    return 1;
}

/// A wheel notch. X11 has no scroll axis — buttons 4/5 are up/down and 6/7 are
/// left/right — so a pixel delta becomes a count of clicks.
static inline int swiftpwa_x11_send_scroll(
    GtkWidget *widget, double x, double y, int button, int clicks
) {
    swiftpwa_xtest_load();
    void *dpy = swiftpwa_xdisplay(widget);
    if (!dpy || !swiftpwa_xtest.button) return 0;
    if (!swiftpwa_x11_send_pointer(widget, 2, x, y, 1)) return 0;
    for (int i = 0; i < clicks; i++) {
        swiftpwa_xtest.button(dpy, (unsigned int)button, 1, 0);
        swiftpwa_xtest.button(dpy, (unsigned int)button, 0, 0);
    }
    gdk_display_flush(gtk_widget_get_display(widget));
    return 1;
}

#else

// GDK without its X11 backend: nothing here can work, and saying so lets the
// Swift side report no input support rather than fail to compile.
static inline int swiftpwa_x11_input_available(GtkWidget *widget) { (void)widget; return 0; }
static inline int swiftpwa_x11_send_key(
    GtkWidget *widget, int phase, unsigned int keyval, unsigned int gdk_state
) { (void)widget; (void)phase; (void)keyval; (void)gdk_state; return 0; }
static inline int swiftpwa_x11_send_pointer(
    GtkWidget *widget, int phase, double x, double y, int button
) { (void)widget; (void)phase; (void)x; (void)y; (void)button; return 0; }
static inline int swiftpwa_x11_send_scroll(
    GtkWidget *widget, double x, double y, int button, int clicks
) { (void)widget; (void)x; (void)y; (void)button; (void)clicks; return 0; }

#endif // GDK_WINDOWING_X11

#endif

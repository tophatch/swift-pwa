#ifndef SWIFT_PWA_AYATANA_APPINDICATOR3_SHIM_H
#define SWIFT_PWA_AYATANA_APPINDICATOR3_SHIM_H

// `libayatana-appindicator` requires GTK3; it transitively pulls in
// `<gtk/gtk.h>` via its own headers, so the GtkMenu helpers below
// resolve naturally.
#include <libayatana-appindicator/app-indicator.h>
// Arrives transitively through GTK, but this file calls GDBus directly.
#include <gio/gio.h>

// ---------------------------------------------------------------------
// Tray (StatusNotifierItem via libayatana-appindicator3 + GtkMenu).
//
// Replaces the legacy `GtkStatusIcon` path that lived in CGtk3Shim.
// AppIndicator publishes the icon over D-Bus per the SNI spec, which
// is what GNOME, Plasma, Sway, Hyprland, XFCE/SNI, etc. consume; on
// legacy Xembed-only desktops the library falls back to drawing a
// `GtkStatusIcon` itself, so this shim works on every target where
// the old code did, plus GNOME and Wayland.
//
// The GTK4 backend cannot use this shim — `libayatana-appindicator3`
// is built against GTK3, and a single process cannot link both GTK3
// and GTK4. The GTK4 `SystemTray` stays a no-op stub until
// `libayatana-appindicator-gtk4` becomes broadly packaged.
// ---------------------------------------------------------------------

/// Tray-event kinds reported through the Swift callback.
///   0 = click on the icon — never emitted under AppIndicator. The SNI
///       spec gives the desktop panel ownership of click semantics; only
///       menu-item activations reach the app. Reserved for parity with
///       Apple, where the click path is still meaningful.
///   1 = menu item activated; `id` is the item's stable identifier.
typedef void (*swiftpwa_tray_event_cb)(int kind, const char *id, void *user_data);

typedef struct _swiftpwa_tray {
    AppIndicator *indicator;
    GtkWidget *menu;       // currently-attached GtkMenu (always non-NULL after _new)
    GtkWidget *pending;    // GtkMenu being built between begin + commit
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

static void swiftpwa_tray_menu_item_activate(GtkMenuItem *item, gpointer user_data) {
    (void)item;
    swiftpwa_tray_item_box *b = (swiftpwa_tray_item_box *)user_data;
    if (b && b->tray) b->tray->cb(1, b->id, b->tray->user_data);
}

/// Distinguishes indicators within one process — see `swiftpwa_tray_new`.
static int swiftpwa_tray_instance_seq = 0;

static inline swiftpwa_tray *swiftpwa_tray_new(
    swiftpwa_tray_event_cb cb, void *user_data
) {
    swiftpwa_tray *t = (swiftpwa_tray *)g_malloc0(sizeof(swiftpwa_tray));
    t->cb = cb;
    t->user_data = user_data;
    // The id has to be unique per indicator, not per app. libayatana derives
    // the item's D-Bus object path from it (`/org/ayatana/NotificationItem/<id>`),
    // so a second indicator built with the same id lands on the path the first
    // one already registered, and the panel is only ever told about one of them.
    // An app with its own tray plus the runtime's agent indicator is exactly
    // that case: the indicator registered nothing and the user saw no sign that
    // agent access was open.
    char id[64];
    int seq = ++swiftpwa_tray_instance_seq;
    if (seq == 1) {
        // The first keeps the bare id: it's the app's own tray, and a stable
        // path is what a panel remembers position and visibility against.
        g_strlcpy(id, "swift-pwa", sizeof(id));
    } else {
        g_snprintf(id, sizeof(id), "swift-pwa-%d", seq);
    }
    t->indicator = app_indicator_new(
        id,
        "",                                          // icon name (set later)
        APP_INDICATOR_CATEGORY_APPLICATION_STATUS
    );
    app_indicator_set_status(t->indicator, APP_INDICATOR_STATUS_ACTIVE);
    // AppIndicator requires a menu to display; install an empty
    // placeholder so the icon shows up before the user calls setMenu.
    GtkWidget *empty = gtk_menu_new();
    g_object_ref_sink(empty);
    app_indicator_set_menu(t->indicator, GTK_MENU(empty));
    t->menu = empty;
    return t;
}

static inline void swiftpwa_tray_free(swiftpwa_tray *t) {
    if (!t) return;
    if (t->menu) g_object_unref(t->menu);
    if (t->pending) {
        // Pending menus are still floating; sink + unref to free.
        g_object_ref_sink(t->pending);
        g_object_unref(t->pending);
    }
    if (t->indicator) g_object_unref(t->indicator);
    g_free(t);
}

static inline void swiftpwa_tray_set_icon_path(swiftpwa_tray *t, const char *path) {
    if (t && t->indicator) app_indicator_set_icon_full(t->indicator, path, "swift-pwa");
}

static inline void swiftpwa_tray_set_tooltip(swiftpwa_tray *t, const char *text) {
    // SNI doesn't have a real tooltip; `set_title` populates the
    // accessible label, which some panels surface as a tooltip / a11y
    // label. Best-effort.
    if (t && t->indicator) app_indicator_set_title(t->indicator, text);
}

static inline void swiftpwa_tray_set_visible(swiftpwa_tray *t, int visible) {
    if (t && t->indicator) {
        app_indicator_set_status(
            t->indicator,
            visible ? APP_INDICATOR_STATUS_ACTIVE : APP_INDICATOR_STATUS_PASSIVE
        );
    }
}

/// Begin building a new menu. Discards any in-progress draft.
static inline void swiftpwa_tray_menu_begin(swiftpwa_tray *t) {
    if (t->pending) {
        g_object_ref_sink(t->pending);
        g_object_unref(t->pending);
    }
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

/// Swap in the pending menu, replacing the previous one. If no items
/// were appended, installs a fresh empty menu (AppIndicator requires
/// a non-NULL menu).
static inline void swiftpwa_tray_menu_commit(swiftpwa_tray *t) {
    GtkWidget *new_menu = t->pending ? t->pending : gtk_menu_new();
    g_object_ref_sink(new_menu);
    if (t->indicator) {
        app_indicator_set_menu(t->indicator, GTK_MENU(new_menu));
    }
    if (t->menu) g_object_unref(t->menu);
    t->menu = new_menu;
    t->pending = NULL;
}


// ---------------------------------------------------------------------
// Panel-theme detection, for tray art that has to read against it.
//
// Nothing on Linux tints a tray icon the way AppKit tints a macOS
// template image, so art drawn as a black silhouette disappears against
// a dark panel. There's no way to ask what colour the panel *is* — the
// closest portable signal is the XDG desktop portal's
// `org.freedesktop.appearance` / `color-scheme` preference.
//
// Returns 1 to draw light art, 0 to draw dark art. There is no "don't
// know": a missing portal, a missing Settings backend and a missing
// session bus all mean the same thing in practice — we have to pick, and
// light is the better pick (below).
//
// The mapping is deliberately asymmetric. `color-scheme` is 0 (no
// preference), 1 (prefer dark) or 2 (prefer light), and it describes the
// user's *app* theme rather than the panel: GNOME's top bar is dark in
// both modes, and most other default panels are dark too. So only an
// explicit "prefer light" earns dark ink; no preference, no portal and no
// session bus all fall through to light, which is the better guess far
// more often than not. A light panel with no portal is the case this gets
// wrong, and it's the rarer one.
//
// Duplicated verbatim in `CStatusNotifierShim` — the two Linux backends
// are parallel implementations that already carry two copies of the whole
// `swiftpwa_tray_*` API, and one shared C target for 30 lines would be a
// worse trade than the copy. Change both.
// ---------------------------------------------------------------------

/// Peel nested variants until something that isn't a variant falls out.
/// `ReadOne` returns the value boxed once; the older `Read` boxes it
/// twice, and implementations have differed on this.
static inline GVariant *swiftpwa_unbox_variant(GVariant *v) {
    while (v && g_variant_is_of_type(v, G_VARIANT_TYPE_VARIANT)) {
        GVariant *inner = g_variant_get_variant(v);
        g_variant_unref(v);
        v = inner;
    }
    return v;
}

static inline int swiftpwa_prefers_light_art(void) {
    GError *error = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!bus) {
        g_clear_error(&error);
        return 1;
    }

    // A short timeout on purpose: this runs on the UI thread when the art
    // changes, and a desktop with no Settings backend should cost a blink,
    // not a stall.
    GVariant *reply = NULL;
    const char *methods[] = { "ReadOne", "Read" };  // Read: portals < 1.17
    for (int i = 0; i < 2 && !reply; i++) {
        reply = g_dbus_connection_call_sync(
            bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.Settings", methods[i],
            g_variant_new("(ss)", "org.freedesktop.appearance", "color-scheme"),
            G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 300, NULL, &error);
        if (!reply) g_clear_error(&error);
    }
    g_object_unref(bus);
    if (!reply) return 1;

    GVariant *value = swiftpwa_unbox_variant(g_variant_get_child_value(reply, 0));
    g_variant_unref(reply);
    if (!value) return 1;

    int scheme = -1;
    if (g_variant_is_of_type(value, G_VARIANT_TYPE_UINT32)) {
        scheme = (int)g_variant_get_uint32(value);
    } else if (g_variant_is_of_type(value, G_VARIANT_TYPE_INT32)) {
        scheme = g_variant_get_int32(value);
    }
    g_variant_unref(value);
    return scheme == 2 ? 0 : 1;   // 2 = prefer light; everything else => light art
}

#endif

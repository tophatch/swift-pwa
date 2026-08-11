#ifndef SWIFT_PWA_STATUS_NOTIFIER_SHIM_H
#define SWIFT_PWA_STATUS_NOTIFIER_SHIM_H

// ---------------------------------------------------------------------
// Tray (StatusNotifierItem + com.canonical.dbusmenu, hand-rolled over
// GDBus) for the GTK4 backend.
//
// GTK4 removed `GtkStatusIcon`, and the GTK3 tray is built on
// `libayatana-appindicator3`, which links GTK3 — a single process can't
// link both GTK3 and GTK4. `libayatana-appindicator-gtk4` isn't packaged
// on target distros. But `libayatana-appindicator` is only a thin wrapper
// over two freedesktop D-Bus protocols — StatusNotifierItem (SNI) and
// com.canonical.dbusmenu — and GDBus (gio-2.0) + GdkPixbuf are already
// linked by the GTK4 backend. So this shim speaks those protocols
// directly, with no external tray dependency.
//
// It exposes the *same* `swiftpwa_tray_*` C API as the GTK3
// AppIndicator shim (`CAyatanaAppIndicator3Shim`), so the GTK4
// `SystemTray.swift` is a near-copy of the GTK3 one.
//
// Menu model is flat: a list of items (label + stable string id +
// enabled) and separators. No submenus.
//
// Threading: every GDBus callback here (name acquisition, watcher
// appearance, and the SNI / dbusmenu vtable method-call & get-property
// callbacks) is dispatched as a GSource on the global-default
// `GMainContext`, which the GTK4 backend pumps via `g_main_loop_run` on
// the main thread — the same context the `g_idle_add`-based
// `MainThread.run` hook uses. So the Swift-side event trampoline can hop
// in via `MainActor.assumeIsolated`, exactly like the GTK3 shim.
// ---------------------------------------------------------------------

#include <gio/gio.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <string.h>
#include <unistd.h>

/// Tray-event kinds reported through the Swift callback.
///   0 = click on the icon — never emitted here. The SNI spec gives the
///       desktop panel ownership of click semantics; only menu-item
///       activations reach the app. Reserved for parity with Apple.
///   1 = menu item activated; `id` is the item's stable identifier.
typedef void (*swiftpwa_tray_event_cb)(int kind, const char *id, void *user_data);

typedef struct _swiftpwa_tray_item {
    char *id;         // stable string id (reported back on activation)
    char *label;
    int enabled;
    int separator;
} swiftpwa_tray_item;

typedef struct _swiftpwa_tray {
    GDBusConnection *connection;   // owned; private per tray, see tray_new
    guint own_id;                  // g_bus_own_name_on_connection id
    guint watch_id;                // g_bus_watch_name id (watcher)
    guint sni_reg_id;              // registered /StatusNotifierItem object
    guint menu_reg_id;             // registered /MenuBar object
    GDBusNodeInfo *sni_node;       // owned
    GDBusNodeInfo *menu_node;      // owned
    char *bus_name;                // org.kde.StatusNotifierItem-<pid>-<n>

    // SNI state
    char *title;                   // NULL => "swift-pwa"
    char *tooltip;                 // NULL => ""
    int status_active;             // 1 = Active, 0 = Passive
    GVariant *icon_pixmap;         // a(iiay), owned (ref_sink'd), or NULL

    // Committed menu.
    swiftpwa_tray_item *items;
    int item_count;

    // Menu being built between _menu_begin and _menu_commit.
    swiftpwa_tray_item *pending;
    int pending_count;
    int pending_cap;

    guint menu_revision;

    swiftpwa_tray_event_cb cb;
    void *user_data;
} swiftpwa_tray;

// Per-process instance counter so multiple trays (should one ever be
// created) don't collide on the bus name. Cheap insurance.
static int swiftpwa_tray_instance_seq = 0;

// --- Introspection XML -----------------------------------------------

static const char *SWIFTPWA_SNI_XML =
    "<node>"
    "  <interface name='org.kde.StatusNotifierItem'>"
    "    <property name='Category' type='s' access='read'/>"
    "    <property name='Id' type='s' access='read'/>"
    "    <property name='Title' type='s' access='read'/>"
    "    <property name='Status' type='s' access='read'/>"
    "    <property name='IconName' type='s' access='read'/>"
    "    <property name='IconPixmap' type='a(iiay)' access='read'/>"
    "    <property name='ToolTip' type='(sa(iiay)ss)' access='read'/>"
    "    <property name='ItemIsMenu' type='b' access='read'/>"
    "    <property name='Menu' type='o' access='read'/>"
    "    <method name='Activate'>"
    "      <arg type='i' name='x' direction='in'/>"
    "      <arg type='i' name='y' direction='in'/>"
    "    </method>"
    "    <method name='SecondaryActivate'>"
    "      <arg type='i' name='x' direction='in'/>"
    "      <arg type='i' name='y' direction='in'/>"
    "    </method>"
    "    <method name='ContextMenu'>"
    "      <arg type='i' name='x' direction='in'/>"
    "      <arg type='i' name='y' direction='in'/>"
    "    </method>"
    "    <method name='Scroll'>"
    "      <arg type='i' name='delta' direction='in'/>"
    "      <arg type='s' name='orientation' direction='in'/>"
    "    </method>"
    "    <signal name='NewTitle'/>"
    "    <signal name='NewIcon'/>"
    "    <signal name='NewToolTip'/>"
    "    <signal name='NewStatus'>"
    "      <arg type='s' name='status'/>"
    "    </signal>"
    "  </interface>"
    "</node>";

static const char *SWIFTPWA_MENU_XML =
    "<node>"
    "  <interface name='com.canonical.dbusmenu'>"
    "    <property name='Version' type='u' access='read'/>"
    "    <property name='TextDirection' type='s' access='read'/>"
    "    <property name='Status' type='s' access='read'/>"
    "    <property name='IconThemePath' type='as' access='read'/>"
    "    <method name='GetLayout'>"
    "      <arg type='i' name='parentId' direction='in'/>"
    "      <arg type='i' name='recursionDepth' direction='in'/>"
    "      <arg type='as' name='propertyNames' direction='in'/>"
    "      <arg type='u' name='revision' direction='out'/>"
    "      <arg type='(ia{sv}av)' name='layout' direction='out'/>"
    "    </method>"
    "    <method name='GetGroupProperties'>"
    "      <arg type='ai' name='ids' direction='in'/>"
    "      <arg type='as' name='propertyNames' direction='in'/>"
    "      <arg type='a(ia{sv})' name='properties' direction='out'/>"
    "    </method>"
    "    <method name='GetProperty'>"
    "      <arg type='i' name='id' direction='in'/>"
    "      <arg type='s' name='name' direction='in'/>"
    "      <arg type='v' name='value' direction='out'/>"
    "    </method>"
    "    <method name='Event'>"
    "      <arg type='i' name='id' direction='in'/>"
    "      <arg type='s' name='eventId' direction='in'/>"
    "      <arg type='v' name='data' direction='in'/>"
    "      <arg type='u' name='timestamp' direction='in'/>"
    "    </method>"
    "    <method name='AboutToShow'>"
    "      <arg type='i' name='id' direction='in'/>"
    "      <arg type='b' name='needUpdate' direction='out'/>"
    "    </method>"
    "    <signal name='LayoutUpdated'>"
    "      <arg type='u' name='revision'/>"
    "      <arg type='i' name='parentId'/>"
    "    </signal>"
    "    <signal name='ItemsPropertiesUpdated'>"
    "      <arg type='a(ia{sv})' name='updatedProps'/>"
    "      <arg type='a(ias)' name='removedProps'/>"
    "    </signal>"
    "  </interface>"
    "</node>";

// --- Small helpers ----------------------------------------------------

static void swiftpwa_tray_item_clear(swiftpwa_tray_item *it) {
    if (!it) return;
    g_free(it->id);
    g_free(it->label);
    it->id = NULL;
    it->label = NULL;
}

/// Emit one of the no-argument SNI change signals (NewIcon / NewToolTip
/// / NewTitle). Several real SNI hosts listen only for these
/// interface-specific signals, not `PropertiesChanged`.
static void swiftpwa_tray_emit_sni(swiftpwa_tray *t, const char *signal_name) {
    if (!t || !t->connection) return;
    g_dbus_connection_emit_signal(
        t->connection, NULL, "/StatusNotifierItem",
        "org.kde.StatusNotifierItem", signal_name, NULL, NULL);
}

/// Build the a{sv} property bag for a single menu item (used by both
/// GetLayout and GetGroupProperties).
static GVariant *swiftpwa_tray_item_props(const swiftpwa_tray_item *it) {
    GVariantBuilder props;
    g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
    if (it->separator) {
        g_variant_builder_add(&props, "{sv}", "type", g_variant_new_string("separator"));
    } else {
        g_variant_builder_add(&props, "{sv}", "label", g_variant_new_string(it->label ? it->label : ""));
        g_variant_builder_add(&props, "{sv}", "enabled", g_variant_new_boolean(it->enabled ? TRUE : FALSE));
        g_variant_builder_add(&props, "{sv}", "visible", g_variant_new_boolean(TRUE));
    }
    return g_variant_builder_end(&props);
}

/// Numeric dbusmenu id → item. Root is 0; items are 1..N in order.
static const swiftpwa_tray_item *swiftpwa_tray_find(const swiftpwa_tray *t, gint32 id) {
    if (id < 1 || id > t->item_count) return NULL;
    return &t->items[id - 1];
}

// --- SNI vtable -------------------------------------------------------

static void swiftpwa_sni_method_call(
    GDBusConnection *conn, const gchar *sender, const gchar *object_path,
    const gchar *interface_name, const gchar *method_name,
    GVariant *parameters, GDBusMethodInvocation *invocation, gpointer user_data
) {
    (void)conn; (void)sender; (void)object_path; (void)interface_name;
    (void)parameters; (void)user_data;
    // Activate / SecondaryActivate / ContextMenu / Scroll are accepted
    // and ignored: with ItemIsMenu = true the panel drives the menu, so
    // there's no `.click` path (matching the GTK3 AppIndicator backend).
    // They must still exist + reply, or hosts that probe interface shape
    // misbehave.
    if (g_strcmp0(method_name, "Activate") == 0 ||
        g_strcmp0(method_name, "SecondaryActivate") == 0 ||
        g_strcmp0(method_name, "ContextMenu") == 0 ||
        g_strcmp0(method_name, "Scroll") == 0) {
        g_dbus_method_invocation_return_value(invocation, NULL);
        return;
    }
    g_dbus_method_invocation_return_error(
        invocation, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
        "Unknown method %s", method_name);
}

static GVariant *swiftpwa_sni_get_property(
    GDBusConnection *conn, const gchar *sender, const gchar *object_path,
    const gchar *interface_name, const gchar *property_name,
    GError **error, gpointer user_data
) {
    (void)conn; (void)sender; (void)object_path; (void)interface_name; (void)error;
    swiftpwa_tray *t = (swiftpwa_tray *)user_data;

    if (g_strcmp0(property_name, "Category") == 0)
        return g_variant_new_string("ApplicationStatus");
    if (g_strcmp0(property_name, "Id") == 0)
        return g_variant_new_string("swift-pwa");
    if (g_strcmp0(property_name, "Title") == 0)
        return g_variant_new_string(t->title ? t->title : "swift-pwa");
    if (g_strcmp0(property_name, "Status") == 0)
        return g_variant_new_string(t->status_active ? "Active" : "Passive");
    if (g_strcmp0(property_name, "IconName") == 0)
        return g_variant_new_string("");
    if (g_strcmp0(property_name, "ItemIsMenu") == 0)
        return g_variant_new_boolean(TRUE);
    if (g_strcmp0(property_name, "Menu") == 0)
        return g_variant_new_object_path("/MenuBar");
    if (g_strcmp0(property_name, "IconPixmap") == 0) {
        // GDBus consumes exactly one ref of the returned value; hand back
        // a fresh ref on the cached pixmap, or an empty array.
        if (t->icon_pixmap) return g_variant_ref(t->icon_pixmap);
        return g_variant_new_array(G_VARIANT_TYPE("(iiay)"), NULL, 0);
    }
    if (g_strcmp0(property_name, "ToolTip") == 0) {
        // (icon-name, icon-pixmaps, title, description). We put the
        // tooltip text in `title`; panels surface that on hover.
        GVariant *empty_pixmaps = g_variant_new_array(G_VARIANT_TYPE("(iiay)"), NULL, 0);
        return g_variant_new("(s@a(iiay)ss)",
            "", empty_pixmaps, t->tooltip ? t->tooltip : "", "");
    }
    return NULL;
}

static const GDBusInterfaceVTable swiftpwa_sni_vtable = {
    swiftpwa_sni_method_call, swiftpwa_sni_get_property, NULL, { 0 }
};

// --- dbusmenu vtable --------------------------------------------------

/// Build the full (flat) layout tree: root id 0 with N leaf children.
static GVariant *swiftpwa_menu_build_layout(swiftpwa_tray *t) {
    GVariantBuilder root_props;
    g_variant_builder_init(&root_props, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&root_props, "{sv}", "children-display", g_variant_new_string("submenu"));

    GVariantBuilder children;
    g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
    for (int i = 0; i < t->item_count; i++) {
        // Leaf item: no children (flat menu). `@a{sv}`/`@av` splice in the
        // already-built GVariants (consuming their floating refs).
        GVariant *empty_children = g_variant_new_array(G_VARIANT_TYPE_VARIANT, NULL, 0);
        GVariant *child = g_variant_new("(i@a{sv}@av)",
            i + 1, swiftpwa_tray_item_props(&t->items[i]), empty_children);
        g_variant_builder_add_value(&children, g_variant_new_variant(child));
    }
    return g_variant_new("(ia{sv}av)", 0, &root_props, &children);
}

static void swiftpwa_menu_method_call(
    GDBusConnection *conn, const gchar *sender, const gchar *object_path,
    const gchar *interface_name, const gchar *method_name,
    GVariant *parameters, GDBusMethodInvocation *invocation, gpointer user_data
) {
    (void)conn; (void)sender; (void)object_path; (void)interface_name;
    swiftpwa_tray *t = (swiftpwa_tray *)user_data;

    if (g_strcmp0(method_name, "GetLayout") == 0) {
        GVariant *layout = swiftpwa_menu_build_layout(t);
        g_dbus_method_invocation_return_value(
            invocation, g_variant_new("(u@(ia{sv}av))", t->menu_revision, layout));
        return;
    }
    if (g_strcmp0(method_name, "GetGroupProperties") == 0) {
        // ids: an empty array means "all items".
        GVariant *ids_v = g_variant_get_child_value(parameters, 0);
        gsize n_ids = g_variant_n_children(ids_v);
        GVariantBuilder out;
        g_variant_builder_init(&out, G_VARIANT_TYPE("a(ia{sv})"));
        if (n_ids == 0) {
            for (int i = 0; i < t->item_count; i++)
                g_variant_builder_add(&out, "(i@a{sv})", i + 1, swiftpwa_tray_item_props(&t->items[i]));
        } else {
            for (gsize k = 0; k < n_ids; k++) {
                gint32 id;
                g_variant_get_child(ids_v, k, "i", &id);
                const swiftpwa_tray_item *it = swiftpwa_tray_find(t, id);
                if (it)
                    g_variant_builder_add(&out, "(i@a{sv})", id, swiftpwa_tray_item_props(it));
            }
        }
        g_variant_unref(ids_v);
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(a(ia{sv}))", &out));
        return;
    }
    if (g_strcmp0(method_name, "GetProperty") == 0) {
        gint32 id; const gchar *name;
        g_variant_get(parameters, "(i&s)", &id, &name);
        const swiftpwa_tray_item *it = swiftpwa_tray_find(t, id);
        GVariant *value = NULL;
        if (it) {
            if (g_strcmp0(name, "label") == 0)
                value = g_variant_new_string(it->label ? it->label : "");
            else if (g_strcmp0(name, "enabled") == 0)
                value = g_variant_new_boolean(it->enabled ? TRUE : FALSE);
            else if (g_strcmp0(name, "visible") == 0)
                value = g_variant_new_boolean(TRUE);
            else if (g_strcmp0(name, "type") == 0 && it->separator)
                value = g_variant_new_string("separator");
        }
        if (!value) value = g_variant_new_string("");
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(v)", value));
        return;
    }
    if (g_strcmp0(method_name, "Event") == 0) {
        gint32 id; const gchar *event_id; GVariant *data; guint32 timestamp;
        g_variant_get(parameters, "(i&svu)", &id, &event_id, &data, &timestamp);
        g_dbus_method_invocation_return_value(invocation, NULL);
        if (g_strcmp0(event_id, "clicked") == 0) {
            const swiftpwa_tray_item *it = swiftpwa_tray_find(t, id);
            if (it && !it->separator && t->cb) t->cb(1, it->id ? it->id : "", t->user_data);
        }
        g_variant_unref(data);
        return;
    }
    if (g_strcmp0(method_name, "AboutToShow") == 0) {
        // Static flat menu — never needs lazy population.
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(b)", FALSE));
        return;
    }
    g_dbus_method_invocation_return_error(
        invocation, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
        "Unknown method %s", method_name);
}

static GVariant *swiftpwa_menu_get_property(
    GDBusConnection *conn, const gchar *sender, const gchar *object_path,
    const gchar *interface_name, const gchar *property_name,
    GError **error, gpointer user_data
) {
    (void)conn; (void)sender; (void)object_path; (void)interface_name;
    (void)error; (void)user_data;
    if (g_strcmp0(property_name, "Version") == 0)
        return g_variant_new_uint32(3);
    if (g_strcmp0(property_name, "TextDirection") == 0)
        return g_variant_new_string("ltr");
    if (g_strcmp0(property_name, "Status") == 0)
        return g_variant_new_string("normal");
    if (g_strcmp0(property_name, "IconThemePath") == 0)
        return g_variant_new_array(G_VARIANT_TYPE_STRING, NULL, 0);
    return NULL;
}

static const GDBusInterfaceVTable swiftpwa_menu_vtable = {
    swiftpwa_menu_method_call, swiftpwa_menu_get_property, NULL, { 0 }
};

// --- Bus name / watcher lifecycle ------------------------------------

/// Completion for RegisterStatusNotifierItem. Success is silent; a
/// failure (e.g. a watcher that vanished mid-call) gets one diagnostic
/// line rather than being swallowed.
static void swiftpwa_register_done(GObject *src, GAsyncResult *res, gpointer user_data) {
    (void)user_data;
    GError *err = NULL;
    GVariant *r = g_dbus_connection_call_finish((GDBusConnection *)src, res, &err);
    if (err) {
        g_warning("swift-pwa tray: RegisterStatusNotifierItem failed: %s", err->message);
        g_error_free(err);
    } else if (r) {
        g_variant_unref(r);
    }
}

static void swiftpwa_register_with_watcher(swiftpwa_tray *t) {
    if (!t->connection) return;
    g_dbus_connection_call(
        t->connection, "org.kde.StatusNotifierWatcher",
        "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
        "RegisterStatusNotifierItem", g_variant_new("(s)", t->bus_name),
        NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, swiftpwa_register_done, NULL);
}

static void swiftpwa_on_watcher_appeared(
    GDBusConnection *conn, const gchar *name, const gchar *owner, gpointer user_data
) {
    (void)conn; (void)name; (void)owner;
    swiftpwa_register_with_watcher((swiftpwa_tray *)user_data);
}

static void swiftpwa_on_watcher_vanished(
    GDBusConnection *conn, const gchar *name, gpointer user_data
) {
    // No watcher (e.g. bare GNOME Shell with no AppIndicator extension).
    // Nothing to do — re-registers automatically when one appears.
    (void)conn; (void)name; (void)user_data;
}

// --- Public API (mirrors CAyatanaAppIndicator3Shim) ------------------

static inline swiftpwa_tray *swiftpwa_tray_new(
    swiftpwa_tray_event_cb cb, void *user_data
) {
    swiftpwa_tray *t = (swiftpwa_tray *)g_malloc0(sizeof(swiftpwa_tray));
    t->cb = cb;
    t->user_data = user_data;
    t->status_active = 1;
    t->menu_revision = 1;
    t->sni_node = g_dbus_node_info_new_for_xml(SWIFTPWA_SNI_XML, NULL);
    t->menu_node = g_dbus_node_info_new_for_xml(SWIFTPWA_MENU_XML, NULL);
    t->bus_name = g_strdup_printf(
        "org.kde.StatusNotifierItem-%d-%d",
        (int)getpid(), ++swiftpwa_tray_instance_seq);

    // Each tray gets its **own** connection to the session bus, rather than
    // sharing the process-wide one.
    //
    // The spec fixes an item's object path at `/StatusNotifierItem`, and GDBus
    // permits one object per path per connection — so on the shared connection
    // a second tray's `register_object` fails, and it fails *quietly* unless
    // you ask for the error. An app with its own tray (any `TrayPlugin` user)
    // plus the runtime's agent indicator is exactly two, and the symptom is
    // subtle enough to survive review: two icons appear, both answering with
    // the first tray's title, tooltip and menu, so the indicator's "turn
    // access off" item can't be reached at all. A private connection per tray
    // gives each its own path namespace.
    GError *error = NULL;
    gchar *address = g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!address) {
        g_warning("swift-pwa: no session bus address (%s); tray disabled",
                  error ? error->message : "unknown");
        g_clear_error(&error);
        return t;
    }
    t->connection = g_dbus_connection_new_for_address_sync(
        address,
        (GDBusConnectionFlags)(G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT
                               | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
        NULL, NULL, &error);
    g_free(address);
    if (!t->connection) {
        g_warning("swift-pwa: session bus connection failed (%s); tray disabled",
                  error ? error->message : "unknown");
        g_clear_error(&error);
        return t;
    }
    // A dropped bus must not take the app with it — the default for a private
    // connection, but stated because the shared one does the opposite.
    g_dbus_connection_set_exit_on_close(t->connection, FALSE);

    // Objects before the name: a host that reacts the instant we own it finds
    // a complete item. The `&error` is the point — see above.
    t->sni_reg_id = g_dbus_connection_register_object(
        t->connection, "/StatusNotifierItem", t->sni_node->interfaces[0],
        &swiftpwa_sni_vtable, t, NULL, &error);
    if (t->sni_reg_id == 0) {
        g_warning("swift-pwa: tray /StatusNotifierItem not exported (%s)",
                  error ? error->message : "unknown");
        g_clear_error(&error);
    }
    t->menu_reg_id = g_dbus_connection_register_object(
        t->connection, "/MenuBar", t->menu_node->interfaces[0],
        &swiftpwa_menu_vtable, t, NULL, &error);
    if (t->menu_reg_id == 0) {
        g_warning("swift-pwa: tray /MenuBar not exported (%s)",
                  error ? error->message : "unknown");
        g_clear_error(&error);
    }

    t->own_id = g_bus_own_name_on_connection(
        t->connection, t->bus_name, G_BUS_NAME_OWNER_FLAGS_NONE,
        NULL, NULL, t, NULL);

    // Register now if a watcher is already up, and keep watching so a
    // tray created before the panel still shows up later.
    t->watch_id = g_bus_watch_name_on_connection(
        t->connection, "org.kde.StatusNotifierWatcher", G_BUS_NAME_WATCHER_FLAGS_NONE,
        swiftpwa_on_watcher_appeared, swiftpwa_on_watcher_vanished, t, NULL);
    return t;
}

/// The unique bus name this tray owns (org.kde.StatusNotifierItem-<pid>-<n>).
/// Exposed mainly so tests can address the item over the session bus.
static inline const char *swiftpwa_tray_bus_name(swiftpwa_tray *t) {
    return (t && t->bus_name) ? t->bus_name : "";
}

static inline void swiftpwa_tray_set_icon_path(swiftpwa_tray *t, const char *path) {
    if (!t || !path) return;
    GdkPixbuf *pb = gdk_pixbuf_new_from_file(path, NULL);
    if (!pb) return;  // best-effort; leave the current icon in place
    int w = gdk_pixbuf_get_width(pb);
    int h = gdk_pixbuf_get_height(pb);
    int stride = gdk_pixbuf_get_rowstride(pb);
    int nch = gdk_pixbuf_get_n_channels(pb);
    gboolean has_alpha = gdk_pixbuf_get_has_alpha(pb);
    const guchar *src = gdk_pixbuf_get_pixels(pb);

    // SNI wants ARGB32 in network (big-endian) byte order: A,R,G,B.
    guchar *argb = (guchar *)g_malloc((gsize)w * h * 4);
    for (int y = 0; y < h; y++) {
        const guchar *row = src + (gsize)y * stride;
        for (int x = 0; x < w; x++) {
            const guchar *px = row + (gsize)x * nch;
            guchar *out = argb + ((gsize)y * w + x) * 4;
            out[0] = has_alpha ? px[3] : 0xFF;  // A
            out[1] = px[0];                     // R
            out[2] = px[1];                     // G
            out[3] = px[2];                     // B
        }
    }

    GVariantBuilder pm;
    g_variant_builder_init(&pm, G_VARIANT_TYPE("a(iiay)"));
    g_variant_builder_open(&pm, G_VARIANT_TYPE("(iiay)"));
    g_variant_builder_add(&pm, "i", w);
    g_variant_builder_add(&pm, "i", h);
    g_variant_builder_add_value(&pm,
        g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, argb, (gsize)w * h * 4, sizeof(guchar)));
    g_variant_builder_close(&pm);
    GVariant *pixmap = g_variant_ref_sink(g_variant_builder_end(&pm));

    g_free(argb);          // g_variant_new_fixed_array copied the bytes
    g_object_unref(pb);

    if (t->icon_pixmap) g_variant_unref(t->icon_pixmap);
    t->icon_pixmap = pixmap;
    swiftpwa_tray_emit_sni(t, "NewIcon");
}

static inline void swiftpwa_tray_set_tooltip(swiftpwa_tray *t, const char *text) {
    if (!t) return;
    g_free(t->tooltip);
    t->tooltip = g_strdup(text ? text : "");
    swiftpwa_tray_emit_sni(t, "NewToolTip");
}

static inline void swiftpwa_tray_set_visible(swiftpwa_tray *t, int visible) {
    if (!t) return;
    t->status_active = visible ? 1 : 0;
    if (t->connection) {
        g_dbus_connection_emit_signal(
            t->connection, NULL, "/StatusNotifierItem",
            "org.kde.StatusNotifierItem", "NewStatus",
            g_variant_new("(s)", t->status_active ? "Active" : "Passive"), NULL);
    }
}

static inline void swiftpwa_tray_menu_begin(swiftpwa_tray *t) {
    if (!t) return;
    for (int i = 0; i < t->pending_count; i++) swiftpwa_tray_item_clear(&t->pending[i]);
    t->pending_count = 0;
}

static inline void swiftpwa_tray_menu_append_item(
    swiftpwa_tray *t, const char *id, const char *label, int enabled
) {
    if (!t) return;
    if (t->pending_count >= t->pending_cap) {
        int cap = t->pending_cap ? t->pending_cap * 2 : 8;
        t->pending = (swiftpwa_tray_item *)g_realloc(t->pending, (gsize)cap * sizeof(swiftpwa_tray_item));
        t->pending_cap = cap;
    }
    swiftpwa_tray_item *it = &t->pending[t->pending_count++];
    it->id = g_strdup(id ? id : "");
    it->label = g_strdup(label ? label : "");
    it->enabled = enabled ? 1 : 0;
    it->separator = 0;
}

static inline void swiftpwa_tray_menu_append_separator(swiftpwa_tray *t) {
    if (!t) return;
    if (t->pending_count >= t->pending_cap) {
        int cap = t->pending_cap ? t->pending_cap * 2 : 8;
        t->pending = (swiftpwa_tray_item *)g_realloc(t->pending, (gsize)cap * sizeof(swiftpwa_tray_item));
        t->pending_cap = cap;
    }
    swiftpwa_tray_item *it = &t->pending[t->pending_count++];
    it->id = g_strdup("");
    it->label = g_strdup("");
    it->enabled = 0;
    it->separator = 1;
}

static inline void swiftpwa_tray_menu_commit(swiftpwa_tray *t) {
    if (!t) return;
    // Swap pending -> committed.
    for (int i = 0; i < t->item_count; i++) swiftpwa_tray_item_clear(&t->items[i]);
    g_free(t->items);
    t->items = t->pending;
    t->item_count = t->pending_count;
    t->pending = NULL;
    t->pending_count = 0;
    t->pending_cap = 0;

    // A panel that cached the previous (or the initial empty) layout only
    // re-polls GetLayout after LayoutUpdated with a higher revision.
    t->menu_revision++;
    if (t->connection) {
        g_dbus_connection_emit_signal(
            t->connection, NULL, "/MenuBar", "com.canonical.dbusmenu",
            "LayoutUpdated", g_variant_new("(ui)", t->menu_revision, 0), NULL);
    }
}

static inline void swiftpwa_tray_free(swiftpwa_tray *t) {
    if (!t) return;
    if (t->watch_id) g_bus_unwatch_name(t->watch_id);
    if (t->own_id) g_bus_unown_name(t->own_id);
    if (t->connection) {
        if (t->sni_reg_id) g_dbus_connection_unregister_object(t->connection, t->sni_reg_id);
        if (t->menu_reg_id) g_dbus_connection_unregister_object(t->connection, t->menu_reg_id);
        g_object_unref(t->connection);
    }
    if (t->sni_node) g_dbus_node_info_unref(t->sni_node);
    if (t->menu_node) g_dbus_node_info_unref(t->menu_node);
    if (t->icon_pixmap) g_variant_unref(t->icon_pixmap);
    for (int i = 0; i < t->item_count; i++) swiftpwa_tray_item_clear(&t->items[i]);
    g_free(t->items);
    for (int i = 0; i < t->pending_count; i++) swiftpwa_tray_item_clear(&t->pending[i]);
    g_free(t->pending);
    g_free(t->title);
    g_free(t->tooltip);
    g_free(t->bus_name);
    g_free(t);
}

#endif

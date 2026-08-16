#ifndef SWIFT_PWA_GEOCLUE_SHIM_H
#define SWIFT_PWA_GEOCLUE_SHIM_H

// ---------------------------------------------------------------------
// GeoClue 2 over GDBus — the Linux `geo.*` backend.
//
// GeoClue is a D-Bus service, so this needs no GeoClue development
// package and no GTK: gio-2.0 is the whole dependency, which is why one
// shim serves both Linux backends (the tray shims can't, being tied to a
// toolkit version).
//
// The protocol, on the **system** bus:
//
//   1. org.freedesktop.GeoClue2.Manager.GetClient() -> a client object path
//   2. set the client's DesktopId + RequestedAccuracyLevel properties
//   3. subscribe to the client's LocationUpdated(o old, o new) signal
//   4. Client.Start()
//   5. read the Location object named by the signal
//   6. Client.Stop()
//
// DesktopId is not optional: GeoClue refuses to Start a client without
// one, because it's how the agent decides what to tell the user an app
// is. It's also how a distro's geoclue.conf allowlists callers.
//
// Everything here runs on its own GMainContext rather than the app's, so
// a location request never depends on the GTK main loop being free — the
// bridge calls in from the cooperative pool, and blocking GTK to answer
// would be a deadlock waiting to happen.
// ---------------------------------------------------------------------

#include <gio/gio.h>
#include <string.h>

/// GeoClue's accuracy levels (`org.freedesktop.GeoClue2.Client.RequestedAccuracyLevel`).
/// Not a metre budget — the daemon picks a source class from this.
static const unsigned int SWIFTPWA_GEOCLUE_ACCURACY_CITY = 4;   // GCLUE_ACCURACY_LEVEL_CITY
static const unsigned int SWIFTPWA_GEOCLUE_ACCURACY_EXACT = 8;  // GCLUE_ACCURACY_LEVEL_EXACT

/// One position, in the units the web platform uses. `has_*` flags mark
/// the fields GeoClue leaves at 0 when it has nothing to say — altitude
/// especially, which it reports as a large negative sentinel.
typedef struct {
    double latitude;
    double longitude;
    double accuracy;
    double altitude;
    double speed;
    double heading;
    double timestamp;
    int has_altitude;
    int has_speed;
    int has_heading;
} swiftpwa_geo_fix;

/// Fires on the shim's own thread for each update. `fix` is only valid
/// for the duration of the call.
typedef void (*swiftpwa_geo_callback)(const swiftpwa_geo_fix *fix, void *user_data);

typedef struct {
    GMainContext *context;
    GMainLoop *loop;
    GThread *thread;
    GDBusConnection *bus;
    char *client_path;
    guint signal_id;
    swiftpwa_geo_callback cb;
    void *user_data;
} swiftpwa_geo_session;

/// Read a `double` property off a GeoClue object. Returns 0 when absent.
static inline double swiftpwa_geo_read_double(
    GDBusConnection *bus, const char *path, const char *iface, const char *name, int *ok
) {
    GError *err = NULL;
    GVariant *reply = g_dbus_connection_call_sync(
        bus, "org.freedesktop.GeoClue2", path,
        "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", iface, name),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err
    );
    if (!reply) {
        if (err) g_error_free(err);
        if (ok) *ok = 0;
        return 0;
    }
    GVariant *boxed = NULL;
    g_variant_get(reply, "(v)", &boxed);
    double value = 0;
    if (boxed && g_variant_is_of_type(boxed, G_VARIANT_TYPE_DOUBLE)) {
        value = g_variant_get_double(boxed);
        if (ok) *ok = 1;
    } else if (ok) {
        *ok = 0;
    }
    if (boxed) g_variant_unref(boxed);
    g_variant_unref(reply);
    return value;
}

/// Set a client property. GeoClue exposes these as writable D-Bus
/// properties rather than as Start() arguments.
static inline void swiftpwa_geo_set_property(
    GDBusConnection *bus, const char *path, const char *name, GVariant *value
) {
    GError *err = NULL;
    GVariant *reply = g_dbus_connection_call_sync(
        bus, "org.freedesktop.GeoClue2", path,
        "org.freedesktop.DBus.Properties", "Set",
        g_variant_new("(ssv)", "org.freedesktop.GeoClue2.Client", name, value),
        NULL, G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err
    );
    if (reply) g_variant_unref(reply);
    if (err) g_error_free(err);
}

static inline void swiftpwa_geo_location_updated(
    GDBusConnection *bus,
    const gchar *sender, const gchar *path, const gchar *iface,
    const gchar *signal, GVariant *params, gpointer user_data
) {
    (void)sender; (void)path; (void)iface; (void)signal;
    swiftpwa_geo_session *session = (swiftpwa_geo_session *)user_data;
    const char *old_path = NULL, *new_path = NULL;
    g_variant_get(params, "(&o&o)", &old_path, &new_path);
    if (!new_path) return;

    const char *loc_iface = "org.freedesktop.GeoClue2.Location";
    swiftpwa_geo_fix fix;
    memset(&fix, 0, sizeof(fix));
    int ok = 0;
    fix.latitude = swiftpwa_geo_read_double(bus, new_path, loc_iface, "Latitude", &ok);
    if (!ok) return;
    fix.longitude = swiftpwa_geo_read_double(bus, new_path, loc_iface, "Longitude", &ok);
    if (!ok) return;
    fix.accuracy = swiftpwa_geo_read_double(bus, new_path, loc_iface, "Accuracy", &ok);

    // GeoClue reports "unknown" as a large negative sentinel for altitude
    // and as 0/-1 for the movement fields; passing those through as real
    // values would be worse than omitting them.
    int has = 0;
    double altitude = swiftpwa_geo_read_double(bus, new_path, loc_iface, "Altitude", &has);
    if (has && altitude > -1000000.0) { fix.altitude = altitude; fix.has_altitude = 1; }
    double speed = swiftpwa_geo_read_double(bus, new_path, loc_iface, "Speed", &has);
    if (has && speed >= 0) { fix.speed = speed; fix.has_speed = 1; }
    double heading = swiftpwa_geo_read_double(bus, new_path, loc_iface, "Heading", &has);
    if (has && heading >= 0) { fix.heading = heading; fix.has_heading = 1; }

    // Timestamp is (tt) — seconds + microseconds since the epoch.
    GError *err = NULL;
    GVariant *reply = g_dbus_connection_call_sync(
        bus, "org.freedesktop.GeoClue2", new_path,
        "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", loc_iface, "Timestamp"),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err
    );
    if (reply) {
        GVariant *boxed = NULL;
        g_variant_get(reply, "(v)", &boxed);
        if (boxed) {
            guint64 seconds = 0, micros = 0;
            g_variant_get(boxed, "(tt)", &seconds, &micros);
            fix.timestamp = (double)seconds + (double)micros / 1000000.0;
            g_variant_unref(boxed);
        }
        g_variant_unref(reply);
    }
    if (err) g_error_free(err);
    if (fix.timestamp == 0) fix.timestamp = (double)g_get_real_time() / 1000000.0;

    if (session->cb) session->cb(&fix, session->user_data);
}

static inline gpointer swiftpwa_geo_thread(gpointer data) {
    swiftpwa_geo_session *session = (swiftpwa_geo_session *)data;
    g_main_context_push_thread_default(session->context);
    g_main_loop_run(session->loop);
    g_main_context_pop_thread_default(session->context);
    return NULL;
}

/// Start a GeoClue client and deliver every update to `cb` until
/// ``swiftpwa_geoclue_stop``. Returns NULL and writes a freshly-allocated
/// message to `*err_out` when GeoClue isn't there, refuses the caller, or
/// has no usable source — all of which are "this machine, right now"
/// conditions rather than "Linux can't do this".
static inline swiftpwa_geo_session *swiftpwa_geoclue_start(
    const char *desktop_id,
    unsigned int accuracy_level,
    swiftpwa_geo_callback cb,
    void *user_data,
    char **err_out
) {
    GError *err = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &err);
    if (!bus) {
        if (err_out) {
            *err_out = err ? g_strdup(err->message) : g_strdup("no system bus");
        }
        if (err) g_error_free(err);
        return NULL;
    }

    GVariant *reply = g_dbus_connection_call_sync(
        bus, "org.freedesktop.GeoClue2", "/org/freedesktop/GeoClue2/Manager",
        "org.freedesktop.GeoClue2.Manager", "GetClient", NULL,
        G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err
    );
    if (!reply) {
        if (err_out) {
            *err_out = err
                ? g_strdup_printf("GeoClue2.Manager.GetClient failed: %s", err->message)
                : g_strdup("GeoClue2.Manager.GetClient failed");
        }
        if (err) g_error_free(err);
        g_object_unref(bus);
        return NULL;
    }
    char *client_path = NULL;
    g_variant_get(reply, "(o)", &client_path);
    g_variant_unref(reply);

    swiftpwa_geo_session *session = g_malloc0(sizeof(swiftpwa_geo_session));
    session->bus = bus;
    session->client_path = client_path;
    session->cb = cb;
    session->user_data = user_data;
    session->context = g_main_context_new();
    session->loop = g_main_loop_new(session->context, FALSE);

    swiftpwa_geo_set_property(
        bus, client_path, "DesktopId",
        g_variant_new_string(desktop_id ? desktop_id : "swift-pwa")
    );
    swiftpwa_geo_set_property(
        bus, client_path, "RequestedAccuracyLevel",
        g_variant_new_uint32(accuracy_level)
    );

    // `signal_subscribe` attaches its dispatch source to whichever context
    // is thread-default *at subscribe time*. Without this push that would be
    // the global default — iterated by the GTK main loop on a desktop app and
    // by nobody at all headless, so updates would arrive on the wrong thread
    // or never. Pushing our own context first binds it to the loop below.
    g_main_context_push_thread_default(session->context);
    session->signal_id = g_dbus_connection_signal_subscribe(
        bus, "org.freedesktop.GeoClue2", "org.freedesktop.GeoClue2.Client",
        "LocationUpdated", client_path, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
        swiftpwa_geo_location_updated, session, NULL
    );
    g_main_context_pop_thread_default(session->context);

    session->thread = g_thread_new("swiftpwa-geoclue", swiftpwa_geo_thread, session);

    reply = g_dbus_connection_call_sync(
        bus, "org.freedesktop.GeoClue2", client_path,
        "org.freedesktop.GeoClue2.Client", "Start", NULL,
        NULL, G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err
    );
    if (!reply) {
        if (err_out) {
            // The common ones: no agent registered for this desktop id, and
            // no usable source (no WiFi source, no GPS, network geolocation
            // disabled in geoclue.conf).
            *err_out = err
                ? g_strdup_printf("GeoClue2.Client.Start failed: %s", err->message)
                : g_strdup("GeoClue2.Client.Start failed");
        }
        if (err) g_error_free(err);
        g_main_loop_quit(session->loop);
        g_thread_join(session->thread);
        g_dbus_connection_signal_unsubscribe(bus, session->signal_id);
        g_main_loop_unref(session->loop);
        g_main_context_unref(session->context);
        g_free(session->client_path);
        g_object_unref(bus);
        g_free(session);
        return NULL;
    }
    g_variant_unref(reply);
    return session;
}

static inline void swiftpwa_geoclue_stop(swiftpwa_geo_session *session) {
    if (!session) return;
    GError *err = NULL;
    GVariant *reply = g_dbus_connection_call_sync(
        session->bus, "org.freedesktop.GeoClue2", session->client_path,
        "org.freedesktop.GeoClue2.Client", "Stop", NULL,
        NULL, G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err
    );
    if (reply) g_variant_unref(reply);
    if (err) g_error_free(err);

    g_dbus_connection_signal_unsubscribe(session->bus, session->signal_id);
    g_main_loop_quit(session->loop);
    if (session->thread) g_thread_join(session->thread);
    g_main_loop_unref(session->loop);
    g_main_context_unref(session->context);
    g_free(session->client_path);
    g_object_unref(session->bus);
    g_free(session);
}

#endif

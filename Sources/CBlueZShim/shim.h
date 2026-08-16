#ifndef SWIFT_PWA_BLUEZ_SHIM_H
#define SWIFT_PWA_BLUEZ_SHIM_H

// ---------------------------------------------------------------------
// BlueZ over GDBus — the Linux `ble.*` backend.
//
// BlueZ has no usable C library for this; the interface *is* D-Bus. So
// this needs no BlueZ development package and no GTK: gio-2.0 is the
// whole dependency, which is why one shim serves both Linux backends
// (the tray shims can't, being tied to a toolkit version).
//
// The protocol, on the **system** bus, under `org.bluez`:
//
//   scan     Adapter1.SetDiscoveryFilter({Transport: "le", UUIDs: […]})
//            Adapter1.StartDiscovery(), then watch ObjectManager's
//            InterfacesAdded and Device1's PropertiesChanged for RSSI.
//   connect  Device1.Connect(), then wait for ServicesResolved — the
//            services exist as D-Bus objects underneath the device, and
//            they aren't all there until that flips.
//   write    GattCharacteristic1.WriteValue(ay, {type: request|command})
//   notify   GattCharacteristic1.StartNotify(), then the values arrive
//            as PropertiesChanged on the characteristic object.
//
// Events reach Swift as JSON strings rather than structs. The shapes are
// the same ones the Android RPC sends, so both backends decode into the
// same Swift types — and a C struct per event kind would be four more
// things to keep in step by hand.
//
// Everything runs on its own GMainContext rather than the app's, so a
// Bluetooth call never depends on the GTK main loop being free: the
// bridge calls in from the cooperative pool, and blocking GTK to answer
// would be a deadlock waiting to happen.
// ---------------------------------------------------------------------

#include <gio/gio.h>
#include <string.h>

#define SWIFTPWA_BLUEZ "org.bluez"
#define SWIFTPWA_BLUEZ_ADAPTER "org.bluez.Adapter1"
#define SWIFTPWA_BLUEZ_DEVICE "org.bluez.Device1"
#define SWIFTPWA_BLUEZ_SERVICE "org.bluez.GattService1"
#define SWIFTPWA_BLUEZ_CHARACTERISTIC "org.bluez.GattCharacteristic1"

/// Fires on the shim's own thread with one JSON object per event.
/// `json` is only valid for the duration of the call.
typedef void (*swiftpwa_ble_callback)(const char *json, void *user_data);

typedef struct {
    GMainContext *context;
    GMainLoop *loop;
    GThread *thread;
    GDBusConnection *bus;
    swiftpwa_ble_callback callback;
    void *user_data;

    /// Scan state.
    char *adapter_path;
    guint added_signal;
    guint changed_signal;
    char **filter_uuids;
    int filter_uuid_count;

    /// Link state.
    char *device_path;
    guint device_signal;
    /// Characteristic object paths with notifications turned on.
    GList *notifying;
    int reported_ready;
} swiftpwa_ble_session;

// ---------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------

/// JSON string escaping, enough for what BlueZ hands back: device names
/// are arbitrary UTF-8 from the peripheral, so quotes and control bytes
/// are entirely possible and would otherwise produce JSON the Swift side
/// silently fails to decode.
static void swiftpwa_ble_append_escaped(GString *out, const char *text) {
    g_string_append_c(out, '"');
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
        switch (*p) {
        case '"': g_string_append(out, "\\\""); break;
        case '\\': g_string_append(out, "\\\\"); break;
        case '\n': g_string_append(out, "\\n"); break;
        case '\r': g_string_append(out, "\\r"); break;
        case '\t': g_string_append(out, "\\t"); break;
        default:
            if (*p < 0x20) {
                g_string_append_printf(out, "\\u%04x", *p);
            } else {
                g_string_append_c(out, (char)*p);
            }
        }
    }
    g_string_append_c(out, '"');
}

static void swiftpwa_ble_emit(swiftpwa_ble_session *session, GString *json) {
    if (session->callback) session->callback(json->str, session->user_data);
    g_string_free(json, TRUE);
}

/// `/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF` -> `AA:BB:CC:DD:EE:FF`.
static char *swiftpwa_ble_address_from_path(const char *path) {
    const char *dev = strstr(path, "/dev_");
    if (!dev) return NULL;
    char *address = g_strdup(dev + 5);
    for (char *p = address; *p; p++) {
        if (*p == '_') *p = ':';
        if (*p == '/') { *p = '\0'; break; }
    }
    return address;
}

static gpointer swiftpwa_ble_thread(gpointer data) {
    swiftpwa_ble_session *session = (swiftpwa_ble_session *)data;
    g_main_context_push_thread_default(session->context);
    g_main_loop_run(session->loop);
    g_main_context_pop_thread_default(session->context);
    return NULL;
}

/// A session with its own thread, context and system-bus connection.
///
/// The signal subscriptions have to be made with the context pushed as
/// thread-default or they land on the *global* default context, which
/// nothing here runs — the same trap the GeoClue shim documents, where
/// the calls all work and no signal ever arrives.
static swiftpwa_ble_session *swiftpwa_ble_session_new(char **error_out) {
    swiftpwa_ble_session *session = g_new0(swiftpwa_ble_session, 1);
    session->context = g_main_context_new();
    session->loop = g_main_loop_new(session->context, FALSE);

    GError *error = NULL;
    g_main_context_push_thread_default(session->context);
    session->bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &error);
    g_main_context_pop_thread_default(session->context);
    if (!session->bus) {
        if (error_out) *error_out = g_strdup(error ? error->message : "no system bus");
        if (error) g_error_free(error);
        g_main_loop_unref(session->loop);
        g_main_context_unref(session->context);
        g_free(session);
        return NULL;
    }
    session->thread = g_thread_new("swiftpwa-ble", swiftpwa_ble_thread, session);
    return session;
}

static void swiftpwa_ble_session_free(swiftpwa_ble_session *session) {
    if (!session) return;
    if (session->added_signal) g_dbus_connection_signal_unsubscribe(session->bus, session->added_signal);
    if (session->changed_signal) g_dbus_connection_signal_unsubscribe(session->bus, session->changed_signal);
    if (session->device_signal) g_dbus_connection_signal_unsubscribe(session->bus, session->device_signal);
    g_list_free_full(session->notifying, g_free);
    if (session->loop) {
        g_main_loop_quit(session->loop);
        if (session->thread) g_thread_join(session->thread);
        g_main_loop_unref(session->loop);
    }
    if (session->bus) g_object_unref(session->bus);
    if (session->context) g_main_context_unref(session->context);
    g_strfreev(session->filter_uuids);
    g_free(session->adapter_path);
    g_free(session->device_path);
    g_free(session);
}

/// Call a method on an org.bluez object, discarding the reply.
static gboolean swiftpwa_ble_call(
    swiftpwa_ble_session *session, const char *path, const char *interface,
    const char *method, GVariant *args, char **error_out
) {
    GError *error = NULL;
    GVariant *reply = g_dbus_connection_call_sync(
        session->bus, SWIFTPWA_BLUEZ, path, interface, method, args,
        NULL, G_DBUS_CALL_FLAGS_NONE, 20000, NULL, &error
    );
    if (!reply) {
        if (error_out) *error_out = g_strdup(error ? error->message : "the call failed");
        if (error) g_error_free(error);
        return FALSE;
    }
    g_variant_unref(reply);
    return TRUE;
}

static GVariant *swiftpwa_ble_get_property(
    swiftpwa_ble_session *session, const char *path, const char *interface, const char *name
) {
    GError *error = NULL;
    GVariant *reply = g_dbus_connection_call_sync(
        session->bus, SWIFTPWA_BLUEZ, path, "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", interface, name), G_VARIANT_TYPE("(v)"),
        G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &error
    );
    if (!reply) {
        if (error) g_error_free(error);
        return NULL;
    }
    GVariant *boxed = NULL;
    g_variant_get(reply, "(v)", &boxed);
    g_variant_unref(reply);
    return boxed;
}

static GVariant *swiftpwa_ble_managed_objects(swiftpwa_ble_session *session) {
    GError *error = NULL;
    GVariant *reply = g_dbus_connection_call_sync(
        session->bus, SWIFTPWA_BLUEZ, "/", "org.freedesktop.DBus.ObjectManager",
        "GetManagedObjects", NULL, G_VARIANT_TYPE("(a{oa{sa{sv}}})"),
        G_DBUS_CALL_FLAGS_NONE, 10000, NULL, &error
    );
    if (!reply) {
        if (error) g_error_free(error);
        return NULL;
    }
    return reply;
}

/// The first powered adapter, or the first one at all when none is on —
/// so "Bluetooth is switched off" can be told apart from "no adapter",
/// which are different sentences to show a user.
static char *swiftpwa_ble_find_adapter(swiftpwa_ble_session *session, int *powered_out) {
    GVariant *objects = swiftpwa_ble_managed_objects(session);
    if (!objects) return NULL;

    char *first = NULL;
    int first_powered = 0;
    GVariantIter *paths = NULL;
    const char *path = NULL;
    GVariantIter *interfaces = NULL;
    g_variant_get(objects, "(a{oa{sa{sv}}})", &paths);
    while (g_variant_iter_loop(paths, "{&oa{sa{sv}}}", &path, &interfaces)) {
        const char *interface = NULL;
        GVariantIter *properties = NULL;
        while (g_variant_iter_loop(interfaces, "{&sa{sv}}", &interface, &properties)) {
            if (g_strcmp0(interface, SWIFTPWA_BLUEZ_ADAPTER) != 0) continue;
            int powered = 0;
            const char *name = NULL;
            GVariant *value = NULL;
            while (g_variant_iter_loop(properties, "{&sv}", &name, &value)) {
                if (g_strcmp0(name, "Powered") == 0) powered = g_variant_get_boolean(value);
            }
            if (powered && !first_powered) {
                g_free(first);
                first = g_strdup(path);
                first_powered = 1;
            } else if (!first) {
                first = g_strdup(path);
            }
        }
    }
    g_variant_iter_free(paths);
    g_variant_unref(objects);
    if (powered_out) *powered_out = first_powered;
    return first;
}

// ---------------------------------------------------------------------
// Availability
// ---------------------------------------------------------------------

/// 1 when a powered adapter is present. `reason_out` is set (caller
/// frees) when it isn't, and never says "this platform doesn't do
/// Bluetooth" — every platform here does.
static int swiftpwa_ble_available(char **reason_out) {
    char *error = NULL;
    swiftpwa_ble_session *session = swiftpwa_ble_session_new(&error);
    if (!session) {
        if (reason_out) {
            *reason_out = g_strdup_printf(
                "the system bus is unreachable, so BlueZ can't be asked (%s)", error ? error : "unknown"
            );
        }
        g_free(error);
        return 0;
    }
    int powered = 0;
    char *adapter = swiftpwa_ble_find_adapter(session, &powered);
    int available = adapter != NULL && powered;
    if (!available && reason_out) {
        *reason_out = adapter
            ? g_strdup("Bluetooth is switched off")
            : g_strdup("no Bluetooth adapter is present, or bluetoothd isn't running");
    }
    g_free(adapter);
    swiftpwa_ble_session_free(session);
    return available;
}

// ---------------------------------------------------------------------
// Scanning
// ---------------------------------------------------------------------

/// Build one advertisement object out of a Device1 property map.
///
/// Returns NULL when the device doesn't match the session's UUID filter.
/// BlueZ's own discovery filter is a hint the daemon applies across every
/// client, so a second app scanning for everything widens it underneath
/// us — the filter has to be applied here too.
static GString *swiftpwa_ble_advertisement(
    swiftpwa_ble_session *session, const char *path, GVariantIter *properties
) {
    char *address = swiftpwa_ble_address_from_path(path);
    if (!address) return NULL;

    const char *name = NULL;
    gboolean have_rssi = FALSE;
    gint16 rssi = 0;
    GString *uuids = g_string_new("[");
    int uuid_count = 0;
    int matched = session->filter_uuid_count == 0;
    GString *manufacturer = NULL;

    const char *key = NULL;
    GVariant *value = NULL;
    while (g_variant_iter_loop(properties, "{&sv}", &key, &value)) {
        if (g_strcmp0(key, "Alias") == 0 || g_strcmp0(key, "Name") == 0) {
            // Prefer Name; Alias falls back to the address when there is
            // no name, which would make every unnamed device look named.
            if (!name || g_strcmp0(key, "Name") == 0) name = g_variant_get_string(value, NULL);
            if (g_strcmp0(key, "Alias") == 0 && g_strcmp0(name, address) == 0) name = NULL;
        } else if (g_strcmp0(key, "RSSI") == 0) {
            have_rssi = TRUE;
            rssi = g_variant_get_int16(value);
        } else if (g_strcmp0(key, "UUIDs") == 0) {
            GVariantIter *list = NULL;
            const char *uuid = NULL;
            g_variant_get(value, "as", &list);
            while (g_variant_iter_loop(list, "&s", &uuid)) {
                if (uuid_count++) g_string_append_c(uuids, ',');
                swiftpwa_ble_append_escaped(uuids, uuid);
                for (int i = 0; i < session->filter_uuid_count; i++) {
                    if (g_ascii_strcasecmp(uuid, session->filter_uuids[i]) == 0) matched = 1;
                }
            }
            g_variant_iter_free(list);
        } else if (g_strcmp0(key, "ManufacturerData") == 0) {
            GVariantIter *entries = NULL;
            guint16 company = 0;
            GVariant *bytes = NULL;
            g_variant_get(value, "a{qv}", &entries);
            if (g_variant_iter_loop(entries, "{qv}", &company, &bytes)) {
                gsize length = 0;
                const guchar *data = g_variant_get_fixed_array(bytes, &length, sizeof(guchar));
                // The company id goes back in front of the bytes, so the
                // field matches what the peripheral put on the air —
                // BlueZ splits it out, Apple and Windows don't.
                guchar *combined = g_malloc(length + 2);
                combined[0] = (guchar)(company & 0xFF);
                combined[1] = (guchar)((company >> 8) & 0xFF);
                memcpy(combined + 2, data, length);
                char *encoded = g_base64_encode(combined, length + 2);
                manufacturer = g_string_new(encoded);
                g_free(encoded);
                g_free(combined);
            }
            g_variant_iter_free(entries);
        }
    }
    g_string_append_c(uuids, ']');

    if (!matched) {
        g_free(address);
        g_string_free(uuids, TRUE);
        if (manufacturer) g_string_free(manufacturer, TRUE);
        return NULL;
    }

    GString *json = g_string_new("{\"advertisement\":{\"id\":");
    swiftpwa_ble_append_escaped(json, address);
    if (name) {
        g_string_append(json, ",\"name\":");
        swiftpwa_ble_append_escaped(json, name);
    }
    if (have_rssi) g_string_append_printf(json, ",\"rssi\":%d", rssi);
    g_string_append_printf(json, ",\"services\":%s", uuids->str);
    if (manufacturer) {
        g_string_append(json, ",\"manufacturerDataBase64\":");
        swiftpwa_ble_append_escaped(json, manufacturer->str);
    }
    g_string_append_printf(json, ",\"timestamp\":%.3f}}", (double)g_get_real_time() / 1000000.0);

    g_free(address);
    g_string_free(uuids, TRUE);
    if (manufacturer) g_string_free(manufacturer, TRUE);
    return json;
}

static void swiftpwa_ble_interfaces_added(
    GDBusConnection *connection, const gchar *sender, const gchar *object_path,
    const gchar *interface_name, const gchar *signal_name, GVariant *parameters,
    gpointer user_data
) {
    (void)connection; (void)sender; (void)object_path;
    (void)interface_name; (void)signal_name;
    swiftpwa_ble_session *session = (swiftpwa_ble_session *)user_data;

    const char *path = NULL;
    GVariantIter *interfaces = NULL;
    g_variant_get(parameters, "(&oa{sa{sv}})", &path, &interfaces);
    const char *interface = NULL;
    GVariantIter *properties = NULL;
    while (g_variant_iter_loop(interfaces, "{&sa{sv}}", &interface, &properties)) {
        if (g_strcmp0(interface, SWIFTPWA_BLUEZ_DEVICE) != 0) continue;
        GString *json = swiftpwa_ble_advertisement(session, path, properties);
        if (json) swiftpwa_ble_emit(session, json);
    }
    g_variant_iter_free(interfaces);
}

/// A device BlueZ already knew about re-advertising. Its cache means the
/// first sighting of a known device arrives as a property change rather
/// than InterfacesAdded, so a scan that only watched the latter would
/// miss every peripheral the machine has seen before — which, on a
/// developer's box, is all of them.
static void swiftpwa_ble_device_changed(
    GDBusConnection *connection, const gchar *sender, const gchar *object_path,
    const gchar *interface_name, const gchar *signal_name, GVariant *parameters,
    gpointer user_data
) {
    (void)connection; (void)sender; (void)interface_name; (void)signal_name;
    swiftpwa_ble_session *session = (swiftpwa_ble_session *)user_data;
    if (!strstr(object_path, "/dev_")) return;

    const char *changed_interface = NULL;
    GVariantIter *changed = NULL;
    GVariantIter *invalidated = NULL;
    g_variant_get(parameters, "(&sa{sv}as)", &changed_interface, &changed, &invalidated);
    if (g_strcmp0(changed_interface, SWIFTPWA_BLUEZ_DEVICE) == 0) {
        // The changed set is partial (usually just RSSI), so the full
        // property map is read back: a page building a picker needs the
        // name and services, not only what moved.
        GVariant *full = swiftpwa_ble_managed_objects(session);
        if (full) {
            GVariantIter *paths = NULL;
            const char *path = NULL;
            GVariantIter *interfaces = NULL;
            g_variant_get(full, "(a{oa{sa{sv}}})", &paths);
            while (g_variant_iter_loop(paths, "{&oa{sa{sv}}}", &path, &interfaces)) {
                if (g_strcmp0(path, object_path) != 0) continue;
                const char *interface = NULL;
                GVariantIter *properties = NULL;
                while (g_variant_iter_loop(interfaces, "{&sa{sv}}", &interface, &properties)) {
                    if (g_strcmp0(interface, SWIFTPWA_BLUEZ_DEVICE) != 0) continue;
                    GString *json = swiftpwa_ble_advertisement(session, path, properties);
                    if (json) swiftpwa_ble_emit(session, json);
                }
            }
            g_variant_iter_free(paths);
            g_variant_unref(full);
        }
    }
    g_variant_iter_free(changed);
    g_variant_iter_free(invalidated);
}

static swiftpwa_ble_session *swiftpwa_ble_scan_start(
    const char *const *uuids, int uuid_count,
    swiftpwa_ble_callback callback, void *user_data, char **error_out
) {
    swiftpwa_ble_session *session = swiftpwa_ble_session_new(error_out);
    if (!session) return NULL;
    session->callback = callback;
    session->user_data = user_data;

    int powered = 0;
    session->adapter_path = swiftpwa_ble_find_adapter(session, &powered);
    if (!session->adapter_path || !powered) {
        if (error_out) {
            *error_out = session->adapter_path
                ? g_strdup("Bluetooth is switched off")
                : g_strdup("no Bluetooth adapter is present, or bluetoothd isn't running");
        }
        swiftpwa_ble_session_free(session);
        return NULL;
    }

    if (uuid_count > 0) {
        session->filter_uuids = g_new0(char *, uuid_count + 1);
        for (int i = 0; i < uuid_count; i++) session->filter_uuids[i] = g_strdup(uuids[i]);
        session->filter_uuid_count = uuid_count;
    }

    g_main_context_push_thread_default(session->context);
    session->added_signal = g_dbus_connection_signal_subscribe(
        session->bus, SWIFTPWA_BLUEZ, "org.freedesktop.DBus.ObjectManager",
        "InterfacesAdded", NULL, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
        swiftpwa_ble_interfaces_added, session, NULL
    );
    session->changed_signal = g_dbus_connection_signal_subscribe(
        session->bus, SWIFTPWA_BLUEZ, "org.freedesktop.DBus.Properties",
        "PropertiesChanged", NULL, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
        swiftpwa_ble_device_changed, session, NULL
    );
    g_main_context_pop_thread_default(session->context);

    // `DuplicateData` keeps repeat advertisements coming, so RSSI updates
    // and a picker can show a device getting nearer. `Transport: le`
    // keeps classic Bluetooth devices out of a scan for LE peripherals.
    GVariantBuilder filter;
    g_variant_builder_init(&filter, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&filter, "{sv}", "Transport", g_variant_new_string("le"));
    g_variant_builder_add(&filter, "{sv}", "DuplicateData", g_variant_new_boolean(TRUE));
    if (uuid_count > 0) {
        GVariantBuilder list;
        g_variant_builder_init(&list, G_VARIANT_TYPE("as"));
        for (int i = 0; i < uuid_count; i++) g_variant_builder_add(&list, "s", uuids[i]);
        g_variant_builder_add(&filter, "{sv}", "UUIDs", g_variant_builder_end(&list));
    }
    char *filter_error = NULL;
    swiftpwa_ble_call(
        session, session->adapter_path, SWIFTPWA_BLUEZ_ADAPTER, "SetDiscoveryFilter",
        g_variant_new("(a{sv})", &filter), &filter_error
    );
    // A rejected filter is not fatal — an unfiltered scan still finds the
    // peripheral, and this shim filters on the way out anyway.
    g_free(filter_error);

    char *start_error = NULL;
    if (!swiftpwa_ble_call(
            session, session->adapter_path, SWIFTPWA_BLUEZ_ADAPTER, "StartDiscovery", NULL, &start_error
        )) {
        if (error_out) *error_out = start_error; else g_free(start_error);
        swiftpwa_ble_session_free(session);
        return NULL;
    }
    return session;
}

static void swiftpwa_ble_scan_stop(swiftpwa_ble_session *session) {
    if (!session) return;
    char *error = NULL;
    // Another client may still want discovery, so BlueZ refuses this when
    // it isn't ours to stop. Nothing to do about that but let it go.
    swiftpwa_ble_call(
        session, session->adapter_path, SWIFTPWA_BLUEZ_ADAPTER, "StopDiscovery", NULL, &error
    );
    g_free(error);
    session->callback = NULL;
    swiftpwa_ble_session_free(session);
}

// ---------------------------------------------------------------------
// A link
// ---------------------------------------------------------------------

/// Find a characteristic's object path by UUID, under the open device.
static char *swiftpwa_ble_characteristic_path(swiftpwa_ble_session *session, const char *uuid) {
    GVariant *objects = swiftpwa_ble_managed_objects(session);
    if (!objects) return NULL;

    char *found = NULL;
    GVariantIter *paths = NULL;
    const char *path = NULL;
    GVariantIter *interfaces = NULL;
    g_variant_get(objects, "(a{oa{sa{sv}}})", &paths);
    while (g_variant_iter_loop(paths, "{&oa{sa{sv}}}", &path, &interfaces)) {
        if (!g_str_has_prefix(path, session->device_path)) continue;
        const char *interface = NULL;
        GVariantIter *properties = NULL;
        while (g_variant_iter_loop(interfaces, "{&sa{sv}}", &interface, &properties)) {
            if (g_strcmp0(interface, SWIFTPWA_BLUEZ_CHARACTERISTIC) != 0) continue;
            const char *key = NULL;
            GVariant *value = NULL;
            while (g_variant_iter_loop(properties, "{&sv}", &key, &value)) {
                if (g_strcmp0(key, "UUID") != 0) continue;
                if (g_ascii_strcasecmp(g_variant_get_string(value, NULL), uuid) == 0) {
                    g_free(found);
                    found = g_strdup(path);
                }
            }
        }
    }
    g_variant_iter_free(paths);
    g_variant_unref(objects);
    return found;
}

/// The `ready` event: every service under the device with its
/// characteristics and their flags.
static void swiftpwa_ble_emit_ready(swiftpwa_ble_session *session) {
    GVariant *objects = swiftpwa_ble_managed_objects(session);
    if (!objects) return;

    GString *json = g_string_new("{\"kind\":\"ready\",\"services\":[");
    int service_count = 0;

    GVariantIter *paths = NULL;
    const char *path = NULL;
    GVariantIter *interfaces = NULL;
    g_variant_get(objects, "(a{oa{sa{sv}}})", &paths);
    while (g_variant_iter_loop(paths, "{&oa{sa{sv}}}", &path, &interfaces)) {
        if (!g_str_has_prefix(path, session->device_path)) continue;
        const char *interface = NULL;
        GVariantIter *properties = NULL;
        while (g_variant_iter_loop(interfaces, "{&sa{sv}}", &interface, &properties)) {
            if (g_strcmp0(interface, SWIFTPWA_BLUEZ_SERVICE) != 0) continue;
            const char *uuid = NULL;
            gboolean primary = TRUE;
            const char *key = NULL;
            GVariant *value = NULL;
            while (g_variant_iter_loop(properties, "{&sv}", &key, &value)) {
                if (g_strcmp0(key, "UUID") == 0) uuid = g_variant_get_string(value, NULL);
                if (g_strcmp0(key, "Primary") == 0) primary = g_variant_get_boolean(value);
            }
            if (!uuid) continue;
            if (service_count++) g_string_append_c(json, ',');
            g_string_append(json, "{\"uuid\":");
            swiftpwa_ble_append_escaped(json, uuid);
            g_string_append_printf(json, ",\"isPrimary\":%s,\"characteristics\":[", primary ? "true" : "false");

            // Characteristics are separate objects nested under the
            // service's path, so this is a second pass over the same map.
            int characteristic_count = 0;
            GVariantIter *inner_paths = NULL;
            const char *inner_path = NULL;
            GVariantIter *inner_interfaces = NULL;
            g_variant_get(objects, "(a{oa{sa{sv}}})", &inner_paths);
            while (g_variant_iter_loop(inner_paths, "{&oa{sa{sv}}}", &inner_path, &inner_interfaces)) {
                if (!g_str_has_prefix(inner_path, path)) continue;
                const char *inner_interface = NULL;
                GVariantIter *inner_properties = NULL;
                while (g_variant_iter_loop(
                    inner_interfaces, "{&sa{sv}}", &inner_interface, &inner_properties
                )) {
                    if (g_strcmp0(inner_interface, SWIFTPWA_BLUEZ_CHARACTERISTIC) != 0) continue;
                    const char *characteristic_uuid = NULL;
                    GString *flags = g_string_new("[");
                    int flag_count = 0;
                    const char *inner_key = NULL;
                    GVariant *inner_value = NULL;
                    while (g_variant_iter_loop(inner_properties, "{&sv}", &inner_key, &inner_value)) {
                        if (g_strcmp0(inner_key, "UUID") == 0) {
                            characteristic_uuid = g_variant_get_string(inner_value, NULL);
                        } else if (g_strcmp0(inner_key, "Flags") == 0) {
                            GVariantIter *list = NULL;
                            const char *flag = NULL;
                            g_variant_get(inner_value, "as", &list);
                            while (g_variant_iter_loop(list, "&s", &flag)) {
                                // BlueZ spells them with hyphens; the
                                // contract uses the web/Apple spelling.
                                const char *name = flag;
                                if (g_strcmp0(flag, "write-without-response") == 0) {
                                    name = "writeWithoutResponse";
                                }
                                if (flag_count++) g_string_append_c(flags, ',');
                                swiftpwa_ble_append_escaped(flags, name);
                            }
                            g_variant_iter_free(list);
                        }
                    }
                    g_string_append_c(flags, ']');
                    if (characteristic_uuid) {
                        if (characteristic_count++) g_string_append_c(json, ',');
                        g_string_append(json, "{\"uuid\":");
                        swiftpwa_ble_append_escaped(json, characteristic_uuid);
                        g_string_append_printf(json, ",\"properties\":%s}", flags->str);
                    }
                    g_string_free(flags, TRUE);
                }
            }
            g_variant_iter_free(inner_paths);
            g_string_append(json, "]}");
        }
    }
    g_variant_iter_free(paths);
    g_variant_unref(objects);
    g_string_append(json, "]}");
    swiftpwa_ble_emit(session, json);
}

static void swiftpwa_ble_link_changed(
    GDBusConnection *connection, const gchar *sender, const gchar *object_path,
    const gchar *interface_name, const gchar *signal_name, GVariant *parameters,
    gpointer user_data
) {
    (void)connection; (void)sender; (void)interface_name; (void)signal_name;
    swiftpwa_ble_session *session = (swiftpwa_ble_session *)user_data;

    const char *changed_interface = NULL;
    GVariantIter *changed = NULL;
    GVariantIter *invalidated = NULL;
    g_variant_get(parameters, "(&sa{sv}as)", &changed_interface, &changed, &invalidated);

    const char *key = NULL;
    GVariant *value = NULL;
    if (g_strcmp0(changed_interface, SWIFTPWA_BLUEZ_DEVICE) == 0 &&
        g_strcmp0(object_path, session->device_path) == 0) {
        while (g_variant_iter_loop(changed, "{&sv}", &key, &value)) {
            if (g_strcmp0(key, "Connected") == 0) {
                gboolean connected = g_variant_get_boolean(value);
                GString *json = g_string_new("{\"kind\":\"state\",\"connected\":");
                g_string_append(json, connected ? "true" : "false");
                if (!connected) {
                    session->reported_ready = 0;
                    g_string_append(json, ",\"reason\":\"reconnecting\"");
                }
                g_string_append_c(json, '}');
                swiftpwa_ble_emit(session, json);
            } else if (g_strcmp0(key, "ServicesResolved") == 0) {
                // The services aren't all on the bus until this flips, so
                // enumerating on Connected alone finds a partial tree —
                // and reports a peripheral that's missing characteristics
                // it actually has.
                if (g_variant_get_boolean(value) && !session->reported_ready) {
                    session->reported_ready = 1;
                    swiftpwa_ble_emit_ready(session);
                }
            }
        }
    } else if (g_strcmp0(changed_interface, SWIFTPWA_BLUEZ_CHARACTERISTIC) == 0 &&
               g_str_has_prefix(object_path, session->device_path) &&
               g_list_find_custom(session->notifying, object_path, (GCompareFunc)g_strcmp0)) {
        while (g_variant_iter_loop(changed, "{&sv}", &key, &value)) {
            if (g_strcmp0(key, "Value") != 0) continue;
            gsize length = 0;
            const guchar *data = g_variant_get_fixed_array(value, &length, sizeof(guchar));
            GVariant *uuid = swiftpwa_ble_get_property(
                session, object_path, SWIFTPWA_BLUEZ_CHARACTERISTIC, "UUID"
            );
            if (!uuid) continue;
            char *encoded = g_base64_encode(data, length);
            GString *json = g_string_new("{\"kind\":\"notify\",\"characteristic\":");
            swiftpwa_ble_append_escaped(json, g_variant_get_string(uuid, NULL));
            g_string_append(json, ",\"value\":");
            swiftpwa_ble_append_escaped(json, encoded);
            g_string_append_c(json, '}');
            swiftpwa_ble_emit(session, json);
            g_free(encoded);
            g_variant_unref(uuid);
        }
    }
    g_variant_iter_free(changed);
    g_variant_iter_free(invalidated);
}

/// Make BlueZ see the device as LE before connecting to it.
///
/// Runs a bounded discovery with `Transport: le` and waits for the device
/// object to carry an `AddressType`, which is what tells BlueZ to take the LE
/// route. Discovery is stopped again either way: leaving it running would keep
/// the radio busy for the life of the link.
static void swiftpwa_ble_ensure_le_view(swiftpwa_ble_session *session) {
    char *adapter = swiftpwa_ble_find_adapter(session, NULL);
    if (!adapter) return;

    GVariant *connected = swiftpwa_ble_get_property(
        session, session->device_path, SWIFTPWA_BLUEZ_DEVICE, "Connected"
    );
    if (connected) {
        gboolean already = g_variant_get_boolean(connected);
        g_variant_unref(connected);
        if (already) { g_free(adapter); return; }
    }

    GVariantBuilder filter;
    g_variant_builder_init(&filter, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&filter, "{sv}", "Transport", g_variant_new_string("le"));
    char *error = NULL;
    swiftpwa_ble_call(
        session, adapter, SWIFTPWA_BLUEZ_ADAPTER, "SetDiscoveryFilter",
        g_variant_new("(a{sv})", &filter), &error
    );
    g_free(error);
    error = NULL;
    if (swiftpwa_ble_call(session, adapter, SWIFTPWA_BLUEZ_ADAPTER, "StartDiscovery", NULL, &error)) {
        // Up to five seconds, checked ten times a second — a peripheral
        // already advertising is usually seen on the first or second look.
        for (int i = 0; i < 50; i++) {
            GVariant *address_type = swiftpwa_ble_get_property(
                session, session->device_path, SWIFTPWA_BLUEZ_DEVICE, "AddressType"
            );
            if (address_type) {
                g_variant_unref(address_type);
                break;
            }
            g_usleep(100000);
        }
        char *stop_error = NULL;
        swiftpwa_ble_call(session, adapter, SWIFTPWA_BLUEZ_ADAPTER, "StopDiscovery", NULL, &stop_error);
        g_free(stop_error);
    }
    g_free(error);
    g_free(adapter);
}

static swiftpwa_ble_session *swiftpwa_ble_connect(
    const char *address, swiftpwa_ble_callback callback, void *user_data, char **error_out
) {
    swiftpwa_ble_session *session = swiftpwa_ble_session_new(error_out);
    if (!session) return NULL;
    session->callback = callback;
    session->user_data = user_data;

    int powered = 0;
    char *adapter = swiftpwa_ble_find_adapter(session, &powered);
    if (!adapter || !powered) {
        if (error_out) *error_out = g_strdup("Bluetooth is switched off or unavailable");
        g_free(adapter);
        swiftpwa_ble_session_free(session);
        return NULL;
    }
    char *device_suffix = g_strdup(address);
    for (char *p = device_suffix; *p; p++) {
        if (*p == ':') *p = '_';
    }
    session->device_path = g_strdup_printf("%s/dev_%s", adapter, device_suffix);
    g_free(device_suffix);
    g_free(adapter);

    g_main_context_push_thread_default(session->context);
    session->device_signal = g_dbus_connection_signal_subscribe(
        session->bus, SWIFTPWA_BLUEZ, "org.freedesktop.DBus.Properties",
        "PropertiesChanged", NULL, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
        swiftpwa_ble_link_changed, session, NULL
    );
    g_main_context_pop_thread_default(session->context);

    // A short LE discovery before connecting, unless BlueZ already has an LE
    // view of this device.
    //
    // `Device1.Connect()` connects "all profiles", and for a dual-mode
    // peripheral — every Mac, every phone — BlueZ prefers BR/EDR unless the
    // device object was built from an LE scan. Without this it answers
    // `br-connection-key-missing`: a pairing error about classic Bluetooth,
    // raised while trying to reach a GATT service over LE, which is a long way
    // from anything the caller did wrong.
    swiftpwa_ble_ensure_le_view(session);

    char *connect_error = NULL;
    if (!swiftpwa_ble_call(
            session, session->device_path, SWIFTPWA_BLUEZ_DEVICE, "Connect", NULL, &connect_error
        )) {
        // A dual-mode peripheral — a Mac, a phone, anything that is also a
        // classic Bluetooth device — advertises over LE from the same address
        // its classic radio uses, so BlueZ keeps *one* device object carrying
        // both identities and `Connect()` takes the classic route. The failure
        // is `br-connection-key-missing`: a pairing error about a transport
        // the caller never asked for.
        //
        // Measured rather than assumed: removing the cached device and
        // rebuilding it from an LE-only scan doesn't change BlueZ's mind, and
        // `bluetoothctl` "succeeds" here only by starting a classic pairing
        // and asking the user to confirm a passkey. So the honest answer is to
        // say what happened and what fixes it, rather than to quietly unpair
        // things on the user's machine hoping for a different outcome.
        if (error_out) {
            *error_out = strstr(connect_error, "br-connection") || strstr(connect_error, "key-missing")
                ? g_strdup_printf(
                    "%s — this peripheral also speaks classic Bluetooth, and BlueZ tries that "
                    "first. Pairing it once (bluetoothctl pair %s) is the usual fix; an LE-only "
                    "peripheral never takes this path.",
                    connect_error, address
                )
                : g_strdup(connect_error);
        }
        g_free(connect_error);
        swiftpwa_ble_session_free(session);
        return NULL;
    }

    // BlueZ often has the whole tree resolved by the time Connect returns,
    // and the signal for it has then already been and gone.
    GVariant *resolved = swiftpwa_ble_get_property(
        session, session->device_path, SWIFTPWA_BLUEZ_DEVICE, "ServicesResolved"
    );
    if (resolved) {
        if (g_variant_get_boolean(resolved) && !session->reported_ready) {
            session->reported_ready = 1;
            GString *state = g_string_new("{\"kind\":\"state\",\"connected\":true}");
            swiftpwa_ble_emit(session, state);
            swiftpwa_ble_emit_ready(session);
        }
        g_variant_unref(resolved);
    }
    return session;
}

static void swiftpwa_ble_disconnect(swiftpwa_ble_session *session) {
    if (!session) return;
    char *error = NULL;
    swiftpwa_ble_call(session, session->device_path, SWIFTPWA_BLUEZ_DEVICE, "Disconnect", NULL, &error);
    g_free(error);
    session->callback = NULL;
    swiftpwa_ble_session_free(session);
}

static int swiftpwa_ble_write(
    swiftpwa_ble_session *session, const char *uuid,
    const unsigned char *bytes, int length, int with_response, char **error_out
) {
    char *path = swiftpwa_ble_characteristic_path(session, uuid);
    if (!path) {
        if (error_out) *error_out = g_strdup_printf("this peripheral has no characteristic %s", uuid);
        return 0;
    }
    GVariantBuilder value;
    g_variant_builder_init(&value, G_VARIANT_TYPE("ay"));
    for (int i = 0; i < length; i++) g_variant_builder_add(&value, "y", bytes[i]);

    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(
        &options, "{sv}", "type", g_variant_new_string(with_response ? "request" : "command")
    );

    int ok = swiftpwa_ble_call(
        session, path, SWIFTPWA_BLUEZ_CHARACTERISTIC, "WriteValue",
        g_variant_new("(aya{sv})", &value, &options), error_out
    );
    g_free(path);
    return ok;
}

/// Reads into a caller-owned base64 string, because that's what crosses
/// into Swift everywhere else in this contract.
static char *swiftpwa_ble_read(swiftpwa_ble_session *session, const char *uuid, char **error_out) {
    char *path = swiftpwa_ble_characteristic_path(session, uuid);
    if (!path) {
        if (error_out) *error_out = g_strdup_printf("this peripheral has no characteristic %s", uuid);
        return NULL;
    }
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE("a{sv}"));

    GError *error = NULL;
    GVariant *reply = g_dbus_connection_call_sync(
        session->bus, SWIFTPWA_BLUEZ, path, SWIFTPWA_BLUEZ_CHARACTERISTIC, "ReadValue",
        g_variant_new("(a{sv})", &options), G_VARIANT_TYPE("(ay)"),
        G_DBUS_CALL_FLAGS_NONE, 20000, NULL, &error
    );
    g_free(path);
    if (!reply) {
        if (error_out) *error_out = g_strdup(error ? error->message : "the read failed");
        if (error) g_error_free(error);
        return NULL;
    }
    GVariant *array = g_variant_get_child_value(reply, 0);
    gsize length = 0;
    const guchar *data = g_variant_get_fixed_array(array, &length, sizeof(guchar));
    char *encoded = g_base64_encode(data, length);
    g_variant_unref(array);
    g_variant_unref(reply);
    return encoded;
}

static int swiftpwa_ble_set_notify(
    swiftpwa_ble_session *session, const char *uuid, int enabled, char **error_out
) {
    char *path = swiftpwa_ble_characteristic_path(session, uuid);
    if (!path) {
        if (error_out) *error_out = g_strdup_printf("this peripheral has no characteristic %s", uuid);
        return 0;
    }
    // Remember what's subscribed. BlueZ raises `Value` PropertiesChanged for
    // a `ReadValue` too, so without this a read comes back to the page as a
    // notification it never asked for — which then looks like the peripheral
    // pushing data on its own.
    if (enabled) {
        if (!g_list_find_custom(session->notifying, path, (GCompareFunc)g_strcmp0)) {
            session->notifying = g_list_prepend(session->notifying, g_strdup(path));
        }
    } else {
        GList *entry = g_list_find_custom(session->notifying, path, (GCompareFunc)g_strcmp0);
        if (entry) {
            g_free(entry->data);
            session->notifying = g_list_delete_link(session->notifying, entry);
        }
    }
    int ok = swiftpwa_ble_call(
        session, path, SWIFTPWA_BLUEZ_CHARACTERISTIC,
        enabled ? "StartNotify" : "StopNotify", NULL, error_out
    );
    g_free(path);
    return ok;
}

#endif /* SWIFT_PWA_BLUEZ_SHIM_H */

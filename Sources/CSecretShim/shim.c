#include "CSecretShim.h"

#include <stdlib.h>

#ifdef __linux__

#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>

// libsecret is loaded with `dlopen` rather than linked, for the same reason
// CHeifShim loads libheif that way: a link would put `libsecret-1.so.0` (and
// the glib trio it drags in) in this binary's `DT_NEEDED` list, so **every**
// swift-pwa binary — including the `swift-pwa` CLI, which never touches a
// keyring — refuses to start on a machine without them. That is not
// hypothetical; it is half of the first-run failure in #199. It also drops
// `libsecret-1-dev` from the Linux build prerequisites, since nothing here
// includes its headers any more.
//
// The cost is transcribing the slice of ABI we call. It is small — three
// functions, one free, one struct passed by pointer — and the real-keyring
// round-trip test is what pins it, since a wrong struct layout would show up
// as a lookup that finds nothing rather than as a compile error.

typedef uint32_t GQuark;

// glib's GError: `GQuark domain; gint code; gchar *message;`.
typedef struct {
    GQuark domain;
    int code;
    char *message;
} GError;

// libsecret's SecretSchemaAttributeType. Only STRING is used here.
enum { SWIFTPWA_SECRET_SCHEMA_ATTRIBUTE_STRING = 0 };
// SecretSchemaFlags. NONE means "don't require the schema name to match on
// lookup" — we still match on the attributes.
enum { SWIFTPWA_SECRET_SCHEMA_NONE = 0 };

typedef struct {
    const char *name;
    int type;
} SecretSchemaAttribute;

// The fixed-size-32 attribute array and the eight reserved fields are part of
// the ABI, not an implementation detail — libsecret indexes past the array and
// reads the trailing fields, so the struct must be laid out exactly as its
// header declares it.
typedef struct {
    const char *name;
    int flags;
    SecretSchemaAttribute attributes[32];

    // <private> in the header; zero-initialized.
    int reserved;
    void *reserved1;
    void *reserved2;
    void *reserved3;
    void *reserved4;
    void *reserved5;
    void *reserved6;
    void *reserved7;
} SecretSchema;

// SECRET_COLLECTION_DEFAULT.
static const char *const kDefaultCollection = "default";

// All three are NULL-terminated variadic functions taking `name, value` pairs.
typedef int (*fn_store_sync)(const SecretSchema *, const char *, const char *, const char *, void *, GError **, ...);
typedef char *(*fn_lookup_sync)(const SecretSchema *, void *, GError **, ...);
typedef int (*fn_clear_sync)(const SecretSchema *, void *, GError **, ...);
typedef void (*fn_password_free)(char *);
typedef void (*fn_error_free)(GError *);

static struct {
    void *handle;
    fn_store_sync store;
    fn_lookup_sync lookup;
    fn_clear_sync clear;
    fn_password_free password_free;
    fn_error_free error_free;
    int usable;
} lib;

static pthread_once_t load_once = PTHREAD_ONCE_INIT;

static void load_libsecret(void) {
    // The SONAME, not the bare `.so` symlink: that symlink ships in
    // libsecret-1-dev, which is the package this is avoiding.
    lib.handle = dlopen("libsecret-1.so.0", RTLD_LAZY | RTLD_LOCAL);
    if (!lib.handle) {
        return;
    }

    lib.store = (fn_store_sync)dlsym(lib.handle, "secret_password_store_sync");
    lib.lookup = (fn_lookup_sync)dlsym(lib.handle, "secret_password_lookup_sync");
    lib.clear = (fn_clear_sync)dlsym(lib.handle, "secret_password_clear_sync");
    lib.password_free = (fn_password_free)dlsym(lib.handle, "secret_password_free");

    // glib is in libsecret's own dependency tree, so its symbols resolve
    // through this handle; fall back to loading it directly in case a distro
    // ever links it differently.
    lib.error_free = (fn_error_free)dlsym(lib.handle, "g_error_free");
    if (!lib.error_free) {
        void *glib = dlopen("libglib-2.0.so.0", RTLD_LAZY | RTLD_LOCAL);
        if (glib) {
            lib.error_free = (fn_error_free)dlsym(glib, "g_error_free");
        }
    }

    lib.usable = lib.store && lib.lookup && lib.clear && lib.password_free && lib.error_free;
}

static int ensure_loaded(void) {
    pthread_once(&load_once, load_libsecret);
    return lib.usable;
}

// One schema for all swift-pwa secrets. Two string attributes — `service`
// (per-app namespace) and `key`. The `attributes` array is NULL-name-terminated.
static const SecretSchema *swiftpwa_schema(void) {
    static const SecretSchema schema = {
        "dev.swiftpwa.Secret",
        SWIFTPWA_SECRET_SCHEMA_NONE,
        {
            { "service", SWIFTPWA_SECRET_SCHEMA_ATTRIBUTE_STRING },
            { "key", SWIFTPWA_SECRET_SCHEMA_ATTRIBUTE_STRING },
            { NULL, 0 },
        },
        // Reserved fields — zero-initialized.
        0, 0, 0, 0, 0, 0, 0, 0,
    };
    return &schema;
}

// Release a GError and report that an error happened. Safe to call with NULL.
static void discard_error(GError *error) {
    if (error != NULL && lib.error_free != NULL) {
        lib.error_free(error);
    }
}

int swiftpwa_secret_set(const char *service, const char *key, const char *value) {
    if (!ensure_loaded()) {
        return 3;
    }
    GError *error = NULL;
    int ok = lib.store(
        swiftpwa_schema(),
        kDefaultCollection,
        "swift-pwa secret",
        value,
        NULL, // GCancellable
        &error,
        "service", service,
        "key", key,
        NULL);
    if (error != NULL) {
        discard_error(error);
        return 1;
    }
    return ok ? 0 : 2;
}

int swiftpwa_secret_get(const char *service, const char *key, char **out_value) {
    *out_value = NULL;
    if (!ensure_loaded()) {
        return 2;
    }
    GError *error = NULL;
    char *password = lib.lookup(
        swiftpwa_schema(),
        NULL, // GCancellable
        &error,
        "service", service,
        "key", key,
        NULL);
    if (error != NULL) {
        discard_error(error);
        return 2; // error (e.g. no Secret Service)
    }
    if (password == NULL) {
        return 1; // not found
    }
    // Copy into a malloc'd buffer the caller frees; release libsecret's copy
    // (which is allocated with its own secure-free).
    *out_value = strdup(password);
    lib.password_free(password);
    return (*out_value != NULL) ? 0 : 2;
}

int swiftpwa_secret_delete(const char *service, const char *key) {
    if (!ensure_loaded()) {
        return 3;
    }
    GError *error = NULL;
    // Returns whether an item was removed; "nothing to remove" is not an error,
    // so we only fail on a real GError (idempotent delete).
    lib.clear(
        swiftpwa_schema(),
        NULL, // GCancellable
        &error,
        "service", service,
        "key", key,
        NULL);
    if (error != NULL) {
        discard_error(error);
        return 1;
    }
    return 0;
}

void swiftpwa_secret_string_free(char *value) {
    free(value);
}

int swiftpwa_secret_available(void) {
    return ensure_loaded();
}

#else

// Non-Linux builds never compile the Secret Service store; these exist so the
// target still produces an object file.
int swiftpwa_secret_set(const char *service, const char *key, const char *value) {
    (void)service;
    (void)key;
    (void)value;
    return 3;
}

int swiftpwa_secret_get(const char *service, const char *key, char **out_value) {
    (void)service;
    (void)key;
    *out_value = NULL;
    return 2;
}

int swiftpwa_secret_delete(const char *service, const char *key) {
    (void)service;
    (void)key;
    return 3;
}

void swiftpwa_secret_string_free(char *value) {
    free(value);
}

int swiftpwa_secret_available(void) {
    return 0;
}

#endif

#include "CSecretShim.h"
#include <libsecret/secret.h>
#include <stdlib.h>
#include <string.h>

// One schema for all swift-pwa secrets. Two string attributes — `service`
// (per-app namespace) and `key`. SECRET_SCHEMA_NONE = don't require the schema
// name to match on lookup (we still match on the attributes). The `attributes`
// array is NULL-name-terminated.
static const SecretSchema *swiftpwa_schema(void) {
    static const SecretSchema schema = {
        "dev.swiftpwa.Secret",
        SECRET_SCHEMA_NONE,
        {
            { "service", SECRET_SCHEMA_ATTRIBUTE_STRING },
            { "key", SECRET_SCHEMA_ATTRIBUTE_STRING },
            { NULL, 0 },
        },
        // Reserved fields — zero-initialized.
        0, 0, 0, 0, 0, 0, 0, 0,
    };
    return &schema;
}

int swiftpwa_secret_set(const char *service, const char *key, const char *value) {
    GError *error = NULL;
    gboolean ok = secret_password_store_sync(
        swiftpwa_schema(),
        SECRET_COLLECTION_DEFAULT,
        "swift-pwa secret",
        value,
        NULL, // GCancellable
        &error,
        "service", service,
        "key", key,
        NULL);
    if (error != NULL) {
        g_error_free(error);
        return 1;
    }
    return ok ? 0 : 2;
}

int swiftpwa_secret_get(const char *service, const char *key, char **out_value) {
    *out_value = NULL;
    GError *error = NULL;
    gchar *password = secret_password_lookup_sync(
        swiftpwa_schema(),
        NULL, // GCancellable
        &error,
        "service", service,
        "key", key,
        NULL);
    if (error != NULL) {
        g_error_free(error);
        return 2; // error (e.g. no Secret Service)
    }
    if (password == NULL) {
        return 1; // not found
    }
    // Copy into a malloc'd buffer the caller frees; release libsecret's copy
    // (which is allocated with its own secure-free).
    *out_value = strdup(password);
    secret_password_free(password);
    return (*out_value != NULL) ? 0 : 2;
}

int swiftpwa_secret_delete(const char *service, const char *key) {
    GError *error = NULL;
    // Returns whether an item was removed; "nothing to remove" is not an error,
    // so we only fail on a real GError (idempotent delete).
    secret_password_clear_sync(
        swiftpwa_schema(),
        NULL, // GCancellable
        &error,
        "service", service,
        "key", key,
        NULL);
    if (error != NULL) {
        g_error_free(error);
        return 1;
    }
    return 0;
}

void swiftpwa_secret_string_free(char *value) {
    free(value);
}

#!/usr/bin/env bash
#
# Check the libsecret ABI that Sources/CSecretShim/shim.c transcribes by hand
# against libsecret's real headers. Every comparison is a `static_assert`, so
# drift is a compile error rather than a wrong answer at runtime.
#
# Why a script and not a test: the shim `dlopen`s libsecret precisely so that
# `libsecret-1-dev` is NOT a build prerequisite (#199), and CI no longer
# installs it. This needs those headers, so it runs on demand — when you touch
# the shim, or when a distro ships a new libsecret major.
#
#   Scripts/verify-libsecret-abi.sh              # here, if the dev package is installed
#   Scripts/verify-libsecret-abi.sh --host <box> # on a Linux box over ssh
#
# A layout mismatch would otherwise surface as a lookup that quietly finds
# nothing, which is the worst way to learn about it.
set -euo pipefail

HOST=""
[[ "${1:-}" == "--host" ]] && HOST="${2:-}"

SRC="$(mktemp -t libsecret-abi-XXXXXX).c"
cat > "$SRC" <<'PROGRAM'
// Compares the structs CSecretShim transcribes by hand against the ones in
// libsecret's / glib's real headers. Any drift is a compile error.
#include <libsecret/secret.h>
#include <glib.h>
#include <stdint.h>
#include <stddef.h>
#include <assert.h>
#include <stdio.h>

// ---- verbatim copies of the transcriptions in Sources/CSecretShim/shim.c ----
typedef uint32_t MyGQuark;
typedef struct { MyGQuark domain; int code; char *message; } MyGError;
typedef struct { const char *name; int type; } MySecretSchemaAttribute;
typedef struct {
    const char *name;
    int flags;
    MySecretSchemaAttribute attributes[32];
    int reserved;
    void *reserved1; void *reserved2; void *reserved3; void *reserved4;
    void *reserved5; void *reserved6; void *reserved7;
} MySecretSchema;
// ---------------------------------------------------------------------------

#define SAME_SIZE(a, b) static_assert(sizeof(a) == sizeof(b), #a " vs " #b " size")
#define SAME_OFF(a, fa, b, fb) static_assert(offsetof(a, fa) == offsetof(b, fb), #a "." #fa " offset")

SAME_SIZE(MyGError, GError);
SAME_OFF(MyGError, domain, GError, domain);
SAME_OFF(MyGError, code, GError, code);
SAME_OFF(MyGError, message, GError, message);

SAME_SIZE(MySecretSchemaAttribute, SecretSchemaAttribute);
SAME_OFF(MySecretSchemaAttribute, name, SecretSchemaAttribute, name);
SAME_OFF(MySecretSchemaAttribute, type, SecretSchemaAttribute, type);

SAME_SIZE(MySecretSchema, SecretSchema);
SAME_OFF(MySecretSchema, name, SecretSchema, name);
SAME_OFF(MySecretSchema, flags, SecretSchema, flags);
SAME_OFF(MySecretSchema, attributes, SecretSchema, attributes);
SAME_OFF(MySecretSchema, reserved, SecretSchema, reserved);
SAME_OFF(MySecretSchema, reserved7, SecretSchema, reserved7);

// The two enum values and the collection name the shim hardcodes.
static_assert(SECRET_SCHEMA_NONE == 0, "SECRET_SCHEMA_NONE");
static_assert(SECRET_SCHEMA_ATTRIBUTE_STRING == 0, "SECRET_SCHEMA_ATTRIBUTE_STRING");

int main(void) {
    printf("SecretSchema: %zu bytes, attributes at %zu, reserved at %zu\n",
           sizeof(SecretSchema), offsetof(SecretSchema, attributes), offsetof(SecretSchema, reserved));
    printf("GError: %zu bytes\n", sizeof(GError));
    printf("SECRET_COLLECTION_DEFAULT = \"%s\"\n", SECRET_COLLECTION_DEFAULT);
    return 0;
}
PROGRAM

run() {
    gcc -std=c11 "$1" $(pkg-config --cflags --libs libsecret-1) -o "${1%.c}" \
        && "${1%.c}" \
        && echo "libsecret ABI matches the shim's transcription."
}

if [[ -n "$HOST" ]]; then
    scp -q "$SRC" "$HOST:/tmp/$(basename "$SRC")"
    # shellcheck disable=SC2029
    ssh "$HOST" "bash -s" <<REMOTE
set -euo pipefail
cd /tmp
gcc -std=c11 "$(basename "$SRC")" \$(pkg-config --cflags --libs libsecret-1) -o abicheck
./abicheck
echo "libsecret ABI matches the shim's transcription."
REMOTE
else
    command -v pkg-config >/dev/null || { echo "pkg-config not found" >&2; exit 2; }
    pkg-config --exists libsecret-1 || {
        echo "libsecret-1 headers not found — install libsecret-1-dev, or pass --host <linux-box>" >&2
        exit 2
    }
    run "$SRC"
fi

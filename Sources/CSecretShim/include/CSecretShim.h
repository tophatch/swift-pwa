#pragma once
#include <stddef.h>

// A thin C wrapper over libsecret's Secret Service password API, so the Swift
// side calls plain functions instead of libsecret's variadic
// `secret_password_*_sync` + the fixed-size-32 `SecretSchema` struct (both
// awkward from Swift). Secrets are keyed by (service, key) attributes under a
// single app schema; the value is the password. Synchronous (the Swift store
// runs these off the main actor).
//
// libsecret is `dlopen`ed, not linked — see the note in shim.c. A binary that
// never stores a secret therefore doesn't require libsecret to be installed to
// *start*, which is what linking it cost us (#199).

// Store `value` under (service, key). Returns 0 on success, non-zero on failure
// (e.g. no Secret Service / keyring available).
int swiftpwa_secret_set(const char *service, const char *key, const char *value);

// Look up (service, key). Returns:
//   0  = found; *out_value points to a newly-allocated C string (free with
//        swiftpwa_secret_string_free).
//   1  = not found (no error); *out_value is NULL.
//   2  = error (e.g. no Secret Service); *out_value is NULL.
int swiftpwa_secret_get(const char *service, const char *key, char **out_value);

// Remove (service, key). Returns 0 on success (including "wasn't there" —
// idempotent), non-zero on error.
int swiftpwa_secret_delete(const char *service, const char *key);

// Free a string returned by swiftpwa_secret_get.
void swiftpwa_secret_string_free(char *value);

// Whether libsecret could be loaded at all. False means the library isn't
// installed — a different problem from "installed, but no keyring is running",
// and a different fix, so the Swift store reports them separately.
int swiftpwa_secret_available(void);

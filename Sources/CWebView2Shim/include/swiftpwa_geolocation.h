// swiftpwa_geolocation — Windows location (`Windows.Devices.Geolocation`)
// behind a flat C ABI.
//
// Why a C++/WinRT shim and not raw Swift: `Geolocator` is asynchronous
// (`IAsyncOperation<Geoposition>`) and event-based (`PositionChanged`), and
// the results are nested WinRT projections. That's the same `Completed(...)`
// plumbing the biometric shim already does here, and Swift bridges each
// callback back to a continuation / AsyncThrowingStream.
//
// UNLIKE `CPhiSilica`, this is **built-in WinRT** — no NuGet package, no
// Windows App SDK bootstrapper, nothing to provision. It rides the
// `WindowsApp.lib` this target already links.
//
// Access is governed by Settings → Privacy & security → Location, at both
// system and per-app scope. `RequestAccessAsync` reports the answer;
// unpackaged Win32 apps are covered by the desktop-app toggle rather than
// getting their own entry, so a refusal usually means location is off for
// desktop apps generally.

#ifndef SWIFT_PWA_GEOLOCATION_SHIM_H
#define SWIFT_PWA_GEOLOCATION_SHIM_H

#include <stdint.h>
#include <wchar.h>

#ifdef __cplusplus
extern "C" {
#endif

// One position, in the units the web platform uses. `has_*` marks the
// fields WinRT leaves empty — they're `IReference<double>`, genuinely
// absent rather than zero, and passing 0 through would be a lie.
typedef struct {
    double latitude;
    double longitude;
    double accuracy;
    double altitude;
    double altitude_accuracy;
    double speed;
    double heading;
    double timestamp;
    int32_t has_altitude;
    int32_t has_altitude_accuracy;
    int32_t has_speed;
    int32_t has_heading;
} swiftpwa_geo_position;

// Why a fix didn't happen. Kept apart because an app shows something
// different for each, and collapsing them is what makes a location feature
// feel broken.
typedef enum {
    SWIFTPWA_WINGEO_NONE = 0,        // Success — `position` is set.
    SWIFTPWA_WINGEO_DENIED = 1,       // Location off, for the system or this app.
    SWIFTPWA_WINGEO_UNAVAILABLE = 2,  // No source, no hardware, radio off.
    SWIFTPWA_WINGEO_TIMEOUT = 3,      // Nothing arrived in time; retrying is reasonable.
} swiftpwa_wingeo_error_kind;

// Fires once per position for a watch, or once for a one-shot. Exactly one
// of `position` / `error` is non-NULL. Both are owned by the shim and valid
// only for the duration of the call — copy in Swift.
typedef void (*swiftpwa_wingeo_callback)(
    const swiftpwa_geo_position *position,
    swiftpwa_wingeo_error_kind error_kind,
    const wchar_t *error_message,
    void *user_data);

typedef struct swiftpwa_wingeo_session swiftpwa_wingeo_session;

// One position. `high_accuracy` selects `PositionAccuracy::High`; the
// callback fires exactly once.
void swiftpwa_wingeo_get_position(
    int32_t high_accuracy,
    uint32_t timeout_ms,
    uint32_t maximum_age_seconds,
    swiftpwa_wingeo_callback callback,
    void *user_data);

// Positions until `swiftpwa_wingeo_stop`. Returns NULL when the session
// couldn't start, having already reported why through the callback.
swiftpwa_wingeo_session *swiftpwa_wingeo_watch(
    int32_t high_accuracy,
    swiftpwa_wingeo_callback callback,
    void *user_data);

// Detaches the handler and releases the session. Safe with NULL.
void swiftpwa_wingeo_stop(swiftpwa_wingeo_session *session);

#ifdef __cplusplus
}
#endif

#endif

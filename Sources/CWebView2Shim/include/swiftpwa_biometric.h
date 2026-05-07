// swiftpwa_biometric — Windows Hello (UserConsentVerifier) behind a
// flat C ABI.
//
// Why a C++/WinRT shim and not raw Swift: the verifier surface is
// asynchronous (IAsyncOperation<...>), and the result types are WinRT
// enums. Doing the projection by hand from Swift adds significant
// complexity for two functions; doing it in C++/WinRT is ~30 lines
// of `Completed(...)` plumbing. We use the same callback-based shape
// as the GTK4 dialog shim — Swift bridges back to a continuation.
//
// The verifier requires application identity to *reliably* succeed
// (i.e. an MSIX-packaged build). Unpackaged portable EXEs may see
// `device-not-present` even on machines with Windows Hello set up
// — this is a Windows/WinRT quirk, not a swift-pwa bug. We expose
// the raw enum so the caller can distinguish the failure mode.

#ifndef SWIFT_PWA_BIOMETRIC_SHIM_H
#define SWIFT_PWA_BIOMETRIC_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Mirrors WinRT's `UserConsentVerifierAvailability`.
typedef enum {
    SWIFTPWA_BIO_AVAILABLE = 0,
    SWIFTPWA_BIO_DEVICE_NOT_PRESENT = 1,
    SWIFTPWA_BIO_NOT_CONFIGURED = 2,
    SWIFTPWA_BIO_DISABLED_BY_POLICY = 3,
    SWIFTPWA_BIO_DEVICE_BUSY = 4,
    SWIFTPWA_BIO_FAILED = -1,
} swiftpwa_biometric_availability;

// Mirrors WinRT's `UserConsentVerificationResult`.
typedef enum {
    SWIFTPWA_BIO_VERIFIED = 0,
    SWIFTPWA_BIO_VERIFY_DEVICE_NOT_PRESENT = 1,
    SWIFTPWA_BIO_VERIFY_NOT_CONFIGURED = 2,
    SWIFTPWA_BIO_VERIFY_DISABLED_BY_POLICY = 3,
    SWIFTPWA_BIO_VERIFY_DEVICE_BUSY = 4,
    SWIFTPWA_BIO_VERIFY_RETRIES_EXHAUSTED = 5,
    SWIFTPWA_BIO_VERIFY_CANCELED = 6,
    SWIFTPWA_BIO_VERIFY_FAILED = -1,
} swiftpwa_biometric_verify_result;

typedef void (*swiftpwa_biometric_availability_callback)(
    swiftpwa_biometric_availability result, void *user_data);

typedef void (*swiftpwa_biometric_verify_callback)(
    swiftpwa_biometric_verify_result result, void *user_data);

// Asynchronously check whether biometric verification is available.
// Fires `cb(result, user_data)` on a background thread once WinRT
// resolves the IAsyncOperation; the Swift side hops back to the
// UI thread internally if it cares.
void swiftpwa_biometric_check_availability(
    swiftpwa_biometric_availability_callback cb,
    void *user_data);

// Show the Windows Hello prompt with `message` as the reason.
// Fires `cb(result, user_data)` when the user dismisses (verify /
// cancel / device unavailable / etc).
void swiftpwa_biometric_request_verification(
    const wchar_t *message,
    swiftpwa_biometric_verify_callback cb,
    void *user_data);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // SWIFT_PWA_BIOMETRIC_SHIM_H

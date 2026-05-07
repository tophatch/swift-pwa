// swiftpwa_biometric — Windows Hello via UserConsentVerifier.
// See include/swiftpwa_biometric.h for the rationale + ABI.

#if defined(_WIN32) || defined(_WIN64)

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include "swiftpwa_biometric.h"

#include <windows.h>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Security.Credentials.UI.h>

namespace WSCU = winrt::Windows::Security::Credentials::UI;
namespace WF = winrt::Windows::Foundation;

namespace {

// `Completed(...)` on an `IAsyncOperation<T>` fires once with the
// final status and result; it's the canonical way to wire a callback
// without using `co_await`. We use it to keep the shim free of
// coroutines (which would also work but expand the binary).

swiftpwa_biometric_availability map_availability(WSCU::UserConsentVerifierAvailability v) {
    switch (v) {
        case WSCU::UserConsentVerifierAvailability::Available:
            return SWIFTPWA_BIO_AVAILABLE;
        case WSCU::UserConsentVerifierAvailability::DeviceNotPresent:
            return SWIFTPWA_BIO_DEVICE_NOT_PRESENT;
        case WSCU::UserConsentVerifierAvailability::NotConfiguredForUser:
            return SWIFTPWA_BIO_NOT_CONFIGURED;
        case WSCU::UserConsentVerifierAvailability::DisabledByPolicy:
            return SWIFTPWA_BIO_DISABLED_BY_POLICY;
        case WSCU::UserConsentVerifierAvailability::DeviceBusy:
            return SWIFTPWA_BIO_DEVICE_BUSY;
        default:
            return SWIFTPWA_BIO_FAILED;
    }
}

swiftpwa_biometric_verify_result map_verify(WSCU::UserConsentVerificationResult v) {
    switch (v) {
        case WSCU::UserConsentVerificationResult::Verified:
            return SWIFTPWA_BIO_VERIFIED;
        case WSCU::UserConsentVerificationResult::DeviceNotPresent:
            return SWIFTPWA_BIO_VERIFY_DEVICE_NOT_PRESENT;
        case WSCU::UserConsentVerificationResult::NotConfiguredForUser:
            return SWIFTPWA_BIO_VERIFY_NOT_CONFIGURED;
        case WSCU::UserConsentVerificationResult::DisabledByPolicy:
            return SWIFTPWA_BIO_VERIFY_DISABLED_BY_POLICY;
        case WSCU::UserConsentVerificationResult::DeviceBusy:
            return SWIFTPWA_BIO_VERIFY_DEVICE_BUSY;
        case WSCU::UserConsentVerificationResult::RetriesExhausted:
            return SWIFTPWA_BIO_VERIFY_RETRIES_EXHAUSTED;
        case WSCU::UserConsentVerificationResult::Canceled:
            return SWIFTPWA_BIO_VERIFY_CANCELED;
        default:
            return SWIFTPWA_BIO_VERIFY_FAILED;
    }
}

bool ensure_apartment() {
    // The verifier APIs require a multithreaded apartment when called
    // off the UI thread. We init MTA on first use; if the thread is
    // already STA, RPC_E_CHANGED_MODE comes back and the existing
    // apartment continues to work for these calls.
    HRESULT hr = winrt::init_apartment(winrt::apartment_type::multi_threaded);
    return SUCCEEDED(hr) || hr == RPC_E_CHANGED_MODE;
}

} // namespace

extern "C" {

void swiftpwa_biometric_check_availability(
    swiftpwa_biometric_availability_callback cb,
    void *user_data
) {
    if (!cb) return;
    if (!ensure_apartment()) {
        cb(SWIFTPWA_BIO_FAILED, user_data);
        return;
    }
    try {
        auto op = WSCU::UserConsentVerifier::CheckAvailabilityAsync();
        op.Completed([cb, user_data](
            const WF::IAsyncOperation<WSCU::UserConsentVerifierAvailability> &sender,
            WF::AsyncStatus status
        ) {
            if (status == WF::AsyncStatus::Completed) {
                cb(map_availability(sender.GetResults()), user_data);
            } else {
                cb(SWIFTPWA_BIO_FAILED, user_data);
            }
        });
    } catch (...) {
        cb(SWIFTPWA_BIO_FAILED, user_data);
    }
}

void swiftpwa_biometric_request_verification(
    const wchar_t *message,
    swiftpwa_biometric_verify_callback cb,
    void *user_data
) {
    if (!cb) return;
    if (!ensure_apartment()) {
        cb(SWIFTPWA_BIO_VERIFY_FAILED, user_data);
        return;
    }
    try {
        winrt::hstring msg = message ? winrt::hstring{message} : winrt::hstring{L""};
        auto op = WSCU::UserConsentVerifier::RequestVerificationAsync(msg);
        op.Completed([cb, user_data](
            const WF::IAsyncOperation<WSCU::UserConsentVerificationResult> &sender,
            WF::AsyncStatus status
        ) {
            if (status == WF::AsyncStatus::Completed) {
                cb(map_verify(sender.GetResults()), user_data);
            } else {
                cb(SWIFTPWA_BIO_VERIFY_FAILED, user_data);
            }
        });
    } catch (...) {
        cb(SWIFTPWA_BIO_VERIFY_FAILED, user_data);
    }
}

} // extern "C"

#endif // _WIN32

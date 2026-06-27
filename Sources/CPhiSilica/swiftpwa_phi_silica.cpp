// swiftpwa_phi_silica — Windows Phi Silica via the Windows AI APIs in the
// Windows App SDK. See include/swiftpwa_phi_silica.h for the ABI + rationale.
//
// ┌─ BOX-PENDING ────────────────────────────────────────────────────────┐
// │ This file compiles only against the Windows App SDK cppwinrt headers  │
// │ (Microsoft.WindowsAppSDK NuGet) on INCLUDE, with the bootstrapper lib  │
// │ on LIB — neither is present in swift-pwa CI. It is built only when     │
// │ `SWIFT_PWA_PHI_SILICA=1` (the env the CLI sets from ai.phi_silica),    │
// │ and is verified on the Copilot+ NPU box (bsp12in, arm64). The exact    │
// │ streaming-progress signature, the bootstrap version tag, and the LAF   │
// │ unlock path are confirmed/adjusted there. Structure + the unary path   │
// │ follow the documented C++/WinRT sample.                                │
// └────────────────────────────────────────────────────────────────────┘

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

#include "swiftpwa_phi_silica.h"

#include <windows.h>
#include <unknwn.h>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Microsoft.Windows.AI.h>
#include <winrt/Microsoft.Windows.AI.Text.h>

// Windows App SDK bootstrapper (C API) for unpackaged apps + the SDK's own
// version constants (so the bootstrap binds the matching runtime release
// rather than a hard-coded guess).
#include <MddBootstrap.h>
#include <WindowsAppSDK-VersionInfo.h>

namespace WF = winrt::Windows::Foundation;
namespace WAM = winrt::Windows::ApplicationModel;
namespace AI = winrt::Microsoft::Windows::AI;
namespace AIT = winrt::Microsoft::Windows::AI::Text;

namespace {

bool g_bootstrapped = false;

swiftpwa_phi_silica_ready_state map_ready(AI::AIFeatureReadyState s) {
    switch (s) {
        case AI::AIFeatureReadyState::Ready:    return SWIFTPWA_PHI_READY;
        case AI::AIFeatureReadyState::NotReady: return SWIFTPWA_PHI_NOT_READY;
        // NotSupportedOnCurrentSystem / DisabledByUser / CapabilityMissing all
        // mean "can't use it here" → the backend reports available:false.
        default: return SWIFTPWA_PHI_NOT_SUPPORTED;
    }
}

bool ensure_apartment() {
    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        return true;
    } catch (...) {
        return false;
    }
}

} // namespace

extern "C" {

bool swiftpwa_phi_silica_init(void) {
    if (g_bootstrapped) return true;
    if (!ensure_apartment()) return false;
    // Initialize the Windows App SDK runtime for this (unpackaged) process,
    // using the version constants from the SDK we built against
    // (WindowsAppSDK-VersionInfo.h) so the bootstrap binds the matching
    // runtime release. `OnNoMatch_NOOP`-free: a failure (runtime absent)
    // returns false → the backend reports unavailable rather than crashing.
    PACKAGE_VERSION minVersion{};
    HRESULT hr = MddBootstrapInitialize2(
        WINDOWSAPPSDK_RELEASE_MAJORMINOR,
        WINDOWSAPPSDK_RELEASE_VERSION_TAG_W,
        minVersion,
        MddBootstrapInitializeOptions_OnPackageIdentity_NOOP);
    if (FAILED(hr)) return false;
    g_bootstrapped = true;
    return true;
}

bool swiftpwa_phi_silica_unlock(const wchar_t *token) {
    if (!swiftpwa_phi_silica_init()) return false;
    try {
        const winrt::hstring featureId = L"com.microsoft.windows.ai.languagemodel";
        // Standard LAF attestation format: "<PFN> has registered their use of
        // <featureId> with Microsoft and agrees to the terms of use." Built from
        // the running package's identity (throws if unpackaged → caught below).
        winrt::hstring pfn = WAM::Package::Current().Id().FamilyName();
        winrt::hstring attestation = pfn + L" has registered their use of " + featureId
            + L" with Microsoft and agrees to the terms of use.";
        auto result = WAM::LimitedAccessFeatures::TryUnlockFeature(
            featureId, token ? winrt::hstring{token} : winrt::hstring{L""}, attestation);
        auto status = result.Status();
        return status == WAM::LimitedAccessFeatureStatus::Available
            || status == WAM::LimitedAccessFeatureStatus::AvailableWithoutToken;
    } catch (...) {
        return false;
    }
}

swiftpwa_phi_silica_ready_state swiftpwa_phi_silica_ready_state_query(void) {
    if (!swiftpwa_phi_silica_init()) return SWIFTPWA_PHI_ERROR;
    try {
        // CapabilityMissing / DisabledByUser / NotCompatibleWithSystemHardware /
        // OSUpdateNeeded all collapse to NOT_SUPPORTED in map_ready. An
        // unpackaged process gets CapabilityMissing here (the Windows AI APIs
        // need package identity + the systemAIModels capability — see
        // docs/windows-setup.md), so the backend reports available:false.
        return map_ready(AIT::LanguageModel::GetReadyState());
    } catch (...) {
        return SWIFTPWA_PHI_ERROR;
    }
}

void swiftpwa_phi_silica_ensure_ready(
    swiftpwa_phi_silica_done_callback cb, void *user_data
) {
    if (!cb) return;
    if (!swiftpwa_phi_silica_init()) { cb(nullptr, L"Windows App SDK runtime unavailable", user_data); return; }
    try {
        if (AIT::LanguageModel::GetReadyState() == AI::AIFeatureReadyState::Ready) {
            cb(nullptr, nullptr, user_data);
            return;
        }
        auto op = AIT::LanguageModel::EnsureReadyAsync();
        op.Completed([cb, user_data](auto const &, WF::AsyncStatus status) {
            if (status == WF::AsyncStatus::Completed) cb(nullptr, nullptr, user_data);
            else cb(nullptr, L"EnsureReadyAsync failed", user_data);
        });
    } catch (winrt::hresult_error const &e) {
        cb(nullptr, e.message().c_str(), user_data);
    } catch (...) {
        cb(nullptr, L"ensure failed", user_data);
    }
}

void swiftpwa_phi_silica_generate(
    const wchar_t *prompt,
    swiftpwa_phi_silica_done_callback cb,
    void *user_data
) {
    if (!cb) return;
    if (!swiftpwa_phi_silica_init()) { cb(nullptr, L"Windows App SDK runtime unavailable", user_data); return; }
    try {
        winrt::hstring p = prompt ? winrt::hstring{prompt} : winrt::hstring{L""};
        auto languageModel = AIT::LanguageModel::CreateAsync().get();
        auto op = languageModel.GenerateResponseAsync(p);
        op.Completed([cb, user_data](auto const &sender, WF::AsyncStatus status) {
            if (status == WF::AsyncStatus::Completed) {
                auto result = sender.GetResults();
                cb(result.Text().c_str(), nullptr, user_data);
            } else {
                // Surface the real failure: GetResults() rethrows the
                // underlying hresult_error on a non-Completed async op.
                try {
                    sender.GetResults();
                } catch (winrt::hresult_error const &e) {
                    cb(nullptr, e.message().c_str(), user_data);
                    return;
                } catch (...) {}
                cb(nullptr, L"GenerateResponseAsync failed", user_data);
            }
        });
    } catch (winrt::hresult_error const &e) {
        cb(nullptr, e.message().c_str(), user_data);
    } catch (...) {
        cb(nullptr, L"generate failed", user_data);
    }
}

void swiftpwa_phi_silica_generate_stream(
    const wchar_t *prompt,
    swiftpwa_phi_silica_delta_callback delta_cb,
    swiftpwa_phi_silica_done_callback done_cb,
    void *user_data
) {
    if (!done_cb) return;
    if (!swiftpwa_phi_silica_init()) { done_cb(nullptr, L"Windows App SDK runtime unavailable", user_data); return; }
    try {
        winrt::hstring p = prompt ? winrt::hstring{prompt} : winrt::hstring{L""};
        auto languageModel = AIT::LanguageModel::CreateAsync().get();
        auto op = languageModel.GenerateResponseAsync(p);
        // TODO(box): confirm the progress payload type. The Windows AI text
        // model surfaces partial generations through the
        // IAsyncOperationWithProgress progress handler; the delta arrives as
        // an hstring (cumulative-vs-incremental TBD on the box — match the
        // Swift side to whichever it is, like the Gemini chunk handling).
        op.Progress([delta_cb, user_data](auto const &, winrt::hstring const &partial) {
            if (delta_cb) delta_cb(partial.c_str(), user_data);
        });
        op.Completed([done_cb, user_data](auto const &, WF::AsyncStatus status) {
            if (status == WF::AsyncStatus::Completed) done_cb(nullptr, nullptr, user_data);
            else done_cb(nullptr, L"stream failed", user_data);
        });
    } catch (winrt::hresult_error const &e) {
        done_cb(nullptr, e.message().c_str(), user_data);
    } catch (...) {
        done_cb(nullptr, L"stream failed", user_data);
    }
}

} // extern "C"

#endif // _WIN32

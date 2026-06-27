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
#include <winrt/Microsoft.Windows.AI.h>
#include <winrt/Microsoft.Windows.AI.Text.h>

// Windows App SDK bootstrapper (C API) for unpackaged apps.
#include <MddBootstrap.h>

namespace WF = winrt::Windows::Foundation;
namespace AI = winrt::Microsoft::Windows::AI;
namespace AIT = winrt::Microsoft::Windows::AI::Text;

namespace {

bool g_bootstrapped = false;

swiftpwa_phi_silica_ready_state map_ready(AI::AIFeatureReadyState s) {
    switch (s) {
        case AI::AIFeatureReadyState::Ready:        return SWIFTPWA_PHI_READY;
        case AI::AIFeatureReadyState::NotReady:     return SWIFTPWA_PHI_NOT_READY;
        case AI::AIFeatureReadyState::EnsureNeeded: return SWIFTPWA_PHI_ENSURE_NEEDED;
        case AI::AIFeatureReadyState::NotSupportedOnCurrentSystem:
            return SWIFTPWA_PHI_NOT_SUPPORTED;
        default: return SWIFTPWA_PHI_ERROR;
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
    // Initialize the Windows App SDK runtime for this (unpackaged) process.
    // The release/version tag are pinned to the SDK the build links against;
    // TODO(box): confirm the exact UINT32 majorMinor + versionTag for the
    // installed runtime (e.g. 0x00010008 for 1.8). MddBootstrapInitialize2
    // returns an HRESULT; a failure means the runtime redistributable is
    // absent — report unavailable rather than crash.
    const UINT32 majorMinor = 0x00010008; // 1.8 — adjust on the box
    PACKAGE_VERSION minVersion{};
    HRESULT hr = MddBootstrapInitialize2(
        majorMinor, L"", minVersion, MddBootstrapInitializeOptions_OnNoMatch_ShowUI);
    if (FAILED(hr)) return false;
    g_bootstrapped = true;
    return true;
}

swiftpwa_phi_silica_ready_state swiftpwa_phi_silica_ready_state_query(void) {
    if (!swiftpwa_phi_silica_init()) return SWIFTPWA_PHI_ERROR;
    try {
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

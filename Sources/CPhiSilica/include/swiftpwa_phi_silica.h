// swiftpwa_phi_silica — Windows Phi Silica (Windows AI APIs in the Windows
// App SDK) behind a flat C ABI.
//
// Why a C++/WinRT shim and not raw Swift: the `LanguageModel` surface is
// asynchronous (IAsyncOperation / IAsyncOperationWithProgress) and projected
// from the Windows App SDK's cppwinrt metadata. Doing the projection from
// Swift is impractical; in C++/WinRT it's the same `Completed(...)` /
// `Progress(...)` plumbing the biometric shim uses. Swift bridges each
// callback back to a continuation / AsyncThrowingStream.
//
// UNLIKE the toast / biometric shims (built-in WinRT, linked via
// `WindowsApp.lib`), Phi Silica lives in the **Windows App SDK** — the .cpp
// needs the WinAppSDK cppwinrt projection headers on INCLUDE and the
// WinAppSDK **bootstrapper** initialized at process start for an unpackaged
// app. See docs/windows-setup.md and the Package.swift CPhiSilica target.
//
// Phi Silica is also a **Limited Access Feature**: `CreateAsync` can throw
// without a LAF unlock token. Every entry point catches and reports the
// failure as a state / error rather than crashing, so an app on unsupported
// hardware (or without the runtime) cleanly falls back to its own tier.

#ifndef SWIFT_PWA_PHI_SILICA_SHIM_H
#define SWIFT_PWA_PHI_SILICA_SHIM_H

#include <stdbool.h>
#include <wchar.h>

#ifdef __cplusplus
extern "C" {
#endif

// Mirrors WinRT's `Microsoft.Windows.AI.AIFeatureReadyState`.
typedef enum {
    SWIFTPWA_PHI_READY = 0,          // Ready — model installed, usable now.
    SWIFTPWA_PHI_NOT_READY = 1,      // NotReady — transient / model absent.
    SWIFTPWA_PHI_ENSURE_NEEDED = 2,  // EnsureNeeded — call ensure to download.
    SWIFTPWA_PHI_NOT_SUPPORTED = 3,  // NotSupportedOnCurrentSystem.
    SWIFTPWA_PHI_ERROR = -1,         // Exception (LAF locked, no runtime, …).
} swiftpwa_phi_silica_ready_state;

// Fires once when an `ensure` / `generate` operation finishes. On success
// `text` carries the result (generate) or is NULL (ensure) and `error` is
// NULL; on failure `error` carries a UTF-16 message and `text` is NULL. The
// shim owns both strings only for the duration of the call — copy in Swift.
typedef void (*swiftpwa_phi_silica_done_callback)(
    const wchar_t *text, const wchar_t *error, void *user_data);

// Fires for each incremental token chunk during streaming generation.
typedef void (*swiftpwa_phi_silica_delta_callback)(
    const wchar_t *delta, void *user_data);

// Initialize the Windows App SDK runtime bootstrapper for this process.
// Idempotent; returns true once the runtime is available. MUST succeed
// before any other call here (an unpackaged app has no implicit WinAppSDK
// activation context). Returns false when the runtime redistributable is
// absent — the backend then reports `available: false`.
bool swiftpwa_phi_silica_init(void);

// Synchronous readiness probe (`LanguageModel::GetReadyState()`). Cheap;
// safe to call from `ai.info`. Returns SWIFTPWA_PHI_ERROR if the feature is
// locked / unavailable.
swiftpwa_phi_silica_ready_state swiftpwa_phi_silica_ready_state_query(void);

// Ensure the model is present (`EnsureReadyAsync`) — a no-op when already
// Ready, otherwise a (potentially multi-GB, Windows-Update-backed) download
// on GPU systems. Fires `cb` with `error == NULL` on success.
void swiftpwa_phi_silica_ensure_ready(
    swiftpwa_phi_silica_done_callback cb, void *user_data);

// Unary generation (`CreateAsync` → `GenerateResponseAsync`). Fires `cb`
// with the full response text on success.
void swiftpwa_phi_silica_generate(
    const wchar_t *prompt,
    swiftpwa_phi_silica_done_callback cb,
    void *user_data);

// Streaming generation. Fires `delta_cb` per incremental chunk (via the
// IAsyncOperationWithProgress progress handler), then `done_cb` once with
// `error == NULL` (the `text` arg of done_cb is unused / NULL on success).
void swiftpwa_phi_silica_generate_stream(
    const wchar_t *prompt,
    swiftpwa_phi_silica_delta_callback delta_cb,
    swiftpwa_phi_silica_done_callback done_cb,
    void *user_data);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // SWIFT_PWA_PHI_SILICA_SHIM_H

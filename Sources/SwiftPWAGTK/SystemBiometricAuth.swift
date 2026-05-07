#if os(Linux)
    import Foundation
    import SwiftPWACore

    /// Linux stub `BiometricAuth` — always reports unavailable. There
    /// is no cross-distro biometric primitive: `libfprint` only covers
    /// a subset of fingerprint readers and isn't preinstalled, polkit
    /// gives root-style authorization rather than a biometric prompt,
    /// and PAM is a system-level configuration concern that a per-app
    /// library shouldn't touch. Apps targeting Linux should fall back
    /// to a passphrase flow (e.g. `dialog.confirm` after typing a
    /// password) and treat `canAuthenticate().available == false` as
    /// the universal cue.
    ///
    /// `authenticate` returns `authenticated: false` with a clear
    /// reason rather than throwing, matching the protocol's "cancel
    /// is not an error" contract — the caller's UI presumably already
    /// rendered something it'll show next.
    public final class SystemBiometricAuth: BiometricAuth, @unchecked Sendable {
        public init() {}

        public func canAuthenticate() async throws -> BiometricAvailability {
            BiometricAvailability(
                available: false,
                kind: .none,
                reason: "biometric authentication is not supported on Linux"
            )
        }

        public func authenticate(_: BiometricAuthArgs) async throws -> BiometricAuthResult {
            BiometricAuthResult(
                authenticated: false,
                error: "biometric authentication is not supported on Linux"
            )
        }
    }
#endif

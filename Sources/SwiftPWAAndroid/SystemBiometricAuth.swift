#if os(Android)
    import Foundation
    import SwiftPWACore

    /// `BiometricAuth` backed by `androidx.biometric.BiometricPrompt`.
    ///
    /// The host `MainActivity` extends `androidx.appcompat.app.AppCompatActivity`
    /// (a `FragmentActivity` subclass) — `BiometricPrompt` requires a
    /// `FragmentActivity` to attach its dialog fragment to, so the
    /// scaffold's Activity base class is set accordingly. Apps that
    /// derive a custom Activity should preserve that base class or
    /// the prompt will fail to attach with `IllegalStateException:
    /// FragmentActivity required`.
    ///
    /// **`BiometricKind` reporting.** Android's `BiometricManager` doesn't
    /// distinguish fingerprint vs face vs iris at the public API
    /// level — both `BIOMETRIC_STRONG` and `BIOMETRIC_WEAK` are
    /// abstract authenticator strengths. We always report `.unknown`
    /// when biometrics are available; `.none` when the device has no
    /// enrolled biometrics. JS-side capability gating should check
    /// `available`, not `kind`.
    ///
    /// **Cancel vs error.** Per the protocol contract, user cancel
    /// surfaces as `authenticated: false` with `error: "cancelled"`.
    /// System errors (no hardware, lockout, etc.) come back through
    /// the same field with the underlying error string from the
    /// `onAuthenticationError` callback.
    public final class SystemBiometricAuth: BiometricAuth, @unchecked Sendable {
        public init() {}

        public func canAuthenticate() async throws -> BiometricAvailability {
            try await AndroidRPC.call(
                "biometric.canAuthenticate", EmptyArgs()
            )
        }

        public func authenticate(_ args: BiometricAuthArgs) async throws -> BiometricAuthResult {
            try await AndroidRPC.call("biometric.authenticate", args)
        }
    }
#endif

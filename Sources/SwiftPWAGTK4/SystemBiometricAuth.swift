#if os(Linux)
    import Foundation
    import SwiftPWACore

    /// Linux stub `BiometricAuth`. See the GTK3 backend for the
    /// rationale; this is the same implementation, copied because
    /// the two backends are conditionally compiled into independent
    /// `SwiftPWAGTK` modules.
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

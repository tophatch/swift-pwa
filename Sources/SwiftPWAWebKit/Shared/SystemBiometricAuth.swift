#if os(macOS) || os(iOS)
    import Foundation
    import LocalAuthentication
    import SwiftPWACore

    /// `BiometricAuth` backed by `LAContext.evaluatePolicy`. Same
    /// surface across macOS / iOS — `LocalAuthentication` is unified.
    ///
    /// **Bundling caveat (Apple).** `LAContext` works without a
    /// bundle identity (unlike `UNUserNotificationCenter`), but
    /// behaviour is more predictable inside a real `.app` —
    /// particularly Touch ID prompts on macOS, where running from
    /// `swift run` can produce permission-dialog races. The plugin
    /// reports `available == true` as long as the policy evaluates;
    /// callers that want to enforce "bundled only" can check
    /// `Bundle.main.bundleIdentifier` themselves.
    public final class SystemBiometricAuth: BiometricAuth, @unchecked Sendable {
        public init() {}

        public func canAuthenticate() async throws -> BiometricAvailability {
            let context = LAContext()
            var error: NSError?
            let ok = context.canEvaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                error: &error
            )
            let kind = mapBiometryType(context.biometryType)
            if ok {
                return BiometricAvailability(available: true, kind: kind)
            }
            // `error` distinguishes "not enrolled" from "no sensor"
            // from "lockout" — surface its `localizedDescription`
            // verbatim so callers can show the actual reason.
            return BiometricAvailability(
                available: false,
                kind: kind,
                reason: error?.localizedDescription ?? "biometrics unavailable"
            )
        }

        public func authenticate(_ args: BiometricAuthArgs) async throws -> BiometricAuthResult {
            let context = LAContext()
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: args.reason
                )
                return BiometricAuthResult(authenticated: success)
            } catch let laError as LAError {
                // Treat user-driven dismissals as a non-throwing
                // `authenticated: false` — that's what the protocol
                // promises. System errors propagate as bridge errors.
                if laError.code == .userCancel || laError.code == .userFallback || laError.code == .systemCancel {
                    return BiometricAuthResult(authenticated: false, error: "cancelled")
                }
                if laError.code == .authenticationFailed {
                    return BiometricAuthResult(
                        authenticated: false,
                        error: "authentication failed"
                    )
                }
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "biometric authentication failed: \(laError.localizedDescription)"
                )
            } catch {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "biometric authentication failed: \(error.localizedDescription)"
                )
            }
        }

        private func mapBiometryType(_ type: LABiometryType) -> BiometricKind {
            switch type {
            case .none: .none
            case .touchID: .touchID
            case .faceID: .faceID
            case .opticID: .opticID
            @unknown default: .unknown
            }
        }
    }
#endif

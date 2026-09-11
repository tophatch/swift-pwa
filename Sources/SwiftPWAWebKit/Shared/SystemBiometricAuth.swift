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

        public func canAuthenticate(_ args: BiometricAvailabilityArgs) async throws -> BiometricAvailability {
            let context = LAContext()
            var error: NSError?
            let ok = context.canEvaluatePolicy(
                BiometricPolicy.laPolicy(allowDeviceCredential: args.allowDeviceCredential),
                error: &error
            )
            let kind = mapBiometryType(context.biometryType)
            // A Face ID device with no usage description can never
            // complete `authenticate` — it throws before it prompts,
            // because evaluating would abort the app. The advisory
            // answer has to say so, or an app doing the documented
            // thing offers a lock that cannot be opened.
            if let reason = faceIDUsageDescriptionProblem(kind: kind) {
                return BiometricAvailability(available: false, kind: kind, reason: reason)
            }
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
            // `biometryType` is only populated after a policy
            // evaluation, so probe before reading it.
            var probeError: NSError?
            _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &probeError)
            if let reason = faceIDUsageDescriptionProblem(kind: mapBiometryType(context.biometryType)) {
                throw BridgeError(code: BridgeError.handler, message: reason)
            }
            do {
                let success = try await context.evaluatePolicy(
                    BiometricPolicy.laPolicy(allowDeviceCredential: args.allowDeviceCredential),
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

        private func faceIDUsageDescriptionProblem(kind: BiometricKind) -> String? {
            #if os(iOS)
                BiometricPolicy.faceIDUsageDescriptionProblem(
                    kind: kind,
                    usageDescription: Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription")
                )
            #else
                nil
            #endif
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

    /// The two policy decisions, pulled out of `SystemBiometricAuth`
    /// so they can be asserted without a real `LAContext` — neither a
    /// Face ID sensor nor a missing `Info.plist` key can be staged in
    /// a test process.
    package enum BiometricPolicy {
        package static func laPolicy(allowDeviceCredential: Bool) -> LAPolicy {
            allowDeviceCredential ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics
        }

        /// iOS **terminates the app** if `evaluatePolicy` triggers Face
        /// ID without an `NSFaceIDUsageDescription` string in
        /// Info.plist — a hard OS requirement, raised as an uncatchable
        /// exception (so the caller's try/catch can't save it). Both
        /// entry points check for it: `authenticate` throws this
        /// instead of crashing, and `canAuthenticate` reports it as
        /// unavailable so the feature is never offered.
        ///
        /// It applies with `allowDeviceCredential` too: Face ID is
        /// attempted first, so the passcode fallback is never reached.
        package static func faceIDUsageDescriptionProblem(
            kind: BiometricKind,
            usageDescription: Any?
        ) -> String? {
            guard kind == .faceID else { return nil }
            if let text = usageDescription as? String, !text.isEmpty {
                return nil
            }
            if usageDescription != nil, !(usageDescription is String) {
                return nil
            }
            return "Face ID needs an NSFaceIDUsageDescription string in Info.plist — "
                + "add it via pwa.json's `ios.info_plist` (see docs/ios-setup.md). "
                + "Without it iOS aborts the app when Face ID is invoked."
        }
    }
#endif

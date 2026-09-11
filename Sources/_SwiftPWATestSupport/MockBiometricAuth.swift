import Foundation
import SwiftPWACore

/// In-memory `BiometricAuth` for unit tests. Tests set `nextAvailability`
/// and `nextResult` to script the JS-side flow without engaging
/// `LocalAuthentication` / WinRT.
@MainActor
public final class MockBiometricAuth: BiometricAuth {
    public enum Action: Sendable, Equatable {
        case canAuthenticate(BiometricAvailabilityArgs)
        case authenticate(BiometricAuthArgs)
    }

    public private(set) var actions: [Action] = []

    public var nextAvailability = BiometricAvailability(available: true, kind: .touchID)
    public var nextResult = BiometricAuthResult(authenticated: true)

    public init() {}

    public func canAuthenticate(_ args: BiometricAvailabilityArgs) async throws -> BiometricAvailability {
        actions.append(.canAuthenticate(args))
        return nextAvailability
    }

    public func authenticate(_ args: BiometricAuthArgs) async throws -> BiometricAuthResult {
        actions.append(.authenticate(args))
        return nextResult
    }
}

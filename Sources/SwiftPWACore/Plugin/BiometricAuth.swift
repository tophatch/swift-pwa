import Foundation

/// Cross-platform biometric / device-owner authentication. Backends
/// provide a concrete `SystemBiometricAuth` (`SwiftPWAWebKit` for
/// macOS / iOS via `LocalAuthentication`, `SwiftPWAWindows` via
/// `Windows.Security.Credentials.UI.UserConsentVerifier`,
/// `SwiftPWAGTK` ships a stub that always reports unavailable).
///
/// **Linux is unsupported.** There is no cross-distro biometric
/// authentication primitive — `libfprint` covers a subset of
/// fingerprint readers and isn't preinstalled, polkit gives root-style
/// authorization rather than a biometric prompt, and PAM is a system
/// configuration concern that a per-app library shouldn't touch.
/// Apps targeting Linux should fall back to a passphrase-style flow
/// (e.g. `dialog.confirm` after typing a password) and treat
/// `canAuthenticate().available == false` as the universal cue.
///
/// **Windows works on both packaged and unpackaged builds.** The
/// shim uses the `IUserConsentVerifierInterop` desktop-app variant
/// (`RequestVerificationForWindowAsync`), passing an explicit HWND
/// parent so the consent prompt anchors to a real window. The
/// static `RequestVerificationAsync` entry point assumes package
/// identity and won't show its UI from a portable EXE — see the
/// notes in [docs/windows-setup.md](docs/windows-setup.md).
public protocol BiometricAuth: AnyObject, Sendable {
    /// Inspect the current host. The result is *advisory*: callers
    /// should still handle `authenticate` returning `authenticated:
    /// false` (the user may have disabled biometrics between this
    /// call and the prompt).
    func canAuthenticate() async throws -> BiometricAvailability

    /// Show the platform's biometric prompt with `reason` as the
    /// localized explanation. Returns whether the user proved
    /// presence; never throws on a cancel — that's reported as
    /// `authenticated: false` with `error: "cancelled"`. Real
    /// system errors (no sensor available, device locked out) come
    /// back as `BridgeError(code: .handler)`.
    func authenticate(_ args: BiometricAuthArgs) async throws -> BiometricAuthResult
}

// MARK: - DTOs

/// Which biometric primitive the host exposes. `none` means "not
/// available"; consumers branch on `available` first.
public enum BiometricKind: String, Sendable, Codable, Equatable {
    case none, touchID, faceID, opticID, windowsHello, unknown
}

public struct BiometricAvailability: Sendable, Codable, Equatable {
    /// True only when an *enrolled* sensor is available and the user
    /// is allowed to authenticate. False when biometrics are missing,
    /// disabled, or temporarily locked out.
    public var available: Bool
    public var kind: BiometricKind
    /// On `available == false`, a human-readable reason ("not
    /// configured", "lockout", "no sensor"). `nil` when available.
    public var reason: String?

    public init(available: Bool, kind: BiometricKind, reason: String? = nil) {
        self.available = available
        self.kind = kind
        self.reason = reason
    }
}

public struct BiometricAuthArgs: Sendable, Codable, Equatable {
    /// Localized explanation shown next to the system prompt
    /// ("Authenticate to unlock the journal"). Apple requires this;
    /// Windows and the mock both accept and ignore it.
    public var reason: String
    public init(reason: String) { self.reason = reason }
}

public struct BiometricAuthResult: Sendable, Codable, Equatable {
    public var authenticated: Bool
    /// Failure detail. `"cancelled"` for user-driven dismissal,
    /// system-defined string otherwise. `nil` on success.
    public var error: String?

    public init(authenticated: Bool, error: String? = nil) {
        self.authenticated = authenticated
        self.error = error
    }
}

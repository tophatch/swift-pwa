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
    /// Inspect the current host for the policy `args` describes. The
    /// result is *advisory*: callers should still handle
    /// `authenticate` returning `authenticated: false` (the user may
    /// have disabled biometrics between this call and the prompt).
    ///
    /// The answer has to be policy-specific: a Mac with no Touch ID
    /// is unavailable for biometrics and available for the account
    /// password, and an app willing to accept either shouldn't hide
    /// the feature because it asked the narrower question.
    func canAuthenticate(_ args: BiometricAvailabilityArgs) async throws -> BiometricAvailability

    /// Show the platform's biometric prompt with `reason` as the
    /// localized explanation. Returns whether the user proved
    /// presence; never throws on a cancel — that's reported as
    /// `authenticated: false` with `error: "cancelled"`. Real
    /// system errors (no sensor available, device locked out) come
    /// back as `BridgeError(code: .handler)`.
    func authenticate(_ args: BiometricAuthArgs) async throws -> BiometricAuthResult
}

public extension BiometricAuth {
    /// Biometrics-only availability — `canAuthenticate(.init())`.
    func canAuthenticate() async throws -> BiometricAvailability {
        try await canAuthenticate(BiometricAvailabilityArgs())
    }
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

public struct BiometricAvailabilityArgs: Sendable, Codable, Equatable {
    /// Ask whether the *device credential* (account password, device
    /// passcode, PIN, pattern) counts as well as biometrics — the
    /// same policy `BiometricAuthArgs.allowDeviceCredential` runs.
    public var allowDeviceCredential: Bool

    public init(allowDeviceCredential: Bool = false) {
        self.allowDeviceCredential = allowDeviceCredential
    }

    /// Hand-written so `biometric.canAuthenticate()` with no payload
    /// keeps working: a synthesized `init(from:)` requires every key.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowDeviceCredential = try container.decodeIfPresent(Bool.self, forKey: .allowDeviceCredential) ?? false
    }
}

public struct BiometricAuthArgs: Sendable, Codable, Equatable {
    /// Localized explanation shown next to the system prompt
    /// ("Authenticate to unlock the journal"). Apple requires this;
    /// Windows and the mock both accept and ignore it.
    public var reason: String

    /// Accept the account password / device passcode when biometrics
    /// are unavailable or fail, so a lock the app set can still be
    /// opened on a machine whose sensor is gone. Defaults to `false`,
    /// which is biometrics or nothing.
    ///
    /// Apple swaps `LAPolicy` (`.deviceOwnerAuthentication` rather
    /// than `.deviceOwnerAuthenticationWithBiometrics`); Android adds
    /// `DEVICE_CREDENTIAL` to the allowed authenticators. Windows'
    /// `UserConsentVerifier` always offers the PIN, so the flag is
    /// already its behaviour and changes nothing there; Linux has no
    /// biometric primitive either way.
    public var allowDeviceCredential: Bool

    public init(reason: String, allowDeviceCredential: Bool = false) {
        self.reason = reason
        self.allowDeviceCredential = allowDeviceCredential
    }

    /// Hand-written so a page sending `{ reason }` — every caller
    /// written before this flag existed — still decodes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = try container.decode(String.self, forKey: .reason)
        allowDeviceCredential = try container.decodeIfPresent(Bool.self, forKey: .allowDeviceCredential) ?? false
    }
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

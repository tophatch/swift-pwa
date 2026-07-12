import Foundation

/// A small key→string store backed by the operating system's secure secret
/// storage — Keychain on Apple, `EncryptedSharedPreferences` (Keystore-backed)
/// on Android, DPAPI on Windows, the Secret Service (libsecret) on Linux.
///
/// This is the injectable transport seam behind ``SecretsPlugin``, exactly like
/// `NetworkClient` behind `NetPlugin` and `ProcessRunner` behind `ProcessPlugin`.
/// An app picks the platform implementation and hands it to the plugin:
/// `ctx.use(SecretsPlugin(KeychainSecretStore()))` (Apple),
/// `ctx.use(SecretsPlugin(AndroidSecretStore()))` (Android).
///
/// **Values are strings.** Callers store binary as base64. Keys are opaque
/// identifiers namespaced per app by the underlying store (Keychain service =
/// bundle id, Android prefs file, etc.), so a plain `"google-ai"` is fine.
///
/// **A missing key is not an error** — ``get(_:)`` returns `nil`. Only a store
/// failure (unavailable, access denied, I/O) throws; conform such errors to
/// carry ``BridgeError/secrets`` so the JS side sees a stable `E_SECRETS` code.
public protocol SecretStore: Sendable {
    /// Return the stored value for `key`, or `nil` if no value is stored.
    func get(_ key: String) async throws -> String?

    /// Store `value` under `key`, replacing any existing value.
    func set(_ key: String, _ value: String) async throws

    /// Remove any value stored under `key`. Deleting a missing key is a no-op
    /// (not an error), so the operation is idempotent.
    func delete(_ key: String) async throws
}

/// The default ``SecretStore`` used when an app registers ``SecretsPlugin``
/// without a platform store — every operation throws ``BridgeError/secrets``.
///
/// This keeps the JS `secrets.*` contract present (and its errors well-defined)
/// on a platform whose store hasn't been wired yet, rather than the command set
/// being silently absent. An app that wants secrets on such a platform injects
/// its own conforming store.
public struct NoneSecretStore: SecretStore {
    private let reason: String

    public init(reason: String = "no secure store configured on this platform") {
        self.reason = reason
    }

    public func get(_: String) async throws -> String? {
        throw BridgeError(code: BridgeError.secrets, message: reason)
    }

    public func set(_: String, _: String) async throws {
        throw BridgeError(code: BridgeError.secrets, message: reason)
    }

    public func delete(_: String) async throws {
        throw BridgeError(code: BridgeError.secrets, message: reason)
    }
}

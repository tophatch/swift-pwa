#if os(Android)
    import Foundation
    import SwiftPWACore

    /// The Android ``SecretStore``. Routes through the Kotlin RPC bridge to
    /// `EncryptedSharedPreferences` (Jetpack Security) — an AES-encrypted prefs
    /// file whose master key lives in the Android Keystore (hardware-backed
    /// where available). The Swift side can't touch the Keystore directly, so
    /// this mirrors the `net.request` pattern: a `secrets.*` dispatch case on
    /// the Kotlin `MainActivity`, invoked over ``AndroidRPC``.
    ///
    /// Wire it into the plugin: `ctx.use(SecretsPlugin(AndroidSecretStore()))`.
    public struct AndroidSecretStore: SecretStore {
        public init() {}

        public func get(_ key: String) async throws -> String? {
            try await asSecretsError {
                try await AndroidRPC.call("secrets.get", KeyArgs(key: key), as: ValueResult.self).value
            }
        }

        public func set(_ key: String, _ value: String) async throws {
            try await asSecretsError {
                _ = try await AndroidRPC.call("secrets.set", SetArgs(key: key, value: value), as: NoResult.self)
            }
        }

        public func delete(_ key: String) async throws {
            try await asSecretsError {
                _ = try await AndroidRPC.call("secrets.delete", KeyArgs(key: key), as: NoResult.self)
            }
        }

        /// The RPC bridge surfaces a Kotlin-side failure as a generic
        /// `E_HANDLER`; re-map it to the `secrets.*` contract's `E_SECRETS` so
        /// the JS side gets the stable code (a missing key is *not* an error —
        /// it comes back as `value: null` and never reaches here).
        private func asSecretsError<T>(_ body: () async throws -> T) async throws -> T {
            do {
                return try await body()
            } catch let bridge as BridgeError {
                throw BridgeError(code: BridgeError.secrets, message: bridge.message)
            }
        }

        // MARK: - Wire types

        private struct KeyArgs: Encodable {
            let key: String
        }

        private struct SetArgs: Encodable {
            let key: String
            let value: String
        }

        private struct ValueResult: Decodable {
            let value: String?
        }
    }
#endif

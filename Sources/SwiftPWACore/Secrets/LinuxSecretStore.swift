#if canImport(CSecretShim)
    import CSecretShim
    import Foundation

    /// The Linux ``SecretStore``, backed by the **Secret Service** (libsecret →
    /// GNOME Keyring / KWallet) via a small C shim (``CSecretShim``). Secrets are
    /// filed under a `service` attribute (default `"swift-pwa"`) plus the key.
    ///
    /// **Requires a running Secret Service** (a desktop keyring + a D-Bus session
    /// bus). On a headless box with none, the operations throw `E_SECRETS` rather
    /// than silently losing data — an app that wants a headless fallback injects
    /// its own `SecretStore`. Wire it into the plugin:
    /// `ctx.use(SecretsPlugin(LinuxSecretStore()))`.
    ///
    /// libsecret is `dlopen`ed rather than linked, so an app that never stores a
    /// secret runs on a machine without it. That makes "libsecret isn't
    /// installed" a real state, and a different one from "installed, but nothing
    /// is listening on the session bus" — they have different fixes, so the
    /// thrown message names which one it is.
    public struct LinuxSecretStore: SecretStore {
        private let service: String

        public init(service: String = "swift-pwa") {
            self.service = service
        }

        /// The reason a call failed, phrased as the thing to go and do. Checked
        /// only on the failure path — the probe is a `pthread_once`'d `dlopen`,
        /// so it costs nothing after the first call.
        private var unavailableReason: String {
            swiftpwa_secret_available() != 0
                ? "no Secret Service / keyring?"
                : "libsecret isn't installed — apt install libsecret-1-0"
        }

        public func get(_ key: String) async throws -> String? {
            var out: UnsafeMutablePointer<CChar>?
            switch swiftpwa_secret_get(service, key, &out) {
            case 0:
                defer { swiftpwa_secret_string_free(out) }
                return out.map { String(cString: $0) }
            case 1:
                return nil // not found
            default:
                throw BridgeError(
                    code: BridgeError.secrets,
                    message: "libsecret lookup failed for \"\(key)\" (\(unavailableReason))"
                )
            }
        }

        public func set(_ key: String, _ value: String) async throws {
            guard swiftpwa_secret_set(service, key, value) == 0 else {
                throw BridgeError(
                    code: BridgeError.secrets,
                    message: "libsecret store failed for \"\(key)\" (\(unavailableReason))"
                )
            }
        }

        public func delete(_ key: String) async throws {
            guard swiftpwa_secret_delete(service, key) == 0 else {
                throw BridgeError(
                    code: BridgeError.secrets,
                    message: "libsecret clear failed for \"\(key)\" (\(unavailableReason))"
                )
            }
        }
    }
#endif

#if canImport(Security)
    import Foundation
    import Security

    /// The Apple (macOS / iOS) ``SecretStore``, backed by the **Keychain**
    /// (`kSecClassGenericPassword`). Items are scoped by a *service* string
    /// (default: the main bundle identifier) so two apps don't collide, and are
    /// stored `kSecAttrAccessibleAfterFirstUnlock` — readable in the background
    /// after the first unlock following a boot, which is what a headless
    /// generate-on-launch flow needs, without exposing the item before first
    /// unlock.
    ///
    /// Wire it into the plugin: `ctx.use(SecretsPlugin(KeychainSecretStore()))`.
    public struct KeychainSecretStore: SecretStore {
        private let service: String

        /// - Parameter service: the Keychain service the items are filed under.
        ///   Defaults to the main bundle identifier (falling back to
        ///   `"swift-pwa"` in the rare case there's no bundle id), so an app
        ///   gets its own namespace with no configuration.
        public init(service: String? = nil) {
            self.service = service ?? Bundle.main.bundleIdentifier ?? "swift-pwa"
        }

        public func get(_ key: String) async throws -> String? {
            var query = baseQuery(for: key)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
                    throw secretsError("stored value for \"\(key)\" is not valid UTF-8", status)
                }
                return string
            case errSecItemNotFound:
                return nil
            default:
                throw secretsError("keychain read failed for \"\(key)\"", status)
            }
        }

        public func set(_ key: String, _ value: String) async throws {
            guard let data = value.data(using: .utf8) else {
                throw BridgeError(code: BridgeError.secrets, message: "value is not encodable as UTF-8")
            }
            // Try to update an existing item first; add it if there's none.
            let update = [kSecValueData as String: data] as CFDictionary
            let updateStatus = SecItemUpdate(baseQuery(for: key) as CFDictionary, update)
            if updateStatus == errSecSuccess { return }
            if updateStatus != errSecItemNotFound {
                throw secretsError("keychain update failed for \"\(key)\"", updateStatus)
            }
            var add = baseQuery(for: key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw secretsError("keychain write failed for \"\(key)\"", addStatus)
            }
        }

        public func delete(_ key: String) async throws {
            let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
            // Deleting a missing item is a successful no-op (idempotent).
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw secretsError("keychain delete failed for \"\(key)\"", status)
            }
        }

        private func baseQuery(for key: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
        }

        private func secretsError(_ message: String, _ status: OSStatus) -> BridgeError {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return BridgeError(code: BridgeError.secrets, message: "\(message): \(detail)")
        }
    }
#endif

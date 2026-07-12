import Foundation

/// Plugin exposing the `secrets.*` command set: read/write/delete small secrets
/// in the operating system's secure store from JS. The secure-by-default place
/// for an API token, a sync credential, or a license key — so an app never has
/// to fall back to `localStorage`, a plaintext file, or `pwa.json`.
///
/// **Opt-in.** Register it explicitly with a platform store, the same way as
/// `net.*` / `process.*`:
/// `ctx.use(SecretsPlugin(KeychainSecretStore()))` on Apple,
/// `ctx.use(SecretsPlugin(AndroidSecretStore()))` on Android. Not auto-installed
/// — reaching the OS keychain is a capability an app opts into. Registered
/// without a store, it defaults to ``NoneSecretStore`` so the JS contract still
/// exists (every call throws a well-defined `E_SECRETS`).
///
/// **The framework never persists secrets for you.** This plugin is a thin,
/// audited bridge to the OS store; where a value lives is the store's business.
/// The remote-AI `ImagenProvider`'s `apiKey` closure reads straight through it:
/// `ImagenProvider(apiKey: { try? await store.get("google-ai") })`.
///
/// ## Commands
/// - `secrets.get(SecretKeyArgs)` → ``SecretValueResult``. `value` is the stored
///   string or `null` if the key is absent (a missing key is *not* an error).
/// - `secrets.set(SecretSetArgs)` → ``EmptyResult``. Stores `value` under `key`,
///   replacing any existing value.
/// - `secrets.delete(SecretKeyArgs)` → ``EmptyResult``. Idempotent — deleting a
///   missing key succeeds.
///
/// A store failure (unavailable, access denied, I/O) throws `E_SECRETS`.
public struct SecretsPlugin: Plugin {
    public static let pluginName = "secrets"

    private let store: any SecretStore

    public init(_ store: any SecretStore = NoneSecretStore()) {
        self.store = store
    }

    public func register(into registry: CommandRegistry, app _: any AppContext) {
        let store = store

        registry.register("secrets.get", typed: { (args: SecretKeyArgs, _) async throws -> SecretValueResult in
            let value = try await store.get(args.key)
            return SecretValueResult(value: value)
        })

        registry.register("secrets.set", typed: { (args: SecretSetArgs, _) async throws -> EmptyResult in
            try await store.set(args.key, args.value)
            return EmptyResult()
        })

        registry.register("secrets.delete", typed: { (args: SecretKeyArgs, _) async throws -> EmptyResult in
            try await store.delete(args.key)
            return EmptyResult()
        })
    }
}

// MARK: - Wire types (JS-facing)

/// Arguments for `secrets.get` / `secrets.delete` — the opaque key.
public struct SecretKeyArgs: Sendable, Codable, Equatable {
    public var key: String

    public init(key: String) {
        self.key = key
    }
}

/// Arguments for `secrets.set` — the key and its string value.
public struct SecretSetArgs: Sendable, Codable, Equatable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// `secrets.get` result. `value` is `nil` (JS `null`) when the key is absent.
public struct SecretValueResult: Sendable, Codable, Equatable {
    public var value: String?

    public init(value: String?) {
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case value }

    /// Encode `value` **explicitly as `null`** when nil, rather than omitting the
    /// key. `JSONEncoder` drops a nil `Optional` property by default, which would
    /// send `{}` for a missing key — but the JS contract is `{ value: null }`, so
    /// a page can destructure `const { value }` and test `value === null`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let value {
            try container.encode(value, forKey: .value)
        } else {
            try container.encodeNil(forKey: .value)
        }
    }
}

import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

// MARK: - Mock

/// An in-memory ``SecretStore`` for exercising ``SecretsPlugin``'s wiring
/// (arg decode, missing-key → null, error mapping) without an OS keychain.
/// Optionally fails every operation to test the error path.
private final class MockSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private let failure: (any Error)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    func get(_ key: String) async throws -> String? {
        if let failure { throw failure }
        return lock.withLock { storage[key] }
    }

    func set(_ key: String, _ value: String) async throws {
        if let failure { throw failure }
        lock.withLock { storage[key] = value }
    }

    func delete(_ key: String) async throws {
        if let failure { throw failure }
        lock.withLock { storage[key] = nil }
    }

    func peek(_ key: String) -> String? {
        lock.withLock { storage[key] }
    }
}

// MARK: - Tests

@Suite("SecretsPlugin")
@MainActor
struct SecretsPluginTests {
    private func makeApp(_ store: any SecretStore) -> MockAppContext {
        let app = MockAppContext()
        app.use(SecretsPlugin(store))
        return app
    }

    private func dispatch(
        _ command: String,
        _ payload: [String: Any],
        on app: MockAppContext
    ) async -> InvocationResult {
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        let inv = Invocation(id: 1, command: command, payload: data)
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        return await app.registry.dispatch(ctx)
    }

    private func decodeOK<T: Decodable>(_ result: InvocationResult, as _: T.Type) throws -> T {
        guard case let .ok(data) = result else {
            throw BridgeError(code: "TEST", message: "expected .ok, got \(result)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test("secrets.set then secrets.get round-trips the value")
    func setThenGet() async throws {
        let store = MockSecretStore()
        let app = makeApp(store)

        let setResult = await dispatch("secrets.set", ["key": "google-ai", "value": "sk-123"], on: app)
        _ = try decodeOK(setResult, as: EmptyResult.self)
        #expect(store.peek("google-ai") == "sk-123")

        let getResult = await dispatch("secrets.get", ["key": "google-ai"], on: app)
        let value = try decodeOK(getResult, as: SecretValueResult.self)
        #expect(value.value == "sk-123")
    }

    @Test("secrets.get returns null for a missing key (not an error)")
    func getMissingIsNull() async throws {
        let app = makeApp(MockSecretStore())
        let result = await dispatch("secrets.get", ["key": "absent"], on: app)
        let value = try decodeOK(result, as: SecretValueResult.self)
        #expect(value.value == nil)
    }

    @Test("a missing key serializes as { value: null }, not {} — the JS contract")
    func missingKeyWireIsExplicitNull() async throws {
        // JSONEncoder omits a nil Optional by default, which would send `{}` and
        // make `value === null` false in JS. The result must emit an explicit
        // null. Assert on the raw bytes the bridge delivers.
        let app = makeApp(MockSecretStore())
        let result = await dispatch("secrets.get", ["key": "absent"], on: app)
        guard case let .ok(data) = result else {
            Issue.record("expected .ok")
            return
        }
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json.keys.contains("value"))
        #expect(json["value"] is NSNull)
    }

    @Test("secrets.set overwrites an existing value")
    func setOverwrites() async {
        let store = MockSecretStore()
        let app = makeApp(store)
        _ = await dispatch("secrets.set", ["key": "k", "value": "first"], on: app)
        _ = await dispatch("secrets.set", ["key": "k", "value": "second"], on: app)
        #expect(store.peek("k") == "second")
    }

    @Test("secrets.delete removes a value and is idempotent for a missing key")
    func deleteThenGet() async throws {
        let store = MockSecretStore()
        let app = makeApp(store)
        _ = await dispatch("secrets.set", ["key": "k", "value": "v"], on: app)

        let del = await dispatch("secrets.delete", ["key": "k"], on: app)
        _ = try decodeOK(del, as: EmptyResult.self)
        #expect(store.peek("k") == nil)

        // Deleting again succeeds (idempotent).
        let delAgain = await dispatch("secrets.delete", ["key": "k"], on: app)
        _ = try decodeOK(delAgain, as: EmptyResult.self)

        let getResult = await dispatch("secrets.get", ["key": "k"], on: app)
        let value = try decodeOK(getResult, as: SecretValueResult.self)
        #expect(value.value == nil)
    }

    @Test("a store failure surfaces as E_SECRETS")
    func storeFailureIsSecretsError() async {
        let failing = MockSecretStore(failure: BridgeError(code: BridgeError.secrets, message: "keychain locked"))
        let app = makeApp(failing)

        for command in ["secrets.get", "secrets.set", "secrets.delete"] {
            let payload: [String: Any] = command == "secrets.set"
                ? ["key": "k", "value": "v"]
                : ["key": "k"]
            let result = await dispatch(command, payload, on: app)
            guard case let .failure(err) = result else {
                Issue.record("expected failure for \(command)")
                continue
            }
            #expect(err.code == BridgeError.secrets)
        }
    }

    @Test("NoneSecretStore throws E_SECRETS for every operation")
    func noneStoreThrows() async {
        let app = makeApp(NoneSecretStore())
        let result = await dispatch("secrets.get", ["key": "k"], on: app)
        guard case let .failure(err) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(err.code == BridgeError.secrets)
    }
}

import Foundation
@testable import SwiftPWACore
import Testing

/// Opt-in live test that round-trips a value through the *real* OS secure store
/// for the current platform — Keychain (Apple), DPAPI (Windows), libsecret
/// (Linux). Proves the concrete `SecretStore`, not a mock.
///
/// Off by default (it writes to the real store and, on Linux, needs a running
/// keyring / D-Bus session). Run with:
/// `SWIFT_PWA_LIVE_SECRETS=1 swift test --filter LiveSecretStore`.
/// Uses a throwaway service string and cleans up after itself.
@Suite("LiveSecretStore", .enabled(if: ProcessInfo.processInfo.environment["SWIFT_PWA_LIVE_SECRETS"] == "1"))
struct LiveSecretStoreTests {
    /// The platform store under test, or `nil` if this platform has no store yet
    /// (then the test is a no-op success).
    private func makeStore() -> (any SecretStore)? {
        #if canImport(Security)
            KeychainSecretStore(service: "com.swift-pwa.tests.secrets-live")
        #elseif os(Windows)
            WindowsSecretStore(service: "swift-pwa-tests-secrets-live")
        #elseif canImport(CLibSecret)
            LinuxSecretStore(service: "com.swift-pwa.tests.secrets-live")
        #else
            nil
        #endif
    }

    @Test("set → get → overwrite → delete against the real OS store")
    func roundTrip() async throws {
        guard let store = makeStore() else { return }
        let key = "live-test-key"
        // Clean slate.
        try await store.delete(key)
        #expect(try await store.get(key) == nil)

        try await store.set(key, "first-value")
        #expect(try await store.get(key) == "first-value")

        // Overwrite (exercises the update path).
        try await store.set(key, "second-value")
        #expect(try await store.get(key) == "second-value")

        try await store.delete(key)
        #expect(try await store.get(key) == nil)
        // Delete is idempotent.
        try await store.delete(key)
    }
}

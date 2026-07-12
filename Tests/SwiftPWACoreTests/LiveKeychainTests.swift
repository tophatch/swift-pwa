#if canImport(Security)
    import Foundation
    @testable import SwiftPWACore
    import Testing

    /// Opt-in live test that round-trips a value through the *real* macOS/iOS
    /// Keychain — proving `KeychainSecretStore` against `SecItem*`, not a mock.
    ///
    /// Off by default (it writes to the login keychain and may prompt for
    /// access in some environments). Run with:
    /// `SWIFT_PWA_LIVE_KEYCHAIN=1 swift test --filter LiveKeychainTests`.
    /// Uses a throwaway service string and cleans up after itself.
    @Suite("LiveKeychain", .enabled(if: ProcessInfo.processInfo.environment["SWIFT_PWA_LIVE_KEYCHAIN"] == "1"))
    struct LiveKeychainTests {
        @Test("set → get → overwrite → delete against the real Keychain")
        func roundTrip() async throws {
            let store = KeychainSecretStore(service: "com.swift-pwa.tests.keychain-live")
            let key = "live-test-key"
            // Clean slate.
            try await store.delete(key)
            #expect(try await store.get(key) == nil)

            try await store.set(key, "first-value")
            #expect(try await store.get(key) == "first-value")

            // Overwrite (exercises the update-not-add path).
            try await store.set(key, "second-value")
            #expect(try await store.get(key) == "second-value")

            try await store.delete(key)
            #expect(try await store.get(key) == nil)
            // Delete is idempotent.
            try await store.delete(key)
        }
    }
#endif

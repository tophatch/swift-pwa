#if os(Linux)
    import Crypto
    import Foundation
    import SwiftPWACore
    @testable import SwiftPWAGTK
    import Testing

    @Suite("LinuxAppImageUpdater")
    struct LinuxAppImageUpdaterTests {
        // MARK: - installAndRelaunch error paths

        @Test("installAndRelaunch errors when no update has been staged")
        func installAndRelaunchWithoutStagedUpdate() async throws {
            let updater = try LinuxAppImageUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: nil,
                appImagePath: URL(fileURLWithPath: "/tmp/swift-pwa-fake.AppImage")
            )
            do {
                try await updater.installAndRelaunch()
                Issue.record("expected installAndRelaunch to throw")
            } catch let bridge as BridgeError {
                #expect(bridge.code == BridgeError.handler)
                #expect(bridge.message.contains("no staged update"))
            } catch {
                Issue.record("expected BridgeError, got \(error)")
            }
        }

        // MARK: - currentAppImagePath resolution

        @Test("currentAppImagePath honours the explicit override")
        func currentAppImagePathOverride() throws {
            let override = URL(fileURLWithPath: "/opt/whatever/MyApp.AppImage")
            let updater = try LinuxAppImageUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: nil,
                appImagePath: override
            )
            #expect(updater.currentAppImagePath() == override)
        }

        // MARK: - atomicReplace

        @Test("atomicReplace clobbers an existing target file")
        func atomicReplaceClobbers() throws {
            let tmp = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: tmp) }

            let target = tmp.appendingPathComponent("running.AppImage")
            try Data("OLD".utf8).write(to: target)
            let source = tmp.appendingPathComponent("staged.AppImage")
            try Data("NEW".utf8).write(to: source)

            let updater = try LinuxAppImageUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: nil,
                appImagePath: target
            )
            try updater.atomicReplace(at: target, with: source)

            #expect(try Data(contentsOf: target) == Data("NEW".utf8))
            // rename(2) consumes the source within the same fs.
            #expect(!FileManager.default.fileExists(atPath: source.path))
        }

        @Test("atomicReplace creates the target when it doesn't exist yet")
        func atomicReplaceFreshTarget() throws {
            let tmp = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: tmp) }

            let target = tmp.appendingPathComponent("running.AppImage")
            let source = tmp.appendingPathComponent("staged.AppImage")
            try Data("FRESH".utf8).write(to: source)

            let updater = try LinuxAppImageUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: nil,
                appImagePath: target
            )
            try updater.atomicReplace(at: target, with: source)

            #expect(try Data(contentsOf: target) == Data("FRESH".utf8))
        }

        // MARK: - Ed25519 verification

        @Test("verifyEd25519 accepts a signature produced by the corresponding private key")
        func verifyEd25519HappyPath() throws {
            let priv = Curve25519.Signing.PrivateKey()
            let pubB64 = priv.publicKey.rawRepresentation.base64EncodedString()
            let payload = Data("the artifact bytes".utf8)
            let sigB64 = try priv.signature(for: payload).base64EncodedString()

            let updater = try LinuxAppImageUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: pubB64
            )
            try updater.verifyEd25519(data: payload, signature: sigB64)
        }

        @Test("verifyEd25519 rejects a signature from a different key")
        func verifyEd25519WrongKey() throws {
            let signingKey = Curve25519.Signing.PrivateKey()
            let unrelatedKey = Curve25519.Signing.PrivateKey()
            let payload = Data("the artifact bytes".utf8)
            let sigB64 = try signingKey.signature(for: payload).base64EncodedString()

            let updater = try LinuxAppImageUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: unrelatedKey.publicKey.rawRepresentation.base64EncodedString()
            )
            do {
                try updater.verifyEd25519(data: payload, signature: sigB64)
                Issue.record("expected verifyEd25519 to throw")
            } catch let bridge as BridgeError {
                #expect(bridge.code == BridgeError.handler)
                #expect(bridge.message.contains("signature verification failed"))
            } catch {
                Issue.record("expected BridgeError, got \(error)")
            }
        }

        @Test("verifyEd25519 rejects a missing public key with a helpful message")
        func verifyEd25519NoKey() throws {
            let updater = try LinuxAppImageUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: nil
            )
            do {
                try updater.verifyEd25519(data: Data(), signature: "")
                Issue.record("expected verifyEd25519 to throw")
            } catch let bridge as BridgeError {
                #expect(bridge.message.contains("no public key configured"))
            } catch {
                Issue.record("expected BridgeError, got \(error)")
            }
        }

        @Test("verifyEd25519 rejects a malformed signature")
        func verifyEd25519MalformedSignature() throws {
            let priv = Curve25519.Signing.PrivateKey()
            let updater = try LinuxAppImageUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: priv.publicKey.rawRepresentation.base64EncodedString()
            )
            do {
                try updater.verifyEd25519(data: Data("x".utf8), signature: "not-base64!!")
                Issue.record("expected verifyEd25519 to throw")
            } catch let bridge as BridgeError {
                #expect(bridge.message.contains("64-byte Ed25519 signature"))
            } catch {
                Issue.record("expected BridgeError, got \(error)")
            }
        }

        // MARK: - helpers

        private func makeTempDir() throws -> URL {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swift-pwa-updater-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
    }
#endif

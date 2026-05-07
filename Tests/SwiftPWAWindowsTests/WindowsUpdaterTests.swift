#if os(Windows)
    import Crypto
    import Foundation
    import SwiftPWACore
    @testable import SwiftPWAWindows
    import Testing

    @Suite("WindowsUpdater")
    struct WindowsUpdaterTests {
        // MARK: - installAndRelaunch error paths

        @Test("installAndRelaunch errors when no update has been staged")
        func installAndRelaunchWithoutStagedUpdate() async throws {
            let updater = try WindowsUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: nil,
                installMode: .portable,
                executablePath: URL(fileURLWithPath: "C:/Program Files/Fake/MyApp.exe")
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

        // MARK: - currentExecutablePath

        @Test("currentExecutablePath honours the explicit override")
        func currentExecutablePathOverride() throws {
            let override = URL(fileURLWithPath: "C:/Apps/Whatever/MyApp.exe")
            let updater = try WindowsUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: nil,
                installMode: .portable,
                executablePath: override
            )
            #expect(updater.currentExecutablePath() == override)
        }

        // MARK: - Ed25519 verification

        @Test("verifyEd25519 accepts a signature produced by the corresponding private key")
        func verifyEd25519HappyPath() throws {
            let priv = Curve25519.Signing.PrivateKey()
            let pubB64 = priv.publicKey.rawRepresentation.base64EncodedString()
            let payload = Data("the artifact bytes".utf8)
            let sigB64 = try priv.signature(for: payload).base64EncodedString()

            let updater = try WindowsUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: pubB64,
                installMode: .portable
            )
            try updater.verifyEd25519(data: payload, signature: sigB64)
        }

        @Test("verifyEd25519 rejects a signature from a different key")
        func verifyEd25519WrongKey() throws {
            let signingKey = Curve25519.Signing.PrivateKey()
            let unrelatedKey = Curve25519.Signing.PrivateKey()
            let payload = Data("the artifact bytes".utf8)
            let sigB64 = try signingKey.signature(for: payload).base64EncodedString()

            let updater = try WindowsUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: unrelatedKey.publicKey.rawRepresentation.base64EncodedString(),
                installMode: .portable
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
            let updater = try WindowsUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: nil,
                installMode: .portable
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
            let updater = try WindowsUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: priv.publicKey.rawRepresentation.base64EncodedString(),
                installMode: .portable
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

        // MARK: - MSIX verification escape hatch

        @Test("MSIX without public key skips verification (trusts Authenticode chain)")
        func msixSkipVerifyWithoutKey() throws {
            let tmp = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: tmp) }
            let staged = tmp.appendingPathComponent("update.msix")
            try Data("fake msix bytes".utf8).write(to: staged)
            let updater = try WindowsUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: nil,
                installMode: .msix
            )
            let info = try UpdateInfo(
                version: "0.4.0",
                currentVersion: "0.3.0",
                downloadURL: #require(URL(string: "https://example.invalid/update.msix")),
                signature: "", // empty → trust the OS chain
                target: "windows-x86_64-msix"
            )
            // Should not throw despite no key + no signature.
            try updater.verifySignature(at: staged, info: info)
        }

        @Test("MSIX with public key still verifies the signature")
        func msixVerifiesWhenKeySet() throws {
            let tmp = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: tmp) }
            let staged = tmp.appendingPathComponent("update.msix")
            let payload = Data("real msix bytes".utf8)
            try payload.write(to: staged)

            let priv = Curve25519.Signing.PrivateKey()
            let pubB64 = priv.publicKey.rawRepresentation.base64EncodedString()
            let sigB64 = try priv.signature(for: payload).base64EncodedString()

            let updater = try WindowsUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: pubB64,
                installMode: .msix
            )
            let info = try UpdateInfo(
                version: "0.4.0",
                currentVersion: "0.3.0",
                downloadURL: #require(URL(string: "https://example.invalid/update.msix")),
                signature: sigB64,
                target: "windows-x86_64-msix"
            )
            try updater.verifySignature(at: staged, info: info)
        }

        @Test("Portable mode requires a configured public key")
        func portableRequiresKey() throws {
            let tmp = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: tmp) }
            let staged = tmp.appendingPathComponent("update.exe")
            try Data("fake exe".utf8).write(to: staged)
            let updater = try WindowsUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: nil,
                installMode: .portable
            )
            let info = try UpdateInfo(
                version: "0.4.0",
                currentVersion: "0.3.0",
                downloadURL: #require(URL(string: "https://example.invalid/update.exe")),
                signature: "",
                target: "windows-x86_64-portable"
            )
            do {
                try updater.verifySignature(at: staged, info: info)
                Issue.record("expected verifySignature to throw on portable without key")
            } catch let bridge as BridgeError {
                #expect(bridge.message.contains("no public key configured"))
            } catch {
                Issue.record("expected BridgeError, got \(error)")
            }
        }

        // MARK: - MSIX relaunch identity

        @Test("MSIX identity defaults to nil when not supplied")
        func msixIdentityDefaultsNil() throws {
            let updater = try WindowsUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: nil,
                installMode: .msix
            )
            #expect(updater.msixIdentityName == nil)
            #expect(updater.applicationID == "App")
        }

        @Test("MSIX identity round-trips through the constructor")
        func msixIdentityRoundtrip() throws {
            let updater = try WindowsUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: nil,
                installMode: .msix,
                msixIdentityName: "com.example.hello",
                applicationID: "App"
            )
            #expect(updater.msixIdentityName == "com.example.hello")
            #expect(updater.applicationID == "App")
        }

        @Test("verifyEd25519 accepts minisign-format inputs")
        func verifyEd25519MinisignInputs() throws {
            let priv = Curve25519.Signing.PrivateKey()
            let payload = Data("an msix's bytes".utf8)
            let rawSig = try priv.signature(for: payload)

            var pubBlob = Data()
            pubBlob.append(contentsOf: "Ed".utf8)
            pubBlob.append(contentsOf: Array(repeating: UInt8(0), count: 8))
            pubBlob.append(priv.publicKey.rawRepresentation)
            let pubText = """
            untrusted comment: minisign public key
            \(pubBlob.base64EncodedString())
            """

            var sigBlob = Data()
            sigBlob.append(contentsOf: "Ed".utf8)
            sigBlob.append(contentsOf: Array(repeating: UInt8(0), count: 8))
            sigBlob.append(rawSig)
            let sigText = """
            untrusted comment: signature
            \(sigBlob.base64EncodedString())
            trusted comment: x
            \(Data(repeating: 0, count: 64).base64EncodedString())
            """

            let updater = try WindowsUpdater(
                endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                publicKey: pubText,
                installMode: .portable
            )
            try updater.verifyEd25519(data: payload, signature: sigText)
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

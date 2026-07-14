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

        // MARK: - ZstdPatch (delta reconstruction)

        @Test("ZstdPatch.apply reconstructs the new artifact from base + a zstd --patch-from patch")
        func zstdPatchRoundTrip() throws {
            guard zstdAvailable() else { return } // skip on a zstd-less image
            let tmp = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: tmp) }

            // A base with a small changed region — the point of a delta.
            var newBytes = Data((0 ..< 300_000).map { UInt8($0 &* 37 & 0xFF) })
            let base = tmp.appendingPathComponent("base.bin")
            try newBytes.write(to: base)
            newBytes.replaceSubrange(150_000 ..< 150_080, with: Data(repeating: 0x5A, count: 80))
            let new = tmp.appendingPathComponent("new.bin")
            try newBytes.write(to: new)

            let patch = tmp.appendingPathComponent("p.zstpatch")
            try runZstd(["-q", "-f", "-19", "--long=30", "--patch-from=\(base.path)", new.path, "-o", patch.path])

            let baseData = try Data(contentsOf: base)
            let patchData = try Data(contentsOf: patch)
            // Far smaller than the full artifact (this is the whole point).
            #expect(patchData.count < newBytes.count / 10)

            let reconstructed = try ZstdPatch.apply(base: baseData, patch: patchData)
            #expect(reconstructed == newBytes)
        }

        @Test("ZstdPatch.apply throws on a corrupt patch (so the updater can fall back)")
        func zstdPatchRejectsCorruptPatch() throws {
            guard zstdAvailable() else { return }
            let tmp = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: tmp) }

            let baseData = Data((0 ..< 100_000).map { UInt8($0 & 0xFF) })
            let base = tmp.appendingPathComponent("base.bin")
            try baseData.write(to: base)
            var changed = baseData
            changed.replaceSubrange(50000 ..< 50020, with: Data(repeating: 0x11, count: 20))
            let new = tmp.appendingPathComponent("new.bin")
            try changed.write(to: new)

            let patch = tmp.appendingPathComponent("p.zstpatch")
            try runZstd(["-q", "-f", "-19", "--long=30", "--patch-from=\(base.path)", new.path, "-o", patch.path])

            // Corrupt the patch bytes; reconstruction must fail rather than
            // silently produce garbage.
            var corrupt = try Data(contentsOf: patch)
            for i in corrupt.indices where i % 3 == 0 { corrupt[i] = corrupt[i] ^ 0xFF }
            #expect(throws: BridgeError.self) {
                _ = try ZstdPatch.apply(base: baseData, patch: corrupt)
            }
        }

        // MARK: - helpers

        private func zstdAvailable() -> Bool {
            (try? runZstd(["--version"])) != nil
        }

        @discardableResult
        private func runZstd(_ args: [String]) throws -> Int32 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["zstd"] + args
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw BridgeError(code: BridgeError.handler, message: "zstd exited \(proc.terminationStatus)")
            }
            return proc.terminationStatus
        }

        private func makeTempDir() throws -> URL {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swift-pwa-updater-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
    }
#endif

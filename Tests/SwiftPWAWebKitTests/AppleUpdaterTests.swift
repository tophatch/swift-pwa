#if os(macOS) || os(iOS)
    import CryptoKit
    import Foundation
    import SwiftPWACore
    @testable import SwiftPWAWebKit
    import Testing

    /// Mirrors `LinuxAppImageUpdaterTests` / `WindowsUpdaterTests` for
    /// the Apple backend. Until v0.4 the Apple backend had no
    /// targeted unit tests around its `verifyEd25519` helper — the
    /// shared minisign / raw-base64 coercion now lives in core, so a
    /// regression there would have cascaded silently across every
    /// backend without a per-backend test pinning the contract.
    @Suite("AppleUpdater")
    struct AppleUpdaterTests {
        @Test("verifyEd25519 accepts a signature produced by the corresponding private key")
        func verifyEd25519HappyPath() throws {
            #if os(macOS)
                let priv = Curve25519.Signing.PrivateKey()
                let pubB64 = priv.publicKey.rawRepresentation.base64EncodedString()
                let payload = Data("the artifact bytes".utf8)
                let sigB64 = try priv.signature(for: payload).base64EncodedString()

                let updater = try AppleUpdater(
                    endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                    publicKey: pubB64
                )
                try updater.verifyEd25519(data: payload, signature: sigB64)
            #endif
        }

        @Test("verifyEd25519 accepts minisign-format public key + signature inputs")
        func verifyEd25519MinisignInputs() throws {
            #if os(macOS)
                let priv = Curve25519.Signing.PrivateKey()
                let payload = Data("the artifact bytes".utf8)
                let rawSig = try priv.signature(for: payload)

                // Wrap the raw 32-byte pubkey + 64-byte sig in
                // minisign's two-line shape so the verifier exercises
                // the parser path rather than the plain-base64 path.
                let pubBlob = makePubKeyBlob(rawPubKey: priv.publicKey.rawRepresentation)
                let sigBlob = makeSignatureBlob(rawSignature: rawSig)
                let pubText = """
                untrusted comment: minisign public key XXXX
                \(pubBlob)
                """
                let sigText = """
                untrusted comment: signature
                \(sigBlob)
                trusted comment: timestamp:0 file:test
                \(Data(repeating: 0, count: 64).base64EncodedString())
                """

                let updater = try AppleUpdater(
                    endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                    publicKey: pubText
                )
                try updater.verifyEd25519(data: payload, signature: sigText)
            #endif
        }

        @Test("verifyEd25519 rejects a signature from a different key")
        func verifyEd25519WrongKey() throws {
            #if os(macOS)
                let signingKey = Curve25519.Signing.PrivateKey()
                let unrelatedKey = Curve25519.Signing.PrivateKey()
                let payload = Data("the artifact bytes".utf8)
                let sigB64 = try signingKey.signature(for: payload).base64EncodedString()

                let updater = try AppleUpdater(
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
            #endif
        }

        @Test("verifyEd25519 rejects a missing public key with a helpful message")
        func verifyEd25519NoKey() throws {
            #if os(macOS)
                let updater = try AppleUpdater(
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
            #endif
        }

        // MARK: - ZstdPatch (delta reconstruction)

        @Test("ZstdPatch.apply reconstructs the new artifact from base + a zstd --patch-from patch")
        func zstdPatchRoundTrip() throws {
            #if os(macOS)
                guard zstdAvailable() else { return } // skip on a zstd-less host
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
            #endif
        }

        @Test("ZstdPatch.apply throws on a corrupt patch (so the updater can fall back)")
        func zstdPatchRejectsCorruptPatch() throws {
            #if os(macOS)
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
            #endif
        }

        @Test("cachedBaseTarballURL returns nil until a base is cached, then the version-keyed tarball")
        func cachedBaseTarballDiscovery() throws {
            #if os(macOS)
                let tmp = try makeTempDir()
                defer { try? FileManager.default.removeItem(at: tmp) }

                let updater = try AppleUpdater(
                    endpoint: #require(URL(string: "https://example.invalid/manifest.json")),
                    publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
                    currentVersion: "1.2.3",
                    stagingRoot: tmp
                )

                // No base cached yet → nil (the first update always full-downloads).
                #expect(updater.cachedBaseTarballURL() == nil)

                // Simulate a prior update having cached the base for 1.2.3.
                let baseDir = tmp.appendingPathComponent("base", isDirectory: true)
                try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
                let tarball = baseDir.appendingPathComponent("1.2.3.app.tar.gz")
                try Data("cached base bytes".utf8).write(to: tarball)

                #expect(updater.cachedBaseTarballURL() == tarball)

                // A base cached under a *different* version doesn't match the
                // running version, so it isn't offered as a patch base.
                try FileManager.default.removeItem(at: tarball)
                try Data("other".utf8).write(to: baseDir.appendingPathComponent("9.9.9.app.tar.gz"))
                #expect(updater.cachedBaseTarballURL() == nil)
            #endif
        }

        // MARK: - helpers

        #if os(macOS)
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
                    .appendingPathComponent("swift-pwa-apple-updater-tests-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir
            }

            /// Build the raw 42-byte minisign public-key blob (algo id +
            /// key id + raw pubkey) and base64-encode it, ready to drop
            /// in as the second line of a minisign public-key file.
            private func makePubKeyBlob(rawPubKey: Data) -> String {
                var blob = Data()
                blob.append(contentsOf: "Ed".utf8)
                blob.append(contentsOf: Array(repeating: UInt8(0xAA), count: 8))
                blob.append(rawPubKey)
                return blob.base64EncodedString()
            }

            /// Same for the 74-byte minisign signature blob.
            private func makeSignatureBlob(rawSignature: Data) -> String {
                var blob = Data()
                blob.append(contentsOf: "Ed".utf8)
                blob.append(contentsOf: Array(repeating: UInt8(0xAA), count: 8))
                blob.append(rawSignature)
                return blob.base64EncodedString()
            }
        #endif
    }
#endif

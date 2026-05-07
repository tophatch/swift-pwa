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

        // MARK: - helpers

        #if os(macOS)
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

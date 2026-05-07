import Foundation
import SwiftPWACore
import Testing

@Suite("Minisign parser")
struct MinisignTests {
    // MARK: - parsePublicKey

    @Test("Plain base64 input returns nil so callers can fall back")
    func plainBase64NotMinisign() throws {
        let raw = Data(repeating: 0x42, count: 32).base64EncodedString()
        #expect(try Minisign.parsePublicKey(raw) == nil)
    }

    @Test("A real-looking minisign public key parses to the trailing 32 bytes")
    func publicKeyHappyPath() throws {
        // Build a synthetic minisign public-key blob: 2-byte algo "Ed",
        // 8-byte key id, 32-byte pubkey. Real minisign bumps a few bits
        // in the key id we don't care about — we just verify the suffix.
        var blob = Data()
        blob.append(contentsOf: "Ed".utf8) // legacy algorithm
        blob.append(contentsOf: Array(repeating: UInt8(0xAB), count: 8)) // key id
        blob.append(contentsOf: Array(repeating: UInt8(0x77), count: 32)) // pubkey
        let body = blob.base64EncodedString()
        let text = """
        untrusted comment: minisign public key 1234567890ABCDEF
        \(body)
        """

        let parsed = try Minisign.parsePublicKey(text)
        #expect(parsed == Data(repeating: 0x77, count: 32))
    }

    @Test("Public key with the wrong byte length throws a length error")
    func publicKeyWrongLength() throws {
        var blob = Data()
        blob.append(contentsOf: "Ed".utf8)
        // 8 + 16 = 24 bytes after algo, not 8 + 32.
        blob.append(contentsOf: Array(repeating: UInt8(0), count: 8 + 16))
        let text = """
        untrusted comment: minisign public key
        \(blob.base64EncodedString())
        """
        #expect(throws: BridgeError.self) {
            _ = try Minisign.parsePublicKey(text)
        }
    }

    @Test("Public key in prehashed 'ED' mode is rejected with a helpful pointer")
    func publicKeyPrehashedRejected() throws {
        var blob = Data()
        blob.append(contentsOf: "ED".utf8) // prehashed
        blob.append(contentsOf: Array(repeating: UInt8(0), count: 8 + 32))
        let text = """
        untrusted comment: minisign public key
        \(blob.base64EncodedString())
        """
        do {
            _ = try Minisign.parsePublicKey(text)
            Issue.record("expected throw")
        } catch let error as BridgeError {
            #expect(error.code == BridgeError.handler)
            #expect(error.message.contains("prehashed"))
            #expect(error.message.contains("minisign -Sl"))
        } catch {
            Issue.record("expected BridgeError, got \(error)")
        }
    }

    // MARK: - parseSignature

    @Test("Plain base64 signature returns nil")
    func plainBase64SignatureNotMinisign() throws {
        let raw = Data(repeating: 0xAA, count: 64).base64EncodedString()
        #expect(try Minisign.parseSignature(raw) == nil)
    }

    @Test("A minisign signature file parses to the 64-byte signature")
    func signatureHappyPath() throws {
        var blob = Data()
        blob.append(contentsOf: "Ed".utf8)
        blob.append(contentsOf: Array(repeating: UInt8(0x99), count: 8))
        blob.append(contentsOf: Array(repeating: UInt8(0xCC), count: 64))
        let body = blob.base64EncodedString()
        let trustedSig = Data(repeating: 0xDE, count: 64).base64EncodedString()
        let text = """
        untrusted comment: signature from minisign secret key
        \(body)
        trusted comment: timestamp:1234 file:hello.AppImage
        \(trustedSig)
        """

        let parsed = try Minisign.parseSignature(text)
        #expect(parsed == Data(repeating: 0xCC, count: 64))
    }

    @Test("Signature with the wrong byte length throws on length")
    func signatureWrongLength() throws {
        // Valid base64, decoded length wrong: 8 + 16 = 24 bytes, not 74.
        let bogusBlob = Data(repeating: 0, count: 24).base64EncodedString()
        let text = """
        untrusted comment: signature
        \(bogusBlob)
        """
        do {
            _ = try Minisign.parseSignature(text)
            Issue.record("expected throw")
        } catch let error as BridgeError {
            #expect(error.message.contains("wrong length"))
        } catch {
            Issue.record("expected BridgeError, got \(error)")
        }
    }

    @Test("Signature with non-base64 second line returns nil so callers fall back")
    func signatureUndecodableTreatedAsNonMinisign() throws {
        let text = """
        untrusted comment: signature
        not actually base64 at all !!!
        """
        // The blob isn't valid base64; from the parser's POV this isn't
        // a minisign sig at all (just a comment + garbage). Returning
        // nil lets the caller's fallback to `Data(base64Encoded:)` of
        // the original string make the final call about validity.
        #expect(try Minisign.parseSignature(text) == nil)
    }

    // MARK: - resolveEd25519PublicKey / Signature convenience

    @Test("resolveEd25519PublicKey accepts plain base64 unchanged")
    func resolvePublicKeyPlainBase64() throws {
        let raw = Data(repeating: 0x33, count: 32)
        let resolved = try resolveEd25519PublicKey(raw.base64EncodedString())
        #expect(resolved == raw)
    }

    @Test("resolveEd25519PublicKey accepts minisign-format input")
    func resolvePublicKeyMinisign() throws {
        var blob = Data()
        blob.append(contentsOf: "Ed".utf8)
        blob.append(contentsOf: Array(repeating: UInt8(0), count: 8))
        blob.append(contentsOf: Array(repeating: UInt8(0x55), count: 32))
        let text = "untrusted comment: x\n\(blob.base64EncodedString())\n"

        let resolved = try resolveEd25519PublicKey(text)
        #expect(resolved == Data(repeating: 0x55, count: 32))
    }

    @Test("resolveEd25519PublicKey rejects neither-form input with a clear message")
    func resolvePublicKeyRejectsGarbage() {
        do {
            _ = try resolveEd25519PublicKey("not a key at all")
            Issue.record("expected throw")
        } catch let error as BridgeError {
            #expect(error.message.contains("base64"))
            #expect(error.message.contains("minisign"))
        } catch {
            Issue.record("expected BridgeError, got \(error)")
        }
    }

    @Test("resolveEd25519Signature tolerates surrounding whitespace on plain base64")
    func resolveSignatureTrimsWhitespace() throws {
        let raw = Data(repeating: 0x11, count: 64)
        let padded = "  \n" + raw.base64EncodedString() + "\n  "
        let resolved = try resolveEd25519Signature(padded)
        #expect(resolved == raw)
    }
}

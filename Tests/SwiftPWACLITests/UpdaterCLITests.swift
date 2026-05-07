import Crypto
import Foundation
@testable import SwiftPWACLISupport
import SwiftPWACore
import Testing

@Suite("Updater CLI helpers")
struct UpdaterCLITests {
    // MARK: - parsePlatformSpec

    @Test("Two-part spec → unsigned (iOS enterprise shape)")
    func twoPartSpecIsUnsigned() throws {
        let parsed = try UpdaterCLISupport.parsePlatformSpec(
            "ios-aarch64-enterprise=https://example.com/manifest.plist"
        )
        #expect(parsed.target == "ios-aarch64-enterprise")
        #expect(parsed.downloadURL == "https://example.com/manifest.plist")
        #expect(parsed.kind == .unsigned)
    }

    @Test("Three-part spec where the middle is an existing file → needsSigning")
    func threePartSpecLocalArtifact() throws {
        let tmp = try makeTempArtifact(named: "needs-sign.bin", bytes: 16)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let parsed = try UpdaterCLISupport.parsePlatformSpec(
            "darwin-aarch64=\(tmp.path)=https://example.com/MyApp.app.tar.gz"
        )
        #expect(parsed.target == "darwin-aarch64")
        #expect(parsed.downloadURL == "https://example.com/MyApp.app.tar.gz")
        #expect(parsed.kind == .needsSigning(tmp.path))
    }

    @Test("Three-part spec where the middle is a URL → signed (third is base64 sig)")
    func threePartSpecPreSigned() throws {
        let parsed = try UpdaterCLISupport.parsePlatformSpec(
            "darwin-aarch64=https://example.com/MyApp.app.tar.gz=BASE64SIG"
        )
        #expect(parsed.target == "darwin-aarch64")
        #expect(parsed.downloadURL == "https://example.com/MyApp.app.tar.gz")
        #expect(parsed.kind == .signed("BASE64SIG"))
    }

    @Test("Pre-signed spec preserves base64 padding even though `=` is the separator")
    func preSignedPreservesBase64Padding() throws {
        // Real Ed25519 signatures often end in `==` after base64
        // encoding. The parser splits on `=`, so the trailing pad
        // must be reassembled into a single value rather than dropped.
        let sig = "AAAA=="
        let parsed = try UpdaterCLISupport.parsePlatformSpec(
            "darwin-aarch64=https://example.com/MyApp.app.tar.gz=\(sig)"
        )
        #expect(parsed.kind == .signed(sig))
    }

    @Test("Empty target rejected")
    func emptyTargetRejected() {
        #expect(throws: (any Error).self) {
            _ = try UpdaterCLISupport.parsePlatformSpec("=https://example.com/x")
        }
    }

    // MARK: - loadPrivateKey

    @Test("loadPrivateKey round-trips a freshly written key")
    func loadPrivateKeyRoundtrip() throws {
        let key = Curve25519.Signing.PrivateKey()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("key.priv").path
        try (key.rawRepresentation.base64EncodedString() + "\n").write(
            toFile: path, atomically: true, encoding: .utf8
        )

        let loaded = try UpdaterCLISupport.loadPrivateKey(at: path)
        #expect(loaded.rawRepresentation == key.rawRepresentation)
    }

    @Test("loadPrivateKey rejects a non-base64 file")
    func loadPrivateKeyRejectsGarbage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("key.priv").path
        try "not a key".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            _ = try UpdaterCLISupport.loadPrivateKey(at: path)
        }
    }

    @Test("loadPrivateKey rejects a base64 blob of the wrong length")
    func loadPrivateKeyRejectsWrongLength() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("key.priv").path
        // 16 bytes → not 32
        let bogus = Data(repeating: 0x42, count: 16).base64EncodedString()
        try bogus.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            _ = try UpdaterCLISupport.loadPrivateKey(at: path)
        }
    }

    // MARK: - sign + verify round-trip (proves wire-format compat with AppleUpdater)

    @Test("Signatures produced via UpdaterCLISupport verify against the matching public key")
    func signVerifyRoundtrip() throws {
        let key = Curve25519.Signing.PrivateKey()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyPath = dir.appendingPathComponent("key.priv").path
        try (key.rawRepresentation.base64EncodedString() + "\n").write(
            toFile: keyPath, atomically: true, encoding: .utf8
        )

        let artifact = try makeTempArtifact(named: "art.bin", bytes: 4096)
        defer { try? FileManager.default.removeItem(at: artifact) }

        let loaded = try UpdaterCLISupport.loadPrivateKey(at: keyPath)
        let data = try UpdaterCLISupport.readArtifact(at: artifact)
        let sigBase64 = try loaded.signature(for: data).base64EncodedString()

        guard let sigBytes = Data(base64Encoded: sigBase64) else {
            Issue.record("base64 round-trip failed")
            return
        }
        // Verify exactly the same way `AppleUpdater.verifyEd25519` does.
        #expect(key.publicKey.isValidSignature(sigBytes, for: data))
    }

    // MARK: - manifest round-trip

    @Test("Encoded manifest decodes back into UpdateManifest with matching fields")
    func manifestRoundtrip() throws {
        let entry = try UpdateManifest.PlatformEntry(
            url: #require(URL(string: "https://example.com/MyApp.app.tar.gz")),
            signature: "AAAA"
        )
        let original = UpdateManifest(
            version: "0.4.0",
            pubDate: "2026-05-12T10:00:00Z",
            notes: "Bug fixes.",
            platforms: ["darwin-aarch64": entry]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(original)

        // Wire format must match Tauri v1 (snake_case keys).
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"pub_date\""))
        #expect(!json.contains("\"pubDate\""))

        let decoded = try JSONDecoder().decode(UpdateManifest.self, from: data)
        #expect(decoded == original)
    }

    @Test("currentISO8601Date parses back into a Date")
    func iso8601IsRoundTrippable() {
        let formatted = UpdaterCLISupport.currentISO8601Date()
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        #expect(parser.date(from: formatted) != nil)
    }

    // MARK: - minisign output round-trip

    @Test("Minisign-format public key from the CLI parses back via Minisign")
    func minisignPublicKeyRoundtrip() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let raw = priv.publicKey.rawRepresentation
        let text = MinisignFormat.publicKeyText(rawPubKey: raw)

        // The runtime-side parser lives in SwiftPWACore — same one the
        // updater verifiers call. Round-tripping through it proves the
        // CLI's output is consumable as-is by every backend.
        let parsed = try Minisign.parsePublicKey(text)
        #expect(parsed == raw)
    }

    @Test("Minisign-format signature from the CLI parses back via Minisign")
    func minisignSignatureRoundtrip() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let payload = Data("artifact bytes".utf8)
        let rawSig = try priv.signature(for: payload)
        let text = MinisignFormat.signatureText(rawSignature: rawSig, artifactName: "x.AppImage")

        let parsed = try Minisign.parseSignature(text)
        #expect(parsed == rawSig)

        // And the public-key side verifies the parsed signature against
        // the artifact bytes — proves the wire format is end-to-end
        // valid, not just structurally well-formed.
        guard let parsed else {
            Issue.record("parser returned nil")
            return
        }
        #expect(priv.publicKey.isValidSignature(parsed, for: payload))
    }

    // MARK: - helpers

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-updater-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTempArtifact(named name: String, bytes: Int) throws -> URL {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent(name)
        let data = Data((0 ..< bytes).map { UInt8($0 & 0xFF) })
        try data.write(to: url)
        return url
    }
}

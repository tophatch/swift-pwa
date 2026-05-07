import ArgumentParser
import Crypto
import Foundation
import SwiftPWACore

/// Top-level `swift-pwa updater` group. The three subcommands form the
/// publishing pipeline that backs the runtime-side `Updater` protocol
/// across every supported backend:
///
/// 1. `keygen` — generate a fresh Ed25519 keypair. The public half is
///    what apps embed via `pwa.json`'s `updater.public_key`; the private
///    half stays on the release machine and is fed to `sign`.
/// 2. `sign` — sign a release artifact with the private key. Output is
///    base64 of the raw 64-byte Ed25519 signature, byte-compatible with
///    the format the runtime verifiers (`AppleUpdater`,
///    `LinuxAppImageUpdater`, `WindowsUpdater`) expect.
/// 3. `manifest` — assemble the JSON manifest file that the runtime's
///    `updater.endpoint` URL will serve. Optionally signs each platform
///    artifact in one pass when `--private-key` is supplied.
///
/// Both `keygen` and `sign` accept a `--minisign` flag that switches the
/// output from raw-base64 to the [minisign](https://jedisct1.github.io/minisign/)
/// two-line `untrusted comment: …\n<base64>` shape — the runtime
/// verifiers accept either form transparently. Existing pipelines that
/// already produce minisign keys with the `minisign` CLI can also feed
/// those files through unchanged.
///
/// The wire format is the `UpdateManifest` shape from `SwiftPWACore`,
/// matching Tauri v1's updater manifest layout — same publishing
/// tooling can produce manifests for swift-pwa apps.
struct Updater: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "updater",
        abstract: "Generate keys, sign artifacts, and assemble the auto-updater manifest.",
        subcommands: [Keygen.self, Sign.self, Manifest.self]
    )
}

// MARK: - keygen

extension Updater {
    struct Keygen: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "keygen",
            abstract: "Generate an Ed25519 keypair for signing updater artifacts."
        )

        @Option(help: "Path to write the private key (base64 of the raw 32 bytes).")
        var privateKey: String

        @Option(help: "Path to write the public key (base64 of the raw 32 bytes).")
        var publicKey: String

        @Flag(help: "Overwrite the output files if they already exist.")
        var force: Bool = false

        @Flag(help: """
        Wrap the public key in the two-line minisign `untrusted comment: …\\n<base64>` \
        shape (legacy 'Ed' algorithm). The private key stays as raw base64 — \
        `swift-pwa updater sign` reads only the raw form. Existing minisign \
        public-key files can be embedded as-is in `pwa.json`'s `updater.public_key` \
        without going through this flag.
        """)
        var minisign: Bool = false

        func run() throws {
            let priv = Curve25519.Signing.PrivateKey()
            let privB64 = priv.rawRepresentation.base64EncodedString()
            let pubB64 = priv.publicKey.rawRepresentation.base64EncodedString()
            let pubMinisign = MinisignFormat.publicKeyText(rawPubKey: priv.publicKey.rawRepresentation)
            let pubOutput = minisign ? pubMinisign : pubB64

            let privURL = URL(fileURLWithPath: privateKey)
            let pubURL = URL(fileURLWithPath: publicKey)

            for url in [privURL, pubURL] where FileManager.default.fileExists(atPath: url.path) && !force {
                throw ValidationError(
                    "swift-pwa: \(url.path) already exists — pass --force to overwrite."
                )
            }

            // The private key is sensitive: write it 0600 so a stray
            // `cat` from another user account on the dev box doesn't
            // expose it. The public key is fine 0644 — it's meant to
            // ship in `pwa.json`.
            try (privB64 + "\n").write(to: privURL, atomically: true, encoding: .utf8)
            #if !os(Windows)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: privURL.path
                )
            #endif
            try (pubOutput + "\n").write(to: pubURL, atomically: true, encoding: .utf8)

            print("Wrote private key: \(privURL.path)")
            print("Wrote public key:  \(pubURL.path)")
            print("")
            print("Add to pwa.json:")
            print("  \"updater\": {")
            if minisign {
                // pwa.json's value is a JSON string — escape newlines
                // so the user can paste the multi-line minisign block
                // verbatim and JSON parsers don't choke.
                let escaped = pubOutput.replacingOccurrences(of: "\n", with: "\\n")
                print("    \"public_key\": \"\(escaped)\",")
            } else {
                print("    \"public_key\": \"\(pubB64)\",")
            }
            print("    \"pubkey_algorithm\": \"ed25519\"")
            print("  }")
        }
    }
}

// MARK: - sign

extension Updater {
    struct Sign: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sign",
            abstract: "Sign a release artifact and emit the base64 Ed25519 signature."
        )

        @Option(help: "Path to the private key produced by `swift-pwa updater keygen`.")
        var privateKey: String

        @Option(name: [.customShort("o"), .long], help: "Write the signature to this path. Defaults to <artifact>.sig.")
        var output: String?

        @Flag(help: "Print the signature to stdout instead of writing a sidecar file.")
        var stdout: Bool = false

        @Argument(help: "Path to the artifact to sign.")
        var artifact: String

        @Flag(help: """
        Wrap the output in the two-line minisign `untrusted comment: …\\n<base64>` \
        shape (legacy 'Ed' algorithm). Default output is raw-base64 — both forms \
        are accepted by every runtime verifier.
        """)
        var minisign: Bool = false

        func run() throws {
            let key = try UpdaterCLISupport.loadPrivateKey(at: privateKey)
            let artifactURL = URL(fileURLWithPath: artifact)
            let data = try UpdaterCLISupport.readArtifact(at: artifactURL)
            let rawSignature = try key.signature(for: data)
            let signatureOutput: String = if minisign {
                MinisignFormat.signatureText(
                    rawSignature: rawSignature,
                    artifactName: artifactURL.lastPathComponent
                )
            } else {
                rawSignature.base64EncodedString()
            }

            if stdout {
                print(signatureOutput)
                return
            }

            let outPath = output ?? (artifact + ".sig")
            let outURL = URL(fileURLWithPath: outPath)
            try (signatureOutput + "\n").write(to: outURL, atomically: true, encoding: .utf8)
            print("Wrote signature: \(outURL.path)")
        }
    }
}

// MARK: - manifest

extension Updater {
    struct Manifest: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "manifest",
            abstract: "Assemble the JSON updater manifest the endpoint URL serves."
        )

        @Option(help: "Release version, e.g. 0.4.0.")
        var version: String

        @Option(help: "ISO-8601 publication date. Defaults to the current UTC time.")
        var pubDate: String?

        @Option(help: "Release notes (plain text or markdown — passed through verbatim).")
        var notes: String?

        @Option(help: "Path to the private key. Required when --platform values reference local artifacts to sign.")
        var privateKey: String?

        @Option(
            name: .long,
            parsing: .upToNextOption,
            help: ArgumentHelp(
                "Per-target entry. Three forms accepted:",
                discussion: """
                <target>=<artifact-path>=<download-url>
                    Sign <artifact-path> with --private-key, embed the resulting signature.

                <target>=<download-url>=<base64-signature>
                    Pre-signed (e.g. produced by an earlier `swift-pwa updater sign`).

                <target>=<download-url>
                    No signature — only valid for iOS enterprise / ad-hoc, where
                    the system installer validates the .ipa via Apple's signing chain.
                """,
                valueName: "spec"
            )
        )
        var platform: [String] = []

        @Option(name: [.customShort("o"), .long], help: "Output path. Defaults to ./manifest.json.")
        var output: String = "manifest.json"

        @Flag(help: "Overwrite the output file if it already exists.")
        var force: Bool = false

        func run() throws {
            guard !platform.isEmpty else {
                throw ValidationError(
                    "swift-pwa: --platform must be supplied at least once. See `swift-pwa updater manifest --help`."
                )
            }

            let outURL = URL(fileURLWithPath: output)
            if FileManager.default.fileExists(atPath: outURL.path), !force {
                throw ValidationError(
                    "swift-pwa: \(outURL.path) already exists — pass --force to overwrite."
                )
            }

            let signingKey = try privateKey.map { try UpdaterCLISupport.loadPrivateKey(at: $0) }

            var entries: [String: UpdateManifest.PlatformEntry] = [:]
            for spec in platform {
                let parsed = try UpdaterCLISupport.parsePlatformSpec(spec)
                let signature = try resolveSignature(parsed: parsed, signingKey: signingKey)
                guard let url = URL(string: parsed.downloadURL) else {
                    throw ValidationError(
                        "swift-pwa: --platform \(parsed.target): '\(parsed.downloadURL)' is not a valid URL."
                    )
                }
                entries[parsed.target] = UpdateManifest.PlatformEntry(
                    url: url, signature: signature
                )
            }

            let manifest = UpdateManifest(
                version: version,
                pubDate: pubDate ?? UpdaterCLISupport.currentISO8601Date(),
                notes: notes,
                platforms: entries
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: outURL, options: .atomic)
            print("Wrote manifest: \(outURL.path) (\(entries.count) target\(entries.count == 1 ? "" : "s"))")
        }

        private func resolveSignature(
            parsed: UpdaterCLISupport.PlatformSpec,
            signingKey: Curve25519.Signing.PrivateKey?
        ) throws -> String {
            switch parsed.kind {
            case let .signed(signature):
                return signature
            case .unsigned:
                return ""
            case let .needsSigning(artifactPath):
                guard let signingKey else {
                    throw ValidationError("""
                    swift-pwa: --platform \(parsed.target) references a local artifact (\(artifactPath)) \
                    but --private-key was not supplied. Either pass --private-key, or pre-sign with \
                    `swift-pwa updater sign` and pass the base64 signature directly.
                    """)
                }
                let data = try UpdaterCLISupport.readArtifact(at: URL(fileURLWithPath: artifactPath))
                return try signingKey.signature(for: data).base64EncodedString()
            }
        }
    }
}

// MARK: - shared helpers

/// Pulled out of the subcommand structs so it can be unit-tested
/// directly (the subcommands themselves go through ArgumentParser's
/// `run()`, which is awkward to drive from `swift-testing`).
enum UpdaterCLISupport {
    struct PlatformSpec: Equatable {
        enum Kind: Equatable {
            case signed(String) // already base64
            case needsSigning(String) // local artifact path
            case unsigned // explicit empty signature (iOS enterprise)
        }

        var target: String
        var downloadURL: String
        var kind: Kind
    }

    /// Parse a `--platform` spec. Three forms (in priority order):
    ///   - 3 parts, second is an existing local file → needsSigning
    ///   - 3 parts, second looks like a URL → signed (third is base64 sig)
    ///   - 2 parts → unsigned (only valid for iOS enterprise)
    static func parsePlatformSpec(_ spec: String) throws -> PlatformSpec {
        let parts = spec.split(separator: "=", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty else {
            throw ValidationError(
                "swift-pwa: --platform spec '\(spec)' is malformed. Expected <target>=<url>[=<signature-or-artifact>]."
            )
        }
        let target = parts[0]
        if parts.count == 2 {
            return PlatformSpec(target: target, downloadURL: parts[1], kind: .unsigned)
        }
        // 3 parts: middle is either an artifact path (sign on the fly)
        // or the download URL (then third is a base64 signature).
        let middle = parts[1]
        let trailing = parts[2 ..< parts.count].joined(separator: "=")
        if FileManager.default.fileExists(atPath: middle) {
            return PlatformSpec(target: target, downloadURL: trailing, kind: .needsSigning(middle))
        }
        return PlatformSpec(target: target, downloadURL: middle, kind: .signed(trailing))
    }

    static func loadPrivateKey(at path: String) throws -> Curve25519.Signing.PrivateKey {
        let url = URL(fileURLWithPath: path)
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ValidationError(
                "swift-pwa: could not read private key at \(url.path): \(error.localizedDescription)"
            )
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed), data.count == 32 else {
            throw ValidationError("""
            swift-pwa: \(url.path) is not a base64-encoded 32-byte Ed25519 private key. \
            Generate one with `swift-pwa updater keygen`.
            """)
        }
        do {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        } catch {
            throw ValidationError(
                "swift-pwa: \(url.path) is not a valid Ed25519 private key: \(error.localizedDescription)"
            )
        }
    }

    static func readArtifact(at url: URL) throws -> Data {
        // `Data(contentsOf:)` is unreliable on swift-corelibs-foundation
        // under Windows (NSCocoaError 260 on real files). Mirror the
        // `WindowsBundler` workaround and route through `FileManager`.
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("swift-pwa: artifact not found: \(url.path)")
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ValidationError("swift-pwa: could not read artifact: \(url.path)")
        }
        return data
    }

    static func currentISO8601Date() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

/// Encoder for minisign-format outputs. Pure formatting logic — the
/// runtime-side parser lives in `SwiftPWACore.Minisign`. We don't try
/// to round-trip the same key id minisign would generate (`SipHash24`
/// over the raw key) because nothing in the verification path checks
/// it; a deterministic placeholder keeps the output stable for tests
/// without ever being meaningful.
enum MinisignFormat {
    /// Stable 8-byte key id placeholder. Real minisign derives this
    /// from a hash of the raw key so the same key always rounds-trips
    /// to the same id; we don't have that machinery in `Crypto` and
    /// the verifier ignores the id, so a constant value is fine. The
    /// pattern (`5357 4946 5450 5741`) spells `SWIFTPWA` in ASCII so
    /// `xxd` on a generated key shows where it came from.
    private static let keyIDPlaceholder: [UInt8] = [
        0x53, 0x57, 0x49, 0x46, 0x54, 0x50, 0x57, 0x41
    ]

    /// Encode `rawPubKey` (32 raw Ed25519 bytes) as a minisign-format
    /// public-key file (legacy 'Ed' algorithm). The trailing newline is
    /// the caller's responsibility.
    static func publicKeyText(rawPubKey: Data) -> String {
        precondition(rawPubKey.count == 32, "public key must be 32 raw bytes")
        var blob = Data()
        blob.append(contentsOf: "Ed".utf8)
        blob.append(contentsOf: keyIDPlaceholder)
        blob.append(rawPubKey)
        return """
        untrusted comment: minisign public key (swift-pwa)
        \(blob.base64EncodedString())
        """
    }

    /// Encode `rawSignature` (64 raw Ed25519 bytes) as a minisign-format
    /// signature file. The trusted-comment block is informational only —
    /// our verifier doesn't check the global signature over it. The
    /// global-signature line is filled with zeroes for that reason; tools
    /// that want a real global signature should sign with the `minisign`
    /// CLI directly.
    static func signatureText(rawSignature: Data, artifactName: String) -> String {
        precondition(rawSignature.count == 64, "signature must be 64 raw bytes")
        var blob = Data()
        blob.append(contentsOf: "Ed".utf8)
        blob.append(contentsOf: keyIDPlaceholder)
        blob.append(rawSignature)
        let trustedComment = "timestamp:\(Int(Date().timeIntervalSince1970))" +
            "\tfile:\(artifactName)\thashed"
        let globalSig = Data(repeating: 0, count: 64).base64EncodedString()
        return """
        untrusted comment: signature from swift-pwa updater sign
        \(blob.base64EncodedString())
        trusted comment: \(trustedComment)
        \(globalSig)
        """
    }
}

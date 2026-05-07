import Foundation

/// Parser for [minisign](https://jedisct1.github.io/minisign/)-format
/// Ed25519 keys and signatures. Pure text manipulation — no crypto deps,
/// so this lives in `SwiftPWACore` and the three updater backends share
/// it before handing the raw bytes to whatever Curve25519 implementation
/// they were built against (CryptoKit on Apple, swift-crypto's `Crypto`
/// elsewhere).
///
/// ## Why support minisign?
///
/// Two reasons. First, lots of release pipelines already produce
/// minisign-format keys and signatures — Tauri's recommended publishing
/// flow is one example, but `minisign(1)` itself is a small standalone
/// utility a release engineer can drop into a build script without
/// pulling Tauri in. Second, the minisign signature file embeds a
/// trusted-comment block (timestamps, file names, etc.) that makes
/// verification artifacts self-describing in a way bare base64 can't.
///
/// ## Wire shapes
///
/// Public key file (two lines):
/// ```
/// untrusted comment: minisign public key <key-id>
/// <base64 of 2-byte algo || 8-byte key-id || 32-byte ed25519 pubkey>
/// ```
///
/// Signature file (four lines):
/// ```
/// untrusted comment: signature from minisign secret key
/// <base64 of 2-byte algo || 8-byte key-id || 64-byte signature>
/// trusted comment: <free-form metadata>
/// <base64 of 64-byte global signature over (sig || trusted comment)>
/// ```
///
/// ## Algorithm modes
///
/// The 2-byte algorithm prefix is one of:
/// - `Ed` — legacy, pure Ed25519 over the file bytes. swift-pwa supports
///   this mode and it's what `swift-pwa updater sign --minisign` emits.
///   To produce it from the `minisign(1)` CLI, use `minisign -Sl`.
/// - `ED` — prehashed: Ed25519 over the BLAKE2b-256 hash of the file.
///   This is the modern default for minisign because it streams cleanly
///   over arbitrarily-large artifacts. swift-pwa rejects it with a clear
///   error today — neither CryptoKit nor swift-crypto ships BLAKE2b out
///   of the box, so adding `ED` support means vendoring or pulling in a
///   BLAKE2b implementation. Tracked as a follow-up.
///
/// The trusted-comment global signature (the fourth line of a sig file)
/// is *not* verified — we don't have the trusted comment bytes the
/// signer used to feed into BLAKE2b/SHA, and the protection it offers
/// (binding the comment to the artifact) is orthogonal to verifying the
/// artifact bytes themselves. Future iterations can verify the global
/// sig once we ship a BLAKE2b in core.
public enum Minisign {
    /// Parse a minisign public-key file's contents. Returns the raw
    /// 32-byte Ed25519 public key.
    ///
    /// Returns `nil` when the input doesn't look like minisign at all —
    /// callers fall back to plain base64 in that case so the existing
    /// `<base64-of-32-bytes>` form keeps working unchanged. Throws a
    /// `BridgeError(code: .handler)` when the input *does* look like
    /// minisign but is malformed (wrong byte length, unsupported
    /// algorithm prefix, undecodeable base64).
    public static func parsePublicKey(_ text: String) throws -> Data? {
        guard let blob = parseBlob(text) else { return nil }
        guard blob.count == 42 else {
            throw BridgeError(
                code: BridgeError.handler,
                message: """
                minisign public key has wrong length: got \(blob.count) bytes, expected 42 \
                (2-byte algorithm + 8-byte key id + 32-byte Ed25519 public key).
                """
            )
        }
        try requireLegacyAlgorithm(blob.prefix(2), kind: "public key")
        // Bytes [2..<10] are the key id — opaque to us; the verify path
        // doesn't need to match it because the manifest already pins one
        // public key per channel. Skip them and return the raw pubkey.
        return Data(blob.suffix(32))
    }

    /// Parse a minisign signature file's contents. Returns the raw
    /// 64-byte Ed25519 signature.
    ///
    /// Returns `nil` for non-minisign input (so callers fall back to
    /// plain base64). Throws `BridgeError(code: .handler)` for malformed
    /// minisign input or for the `ED` prehashed mode (with a message
    /// pointing at `minisign -Sl` to produce a legacy `Ed` signature
    /// instead).
    public static func parseSignature(_ text: String) throws -> Data? {
        guard let blob = parseBlob(text) else { return nil }
        guard blob.count == 74 else {
            throw BridgeError(
                code: BridgeError.handler,
                message: """
                minisign signature has wrong length: got \(blob.count) bytes, expected 74 \
                (2-byte algorithm + 8-byte key id + 64-byte Ed25519 signature).
                """
            )
        }
        try requireLegacyAlgorithm(blob.prefix(2), kind: "signature")
        return Data(blob.suffix(64))
    }

    // MARK: - shared

    /// Both file shapes start with `untrusted comment: …\n<base64>` —
    /// the line immediately after the comment is the blob we care about.
    /// Sig files have additional `trusted comment: …` + global-sig lines
    /// after that, which we ignore.
    private static func parseBlob(_ text: String) -> Data? {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first, first.hasPrefix("untrusted comment:") else {
            return nil
        }
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            // Sig files have an `untrusted comment:` for the global sig
            // too, but it always comes *after* the first blob — so the
            // first non-comment, non-empty line is what we want.
            if line.hasPrefix("untrusted comment:") || line.hasPrefix("trusted comment:") {
                continue
            }
            return Data(base64Encoded: line)
        }
        return nil
    }

    private static func requireLegacyAlgorithm(_ algo: Data.SubSequence, kind: String) throws {
        if algo == Data("ED".utf8) {
            throw BridgeError(
                code: BridgeError.handler,
                message: """
                minisign \(kind) uses the prehashed 'ED' algorithm. swift-pwa supports legacy \
                'Ed' (pure Ed25519 over the artifact bytes) only — re-sign with `minisign -Sl` \
                to produce a legacy-mode signature, or pre-sign with `swift-pwa updater sign` \
                which always emits 'Ed'.
                """
            )
        }
        guard algo == Data("Ed".utf8) else {
            let printable = String(data: Data(algo), encoding: .ascii)?.replacingOccurrences(
                of: "\0", with: "?"
            ) ?? "?\u{2049}"
            throw BridgeError(
                code: BridgeError.handler,
                message: """
                minisign \(kind) uses unsupported algorithm prefix '\(printable)' \
                (expected 'Ed' for legacy Ed25519).
                """
            )
        }
    }
}

// MARK: - Convenience for verifiers

/// Coerce a user-supplied public-key string into raw 32 bytes,
/// accepting both minisign-format text *and* plain base64 of the raw
/// 32 bytes. The two updater backends and the CLI all need the same
/// "either form is fine" coercion at the verify boundary; centralise
/// it here so the failure messages match across the three sites.
///
/// Throws `BridgeError(code: .handler)` if the input is recognisably
/// minisign but malformed, or if it's neither minisign nor 32-byte
/// base64.
public func resolveEd25519PublicKey(_ text: String) throws -> Data {
    if let mini = try Minisign.parsePublicKey(text) {
        return mini
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let raw = Data(base64Encoded: trimmed), raw.count == 32 {
        return raw
    }
    throw BridgeError(
        code: BridgeError.handler,
        message: """
        public key must be either base64 of the raw 32-byte Ed25519 value or a \
        minisign-format public key (the two-line `untrusted comment: …\\n<base64>` shape).
        """
    )
}

/// Same as `resolveEd25519PublicKey`, for 64-byte signatures.
public func resolveEd25519Signature(_ text: String) throws -> Data {
    if let mini = try Minisign.parseSignature(text) {
        return mini
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let raw = Data(base64Encoded: trimmed), raw.count == 64 {
        return raw
    }
    throw BridgeError(
        code: BridgeError.handler,
        message: """
        signature must be either base64 of the raw 64-byte Ed25519 signature or a \
        minisign-format signature file (the `untrusted comment: …\\n<base64>\\ntrusted \
        comment: …\\n<base64>` shape).
        """
    )
}

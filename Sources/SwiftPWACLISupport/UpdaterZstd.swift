import ArgumentParser
import Crypto
import Foundation

/// Publish-side binary-diff helper for the auto-updater's **delta**
/// (binary-patch) support. Shells out to the `zstd` CLI's
/// `--patch-from` diff engine — the same soft external-tool dependency
/// convention the bundlers already use for `tar` / `linuxdeploy` /
/// `xcodebuild` (`swift-pwa doctor` surfaces a missing tool).
///
/// The runtime *apply* side links `libzstd` directly (per-backend, on
/// Linux + Windows portable) rather than shelling out — a phone /
/// desktop app can't assume a `zstd` binary on `PATH`. Both sides speak
/// the same standard zstd frame, so a patch produced here is
/// reconstructable there. Design: `docs/proposals/delta-updates.md`.
enum ZstdTool {
    /// zstd long-distance-match window (log2 bytes). 2^30 = 1 GiB covers
    /// any realistic app artifact as the diff reference; zstd only
    /// allocates what the actual reference needs. The runtime
    /// decompressor must permit a window at least this large
    /// (`ZSTD_d_windowLogMax`).
    static let windowLog = 30

    /// Produce a patch that reconstructs `new` from `old`
    /// (`zstd --patch-from=old new -o patch`). Overwrites `output`.
    static func diff(old: URL, new: URL, output: URL) async throws {
        try requireArtifact(old, role: "base (old) artifact")
        try requireArtifact(new, role: "new artifact")
        try await Shell.run("zstd", [
            "-q", "-f", "-19",
            "--long=\(windowLog)",
            "--patch-from=\(old.path)",
            new.path,
            "-o", output.path
        ])
    }

    /// Reconstruct `output` by applying `patch` to `old`
    /// (`zstd -d --patch-from=old patch -o output`). Overwrites `output`.
    /// Provided for scripting / manual verification; the runtime uses
    /// `libzstd` instead.
    static func apply(old: URL, patch: URL, output: URL) async throws {
        try requireArtifact(old, role: "base (old) artifact")
        try requireArtifact(patch, role: "patch")
        try await Shell.run("zstd", [
            "-q", "-f", "-d",
            "--long=\(windowLog)",
            "--patch-from=\(old.path)",
            patch.path,
            "-o", output.path
        ])
    }

    /// Lowercase-hex SHA-256 of a file's bytes. Pure Swift (Crypto) — no
    /// shell. Used for the manifest's `base_sha256`.
    static func sha256Hex(of url: URL) throws -> String {
        let data = try UpdaterCLISupport.readArtifact(at: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func requireArtifact(_ url: URL, role: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("swift-pwa: \(role) not found: \(url.path)")
        }
    }
}

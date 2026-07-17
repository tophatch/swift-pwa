import Crypto
import Foundation

/// Converts a 1024x1024 source PNG into platform-appropriate icon
/// containers. Best-effort: silently no-ops if the host doesn't have
/// the required tools (`sips`/`iconutil` on macOS, `convert` on Linux).
enum IconConverter {
    /// The `.icns` sizes rendered from the source PNG.
    private static let icnsSizes = [16, 32, 64, 128, 256, 512, 1024]

    /// Builds the `.icns` and returns how many distinct icon sizes it
    /// rendered from the source PNG (for the build's one-line icon report).
    ///
    /// Building the `.icns` spawns ~14 `sips` invocations plus `iconutil` —
    /// pure work that's identical as long as the source PNG (and the generation
    /// logic) don't change. When `cacheDir` is provided, the result is cached
    /// there keyed by the source PNG's content + the CLI version, so an
    /// unchanged icon on a rebuild is a single file copy instead of re-running
    /// the whole toolchain. A cache miss (or no `cacheDir`) generates as before.
    @discardableResult
    static func makeICNS(from png: URL, into icns: URL, cacheDir: URL? = nil) async throws -> Int {
        if let cached = cacheURL(for: png, in: cacheDir) {
            if FileManager.default.fileExists(atPath: cached.path) {
                // Cache hit: copy the prebuilt .icns into the bundle.
                try? FileManager.default.removeItem(at: icns)
                try FileManager.default.copyItem(at: cached, to: icns)
                return icnsSizes.count
            }
            // Miss: build once into the cache, then copy into the bundle so the
            // next build (same icon) hits.
            try await generateICNS(from: png, into: cached)
            try? FileManager.default.removeItem(at: icns)
            try FileManager.default.copyItem(at: cached, to: icns)
            return icnsSizes.count
        }
        // No usable cache — generate straight into the destination.
        try await generateICNS(from: png, into: icns)
        return icnsSizes.count
    }

    /// The cache file for this source PNG, or `nil` if caching isn't possible
    /// (no `cacheDir`, unreadable PNG, or the cache dir can't be created — all
    /// of which fall back to direct generation). Keyed on the PNG's bytes, the
    /// CLI version, and the size list, so a changed icon — or a CLI whose icon
    /// logic changed — misses and rebuilds.
    private static func cacheURL(for png: URL, in cacheDir: URL?) -> URL? {
        guard let cacheDir, let data = try? Data(contentsOf: png) else { return nil }
        var hasher = SHA256()
        hasher.update(data: data)
        hasher.update(data: Data("v\(SwiftPWAVersion.current)".utf8))
        hasher.update(data: Data(icnsSizes.map(String.init).joined(separator: ",").utf8))
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard (try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)) != nil
        else { return nil }
        return cacheDir.appendingPathComponent("icon-\(hex.prefix(32)).icns")
    }

    /// The actual `sips`/`iconutil` pipeline: render each size into a temp
    /// `.iconset`, then pack it into `icns`.
    private static func generateICNS(from png: URL, into icns: URL) async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-iconset-\(UUID().uuidString).iconset")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        for size in icnsSizes {
            let dest = tmp.appendingPathComponent("icon_\(size)x\(size).png")
            try await Shell.run("/usr/bin/env", [
                "sips", "-z", "\(size)", "\(size)", png.path, "--out", dest.path
            ])
            if size <= 512 {
                let dest2x = tmp.appendingPathComponent("icon_\(size)x\(size)@2x.png")
                try await Shell.run("/usr/bin/env", [
                    "sips", "-z", "\(size * 2)", "\(size * 2)", png.path, "--out", dest2x.path
                ])
            }
        }
        // Ensure the destination's parent exists (cache dir is pre-created; a
        // bundle Resources dir already exists — but be safe for both).
        try? FileManager.default.createDirectory(
            at: icns.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: icns)
        try await Shell.run("/usr/bin/env", ["iconutil", "-c", "icns", tmp.path, "-o", icns.path])
    }
}

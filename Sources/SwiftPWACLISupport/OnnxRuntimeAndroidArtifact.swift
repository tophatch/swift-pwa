import Crypto
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking // URLSession lives here on swift-corelibs-foundation
#endif

/// Resolves the prebuilt ONNX Runtime **Android** shared library
/// (`libonnxruntime.so`, per ABI) that `SwiftPWASegmentation` links when
/// `ai.local_onnx_runtime` is set for a `--target android` build.
///
/// On Apple the lib reaches the build through SwiftPM's `.binaryTarget`
/// (auto-downloaded + checksum-verified). Android has no binary-library
/// target, so the CLI fetches `libonnxruntime.so` itself — to a
/// content-addressed cache — and points `LIBRARY_PATH` at its directory,
/// which the child `swift build --swift-sdk <triple>` inherits and uses to
/// resolve `.linkedLibrary("onnxruntime")` (no `unsafeFlags`, which would
/// poison dependency resolution). Built + published by
/// `.github/workflows/onnxruntime-android.yml` from the same Maven artifact
/// `Scripts/vendor-onnxruntime-android.sh` vendors locally; the checksums
/// below are recorded from that publish, mirroring `LlamaLinuxArtifact`.
///
/// Unlike `LlamaLinuxArtifact` (single host arch), Android cross-compiles
/// multiple ABIs in one build, each needing its own `.so` — so resolution
/// is keyed per-ABI and called once per ABI from `AndroidBundler`'s
/// cross-compile loop, not once up front.
///
/// Resolution order (mirrors Apple's local-`Vendor/llama` escape hatch):
///   1. `SWIFT_PWA_ONNXRUNTIME_ANDROID_LIB_DIR` env — a directory containing
///      `libonnxruntime.so`. Used verbatim (CI / local dev that just fetched
///      it another way). Applies to whichever ABI is being built — only
///      useful for single-ABI builds.
///   2. `<projectRoot>/Vendor/onnxruntime-android/<abi>/libonnxruntime.so` —
///      present when `Scripts/vendor-onnxruntime-android.sh` was run locally
///      inside the swift-pwa repo.
///   3. download the pinned release asset to the cache, keyed by ABI.
enum OnnxRuntimeAndroidArtifact {
    /// Stable release asset (NOT per swift-pwa version), paralleling
    /// Apple's `onnxruntime-vendor` release. `<abi>` is substituted at
    /// runtime.
    static let urlTemplate =
        "https://github.com/tophatch/swift-pwa/releases/download/" +
        "onnxruntime-vendor-android/libonnxruntime-android-<abi>.so"

    /// SHA-256 per ABI, auto-pinned by the publish workflow. Only ABIs
    /// verified against real Android hardware (Fold7 / Tab S10+, both
    /// arm64-v8a) are published so far — see `ensureLibDir`'s error for
    /// anything else.
    static let sha256ByABI: [String: String] = [
        "arm64-v8a": "12c870ee77349d0e80e0d85eb293849ebe8f56717a81eec62b53ecb1446e7de8"
    ]

    struct ArtifactError: Error, CustomStringConvertible {
        let description: String
    }

    /// Ensure `libonnxruntime.so` for `abi` is available and return the
    /// **directory** to put on `LIBRARY_PATH`. Throws (with an actionable
    /// message) on an unpublished ABI, a download failure, or a checksum
    /// mismatch.
    static func ensureLibDir(projectRoot: URL, abi: String) async throws -> URL {
        let fm = FileManager.default

        // 1. explicit override
        if let dir = ProcessInfo.processInfo.environment["SWIFT_PWA_ONNXRUNTIME_ANDROID_LIB_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            guard fm.fileExists(atPath: url.appendingPathComponent("libonnxruntime.so").path) else {
                throw ArtifactError(
                    description: "SWIFT_PWA_ONNXRUNTIME_ANDROID_LIB_DIR=\(dir) has no libonnxruntime.so"
                )
            }
            return url
        }

        // 2. local vendoring (inside the swift-pwa repo)
        let local = projectRoot.appendingPathComponent("Vendor/onnxruntime-android/\(abi)")
        if fm.fileExists(atPath: local.appendingPathComponent("libonnxruntime.so").path) {
            return local
        }

        // 3. download the pinned release asset
        guard let want = sha256ByABI[abi] else {
            throw ArtifactError(
                description: "ai.local_onnx_runtime has no published libonnxruntime.so for ABI \(abi) yet "
                    + "(published: \(sha256ByABI.keys.sorted().joined(separator: ", "))) — run "
                    + "Scripts/vendor-onnxruntime-android.sh 1.27.0 \(abi) and set "
                    + "SWIFT_PWA_ONNXRUNTIME_ANDROID_LIB_DIR to its Vendor/onnxruntime-android/\(abi) dir, "
                    + "or drop that ABI from --android-abis."
            )
        }
        let cacheDir = cacheRoot().appendingPathComponent(abi, isDirectory: true).appendingPathComponent(
            want,
            isDirectory: true
        )
        let lib = cacheDir.appendingPathComponent("libonnxruntime.so")
        if fm.fileExists(atPath: lib.path), (try? sha256Hex(ofFileAt: lib)) == want {
            return cacheDir
        }

        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let urlString = urlTemplate.replacingOccurrences(of: "<abi>", with: abi)
        guard let url = URL(string: urlString) else {
            throw ArtifactError(description: "bad artifact URL: \(urlString)")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ArtifactError(
                description: "download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)) from \(url)"
            )
        }
        let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard got == want else {
            throw ArtifactError(
                description: "libonnxruntime.so (\(abi)) checksum mismatch (expected \(want), got \(got))"
            )
        }
        try data.write(to: lib)
        return cacheDir
    }

    // MARK: - helpers

    private static func cacheRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        let base: URL = if let xdg = env["XDG_CACHE_HOME"], !xdg.isEmpty {
            URL(fileURLWithPath: xdg)
        } else {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        }
        return base.appendingPathComponent("swift-pwa/onnxruntime-android", isDirectory: true)
    }

    private static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while case let chunk = try handle.read(upToCount: 1 << 20), let data = chunk, !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

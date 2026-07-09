import Crypto
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking // URLSession lives here on swift-corelibs-foundation
#endif

/// Resolves the prebuilt ONNX Runtime **Linux x86_64** shared library
/// (`libonnxruntime.so`, Microsoft's CPU build) that `SwiftPWASegmentation`
/// links when `ai.local_onnx_runtime` is set for a `--target linux` build.
///
/// The Linux analogue of `OnnxRuntimeAndroidArtifact` / `LlamaLinuxArtifact`.
/// Unlike llama's Linux slice (a *static* `libllama.a`), ONNX Runtime desktop
/// ships only a *shared* `.so`, so this dir goes on `LIBRARY_PATH` for the
/// link step **and** the `.so` is staged next to the app at runtime (see
/// `LinuxBundler`). Re-hosted on this repo's stable `onnxruntime-vendor-linux`
/// release from Microsoft's official archive by
/// `.github/workflows/onnxruntime-desktop.yml` (vendored locally by
/// `Scripts/vendor-onnxruntime-linux.sh`).
///
/// Resolution order (mirrors the other artifact resolvers):
///   1. `SWIFT_PWA_ONNXRUNTIME_LINUX_LIB_DIR` env — a directory containing
///      `libonnxruntime.so`. Used verbatim (CI / local dev).
///   2. `<projectRoot>/Vendor/onnxruntime-desktop/linux-x86_64/libonnxruntime.so`
///      — present after `Scripts/vendor-onnxruntime-linux.sh` inside the repo.
///   3. download the pinned release asset to a content-addressed cache.
enum OnnxRuntimeLinuxArtifact {
    static let url =
        "https://github.com/tophatch/swift-pwa/releases/download/" +
        "onnxruntime-vendor-linux/libonnxruntime-linux-x86_64.so"

    /// SHA-256 of Microsoft's ONNX Runtime 1.27.0 Linux x64 `libonnxruntime.so`
    /// (see `Scripts/vendor-onnxruntime-linux.sh`).
    static let sha256 = "4061866361d9a8d2872f5f419c5515ce35a830a0c5c77ce1723320ac0dbabfc7"

    struct ArtifactError: Error, CustomStringConvertible {
        let description: String
    }

    /// Ensure `libonnxruntime.so` is available and return the **directory**
    /// holding it (for `LIBRARY_PATH` + runtime staging). Throws on a download
    /// failure or checksum mismatch.
    static func ensureLibDir(projectRoot: URL) async throws -> URL {
        let fm = FileManager.default

        if let dir = ProcessInfo.processInfo.environment["SWIFT_PWA_ONNXRUNTIME_LINUX_LIB_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            guard fm.fileExists(atPath: url.appendingPathComponent("libonnxruntime.so").path) else {
                throw ArtifactError(
                    description: "SWIFT_PWA_ONNXRUNTIME_LINUX_LIB_DIR=\(dir) has no libonnxruntime.so"
                )
            }
            return url
        }

        let local = projectRoot.appendingPathComponent("Vendor/onnxruntime-desktop/linux-x86_64")
        if fm.fileExists(atPath: local.appendingPathComponent("libonnxruntime.so").path) {
            return local
        }

        let cacheDir = cacheRoot().appendingPathComponent(sha256, isDirectory: true)
        let lib = cacheDir.appendingPathComponent("libonnxruntime.so")
        if fm.fileExists(atPath: lib.path), (try? sha256Hex(ofFileAt: lib)) == sha256 {
            return cacheDir
        }

        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        guard let assetURL = URL(string: url) else {
            throw ArtifactError(description: "bad artifact URL: \(url)")
        }
        let (data, response) = try await URLSession.shared.data(from: assetURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ArtifactError(
                description: "download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)) from \(assetURL)"
            )
        }
        let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard got == sha256 else {
            throw ArtifactError(description: "libonnxruntime.so checksum mismatch (expected \(sha256), got \(got))")
        }
        try data.write(to: lib)
        return cacheDir
    }

    private static func cacheRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        let base: URL = if let xdg = env["XDG_CACHE_HOME"], !xdg.isEmpty {
            URL(fileURLWithPath: xdg)
        } else {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        }
        return base.appendingPathComponent("swift-pwa/onnxruntime-linux", isDirectory: true)
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

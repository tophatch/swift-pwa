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

    /// Ensure the ONNX Runtime lib is available and return the **directory**
    /// holding it — normalized so both names resolve: `libonnxruntime.so.1`
    /// (the SONAME the binary's NEEDED entry references at runtime) and a
    /// `libonnxruntime.so` symlink (what `-lonnxruntime` finds at link time).
    /// Used for `LIBRARY_PATH` (link) + `linuxdeploy --library` (runtime).
    /// Throws on a download failure or checksum mismatch.
    static func ensureLibDir(projectRoot: URL) async throws -> URL {
        let fm = FileManager.default

        if let dir = ProcessInfo.processInfo.environment["SWIFT_PWA_ONNXRUNTIME_LINUX_LIB_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            guard hasLib(url) else {
                throw ArtifactError(
                    description: "SWIFT_PWA_ONNXRUNTIME_LINUX_LIB_DIR=\(dir) has no libonnxruntime.so[.1]"
                )
            }
            try? normalizeSoname(in: url)
            return url
        }

        let local = projectRoot.appendingPathComponent("Vendor/onnxruntime-desktop/linux-x86_64")
        if hasLib(local) {
            try? normalizeSoname(in: local)
            return local
        }

        let cacheDir = cacheRoot().appendingPathComponent(sha256, isDirectory: true)
        let versioned = cacheDir.appendingPathComponent("libonnxruntime.so.1")
        if fm.fileExists(atPath: versioned.path), (try? sha256Hex(ofFileAt: versioned)) == sha256 {
            try? normalizeSoname(in: cacheDir)
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
        // Save under the SONAME name; normalizeSoname adds the `.so` symlink.
        try data.write(to: versioned)
        try? normalizeSoname(in: cacheDir)
        return cacheDir
    }

    private static func hasLib(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("libonnxruntime.so.1").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("libonnxruntime.so").path)
    }

    /// Ensure a lib dir has both `libonnxruntime.so.1` (runtime SONAME) and a
    /// `libonnxruntime.so` symlink (link-time name). Idempotent; tolerates a
    /// dir that already has one, the other, or both.
    private static func normalizeSoname(in dir: URL) throws {
        let fm = FileManager.default
        let versioned = dir.appendingPathComponent("libonnxruntime.so.1")
        let plain = dir.appendingPathComponent("libonnxruntime.so")
        if !fm.fileExists(atPath: versioned.path), fm.fileExists(atPath: plain.path) {
            // Only the plain name present (e.g. an older vendoring) — copy it
            // to the SONAME name the loader needs.
            try fm.copyItem(at: plain, to: versioned)
        }
        if !fm.fileExists(atPath: plain.path) {
            try fm.createSymbolicLink(atPath: plain.path, withDestinationPath: "libonnxruntime.so.1")
        }
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

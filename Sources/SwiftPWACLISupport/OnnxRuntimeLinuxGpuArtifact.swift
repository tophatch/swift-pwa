import Crypto
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking // URLSession lives here on swift-corelibs-foundation
#endif

/// Resolves the prebuilt ONNX Runtime **Linux x86_64 GPU (CUDA 12)** shared
/// libraries that `SwiftPWASegmentation` links when **`ai.onnx_gpu`** is set
/// for a `--target linux` build (see
/// `docs/proposals/onnx-gpu-execution-providers.md`). The GPU analogue of
/// `OnnxRuntimeLinuxArtifact`.
///
/// Unlike the CPU build (a single ~8 MB `libonnxruntime.so`), the CUDA build
/// ships the runtime plus the out-of-tree CUDA provider as **three** shared
/// libs, dlopened on demand at `CreateSession` when the CUDA EP is appended:
///   - `libonnxruntime.so.1`                — the runtime (SONAME)
///   - `libonnxruntime_providers_shared.so` — the shared-provider bridge
///   - `libonnxruntime_providers_cuda.so`   — the CUDA execution provider (~366 MB)
/// All three are staged into the AppImage. The CUDA runtime + cuDNN themselves
/// are **not** vendored — a missing/mismatched CUDA runtime makes the CUDA EP
/// fail to load, which the backend turns into a transparent CPU fallback.
///
/// Headers are identical to the CPU 1.27.0 build (CUDA uses the in-header
/// `OrtSessionOptionsAppendExecutionProvider_CUDA`, no extra header), so this
/// reuses the committed `ONNXRuntimeDesktop` module — only the libs differ.
/// Re-hosted on this repo's stable `onnxruntime-vendor-linux-gpu` release by
/// `.github/workflows/onnxruntime-desktop-gpu.yml` (vendored locally by
/// `Scripts/vendor-onnxruntime-linux-gpu.sh`).
///
/// Resolution order (mirrors `OnnxRuntimeLinuxArtifact`):
///   1. `SWIFT_PWA_ONNXRUNTIME_LINUX_GPU_LIB_DIR` env — a directory containing
///      the three libs. Used verbatim (CI / local dev).
///   2. `<projectRoot>/Vendor/onnxruntime-desktop-gpu/linux-x86_64/` — present
///      after `Scripts/vendor-onnxruntime-linux-gpu.sh` inside the repo.
///   3. download the pinned release assets to a content-addressed cache.
enum OnnxRuntimeLinuxGpuArtifact {
    static let runtimeURL =
        "https://github.com/tophatch/swift-pwa/releases/download/" +
        "onnxruntime-vendor-linux-gpu/libonnxruntime-linux-x86_64-gpu.so"
    static let providersSharedURL =
        "https://github.com/tophatch/swift-pwa/releases/download/" +
        "onnxruntime-vendor-linux-gpu/libonnxruntime_providers_shared.so"
    static let providersCudaURL =
        "https://github.com/tophatch/swift-pwa/releases/download/" +
        "onnxruntime-vendor-linux-gpu/libonnxruntime_providers_cuda.so"

    /// SHA-256 of Microsoft's ONNX Runtime 1.27.0 Linux x64 **GPU (CUDA 12)**
    /// libs (see `Scripts/vendor-onnxruntime-linux-gpu.sh`).
    static let runtimeSha256 = "3718b5be5e75d0dd09139d5ea90f7e8c4f140888187ddb61c1eb5953d0e3e32e"
    static let providersSharedSha256 = "c6a12593396095f5670160e284c35d1700b7708cf3037b7042e2a5200ccae772"
    static let providersCudaSha256 = "85e74c8144f538eba1eccb48e0cecc88f3bb41c2fd7cf01ed4bee4edd36df10a"

    /// The three lib basenames, as they must land in the resolved dir. The
    /// runtime is stored under its SONAME (`.so.1`); `normalizeSoname` adds the
    /// `libonnxruntime.so` symlink for the linker's `-lonnxruntime`.
    static let runtimeName = "libonnxruntime.so.1"
    static let providerNames = ["libonnxruntime_providers_shared.so", "libonnxruntime_providers_cuda.so"]

    struct ArtifactError: Error, CustomStringConvertible {
        let description: String
    }

    /// Ensure all three GPU libs are available and return the **directory**
    /// holding them (normalized so both `libonnxruntime.so.1` and a
    /// `libonnxruntime.so` symlink resolve). Used for `LIBRARY_PATH` (link) +
    /// `linuxdeploy --library` (runtime). Throws on download/checksum failure.
    static func ensureLibDir(projectRoot: URL) async throws -> URL {
        let fm = FileManager.default

        if let dir = ProcessInfo.processInfo.environment["SWIFT_PWA_ONNXRUNTIME_LINUX_GPU_LIB_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            guard hasAllLibs(url) else {
                throw ArtifactError(
                    description: "SWIFT_PWA_ONNXRUNTIME_LINUX_GPU_LIB_DIR=\(dir) is missing one of " +
                        "libonnxruntime.so[.1], \(providerNames.joined(separator: ", "))"
                )
            }
            try? normalizeSoname(in: url)
            return url
        }

        let local = projectRoot.appendingPathComponent("Vendor/onnxruntime-desktop-gpu/linux-x86_64")
        if hasAllLibs(local) {
            try? normalizeSoname(in: local)
            return local
        }

        // Cache key over all three checksums so a re-pin invalidates cleanly.
        let cacheDir = cacheRoot()
            .appendingPathComponent(
                "\(runtimeSha256)-\(providersSharedSha256)-\(providersCudaSha256)",
                isDirectory: true
            )
        if cachedLibsValid(cacheDir) {
            try? normalizeSoname(in: cacheDir)
            return cacheDir
        }

        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try await download(runtimeURL, to: cacheDir.appendingPathComponent(runtimeName), expecting: runtimeSha256)
        try await download(
            providersSharedURL,
            to: cacheDir.appendingPathComponent("libonnxruntime_providers_shared.so"),
            expecting: providersSharedSha256
        )
        try await download(
            providersCudaURL,
            to: cacheDir.appendingPathComponent("libonnxruntime_providers_cuda.so"),
            expecting: providersCudaSha256
        )
        try? normalizeSoname(in: cacheDir)
        return cacheDir
    }

    private static func hasAllLibs(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let hasRuntime = fm.fileExists(atPath: dir.appendingPathComponent("libonnxruntime.so.1").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("libonnxruntime.so").path)
        return hasRuntime && providerNames.allSatisfy {
            fm.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    private static func cachedLibsValid(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let runtime = dir.appendingPathComponent(runtimeName)
        guard fm.fileExists(atPath: runtime.path), (try? sha256Hex(ofFileAt: runtime)) == runtimeSha256 else {
            return false
        }
        let shared = dir.appendingPathComponent("libonnxruntime_providers_shared.so")
        let cuda = dir.appendingPathComponent("libonnxruntime_providers_cuda.so")
        return fm.fileExists(atPath: shared.path) && (try? sha256Hex(ofFileAt: shared)) == providersSharedSha256
            && fm.fileExists(atPath: cuda.path) && (try? sha256Hex(ofFileAt: cuda)) == providersCudaSha256
    }

    /// Ensure a lib dir has both `libonnxruntime.so.1` (runtime SONAME) and a
    /// `libonnxruntime.so` symlink (link-time name). Idempotent.
    private static func normalizeSoname(in dir: URL) throws {
        let fm = FileManager.default
        let versioned = dir.appendingPathComponent("libonnxruntime.so.1")
        let plain = dir.appendingPathComponent("libonnxruntime.so")
        if !fm.fileExists(atPath: versioned.path), fm.fileExists(atPath: plain.path) {
            try fm.copyItem(at: plain, to: versioned)
        }
        if !fm.fileExists(atPath: plain.path) {
            try fm.createSymbolicLink(atPath: plain.path, withDestinationPath: "libonnxruntime.so.1")
        }
    }

    private static func download(_ urlString: String, to dest: URL, expecting sha: String) async throws {
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
        guard got == sha else {
            throw ArtifactError(
                description: "\(dest.lastPathComponent) checksum mismatch (expected \(sha), got \(got))"
            )
        }
        try data.write(to: dest)
    }

    private static func cacheRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        let base: URL = if let xdg = env["XDG_CACHE_HOME"], !xdg.isEmpty {
            URL(fileURLWithPath: xdg)
        } else {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        }
        return base.appendingPathComponent("swift-pwa/onnxruntime-linux-gpu", isDirectory: true)
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

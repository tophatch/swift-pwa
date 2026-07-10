import Crypto
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking // URLSession lives here on swift-corelibs-foundation
#endif

/// Resolves the prebuilt ONNX Runtime **Windows x64 DirectML** libraries that
/// `SwiftPWASegmentation` links when **`ai.onnx_gpu`** is set for a
/// `--target windows` build (see
/// `docs/proposals/onnx-gpu-execution-providers.md`). The GPU analogue of
/// `OnnxRuntimeWindowsArtifact`.
///
/// DirectML is the cross-vendor Windows GPU path (any DX12 GPU —
/// NVIDIA/AMD/Intel) and needs no external runtime (DirectML is in-box on
/// Windows 10+; we stage the redist `DirectML.dll` anyway for a known-good
/// version). Four files:
///   - `onnxruntime.lib`                  — import lib (staged on `LIB`, link step)
///   - `onnxruntime.dll`                  — the DirectML runtime (retains the CPU EP for fallback)
///   - `onnxruntime_providers_shared.dll` — the shared-provider bridge
///   - `DirectML.dll`                     — the DirectML redist (x64-win)
/// The last three are staged next to the built `.exe` (see `WindowsBundler`).
///
/// **Version note:** the DirectML build is NuGet-only and its latest is
/// **1.24.4**, which lags the CPU/CUDA desktop build's 1.27.0. A 1.27 header
/// requests a newer `ORT_API_VERSION` than a 1.24.4 runtime provides
/// (`OrtGetApiBase()->GetApi()` returns null → crash), so this artifact links
/// against a **separate pinned 1.24.4 header set + module**
/// (`ONNXRuntimeDirectML`, committed under `Vendor/onnxruntime-directml-headers/`,
/// including `dml_provider_factory.h` for
/// `OrtSessionOptionsAppendExecutionProvider_DML`), distinct from the shared
/// 1.27 `ONNXRuntimeDesktop` set. Re-hosted on this repo's stable
/// `onnxruntime-vendor-windows-directml` release by
/// `.github/workflows/onnxruntime-desktop-gpu.yml` (vendored locally by
/// `Scripts/vendor-onnxruntime-windows-directml.sh`).
///
/// Resolution order:
///   1. `SWIFT_PWA_ONNXRUNTIME_WINDOWS_DIRECTML_LIB_DIR` env — a directory with
///      all four files. Used verbatim.
///   2. `<projectRoot>\Vendor\onnxruntime-desktop-gpu\windows-x86_64\` — present
///      after `Scripts/vendor-onnxruntime-windows-directml.sh` inside the repo.
///   3. download the pinned release assets to a content-addressed cache.
enum OnnxRuntimeWindowsDirectMLArtifact {
    static let releaseBase =
        "https://github.com/tophatch/swift-pwa/releases/download/onnxruntime-vendor-windows-directml/"

    /// (basename, sha256). The order the linker + bundler expect.
    static let files: [(name: String, sha256: String)] = [
        ("onnxruntime.lib", "281d55c95107ad75ac060569c005031baf1bb7fe1011bdc07a6bef1dee8792b5"),
        ("onnxruntime.dll", "e7eedec6a6f26dc39dc948276a75ef6d2bee3fff944d874ceed0bbd3b97bff40"),
        ("onnxruntime_providers_shared.dll", "265c8daf29637cb259cac8be9f08f2cd45f3883f0f0e4949cbfddd5b4cbec3b6"),
        ("DirectML.dll", "9c9e6d822561c6c41b90e6994b3e8857cf1d66dbfb1e0c4c799c7c89b4e92da1")
    ]

    struct ArtifactError: Error, CustomStringConvertible {
        let description: String
    }

    /// Ensure all four DirectML files are available and return the
    /// **directory** holding them (for `LIB` + runtime staging).
    static func ensureLibDir(projectRoot: URL) async throws -> URL {
        let fm = FileManager.default

        if let dir = ProcessInfo.processInfo.environment["SWIFT_PWA_ONNXRUNTIME_WINDOWS_DIRECTML_LIB_DIR"],
           !dir.isEmpty
        {
            let url = URL(fileURLWithPath: dir)
            for file in files {
                guard fm.fileExists(atPath: url.appendingPathComponent(file.name).path) else {
                    throw ArtifactError(
                        description: "SWIFT_PWA_ONNXRUNTIME_WINDOWS_DIRECTML_LIB_DIR=\(dir) has no \(file.name)"
                    )
                }
            }
            return url
        }

        let local = projectRoot.appendingPathComponent("Vendor/onnxruntime-desktop-gpu/windows-x86_64")
        if files.allSatisfy({ fm.fileExists(atPath: local.appendingPathComponent($0.name).path) }) {
            return local
        }

        // Cache key over all four checksums so a re-pin invalidates cleanly.
        let cacheKey = files.map(\.sha256).joined(separator: "-")
        let cacheDir = cacheRoot().appendingPathComponent(cacheKey, isDirectory: true)
        if files.allSatisfy({ file in
            let path = cacheDir.appendingPathComponent(file.name)
            return fm.fileExists(atPath: path.path) && (try? sha256Hex(ofFileAt: path)) == file.sha256
        }) {
            return cacheDir
        }

        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        for file in files {
            try await download(
                releaseBase + file.name,
                to: cacheDir.appendingPathComponent(file.name),
                expecting: file.sha256
            )
        }
        return cacheDir
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
        let base: URL = if let local = env["LOCALAPPDATA"], !local.isEmpty {
            URL(fileURLWithPath: local)
        } else {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local")
        }
        return base.appendingPathComponent("swift-pwa/onnxruntime-windows-directml", isDirectory: true)
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

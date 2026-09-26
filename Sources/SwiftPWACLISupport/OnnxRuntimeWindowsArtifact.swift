import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

#if canImport(FoundationNetworking)
    import FoundationNetworking // URLSession lives here on swift-corelibs-foundation
#endif

/// Resolves the prebuilt ONNX Runtime **Windows** libraries that
/// `SwiftPWASegmentation` links when `ai.local_onnx_runtime` is set for a
/// `--target windows` build — Microsoft's CPU build, for the host's
/// architecture (x64 or arm64; a Windows build never cross-compiles, so the
/// host is the target). The Windows analogue of
/// `OnnxRuntimeLinuxArtifact`, but two files: the import lib `onnxruntime.lib`
/// (staged on `LIB` for the link step, the same trick `LlamaWindowsArtifact`
/// uses) and the runtime `onnxruntime.dll` (staged next to the built `.exe` —
/// see `WindowsBundler`). Re-hosted on this repo's stable
/// `onnxruntime-vendor-windows` release by
/// `.github/workflows/onnxruntime-desktop.yml`.
///
/// Resolution order:
///   1. `SWIFT_PWA_ONNXRUNTIME_WINDOWS_LIB_DIR` env — a directory containing
///      both `onnxruntime.lib` and `onnxruntime.dll`. Used verbatim.
///   2. `<projectRoot>\Vendor\onnxruntime-desktop\windows-<arch>\` — present
///      after `ARCH=<x64|arm64> Scripts/vendor-onnxruntime-windows.sh` inside
///      the repo.
///   3. download the pinned release assets to a content-addressed cache.
enum OnnxRuntimeWindowsArtifact {
    /// The vendored ONNX Runtime version, carried in the asset names so a
    /// bump adds assets rather than replacing the bytes older swift-pwa
    /// releases pin by checksum.
    static let version = "1.29.0"
    static let releaseBase = "https://github.com/tophatch/swift-pwa/releases/download/onnxruntime-vendor-windows/"

    /// One architecture's pair: where it's vendored locally, the release asset
    /// names, and the SHA-256 of Microsoft's files (see
    /// `Scripts/vendor-onnxruntime-windows.sh`). x64 keeps the unsuffixed names
    /// it shipped under, which older swift-pwa releases pin.
    struct Pair {
        let vendorDir: String
        let libAsset: String
        let dllAsset: String
        let libSha256: String
        let dllSha256: String

        var libURL: String {
            releaseBase + libAsset
        }

        var dllURL: String {
            releaseBase + dllAsset
        }
    }

    static let x64 = Pair(
        vendorDir: "windows-x86_64",
        libAsset: "onnxruntime-\(version).lib",
        dllAsset: "onnxruntime-\(version).dll",
        libSha256: "b9fc3cd678257d88a111b0773ede4bfceaf0fe95daab4379f2b2b37348a68781",
        dllSha256: "69d8e6d3879a3b4001cdc74c8ed9ccc7e7f799a5b847059738323404519ec471"
    )

    static let arm64 = Pair(
        vendorDir: "windows-arm64",
        libAsset: "onnxruntime-\(version)-arm64.lib",
        dllAsset: "onnxruntime-\(version)-arm64.dll",
        libSha256: "9c2733702690024427ca55ccbd6792cd19f44503d8a2c04dd68b6af83225de84",
        dllSha256: "7c7df2cefd6910f50f44792e8f8f71b371bf9675f9273e70a9277eb92e4d75ed"
    )

    /// The pair for the machine this CLI runs on. Without this an arm64 host
    /// downloaded the x64 files and the link failed with `machine type x64
    /// conflicts with arm64`, which names no fix (#262).
    static var host: Pair {
        #if arch(arm64)
            arm64
        #else
            x64
        #endif
    }

    struct ArtifactError: Error, CustomStringConvertible {
        let description: String
    }

    /// Ensure both `onnxruntime.lib` and `onnxruntime.dll` are available and
    /// return the **directory** holding them (for `LIB` + runtime staging).
    static func ensureLibDir(projectRoot: URL) async throws -> URL {
        let fm = FileManager.default

        if let dir = ProcessInfo.processInfo.environment["SWIFT_PWA_ONNXRUNTIME_WINDOWS_LIB_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            for file in ["onnxruntime.lib", "onnxruntime.dll"] {
                guard fm.fileExists(atPath: url.appendingPathComponent(file).path) else {
                    throw ArtifactError(description: "SWIFT_PWA_ONNXRUNTIME_WINDOWS_LIB_DIR=\(dir) has no \(file)")
                }
            }
            return url
        }

        let pair = host
        let local = projectRoot.appendingPathComponent("Vendor/onnxruntime-desktop/\(pair.vendorDir)")
        if fm.fileExists(atPath: local.appendingPathComponent("onnxruntime.lib").path),
           fm.fileExists(atPath: local.appendingPathComponent("onnxruntime.dll").path)
        {
            return local
        }

        // Cache key over both checksums, so a re-pin invalidates cleanly and
        // the two architectures never share a directory.
        let cacheDir = cacheRoot().appendingPathComponent("\(pair.libSha256)-\(pair.dllSha256)", isDirectory: true)
        let lib = cacheDir.appendingPathComponent("onnxruntime.lib")
        let dll = cacheDir.appendingPathComponent("onnxruntime.dll")
        if fm.fileExists(atPath: lib.path), (try? sha256Hex(ofFileAt: lib)) == pair.libSha256,
           fm.fileExists(atPath: dll.path), (try? sha256Hex(ofFileAt: dll)) == pair.dllSha256
        {
            return cacheDir
        }

        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try await download(pair.libURL, to: lib, expecting: pair.libSha256)
        try await download(pair.dllURL, to: dll, expecting: pair.dllSha256)
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
        return base.appendingPathComponent("swift-pwa/onnxruntime-windows", isDirectory: true)
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

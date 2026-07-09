import Crypto
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking // URLSession lives here on swift-corelibs-foundation
#endif

/// Resolves the prebuilt ONNX Runtime **Windows x64** libraries that
/// `SwiftPWASegmentation` links when `ai.local_onnx_runtime` is set for a
/// `--target windows` build — Microsoft's CPU build. The Windows analogue of
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
///   2. `<projectRoot>\Vendor\onnxruntime-desktop\windows-x86_64\` — present
///      after `Scripts/vendor-onnxruntime-windows.sh` inside the repo.
///   3. download the pinned release assets to a content-addressed cache.
enum OnnxRuntimeWindowsArtifact {
    static let libURL =
        "https://github.com/tophatch/swift-pwa/releases/download/onnxruntime-vendor-windows/onnxruntime.lib"
    static let dllURL =
        "https://github.com/tophatch/swift-pwa/releases/download/onnxruntime-vendor-windows/onnxruntime.dll"

    /// SHA-256 of Microsoft's ONNX Runtime 1.27.0 Windows x64 files (see
    /// `Scripts/vendor-onnxruntime-windows.sh`).
    static let libSha256 = "b9fc3cd678257d88a111b0773ede4bfceaf0fe95daab4379f2b2b37348a68781"
    static let dllSha256 = "fd6dd0a8b1f5562d642abdcbd36bc54251482d2ebaa3f4f88669bfdad92e7525"

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

        let local = projectRoot.appendingPathComponent("Vendor/onnxruntime-desktop/windows-x86_64")
        if fm.fileExists(atPath: local.appendingPathComponent("onnxruntime.lib").path),
           fm.fileExists(atPath: local.appendingPathComponent("onnxruntime.dll").path)
        {
            return local
        }

        // Cache key over both checksums so a re-pin invalidates cleanly.
        let cacheDir = cacheRoot().appendingPathComponent("\(libSha256)-\(dllSha256)", isDirectory: true)
        let lib = cacheDir.appendingPathComponent("onnxruntime.lib")
        let dll = cacheDir.appendingPathComponent("onnxruntime.dll")
        if fm.fileExists(atPath: lib.path), (try? sha256Hex(ofFileAt: lib)) == libSha256,
           fm.fileExists(atPath: dll.path), (try? sha256Hex(ofFileAt: dll)) == dllSha256
        {
            return cacheDir
        }

        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try await download(libURL, to: lib, expecting: libSha256)
        try await download(dllURL, to: dll, expecting: dllSha256)
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

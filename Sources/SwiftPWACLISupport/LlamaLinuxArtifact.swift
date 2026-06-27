import Crypto
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking // URLSession lives here on swift-corelibs-foundation
#endif

/// Resolves the prebuilt llama.cpp **Linux** static lib (`libllama.a`, Vulkan
/// GPU backend) that `SwiftPWALlama` links when `ai.local_llama` is set for a
/// `--target linux` build.
///
/// On Apple the lib reaches the build through SwiftPM's `.binaryTarget`
/// (auto-downloaded + checksum-verified). Linux has no binary-library target, so
/// the CLI fetches `libllama.a` itself — to a content-addressed cache — and
/// points `LIBRARY_PATH` at its directory, which the child `swift build`
/// inherits and uses to resolve `.linkedLibrary("llama")` (no `unsafeFlags`,
/// which would poison dependency resolution). Built + published by
/// `.github/workflows/llama-linux.yml` from the same pinned llama.cpp commit as
/// the xcframework; `sha256_x86_64` below is auto-pinned by that workflow.
///
/// Resolution order (mirrors Apple's local-`Vendor/llama` escape hatch):
///   1. `SWIFT_PWA_LLAMA_LINUX_LIB_DIR` env — a directory containing
///      `libllama.a`. Used verbatim (CI / local dev that just built the lib).
///   2. `./Vendor/llama-linux/libllama.a` relative to cwd — present when
///      building from inside the swift-pwa repo after `build-llama-linux.sh`.
///   3. download the pinned release asset to the cache.
enum LlamaLinuxArtifact {
    /// Stable release asset (NOT per swift-pwa version), paralleling Apple's
    /// `llama-vendor` release. `<arch>` is substituted at runtime.
    static let urlTemplate =
        "https://github.com/tophatch/swift-pwa/releases/download/" +
        "llama-vendor-linux-<arch>/libllama-linux-<arch>.a"

    /// SHA-256 of the x86_64 `libllama.a`. Auto-pinned by the publish workflow;
    /// the all-zero placeholder fails closed until the first publish runs.
    static let sha256_x86_64 = "0000000000000000000000000000000000000000000000000000000000000000"

    struct ArtifactError: Error, CustomStringConvertible {
        let description: String
    }

    /// Ensure `libllama.a` is available and return the **directory** to put on
    /// `LIBRARY_PATH`. Throws (with an actionable message) on an unsupported
    /// arch, a download failure, or a checksum mismatch.
    static func ensureLibDir(projectRoot: URL) async throws -> URL {
        let fm = FileManager.default

        // 1. explicit override
        if let dir = ProcessInfo.processInfo.environment["SWIFT_PWA_LLAMA_LINUX_LIB_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            guard fm.fileExists(atPath: url.appendingPathComponent("libllama.a").path) else {
                throw ArtifactError(
                    description: "SWIFT_PWA_LLAMA_LINUX_LIB_DIR=\(dir) has no libllama.a"
                )
            }
            return url
        }

        // 2. local build (inside the swift-pwa repo)
        let local = projectRoot.appendingPathComponent("Vendor/llama-linux")
        if fm.fileExists(atPath: local.appendingPathComponent("libllama.a").path) {
            return local
        }

        // 3. download the pinned release asset
        let arch = currentArch()
        guard arch == "x86_64", sha256_x86_64 != String(repeating: "0", count: 64) else {
            throw ArtifactError(
                description: arch == "x86_64"
                    ? "no pinned libllama.a checksum yet — run the llama-linux publish workflow, "
                    + "or build locally with Scripts/build-llama-linux.sh and set "
                    + "SWIFT_PWA_LLAMA_LINUX_LIB_DIR to its Vendor/llama-linux dir"
                    : "the llama.cpp Linux backend is x86_64-only for now (host arch: \(arch))"
            )
        }
        let want = sha256_x86_64
        let cacheDir = cacheRoot().appendingPathComponent(want, isDirectory: true)
        let lib = cacheDir.appendingPathComponent("libllama.a")
        if fm.fileExists(atPath: lib.path), (try? sha256Hex(ofFileAt: lib)) == want {
            return cacheDir
        }

        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let urlString = urlTemplate.replacingOccurrences(of: "<arch>", with: arch)
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
            throw ArtifactError(description: "libllama.a checksum mismatch (expected \(want), got \(got))")
        }
        try data.write(to: lib)
        return cacheDir
    }

    // MARK: - helpers

    private static func currentArch() -> String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw -> String in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
    }

    private static func cacheRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        let base: URL = if let xdg = env["XDG_CACHE_HOME"], !xdg.isEmpty {
            URL(fileURLWithPath: xdg)
        } else {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        }
        return base.appendingPathComponent("swift-pwa/llama-linux", isDirectory: true)
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

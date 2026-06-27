import Crypto
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking // URLSession lives here on swift-corelibs-foundation
#endif

/// Resolves the prebuilt llama.cpp **Windows** static lib (`llama.lib`, Vulkan
/// GPU backend) that `SwiftPWALlama` links when `ai.local_llama` is set for a
/// `--target windows` build.
///
/// The Windows analogue of `LlamaLinuxArtifact`: there's no binary-library
/// target off Apple, so the CLI fetches `llama.lib` itself — to a
/// content-addressed cache — and points `LIB` at its directory, which the child
/// `swift build` inherits and uses to resolve `.linkedLibrary("llama")` (no
/// `unsafeFlags`, which would poison dependency resolution). `LIB` is the
/// MSVC-linker search-path env var, the Windows counterpart to Linux's
/// `LIBRARY_PATH` — the same trick `CWebView2Shim` already relies on. Built +
/// published by `.github/workflows/llama-windows.yml` from the same pinned
/// llama.cpp commit as the Linux lib + the Apple xcframework; `sha256_x64` below
/// is auto-pinned by that workflow.
///
/// Resolution order (mirrors the Linux escape hatch):
///   1. `SWIFT_PWA_LLAMA_WINDOWS_LIB_DIR` env — a directory containing
///      `llama.lib`. Used verbatim (CI / local dev that just built the lib).
///   2. `.\Vendor\llama-windows\llama.lib` relative to the project root —
///      present when building from inside the swift-pwa repo after
///      `build-llama-windows.ps1`.
///   3. download the pinned release asset to the cache.
enum LlamaWindowsArtifact {
    /// Stable release asset (NOT per swift-pwa version), paralleling Apple's
    /// `llama-vendor` and Linux's `llama-vendor-linux-<arch>` releases. `<arch>`
    /// is substituted at runtime.
    static let urlTemplate =
        "https://github.com/tophatch/swift-pwa/releases/download/" +
        "llama-vendor-windows-<arch>/llama-windows-<arch>.lib"

    /// SHA-256 of the x64 `llama.lib`. Auto-pinned by the publish workflow; the
    /// all-zero placeholder fails closed until the first publish runs.
    static let sha256_x64 = "4a6ff29e879e92ecf0966cae8f15df5bb743ba13168c7ddd1aa1cae9bd81130e"

    struct ArtifactError: Error, CustomStringConvertible {
        let description: String
    }

    /// Ensure `llama.lib` is available and return the **directory** to put on
    /// `LIB`. Throws (with an actionable message) on an unsupported arch, a
    /// download failure, or a checksum mismatch.
    static func ensureLibDir(projectRoot: URL) async throws -> URL {
        let fm = FileManager.default

        // 1. explicit override
        if let dir = ProcessInfo.processInfo.environment["SWIFT_PWA_LLAMA_WINDOWS_LIB_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            guard fm.fileExists(atPath: url.appendingPathComponent("llama.lib").path) else {
                throw ArtifactError(
                    description: "SWIFT_PWA_LLAMA_WINDOWS_LIB_DIR=\(dir) has no llama.lib"
                )
            }
            return url
        }

        // 2. local build (inside the swift-pwa repo)
        let local = projectRoot.appendingPathComponent("Vendor/llama-windows")
        if fm.fileExists(atPath: local.appendingPathComponent("llama.lib").path) {
            return local
        }

        // 3. download the pinned release asset
        let arch = currentArch()
        guard arch == "x64", sha256_x64 != String(repeating: "0", count: 64) else {
            throw ArtifactError(
                description: arch == "x64"
                    ? "no pinned llama.lib checksum yet — run the llama-windows publish workflow, "
                    + "or build locally with Scripts\\build-llama-windows.ps1 and set "
                    + "SWIFT_PWA_LLAMA_WINDOWS_LIB_DIR to its Vendor\\llama-windows dir"
                    : "the llama.cpp Windows backend is x64-only for now (host arch: \(arch))"
            )
        }
        let want = sha256_x64
        let cacheDir = cacheRoot().appendingPathComponent(want, isDirectory: true)
        let lib = cacheDir.appendingPathComponent("llama.lib")
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
            throw ArtifactError(description: "llama.lib checksum mismatch (expected \(want), got \(got))")
        }
        try data.write(to: lib)
        return cacheDir
    }

    // MARK: - helpers

    private static func currentArch() -> String {
        // Compile-time arch — the CLI runs natively on its build host, so this is
        // the host arch, and it's portable (no `uname`, absent on Windows). The
        // token matches the `windows` arch vocabulary (x64 / arm64), not the
        // Linux `x86_64` / `aarch64`.
        #if arch(x86_64)
            return "x64"
        #elseif arch(arm64)
            return "arm64"
        #else
            return "unknown"
        #endif
    }

    private static func cacheRoot() -> URL {
        // %LOCALAPPDATA%\swift-pwa\llama-windows on Windows; falls back to
        // ~/.cache off-Windows (this file compiles everywhere, like its Linux
        // sibling — only the .windows build path actually calls it).
        let env = ProcessInfo.processInfo.environment
        let base: URL = if let local = env["LOCALAPPDATA"], !local.isEmpty {
            URL(fileURLWithPath: local)
        } else if let xdg = env["XDG_CACHE_HOME"], !xdg.isEmpty {
            URL(fileURLWithPath: xdg)
        } else {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        }
        return base.appendingPathComponent("swift-pwa/llama-windows", isDirectory: true)
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

import ArgumentParser
import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Update the `swift-pwa` CLI binary in place to the latest (or a pinned)
/// release.
///
/// The motivating papercut: hand-updating the binary by `cp`-ing a new
/// build over the old one gets the process `Killed: 9` on macOS — `cp`
/// reuses the inode, and the kernel had a code-signing validation cached
/// against that path/inode, so the adhoc signature of the new bytes no
/// longer matches and it SIGKILLs on first run. It reads exactly like a
/// corrupt download when it isn't.
///
/// This sidesteps the trap two ways: it runs the downloaded binary's
/// `--version` from a *fresh* temp path first (proving it's neither
/// corrupt nor the wrong version — and not hitting the cache, since it's a
/// new path), then installs it with an atomic `rename(2)` onto the CLI's
/// own resolved path. `rename` gives the destination the temp file's fresh
/// inode, so there's no stale code-signing cache to trip over.
struct SelfUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "self-update",
        abstract: "Update the swift-pwa CLI binary in place to the latest release.",
        discussion: """
        Resolves the latest GitHub release (or a pinned --version), downloads the asset for \
        this OS/arch, verifies it reports the expected version, then installs it with an atomic \
        rename onto this binary's own path. On macOS this avoids the stale-code-signing-cache \
        SIGKILL that an in-place overwrite (cp) hits. Homebrew installs should use `brew upgrade \
        swift-pwa` instead; Windows can't replace a running .exe, so it prints manual steps.
        """
    )

    @Option(help: "Install a specific version (e.g. v0.6.1 or 0.6.1) instead of the latest release.")
    var version: String?

    @Flag(help: "Reinstall even when already on the target version.")
    var force: Bool = false

    private static let repo = "tophatch/swift-pwa"

    func run() async throws {
        let current = SwiftPWAVersion.current

        #if os(Windows)
            throw ValidationError(Self.windowsGuidance(current: current))
        #else
            guard let asset = Self.hostAsset() else {
                throw ValidationError(
                    "self-update: no prebuilt binary is published for this OS/arch. "
                        + "Build from source, or install via a package manager."
                )
            }
            guard let exePath = Self.executablePath() else {
                throw ValidationError(
                    "self-update: couldn't resolve this binary's own path. Download \(asset) from "
                        + "https://github.com/\(Self.repo)/releases and replace it manually."
                )
            }

            let tag = try await Self.resolveTag(requested: version)
            let targetVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if targetVersion == current, !force {
                print("swift-pwa is already on v\(current) (\(tag)). Pass --force to reinstall.")
                return
            }

            // The install dir has to be writable to stage the temp file
            // and rename over the existing binary. Catch the common
            // "installed under /usr/local or /opt" case before downloading.
            let dir = (exePath as NSString).deletingLastPathComponent
            guard FileManager.default.isWritableFile(atPath: dir) else {
                throw ValidationError(
                    "self-update: \(dir) isn't writable. Re-run with sudo, or move swift-pwa somewhere you own. "
                        + "(Installed via Homebrew? Use `brew upgrade swift-pwa` instead.)"
                )
            }

            print("Updating swift-pwa: v\(current) → \(tag) (\(asset))")
            let tmp = "\(dir)/.swift-pwa-update-\(ProcessInfo.processInfo.processIdentifier)"
            defer { try? FileManager.default.removeItem(atPath: tmp) }

            let url = "https://github.com/\(Self.repo)/releases/download/\(tag)/\(asset)"
            do {
                try await Shell.run("curl", ["-fSL", url, "-o", tmp])
            } catch {
                throw ValidationError(
                    "self-update: download failed from \(url). Check that \(tag) exists and you have network access."
                )
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp)

            // Integrity + sanity: run the freshly-downloaded binary from its
            // temp path (a new path, so no stale code-signing cache) and
            // confirm it reports the version we asked for. A corrupt or
            // wrong-arch download fails here, before we touch the installed
            // CLI.
            let reported = await (try? Shell.capture(tmp, ["--version"], timeout: 30))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let reported, reported.contains(targetVersion) else {
                throw ValidationError(
                    "self-update: the downloaded binary didn't report v\(targetVersion) "
                        + "(got: \(reported.map { "\"\($0)\"" } ?? "no output")). "
                        + "Leaving the installed CLI untouched."
                )
            }

            // Atomic install. rename(2) is atomic on the same filesystem and
            // gives the destination the temp file's fresh inode — which is
            // what dodges the macOS SIGKILL an in-place overwrite would hit.
            if rename(tmp, exePath) != 0 {
                let err = errno
                if err == EACCES || err == EPERM {
                    throw ValidationError(
                        "self-update: permission denied installing onto \(exePath). Re-run with sudo."
                    )
                }
                throw ValidationError("self-update: failed to install onto \(exePath) (errno \(err)).")
            }
            print("Updated swift-pwa to \(tag). 🎉")
        #endif
    }

    // MARK: - Helpers

    /// The release asset name for the host OS/arch. `nil` when no prebuilt
    /// binary is published for this combination (e.g. Linux arm64).
    static func hostAsset() -> String? {
        #if os(macOS)
            #if arch(arm64)
                return "swift-pwa-macos-arm64"
            #else
                return "swift-pwa-macos-x86_64"
            #endif
        #elseif os(Linux)
            #if arch(x86_64)
                return "swift-pwa-linux-x86_64"
            #else
                return nil
            #endif
        #elseif os(Windows)
            return "swift-pwa-windows-x86_64.exe"
        #else
            return nil
        #endif
    }

    /// Absolute, symlink-resolved path to the running binary. `nil` on
    /// platforms where we don't resolve it (Windows).
    static func executablePath() -> String? {
        #if canImport(Darwin)
            var size: UInt32 = 0
            _ = _NSGetExecutablePath(nil, &size)
            var buffer = [CChar](repeating: 0, count: Int(size))
            guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
            let raw = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            // Canonicalize so we rename onto the real file, not a `..`-laden
            // or symlinked path.
            if let resolved = realpath(raw, nil) {
                defer { free(resolved) }
                return String(cString: resolved)
            }
            return raw
        #elseif canImport(Glibc)
            // /proc/self/exe is already a canonical absolute path.
            return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        #else
            return nil
        #endif
    }

    /// Resolve the tag to install: an explicit `--version` (normalised to a
    /// leading `v`), or the latest release via the GitHub API.
    static func resolveTag(requested: String?) async throws -> String {
        if let requested, !requested.isEmpty {
            return requested.hasPrefix("v") ? requested : "v\(requested)"
        }
        let json = try await Shell.capture(
            "curl",
            [
                "-fsSL",
                "-H",
                "Accept: application/vnd.github+json",
                "https://api.github.com/repos/\(repo)/releases/latest"
            ],
            timeout: 30
        )
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String
        else {
            throw ValidationError(
                "self-update: couldn't determine the latest release from the GitHub API. "
                    + "Pass --version explicitly (e.g. --version v\(SwiftPWAVersion.current))."
            )
        }
        return tag
    }

    static func windowsGuidance(current: String) -> String {
        """
        self-update can't replace a running .exe on Windows (the file is locked while it runs).
        To update from v\(current): download swift-pwa-windows-x86_64.exe from
        https://github.com/\(repo)/releases/latest and replace your swift-pwa.exe with it.
        """
    }
}

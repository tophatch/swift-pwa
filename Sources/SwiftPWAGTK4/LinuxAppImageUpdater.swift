#if os(Linux)
    import Crypto
    import Foundation
    import Glibc
    import SwiftPWACore

    // NOTE: This file is duplicated verbatim in Sources/SwiftPWAGTK4/. The
    // GTK3 and GTK4 backends ship identical AppImage update logic — the
    // updater touches no GTK / WebKit symbols, so the only reason for the
    // duplication is that the two backends are separate Swift targets in
    // Package.swift (selected via `SWIFT_PWA_GTK4`). Keep the two copies in
    // sync; if you change one, mirror the change to the other.

    /// `Updater` for Linux AppImage distributions.
    ///
    /// Detects the running AppImage via the `APPIMAGE` environment
    /// variable that the AppImage runtime sets when launching the
    /// embedded ELF. `download` fetches the new AppImage, verifies its
    /// Ed25519 signature, and stages it under `XDG_CACHE_HOME`.
    /// `installAndRelaunch` atomically renames the staged file onto the
    /// running AppImage's path, spawns the (now-updated) AppImage as a
    /// detached child via `setsid`, and exits.
    ///
    /// **Why atomic-rename works.** Linux `rename(2)` is atomic within a
    /// filesystem and replaces the destination. The currently-running
    /// process keeps its mmap of the old inode (the kernel won't reclaim
    /// it until the process exits), so the running AppImage continues
    /// to function until we exit; new launches resolve the path to the
    /// new inode and pick up the new bundle. If the staging directory is
    /// on a different filesystem from the AppImage (`EXDEV`), the
    /// updater falls back to `copy → rename` via a temp file in the
    /// destination directory so the final swap is still atomic.
    ///
    /// **First-cut limitations** (each tracked in
    /// `docs/linux-setup.md` "Known limitations"):
    ///
    /// - Only the in-place strategy is implemented. `pwa.json`'s
    ///   `updater.linux.appimage_strategy = "side_by_side"` is reserved
    ///   for a future iteration that writes the new AppImage alongside
    ///   the old one and updates a `~/.local/bin` symlink instead of
    ///   replacing the file in place.
    public final class LinuxAppImageUpdater: Updater, @unchecked Sendable {
        private let endpoint: URL
        private let publicKey: String?
        private let currentVersion: String
        private let target: String
        private let urlSession: URLSession
        private let stagingRoot: URL
        private let appImagePathOverride: URL?

        private let lock = NSLock()
        private var stagedArtifactPath: URL?
        private var stagedInfo: UpdateInfo?

        /// - Parameters:
        ///   - endpoint: URL of the JSON manifest. May contain
        ///     `{{target}}` and `{{current_version}}` placeholders;
        ///     they are substituted before the request is made.
        ///   - publicKey: Base64 of the 32-byte raw Ed25519 public key.
        ///     Required — the runtime refuses to install an artifact
        ///     without verifying it (an unsigned drop-in could ship
        ///     hostile code as easily as the right one).
        ///   - currentVersion: Version string the running build
        ///     identifies as. Defaults to the value of the
        ///     `APPIMAGE_VERSION` environment variable (set by the
        ///     AppImage runtime when the bundle's `.desktop` file has
        ///     `X-AppImage-Version`), falling back to `"0.0.0"`.
        ///   - target: Manifest target key (e.g. `linux-x86_64-appimage`).
        ///     Defaults to `UpdaterTarget.current(packageFormat: "appimage")`.
        ///   - urlSession: Override for tests. Defaults to `.shared`.
        ///   - stagingRoot: Where to stage downloaded AppImages.
        ///     Defaults to `${XDG_CACHE_HOME:-$HOME/.cache}/<bundle-id>/SwiftPWAUpdates`.
        ///   - appImagePath: Override for the running AppImage's path.
        ///     Defaults to the value of the `APPIMAGE` environment
        ///     variable. Tests pass an explicit URL so they don't have
        ///     to spoof a real AppImage launch.
        public init(
            endpoint: URL,
            publicKey: String?,
            currentVersion: String? = nil,
            target: String? = nil,
            urlSession: URLSession = .shared,
            stagingRoot: URL? = nil,
            appImagePath: URL? = nil
        ) {
            self.endpoint = endpoint
            self.publicKey = publicKey
            self.currentVersion = currentVersion
                ?? ProcessInfo.processInfo.environment["APPIMAGE_VERSION"]
                ?? "0.0.0"
            self.target = target ?? UpdaterTarget.current(packageFormat: "appimage")
            self.urlSession = urlSession
            self.stagingRoot = stagingRoot ?? Self.defaultStagingRoot()
            appImagePathOverride = appImagePath
        }

        // MARK: - check

        public func check() async throws -> UpdateInfo? {
            let url = expandPlaceholders(endpoint)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await urlSession.data(from: url)
            } catch {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "manifest fetch failed: \(error.localizedDescription)"
                )
            }
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "manifest fetch returned HTTP \(http.statusCode)"
                )
            }
            let manifest: UpdateManifest
            do {
                manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            } catch {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "manifest decode failed: \(error)"
                )
            }
            guard let info = manifest.updateInfo(for: target, currentVersion: currentVersion) else {
                return nil
            }
            guard UpdaterVersion.isNewer(info.version, than: currentVersion) else {
                return nil
            }
            return info
        }

        // MARK: - download

        public func download(_ info: UpdateInfo) -> AsyncThrowingStream<UpdaterEvent, any Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let staged = try await self.stage(info: info) { event in
                            continuation.yield(event)
                        }
                        self.lock.withLock {
                            self.stagedArtifactPath = staged
                            self.stagedInfo = info
                        }
                        continuation.yield(.readyToInstall)
                        continuation.finish()
                    } catch let bridge as BridgeError {
                        continuation.finish(throwing: bridge)
                    } catch {
                        continuation.finish(throwing: BridgeError(
                            code: BridgeError.handler,
                            message: "download failed: \(error)"
                        ))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        /// Download → verify → chmod. Returns the staged AppImage URL.
        /// Streams `downloadProgress` frames at the granularity of
        /// `URLSessionDownloadDelegate.didWriteData`, so progress
        /// indicators in the UI tick smoothly through a multi-MB
        /// AppImage rather than jumping 0→100% on completion.
        private func stage(
            info: UpdateInfo,
            yield: @escaping @Sendable (UpdaterEvent) -> Void
        ) async throws -> URL {
            let dir = try ensureVersionStagingDir(version: info.version)
            let staged = dir.appendingPathComponent("update.AppImage")

            _ = try await UpdaterDownload.download(
                from: info.downloadURL,
                to: staged,
                urlSession: urlSession,
                onProgress: { bytes, total in
                    yield(.downloadProgress(bytesDownloaded: bytes, contentLength: total))
                }
            )

            let bytesData = try Data(contentsOf: staged)
            try verifyEd25519(data: bytesData, signature: info.signature)

            // AppImages must be executable to launch. The temp file from
            // URLSession is 0644; mark it +x before staging so the
            // atomic rename in installAndRelaunch produces a runnable
            // file in one shot.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: staged.path
            )

            return staged
        }

        // MARK: - installAndRelaunch

        public func installAndRelaunch() async throws {
            let staged = lock.withLock { stagedArtifactPath }
            guard let staged else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "no staged update — call updater.run (or updater.download) first"
                )
            }
            guard let installPath = currentAppImagePath() else {
                // Likely running from `swift run` / `.build/...` rather
                // than a real AppImage; we have no path to swap onto.
                // Tell the caller exactly what's wrong rather than
                // silently no-op.
                throw BridgeError(
                    code: BridgeError.handler,
                    message: """
                    installAndRelaunch could not detect the running AppImage path. \
                    The AppImage runtime sets the APPIMAGE environment variable when \
                    launching the embedded ELF; the env var is unset, so this process \
                    is almost certainly not running from an AppImage. Bundle with \
                    `swift run swift-pwa build --target linux` and run from the \
                    resulting `.AppImage` to exercise auto-updates.
                    """
                )
            }
            try atomicReplace(at: installPath, with: staged)

            // Launch the (now-updated) AppImage detached via `setsid` so
            // the new process keeps running after we exit. Redirecting
            // stdio to /dev/null severs the controlling terminal, so a
            // user running the AppImage from a shell doesn't see the
            // new process attached to their session.
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            let escaped = Self.escapeShell(installPath.path)
            proc.arguments = [
                "-c",
                "setsid \(escaped) </dev/null >/dev/null 2>&1 &"
            ]
            try proc.run()
            proc.waitUntilExit()

            // Hand off to the freshly-spawned AppImage. Calling exit(0)
            // rather than routing through `AppContext.quit` mirrors the
            // macOS implementation — the WebView is going to be torn
            // down with the process, and the bridge's reply frame is
            // academic. Plumbing `quit` so JS sees a clean reply before
            // the swap is a future iteration.
            exit(0)
        }

        // MARK: - helpers (internal so tests can exercise them directly)

        /// Resolve the currently-running AppImage's path. Returns the
        /// constructor override if set, otherwise the value of the
        /// `APPIMAGE` environment variable, otherwise `nil`.
        func currentAppImagePath() -> URL? {
            if let override = appImagePathOverride { return override }
            if let env = ProcessInfo.processInfo.environment["APPIMAGE"], !env.isEmpty {
                return URL(fileURLWithPath: env)
            }
            return nil
        }

        /// Atomically replace the file at `target` with `source`. Same
        /// filesystem → single `rename(2)`. Cross-filesystem (`EXDEV`) →
        /// copy `source` to a temp file alongside `target`, then
        /// `rename(2)` the temp onto `target`.
        func atomicReplace(at target: URL, with source: URL) throws {
            if rename(source.path, target.path) == 0 { return }
            let savedErrno = errno
            if savedErrno != EXDEV {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: """
                    atomic rename onto \(target.path) failed: \
                    \(String(cString: strerror(savedErrno)))
                    """
                )
            }
            // Cross-filesystem fallback: copy to a temp file in the
            // destination directory so the trailing rename is on the
            // same filesystem as the target.
            let parent = target.deletingLastPathComponent()
            let tempURL = parent.appendingPathComponent(
                ".\(target.lastPathComponent).swiftpwa-update-\(UUID().uuidString)"
            )
            try? FileManager.default.removeItem(at: tempURL)
            try FileManager.default.copyItem(at: source, to: tempURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tempURL.path
            )
            if rename(tempURL.path, target.path) != 0 {
                let e = errno
                try? FileManager.default.removeItem(at: tempURL)
                throw BridgeError(
                    code: BridgeError.handler,
                    message: """
                    cross-filesystem rename onto \(target.path) failed: \
                    \(String(cString: strerror(e)))
                    """
                )
            }
            // Clean up the original staged file on the source fs so we
            // don't leave a stale copy behind.
            try? FileManager.default.removeItem(at: source)
        }

        /// Verify an Ed25519 signature over `data` against the configured
        /// public key. Both the public-key and signature inputs accept
        /// either base64 of the raw bytes (32 / 64 respectively) or
        /// minisign-format file contents (the two-line `untrusted
        /// comment: …\n<base64>` shape) — see `Minisign` for the wire
        /// shape. Throws a bridge error with a clear message on every
        /// failure mode (missing key, malformed key / signature,
        /// signature mismatch).
        func verifyEd25519(data: Data, signature: String) throws {
            guard let publicKey else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "no public key configured — pass one to LinuxAppImageUpdater(publicKey:)"
                )
            }
            let pubKeyBytes = try resolveEd25519PublicKey(publicKey)
            let sigBytes = try resolveEd25519Signature(signature)
            let key: Curve25519.Signing.PublicKey
            do {
                key = try Curve25519.Signing.PublicKey(rawRepresentation: pubKeyBytes)
            } catch {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "invalid Ed25519 public key: \(error)"
                )
            }
            guard key.isValidSignature(sigBytes, for: data) else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "signature verification failed"
                )
            }
        }

        private func expandPlaceholders(_ url: URL) -> URL {
            let raw = url.absoluteString
                .replacingOccurrences(of: "{{target}}", with: target)
                .replacingOccurrences(of: "{{current_version}}", with: currentVersion)
            return URL(string: raw) ?? url
        }

        private func ensureVersionStagingDir(version: String) throws -> URL {
            let dir = stagingRoot.appendingPathComponent(version, isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }

        private static func defaultStagingRoot() -> URL {
            let env = ProcessInfo.processInfo.environment
            let base = if let xdg = env["XDG_CACHE_HOME"], !xdg.isEmpty {
                URL(fileURLWithPath: xdg)
            } else if let home = env["HOME"], !home.isEmpty {
                URL(fileURLWithPath: home)
                    .appendingPathComponent(".cache", isDirectory: true)
            } else {
                URL(fileURLWithPath: NSTemporaryDirectory())
            }
            let appID = Bundle.main.bundleIdentifier ?? "swift-pwa"
            return base
                .appendingPathComponent(appID, isDirectory: true)
                .appendingPathComponent("SwiftPWAUpdates", isDirectory: true)
        }

        private static func escapeShell(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }
#endif

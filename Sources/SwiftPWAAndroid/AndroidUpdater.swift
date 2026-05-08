#if os(Android)
    import Crypto
    import Foundation
    import SwiftPWACore

    #if canImport(FoundationNetworking)
        // swift-corelibs-foundation on Android ships URLSession via a
        // separate module, same as on Linux/Windows. Without this
        // import the URLSession references below are unresolved.
        import FoundationNetworking
    #endif

    /// `Updater` for Android APK distributions.
    ///
    /// Fetches the JSON manifest, downloads the new `.apk`, verifies its
    /// Ed25519 signature against the configured public key, and stages
    /// it under the app's cache directory. `installAndRelaunch` hands
    /// the staged file to the system installer through
    /// `PackageInstaller.Session` (Kotlin-side, behind the RPC bridge);
    /// the user sees the standard system "Install update?" prompt and
    /// confirms manually.
    ///
    /// **Permissions.** Self-installing APKs requires the
    /// `REQUEST_INSTALL_PACKAGES` permission in the manifest plus the
    /// per-app "Install unknown apps" toggle on API 26+. The Gradle
    /// scaffold's `AndroidManifest.xml` declares the permission; the
    /// per-app toggle is a one-time user action that swift-pwa cannot
    /// flip on the user's behalf. If the toggle is off, the system
    /// installer surfaces a dialog routing the user to the right
    /// settings screen — `installAndRelaunch` doesn't pre-empt that
    /// flow.
    ///
    /// **Why no signature-skip escape hatch.** Unlike the MSIX path on
    /// Windows (where the OS validates the Authenticode chain on
    /// `Add-AppxPackage`), Android's `PackageInstaller.Session` only
    /// validates that the APK's signing certificate matches the
    /// installed app's certificate (`SigningInfo.hasMultipleSigners`
    /// equality check). That's a same-key check, not a same-publisher
    /// check, and a compromised CDN could swap in a different APK
    /// signed with the same dev key. We require Ed25519 over the bytes
    /// regardless to pin the artifact identity.
    ///
    /// **First-cut limitations** (tracked in `docs/android-setup.md`
    /// "Known limitations (v0.5)"):
    ///
    /// - The install confirmation UI is system-driven; we don't track
    ///   the install result. `installAndRelaunch` returns once the
    ///   session has been committed; the user accepting / rejecting
    ///   the prompt happens after this method returns. Apps that need
    ///   to act on success / failure should listen for
    ///   `PackageInstaller.STATUS_*` broadcasts via their own
    ///   `BroadcastReceiver` (or wait for v0.5.x to surface this
    ///   through a `subscribe` stream).
    /// - Delta / split APKs are not supported. Only single-APK
    ///   updates work; AAB / split-by-density is queued.
    public final class AndroidUpdater: Updater, @unchecked Sendable {
        private let endpoint: URL
        private let publicKey: String?
        private let currentVersion: String
        private let target: String
        private let urlSession: URLSession
        private let stagingRoot: URL

        private let lock = NSLock()
        private var stagedArtifactPath: URL?
        private var stagedInfo: UpdateInfo?

        /// - Parameters:
        ///   - endpoint: URL of the JSON manifest. May contain
        ///     `{{target}}` and `{{current_version}}` placeholders;
        ///     they are substituted before the request is made.
        ///   - publicKey: Base64 of the 32-byte raw Ed25519 public key
        ///     (or minisign-format public-key file contents). Required
        ///     — the runtime refuses to install an unsigned artifact.
        ///   - currentVersion: Version string the running build
        ///     identifies as. Defaults to `"0.0.0"`. Apps should pass
        ///     `versionName` from their `BuildConfig` (or the value
        ///     baked into `pwa.json`'s `version`).
        ///   - target: Manifest target key (e.g. `android-aarch64-apk`).
        ///     Defaults to `UpdaterTarget.current(packageFormat: "apk")`.
        ///   - urlSession: Override for tests. Defaults to `.shared`.
        ///   - stagingRoot: Where to stage downloaded APKs. Defaults
        ///     to `<cache>/SwiftPWAUpdates`.
        public init(
            endpoint: URL,
            publicKey: String?,
            currentVersion: String? = nil,
            target: String? = nil,
            urlSession: URLSession = .shared,
            stagingRoot: URL? = nil
        ) {
            self.endpoint = endpoint
            self.publicKey = publicKey
            self.currentVersion = currentVersion ?? "0.0.0"
            self.target = target ?? UpdaterTarget.current(packageFormat: "apk")
            self.urlSession = urlSession
            self.stagingRoot = stagingRoot ?? Self.defaultStagingRoot()
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

        private func stage(
            info: UpdateInfo,
            yield: @escaping @Sendable (UpdaterEvent) -> Void
        ) async throws -> URL {
            let dir = try ensureVersionStagingDir(version: info.version)
            let staged = dir.appendingPathComponent("update.apk")

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
            // The Kotlin side opens a `PackageInstaller.Session`,
            // streams the APK bytes in, and commits with a PendingIntent
            // — the system then shows the standard install-confirmation
            // UI. Returns immediately on commit; we don't wait for the
            // user's accept/reject.
            _ = try await AndroidRPC.call(
                "updater.installApk",
                InstallApkArgs(path: staged.path),
                as: NoResult.self
            )
            // Don't `exit()` like the desktop backends do. Android's
            // process model means the system kills + relaunches the
            // app once the APK has been written — `exit()` here would
            // race the install commit. The Activity stays up until
            // the system tears it down on package replacement.
        }

        // MARK: - helpers

        func verifyEd25519(data: Data, signature: String) throws {
            guard let publicKey else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "no public key configured — pass one to AndroidUpdater(publicKey:)"
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
            // Android apps' cache dir is `<context>.getCacheDir()` —
            // typically `/data/data/<pkg>/cache`. We don't have the
            // Context handy from Swift, but `NSTemporaryDirectory` on
            // Android resolves to the per-app cache via the runtime's
            // `TMPDIR` env var, which the JNI bootstrap sets up. As a
            // belt-and-braces fallback we use `/data/local/tmp` — that
            // path exists on every Android build but isn't the right
            // long-term home (it's writable only on rooted / debug
            // builds). Apps that care should pass `stagingRoot:`
            // explicitly with their `Context.getCacheDir().path`.
            let tmp = NSTemporaryDirectory()
            let base = URL(fileURLWithPath: tmp.isEmpty ? "/data/local/tmp" : tmp)
            return base.appendingPathComponent("SwiftPWAUpdates", isDirectory: true)
        }
    }

    /// On-the-wire shape for the `updater.installApk` RPC.
    struct InstallApkArgs: Encodable {
        let path: String
    }
#endif

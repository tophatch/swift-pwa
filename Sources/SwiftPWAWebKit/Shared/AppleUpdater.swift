#if os(macOS) || os(iOS)
    import CryptoKit
    import Foundation
    import SwiftPWACore

    #if os(macOS)
        import AppKit
    #elseif os(iOS)
        import UIKit
    #endif

    /// `Updater` for Apple platforms. One type, two install paths:
    ///
    /// - **macOS**: download a signed `.app.tar.gz`, verify Ed25519
    ///   signature, untar to a staging directory, and on
    ///   `installAndRelaunch` spawn a detached `/bin/sh` helper that
    ///   waits for the parent to exit, `ditto`s the new bundle in
    ///   place of the running one, and re-`open`s it. This is the
    ///   standard "Squirrel-style" trick — the kernel keeps the
    ///   running mmap valid, and the new app picks up on next launch.
    ///
    ///   **Delta (binary-patch) updates.** Unlike the Linux AppImage /
    ///   Windows portable backends — where the installed file *is* the
    ///   signed artifact, so a patch has a natural base on disk — macOS
    ///   installs the *extracted* `.app` and discards the signed
    ///   `.app.tar.gz`. To make deltas work anyway, this backend caches
    ///   the last verified `.app.tar.gz` (one artifact's disk, under
    ///   `<stagingRoot>/base/`) and, when a manifest advertises a delta
    ///   from the running version, reconstructs the new tarball from
    ///   that cached base + the patch, then runs the **same** Ed25519
    ///   check as a full download. Any failure (no cached base yet,
    ///   base-hash mismatch, corrupt patch, signature) transparently
    ///   falls back to a full download. The first update after this
    ///   ships has no cached base and always full-downloads; it then
    ///   caches the base so subsequent updates can go delta.
    /// - **iOS** (enterprise / ad-hoc): the manifest entry's `url` must
    ///   point at the install-manifest `.plist` (not the `.ipa`).
    ///   `download` is a no-op that yields `readyToInstall` straight
    ///   away — the actual transfer happens after `installAndRelaunch`
    ///   opens `itms-services://?action=download-manifest&url=…` and
    ///   the system installer takes over. Signature trust is delegated
    ///   to Apple's signing chain, so no public key is required (and
    ///   the Ed25519 field on the manifest entry is ignored on iOS).
    ///
    /// **First-cut limitations** (each tracked in
    /// `docs/macos-setup.md` / `docs/ios-setup.md` "Known limitations"):
    ///
    /// - macOS install prompts no UI before swapping. Apps that want a
    ///   "Restart now / later" dialog should subscribe to
    ///   `updater.run`, gate `updater.installAndRelaunch` behind their
    ///   own prompt UI, and only call it when the user agrees.
    public final class AppleUpdater: Updater, @unchecked Sendable {
        private let endpoint: URL
        private let publicKey: String?
        private let currentVersion: String
        private let target: String
        private let urlSession: URLSession
        private let stagingRoot: URL

        private let lock = NSLock()
        private var stagedAppPath: URL?
        private var stagedInfo: UpdateInfo?

        /// - Parameters:
        ///   - endpoint: URL of the JSON manifest. May contain
        ///     `{{target}}` and `{{current_version}}` placeholders;
        ///     they are substituted before the request is made.
        ///   - publicKey: Base64 of the 32-byte raw Ed25519 public key.
        ///     Required on macOS (artifacts are verified before
        ///     install). Pass `nil` on iOS — `itms-services` validates
        ///     the .ipa via Apple's signing chain.
        ///   - currentVersion: Version string the running build
        ///     identifies as. Defaults to
        ///     `Bundle.main.infoDictionary["CFBundleShortVersionString"]`.
        ///   - target: Manifest target key (e.g. `darwin-aarch64`).
        ///     Defaults to `UpdaterTarget.current()`.
        ///   - urlSession: Override for tests. Defaults to `.shared`.
        ///   - stagingRoot: Where to stage downloaded artifacts.
        ///     Defaults to `~/Library/Caches/<bundle-id>/SwiftPWAUpdates`
        ///     on macOS, the app's Caches dir on iOS (unused — iOS
        ///     doesn't stage anything locally).
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
            self.currentVersion = currentVersion
                ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
                ?? "0.0.0"
            self.target = target ?? UpdaterTarget.current(packageFormat: AppleUpdater.defaultPackageFormat())
            self.urlSession = urlSession
            self.stagingRoot = stagingRoot ?? AppleUpdater.defaultStagingRoot()
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
                        #if os(macOS)
                            let stagedApp = try await self.macStage(info: info) { event in
                                continuation.yield(event)
                            }
                            self.lock.withLock {
                                self.stagedAppPath = stagedApp
                                self.stagedInfo = info
                            }
                        #elseif os(iOS)
                            // Nothing to fetch — `itms-services://` will
                            // pull the .ipa from the manifest plist when
                            // `installAndRelaunch` opens the URL.
                            self.lock.withLock { self.stagedInfo = info }
                        #endif
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

        #if os(macOS)
            /// Download → verify → untar. Returns the staged `.app`
            /// bundle URL. Streams `downloadProgress` frames at the
            /// granularity of `URLSessionDownloadDelegate.didWriteData`
            /// — typically every ~64 KB chunk on Apple URL loaders.
            private func macStage(
                info: UpdateInfo,
                yield: @escaping @Sendable (UpdaterEvent) -> Void
            ) async throws -> URL {
                let dir = try ensureVersionStagingDir(version: info.version)
                let archiveURL = dir.appendingPathComponent("update.tar.gz")
                do {
                    // Fast path: if the manifest advertised a delta for our
                    // running version and we've cached the matching signed
                    // tarball from a prior update, download the (small) patch,
                    // reconstruct the new tarball locally, and verify the
                    // *reconstructed* artifact. Any failure falls through to
                    // the full download below — the delta is an optimization,
                    // never a hard dependency.
                    var obtainedViaDelta = false
                    if let delta = info.delta, let base = cachedBaseTarballURL() {
                        do {
                            try await stageViaDelta(
                                delta: delta, info: info, base: base, into: archiveURL, yield: yield
                            )
                            obtainedViaDelta = true
                        } catch {
                            FileHandle.standardError.write(Data(
                                "[swift-pwa updater] delta update failed (\(error)); falling back to full download\n"
                                    .utf8
                            ))
                            try? FileManager.default.removeItem(at: archiveURL)
                        }
                    }

                    if !obtainedViaDelta {
                        _ = try await UpdaterDownload.download(
                            from: info.downloadURL,
                            to: archiveURL,
                            urlSession: urlSession,
                            onProgress: { bytes, total in
                                yield(.downloadProgress(bytesDownloaded: bytes, contentLength: total))
                            }
                        )

                        let archiveData = try Data(contentsOf: archiveURL)
                        try verifyEd25519(data: archiveData, signature: info.signature)
                    }

                    let extracted = dir.appendingPathComponent("extracted", isDirectory: true)
                    try? FileManager.default.removeItem(at: extracted)
                    try FileManager.default.createDirectory(
                        at: extracted, withIntermediateDirectories: true
                    )
                    let tar = Process()
                    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                    tar.arguments = ["-xzf", archiveURL.path, "-C", extracted.path]
                    tar.standardOutput = FileHandle.nullDevice
                    tar.standardError = FileHandle.nullDevice
                    try tar.run()
                    tar.waitUntilExit()
                    guard tar.terminationStatus == 0 else {
                        throw BridgeError(
                            code: BridgeError.handler,
                            message: "tar -xzf failed (status \(tar.terminationStatus))"
                        )
                    }

                    let entries = try FileManager.default.contentsOfDirectory(atPath: extracted.path)
                    guard let appName = entries.first(where: { $0.hasSuffix(".app") }) else {
                        throw BridgeError(
                            code: BridgeError.handler,
                            message: "extracted archive contained no .app bundle"
                        )
                    }
                    // Cache the verified tarball as the base for the *next*
                    // update's delta (best-effort — see `saveBaseTarball`).
                    // Do this before dropping the archive; the base cache lives
                    // outside the per-version staging dir the install helper
                    // cleans up, so it survives the swap.
                    saveBaseTarball(from: archiveURL, version: info.version)

                    // Verified + extracted: the archive is no longer needed (only
                    // the extracted `.app` gets swapped in), so drop it — the cache
                    // then holds just the staged bundle, which the install helper
                    // removes after the swap.
                    try? FileManager.default.removeItem(at: archiveURL)
                    return extracted.appendingPathComponent(appName)
                } catch {
                    // Download / signature / extraction failure: never leave
                    // unverified or partial bytes in the cache. (A wrong-key
                    // signature used to leave the downloaded `update.tar.gz`
                    // behind.)
                    try? FileManager.default.removeItem(at: dir)
                    throw error
                }
            }

            /// Reconstruct the new `.app.tar.gz` from a cached base tarball + a
            /// `zstd --patch-from` patch, verify it against the manifest's
            /// full-artifact signature, and write the verified bytes to
            /// `archiveURL` (from where `macStage` extracts them exactly as it
            /// would a full download). Throws (so `macStage` falls back) on a
            /// base-hash mismatch, a download / decode error, or a signature
            /// failure.
            private func stageViaDelta(
                delta: UpdateInfo.DeltaInfo,
                info: UpdateInfo,
                base: URL,
                into archiveURL: URL,
                yield: @escaping @Sendable (UpdaterEvent) -> Void
            ) async throws {
                let baseData = try Data(contentsOf: base)
                // Optional local fast-reject: if the cached base doesn't match
                // the patch's advertised base, don't bother downloading it.
                if let expected = delta.baseSHA256 {
                    let actual = SHA256.hash(data: baseData)
                        .map { String(format: "%02x", $0) }.joined()
                    guard actual == expected.lowercased() else {
                        throw BridgeError(
                            code: BridgeError.handler,
                            message: "delta base mismatch (cached artifact differs from the patch's base)"
                        )
                    }
                }

                let patchFile = archiveURL.deletingLastPathComponent()
                    .appendingPathComponent("update.zstpatch")
                _ = try await UpdaterDownload.download(
                    from: delta.url,
                    to: patchFile,
                    urlSession: urlSession,
                    onProgress: { bytes, total in
                        yield(.downloadProgress(bytesDownloaded: bytes, contentLength: total))
                    }
                )
                let patchData = try Data(contentsOf: patchFile)
                let reconstructed = try ZstdPatch.apply(base: baseData, patch: patchData)
                // The same Ed25519 check a full download runs — trust rests on
                // the reconstructed artifact's signature, so a tampered patch
                // can only fail here (→ fall back), never smuggle bytes in.
                try verifyEd25519(data: reconstructed, signature: info.signature)
                try reconstructed.write(to: archiveURL)
                try? FileManager.default.removeItem(at: patchFile)
            }

            /// Directory holding the cached signed tarball used as a delta base.
            /// A sibling of the per-version staging dirs (which the install
            /// helper `rm -rf`s post-swap), so the base survives across updates.
            private func baseCacheDir() -> URL {
                stagingRoot.appendingPathComponent("base", isDirectory: true)
            }

            /// The cached `.app.tar.gz` matching the running version, or `nil`
            /// if we haven't cached one yet (the macOS analogue of Linux's
            /// `currentAppImagePath()` — the on-disk base a patch applies to).
            func cachedBaseTarballURL() -> URL? {
                let url = baseCacheDir().appendingPathComponent("\(currentVersion).app.tar.gz")
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }

            /// Cache the just-verified tarball as the delta base for the next
            /// update. Best-effort: a failure here only means the next update
            /// full-downloads, so it must never fail the install. Keeps just the
            /// newest tarball (one artifact's disk).
            private func saveBaseTarball(from verifiedArchive: URL, version: String) {
                let baseDir = baseCacheDir()
                do {
                    // Drop any prior cached base before copying the new one in.
                    if FileManager.default.fileExists(atPath: baseDir.path) {
                        try FileManager.default.removeItem(at: baseDir)
                    }
                    try FileManager.default.createDirectory(
                        at: baseDir, withIntermediateDirectories: true
                    )
                    let dest = baseDir.appendingPathComponent("\(version).app.tar.gz")
                    try FileManager.default.copyItem(at: verifiedArchive, to: dest)
                } catch {
                    FileHandle.standardError.write(Data(
                        "[swift-pwa updater] could not cache delta base (\(error)); next update will full-download\n"
                            .utf8
                    ))
                }
            }

            func verifyEd25519(data: Data, signature: String) throws {
                guard let publicKey else {
                    throw BridgeError(
                        code: BridgeError.handler,
                        message: "no public key configured — pass one to AppleUpdater(publicKey:)"
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
        #endif

        // MARK: - installAndRelaunch

        public func installAndRelaunch() async throws {
            #if os(macOS)
                try macInstallAndRelaunch()
            #elseif os(iOS)
                try await iosInstallAndRelaunch()
            #endif
        }

        #if os(macOS)
            private func macInstallAndRelaunch() throws {
                let staged = lock.withLock { stagedAppPath }
                guard let staged else {
                    throw BridgeError(
                        code: BridgeError.handler,
                        message: "no staged update — call updater.run (or updater.download) first"
                    )
                }
                let installPath = Bundle.main.bundleURL
                guard installPath.pathExtension == "app" else {
                    // Likely running from `swift run` / `.build/...`; we
                    // can't swap a non-bundled binary. Tell the caller
                    // exactly what's wrong rather than silently no-op.
                    throw BridgeError(
                        code: BridgeError.handler,
                        message: """
                        installAndRelaunch requires a bundled `.app` (Bundle.main.bundleURL is \
                        \(installPath.path)). Bundle with `swift run swift-pwa build --target macos` \
                        and run from the resulting `.app` to exercise auto-updates.
                        """
                    )
                }
                let pid = ProcessInfo.processInfo.processIdentifier
                let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("swift-pwa-update-\(UUID().uuidString).sh")
                // `staged` is `<stagingRoot>/<version>/extracted/<App>.app`; its
                // grandparent is the per-version staging dir, cleaned after the
                // swap so the cache doesn't accumulate old bundles.
                let stagingVersionDir = staged
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                let script = #"""
                #!/bin/sh
                set -e
                while kill -0 \#(pid) 2>/dev/null; do
                    sleep 0.2
                done
                rm -rf "\#(installPath.path)"
                /usr/bin/ditto "\#(staged.path)" "\#(installPath.path)"
                /usr/bin/open "\#(installPath.path)"
                # Housekeeping: drop the consumed staging dir and this helper
                # itself (a running shell can unlink its own file on Unix).
                rm -rf "\#(stagingVersionDir.path)"
                rm -f "\#(scriptURL.path)"
                """#
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
                )

                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/sh")
                // The shell command exits immediately because the inner
                // helper is backgrounded with `&`. The detached helper
                // (re-parented to launchd by `nohup`) waits for our PID
                // to disappear and then performs the swap.
                proc.arguments = ["-c", "nohup \(scriptURL.path) </dev/null >/dev/null 2>&1 &"]
                try proc.run()
                proc.waitUntilExit()

                // Hand off to the helper. Calling `exit(0)` rather than
                // routing through `AppContext.quit` is a deliberate
                // simplification — the helper is going to terminate us
                // anyway, and the bridge's reply frame is academic
                // because the WebView is about to be torn down with the
                // process. A future iteration could plumb `quit` so JS
                // sees a clean reply before the swap.
                exit(0)
            }
        #endif

        #if os(iOS)
            @MainActor
            private func iosInstallAndRelaunch() async throws {
                let info = lock.withLock { stagedInfo }
                guard let info else {
                    throw BridgeError(
                        code: BridgeError.handler,
                        message: "no staged update — call updater.run (or updater.download) first"
                    )
                }
                let manifestURL = info.downloadURL.absoluteString
                guard let itms = URL(string: "itms-services://?action=download-manifest&url=\(manifestURL)") else {
                    throw BridgeError(
                        code: BridgeError.handler,
                        message: "could not construct itms-services URL for \(manifestURL)"
                    )
                }
                guard await UIApplication.shared.canOpenURL(itms) else {
                    throw BridgeError(
                        code: BridgeError.handler,
                        message: """
                        the system declined to open \(itms). Enterprise / ad-hoc updates require \
                        a build distributed via an Apple Developer Enterprise Program profile or \
                        an ad-hoc provisioning profile that lists this device.
                        """
                    )
                }
                _ = await UIApplication.shared.open(itms, options: [:])
            }
        #endif

        // MARK: - helpers

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
            let caches = (try? FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let bundleID = Bundle.main.bundleIdentifier ?? "swift-pwa"
            return caches
                .appendingPathComponent(bundleID, isDirectory: true)
                .appendingPathComponent("SwiftPWAUpdates", isDirectory: true)
        }

        private static func defaultPackageFormat() -> String? {
            #if os(iOS)
                // Enterprise / ad-hoc is the only first-class iOS path
                // for swift-pwa apps that want an in-app updater (the
                // App Store handles updates outside our control).
                return "enterprise"
            #else
                return nil
            #endif
        }
    }
#endif

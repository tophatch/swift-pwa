#if os(Windows)
    import Crypto
    import Foundation
    import SwiftPWACore
    import WinSDK

    #if canImport(FoundationNetworking)
        import FoundationNetworking
    #endif

    /// `Updater` for Windows.
    ///
    /// Handles both v0.4-supported package formats produced by
    /// `swift-pwa build --target windows`:
    ///
    /// - **`.portable`** — the app is a self-contained EXE in a folder
    ///   the user installed by hand (typical "drop and run" deploys).
    ///   `download` fetches the new EXE, signature-verifies it, and
    ///   stages it. `installAndRelaunch` spawns a detached PowerShell
    ///   helper that waits for the running process to exit, `Move-Item`s
    ///   the staged EXE onto the running EXE's path (`MoveFileExW`-style
    ///   atomic replace, `MOVEFILE_REPLACE_EXISTING`), and `Start-Process`es
    ///   the result. We use PowerShell rather than a `cmd.exe` batch
    ///   because the quoting model is far more forgiving for paths
    ///   containing spaces / brackets / unicode, and `-EncodedCommand`
    ///   bypasses the default Restricted execution policy without us
    ///   needing to drop a `.ps1` on disk first.
    /// - **`.msix`** — the app was installed via `Add-AppxPackage`
    ///   (sideload) or the Microsoft Store. `download` fetches the new
    ///   `.msix` and signature-verifies it; `installAndRelaunch` hands
    ///   the staged file to PowerShell's `Add-AppxPackage`, which lets
    ///   the OS validate the Authenticode chain and update the
    ///   installation in place. We still verify Ed25519 over the bytes
    ///   for tamper detection in transit (a compromised CDN could swap
    ///   in a different Microsoft-signed package — Authenticode catches
    ///   wholesale tampering but doesn't pin *which* signed package the
    ///   updater is allowed to install).
    ///
    /// **First-cut limitations** (each tracked in
    /// `docs/windows-setup.md` "Known limitations"):
    ///
    /// - `installAndRelaunch` on `.portable` requires write access to
    ///   the directory containing the running EXE. Apps installed
    ///   under `C:\Program Files\…` without an elevation step on
    ///   install will see `Move-Item` fail in the helper script.
    ///   Recommend installing portable bundles under `%LOCALAPPDATA%`
    ///   or the user's home directory.
    public final class WindowsUpdater: Updater, @unchecked Sendable {
        public enum InstallMode: String, Sendable {
            case portable
            case msix
        }

        private let endpoint: URL
        private let publicKey: String?
        private let currentVersion: String
        private let target: String
        private let installMode: InstallMode
        private let urlSession: URLSession
        private let stagingRoot: URL
        private let executablePathOverride: URL?

        // `package`-access rather than `internal` so the in-package test
        // runner `SwiftPWAWindowsTestRunner` can assert on them without
        // needing `@testable import` — release builds (which CI runs
        // before the test step) don't set `-enable-testing`, so the
        // `@testable` path fails to compile there.
        package let msixIdentityName: String?
        package let applicationID: String

        private let lock = NSLock()
        private var stagedArtifactPath: URL?
        private var stagedInfo: UpdateInfo?

        /// - Parameters:
        ///   - endpoint: URL of the JSON manifest. May contain
        ///     `{{target}}` and `{{current_version}}` placeholders;
        ///     they are substituted before the request is made.
        ///   - publicKey: Either base64 of the 32-byte raw Ed25519
        ///     public key or a minisign-format public-key file's
        ///     contents (the two-line `untrusted comment: …\n<base64>`
        ///     shape — see `Minisign`). Required for `.portable` (an
        ///     unsigned drop-in replaces the EXE, which is full code
        ///     execution). Optional for `.msix` — Authenticode
        ///     validates the package — but setting it pins *which*
        ///     signed package this updater channel is allowed to
        ///     install, which is the right posture for production
        ///     deployments.
        ///   - installMode: Picks between EXE-replacement and
        ///     `Add-AppxPackage`. Should match how the app was packaged
        ///     by `swift-pwa build --target windows`
        ///     (`--package-format portable` vs `msix`).
        ///   - currentVersion: Version string the running build
        ///     identifies as. Defaults to `"0.0.0"` — apps should pass
        ///     the value they baked into `pwa.json` / their build
        ///     metadata so manifest comparisons are accurate.
        ///   - target: Manifest target key (e.g. `windows-x86_64-msix`).
        ///     Defaults to `UpdaterTarget.current(packageFormat: <mode>)`
        ///     where `<mode>` is `"portable"` or `"msix"`.
        ///   - urlSession: Override for tests. Defaults to `.shared`.
        ///   - stagingRoot: Where to stage downloaded artifacts.
        ///     Defaults to `%LOCALAPPDATA%\<bundle-id>\SwiftPWAUpdates`,
        ///     falling back to `%TEMP%` if `LOCALAPPDATA` is unset.
        ///   - executablePath: Override for the running EXE's path.
        ///     Defaults to `GetModuleFileNameW(NULL, …)`. Tests pass an
        ///     explicit URL so they don't have to spoof a real install.
        ///   - msixIdentityName: The `Identity.Name` value baked into
        ///     the running MSIX package's `AppxManifest.xml` — used to
        ///     resolve the AUMID for post-install relaunch via
        ///     PowerShell's `Get-AppxPackage -Name <identity>`.
        ///     `AppxManifestGenerator.render` derives this by stripping
        ///     non-alphanumeric / non-dot / non-hyphen characters from
        ///     `pwa.json`'s `id` field; pass the same value here. When
        ///     `nil` (or for `installMode = .portable`), the helper
        ///     skips the relaunch line and the user re-launches from
        ///     Start manually.
        ///   - applicationID: Application id (the `Id` attribute of
        ///     `AppxManifest.xml`'s `<Application>` element). Defaults
        ///     to `"App"`, which matches what
        ///     `AppxManifestGenerator.render` emits. Apps that override
        ///     the manifest with a different application id should pass
        ///     a matching value here so the AUMID resolves.
        public init(
            endpoint: URL,
            publicKey: String?,
            installMode: InstallMode,
            currentVersion: String? = nil,
            target: String? = nil,
            urlSession: URLSession = .shared,
            stagingRoot: URL? = nil,
            executablePath: URL? = nil,
            msixIdentityName: String? = nil,
            applicationID: String = "App"
        ) {
            self.endpoint = endpoint
            self.publicKey = publicKey
            self.installMode = installMode
            self.currentVersion = currentVersion ?? "0.0.0"
            self.target = target ?? UpdaterTarget.current(packageFormat: installMode.rawValue)
            self.urlSession = urlSession
            self.stagingRoot = stagingRoot ?? Self.defaultStagingRoot()
            executablePathOverride = executablePath
            self.msixIdentityName = msixIdentityName
            self.applicationID = applicationID
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

        /// Download → (verify) → return staged path. Streams
        /// `downloadProgress` frames at the granularity of
        /// `URLSessionDownloadDelegate.didWriteData`. For `.msix` with
        /// no public key configured, Ed25519 verification is skipped —
        /// the OS validates the Authenticode chain on
        /// `Add-AppxPackage`.
        private func stage(
            info: UpdateInfo,
            yield: @escaping @Sendable (UpdaterEvent) -> Void
        ) async throws -> URL {
            let dir = try ensureVersionStagingDir(version: info.version)
            let suffix = installMode == .msix ? "msix" : "exe"
            let staged = dir.appendingPathComponent("update.\(suffix)")
            do {
                // Fast path (portable only — the installed EXE *is* the
                // signed artifact, so it's a valid patch base; MSIX bytes
                // are the OS installer's and don't round-trip): if the
                // manifest advertised a delta for our version and we can
                // locate the running EXE, download the patch, reconstruct
                // locally, and verify the *reconstructed* artifact. Any
                // failure falls through to the full download below.
                if installMode == .portable, let delta = info.delta, let base = currentExecutablePath() {
                    do {
                        try await stageViaDelta(delta: delta, info: info, base: base, into: staged, yield: yield)
                        return staged
                    } catch {
                        FileHandle.standardError.writeQuietly(Data(
                            "[swift-pwa updater] delta update failed (\(error)); falling back to full download\n".utf8
                        ))
                        try? FileManager.default.removeItem(at: staged)
                    }
                }

                _ = try await UpdaterDownload.download(
                    from: info.downloadURL,
                    to: staged,
                    urlSession: urlSession,
                    onProgress: { bytes, total in
                        yield(.downloadProgress(bytesDownloaded: bytes, contentLength: total))
                    }
                )

                try verifySignature(at: staged, info: info)

                return staged
            } catch {
                // Download / signature failure: never leave unverified or
                // partial bytes in the cache.
                try? FileManager.default.removeItem(at: dir)
                throw error
            }
        }

        /// Reconstruct the new EXE from the installed one + a `zstd
        /// --patch-from` patch, then verify it against the manifest's
        /// full-artifact signature. Writes the verified bytes to `staged`.
        /// Throws (so `stage` can fall back to a full download) on a base
        /// mismatch, a download / decode error, or a signature failure.
        private func stageViaDelta(
            delta: UpdateInfo.DeltaInfo,
            info: UpdateInfo,
            base: URL,
            into staged: URL,
            yield: @escaping @Sendable (UpdaterEvent) -> Void
        ) async throws {
            let baseData = try Data(contentsOf: base)
            if let expected = delta.baseSHA256 {
                let actual = SHA256.hash(data: baseData)
                    .map { String(format: "%02x", $0) }.joined()
                guard actual == expected.lowercased() else {
                    throw BridgeError(
                        code: BridgeError.handler,
                        message: "delta base mismatch (installed EXE differs from the patch's base)"
                    )
                }
            }

            let patchFile = staged.deletingLastPathComponent().appendingPathComponent("update.zstpatch")
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
            try reconstructed.write(to: staged)
            try? FileManager.default.removeItem(at: patchFile)
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
            switch installMode {
            case .portable:
                try installPortable(staged: staged)
            case .msix:
                try installMSIX(staged: staged)
            }
            // Hand off to the helper. Exiting frees the running EXE so
            // the helper's `Move-Item` (portable) or `Add-AppxPackage`
            // (msix) can replace it. Mirrors the macOS / Linux pattern.
            exit(0)
        }

        private func installPortable(staged: URL) throws {
            guard let target = currentExecutablePath() else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: """
                    installAndRelaunch could not detect the running EXE path. \
                    GetModuleFileNameW returned an empty string, which usually \
                    means the process was started in an unusual way (e.g. via \
                    a memory-mapped image without a backing file). Pass the path \
                    explicitly via WindowsUpdater(executablePath:) for tests.
                    """
                )
            }
            let pid = GetCurrentProcessId()
            // Drop the now-empty per-version staging directory after the move,
            // so it doesn't accumulate across updates (parity with the macOS
            // helper's post-swap cleanup).
            let stagingDir = staged.deletingLastPathComponent()
            let script = """
            $ErrorActionPreference = 'SilentlyContinue'
            try { Wait-Process -Id \(pid) -Timeout 60 -ErrorAction SilentlyContinue } catch {}
            Move-Item -LiteralPath \(psQuote(staged.path)) -Destination \(psQuote(target.path)) -Force
            Remove-Item -LiteralPath \(psQuote(stagingDir.path)) -Recurse -Force
            Start-Process -FilePath \(psQuote(target.path))
            """
            try spawnDetachedPowerShell(script: script)
        }

        private func installMSIX(staged: URL) throws {
            let pid = GetCurrentProcessId()
            // `-ForceUpdateFromAnyVersion` lets us replace a higher-versioned
            // package with a lower one (e.g. emergency rollback); without
            // it `Add-AppxPackage` rejects an "older" install and exits 1.
            // The MSIX subsystem still requires the publisher CN to match.
            //
            // For relaunch we need the AUMID, which is
            // `<PackageFamilyName>!<ApplicationId>`. The family name is
            // an opaque hash derived from the publisher; resolving it
            // by hand from Swift is fiddly (and `GetCurrentPackageFamilyName`
            // wouldn't reflect the *new* package on disk after the
            // update anyway). Letting PowerShell's `Get-AppxPackage`
            // do the lookup via the manifest's `Identity.Name` is both
            // simpler and self-correcting — if the update changed the
            // family name, we still find it by identity.
            //
            // No identity → no relaunch line. The package is still
            // updated on disk, the user just relaunches from Start.
            // Same for `installMode = .portable`, which doesn't get a
            // relaunch path (the portable `installPortable` already
            // handles its own `Start-Process`).
            let relaunch = if let identity = msixIdentityName, !identity.isEmpty {
                """
                $pkg = Get-AppxPackage -Name \(psQuote(identity)) | Select-Object -First 1
                if ($pkg) {
                    Start-Sleep -Milliseconds 500
                    Start-Process -FilePath ('shell:AppsFolder\\' + $pkg.PackageFamilyName + '!' + \(
                        psQuote(applicationID)
                    ))
                }
                """
            } else {
                ""
            }
            // Drop the now-consumed per-version staging directory after the
            // package install (parity with the macOS / portable cleanup).
            let stagingDir = staged.deletingLastPathComponent()
            let script = """
            $ErrorActionPreference = 'SilentlyContinue'
            try { Wait-Process -Id \(pid) -Timeout 60 -ErrorAction SilentlyContinue } catch {}
            Add-AppxPackage -Path \(psQuote(staged.path)) -ForceUpdateFromAnyVersion
            Remove-Item -LiteralPath \(psQuote(stagingDir.path)) -Recurse -Force
            \(relaunch)
            """
            try spawnDetachedPowerShell(script: script)
        }

        // MARK: - helpers (`package`-access so the in-package test runner

        // can exercise them directly without `@testable import` — which
        // would require `-enable-testing`, off in release builds).

        /// Resolve the running EXE's path. Returns the constructor
        /// override if set, otherwise reads `GetModuleFileNameW(NULL)`.
        package func currentExecutablePath() -> URL? {
            if let override = executablePathOverride { return override }
            var buf = [WCHAR](repeating: 0, count: 1024)
            let len = buf.withUnsafeMutableBufferPointer { ptr -> DWORD in
                GetModuleFileNameW(nil, ptr.baseAddress, DWORD(ptr.count))
            }
            guard len > 0 else { return nil }
            let path = String(decoding: buf.prefix(Int(len)).map { UInt16($0) }, as: UTF16.self)
            return URL(fileURLWithPath: path)
        }

        /// Verify the staged artifact's Ed25519 signature against the
        /// configured public key. For `.msix` with no public key
        /// configured (and no signature in the manifest entry), skips
        /// verification and trusts the OS Authenticode chain.
        package func verifySignature(at staged: URL, info: UpdateInfo) throws {
            if installMode == .msix, publicKey == nil, info.signature.isEmpty {
                // Explicit opt-out for MSIX: rely on `Add-AppxPackage`'s
                // chain validation. The portable path doesn't get this
                // escape hatch — without Ed25519 it has no integrity check.
                return
            }
            let data = try Data(contentsOf: staged)
            try verifyEd25519(data: data, signature: info.signature)
        }

        /// Verify an Ed25519 signature over `data` against the configured
        /// public key. Both the public-key and signature inputs accept
        /// either base64 of the raw bytes (32 / 64 respectively) or
        /// minisign-format file contents (the two-line `untrusted
        /// comment: …\n<base64>` shape) — see `Minisign` for the wire
        /// shape. Throws a bridge error with a clear message on every
        /// failure mode (missing key, malformed key / signature,
        /// signature mismatch).
        package func verifyEd25519(data: Data, signature: String) throws {
            guard let publicKey else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "no public key configured — pass one to WindowsUpdater(publicKey:)"
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

        /// Spawn `powershell.exe` running `script` detached from this
        /// process. Uses `-EncodedCommand <utf16-le-base64>` so we don't
        /// have to escape quotes for the cmdline parser, and so the
        /// default `Restricted` execution policy doesn't reject the
        /// inline command (encoded commands are treated as a single
        /// `-Command` invocation, which the policy exempts).
        ///
        /// Stdio is redirected to `NUL` so the helper isn't tied to a
        /// terminal that's about to disappear with us.
        func spawnDetachedPowerShell(script: String) throws {
            let utf16 = script.utf16.flatMap { unit in
                [UInt8(unit & 0xFF), UInt8((unit >> 8) & 0xFF)]
            }
            let encoded = Data(utf16).base64EncodedString()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
            proc.arguments = [
                "-NoProfile",
                "-NonInteractive",
                "-WindowStyle", "Hidden",
                "-EncodedCommand", encoded
            ]
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            // Don't waitUntilExit — the helper script is supposed to
            // outlive us. We exit(0) right after this returns; Windows
            // doesn't propagate parent termination to children, so the
            // helper keeps running on its own.
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
            let base = if let local = env["LOCALAPPDATA"], !local.isEmpty {
                URL(fileURLWithPath: local)
            } else {
                URL(fileURLWithPath: NSTemporaryDirectory())
            }
            let appID = Bundle.main.bundleIdentifier ?? "swift-pwa"
            return base
                .appendingPathComponent(appID, isDirectory: true)
                .appendingPathComponent("SwiftPWAUpdates", isDirectory: true)
        }

        /// Wrap a string for use as a PowerShell single-quoted literal.
        /// PowerShell escapes a single quote inside `'…'` by doubling it
        /// (`''`), same as SQL. Single-quoted strings don't interpolate,
        /// which is exactly what we want for paths that may contain `$`.
        private func psQuote(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
        }
    }
#endif

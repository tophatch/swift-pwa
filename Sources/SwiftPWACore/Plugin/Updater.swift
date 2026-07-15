import Foundation

/// Cross-platform auto-updater. Backends provide a concrete impl:
/// `AppleUpdater` (macOS + iOS) ships from `SwiftPWAWebKit`,
/// `LinuxAppImageUpdater` ships from `SwiftPWAGTK`, and `WindowsUpdater`
/// (portable + MSIX install modes) ships from `SwiftPWAWindows`.
/// Tests use `MockUpdater` from `_SwiftPWATestSupport`.
///
/// **Scope:** signed JSON manifest fetch, full-bundle download with
/// progress events, Ed25519 signature verification, platform-native
/// install, and a mandatory-update `min_supported_version` kill-switch
/// (surfaced as `UpdateInfo.mandatory`). **Delta (binary-patch)
/// updates**: the manifest carries optional per-target `deltas`
/// (resolved into `UpdateInfo.delta`); a delta-aware backend downloads
/// the small patch, reconstructs the artifact locally (via the vendored
/// `CZstd` decoder), then runs the *same* Ed25519 check against the
/// reconstructed bytes before installing — falling back to a full
/// download on any failure. Implemented on Linux AppImage
/// (`LinuxAppImageUpdater`) and Windows portable (`WindowsUpdater`
/// `.portable`) — the two where the installed file *is* the signed
/// artifact. Design: `docs/proposals/delta-updates.md`.
///
/// **Concurrency.** Implementations are *not* `@MainActor` — `download`
/// runs on the cooperative pool so I/O doesn't block the UI thread.
/// Implementations that need to touch UI (e.g. iOS `UIApplication.open`
/// from `installAndRelaunch`) hop via `MainThread.run` internally.
public protocol Updater: AnyObject, Sendable {
    /// Fetch the manifest, compare against the running bundle version,
    /// and return an `UpdateInfo` if a newer release is available.
    /// Returns `nil` when the running version is already up to date.
    func check() async throws -> UpdateInfo?

    /// Download (and verify) the artifact described by `info`. Yields
    /// `downloadProgress` events while bytes are streaming and a final
    /// `readyToInstall` event once the artifact has been signature-
    /// verified to a staging path. The stream terminates with `end`
    /// after `readyToInstall`. I/O or signature failures throw a
    /// `BridgeError(code: .handler)` into the stream.
    func download(_ info: UpdateInfo) -> AsyncThrowingStream<UpdaterEvent, any Error>

    /// Apply the staged update. The running process is typically
    /// replaced before this method returns (macOS hands off to a
    /// detached helper; iOS hands off to the system installer via
    /// `itms-services://`). Throws if no update has been staged.
    func installAndRelaunch() async throws

    /// Streaming variant of `installAndRelaunch` that surfaces the
    /// post-commit install lifecycle. On platforms where install
    /// replaces the running process the stream finishes without
    /// yielding (the process is gone before any event could be
    /// observed); the default implementation provides exactly that
    /// shape by calling `installAndRelaunch` and finishing.
    ///
    /// On Android the system installer's confirmation UI is
    /// asynchronous — the user accept / reject lands via a
    /// `PackageInstaller.STATUS_*` broadcast that may fire long after
    /// `installAndRelaunch` returns. `AndroidUpdater` overrides this
    /// method to yield `.installCommitted` once the session commits,
    /// then `.installSucceeded` / `.installFailed` once the broadcast
    /// arrives, so apps can drive their own "Update queued / Update
    /// failed" UI without rolling a separate `BroadcastReceiver`.
    func install() -> AsyncThrowingStream<UpdaterEvent, any Error>
}

public extension Updater {
    /// Default streaming install: delegates to `installAndRelaunch`
    /// and finishes. Suitable for every backend where install replaces
    /// the running process (macOS, iOS, Linux AppImage, Windows MSIX
    /// + portable), since no follow-up events can be observed from
    /// the dying process anyway.
    func install() -> AsyncThrowingStream<UpdaterEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await installAndRelaunch()
                    continuation.finish()
                } catch let bridge as BridgeError {
                    continuation.yield(.error(code: bridge.code, message: bridge.message))
                    continuation.finish(throwing: bridge)
                } catch {
                    continuation.yield(.error(code: BridgeError.handler, message: "\(error)"))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - DTOs

/// One available update. Matches the JS-visible shape returned by
/// `updater.check` and emitted as `available(info)` from `updater.run`.
public struct UpdateInfo: Codable, Sendable, Equatable {
    public var version: String
    public var currentVersion: String
    public var pubDate: String?
    public var notes: String?
    public var downloadURL: URL
    public var signature: String
    public var target: String

    /// `true` when the running (`currentVersion`) build is below the
    /// manifest's `min_supported_version` floor — i.e. this update is a
    /// mandatory kill-switch upgrade, not an optional one. Derived by
    /// `UpdateManifest.updateInfo(for:currentVersion:)`; defaults to
    /// `false` (no floor, or the running build is at/above it). JS reads
    /// it off `updater.check` / the `available` event to force the
    /// update UI (e.g. block the app until installed).
    public var mandatory: Bool

    /// The applicable delta (binary-patch) for the running build, if the
    /// manifest advertised one whose `from` matches `currentVersion`.
    /// `nil` when no delta path is available — the backend then does a
    /// full download. Resolved by `UpdateManifest.updateInfo(for:currentVersion:)`.
    /// A delta-aware backend tries the small patch first and falls back
    /// to `downloadURL` on any failure; JS may also read it off the
    /// `available` event for "downloading a small update" copy.
    public var delta: DeltaInfo?

    /// The delta path chosen for this update: where to fetch the patch,
    /// its advertised size, and the expected SHA-256 of the base
    /// (installed) artifact the patch was cut against. A projection of
    /// `UpdateManifest.PlatformEntry.Delta` with `from` dropped (already
    /// matched against the running version).
    public struct DeltaInfo: Codable, Sendable, Equatable {
        public var url: URL
        public var size: Int?
        /// Lowercase-hex SHA-256 of the base artifact. Lets a backend
        /// skip a doomed download+apply when its installed bytes don't
        /// match the advertised base. Optimization only — trust rests on
        /// verifying the *reconstructed* artifact's Ed25519 signature.
        public var baseSHA256: String?

        public init(url: URL, size: Int? = nil, baseSHA256: String? = nil) {
            self.url = url
            self.size = size
            self.baseSHA256 = baseSHA256
        }

        private enum CodingKeys: String, CodingKey {
            case url
            case size
            case baseSHA256 = "base_sha256"
        }
    }

    public init(
        version: String,
        currentVersion: String,
        pubDate: String? = nil,
        notes: String? = nil,
        downloadURL: URL,
        signature: String,
        target: String,
        mandatory: Bool = false,
        delta: DeltaInfo? = nil
    ) {
        self.version = version
        self.currentVersion = currentVersion
        self.pubDate = pubDate
        self.notes = notes
        self.downloadURL = downloadURL
        self.signature = signature
        self.target = target
        self.mandatory = mandatory
        self.delta = delta
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case currentVersion = "current_version"
        case pubDate = "pub_date"
        case notes
        case downloadURL = "download_url"
        case signature
        case target
        case mandatory
        case delta
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        currentVersion = try c.decode(String.self, forKey: .currentVersion)
        pubDate = try c.decodeIfPresent(String.self, forKey: .pubDate)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        downloadURL = try c.decode(URL.self, forKey: .downloadURL)
        signature = try c.decode(String.self, forKey: .signature)
        target = try c.decode(String.self, forKey: .target)
        // Derived + additive: tolerate its absence (older callers, or a
        // hand-built info passed back through `updater.run`).
        mandatory = try c.decodeIfPresent(Bool.self, forKey: .mandatory) ?? false
        delta = try c.decodeIfPresent(DeltaInfo.self, forKey: .delta)
    }
}

/// Tagged event union streamed by `updater.run`. The on-the-wire shape
/// is `{ "type": "<tag>", ...payload }` so JS-side discrimination is
/// the natural `switch (event.type) { ... }` instead of inspecting a
/// nested object — matches the rest of the bridge's tagged events.
public enum UpdaterEvent: Sendable, Equatable {
    case checking
    case available(UpdateInfo)
    case upToDate
    case downloadProgress(bytesDownloaded: Int, contentLength: Int?)
    case readyToInstall
    case error(code: String, message: String)

    /// The platform install session has been committed and the system
    /// install UI is (or shortly will be) visible to the user. Emitted
    /// only by `install()`; not by `download(_:)`. Fires on Android
    /// after `PackageInstaller.Session.commit`; never fires on
    /// platforms where `installAndRelaunch` replaces the running
    /// process directly.
    case installCommitted

    /// The platform reported the install completed successfully.
    /// Emitted only by `install()`. On Android this fires from the
    /// `PackageInstaller.STATUS_SUCCESS` broadcast, typically right
    /// before the system kills + relaunches the app on package
    /// replacement (so observe-and-act windows are short).
    case installSucceeded

    /// The platform reported the install failed or the user rejected
    /// it. Emitted only by `install()`. `code` is a platform-stable
    /// identifier (Android: the `PackageInstaller.STATUS_FAILURE_*`
    /// constant name, e.g. `"STATUS_FAILURE_ABORTED"` for user
    /// rejection); `message` is the system-supplied reason string if
    /// the platform provided one.
    case installFailed(code: String, message: String?)
}

extension UpdaterEvent: Codable {
    private enum Tag: String, Codable {
        case checking
        case available
        case upToDate
        case downloadProgress
        case readyToInstall
        case error
        case installCommitted
        case installSucceeded
        case installFailed
    }

    private enum Keys: String, CodingKey {
        case type
        case info
        case bytesDownloaded
        case contentLength
        case code
        case message
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .checking:
            try c.encode(Tag.checking, forKey: .type)
        case let .available(info):
            try c.encode(Tag.available, forKey: .type)
            try c.encode(info, forKey: .info)
        case .upToDate:
            try c.encode(Tag.upToDate, forKey: .type)
        case let .downloadProgress(bytes, total):
            try c.encode(Tag.downloadProgress, forKey: .type)
            try c.encode(bytes, forKey: .bytesDownloaded)
            try c.encodeIfPresent(total, forKey: .contentLength)
        case .readyToInstall:
            try c.encode(Tag.readyToInstall, forKey: .type)
        case let .error(code, message):
            try c.encode(Tag.error, forKey: .type)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
        case .installCommitted:
            try c.encode(Tag.installCommitted, forKey: .type)
        case .installSucceeded:
            try c.encode(Tag.installSucceeded, forKey: .type)
        case let .installFailed(code, message):
            try c.encode(Tag.installFailed, forKey: .type)
            try c.encode(code, forKey: .code)
            try c.encodeIfPresent(message, forKey: .message)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Tag.self, forKey: .type) {
        case .checking: self = .checking
        case .available:
            self = try .available(c.decode(UpdateInfo.self, forKey: .info))
        case .upToDate: self = .upToDate
        case .downloadProgress:
            self = try .downloadProgress(
                bytesDownloaded: c.decode(Int.self, forKey: .bytesDownloaded),
                contentLength: c.decodeIfPresent(Int.self, forKey: .contentLength)
            )
        case .readyToInstall: self = .readyToInstall
        case .error:
            self = try .error(
                code: c.decode(String.self, forKey: .code),
                message: c.decode(String.self, forKey: .message)
            )
        case .installCommitted: self = .installCommitted
        case .installSucceeded: self = .installSucceeded
        case .installFailed:
            self = try .installFailed(
                code: c.decode(String.self, forKey: .code),
                message: c.decodeIfPresent(String.self, forKey: .message)
            )
        }
    }
}

// MARK: - Wire format the updater endpoint returns

/// On-the-wire schema for the JSON manifest the `updater.endpoint`
/// URL serves. Mirrors Tauri v1's updater manifest layout so the same
/// publishing tooling (e.g. `tauri-action`) can produce manifests for
/// swift-pwa apps. The full per-target shape:
///
/// ```json
/// {
///   "version": "0.4.0",
///   "pub_date": "2026-05-12T10:00:00Z",
///   "notes": "Bug fixes and improvements.",
///   "platforms": {
///     "darwin-aarch64":             { "url": "...", "signature": "..." },
///     "windows-x86_64-msix":        { "url": "...", "signature": "..." },
///     "ios-aarch64-enterprise":     { "url": "...", "signature": "" },
///     "linux-x86_64-appimage":      {
///       "url": "...", "signature": "...",
///       "deltas": [
///         { "from": "0.3.0", "url": "...", "size": 214512, "base_sha256": "..." }
///       ]
///     }
///   }
/// }
/// ```
///
/// Per-target `signature` is base64 of the raw 64-byte Ed25519
/// signature over the artifact bytes. iOS enterprise leaves it empty
/// because `itms-services://` delegates trust to Apple's signing chain
/// rather than swift-pwa's key. Minisign-format signatures (Tauri's
/// preferred form) are a planned follow-up; for now use raw base64.
///
/// The optional `deltas` array (additive; Tauri readers + older
/// swift-pwa clients ignore it) advertises binary patches from prior
/// versions — see `PlatformEntry.Delta` and
/// `docs/proposals/delta-updates.md`.
public struct UpdateManifest: Codable, Sendable, Equatable {
    public var version: String
    public var pubDate: String?
    public var notes: String?

    /// Optional mandatory-update floor. When set, any running build
    /// *older* than this version is force-upgraded: the resolved
    /// `UpdateInfo.mandatory` is `true` so the app can block usage until
    /// the update installs (a security kill-switch — e.g. to retire a
    /// build with a critical vuln). Absent ⇒ every update is optional.
    public var minSupportedVersion: String?
    public var platforms: [String: PlatformEntry]

    public struct PlatformEntry: Codable, Sendable, Equatable {
        public var url: URL
        public var signature: String

        /// Optional binary-patch (delta) entries for this target — one
        /// per prior version that can upgrade to this release with a
        /// small patch instead of a full download. Additive: absent ⇒
        /// full-download only (older clients + Tauri readers ignore it).
        /// A client picks the entry whose `from` equals its running
        /// version, downloads `url`, reconstructs the new artifact
        /// locally, and verifies it against the top-level `signature` —
        /// so the delta carries no signature of its own.
        public var deltas: [Delta]?

        public struct Delta: Codable, Sendable, Equatable {
            /// Running version this patch upgrades *from* (exact match).
            public var from: String
            /// Where to fetch the patch (a zstd `--patch-from` frame).
            public var url: URL
            /// Patch size in bytes (advisory — progress + size policy).
            public var size: Int?
            /// Lowercase-hex SHA-256 of the base artifact this patch was
            /// cut against, so a client can reject a mismatched base
            /// before downloading. Optimization only; trust is the
            /// reconstructed-artifact signature check.
            public var baseSHA256: String?

            public init(from: String, url: URL, size: Int? = nil, baseSHA256: String? = nil) {
                self.from = from
                self.url = url
                self.size = size
                self.baseSHA256 = baseSHA256
            }

            private enum CodingKeys: String, CodingKey {
                case from
                case url
                case size
                case baseSHA256 = "base_sha256"
            }
        }

        public init(url: URL, signature: String, deltas: [Delta]? = nil) {
            self.url = url
            self.signature = signature
            self.deltas = deltas
        }
    }

    public init(
        version: String,
        pubDate: String? = nil,
        notes: String? = nil,
        minSupportedVersion: String? = nil,
        platforms: [String: PlatformEntry]
    ) {
        self.version = version
        self.pubDate = pubDate
        self.notes = notes
        self.minSupportedVersion = minSupportedVersion
        self.platforms = platforms
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case pubDate = "pub_date"
        case notes
        case minSupportedVersion = "min_supported_version"
        case platforms
    }

    /// Resolve the entry for `target` and turn it into an `UpdateInfo`
    /// suitable for passing to `Updater.download`. Returns `nil` if the
    /// manifest has no entry for the requested target. Sets
    /// `UpdateInfo.mandatory` when `currentVersion` is below the
    /// manifest's `min_supported_version` floor.
    public func updateInfo(for target: String, currentVersion: String) -> UpdateInfo? {
        guard let entry = platforms[target] else { return nil }
        let mandatory = minSupportedVersion
            .map { UpdaterVersion.isNewer($0, than: currentVersion) } ?? false
        // Pick the delta whose `from` matches the running version exactly.
        // No match ⇒ nil ⇒ the backend full-downloads. Projected to
        // `DeltaInfo` (drop `from`, already matched).
        let delta = entry.deltas?
            .first { $0.from == currentVersion }
            .map { UpdateInfo.DeltaInfo(url: $0.url, size: $0.size, baseSHA256: $0.baseSHA256) }
        return UpdateInfo(
            version: version,
            currentVersion: currentVersion,
            pubDate: pubDate,
            notes: notes,
            downloadURL: entry.url,
            signature: entry.signature,
            target: target,
            mandatory: mandatory,
            delta: delta
        )
    }
}

// MARK: - Target key derivation

public enum UpdaterTarget {
    /// Compute the platform/arch key used to look up the right artifact
    /// in an `UpdateManifest.platforms` table. Convention is
    /// `<os>-<arch>` with an optional package-format suffix:
    ///
    /// - `darwin-aarch64`, `darwin-x86_64`
    /// - `ios-aarch64-enterprise`
    /// - `windows-x86_64-msix`, `windows-x86_64-portable`
    /// - `linux-x86_64-appimage`, `linux-aarch64-appimage`
    /// - `android-aarch64-apk`, `android-x86_64-apk`
    ///
    /// `packageFormat` is supplied by the backend that knows what kind
    /// of bundle the app was installed from (the iOS / Windows / Linux
    /// / Android runtimes know; the macOS runtime doesn't need a
    /// suffix because the only first-class macOS artifact is
    /// `.app.tar.gz`).
    public static func current(packageFormat: String? = nil) -> String {
        let os: String
        #if os(macOS)
            os = "darwin"
        #elseif os(iOS)
            os = "ios"
        #elseif os(Linux)
            os = "linux"
        #elseif os(Windows)
            os = "windows"
        #elseif os(Android)
            os = "android"
        #else
            os = "unknown"
        #endif

        let arch: String
        #if arch(arm64)
            arch = "aarch64"
        #elseif arch(x86_64)
            arch = "x86_64"
        #else
            arch = "unknown"
        #endif

        return make(os: os, arch: arch, packageFormat: packageFormat)
    }

    /// Pure formatting helper exposed for tests: combine an `os` /
    /// `arch` pair (with an optional package-format suffix) into the
    /// manifest target key. Used by `current()` after compile-time
    /// detection; tests can drive every supported `os` / `arch`
    /// combination without conditional compilation.
    public static func make(os: String, arch: String, packageFormat: String? = nil) -> String {
        if let pkg = packageFormat, !pkg.isEmpty {
            return "\(os)-\(arch)-\(pkg)"
        }
        return "\(os)-\(arch)"
    }
}

// MARK: - Semantic version comparison

public enum UpdaterVersion {
    /// Strict-ish semver compare suitable for "is `lhs` newer than
    /// `rhs`". Splits on `.` and compares component-wise as integers
    /// where possible, falling back to lexicographic compare for
    /// non-numeric components (so `0.4.0-beta1` < `0.4.0`). Pre-release
    /// suffix handling deliberately matches Tauri's updater so manifest
    /// authors can rely on consistent ordering across the two
    /// frameworks.
    public static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        compare(lhs, rhs) > 0
    }

    public static func compare(_ lhs: String, _ rhs: String) -> Int {
        let (lCore, lPre) = split(lhs)
        let (rCore, rPre) = split(rhs)
        let lParts = lCore.split(separator: ".").map(String.init)
        let rParts = rCore.split(separator: ".").map(String.init)
        for i in 0 ..< max(lParts.count, rParts.count) {
            let l = i < lParts.count ? lParts[i] : "0"
            let r = i < rParts.count ? rParts[i] : "0"
            if let li = Int(l), let ri = Int(r) {
                if li != ri { return li < ri ? -1 : 1 }
            } else if l != r {
                return l < r ? -1 : 1
            }
        }
        // Core equal: a missing pre-release ranks *higher* than any
        // present pre-release (semver: 1.0.0 > 1.0.0-beta1).
        switch (lPre, rPre) {
        case (nil, nil): return 0
        case (nil, _): return 1
        case (_, nil): return -1
        case let (l?, r?):
            if l == r { return 0 }
            return l < r ? -1 : 1
        }
    }

    private static func split(_ v: String) -> (core: String, pre: String?) {
        if let dash = v.firstIndex(of: "-") {
            return (String(v[..<dash]), String(v[v.index(after: dash)...]))
        }
        return (v, nil)
    }
}

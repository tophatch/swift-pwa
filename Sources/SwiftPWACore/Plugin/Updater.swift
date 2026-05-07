import Foundation

/// Cross-platform auto-updater. Backends provide a concrete impl:
/// `AppleUpdater` (macOS + iOS) ships from `SwiftPWAWebKit`,
/// `LinuxAppImageUpdater` ships from `SwiftPWAGTK`, and `WindowsUpdater`
/// (portable + MSIX install modes) ships from `SwiftPWAWindows`.
/// Tests use `MockUpdater` from `_SwiftPWATestSupport`.
///
/// **Scope (v0.3 first cut):** signed JSON manifest fetch, full-bundle
/// download with progress events, Ed25519 signature verification, and
/// platform-native install. Delta updates and a mandatory-update
/// `min_supported_version` kill-switch are deferred — see the
/// "Auto-updates" section of the README and each platform's setup doc.
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

    public init(
        version: String,
        currentVersion: String,
        pubDate: String? = nil,
        notes: String? = nil,
        downloadURL: URL,
        signature: String,
        target: String
    ) {
        self.version = version
        self.currentVersion = currentVersion
        self.pubDate = pubDate
        self.notes = notes
        self.downloadURL = downloadURL
        self.signature = signature
        self.target = target
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case currentVersion = "current_version"
        case pubDate = "pub_date"
        case notes
        case downloadURL = "download_url"
        case signature
        case target
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
}

extension UpdaterEvent: Codable {
    private enum Tag: String, Codable {
        case checking
        case available
        case upToDate
        case downloadProgress
        case readyToInstall
        case error
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
///     "linux-x86_64-appimage":      { "url": "...", "signature": "..." }
///   }
/// }
/// ```
///
/// Per-target `signature` is base64 of the raw 64-byte Ed25519
/// signature over the artifact bytes. iOS enterprise leaves it empty
/// because `itms-services://` delegates trust to Apple's signing chain
/// rather than swift-pwa's key. Minisign-format signatures (Tauri's
/// preferred form) are a planned follow-up; for now use raw base64.
public struct UpdateManifest: Codable, Sendable, Equatable {
    public var version: String
    public var pubDate: String?
    public var notes: String?
    public var platforms: [String: PlatformEntry]

    public struct PlatformEntry: Codable, Sendable, Equatable {
        public var url: URL
        public var signature: String

        public init(url: URL, signature: String) {
            self.url = url
            self.signature = signature
        }
    }

    public init(
        version: String,
        pubDate: String? = nil,
        notes: String? = nil,
        platforms: [String: PlatformEntry]
    ) {
        self.version = version
        self.pubDate = pubDate
        self.notes = notes
        self.platforms = platforms
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case pubDate = "pub_date"
        case notes
        case platforms
    }

    /// Resolve the entry for `target` and turn it into an `UpdateInfo`
    /// suitable for passing to `Updater.download`. Returns `nil` if the
    /// manifest has no entry for the requested target.
    public func updateInfo(for target: String, currentVersion: String) -> UpdateInfo? {
        guard let entry = platforms[target] else { return nil }
        return UpdateInfo(
            version: version,
            currentVersion: currentVersion,
            pubDate: pubDate,
            notes: notes,
            downloadURL: entry.url,
            signature: entry.signature,
            target: target
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
    ///
    /// `packageFormat` is supplied by the backend that knows what kind
    /// of bundle the app was installed from (the iOS / Windows / Linux
    /// runtimes know; the macOS runtime doesn't need a suffix because
    /// the only first-class macOS artifact is `.app.tar.gz`).
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

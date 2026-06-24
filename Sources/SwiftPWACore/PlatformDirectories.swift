import Foundation

/// Resolves the per-app **persistent data** and **disposable cache**
/// directories for the host platform — the writable roots an app extracts
/// content packs into (`app.dataDir`) and stashes derived artifacts in
/// (`app.cacheDir`).
///
/// Desktop platforms resolve via Foundation / standard env vars. Android's
/// `filesDir` / `cacheDir` come from the Java `Context`, not Foundation, so
/// the Android backend installs a `Hook` at startup (the same pattern
/// `MainThread` uses for its UI-thread dispatcher); until a hook is set,
/// Android falls back to deriving the paths from the process temp dir.
public enum PlatformDirectories {
    /// Backend-supplied directory resolver. Installed by the Android
    /// backend with the Activity's real `filesDir` / `cacheDir`; left unset
    /// on desktop, where the Foundation defaults are correct.
    public struct Hook: Sendable {
        public let dataDirectory: @Sendable () -> URL
        public let cacheDirectory: @Sendable () -> URL
        public init(
            dataDirectory: @escaping @Sendable () -> URL,
            cacheDirectory: @escaping @Sendable () -> URL
        ) {
            self.dataDirectory = dataDirectory
            self.cacheDirectory = cacheDirectory
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var _hook: Hook?

    public static func setHook(_ hook: Hook) {
        lock.lock(); defer { lock.unlock() }
        _hook = hook
    }

    private static func currentHook() -> Hook? {
        lock.lock(); defer { lock.unlock() }
        return _hook
    }

    /// Persistent per-app data directory, created if absent. `appID` is the
    /// bundle id (or app name fallback) used as the leaf on desktop; it's
    /// ignored when a backend hook supplies an already-scoped path.
    public static func dataDirectory(appID: String) -> URL {
        let url = currentHook()?.dataDirectory() ?? defaultDataDirectory(appID: appID)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Disposable per-app cache directory, created if absent. The OS may
    /// evict its contents; never store anything here you can't regenerate.
    public static func cacheDirectory(appID: String) -> URL {
        let url = currentHook()?.cacheDirectory() ?? defaultCacheDirectory(appID: appID)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Platform defaults

    private static func defaultDataDirectory(appID: String) -> URL {
        #if os(macOS) || os(iOS)
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            return base.appendingPathComponent(appID, isDirectory: true)
        #elseif os(Windows)
            let appData = environmentDir("APPDATA") ?? NSTemporaryDirectory()
            return URL(fileURLWithPath: appData).appendingPathComponent(appID, isDirectory: true)
        #elseif os(Android)
            return androidFilesFallback()
        #else // Linux
            let base = environmentDir("XDG_DATA_HOME") ?? homeSubpath(".local/share")
            return URL(fileURLWithPath: base).appendingPathComponent(appID, isDirectory: true)
        #endif
    }

    private static func defaultCacheDirectory(appID: String) -> URL {
        #if os(macOS) || os(iOS)
            let base = (try? FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            return base.appendingPathComponent(appID, isDirectory: true)
        #elseif os(Windows)
            let local = environmentDir("LOCALAPPDATA") ?? NSTemporaryDirectory()
            return URL(fileURLWithPath: local)
                .appendingPathComponent(appID, isDirectory: true)
                .appendingPathComponent("Cache", isDirectory: true)
        #elseif os(Android)
            return URL(fileURLWithPath: NSTemporaryDirectory())
        #else // Linux
            let base = environmentDir("XDG_CACHE_HOME") ?? homeSubpath(".cache")
            return URL(fileURLWithPath: base).appendingPathComponent(appID, isDirectory: true)
        #endif
    }

    /// Read an env var, treating empty as unset.
    private static func environmentDir(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return value
    }

    private static func homeSubpath(_ sub: String) -> String {
        let home = environmentDir("HOME") ?? NSHomeDirectory()
        return home.hasSuffix("/") ? home + sub : home + "/" + sub
    }

    #if os(Android)
        /// Fallback when no hook is installed: `NSTemporaryDirectory()` maps
        /// to `/data/data/<pkg>/cache` on Android, whose sibling `files` is
        /// the persistent dir. The Android backend should install a `Hook`
        /// with the Activity's real paths to avoid relying on this layout.
        private static func androidFilesFallback() -> URL {
            URL(fileURLWithPath: NSTemporaryDirectory())
                .deletingLastPathComponent()
                .appendingPathComponent("files", isDirectory: true)
        }
    #endif
}

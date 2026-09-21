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
        /// The user-visible documents root — the *parent*, without the app's
        /// own leaf. Nil leaves the platform default in place, which is what
        /// every backend does today; it exists for a host whose documents
        /// location isn't derivable from the environment.
        public let documentsRoot: (@Sendable () -> URL)?

        public init(
            dataDirectory: @escaping @Sendable () -> URL,
            cacheDirectory: @escaping @Sendable () -> URL,
            documentsRoot: (@Sendable () -> URL)? = nil
        ) {
            self.dataDirectory = dataDirectory
            self.cacheDirectory = cacheDirectory
            self.documentsRoot = documentsRoot
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

    /// The folder an app owns **that the user can see**, created if absent —
    /// where content belongs when the user should keep it: books they added,
    /// documents they authored, exports.
    ///
    /// Distinct from ``dataDirectory(appID:)`` in the way that matters to a
    /// person rather than a program: the data directory is the app's private
    /// container, invisible in a file manager and **deleted when the app is**.
    /// This one is a real folder in Documents, and on four of the five
    /// platforms its contents outlive the app — see ``documentsSurviveUninstall``.
    ///
    /// Takes the app's **display name**, not its bundle id, because this path
    /// is one a person reads: `~/Documents/Reader`, not
    /// `~/Documents/com.example.reader`.
    ///
    /// On Android this is `/sdcard/Documents/<App>` and **needs no
    /// permission**: since Android 11 an app may create, list and read its
    /// *own* files in shared storage by path. All-files access is only what
    /// lets it see what everything *else* put there — see
    /// docs/android-setup.md.
    public static func documentsDirectory(appName: String) -> URL {
        let url = documentsRoot().appendingPathComponent(documentsLeaf(appName), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Turn an app's display name into a single folder name.
    ///
    /// This is where a name stops being a label and becomes a path, so it is
    /// the one place to stop a name changing the folder's *depth* — a name
    /// carrying `/` or `..` would otherwise put the app's library somewhere
    /// else entirely, and since the name can come from the environment
    /// (``AppPlugin/displayNameEnvironmentVariable``) that is a boundary, not
    /// a theoretical one.
    ///
    /// The Windows-reserved characters go the same way on **every** platform,
    /// so an app named `Reader: Pro` owns one folder called `Reader- Pro`
    /// rather than working on macOS and silently failing to create its
    /// directory on Windows. Spaces are kept — they are the whole point.
    static func documentsLeaf(_ appName: String) -> String {
        let illegal = Set("/\\:*?\"<>|")
        var leaf = String(appName.map { illegal.contains($0) ? "-" : $0 })
        // Control characters (a newline among them) are dropped rather than
        // substituted: they are never part of a name someone meant to type.
        leaf = leaf.filter { !$0.unicodeScalars.contains { scalar in scalar.properties.generalCategory == .control } }
        // Windows drops trailing dots and spaces from a directory name, which
        // would make two names collide that don't look like they should.
        while let last = leaf.last, last == "." || last == " " { leaf.removeLast() }
        leaf = leaf.trimmingCharacters(in: .whitespaces)
        return leaf.isEmpty ? "App" : leaf
    }

    /// Whether the contents of ``documentsDirectory(appName:)`` outlive the
    /// app being uninstalled.
    ///
    /// False on iOS alone, where the visible Documents folder is inside the
    /// app container and goes with it. That is worth surfacing rather than
    /// hiding: an app that knows can offer an export, instead of implying a
    /// permanence the platform won't provide. (iCloud's
    /// `NSUbiquitousContainers` is the iOS answer, and it needs an entitlement
    /// a free team can't have, so it can't be the default.)
    public static var documentsSurviveUninstall: Bool {
        #if os(iOS)
            false
        #else
            true
        #endif
    }

    // MARK: - Platform defaults

    /// The *parent* documents folder, without the app's leaf.
    private static func documentsRoot() -> URL {
        if let hook = currentHook()?.documentsRoot { return hook() }
        #if os(macOS) || os(iOS)
            // On iOS this is the app's own Documents container, which is what
            // `UIFileSharingEnabled` exposes in Files — already per-app, so
            // the leaf below nests inside it rather than beside other apps.
            return (try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
        #elseif os(Windows)
            // Through Foundation first: `%USERPROFILE%\Documents` is wrong on a
            // machine whose Documents folder is redirected, which OneDrive does
            // by default on a consumer install.
            if let known = try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ) {
                return known
            }
            let profile = environmentDir("USERPROFILE") ?? NSHomeDirectory()
            return URL(fileURLWithPath: profile).appendingPathComponent("Documents", isDirectory: true)
        #elseif os(Android)
            // `Environment.DIRECTORY_DOCUMENTS` is "Documents" by platform
            // contract, and `$EXTERNAL_STORAGE` is set for every app process,
            // so this needs no JNI hop on a path every app reads at startup.
            let external = environmentDir("EXTERNAL_STORAGE") ?? "/sdcard"
            return URL(fileURLWithPath: external).appendingPathComponent("Documents", isDirectory: true)
        #else // Linux
            return linuxDocumentsRoot()
        #endif
    }

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

    #if os(Linux)
        /// `XDG_DOCUMENTS_DIR` is a *user-dirs* value, not an environment
        /// variable — `xdg-user-dirs-update` writes it into
        /// `~/.config/user-dirs.dirs` and only some session managers export it.
        /// So: the env var if a session did export it, then the file, then the
        /// English default. A headless SSH session has neither, which is
        /// exactly where the last fallback earns its place.
        private static func linuxDocumentsRoot() -> URL {
            if let exported = environmentDir("XDG_DOCUMENTS_DIR") {
                return URL(fileURLWithPath: exported)
            }
            let home = environmentDir("HOME") ?? NSHomeDirectory()
            let configHome = environmentDir("XDG_CONFIG_HOME") ?? homeSubpath(".config")
            let userDirs = URL(fileURLWithPath: configHome).appendingPathComponent("user-dirs.dirs")
            if let text = try? String(contentsOf: userDirs, encoding: .utf8),
               let parsed = documentsDirFromUserDirs(text, home: home)
            {
                return URL(fileURLWithPath: parsed)
            }
            return URL(fileURLWithPath: homeSubpath("Documents"))
        }
    #endif

    /// Pull `XDG_DOCUMENTS_DIR` out of a `user-dirs.dirs` file.
    ///
    /// Not `#if os(Linux)`, so it can be tested on the machine anyone is
    /// actually sitting at. The format is shell-ish: `KEY="$HOME/Name"`, with
    /// `#` comments, and a localised install writes a localised folder name —
    /// which is the whole reason for reading the file instead of assuming
    /// `~/Documents`.
    static func documentsDirFromUserDirs(_ text: String, home: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.hasPrefix("XDG_DOCUMENTS_DIR=") else { continue }
            var value = String(trimmed.dropFirst("XDG_DOCUMENTS_DIR=".count))
            // Strip a trailing comment before the quotes, then the quotes.
            if let hash = value.firstIndex(of: "#"), !value.hasPrefix("\"") {
                value = String(value[value.startIndex ..< hash])
            }
            value = value.trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if value.hasPrefix("$HOME") {
                value = home + String(value.dropFirst("$HOME".count))
            }
            guard !value.isEmpty else { continue }
            return value
        }
        return nil
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

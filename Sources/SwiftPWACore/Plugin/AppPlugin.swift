import Foundation

/// Built-in plugin exposing the `app.*` command set: process-level
/// lifecycle and identity that every desktop app needs but that
/// `window.*` deliberately doesn't cover.
///
/// The motivating gap: `window.close` closes a *window*, which on macOS
/// leaves the app alive in the menu bar — so a "Quit" button used to mean
/// dropping into Swift to register a custom command that hopped to the UI
/// thread and called `AppContext.quit`. `app.quit` makes that a one-liner
/// from JS. `app.name` / `app.version` save reaching for a bundled config
/// just to render an About box.
///
/// Registered eagerly by every backend's `AppContext.init` (alongside
/// `WindowPlugin` / `PlatformInfoPlugin`) — never opt-in.
public struct AppPlugin: Plugin {
    public static let pluginName = "app"
    public init() {}

    public func register(into registry: CommandRegistry, app: any AppContext) {
        let app = app

        // Quitting hops to the UI thread because `AppContext` is
        // `@MainActor`. We use `MainThread.run` rather than `MainActor.run`
        // for the same reason `WindowPlugin` does — Swift's MainActor
        // executor isn't pumped by `gtk_main()` on Linux. The reply frame
        // may or may not flush before the loop tears down; a quit caller
        // doesn't meaningfully await it.
        registry.register("app.quit", typed: { (args: AppQuitArgs, _) async -> EmptyResult in
            await MainThread.run { app.quit(exitCode: args.exitCode ?? 0) }
            return EmptyResult()
        })

        registry.register("app.name", typed: { (_: EmptyArgs, _) -> StringResult in
            StringResult(value: Self.appName())
        })

        registry.register("app.version", typed: { (_: EmptyArgs, _) -> StringResult in
            StringResult(value: Self.appVersion())
        })

        // Per-app writable roots. `dataDir` is persistent (the place to
        // extract content packs into); `cacheDir` is disposable. Both are
        // created on first read so JS can write into them immediately.
        registry.register("app.dataDir", typed: { (_: EmptyArgs, _) -> StringResult in
            StringResult(value: PlatformDirectories.dataDirectory(appID: Self.appID()).path)
        })

        registry.register("app.cacheDir", typed: { (_: EmptyArgs, _) -> StringResult in
            StringResult(value: PlatformDirectories.cacheDirectory(appID: Self.appID()).path)
        })

        // The folder the *user* owns a view of, as against the two above,
        // which are the app's own containers. It carries `survivesUninstall`
        // rather than only a path because that is the one fact an app has to
        // branch on: iOS is the platform where the honest answer is no, and an
        // app that knows can offer an export instead of implying a permanence
        // the platform won't provide.
        registry.register("app.documentsDir", typed: { (_: EmptyArgs, _) -> DocumentsLocation in
            DocumentsLocation(
                path: PlatformDirectories.documentsDirectory(appName: Self.appName()).path,
                survivesUninstall: PlatformDirectories.documentsSurviveUninstall
            )
        })

        // What happens when the last window closes, readable and settable
        // from the page so an app can put it behind a preference checkbox.
        // Both sites that consult it read it when they need it, so a change
        // takes effect on the very next close — nothing is cached at launch.
        //
        // Where the choice is *stored* is deliberately the app's business:
        // an app already has somewhere it keeps preferences, and a runtime
        // that quietly persisted this one would then have to answer which of
        // the two wins at launch, its own file or `pwa.json`'s default.
        registry.register(
            "app.lastWindowClosed",
            typed: { (args: AppLastWindowClosedArgs, _) async throws -> StringResult in
                if let requested = args.value {
                    guard let policy = LastWindowClosedPolicy(rawValue: requested) else {
                        let valid = LastWindowClosedPolicy.allCases.map(\.rawValue).joined(separator: ", ")
                        throw BridgeError(
                            code: BridgeError.decode,
                            message: "app.lastWindowClosed: \"\(requested)\" isn't one of: \(valid)"
                        )
                    }
                    await MainThread.run { app.lastWindowClosed = policy }
                }
                return await StringResult(value: MainThread.run { app.lastWindowClosed.rawValue })
            }
        )
    }

    private static let displayNameLock = NSLock()
    private nonisolated(unsafe) static var installedDisplayName: String?

    /// Install the app's display name on a host that has no bundle to read it
    /// from. The Android backend calls this at startup with the Activity's
    /// own label; nothing else does.
    ///
    /// Without it Android had no name at all: `Bundle.main.infoDictionary` is
    /// empty there and the process name is **`app_process64`**, the zygote
    /// binary. That reached `app.name`, and once a user-visible folder was
    /// derived from it (#250) it reached the filesystem as
    /// `/sdcard/Documents/app_process64`.
    public static func setDisplayName(_ name: String) {
        guard !name.isEmpty else { return }
        displayNameLock.lock(); defer { displayNameLock.unlock() }
        installedDisplayName = name
    }

    /// Names the app for a binary that has no bundle to carry the name.
    ///
    /// **Debug builds only**, for the same reason ``WebRoot/environmentVariable``
    /// is: a shipped app that took its identity from its environment would let
    /// whoever launched it choose which folder under Documents it adopts.
    ///
    /// `swift-pwa dev`, `drive` and the headless catalog dump set it from
    /// `pwa.json`'s `name`. Without it a bare `swift build` binary falls back to
    /// the executable, which is the SwiftPM target name — and a target name
    /// can't contain a space, so an app called "Aether Reader" answered
    /// `AetherReader` in development and `Aether Reader` once bundled. Private
    /// containers can differ between the two harmlessly; ``documentsDirectory``
    /// can't, because a debug run then creates an empty folder beside the
    /// user's real library and adopts it (#254).
    public static let displayNameEnvironmentVariable = "SWIFT_PWA_APP_NAME"

    /// The human-facing app name. Prefers a name a backend installed, then the
    /// manifest name the tooling passed for an unbundled run, then the bundle's
    /// display name, then its bundle name, falling back to the process name on
    /// hosts where `Bundle.main.infoDictionary` isn't populated
    /// (corelibs-foundation on Linux). Never empty.
    static func appName() -> String {
        if let installed = installedName() { return installed }
        if let fromTooling = environmentDisplayName() { return fromTooling }
        return bundleOrProcessName()
    }

    private static func installedName() -> String? {
        displayNameLock.lock()
        let installed = installedDisplayName
        displayNameLock.unlock()
        guard let installed, !installed.isEmpty else { return nil }
        return installed
    }

    /// The tooling's answer, when this build is one the tooling can drive.
    private static func environmentDisplayName() -> String? {
        #if SWIFT_PWA_DRIVER
            guard let value = ProcessInfo.processInfo.environment[displayNameEnvironmentVariable],
                  !value.isEmpty
            else { return nil }
            return value
        #else
            return nil
        #endif
    }

    private static func bundleOrProcessName() -> String {
        let info = Bundle.main.infoDictionary
        if let display = info?["CFBundleDisplayName"] as? String, !display.isEmpty { return display }
        if let name = info?["CFBundleName"] as? String, !name.isEmpty { return name }
        return strippingExeExtension(ProcessInfo.processInfo.processName)
    }

    /// Strip a trailing `.exe` from a process name. On Windows
    /// `ProcessInfo.processName` includes the extension, which otherwise
    /// leaks into the display name (`app.name`) and the per-app data/cache
    /// directory leaf (e.g. `%APPDATA%\MyApp.exe\` instead of `…\MyApp\`).
    /// A no-op on macOS / Linux / Android, where the process name carries no
    /// extension. Case-insensitive; only `.exe` is stripped (not arbitrary
    /// extensions, so a Unix binary named `my.tool` is left intact).
    static func strippingExeExtension(_ name: String) -> String {
        name.lowercased().hasSuffix(".exe") ? String(name.dropLast(4)) : name
    }

    /// The marketing version (`CFBundleShortVersionString`), falling back
    /// to the build number, then the empty string when no `Info.plist` is
    /// available (Linux / Android). Empty signals "unknown" to JS rather
    /// than a misleading placeholder.
    static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        if let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty { return short }
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty { return build }
        return ""
    }

    /// Stable identifier used to scope the per-app data / cache
    /// directories on desktop. Prefers the bundle id; falls back to the
    /// (filesystem-safe-ish) app name when unbundled.
    /// Stable per-app identifier: the bundle id when present, else the
    /// (`.exe`-stripped) process name. Used to scope the data / cache
    /// directories, and by backends needing a per-app location (e.g. the
    /// Windows WebView2 user-data folder).
    public static func appID() -> String {
        if let id = Bundle.main.bundleIdentifier, !id.isEmpty { return id }
        if let installed = installedName() { return installed }
        // Deliberately *not* ``displayNameEnvironmentVariable``: the private
        // containers are scoped by bundle id in a shipped app, so renaming the
        // unbundled leaf wouldn't make a development run and an installed one
        // agree — it would only move development state to a new folder and
        // strand what was there. A driven run keeping its own data directory is
        // the useful behaviour anyway.
        return bundleOrProcessName()
    }
}

public extension AppContext {
    /// Persistent per-app data directory (created if absent) — the Swift-
    /// side equivalent of the `app.dataDir` command. Use as the extraction
    /// target for content packs and the root passed to `serveDirectory`.
    func dataDirectory() -> URL {
        PlatformDirectories.dataDirectory(appID: AppPlugin.appID())
    }

    /// Disposable per-app cache directory (created if absent) — the Swift-
    /// side equivalent of `app.cacheDir`. The OS may evict its contents.
    func cacheDirectory() -> URL {
        PlatformDirectories.cacheDirectory(appID: AppPlugin.appID())
    }

    /// The user-visible folder this app owns (created if absent) — the Swift-
    /// side equivalent of `app.documentsDir`, and the place for content the
    /// user should keep rather than content the app can regenerate.
    ///
    /// A real path on every platform, so it can be passed straight to
    /// ``serveDirectory(_:at:)`` and stream with ranges — which is what makes
    /// it the default library location rather than a SAF tree.
    ///
    /// Pair it with ``documentsSurviveUninstall`` before promising the user
    /// their files are safe.
    func documentsDirectory() -> URL {
        PlatformDirectories.documentsDirectory(appName: AppPlugin.appName())
    }

    /// Whether ``documentsDirectory()``'s contents outlive this app being
    /// uninstalled. False on iOS, true everywhere else.
    var documentsSurviveUninstall: Bool {
        PlatformDirectories.documentsSurviveUninstall
    }
}

// MARK: - Result types

/// What `app.documentsDir` returns: where the app's user-visible folder is,
/// and whether the user keeps what's in it.
public struct DocumentsLocation: Sendable, Codable, Equatable {
    /// Absolute path, created by the time this is returned.
    public var path: String
    /// False on iOS, where the visible Documents folder lives inside the app
    /// container and is removed with the app. True on macOS, Linux, Windows
    /// and Android, where the folder is a real place in the user's Documents.
    public var survivesUninstall: Bool

    public init(path: String, survivesUninstall: Bool) {
        self.path = path
        self.survivesUninstall = survivesUninstall
    }
}

// MARK: - Argument types

public struct AppQuitArgs: Sendable, Codable {
    /// Process exit code. Defaults to `0` (clean exit) when omitted.
    public var exitCode: Int32?
    public init(exitCode: Int32? = nil) { self.exitCode = exitCode }
}

public struct AppLastWindowClosedArgs: Sendable, Codable {
    /// The policy to set — `reopen`, `keep-running` or `quit`. Omit to read
    /// the current one; either way the reply carries the value in force
    /// afterwards, so a settings UI can round-trip in one call.
    public var value: String?
    public init(value: String? = nil) { self.value = value }
}

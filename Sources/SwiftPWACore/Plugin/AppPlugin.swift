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
    }

    /// The human-facing app name. Prefers the bundle's display name, then
    /// its bundle name, falling back to the process name on hosts where
    /// `Bundle.main.infoDictionary` isn't populated (corelibs-foundation
    /// on Linux, the Android .so). Never empty.
    static func appName() -> String {
        let info = Bundle.main.infoDictionary
        if let display = info?["CFBundleDisplayName"] as? String, !display.isEmpty { return display }
        if let name = info?["CFBundleName"] as? String, !name.isEmpty { return name }
        return ProcessInfo.processInfo.processName
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
    static func appID() -> String {
        if let id = Bundle.main.bundleIdentifier, !id.isEmpty { return id }
        return appName()
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
}

// MARK: - Argument types

public struct AppQuitArgs: Sendable, Codable {
    /// Process exit code. Defaults to `0` (clean exit) when omitted.
    public var exitCode: Int32?
    public init(exitCode: Int32? = nil) { self.exitCode = exitCode }
}

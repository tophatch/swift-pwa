import Foundation

/// What `__platform.info` returns to JS. Apps can read this to make
/// per-platform UI decisions — e.g. greying out a "Copy from
/// clipboard" button when the active backend hasn't installed
/// `ClipboardPlugin`. Registered automatically by every backend's
/// `AppContext.init`; never opt-in.
public struct PlatformInfo: Sendable, Codable, Equatable {
    /// Lowercased OS identifier: `"macos"`, `"ios"`, `"linux"`,
    /// `"windows"`, `"android"`, or `"unknown"`. Stable;
    /// `swift-pwa` doesn't reuse these values for anything else.
    public var os: String
    /// Every command name currently registered on the
    /// `CommandRegistry`. Sorted, so JS can do membership checks
    /// against a stable order without re-sorting.
    public var commands: [String]
    /// Absolute path to a writable temp directory the app can use
    /// for scratch files when `dialog.saveFile` isn't available
    /// (e.g. on the v0.5 Android backend) or otherwise inappropriate
    /// (background work, machine-generated paths). Resolved via
    /// `NSTemporaryDirectory()`, which Foundation maps to the
    /// platform's standard per-process temp area:
    /// `/var/folders/...` on macOS, `<bundle>/tmp` on iOS,
    /// `/tmp` on Linux, `%TEMP%` on Windows, `/data/data/<pkg>/cache`
    /// on Android. No trailing slash.
    public var tempDir: String

    public init(os: String, commands: [String], tempDir: String) {
        self.os = os
        self.commands = commands
        self.tempDir = tempDir
    }
}

/// Built-in plugin that exposes `__platform.info`. The JS side reads
/// the returned `commands` list to decide which UI controls to enable
/// — much simpler than trying every command and watching for "command
/// not registered" errors. Registered eagerly by each backend's
/// `AppContext.init` so the OS branches in cross-platform demos
/// (HelloPWA's button grid, in particular) have a single source of
/// truth.
public final class PlatformInfoPlugin: Plugin {
    public static let pluginName = "__platform"

    public init() {}

    @MainActor
    public func register(into registry: CommandRegistry, app _: any AppContext) {
        // The closure captures `registry`. `registry.names()` is
        // called at invoke time, not registration time — the list
        // grows as later `use(_:)` calls install more plugins, so a
        // late-bound read is what gives JS the up-to-date set. (The
        // backends register `PlatformInfoPlugin` first, then plugins
        // like `WindowPlugin`, then user-`use`d plugins, then the
        // first window's webview navigation triggers the page load.
        // By the time JS makes its first `__platform.info` invoke
        // call, every plugin in the configure closure is registered.)
        let registryRef = registry
        registry.register("__platform.info", typed: { (_: EmptyArgs, _) -> PlatformInfo in
            // `NSTemporaryDirectory()` returns the path with a
            // trailing slash on Apple, no trailing slash on
            // swift-corelibs-foundation. Strip for consistency so
            // JS callers can do `info.tempDir + "/foo.txt"` without
            // double-slash worries.
            var temp = NSTemporaryDirectory()
            if temp.hasSuffix("/") { temp.removeLast() }
            return PlatformInfo(
                os: currentOSIdentifier(),
                commands: registryRef.names().sorted(),
                tempDir: temp
            )
        })
    }
}

/// Private — exposed via `__platform.info`'s `os` field. Lowercased
/// to match the values JS code on the page typically compares
/// against (e.g. `if (info.os === 'android')`).
private func currentOSIdentifier() -> String {
    #if os(macOS)
        return "macos"
    #elseif os(iOS)
        return "ios"
    #elseif os(Linux)
        return "linux"
    #elseif os(Windows)
        return "windows"
    #elseif os(Android)
        return "android"
    #else
        return "unknown"
    #endif
}

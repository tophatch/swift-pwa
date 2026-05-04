import Foundation

/// Top-level entry point. A backend (`SwiftPWAWebKit`, `SwiftPWAGTK`)
/// provides one of these; user code obtains it via `SwiftPWA.runtime()`
/// on the umbrella module.
public protocol AppRuntime: AnyObject, Sendable {
    /// Configure the app, then run the platform event loop. Does not
    /// return until the app exits.
    @MainActor
    func run(
        _ configure: @escaping @MainActor @Sendable (any AppContext) throws -> Void
    ) throws -> Never
}

/// Per-app, mutable context passed to the configure closure.
@MainActor
public protocol AppContext: AnyObject, Sendable {
    var registry: CommandRegistry { get }

    /// All windows currently alive in this app, keyed by id.
    var windows: [WindowID: any Window] { get }

    /// Create a new window. Backends implement this; the resulting
    /// window's webview is wired into the bridge runtime automatically.
    @discardableResult
    func createWindow(_ config: WindowConfig) throws -> any Window

    /// Install a plugin (registers its commands into the registry).
    func use(_ plugin: any Plugin)

    /// Look up a window by id. `O(1)`.
    func window(_ id: WindowID) -> (any Window)?

    /// Begin orderly shutdown of the platform event loop with the given exit code.
    func quit(exitCode: Int32)
}

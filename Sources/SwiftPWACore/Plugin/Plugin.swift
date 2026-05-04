import Foundation

/// A bundle of related JS-callable commands that can be installed into
/// an `AppContext`. The built-in `WindowPlugin` is one; future tray /
/// notification / clipboard / biometric plugins will live in their own
/// SwiftPM targets and conform here.
public protocol Plugin: Sendable {
    /// Stable name (used for diagnostics and to prevent double-installs).
    static var pluginName: String { get }

    /// Register handlers into the registry. Called once, on the main
    /// actor, when the plugin is `use`d. Synchronous: handlers are async
    /// but the registry now stores them via a lock, not actor isolation,
    /// so registration doesn't need to suspend.
    @MainActor
    func register(into registry: CommandRegistry, app: any AppContext)
}

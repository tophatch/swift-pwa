import Foundation
import SwiftPWACore

/// In-memory `AppContext` for unit tests. Creates `MockWindow`s.
@MainActor
public final class MockAppContext: AppContext {
    public let registry: CommandRegistry
    public let assetProvider = AssetProvider()
    public let events = EventBus()
    public let permissions = PermissionPolicy()
    public let externalURLs = ExternalURLPolicy()

    /// Settable so a test can stand in for what a backend supplies — the
    /// browser a sign-in opens, and the OS authorization session Apple has and
    /// nobody else does.
    public var urlOpener: (any URLOpener)?
    public var authorizationSession: (any AuthorizationSessionPresenter)?
    /// Stored to satisfy ``AppContext``; this backend never reads it.
    /// macOS is the only platform where an app outlives its windows —
    /// see ``LastWindowClosedPolicy``.
    public var lastWindowClosed: LastWindowClosedPolicy = .reopen
    public var windows: [WindowID: any Window] = [:]
    public private(set) var didQuitWith: Int32?
    public private(set) var installedPlugins: [String] = []

    public init(registry: CommandRegistry = CommandRegistry()) {
        self.registry = registry
    }

    /// Register a pre-existing window (typically a test mock). Useful
    /// when tests want full control over the `MockWebView` rather than
    /// letting `createWindow` build one.
    public func attach(_ window: any Window) {
        windows[window.id] = window
    }

    @discardableResult
    public func createWindow(_ config: WindowConfig) throws -> any Window {
        let win = MockWindow(
            id: WindowID(),
            title: config.title,
            size: config.size,
            position: .zero
        )
        windows[win.id] = win
        return win
    }

    public func use(_ plugin: any Plugin) {
        installedPlugins.append(type(of: plugin).pluginName)
        plugin.register(into: registry, app: self)
    }

    public func window(_ id: WindowID) -> (any Window)? {
        windows[id]
    }

    public func quit(exitCode: Int32) {
        didQuitWith = exitCode
    }
}

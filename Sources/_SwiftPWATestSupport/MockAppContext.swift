import Foundation
import SwiftPWACore

/// In-memory `AppContext` for unit tests. Creates `MockWindow`s.
@MainActor
public final class MockAppContext: AppContext {
    public let registry: CommandRegistry
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

    public func use(_ plugin: any Plugin) async {
        installedPlugins.append(type(of: plugin).pluginName)
        await plugin.register(into: registry, app: self)
    }

    public func window(_ id: WindowID) -> (any Window)? {
        windows[id]
    }

    public func quit(exitCode: Int32) {
        didQuitWith = exitCode
    }
}

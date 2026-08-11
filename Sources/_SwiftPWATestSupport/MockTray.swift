import Foundation
import SwiftPWACore

/// In-memory `Tray` for unit tests. `Tray` is `@MainActor`-isolated, so
/// state lives on the main actor and `Sendable` is satisfied implicitly.
@MainActor
public final class MockTray: Tray {
    public enum Action: Sendable, Equatable {
        case setIcon(path: String, template: Bool)
        case setTooltip(String)
        case setMenu(TrayMenu)
        case setVisible(Bool)
    }

    public private(set) var actions: [Action] = []
    public private(set) var iconPath: String?
    public private(set) var iconTemplate: Bool = false
    public private(set) var tooltip: String?
    public private(set) var menu: TrayMenu = .init()
    public private(set) var visible: Bool = true

    /// What this tray claims about its background, for tests that check art
    /// polarity. `nil` (the default) is the real behaviour on a platform that
    /// tints template art for itself.
    public var prefersLightArt: Bool?

    private var continuations: [UUID: AsyncStream<TrayEvent>.Continuation] = [:]

    public init(prefersLightArt: Bool? = nil) {
        self.prefersLightArt = prefersLightArt
    }

    public func setIcon(path: String, template: Bool) {
        actions.append(.setIcon(path: path, template: template))
        iconPath = path
        iconTemplate = template
    }

    public func setTooltip(_ text: String) {
        actions.append(.setTooltip(text))
        tooltip = text
    }

    public func setMenu(_ menu: TrayMenu) {
        actions.append(.setMenu(menu))
        self.menu = menu
    }

    public func setVisible(_ visible: Bool) {
        actions.append(.setVisible(visible))
        self.visible = visible
    }

    public func eventStream() -> AsyncStream<TrayEvent> {
        let key = UUID()
        return AsyncStream { continuation in
            self.continuations[key] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in self.continuations.removeValue(forKey: key) }
            }
        }
    }

    /// Fire an event to all current subscribers (used by tests).
    public func emit(_ event: TrayEvent) {
        for c in continuations.values { c.yield(event) }
    }
}

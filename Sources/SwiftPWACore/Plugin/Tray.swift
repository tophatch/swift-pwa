import Foundation

/// Cross-platform system tray / menu-bar item. Backends provide a
/// concrete implementation (`SystemTray` in `SwiftPWAWebKit` and
/// `SwiftPWAGTK`); tests use `MockTray` from `_SwiftPWATestSupport`.
///
/// **Platform support:** full on macOS (`NSStatusItem`) and the GTK3
/// Linux backend (`GtkStatusIcon`). On iOS and the GTK4 backend the
/// concrete `SystemTray` is a no-op stub that logs a one-shot warning,
/// so the same JS works everywhere — the tray just isn't displayed.
/// `GtkStatusIcon` was removed in GTK4; AppIndicator support comes in a
/// follow-up release once we add the libayatana dependency.
@MainActor
public protocol Tray: AnyObject, Sendable {
    /// Set the icon shown in the tray. Path is interpreted by the
    /// platform's image loader (`NSImage(byReferencingFile:)` on Apple,
    /// `gtk_status_icon_set_from_file` on GTK). `template` requests a
    /// monochrome menu-bar style on macOS — `template == false` on
    /// other platforms is a no-op since they don't auto-tint.
    func setIcon(path: String, template: Bool)

    /// Set the hover-tooltip text.
    func setTooltip(_ text: String)

    /// Replace the tray's context menu. Setting an empty `items` array
    /// removes the menu entirely (left-click then emits `.click`
    /// instead of opening a menu, on platforms that distinguish).
    func setMenu(_ menu: TrayMenu)

    /// Show / hide the tray icon. Newly-created trays are visible.
    func setVisible(_ visible: Bool)

    /// Stream of tray-originated events: clicks on the icon and
    /// activations of menu items by id.
    func eventStream() -> AsyncStream<TrayEvent>
}

// MARK: - Menu model

public struct TrayMenu: Sendable, Codable, Equatable {
    public var items: [TrayMenuItem]
    public init(items: [TrayMenuItem] = []) { self.items = items }
}

public struct TrayMenuItem: Sendable, Codable, Equatable {
    /// Stable identifier reported via `TrayEvent.menuItemClicked`. Use
    /// the empty string for separator items.
    public var id: String
    public var label: String
    public var enabled: Bool
    public var separator: Bool

    public init(id: String, label: String, enabled: Bool = true, separator: Bool = false) {
        self.id = id
        self.label = label
        self.enabled = enabled
        self.separator = separator
    }

    /// Convenience for separator rows.
    public static func separator() -> TrayMenuItem {
        TrayMenuItem(id: "", label: "", enabled: false, separator: true)
    }
}

// MARK: - Events

public enum TrayEvent: Sendable, Equatable {
    /// Left / primary click on the tray icon. Only emitted when no
    /// menu is currently set — when a menu is set, the platform shows
    /// the menu instead of dispatching a click.
    case click
    /// A non-separator menu item was activated. `id` is the item's
    /// stable identifier from `TrayMenuItem.id`.
    case menuItemClicked(id: String)
}

/// Encoded with a `type` discriminator + sibling fields, matching the
/// `WindowEvent` shape:
///   { "type": "click" }
///   { "type": "menuItemClicked", "id": "open" }
extension TrayEvent: Codable {
    private enum CodingKeys: String, CodingKey { case type, id }

    private enum Tag: String, Codable { case click, menuItemClicked }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .click:
            try c.encode(Tag.click, forKey: .type)
        case let .menuItemClicked(id):
            try c.encode(Tag.menuItemClicked, forKey: .type)
            try c.encode(id, forKey: .id)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .click: self = .click
        case .menuItemClicked: self = try .menuItemClicked(id: c.decode(String.self, forKey: .id))
        }
    }
}

// MARK: - DTOs (used by `TrayPlugin`)

public struct TraySetIconArgs: Sendable, Codable, Equatable {
    public var path: String
    public var template: Bool?
    public init(path: String, template: Bool? = nil) {
        self.path = path
        self.template = template
    }
}

public struct TraySetTooltipArgs: Sendable, Codable, Equatable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct TraySetVisibleArgs: Sendable, Codable, Equatable {
    public var visible: Bool
    public init(visible: Bool) { self.visible = visible }
}
